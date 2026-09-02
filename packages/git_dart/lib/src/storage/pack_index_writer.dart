import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../object_id.dart';
import '../platform/big_endian64.dart';

/// One object's place in a pack: its name, where it starts, and a checksum of
/// the bytes as they were written.
///
/// The CRC is not for finding corruption on read — the pack's own trailing
/// hash does that. It exists so a repack can copy an entry from one pack into
/// another without inflating it, and still know the copy arrived intact.
class PackedObject {
  final ObjectId id;
  final int offset;
  final int crc32;

  const PackedObject({
    required this.id,
    required this.offset,
    required this.crc32,
  });
}

/// Builds the `.idx` that makes a packfile readable by name.
///
/// A pack on its own can only be read front to back: it records where each
/// object's compressed data begins but not where it ends, so finding one
/// object means inflating every object before it. The index is what turns that
/// into a lookup, and a pack without one is a pack no reader can use — which
/// is why receiving a pack and building its index are one operation, not two.
///
/// Version 2 is what is written here. Version 1 is still read (see
/// [PackIndex]) because old repositories hold them; nothing has written one
/// since 2007, and its 32-bit offsets cannot describe a pack over 4GB.
class PackIndexWriter {
  static const List<int> _magic = [0xff, 0x74, 0x4f, 0x63];

  /// Serialises an index for [objects], which need not be sorted.
  ///
  /// [packChecksum] is the pack's own trailing hash: the index repeats it, so
  /// that a `.idx` and a `.pack` that do not belong together can be told apart
  /// without reading either in full.
  static Uint8List build({
    required List<PackedObject> objects,
    required ObjectId packChecksum,
  }) {
    // Sorted by name: the fanout table and the binary search over it both
    // depend on this order, and nothing else records it.
    final sorted = [...objects]..sort((a, b) => a.id.compareTo(b.id));

    // A pack may legally hold the same object twice, but an index cannot: a
    // name would then have two offsets and a lookup no answer.
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].id == sorted[i - 1].id) {
        throw FormatException(
          'the pack holds ${sorted[i].id} twice; an index cannot name it',
        );
      }
    }

    final count = sorted.length;

    // Offsets above 2^31 do not fit the 32-bit table and go to a 64-bit one,
    // named from the small table with its top bit set. The boundary is 2^31,
    // not 2^32: the top bit is the flag, so it cannot also be data.
    const smallLimit = 0x80000000;
    final large = <int>[];
    for (final object in sorted) {
      if (object.offset >= smallLimit) large.add(object.offset);
    }
    final largeIndexOf = <int, int>{};
    for (var i = 0; i < large.length; i++) {
      largeIndexOf[large[i]] = i;
    }

    final size = _magic.length +
        4 + // version
        256 * 4 + // fanout
        count * ObjectId.byteLength +
        count * 4 + // crcs
        count * 4 + // small offsets
        large.length * 8 +
        ObjectId.byteLength * 2; // pack checksum, then our own

    final out = Uint8List(size);
    final view = ByteData.sublistView(out);
    var at = 0;

    out.setRange(0, 4, _magic);
    at = 4;
    view.setUint32(at, 2);
    at += 4;

    // The fanout: entry n is how many objects have a first byte of n or less.
    // It narrows a search to one 256th of the file before the binary search
    // starts, which is the whole of why it is here.
    var seen = 0;
    var object = 0;
    for (var bucket = 0; bucket < 256; bucket++) {
      while (object < count && sorted[object].id.bytes[0] == bucket) {
        object += 1;
        seen += 1;
      }
      view.setUint32(at + bucket * 4, seen);
    }
    at += 256 * 4;

    for (final entry in sorted) {
      out.setRange(at, at + ObjectId.byteLength, entry.id.bytes);
      at += ObjectId.byteLength;
    }

    for (final entry in sorted) {
      view.setUint32(at, entry.crc32);
      at += 4;
    }

    for (final entry in sorted) {
      if (entry.offset < smallLimit) {
        view.setUint32(at, entry.offset);
      } else {
        view.setUint32(at, 0x80000000 | largeIndexOf[entry.offset]!);
      }
      at += 4;
    }

    for (final offset in large) {
      writeUint64(view, at, offset);
      at += 8;
    }

    out.setRange(at, at + ObjectId.byteLength, packChecksum.bytes);
    at += ObjectId.byteLength;

    // The index ends with its own hash, over everything before it.
    final checksum = sha1.convert(out.sublist(0, at)).bytes;
    out.setRange(at, at + ObjectId.byteLength, checksum);

    return out;
  }

  /// The name git would give a pack holding [names]: `pack-<hash>`.
  ///
  /// The hash is over the sorted object names, not over the file, so the same
  /// set of objects lands on the same name however it was packed — which is
  /// what stops a re-fetch of the same objects from accumulating packs.
  static String packName(Iterable<ObjectId> names) {
    final sorted = [...names]..sort((a, b) => a.compareTo(b));
    final digest = sha1.convert([
      for (final id in sorted) ...id.bytes,
    ]);
    return 'pack-$digest';
  }
}
