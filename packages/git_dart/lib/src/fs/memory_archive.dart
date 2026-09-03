/// A whole in-memory filesystem, as one block of bytes.
///
/// Written for the browser. OPFS charges per *operation*, and the expensive one
/// — `createWritable` — makes a swap file and copies it into place on close;
/// the cheap synchronous path exists only inside a Web Worker. A repository has
/// thousands of loose objects, so storing it as a directory tree means
/// thousands of those operations to save and as many to load.
///
/// Keeping it as a single file makes both one operation. The cost is that a
/// save rewrites everything rather than just what changed, which for a
/// repository of a few megabytes is far the better trade — and is why
/// [MemoryGitFs.hasChanges] is still worth consulting: the cheapest whole
/// rewrite is the one that is skipped.
///
/// The format is deliberately dull, because it is only ever read by the code
/// that wrote it:
///
/// ```
/// "GITDARTFS\x01"        magic and version
/// uint32                 how many entries
/// per entry:
///   uint8                0 for a directory, 1 for a file
///   uint32               length of the path in bytes
///   bytes                the path, UTF-8, '/'-separated
///   uint32               length of the content (0 for a directory)
///   bytes                the content
/// ```
///
/// Directories are recorded in their own right rather than implied by the
/// files inside them. An empty one is not a curiosity here: `git gc` packs
/// every ref away and leaves `.git/refs` with nothing in it, and a filesystem
/// rebuilt without it stops looking like a repository at all.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'memory_git_fs.dart';

const List<int> _magic = [0x47, 0x49, 0x54, 0x44, 0x41, 0x52, 0x54, 0x46, 0x53];
const int _version = 1;

class MemoryArchiveException implements Exception {
  final String message;
  const MemoryArchiveException(this.message);
  @override
  String toString() => 'MemoryArchiveException: $message';
}

/// Packs [memory] into one buffer.
///
/// [under] is stripped from the front of every path, so what comes out is
/// portable: the same repository can be unpacked at whatever path the platform
/// it lands on wants to call it. Anything outside [under] is left out, since it
/// is not part of the repository being stored.
Uint8List packMemoryFs(MemoryGitFs memory, {String under = ''}) {
  final base = _normalise(under);

  final entries = <({bool isFile, String path, Uint8List content})>[];

  for (final path in memory.directories) {
    final relative = _relativeTo(base, path);
    if (relative == null || relative.isEmpty) continue;
    entries.add((isFile: false, path: relative, content: Uint8List(0)));
  }
  memory.files.forEach((path, content) {
    final relative = _relativeTo(base, path);
    if (relative == null || relative.isEmpty) return;
    entries.add((isFile: true, path: relative, content: content));
  });

  // Sorted so the same filesystem packs to the same bytes twice, which is what
  // lets a caller tell whether anything actually changed.
  entries.sort((a, b) => a.path.compareTo(b.path));

  final out = BytesBuilder();
  out.add(_magic);
  out.addByte(_version);
  out.add(_uint32(entries.length));

  for (final entry in entries) {
    final path = utf8.encode(entry.path);
    out.addByte(entry.isFile ? 1 : 0);
    out.add(_uint32(path.length));
    out.add(path);
    out.add(_uint32(entry.content.length));
    out.add(entry.content);
  }

  return out.takeBytes();
}

/// Rebuilds a filesystem from [bytes], with every path under [under].
///
/// The result is marked clean: it is exactly what the store holds, so none of
/// it needs writing back.
MemoryGitFs unpackMemoryFs(Uint8List bytes, {String under = ''}) {
  final memory = MemoryGitFs();
  final base = _normalise(under);

  if (bytes.length < _magic.length + 5) {
    throw const MemoryArchiveException('too short to be an archive');
  }
  for (var i = 0; i < _magic.length; i++) {
    if (bytes[i] != _magic[i]) {
      throw const MemoryArchiveException('not an archive');
    }
  }
  final version = bytes[_magic.length];
  if (version != _version) {
    throw MemoryArchiveException('unknown archive version $version');
  }

  final view = ByteData.sublistView(bytes);
  var at = _magic.length + 1;

  int readUint32() {
    if (at + 4 > bytes.length) {
      throw const MemoryArchiveException('the archive ends mid-number');
    }
    final value = view.getUint32(at);
    at += 4;
    return value;
  }

  final count = readUint32();

  for (var i = 0; i < count; i++) {
    if (at >= bytes.length) {
      throw MemoryArchiveException(
        'the archive ends after $i of $count entries',
      );
    }
    final isFile = bytes[at] == 1;
    at += 1;

    final pathLength = readUint32();
    if (at + pathLength > bytes.length) {
      throw const MemoryArchiveException('the archive ends mid-path');
    }
    final path = utf8.decode(
      bytes.sublist(at, at + pathLength),
      allowMalformed: true,
    );
    at += pathLength;

    final contentLength = readUint32();
    if (at + contentLength > bytes.length) {
      throw const MemoryArchiveException('the archive ends mid-file');
    }

    final full = base.isEmpty ? path : '$base/$path';
    if (isFile) {
      memory
          .file(full)
          .writeAsBytesSync(Uint8List.sublistView(bytes, at, at + contentLength));
    } else {
      memory.directory(full).createSync(recursive: true);
    }
    at += contentLength;
  }

  memory.markClean();
  return memory;
}

Uint8List _uint32(int value) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setUint32(0, value);
  return out;
}

String _normalise(String path) => path
    .replaceAll(r'\', '/')
    .split('/')
    .where((segment) => segment.isNotEmpty && segment != '.')
    .join('/');

String? _relativeTo(String base, String path) {
  if (base.isEmpty) return path;
  if (path == base) return '';
  if (!path.startsWith('$base/')) return null;
  return path.substring(base.length + 1);
}
