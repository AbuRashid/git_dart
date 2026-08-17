import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Inflate, InputStream, getCrc32;
import 'package:crypto/crypto.dart';

import '../fs/git_fs.dart';
import '../object_id.dart';
import '../objects/git_object.dart';
import 'pack_index_writer.dart';

/// What one entry in a pack says about itself before it is materialised.
class _Record {
  final int type;
  final int size;

  /// Where the entry begins, where its compressed data begins, and where the
  /// next entry begins.
  final int offset;
  final int dataOffset;
  final int end;

  final int? baseOffset;
  final ObjectId? baseName;

  ObjectId? id;

  _Record({
    required this.type,
    required this.size,
    required this.offset,
    required this.dataOffset,
    required this.end,
    this.baseOffset,
    this.baseName,
  });

  bool get isDelta => type == 6 || type == 7;
}

/// Builds an index for a packfile on disk, without holding it in memory.
///
/// [PackParser] reads a pack into a map of every object it contains, which is
/// exactly right for a pack of a few hundred objects and impossible for a
/// clone: the map is the whole repository, uncompressed, at once. This walks
/// the file instead, keeping a bounded cache of recently materialised objects
/// and rebuilding a delta base from its recorded position when the cache no
/// longer has it.
///
/// The cost is occasional re-inflation of a base; the benefit is that peak
/// memory is the cache plus one object, whatever the size of the pack. Git
/// makes the same trade and calls its version a delta base cache.
class PackIndexer {
  final String path;

  /// How many bytes of materialised objects to keep. A delta's base is
  /// usually the object just before it, so even a small cache catches most of
  /// the chain and the rest is re-read rather than lost.
  final int cacheBytes;

  PackIndexer(this.path, {this.cacheBytes = 64 * 1024 * 1024});

  late final GitFsHandle _file = fs.file(path).openSync();
  late final int _length = fs.file(path).lengthSync();

  final _records = <int, _Record>{};
  final _offsetOfName = <ObjectId, int>{};

  /// Most-recently-used last, so eviction takes from the front.
  final _cache = LinkedHashMap<int, ({ObjectKind kind, Uint8List content})>();
  var _cacheHeld = 0;

  /// Walks the pack and returns what its index needs.
  ({List<PackedObject> objects, ObjectId checksum, int count}) run() {
    try {
      final header = _readAt(0, 12);
      if (String.fromCharCodes(header.sublist(0, 4)) != 'PACK') {
        throw FormatException('$path does not begin with PACK');
      }
      final view = ByteData.sublistView(header);
      final version = view.getUint32(4);
      if (version != 2 && version != 3) {
        throw FormatException('unsupported pack version $version');
      }
      final count = view.getUint32(8);

      final checksum = _verifyChecksum();

      // ---- pass one: walk the entries ----
      //
      // Every object has to be inflated, because a pack records where a
      // compressed stream begins and not where it ends. Finding the next entry
      // means finishing the one before it — which is the reason a packfile
      // cannot be understood by reading a hex dump and guessing
      // (`algorithms.where-people-stop`).
      var at = 12;
      final deferred = <_Record>[];

      for (var i = 0; i < count; i++) {
        final record = _readRecord(at);
        _records[record.offset] = record;
        at = record.end;

        // A ref-delta may name a base that appears later in the same pack, so
        // it waits; an ofs-delta always points backwards and never does.
        if (record.type == 7 && !_offsetOfName.containsKey(record.baseName)) {
          deferred.add(record);
          continue;
        }
        _identify(record);
      }

      // ---- pass two: what was waiting for a base ----
      var remaining = deferred;
      while (remaining.isNotEmpty) {
        final stillWaiting = <_Record>[];
        for (final record in remaining) {
          if (!_offsetOfName.containsKey(record.baseName)) {
            stillWaiting.add(record);
            continue;
          }
          _identify(record);
        }
        if (stillWaiting.length == remaining.length) {
          // A thin pack names bases it does not carry. Legal on the wire
          // between two repositories that agree what the other has, and not
          // something this can index on its own.
          throw FormatException(
            '${stillWaiting.length} objects have bases outside $path',
          );
        }
        remaining = stillWaiting;
      }

      final objects = <PackedObject>[];
      for (final record in _records.values) {
        objects.add(PackedObject(
          id: record.id!,
          offset: record.offset,
          // The checksum covers the entry as written — header and compressed
          // data together — because that is the unit a repack copies.
          crc32: getCrc32(_readAt(record.offset, record.end - record.offset)),
        ));
      }
      objects.sort((a, b) => a.offset.compareTo(b.offset));

      return (objects: objects, checksum: checksum, count: count);
    } finally {
      close();
    }
  }

