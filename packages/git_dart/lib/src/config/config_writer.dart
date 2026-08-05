import 'dart:io';

import 'package:path/path.dart' as p;

import 'git_config.dart';
import '../remote/remote.dart' show RemoteStore;

/// Which file a setting is written to, and where it is read from.
///
/// Precedence runs system, then global, then local — later wins — which is
/// why a value can look unchanged after being set: something more specific is
/// covering it.
enum ConfigScope {
  /// The machine's config, shared by every user.
  system,

  /// This user's config, shared by every repository.
  global,

  /// This repository only.
  local;

  String get label => switch (this) {
        ConfigScope.system => 'System',
        ConfigScope.global => 'Global',
        ConfigScope.local => 'This repository',
      };
}

/// Where a value in force actually came from.
class ConfigOrigin {
  final ConfigScope scope;
  final String value;
  const ConfigOrigin(this.scope, this.value);
}

/// Edits git config files in place.
///
/// Rewritten line by line rather than regenerated, so a file the user has
/// arranged by hand — with their comments, their spacing, their ordering —
/// comes back recognisable. A config editor that reformats what it touches is
/// one people stop using.
class ConfigWriter {
  /// The repository's own config, for [ConfigScope.local].
  final String gitDirectory;

  const ConfigWriter(this.gitDirectory);

  String? pathFor(ConfigScope scope) => switch (scope) {
        ConfigScope.local => p.join(gitDirectory, 'config'),
        ConfigScope.global => _firstGlobalPath(),
        ConfigScope.system => GitConfig.systemConfigPaths
            .where((path) => File(path).existsSync())
            .firstOrNull,
      };

  /// The user's config: whichever exists, else `~/.gitconfig`, which is where
  /// git itself would create one.
  static String? _firstGlobalPath() {
    final candidates = GitConfig.globalConfigPaths;
    if (candidates.isEmpty) return null;
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return candidates.last;
  }

  /// The value in force for [key], and which file it came from.
  ///
  /// Null when nothing sets it, in which case git's own default applies —
  /// which this library does not know and does not pretend to.
  ConfigOrigin? origin(String key) {
    for (final scope in const [
      ConfigScope.local,
      ConfigScope.global,
      ConfigScope.system,
    ]) {
      final path = pathFor(scope);
      if (path == null || !File(path).existsSync()) continue;
      final value = GitConfig.parse(File(path).readAsStringSync())[key];
      if (value != null) return ConfigOrigin(scope, value);
    }
    return null;
  }

  /// Everything a scope's file sets, for a reader that wants the whole picture.
  GitConfig read(ConfigScope scope) {
    final path = pathFor(scope);
    if (path == null || !File(path).existsSync()) return GitConfig.empty;
    return GitConfig.parse(File(path).readAsStringSync());
  }

  /// Sets `section.key` — or `section.subsection.key` — in [scope].
  void set(String key, String value, ConfigScope scope) {
    final path = pathFor(scope);
    if (path == null) {
      throw StateError('there is no ${scope.label.toLowerCase()} config file');
    }

    final parts = _split(key);
    final file = File(path);
    final lines = file.existsSync() ? file.readAsLinesSync() : <String>[];
    final written = RemoteStore.escapeConfigValue(value);

    final out = <String>[];
    var inSection = false;
    var replaced = false;
    var lastLineOfSection = -1;

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.startsWith('[')) {
        inSection = _sectionMatches(trimmed, parts.section, parts.subsection);
        out.add(line);
        if (inSection) lastLineOfSection = out.length - 1;
        continue;
      }

      if (inSection && !replaced && _isKey(trimmed, parts.key)) {
        // Keep the indentation the file already uses.
        final indent = line.substring(0, line.length - line.trimLeft().length);
        out.add('$indent${parts.key} = $written');
        replaced = true;
        lastLineOfSection = out.length - 1;
        continue;
      }

      out.add(line);
      if (inSection && trimmed.isNotEmpty) lastLineOfSection = out.length - 1;
    }

    if (!replaced) {
      if (lastLineOfSection >= 0) {
        // The section exists: the new line joins it rather than starting a
        // second section with the same name.
        out.insert(lastLineOfSection + 1, '\t${parts.key} = $written');
      } else {
        if (out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
        out
          ..add(parts.subsection == null
              ? '[${parts.section}]'
              : '[${parts.section} "${parts.subsection}"]')
          ..add('\t${parts.key} = $written');
      }
    }

    _write(file, out);
  }

  /// Removes a setting, so whatever a wider scope says applies again.
  void unset(String key, ConfigScope scope) {
    final path = pathFor(scope);
    if (path == null || !File(path).existsSync()) return;

    final parts = _split(key);
    final file = File(path);
    final out = <String>[];
    var inSection = false;

    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) {
        inSection = _sectionMatches(trimmed, parts.section, parts.subsection);
        out.add(line);
        continue;
      }
      if (inSection && _isKey(trimmed, parts.key)) continue;
      out.add(line);
    }

    _write(file, out);
  }

  void _write(File file, List<String> lines) {
    file.parent.createSync(recursive: true);
    // The same rename dance as a ref: a half-written config makes a
    // repository unreadable to git as well as to this.
    final temporary = File('${file.path}.lock');
    temporary.writeAsStringSync(
      lines.isEmpty ? '' : '${lines.join('\n')}\n',
    );
    if (file.existsSync()) file.deleteSync();
    temporary.renameSync(file.path);
  }

  static ({String section, String? subsection, String key}) _split(String key) {
    final parts = key.split('.');
    if (parts.length < 2) {
      throw ArgumentError.value(key, 'key', 'expected section.key');
    }
    if (parts.length == 2) {
      return (section: parts.first, subsection: null, key: parts.last);
    }
    return (
      section: parts.first,
      subsection: parts.sublist(1, parts.length - 1).join('.'),
      key: parts.last,
    );
  }

  static bool _sectionMatches(
    String header,
    String section,
    String? subsection,
  ) {
    final inside = header.substring(1, header.lastIndexOf(']')).trim();
    final quote = inside.indexOf('"');
    if (quote < 0) {
      return subsection == null &&
          inside.toLowerCase() == section.toLowerCase();
    }
    final name = inside.substring(0, quote).trim().toLowerCase();
    final sub = inside.substring(quote + 1, inside.lastIndexOf('"'));
    return name == section.toLowerCase() && sub == subsection;
  }

  static bool _isKey(String line, String key) {
    final equals = line.indexOf('=');
    final name = (equals < 0 ? line : line.substring(0, equals)).trim();
    return name.toLowerCase() == key.toLowerCase();
  }
}
