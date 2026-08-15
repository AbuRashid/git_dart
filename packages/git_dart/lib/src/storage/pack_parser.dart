import 'dart:typed_data';

import 'package:archive/archive.dart' show Inflate, InputStream, getCrc32;
import 'package:crypto/crypto.dart';

import '../object_id.dart';
import '../objects/git_object.dart';
import 'pack_index_writer.dart';

/// Reads a whole packfile held in memory, resolving every delta.
///
/// The packfile reader used for repositories on disk finds objects through the
/// companion index. A pack that has just arrived over the wire has no index —
/// building one is the receiver's job — so this reads the objects in order
/// instead.
///
/// That needs something the on-disk reader never does: knowing where each
/// compressed object ends. A packfile does not record it, and `dart:io`'s zlib
/// does not report how much input it consumed, so the inflating here is done
/// by a pure-Dart implementation that does.
class PackParser {
  final Uint8List bytes;

  PackParser(this.bytes);

  /// Where each object's entry starts and ends, and what it turned out to be
  /// named. Filled during [parse]; a delta's name is only known once its base
  /// has been found, which is why this is collected rather than returned as
  /// the pass goes.
  final _spans = <int, ({int end, ObjectId? id})>{};

  /// The pack's own trailing hash, once [parse] has checked it.
  ObjectId? checksum;

  /// Every object with its offset and entry checksum, ready to be written as
  /// an index.
  ///
  /// Only meaningful after [parse]. Indexing a pack this way — rather than
  /// re-deriving the offsets afterwards — is the difference between storing a
  /// received pack as it arrived and inflating the whole thing twice.
  List<PackedObject> indexEntries() {
    final out = <PackedObject>[];
    _spans.forEach((offset, span) {
      final id = span.id;
      if (id == null) return;
      out.add(PackedObject(
        id: id,
        offset: offset,
        crc32: getCrc32(Uint8List.sublistView(bytes, offset, span.end)),
      ));
    });
    out.sort((a, b) => a.offset.compareTo(b.offset));
    return out;
  }

  /// Every object in the pack, keyed by name, with deltas applied.
  Map<ObjectId, ({ObjectKind kind, Uint8List content})> parse() {
    final data = ByteData.sublistView(bytes);

    if (bytes.length < 32 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'PACK') {
      throw const FormatException('not a packfile: no PACK signature');
    }
    final version = data.getUint32(4);
    if (version != 2 && version != 3) {
      throw FormatException('unsupported pack version $version');
    }
    final count = data.getUint32(8);

    // The trailing twenty bytes are the hash of everything before them.
    final body = bytes.length - ObjectId.byteLength;
    final declared = ObjectId.fromBytes(bytes, body);
    final actual = ObjectId(
      Uint8List.fromList(sha1.convert(bytes.sublist(0, body)).bytes),
    );
    if (declared != actual) {
      throw const FormatException('the packfile\'s own checksum does not match');
    }
    checksum = actual;

    final byOffset = <int, ({ObjectKind kind, Uint8List content})>{};
    final byName = <ObjectId, ({ObjectKind kind, Uint8List content})>{};
    // A ref-delta may name a base that appears later in the same pack, so
    // anything unresolved is set aside and retried once the pass is done.
    final pending = <({int offset, ObjectId? base, int? baseOffset, Uint8List delta})>[];

    var at = 12;
    for (var i = 0; i < count; i++) {
      final start = at;
      final header = _readHeader(at);
      at = header.next;

      final inflated = _inflateAt(at, header.size);
      at = inflated.next;
      // Where this entry ended, so its checksum can be taken over exactly the
      // bytes a reader will later find here.
      _spans[start] = (end: at, id: null);

      switch (header.type) {
        case 6: // ofs-delta
          final baseOffset = start - header.distance!;
          final base = byOffset[baseOffset];
          if (base == null) {
            pending.add((
              offset: start,
              base: null,
              baseOffset: baseOffset,
              delta: inflated.bytes,
            ));
          } else {
            _record(byOffset, byName, start,
                _applyDelta(base, inflated.bytes));
          }
        case 7: // ref-delta
          final base = byName[header.baseName!];
          if (base == null) {
            pending.add((
              offset: start,
              base: header.baseName,
              baseOffset: null,
              delta: inflated.bytes,
            ));
          } else {
            _record(byOffset, byName, start,
                _applyDelta(base, inflated.bytes));
          }
        default:
          final kind = switch (header.type) {
            1 => ObjectKind.commit,
            2 => ObjectKind.tree,
            3 => ObjectKind.blob,
            4 => ObjectKind.tag,
            _ => throw FormatException(
                'reserved pack object type ${header.type}',
              ),
          };
          _record(byOffset, byName, start,
              (kind: kind, content: inflated.bytes));
      }
    }

    // Resolve what was waiting for a base, repeatedly: a delta may itself be
    // the base of another.
    var remaining = pending;
    while (remaining.isNotEmpty) {
      final stillWaiting = <({int offset, ObjectId? base, int? baseOffset, Uint8List delta})>[];
      for (final item in remaining) {
        final base = item.baseOffset != null
            ? byOffset[item.baseOffset]
            : byName[item.base];
        if (base == null) {
          stillWaiting.add(item);
          continue;
        }
        _record(byOffset, byName, item.offset, _applyDelta(base, item.delta));
      }
      if (stillWaiting.length == remaining.length) {
        // Nothing moved, so the missing bases are not in this pack. A thin
        // pack is legal on the wire and this reader does not accept one.
        throw FormatException(
          '${stillWaiting.length} objects have bases outside this pack',
        );
      }
      remaining = stillWaiting;
    }

    return byName;
  }

