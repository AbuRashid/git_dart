import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A git config file, and the ones it inherits from.
///
/// The format is INI with one addition: a section may carry a quoted
/// subsection name — `[remote "origin"]` — and the subsection is
/// case-sensitive while the section and key are not.
///
/// Only what this library needs is interpreted. Everything else is kept as
/// text, because a config reader that dropped what it did not understand
/// would make a round trip lossy.
class GitConfig {
  /// Keys as `section.name` or `section.subsection.name`, lowercased except
  /// for the subsection.
  final Map<String, List<String>> _values;

  const GitConfig(this._values);

  static const empty = GitConfig({});

  /// The last value set for [key], or null. Last wins, which is how a
  /// repository's config overrides the user's.
  String? operator [](String key) => _values[key]?.last;

  /// Every value for [key], in order. Some keys are legitimately repeated —
  /// a remote's fetch refspecs, for one.
  List<String> all(String key) => _values[key] ?? const [];

  bool? boolean(String key) {
    final value = this[key]?.toLowerCase();
    if (value == null) return null;
    // git accepts a key with no value as true: `[core] bare`.
    if (const ['true', 'yes', 'on', '1', ''].contains(value)) return true;
    if (const ['false', 'no', 'off', '0'].contains(value)) return false;
    return null;
  }

  int? number(String key) => int.tryParse(this[key] ?? '');

  /// The subsection names present under [section] — the remotes, the branches.
  Set<String> subsections(String section) {
    final prefix = '${section.toLowerCase()}.';
    return {
      for (final key in _values.keys)
        if (key.startsWith(prefix) && key.split('.').length >= 3)
          key.substring(prefix.length, key.lastIndexOf('.')),
    };
  }

  Map<String, List<String>> get entries => Map.unmodifiable(_values);

  /// Reads the system, the user's and the repository's config, in git's own
  /// order of precedence — later wins.
  ///
  /// An earlier version skipped the system file, on the grounds that this
  /// library had no business acting on a machine-wide setting. That was wrong
  /// in a way that showed up immediately: Git for Windows ships
  /// `init.defaultBranch = master` in its system config, so a repository
  /// created without reading it got a different branch name from the one the
  /// user's own git would have created. A config reader that answers
  /// differently from `git config` is not a config reader.
  factory GitConfig.forRepository(String gitDirectory) {
    final merged = <String, List<String>>{};
    for (final path in [
      ...systemConfigPaths,
      ...globalConfigPaths,
      p.join(gitDirectory, 'config'),
    ]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final parsed = GitConfig.parse(file.readAsStringSync());
      parsed._values.forEach((key, values) {
        merged.putIfAbsent(key, () => []).addAll(values);
      });
    }
    return GitConfig(merged);
  }

  /// Where git looks for the machine-wide config.
  ///
  /// `GIT_CONFIG_NOSYSTEM` suppresses it and `GIT_CONFIG_SYSTEM` replaces it,
  /// both as git treats them, so a caller that wants a repeatable answer has
  /// git's own way of asking for one.
  static List<String> get systemConfigPaths {
    final environment = Platform.environment;
    if (environment['GIT_CONFIG_NOSYSTEM'] case final suppressed?
        when suppressed.isNotEmpty && suppressed != '0') {
      return const [];
    }
    if (environment['GIT_CONFIG_SYSTEM'] case final override?
        when override.isNotEmpty) {
      return [override];
    }

    if (Platform.isWindows) {
      // Git for Windows keeps it under its own installation directory.
      final roots = <String>{
        if (environment['ProgramFiles'] case final path?) path,
        if (environment['ProgramW6432'] case final path?) path,
        r'C:\Program Files',
      };
      return [for (final root in roots) p.join(root, 'Git', 'etc', 'gitconfig')];
    }
    return const ['/etc/gitconfig', '/usr/local/etc/gitconfig'];
  }

  static List<String> get globalConfigPaths {
    final home = _home;
    if (home == null) return const [];
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    return [
      if (xdg != null) p.join(xdg, 'git', 'config'),
      p.join(home, '.config', 'git', 'config'),
      p.join(home, '.gitconfig'),
    ];
  }

  factory GitConfig.parse(String text) {
    final values = <String, List<String>>{};
    var section = '';

    for (var line in LineSplitter.split(text)) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }

      if (line.startsWith('[')) {
        final close = line.indexOf(']');
        if (close < 0) continue;
        final header = line.substring(1, close).trim();
        final quote = header.indexOf('"');
        if (quote < 0) {
          section = header.toLowerCase().replaceAll(' ', '.');
        } else {
          // The subsection keeps its case; the section does not.
          final name = header.substring(0, quote).trim().toLowerCase();
          final subsection =
              header.substring(quote + 1, header.lastIndexOf('"'));
          section = '$name.$subsection';
        }
        continue;
      }

      final equals = line.indexOf('=');
      final key = (equals < 0 ? line : line.substring(0, equals)).trim();
      final value = equals < 0 ? '' : _unquote(line.substring(equals + 1).trim());
      if (key.isEmpty) continue;

      values
          .putIfAbsent('$section.${key.toLowerCase()}', () => [])
          .add(value);
    }

    return GitConfig(values);
  }

  static String _unquote(String value) {
    var text = value;
    // A trailing comment is not part of the value unless it is quoted.
    //
    // Escapes are read either way: quoting decides how whitespace and comment
    // characters are treated, not whether a backslash is an escape. git writes
    // `url = C:\\Users\\a` unquoted, and reading that literally gives a path
    // with doubled separators that matches nothing.
    if (!text.startsWith('"')) {
      final hash = text.indexOf(RegExp('[#;]'));
      if (hash >= 0) text = text.substring(0, hash).trim();
      return _unescape(text);
    }
    final close = text.lastIndexOf('"');
    if (close <= 0) return text;
    return _unescape(text.substring(1, close));
  }

  /// Reads escape sequences in a single left-to-right pass.
  ///
  /// Sequential replaces cannot do this: turning `\\` into `\` first leaves a
  /// backslash that the next rule reads as the start of an escape, so
  /// `C:\\temp\\twice` became `C:\temp<tab>wice`. Found by pushing to a
  /// Windows path.
  static String _unescape(String value) {
    final out = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      if (value[i] != r'\' || i + 1 >= value.length) {
        out.write(value[i]);
        continue;
      }
      i += 1;
      out.write(switch (value[i]) {
        'n' => '\n',
        't' => '\t',
        'b' => '\b',
        '"' => '"',
        r'\' => r'\',
        // git treats an unknown escape as an error; keeping the character is
        // friendlier and cannot corrupt a path.
        final other => other,
      });
    }
    return out.toString();
  }

  static String? get _home =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  /// Expands the `~` git allows at the start of a path setting.
  static String expandHome(String path) {
    if (!path.startsWith('~')) return path;
    final home = _home;
    if (home == null) return path;
    return p.join(home, path.substring(1).replaceAll(RegExp(r'^[/\\]'), ''));
  }
}
