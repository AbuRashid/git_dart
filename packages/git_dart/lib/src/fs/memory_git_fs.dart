/// A filesystem held entirely in memory.
///
/// Two jobs. It is the storage a platform with no filesystem can hand to
/// git_dart — the web, where a repository is loaded out of OPFS at open and
/// written back on change, with everything in between served from here. And it
/// is the only way to test the [GitFs] seam itself: a backend that is not
/// `dart:io` can be exercised on the VM, against the same repositories real git
/// builds, so the web path is proven before a browser is involved.
///
/// Paths are normalised on the way in. The rest of the package joins paths with
/// `package:path`, which spells them with backslashes on Windows and forward
/// slashes elsewhere, and the same repository has to be readable either way —
/// so a separator is a separator here, and `.` and `..` are resolved rather
/// than stored.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'git_fs.dart';

/// An in-memory [GitFs].
///
/// Nothing is shared between instances: two of these are two filesystems.
class MemoryGitFs implements GitFs {
  /// Every path that exists, by its normalised form.
  final Map<String, _Node> _nodes = {'': const _Directory()};

  /// Paths written since the last [markClean].
  final Set<String> _written = {};

  /// Paths removed since the last [markClean].
  final Set<String> _deleted = {};

  MemoryGitFs();

  /// What has been written since [markClean], and what has been removed.
  ///
  /// Persisting a repository means copying it somewhere slow — OPFS, across a
  /// worker — and a repository holds thousands of loose objects that did not
  /// change. Writing all of them back after every commit would make the cost of
  /// saving proportional to the size of the repository rather than to the size
  /// of the change.
  Set<String> get changedPaths => Set.unmodifiable(_written);
  Set<String> get deletedPaths => Set.unmodifiable(_deleted);

  bool get hasChanges => _written.isNotEmpty || _deleted.isNotEmpty;

  /// Forgets the change log, after persisting what it named.
  void markClean() {
    _written.clear();
    _deleted.clear();
  }

  /// Records a write. A path written after being deleted is written, not both.
  void _put(String path, _Node node) {
    _nodes[path] = node;
    _deleted.remove(path);
    _written.add(path);
  }

  /// Records a removal. A path removed after being written this round never
  /// reached the store it is being compared against, so it is neither.
  void _drop(String path) {
    _nodes.remove(path);
    if (!_written.remove(path)) _deleted.add(path);
  }

  /// A filesystem holding [files], creating the directories they need.
  ///
  /// The shape a caller has after reading a repository out of OPFS, or out of
  /// a zip, or off a server.
  factory MemoryGitFs.of(Map<String, List<int>> files) {
    final result = MemoryGitFs();
    files.forEach((path, bytes) {
      final normalised = _normalise(path);
      result._makeDirectories(_dirname(normalised));
      result._nodes[normalised] = _File(
        Uint8List.fromList(bytes),
        DateTime.now(),
      );
    });
    // Loaded rather than written: nothing here is a change against the store
    // it came from.
    result.markClean();
    return result;
  }

  /// Every file in the filesystem, by path — what to write back to OPFS.
  Map<String, Uint8List> get files => {
        for (final entry in _nodes.entries)
          if (entry.value case final _File file) entry.key: file.bytes,
      };

  /// Every directory in the filesystem.
  ///
  /// Needed when writing back: `git gc` leaves `.git/refs` empty, and a store
  /// rebuilt only from the files it holds would not have it — which stops the
  /// result from looking like a repository at all.
  List<String> get directories => [
        for (final entry in _nodes.entries)
          if (entry.value is _Directory && entry.key.isNotEmpty) entry.key,
      ]..sort();

  /// How many bytes of file content are held, for a caller deciding whether a
  /// repository is small enough to keep this way.
  int get byteCount => _nodes.values
      .whereType<_File>()
      .fold(0, (total, file) => total + file.bytes.length);

  @override
  GitFsFile file(String path) => _FileRef(this, _normalise(path));

  @override
  GitFsDirectory directory(String path) => _DirectoryRef(this, _normalise(path));

  @override
  GitFsLink link(String path) => _LinkRef(this, _normalise(path));

  // ---- the store ----------------------------------------------------------