  void _record(
    Map<int, ({ObjectKind kind, Uint8List content})> byOffset,
    Map<ObjectId, ({ObjectKind kind, Uint8List content})> byName,
    int offset,
    ({ObjectKind kind, Uint8List content}) object,
  ) {
    byOffset[offset] = object;
    final id = hashObject(object.kind, object.content);
    byName[id] = object;

    final span = _spans[offset];
    if (span != null) _spans[offset] = (end: span.end, id: id);
  }

  ({int type, int size, int next, int? distance, ObjectId? baseName})
      _readHeader(int at) {
    var byte = bytes[at++];
    final type = (byte >> 4) & 0x07;
    var size = byte & 0x0f;
    var shift = 4;
    while (byte & 0x80 != 0) {
      byte = bytes[at++];
      size |= (byte & 0x7f) << shift;
      shift += 7;
    }

    int? distance;
    ObjectId? baseName;

    if (type == 6) {
      byte = bytes[at++];
      distance = byte & 0x7f;
      while (byte & 0x80 != 0) {
        byte = bytes[at++];
        distance = ((distance! + 1) << 7) | (byte & 0x7f);
      }
    } else if (type == 7) {
      baseName = ObjectId.fromBytes(bytes, at);
      at += ObjectId.byteLength;
    }

    return (
      type: type,
      size: size,
      next: at,
      distance: distance,
      baseName: baseName,
    );
  }

  /// Inflates from [at], returning the bytes and where the compressed stream
  /// ended.
  ({Uint8List bytes, int next}) _inflateAt(int at, int expectedSize) {
    // A packed object is a zlib stream (RFC 1950): two header bytes, the raw
    // deflate data, then a four-byte Adler-32. The inflater here does raw
    // deflate only, so the wrapper is stepped over on both sides.
    const zlibHeader = 2;
    const zlibChecksum = 4;

    final flags = bytes[at + 1];
    if (flags & 0x20 != 0) {
      // A preset dictionary would put four more bytes before the data. Git
      // does not use one, and guessing would silently misread every object
      // after this one.
      throw FormatException('the object at $at uses a preset dictionary');
    }

    final input = InputStream(Uint8List.sublistView(bytes, at + zlibHeader));
    final out = Uint8List.fromList(
      Inflate.buffer(input, expectedSize).getBytes(),
    );

    if (out.length != expectedSize) {
      throw FormatException(
        'object at $at inflated to ${out.length} bytes, its header said '
        '$expectedSize',
      );
    }
    // How much of the input the inflater actually read — the number the
    // packfile does not record and the reason for this implementation.
    return (bytes: out, next: at + zlibHeader + input.position + zlibChecksum);
  }

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
}
