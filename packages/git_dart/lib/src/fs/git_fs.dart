import 'dart:typed_data';

import 'default_fs_io.dart' if (dart.library.js_interop) 'default_fs_web.dart'
    as defaults;

/// The filesystem every path in git_dart is read and written through.
///
/// The package used `dart:io` directly until this seam existed. Going through
/// an interface instead lets a platform that has no filesystem of its own —
/// the web, where what is on offer is OPFS behind a worker — supply the
/// storage without the rest of the package knowing which it got.
///
/// The operations are deliberately synchronous, mirroring the `dart:io` API
/// they replace. Git's formats are read by seeking around pack files and
/// stat-ing loose paths, so the call sites are synchronous all the way up;
/// making them asynchronous would reach every caller as far as the UI. OPFS
/// can meet this: `FileSystemSyncAccessHandle` reads and writes synchronously,
/// and the operations that it only offers asynchronously — looking a name up,
/// listing, deleting — are the ones a backend can serve from an index it built
/// when the repository was opened.
abstract interface class GitFs {
  /// The file at [path]. Nothing is read or created until it is used.
  GitFsFile file(String path);

  /// The directory at [path]. Nothing is read or created until it is used.
  GitFsDirectory directory(String path);

  /// The symbolic link at [path].
  GitFsLink link(String path);
}

/// What a file, directory and link have in common.
abstract interface class GitFsEntity {
  /// The path this entity was named by.
  String get path;

  /// The directory holding this entity.
  GitFsDirectory get parent;

  bool existsSync();

  void deleteSync({bool recursive = false});

  /// Moves this entity to [newPath], replacing whatever is there.
  void renameSync(String newPath);
}

abstract interface class GitFsFile implements GitFsEntity {
  int lengthSync();

  DateTime lastModifiedSync();

  /// The modification time and size, read together.
  ///
  /// git compares both against what the index recorded, and reading them in
  /// one call is the difference between one round trip and two — which matters
  /// on a backend where each call is expensive.
  GitFsStat statSync();

  Uint8List readAsBytesSync();

  String readAsStringSync();

  List<String> readAsLinesSync();

  void writeAsBytesSync(List<int> bytes, {bool flush = false});

  /// Writes [contents], appending to what is already there when [append].
  ///
  /// Appending is how reflogs grow, and it has to be a flag rather than a
  /// separate open-and-seek so a backend can do it in one operation.
  void writeAsStringSync(
    String contents, {
    bool append = false,
    bool flush = false,
  });

  /// Creates the file, failing when [exclusive] and it already exists.
  ///
  /// Exclusive creation is not a convenience: it is how git takes a lock. The
  /// create and the test for existence have to be one operation, or two writers
  /// both find the lock absent and both think they hold it. A backend that
  /// cannot promise that cannot host a repository safely.
  void createSync({bool recursive = false, bool exclusive = false});

  /// Opens the file for reading at arbitrary offsets.
  GitFsHandle openSync();

  /// Opens the file for writing a stream of bytes to its end.
  GitFsSink openWrite();
}

abstract interface class GitFsDirectory implements GitFsEntity {
  void createSync({bool recursive = false});

  /// The entities directly inside this directory, or beneath it when
  /// [recursive].
  ///
  /// Callers tell files from directories by type, so a backend must return
  /// [GitFsFile] and [GitFsDirectory] rather than something uniform.
  List<GitFsEntity> listSync({bool recursive = false, bool followLinks = true});
}

abstract interface class GitFsLink implements GitFsEntity {
  /// Creates a link pointing at [target].
  ///
  /// Backends that cannot make links should throw [GitFsException]; callers
  /// fall back to writing the target as file content, which is what git itself
  /// does where symlinks are unavailable.
  void createSync(String target, {bool recursive = false});

  /// The path this link points at, as recorded rather than resolved.
  String targetSync();
}

/// A file open for reading at arbitrary offsets.
///
/// This is what pack files are read through: an index lookup gives an offset,
/// and the object is read from there.
abstract interface class GitFsHandle {
  /// Fills [buffer] from [start] to [end] and returns how much was read.
  int readIntoSync(List<int> buffer, [int start = 0, int? end]);

  void setPositionSync(int position);

  void closeSync();
}

/// A file open for appending a stream of bytes, used for incoming packs.
abstract interface class GitFsSink {
  void add(List<int> bytes);

  Future<void> close();
}

/// What git needs to know about a path that is already there.
class GitFsStat {
  const GitFsStat({required this.modified, required this.size});

  final DateTime modified;
  final int size;
}

/// A filesystem operation that did not work.
///
/// Backends translate their own failures into this, so callers can catch one
/// kind of thing whether they are talking to `dart:io` or to OPFS.
class GitFsException implements Exception {
  const GitFsException(this.message, [this.path]);

  final String message;
  final String? path;

  @override
  String toString() => path == null
      ? 'GitFsException: $message'
      : 'GitFsException: $message, path = $path';
}

GitFs _fs = defaults.defaultGitFs();

/// The filesystem in use.
GitFs get fs => _fs;

/// Points git_dart at [value] for every path it reads or writes from now on.
///
/// Call this once, before opening a repository. It exists for platforms that
/// have to supply their own storage; on a platform with a real filesystem the
/// default is already the right answer.
void useGitFileSystem(GitFs value) {
  _fs = value;
}
