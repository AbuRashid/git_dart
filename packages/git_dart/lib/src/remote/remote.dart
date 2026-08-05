import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/git_config.dart';
import '../object_id.dart';

/// A rule mapping refs on one side to refs on the other.
///
/// `+refs/heads/*:refs/remotes/origin/*` — the leading `+` means the update
/// may be forced, the left side is the source and the right the destination.
class RefSpec {
  final bool force;
  final String source;
  final String destination;

  const RefSpec({
    required this.source,
    required this.destination,
    this.force = false,
  });

  factory RefSpec.parse(String text) {
    var rest = text;
    final force = rest.startsWith('+');
    if (force) rest = rest.substring(1);

    final colon = rest.indexOf(':');
    if (colon < 0) {
      return RefSpec(source: rest, destination: '', force: force);
    }
    return RefSpec(
      source: rest.substring(0, colon),
      destination: rest.substring(colon + 1),
      force: force,
    );
  }

  bool get isPattern => source.endsWith('*') && destination.endsWith('*');

  /// Where [ref] lands locally, or null when this spec does not cover it.
  String? map(String ref) {
    if (!isPattern) return ref == source ? destination : null;
    final prefix = source.substring(0, source.length - 1);
    if (!ref.startsWith(prefix)) return null;
    return destination.substring(0, destination.length - 1) +
        ref.substring(prefix.length);
  }

  @override
  String toString() => '${force ? '+' : ''}$source:$destination';
}

/// A named place to fetch from and push to.
class Remote {
  final String name;

  /// Where to fetch from.
  final String url;

  /// Where to push to, when it differs from [url].
  final String pushUrl;

  final List<RefSpec> fetchSpecs;

  const Remote({
    required this.name,
    required this.url,
    String? pushUrl,
    this.fetchSpecs = const [],
  }) : pushUrl = pushUrl ?? url;

  /// The default spec when a remote's config gives none.
  RefSpec get defaultFetchSpec => RefSpec.parse(
        '+refs/heads/*:refs/remotes/$name/*',
      );

  List<RefSpec> get effectiveFetchSpecs =>
      fetchSpecs.isEmpty ? [defaultFetchSpec] : fetchSpecs;

  /// Where a fetched ref is stored locally.
  String? trackingRefFor(String remoteRef) {
    for (final spec in effectiveFetchSpecs) {
      final mapped = spec.map(remoteRef);
      if (mapped != null && mapped.isNotEmpty) return mapped;
    }
    return null;
  }

  /// True when this URL names a directory on this machine rather than a
  /// server. Such a remote can be fetched by reading its object store
  /// directly, with no protocol at all.
  bool get isLocal {
    if (url.startsWith('file://')) return true;
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) return false;
    // `host:path` is scp-style ssh, not a local path — but a Windows drive
    // letter looks the same, so the single-letter case is a path.
    final colon = url.indexOf(':');
    if (colon > 1) return false;
    return true;
  }

  /// The directory this remote names, for a local remote.
  String get localPath {
    if (url.startsWith('file://')) {
      var path = url.substring('file://'.length);
      // file:///C:/x on Windows arrives with a leading slash before the drive.
      if (RegExp(r'^/[a-zA-Z]:').hasMatch(path)) path = path.substring(1);
      return Uri.decodeFull(path);
    }
    return url;
  }

  @override
  String toString() => '$name $url';
}

/// Reads and writes the `[remote "name"]` sections of a repository's config.
///
/// Written directly rather than through a general config writer: these are the
/// only sections this library changes, and a writer that rewrote whole files
/// would reformat a config the user has arranged by hand.
class RemoteStore {
  final String gitDirectory;

  RemoteStore(this.gitDirectory);

  String get _configPath => p.join(gitDirectory, 'config');

  List<Remote> list() {
    final config = GitConfig.forRepository(gitDirectory);
    return [
      for (final name in config.subsections('remote'))
        Remote(
          name: name,
          url: config['remote.$name.url'] ?? '',
          pushUrl: config['remote.$name.pushurl'],
          fetchSpecs: [
            for (final spec in config.all('remote.$name.fetch'))
              RefSpec.parse(spec),
          ],
        ),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  Remote? named(String name) {
    for (final remote in list()) {
      if (remote.name == name) return remote;
    }
    return null;
  }

  /// Adds a remote with git's default fetch refspec.
  void add(String name, String url) {
    if (named(name) != null) {
      throw StateError('a remote named $name already exists');
    }
    _validateName(name);

    final file = File(_configPath);
    final existing = file.existsSync() ? file.readAsStringSync() : '';
    final separator =
        existing.isEmpty || existing.endsWith('\n') ? '' : '\n';

    file.writeAsStringSync(
      '$existing$separator'
      '[remote "$name"]\n'
      '\turl = ${escapeConfigValue(url)}\n'
      '\tfetch = +refs/heads/*:refs/remotes/$name/*\n',
    );
  }

  /// Quotes a value that git would otherwise misread.
  ///
  /// A backslash begins an escape sequence in a config value, so a Windows
  /// path written plainly makes the file unreadable — `git` reports "bad
  /// config line" and refuses the whole repository, which is how this was
  /// found.
  static String escapeConfigValue(String value) {
    if (!value.contains(r'\') &&
        !value.contains('"') &&
        !value.contains('#') &&
        !value.contains(';') &&
        value.trim() == value) {
      return value;
    }
    final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  /// Removes the remote's config section. Its tracking refs are removed too,
  /// since they describe a place this repository no longer knows about.
  void remove(String name) {
    final file = File(_configPath);
    if (!file.existsSync()) return;

    final kept = <String>[];
    var inSection = false;
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) {
        inSection = trimmed.toLowerCase().replaceAll(' ', '') ==
            '[remote"$name"]'.toLowerCase().replaceAll(' ', '');
      }
      if (!inSection) kept.add(line);
    }
    file.writeAsStringSync('${kept.join('\n')}\n');

    final tracking = Directory(p.join(gitDirectory, 'refs', 'remotes', name));
    if (tracking.existsSync()) tracking.deleteSync(recursive: true);
  }

  void rename(String from, String to) {
    final remote = named(from);
    if (remote == null) throw StateError('no remote named $from');
    _validateName(to);
    remove(from);
    add(to, remote.url);
  }

  static void _validateName(String name) {
    if (name.isEmpty || RegExp(r'[\s/\\"\[\]]').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'not a usable remote name');
    }
  }
}

/// How far apart two commits are: what each has that the other does not.
class AheadBehind {
  final int ahead;
  final int behind;

  const AheadBehind(this.ahead, this.behind);

  bool get isEven => ahead == 0 && behind == 0;

  @override
  String toString() => 'ahead $ahead, behind $behind';
}

/// The name a branch tracks, from `branch.<name>.remote` and `.merge`.
({String remote, String ref})? upstreamOf(GitConfig config, String branch) {
  final remote = config['branch.$branch.remote'];
  final merge = config['branch.$branch.merge'];
  if (remote == null || merge == null) return null;
  return (remote: remote, ref: merge);
}

/// A pairing of a local branch with the tracking ref it follows.
class BranchTracking {
  final String branch;
  final ObjectId? localTip;
  final String? upstreamRef;
  final ObjectId? upstreamTip;
  final AheadBehind? divergence;

  const BranchTracking({
    required this.branch,
    this.localTip,
    this.upstreamRef,
    this.upstreamTip,
    this.divergence,
  });
}
