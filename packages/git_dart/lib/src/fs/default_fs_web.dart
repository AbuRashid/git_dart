import 'dart:typed_data';

import 'git_fs.dart';

/// The filesystem to use on the web, where there is no default worth having.
///
/// A browser has no filesystem `dart:io` can reach: importing it compiles, but
/// the first call throws `Unsupported operation: _Namespace` from somewhere
/// deep in the SDK. Failing here instead says what to do about it.
GitFs defaultGitFs() => const UnconfiguredGitFs();

/// A filesystem that refuses every operation, explaining what is missing.
class UnconfiguredGitFs implements GitFs {
  const UnconfiguredGitFs();

  @override
  GitFsFile file(String path) => _Unconfigured(path);

  @override
  GitFsDirectory directory(String path) => _Unconfigured(path);

  @override
  GitFsLink link(String path) => _UnconfiguredLink(path);
}

Never _fail(String path) => throw GitFsException(
      'This platform has no filesystem of its own. Call useGitFileSystem() with '
      'a backend — OPFS behind a worker, on the web — before opening a repository.',
      path,
    );

/// Files and directories, which fail identically.
class _Unconfigured implements GitFsFile, GitFsDirectory {
  const _Unconfigured(this.path);

  @override
  final String path;

  @override
  GitFsDirectory get parent => _fail(path);

  @override
  bool existsSync() => _fail(path);

  @override
  void deleteSync({bool recursive = false}) => _fail(path);

  @override
  void renameSync(String newPath) => _fail(path);

  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      _fail(path);

  @override
  int lengthSync() => _fail(path);

  @override
  DateTime lastModifiedSync() => _fail(path);

  @override
  GitFsStat statSync() => _fail(path);

  @override
  Uint8List readAsBytesSync() => _fail(path);

  @override
  String readAsStringSync() => _fail(path);

  @override
  List<String> readAsLinesSync() => _fail(path);

  @override
  void writeAsBytesSync(List<int> bytes, {bool flush = false}) => _fail(path);

  @override
  void writeAsStringSync(
    String contents, {
    bool append = false,
    bool flush = false,
  }) =>
      _fail(path);

  @override
  GitFsHandle openSync() => _fail(path);

  @override
  GitFsSink openWrite() => _fail(path);

  @override
  List<GitFsEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) =>
      _fail(path);
}

/// Links, whose creation takes a target and so cannot share the above.
class _UnconfiguredLink implements GitFsLink {
  const _UnconfiguredLink(this.path);

  @override
  final String path;

  @override
  GitFsDirectory get parent => _fail(path);

  @override
  bool existsSync() => _fail(path);

  @override
  void deleteSync({bool recursive = false}) => _fail(path);

  @override
  void renameSync(String newPath) => _fail(path);

  @override
  void createSync(String target, {bool recursive = false}) => _fail(path);

  @override
  String targetSync() => _fail(path);
}