  void close() {
    _file.closeSync();
    _cache.clear();
    _cacheHeld = 0;
  }

  /// Names [record], materialising it only as far as is needed to hash it.
  void _identify(_Record record) {
    final object = _materialise(record.offset);
    final id = hashObject(object.kind, object.content);
    record.id = id;
    _offsetOfName[id] = record.offset;
  }

  /// The object at [offset], from the cache or rebuilt.
  ({ObjectKind kind, Uint8List content}) _materialise(int offset) {
    final cached = _cache.remove(offset);
    if (cached != null) {
      _cache[offset] = cached; // most recently used
      return cached;
    }

    final record = _records[offset];
    if (record == null) {
      throw FormatException('no entry was recorded at $offset in $path');
    }

    final ({ObjectKind kind, Uint8List content}) result;
    if (!record.isDelta) {
      result = (
        kind: switch (record.type) {
          1 => ObjectKind.commit,
          2 => ObjectKind.tree,
          3 => ObjectKind.blob,
          4 => ObjectKind.tag,
          _ => throw FormatException(
              'reserved pack object type ${record.type} at $offset',
            ),
        },
        content: _inflate(record),
      );
    } else {
      final baseOffset = record.type == 6
          ? record.baseOffset!
          : (_offsetOfName[record.baseName] ??
              (throw FormatException(
                'delta base ${record.baseName} is not in $path',
              )));
      // Recursive, and bounded by the delta chain rather than by the pack:
      // git's own writer caps a chain at fifty.
      final base = _materialise(baseOffset);
      result = _applyDelta(base, _inflate(record));
    }

    _remember(offset, result);
    return result;
  }

  void _remember(int offset, ({ObjectKind kind, Uint8List content}) object) {
    // An object larger than the whole budget is not worth evicting everything
    // for; it is returned and simply not kept.
    if (object.content.length > cacheBytes) return;

    _cache[offset] = object;
    _cacheHeld += object.content.length;

    while (_cacheHeld > cacheBytes && _cache.isNotEmpty) {
      final oldest = _cache.keys.first;
      final evicted = _cache.remove(oldest)!;
      _cacheHeld -= evicted.content.length;
    }
  }

  // ---- reading ------------------------------------------------------------

  /// Reads one entry's header, and finds where its compressed data ends by
  /// inflating it.
  _Record _readRecord(int offset) {
    // Enough for the size varint, an offset varint and a 20-byte base name.
    final window = _readAt(offset, _min(64, _length - offset));
    var at = 0;

    var byte = window[at++];
    final type = (byte >> 4) & 0x07;
    var size = byte & 0x0f;
    var shift = 4;
    while (byte & 0x80 != 0) {
      byte = window[at++];
      size |= (byte & 0x7f) << shift;
      shift += 7;
    }

    int? baseOffset;
    ObjectId? baseName;

    if (type == 6) {
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
    } else if (type == 7) {
      baseName = ObjectId.fromBytes(window, at);
      at += ObjectId.byteLength;
    }

    final dataOffset = offset + at;
    final end = _endOfStream(dataOffset, size);

    return _Record(
      type: type,
      size: size,
      offset: offset,
      dataOffset: dataOffset,
      end: end,
      baseOffset: baseOffset,
      baseName: baseName,
    );
  }

  /// A zlib stream: two header bytes, raw deflate, then a four-byte Adler-32.
  static const _zlibHeader = 2;
  static const _zlibChecksum = 4;

