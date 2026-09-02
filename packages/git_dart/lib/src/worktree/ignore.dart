import 'dart:convert';

import 'package:path/path.dart' as p;

import '../config/git_config.dart';
import '../fs/git_fs.dart';
import '../platform/host.dart';

/// One line of a `.gitignore`.
class IgnorePattern {
  /// Matches the path or anything below it, which is `.gitignore`'s rule: an
  /// ignored directory takes its contents with it.
  final RegExp matcher;

  /// Matches the path and nothing under it.
  ///
  /// Needed by a caller that walks a path one component at a time and wants
  /// each level answered on its own. Under [matcher] a root pattern like `/*`
  /// also claims `keep/k.txt`, which would let it overrule a decision made
  /// about `keep` — right for "is this ignored", wrong for a walk that has
  /// already asked about the directory.
  final RegExp exactMatcher;

  /// A `!` pattern un-ignores what an earlier pattern ignored.
  final bool negated;

  /// A pattern ending in `/` matches directories only.
  final bool directoryOnly;

  /// The directory the pattern was written in, relative to the working tree
  /// root. A pattern is scoped to its own file's directory and below.
  final String base;

  final String source;

  const IgnorePattern({
    required this.matcher,
    required this.exactMatcher,
    required this.negated,
    required this.directoryOnly,
    required this.base,
    required this.source,
  });

  @override
  String toString() => source;
}

/// The ignore rules in force, in the order they were added.
///
/// The last pattern that matches decides, which is what makes `!` work at all:
/// an earlier rule ignores a directory's contents and a later one rescues one
/// file from it.
class IgnoreRules {
  final List<IgnorePattern> patterns = [];

  /// Reads a `.gitignore`-shaped file. [base] is its directory relative to the
  /// working tree root, `''` at the root.
  void addFile(String path, {String base = ''}) {
    final file = fs.file(path);
    if (!file.existsSync()) return;
    addText(file.readAsStringSync(), base: base);
  }

  void addText(String text, {String base = ''}) {
    for (final raw in LineSplitter.split(text)) {
      final pattern = _compile(raw, base);
      if (pattern != null) patterns.add(pattern);
    }
  }

  /// True when [path] — relative to the working tree root, forward slashes —
  /// is ignored.
  bool isIgnored(String path, {bool isDirectory = false}) =>
      decide(path, isDirectory: isDirectory) ?? false;

  /// What the rules say about [path], or null when none of them mention it.
  ///
  /// The distinction matters to anything that carries a decision from one path
  /// component to the next: "no rule matched" has to leave an inherited answer
  /// alone, where "a rule matched and it was negated" has to overturn it.
  /// [isIgnored] can collapse the two because an unmentioned path is not
  /// ignored; sparse checkout cannot, because an unmentioned path inherits
  /// whatever its directory was told.
  /// [exact] answers about this path alone, ignoring the rule that a matched
  /// directory carries its contents. A caller walking a path component by
  /// component has already accounted for the directories itself.
  bool? decide(
    String path, {
    bool isDirectory = false,
    bool exact = false,
  }) {
    bool? decision;
    for (final pattern in patterns) {
      if (pattern.base.isNotEmpty && !path.startsWith('${pattern.base}/')) {
        continue;
      }
      final relative = pattern.base.isEmpty
          ? path
          : path.substring(pattern.base.length + 1);
      if (pattern.directoryOnly && !isDirectory) continue;
      final matcher = exact ? pattern.exactMatcher : pattern.matcher;
      if (matcher.hasMatch(relative)) decision = !pattern.negated;
    }
    return decision;
  }

  /// True when [path] or any directory above it is ignored. A file inside an
  /// ignored directory is ignored without being matched itself, which is why
  /// this is not the same question as [isIgnored].
  bool isIgnoredWithin(String path) {
    if (isIgnored(path)) return true;
    final segments = path.split('/');
    for (var i = 1; i < segments.length; i++) {
      if (isIgnored(segments.take(i).join('/'), isDirectory: true)) return true;
    }
    return false;
  }