  void _makeDirectories(String path) {
    if (path.isEmpty) return;
    final segments = path.split('/');
    for (var i = 1; i <= segments.length; i++) {
      final at = segments.take(i).join('/');
      final existing = _nodes[at];
      if (existing is _File) {
        throw GitFsException('a file is in the way of a directory', at);
      }
      if (_nodes[at] == null) _put(at, const _Directory());
    }
  }

  /// The paths directly inside [path], or everything beneath it.
  List<String> _childrenOf(String path, {required bool recursive}) {
    final prefix = path.isEmpty ? '' : '$path/';
    final out = <String>[];
    for (final candidate in _nodes.keys) {
      if (candidate.isEmpty || !candidate.startsWith(prefix)) continue;
      if (candidate == path) continue;
      final rest = candidate.substring(prefix.length);
      if (rest.isEmpty) continue;
      if (!recursive && rest.contains('/')) continue;
      out.add(candidate);
    }
    out.sort();
    return out;
  }

  void _remove(String path, {required bool recursive}) {
    final node = _nodes[path];
    if (node == null) {
      throw GitFsException('nothing to delete', path);
    }
    if (node is _Directory) {
      final children = _childrenOf(path, recursive: true);
      if (children.isNotEmpty && !recursive) {
        throw GitFsException('the directory is not empty', path);
      }
      for (final child in children) {
        _drop(child);
      }
    }
    _drop(path);
  }

  void _rename(String from, String to) {
    final node = _nodes[from];
    if (node == null) throw GitFsException('nothing to rename', from);

    _makeDirectories(_dirname(to));

    // Replacing whatever is at the destination is the contract, and it is what
    // every atomic write in the package depends on: a temporary file is
    // written, then renamed over the real one.
    if (_nodes[to] != null) _remove(to, recursive: true);

    if (node is _Directory) {
      for (final child in _childrenOf(from, recursive: true)) {
        final moved = _nodes[child]!;
        _drop(child);
        _put('$to${child.substring(from.length)}', moved);
      }
    }
    _drop(from);
    _put(to, node);
  }
}

// ---- path handling ---------------------------------------------------------

