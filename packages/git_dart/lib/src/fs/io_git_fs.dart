import 'dart:io' as io;
import 'dart:typed_data';

import 'git_fs.dart';

/// The filesystem of the machine git_dart is running on.
///
/// Every method is a thin pass through to `dart:io`, with failures translated
/// into [GitFsException] so callers do not have to know which backend they
/// have. This is the default everywhere except the web.
class IoGitFs implements GitFs {
  const IoGitFs();

  @override
  GitFsFile file(String path) => _IoFile(io.File(path));

  @override
  GitFsDirectory directory(String path) => _IoDirectory(io.Directory(path));

  @override
  GitFsLink link(String path) => _IoLink(io.Link(path));
}

/// Runs [operation], reporting a `dart:io` failure as a [GitFsException].
T _translate<T>(String path, T Function() operation) {
  try {
    return operation();
  } on io.FileSystemException catch (error) {
    throw GitFsException(
      error.osError?.message ?? error.message,
      error.path ?? path,
    );
  }
}

GitFsEntity _wrap(io.FileSystemEntity entity) => switch (entity) {
      io.File() => _IoFile(entity),
      io.Directory() => _IoDirectory(entity),
      io.Link() => _IoLink(entity),
      // `dart:io` has no other kinds, but the switch has to be total. Treating an
      // unknown kind as a file matches what git does with anything it cannot
      // recognise: read it and let the read fail.
      _ => _IoFile(io.File(entity.path)),
    };

class _IoFile implements GitFsFile {
  _IoFile(this._file);

  final io.File _file;

  @override
  String get path => _file.path;

  @override
  GitFsDirectory get parent => _IoDirectory(_file.parent);

  @override
  bool existsSync() => _file.existsSync();

  @override
  void deleteSync({bool recursive = false}) =>
      _translate(path, () => _file.deleteSync(recursive: recursive));

  @override
  void renameSync(String newPath) =>
      _translate(path, () => _file.renameSync(newPath));

  @override
  int lengthSync() => _translate(path, _file.lengthSync);

  @override
  DateTime lastModifiedSync() => _translate(path, _file.lastModifiedSync);

  @override
  GitFsStat statSync() {
    final stat = _file.statSync();
    return GitFsStat(modified: stat.modified, size: stat.size);
  }

  @override
  Uint8List readAsBytesSync() => _translate(path, _file.readAsBytesSync);

  @override
  String readAsStringSync() => _translate(path, _file.readAsStringSync);

  @override
  List<String> readAsLinesSync() => _translate(path, _file.readAsLinesSync);

  @override
  void writeAsBytesSync(List<int> bytes, {bool flush = false}) =>
      _translate(path, () => _file.writeAsBytesSync(bytes, flush: flush));

  @override
  void writeAsStringSync(
    String contents, {
    bool append = false,
    bool flush = false,
  }) =>
      _translate(
        path,
        () => _file.writeAsStringSync(
          contents,
          mode: append ? io.FileMode.append : io.FileMode.write,
          flush: flush,
        ),
      );

  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      _translate(
        path,
        () => _file.createSync(recursive: recursive, exclusive: exclusive),
      );

  @override
  GitFsHandle openSync() => _IoHandle(_translate(path, _file.openSync));

  @override
  GitFsSink openWrite() => _IoSink(_file.openWrite());
}

class _IoDirectory implements GitFsDirectory {
  _IoDirectory(this._directory);

  final io.Directory _directory;

  @override
  String get path => _directory.path;

  @override
  GitFsDirectory get parent => _IoDirectory(_directory.parent);

  @override
  bool existsSync() => _directory.existsSync();

  @override
  void deleteSync({bool recursive = false}) =>
      _translate(path, () => _directory.deleteSync(recursive: recursive));

  @override
  void renameSync(String newPath) =>
      _translate(path, () => _directory.renameSync(newPath));

  @override
  void createSync({bool recursive = false}) =>
      _translate(path, () => _directory.createSync(recursive: recursive));

  @override
  List<GitFsEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) =>
      _translate(
        path,
        () => _directory
            .listSync(recursive: recursive, followLinks: followLinks)
            .map(_wrap)
            .toList(),
      );
}

class _IoLink implements GitFsLink {
  _IoLink(this._link);

  final io.Link _link;

  @override
  String get path => _link.path;

  @override
  GitFsDirectory get parent => _IoDirectory(_link.parent);

  @override
  bool existsSync() => _link.existsSync();

  @override
  void deleteSync({bool recursive = false}) =>
      _translate(path, () => _link.deleteSync(recursive: recursive));

  @override
  void renameSync(String newPath) =>
      _translate(path, () => _link.renameSync(newPath));

  @override
  void createSync(String target, {bool recursive = false}) =>
      _translate(path, () => _link.createSync(target, recursive: recursive));

  @override
  String targetSync() => _translate(path, _link.targetSync);
}

class _IoHandle implements GitFsHandle {
  _IoHandle(this._handle);

  final io.RandomAccessFile _handle;

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) =>
      _translate(_handle.path, () => _handle.readIntoSync(buffer, start, end));

  @override
  void setPositionSync(int position) =>
      _translate(_handle.path, () => _handle.setPositionSync(position));

  @override
  void closeSync() => _handle.closeSync();
}

class _IoSink implements GitFsSink {
  _IoSink(this._sink);

  final io.IOSink _sink;

  @override
  void add(List<int> bytes) => _sink.add(bytes);

  @override
  Future<void> close() => _sink.close();
}