  /// Where the compressed stream beginning at [offset] ends.
  ///
  /// The pack does not record it, so the only way to find out is to inflate.
  /// The window is grown rather than guessed at: an object whose compressed
  /// form is larger than the first read is uncommon and must still be right.
  int _endOfStream(int offset, int expectedSize) {
    // Content that does not compress comes out slightly *larger* than it went
    // in — zlib stores it with a five-byte header per 64KB block — so a window
    // of exactly the uncompressed size is not always enough. The margin covers
    // the ordinary case and the loop covers the rest.
    final margin = 128 + (expectedSize >> 6);
    var window = _min(_max(expectedSize + margin, 8192), _length - offset);

    while (true) {
      final chunk = _readAt(offset, window);
      final flags = chunk[1];
      if (flags & 0x20 != 0) {
        throw FormatException('the object at $offset uses a preset dictionary');
      }

      final atEnd = offset + window >= _length;
      try {
        final input = InputStream(Uint8List.sublistView(chunk, _zlibHeader));
        final out = Inflate.buffer(input, expectedSize).getBytes();

        if (out.length == expectedSize) {
          return offset + _zlibHeader + input.position + _zlibChecksum;
        }
        if (atEnd) {
          throw FormatException(
            'the object at $offset inflated to ${out.length} bytes, its header '
            'said $expectedSize, and the pack ends',
          );
        }
      } on FormatException {
        rethrow;
      } catch (_) {
        // The inflater ran off the end of a window that stopped mid-stream.
        // Indistinguishable here from real corruption, so it is only treated
        // as "not enough bytes" while there are more bytes to be had.
        if (atEnd) {
          throw FormatException(
            'the object at $offset does not inflate to the $expectedSize bytes '
            'its header promised',
          );
        }
      }

      window = _min(window * 2, _length - offset);
    }
  }

  Uint8List _inflate(_Record record) {
    final compressed = _readAt(
      record.dataOffset,
      record.end - record.dataOffset - _zlibChecksum,
    );
    final out = Uint8List.fromList(
      Inflate.buffer(
        InputStream(Uint8List.sublistView(compressed, _zlibHeader)),
        record.size,
      ).getBytes(),
    );
    if (out.length != record.size) {
      throw FormatException(
        'the object at ${record.offset} inflated to ${out.length} bytes, its '
        'header said ${record.size}',
      );
    }
    return out;
  }

  /// Checks the pack's trailing hash by streaming the file, so a corrupt
  /// download is caught before anything is written from it.
  ObjectId _verifyChecksum() {
    final body = _length - ObjectId.byteLength;
    if (body <= 12) throw FormatException('$path is too short to be a pack');

    Digest? result;
    final input = sha1.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback(
        (digests) => result = digests.single,
      ),
    );

    var at = 0;
    const window = 1 << 20;
    while (at < body) {
      final chunk = _readAt(at, _min(window, body - at));
      input.add(chunk);
      at += chunk.length;
    }
    input.close();

    final actual = ObjectId(Uint8List.fromList(result!.bytes));
    final declared = ObjectId.fromBytes(_readAt(body, ObjectId.byteLength));
    if (declared != actual) {
      throw FormatException('$path: its own checksum does not match');
    }
    return actual;
  }

  Uint8List _readAt(int offset, int length) {
    final buffer = Uint8List(length);
    _file.setPositionSync(offset);
    var read = 0;
    while (read < length) {
      final n = _file.readIntoSync(buffer, read, length);
      if (n <= 0) throw FormatException('$path ended early at $offset');
      read += n;
    }
    return buffer;
  }

  // ---- delta --------------------------------------------------------------

  ({ObjectKind kind, Uint8List content}) _applyDelta(
    ({ObjectKind kind, Uint8List content}) base,
    Uint8List delta,
  ) {
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

        out.setRange(written, written + copySize, base.content, copyOffset);
        written += copySize;
      } else if (instruction != 0) {
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

  static int _min(int a, int b) => a < b ? a : b;
  static int _max(int a, int b) => a > b ? a : b;
}