  static IgnorePattern? _compile(String line, String base) {
    var text = line;
    if (text.trimLeft().startsWith('#')) return null;
    // Trailing whitespace is not part of a pattern unless it was escaped.
    text = text.replaceAll(RegExp(r'(?<!\\)\s+$'), '');
    if (text.isEmpty) return null;

    var negated = false;
    if (text.startsWith('!')) {
      negated = true;
      text = text.substring(1);
    }
    if (text.startsWith(r'\')) text = text.substring(1);
    if (text.isEmpty) return null;

    var directoryOnly = false;
    if (text.endsWith('/')) {
      directoryOnly = true;
      text = text.substring(0, text.length - 1);
    }

    // A pattern with a slash anywhere but at the end is anchored to its own
    // directory; one without matches a name at any depth.
    final anchored = text.contains('/');
    if (text.startsWith('/')) text = text.substring(1);

    final body = (anchored ? '^' : r'^(.*/)?') + _translate(text);

    return IgnorePattern(
      matcher: RegExp('$body(/.*)?\$'),
      exactMatcher: RegExp('$body\$'),
      negated: negated,
      directoryOnly: directoryOnly,
      base: base,
      source: line,
    );
  }

  static String _translate(String glob) {
    final out = StringBuffer();
    var i = 0;
    while (i < glob.length) {
      final c = glob[i];
      switch (c) {
        case '*':
          if (i + 1 < glob.length && glob[i + 1] == '*') {
            // `**` crosses directory boundaries; a single `*` does not.
            i += 2;
            if (i < glob.length && glob[i] == '/') {
              out.write('(.*/)?');
              i += 1;
            } else {
              out.write('.*');
            }
            continue;
          }
          out.write('[^/]*');
        case '?':
          out.write('[^/]');
        case '[':
          final close = glob.indexOf(']', i + 1);
          if (close < 0) {
            out.write(r'\[');
          } else {
            var set = glob.substring(i + 1, close);
            if (set.startsWith('!')) set = '^${set.substring(1)}';
            out.write('[$set]');
            i = close;
          }
        default:
          out.write(RegExp.escape(c));
      }
      i += 1;
    }
    return out.toString();
  }
}

/// The rules for a working tree, in git's own order of precedence: the user's
/// global excludes, then `.git/info/exclude`, then the `.gitignore` at the
/// root — and, as the walk descends, the one in each directory.
///
/// The global file is read because not reading it makes this library disagree
/// with `git status` on the machine it is running on, which is worse than the
/// alternative it was avoiding: the same repository reporting different
/// untracked files for different users. That is git's behaviour, and it is
/// the user's setting to have made. Pass [includeGlobal] false to get the
/// repository's own rules alone.
IgnoreRules loadIgnoreRules(
  String workTree,
  String gitDirectory, {
  bool includeGlobal = true,
  GitConfig? config,
}) {
  final rules = IgnoreRules();

  if (includeGlobal) {
    final settings = config ?? GitConfig.forRepository(gitDirectory);
    final configured = settings['core.excludesfile'];
    if (configured != null && configured.isNotEmpty) {
      rules.addFile(GitConfig.expandHome(configured));
    } else {
      for (final path in _defaultGlobalExcludePaths) {
        rules.addFile(path);
      }
    }
  }

  return rules
    ..addFile(p.join(gitDirectory, 'info', 'exclude'))
    ..addFile(p.join(workTree, '.gitignore'));
}

/// Where git looks when `core.excludesFile` is unset.
List<String> get _defaultGlobalExcludePaths {
  final home =
      environment['HOME'] ?? environment['USERPROFILE'];
  if (home == null) return const [];
  final xdg = environment['XDG_CONFIG_HOME'];
  return [
    if (xdg != null) p.join(xdg, 'git', 'ignore'),
    p.join(home, '.config', 'git', 'ignore'),
  ];
}
