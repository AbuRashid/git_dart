/// OPFS through JavaScript interop.
///
/// Only the handful of calls a store needs, declared here rather than pulled in
/// from `package:web`, so that git_dart keeps its dependencies to compression
/// and paths. The shapes are from the File System Access API: a directory
/// handle hands out child handles by name, a file handle hands out a `File` to
/// read and a writable stream to write.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'memory_archive.dart';
import 'memory_git_fs.dart';

// ---- the interop surface ---------------------------------------------------

@JS('navigator')
external JSObject? get _navigator;

extension type _Navigator._(JSObject _) implements JSObject {
  external _StorageManager? get storage;
}

extension type _StorageManager._(JSObject _) implements JSObject {
  external JSPromise<_DirectoryHandle> getDirectory();
  external JSPromise<JSObject> estimate();
}

extension type _Handle._(JSObject _) implements JSObject {
  /// `'file'` or `'directory'`.
  external String get kind;
  external String get name;
}

extension type _DirectoryHandle._(JSObject _) implements JSObject {
  external JSPromise<_DirectoryHandle> getDirectoryHandle(
    String name, [
    JSObject options,
  ]);
  external JSPromise<_FileHandle> getFileHandle(String name, [JSObject options]);
  external JSPromise<JSAny?> removeEntry(String name, [JSObject options]);

  /// An async iterator over the child handles.
  external _AsyncIterator values();
}

extension type _FileHandle._(JSObject _) implements JSObject {
  external JSPromise<_Blob> getFile();
  external JSPromise<_Writable> createWritable([JSObject options]);
}

extension type _Blob._(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _Writable._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSAny data);
  external JSPromise<JSAny?> close();
}

extension type _AsyncIterator._(JSObject _) implements JSObject {
  external JSPromise<_IterationResult> next();
}

extension type _IterationResult._(JSObject _) implements JSObject {
  external bool get done;
  external JSAny? get value;
}

/// `{create: true}` and friends, which the API takes as a plain object.
JSObject _options(Map<String, bool> values) {
  final object = JSObject();
  values.forEach((key, value) {
    object.setProperty(key.toJS, value.toJS);
  });
  return object;
}

// ---- what the store calls --------------------------------------------------

/// The name a repository is stored under, inside its own directory.
///
/// One file rather than a tree: see [packMemoryFs]. OPFS charges per
/// operation, and a repository has thousands of objects.
const String _archiveName = 'repository.gitfs';

Future<bool> isAvailable() async {
  try {
    final storage = (_navigator as _Navigator?)?.storage;
    if (storage == null) return false;
    // Asking for the directory is the only reliable test: the property can be
    // present and the call still refused, in a context without storage.
    await storage.getDirectory().toDart;
    return true;
  } on Object {
    return false;
  }
}

Future<MemoryGitFs> load(String root, String under) async {
  final bytes = await _readAt(_segments(root) + [_archiveName]);
  if (bytes == null) {
    // Nothing stored yet is not an error: it is an empty repository slot.
    return MemoryGitFs()..markClean();
  }
  return unpackMemoryFs(bytes, under: under);
}

Future<void> save(String root, String under, MemoryGitFs memory) async {
  // The cheapest whole rewrite is the one that is skipped.
  if (!memory.hasChanges) return;
  await saveAll(root, under, memory);
}

Future<void> saveAll(String root, String under, MemoryGitFs memory) async {
  await _writeAt(
    _segments(root) + [_archiveName],
    packMemoryFs(memory, under: under),
  );
  memory.markClean();
}

Future<List<String>> list(String root) async {
  final directory = await _descend(_segments(root), create: false);
  if (directory == null) return const [];

  final names = <String>[];
  final iterator = directory.values();
  while (true) {
    final step = await iterator.next().toDart;
    if (step.done) break;
    final value = step.value;
    if (value == null) break;
    names.add((value as _Handle).name);
  }
  names.sort();
  return names;
}

Future<void> delete(String root) async {
  final segments = _segments(root);
  if (segments.isEmpty) return;
  await _removeAt(segments);
}

Future<({int used, int available})?> usage() async {
  try {
    final storage = (_navigator as _Navigator?)?.storage;
    if (storage == null) return null;
    final estimate = await storage.estimate().toDart;
    final used = (estimate.getProperty('usage'.toJS) as JSNumber?)?.toDartInt;
    final quota = (estimate.getProperty('quota'.toJS) as JSNumber?)?.toDartInt;
    if (used == null || quota == null) return null;
    return (used: used, available: quota - used);
  } on Object {
    return null;
  }
}

// ---- walking ---------------------------------------------------------------

List<String> _segments(String path) => path
    .replaceAll(r'\', '/')
    .split('/')
    .where((segment) => segment.isNotEmpty && segment != '.')
    .toList();

Future<_DirectoryHandle?> _root() async {
  final storage = (_navigator as _Navigator?)?.storage;
  if (storage == null) return null;
  return storage.getDirectory().toDart;
}

/// The directory at [segments], making it when [create].
Future<_DirectoryHandle?> _descend(
  List<String> segments, {
  required bool create,
}) async {
  var handle = await _root();
  if (handle == null) return null;

  for (final segment in segments) {
    try {
      handle = await handle!
          .getDirectoryHandle(segment, _options({'create': create}))
          .toDart;
    } on Object {
      // Absent and not being created, or a file is in the way. Either way
      // there is no directory here to hand back.
      return null;
    }
  }
  return handle;
}

Future<void> _writeAt(List<String> segments, Uint8List bytes) async {
  if (segments.isEmpty) return;
  final directory = await _descend(
    segments.sublist(0, segments.length - 1),
    create: true,
  );
  if (directory == null) {
    throw StateError('could not make ${segments.join('/')} in OPFS');
  }

  final file =
      await directory.getFileHandle(segments.last, _options({'create': true}))
          .toDart;
  final writable = await file.createWritable().toDart;
  // A fresh writable truncates, so this replaces rather than overlays — which
  // matters because git writes a ref by replacing the whole file.
  await writable.write(bytes.toJS).toDart;
  await writable.close().toDart;
}

Future<void> _removeAt(List<String> segments) async {
  if (segments.isEmpty) return;
  final directory = await _descend(
    segments.sublist(0, segments.length - 1),
    create: false,
  );
  if (directory == null) return;

  try {
    await directory
        .removeEntry(segments.last, _options({'recursive': true}))
        .toDart;
  } on Object {
    // Already gone. Deleting what is not there is what was wanted.
  }
}

/// The bytes at [segments], or null when nothing is there.
Future<Uint8List?> _readAt(List<String> segments) async {
  if (segments.isEmpty) return null;
  final directory = await _descend(
    segments.sublist(0, segments.length - 1),
    create: false,
  );
  if (directory == null) return null;

  try {
    final handle = await directory.getFileHandle(segments.last).toDart;
    final blob = await handle.getFile().toDart;
    final buffer = await blob.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  } on Object {
    // Absent, which is what a repository that has never been saved looks like.
    return null;
  }
}
