import 'dart:convert';
// Inflating a packed object still uses dart:io's zlib: it is the only streaming
// inflater in the SDK. A web backend will need another one.
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../platform/compress.dart';
import '../object_id.dart';
import '../objects/git_object.dart';
import 'pack_index.dart';

/// The type field of a packed object's header. The four object kinds keep
/// their usual meaning; 5 was never assigned and the two delta types are
/// storage, not kinds — they name how an object is written, not what it is.
enum _PackedType {
  none(0),
  commit(1),
  tree(2),
  blob(3),
  tag(4),
  reserved(5),
  offsetDelta(6),
  referenceDelta(7);

  const _PackedType(this.code);
  final int code;

  static _PackedType byCode(int code) => _PackedType.values[code];

  ObjectKind? get kind => switch (this) {
        commit => ObjectKind.commit,
        tree => ObjectKind.tree,
        blob => ObjectKind.blob,
        tag => ObjectKind.tag,
        _ => null,
      };
}

/// One packfile and its index.
///
/// Objects are located through the index rather than by scanning, so the
/// reader never needs to know where a compressed stream ends — which is the
/// one thing a packfile does not record.
class PackFile {
  final String packPath;
  final PackIndex index;

  final GitFsHandle _file;
  final int _fileLength;

  /// Materialised objects, keyed by their offset in the pack. A delta chain
  /// asks for the same base repeatedly, and re-inflating it each time turns a
  /// linear read into a quadratic one.
  final _cache = <int, ({ObjectKind kind, Uint8List content})>{};
  static const _cacheLimit = 256;

  PackFile._(this.packPath, this.index, this._file, this._fileLength);

  /// Opens `<base>.pack` alongside `<base>.idx`.
  factory PackFile.open(String packPath) {
    final indexPath = '${p.withoutExtension(packPath)}.idx';
    final index = PackIndex.open(indexPath);
    final file = fs.file(packPath);
    final handle = file.openSync();
    final pack = PackFile._(packPath, index, handle, file.lengthSync());
    pack._verifyHeader();
    return pack;
  }

  void _verifyHeader() {
    final header = _readAt(0, 12);
    if (String.fromCharCodes(header.sublist(0, 4)) != 'PACK') {
      throw FormatException('$packPath does not begin with PACK');
    }
    final data = ByteData.sublistView(header);
    final version = data.getUint32(4);
    if (version != 2 && version != 3) {
      throw FormatException('unsupported pack version $version');
    }
  }

  int get objectCount => ByteData.sublistView(_readAt(8, 4)).getUint32(0);

  bool contains(ObjectId id) => index.contains(id);

  Iterable<ObjectId> listAll() => index.listAll();

  void close() => _file.closeSync();

  /// Reads the object named [id], resolving any delta chain, or null if this
  /// pack does not hold it.
  ({ObjectKind kind, Uint8List content})? read(ObjectId id) {
    final offset = index.offsetOf(id);
    if (offset == null) return null;
    return readAtOffset(offset);
  }

  ({ObjectKind kind, Uint8List content}) readAtOffset(int offset) {
    final cached = _cache[offset];
    if (cached != null) return cached;

    final header = _readObjectHeader(offset);
    final result = switch (header.type) {
      _PackedType.offsetDelta => _applyDelta(
          base: readAtOffset(header.baseOffset!),
          delta: _inflateAt(header.dataOffset, header.size),
        ),
      _PackedType.referenceDelta => _applyDelta(
          base: _readBaseByName(header.baseName!),
          delta: _inflateAt(header.dataOffset, header.size),
        ),
      _ => (
          kind: header.type.kind ??
              (throw FormatException(
                'reserved pack object type ${header.type.code} at $offset',
              )),
          content: _inflateAt(header.dataOffset, header.size),
        ),
    };

    if (_cache.length >= _cacheLimit) _cache.clear();
    _cache[offset] = result;
    return result;
  }

  /// Resolves a `ref-delta` base. The base may be outside this pack, which is
  /// why an ObjectStore hands the pack a resolver rather than the pack
  /// searching on its own.
  ({ObjectKind kind, Uint8List content}) Function(ObjectId id)? externalBase;

  ({ObjectKind kind, Uint8List content}) _readBaseByName(ObjectId name) {
    final inThisPack = read(name);
    if (inThisPack != null) return inThisPack;
    final resolve = externalBase;
    if (resolve == null) {
      throw FormatException(
        'delta base $name is outside $packPath and no resolver was given',
      );
    }
    return resolve(name);
  }

  // ---- header -------------------------------------------------------------

  ({
    _PackedType type,
    int size,
    int dataOffset,
    int? baseOffset,
    ObjectId? baseName,
  }) _readObjectHeader(int offset) {
    // Enough for the size varint, an offset varint and a 20-byte base name.
    final window = _readAt(offset, _min(64, _fileLength - offset));
    var at = 0;

    var byte = window[at++];
    final type = _PackedType.byCode((byte >> 4) & 0x07);
    var size = byte & 0x0f;
    var shift = 4;
    while (byte & 0x80 != 0) {
      byte = window[at++];
      size |= (byte & 0x7f) << shift;
      shift += 7;
    }

    int? baseOffset;
    ObjectId? baseName;

    if (type == _PackedType.offsetDelta) {
      // A different varint from the one above: big-endian, and each further
      // byte adds one before shifting, so no encoding is ever ambiguous.
      byte = window[at++];
      var distance = byte & 0x7f;
      while (byte & 0x80 != 0) {
        byte = window[at++];
        distance = ((distance + 1) << 7) | (byte & 0x7f);
      }
      baseOffset = offset - distance;
      if (baseOffset < 0) {
        throw FormatException('delta at $offset points before the pack');
      }
    } else if (type == _PackedType.referenceDelta) {
      baseName = ObjectId.fromBytes(window, at);
      at += ObjectId.byteLength;
    }

    return (
      type: type,
      size: size,
      dataOffset: offset + at,
      baseOffset: baseOffset,
      baseName: baseName,
    );
  }