/// A path as this filesystem stores it: forward slashes, no `.` or `..`, no
/// trailing slash, and no leading one.
///
/// The leading separator goes because a path here is a key rather than a
/// location: what matters is that the same file is spelled the same way each
/// time, whichever style the caller joined it in.
String _normalise(String path) {
  final segments = <String>[];
  for (final segment in path.replaceAll(r'\', '/').split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return segments.join('/');
}

String _dirname(String normalised) {
  final slash = normalised.lastIndexOf('/');
  return slash < 0 ? '' : normalised.substring(0, slash);
}

// ---- nodes -----------------------------------------------------------------

sealed class _Node {
  const _Node();
}

class _Directory extends _Node {
  const _Directory();
}

class _File extends _Node {
  _File(this.bytes, this.modified);
  Uint8List bytes;
  DateTime modified;
}

class _Link extends _Node {
  _Link(this.target);
  String target;
}

// ---- entities --------------------------------------------------------------

abstract class _Ref implements GitFsEntity {
  _Ref(this.owner, this.path);

  final MemoryGitFs owner;

  @override
  final String path;

  @override
  GitFsDirectory get parent => _DirectoryRef(owner, _dirname(path));

  @override
  void deleteSync({bool recursive = false}) =>
      owner._remove(path, recursive: recursive);

  @override
  void renameSync(String newPath) => owner._rename(path, _normalise(newPath));
}

class _FileRef extends _Ref implements GitFsFile {
  _FileRef(super.owner, super.path);

  _File? get _node {
    final node = owner._nodes[path];
    return node is _File ? node : null;
  }

  _File get _required {
    final node = _node;
    if (node == null) throw GitFsException('no such file', path);
    return node;
  }

  @override
  bool existsSync() => _node != null;

  @override
  int lengthSync() => _required.bytes.length;

  @override
  DateTime lastModifiedSync() => _required.modified;

  @override
  GitFsStat statSync() {
    final node = _required;
    return GitFsStat(modified: node.modified, size: node.bytes.length);
  }

  @override
  Uint8List readAsBytesSync() => _required.bytes;

  @override
  String readAsStringSync() =>
      utf8.decode(_required.bytes, allowMalformed: true);

  @override
  List<String> readAsLinesSync() =>
      const LineSplitter().convert(readAsStringSync());

  @override
  void writeAsBytesSync(List<int> bytes, {bool flush = false}) {
    // Parent directories are made rather than demanded. A real filesystem
    // refuses, but every caller in the package creates them first, so being
    // strict here would only reject paths that already work everywhere else.
    owner._makeDirectories(_dirname(path));
    owner._put(path, _File(Uint8List.fromList(bytes), DateTime.now()));
  }

  @override
  void writeAsStringSync(
    String contents, {
    bool append = false,
    bool flush = false,
  }) {
    final incoming = utf8.encode(contents);
    if (!append) {
      writeAsBytesSync(incoming);
      return;
    }
    // Appending in one operation, because that is how a reflog grows and a
    // read-then-write would lose a line to anything writing between the two.
    final existing = _node?.bytes ?? Uint8List(0);
    writeAsBytesSync(<int>[...existing, ...incoming]);
  }

  @override
  void createSync({bool recursive = false, bool exclusive = false}) {
    if (exclusive && owner._nodes.containsKey(path)) {
      // This is how a ref lock is taken: the test and the create are one
      // operation, or two writers both believe they hold it.
      throw GitFsException('the file already exists', path);
    }
    if (recursive) owner._makeDirectories(_dirname(path));
    if (_node != null) return;
    if (!recursive && !owner._nodes.containsKey(_dirname(path))) {
      owner._makeDirectories(_dirname(path));
    }
    owner._put(path, _File(Uint8List(0), DateTime.now()));
  }

  @override
  GitFsHandle openSync() => _Handle(_required.bytes);

  @override
  GitFsSink openWrite() => _Sink(this);
}

class _DirectoryRef extends _Ref implements GitFsDirectory {
  _DirectoryRef(super.owner, super.path);

  @override
  bool existsSync() =>
      path.isEmpty || owner._nodes[path] is _Directory;

  @override
  void createSync({bool recursive = false}) {
    if (owner._nodes[path] is _File) {
      throw GitFsException('a file is in the way of a directory', path);
    }
    owner._makeDirectories(path);
  }

  @override
  List<GitFsEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) {
    if (!existsSync()) throw GitFsException('no such directory', path);
    return [
      for (final child in owner._childrenOf(path, recursive: recursive))
        switch (owner._nodes[child]) {
          _Directory() => _DirectoryRef(owner, child),
          _Link() => _LinkRef(owner, child),
          _ => _FileRef(owner, child),
        },
    ];
  }
}

class _LinkRef extends _Ref implements GitFsLink {
  _LinkRef(super.owner, super.path);

  @override
  bool existsSync() => owner._nodes[path] is _Link;

  @override
  void createSync(String target, {bool recursive = false}) {
    if (recursive) owner._makeDirectories(_dirname(path));
    owner._put(path, _Link(target));
  }

  @override
  String targetSync() {
    final node = owner._nodes[path];
    if (node is! _Link) throw GitFsException('not a link', path);
    return node.target;
  }
}

/// Reading a file at arbitrary offsets, which is how packs are read.
class _Handle implements GitFsHandle {
  _Handle(this._bytes);

  final Uint8List _bytes;
  var _position = 0;

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    final limit = end ?? buffer.length;
    final count = (limit - start).clamp(0, _bytes.length - _position);
    for (var i = 0; i < count; i++) {
      buffer[start + i] = _bytes[_position + i];
    }
    _position += count;
    return count;
  }

  @override
  void setPositionSync(int position) => _position = position;

  @override
  void closeSync() {}
}

/// Appending a stream of bytes, which is how an incoming pack is stored.
class _Sink implements GitFsSink {
  _Sink(this._file) {
    _file.writeAsBytesSync(const []);
  }

  final _FileRef _file;
  final _builder = BytesBuilder();

  @override
  void add(List<int> bytes) => _builder.add(bytes);

  @override
  Future<void> close() async {
    _file.writeAsBytesSync(_builder.takeBytes());
  }
}