  // ---- delta --------------------------------------------------------------

  ({ObjectKind kind, Uint8List content}) _applyDelta({
    required ({ObjectKind kind, Uint8List content}) base,
    required Uint8List delta,
  }) {
    var at = 0;
    int varint() {
      var value = 0;
      var shift = 0;
      int byte;
      do {
        byte = delta[at++];
        value |= (byte & 0x7f) << shift;
        shift += 7;
      } while (byte & 0x80 != 0);
      return value;
    }

    final sourceSize = varint();
    final targetSize = varint();
    if (sourceSize != base.content.length) {
      throw FormatException(
        'delta expects a base of $sourceSize bytes, base is '
        '${base.content.length}',
      );
    }

    final out = Uint8List(targetSize);
    var written = 0;

    while (at < delta.length) {
      final instruction = delta[at++];
      if (instruction & 0x80 != 0) {
        // Copy from the base: the low seven bits say which offset and size
        // bytes follow, so unchanged high bytes cost nothing.
        var copyOffset = 0;
        var copySize = 0;
        if (instruction & 0x01 != 0) copyOffset |= delta[at++];
        if (instruction & 0x02 != 0) copyOffset |= delta[at++] << 8;
        if (instruction & 0x04 != 0) copyOffset |= delta[at++] << 16;
        if (instruction & 0x08 != 0) copyOffset |= delta[at++] << 24;
        if (instruction & 0x10 != 0) copySize |= delta[at++];
        if (instruction & 0x20 != 0) copySize |= delta[at++] << 8;
        if (instruction & 0x40 != 0) copySize |= delta[at++] << 16;
        if (copySize == 0) copySize = 0x10000;

        out.setRange(
          written,
          written + copySize,
          base.content,
          copyOffset,
        );
        written += copySize;
      } else if (instruction != 0) {
        // Insert: the instruction byte is the length of the literal.
        out.setRange(written, written + instruction, delta, at);
        at += instruction;
        written += instruction;
      } else {
        throw const FormatException('delta instruction 0 is reserved');
      }
    }

    if (written != targetSize) {
      throw FormatException(
        'delta produced $written bytes, its header promised $targetSize',
      );
    }

    // A delta never changes the kind: it is a storage form, not an object.
    return (kind: base.kind, content: out);
  }

  // ---- bytes --------------------------------------------------------------

  Uint8List _readAt(int offset, int length) {
    final buffer = Uint8List(length);
    _file.setPositionSync(offset);
    var read = 0;
    while (read < length) {
      final n = _file.readIntoSync(buffer, read, length);
      if (n <= 0) throw FormatException('$packPath ended early at $offset');
      read += n;
    }
    return buffer;
  }

  /// Inflates the stream beginning at [offset] until [expectedSize] bytes have
  /// come out. The pack does not record how long a compressed stream is, so
  /// the uncompressed size in the object's header is the only stopping
  /// condition available.
  Uint8List _inflateAt(int offset, int expectedSize) {
    // Deflate never expands its input by more than the overhead of storing it
    // uncompressed, so the compressed form of an object cannot be much larger
    // than the object. That bound is what makes it safe to read a slab and
    // inflate from it rather than feeding the decompressor window by window:
    // the stream is certainly inside it, and whatever else the slab caught is
    // ignored.
    final bound = expectedSize + (expectedSize >> 10) + 64;
    final available = _fileLength - offset;
    if (available <= 0) {
      throw FormatException(
        '$packPath ends before the object at $offset',
      );
    }

    final slab = _readAt(offset, _min(bound, available));
    try {
      return inflateExactly(slab, expectedSize);
    } on FormatException catch (error) {
      throw FormatException(
        'the object at $offset in $packPath: ${error.message}',
      );
    }
  }

  static int _min(int a, int b) => a < b ? a : b;
}

/// Every pack in `objects/pack`, newest first — which is where a recently
/// fetched object is most likely to be.
List<PackFile> openPacks(String objectsDirectory) {
  final directory = fs.directory(p.join(objectsDirectory, 'pack'));
  if (!directory.existsSync()) return [];

  final packs = <PackFile>[];
  for (final entry in directory.listSync()) {
    if (entry is! GitFsFile || !entry.path.endsWith('.pack')) continue;
    final indexPath = '${p.withoutExtension(entry.path)}.idx';
    // A pack without its index cannot be read by name, only scanned; a fetch
    // in progress leaves exactly this state, so it is skipped rather than an
    // error.
    if (!fs.file(indexPath).existsSync()) continue;
    packs.add(PackFile.open(entry.path));
  }
  packs.sort((a, b) => fs.file(b.packPath)
      .lastModifiedSync()
      .compareTo(fs.file(a.packPath).lastModifiedSync()));
  return packs;
}

/// Reads the `objects/info/alternates` file: other object directories this
/// repository borrows from. One absolute or relative path per line.
List<String> readAlternates(String objectsDirectory) {
  final file = fs.file(p.join(objectsDirectory, 'info', 'alternates'));
  if (!file.existsSync()) return [];
  return LineSplitter.split(file.readAsStringSync())
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .map((line) => p.isAbsolute(line) ? line : p.join(objectsDirectory, line))
      .toList();
}
