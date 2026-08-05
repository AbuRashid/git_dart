import 'dart:io';
import 'dart:typed_data';

import '../object_id.dart';

/// The companion index of a packfile: object name to offset within the pack.
///
/// Two versions exist in the wild. Version 2 announces itself with the magic
/// `ff 74 4f 63`; version 1 has no magic at all and begins directly with the
/// fanout table, which is why the magic was chosen to be a value no version-1
/// fanout entry could hold.
class PackIndex {
  static const List<int> _magic = [0xff, 0x74, 0x4f, 0x63];

  final int version;

  /// Object names in ascending order — the order the file stores them in, so
  /// a lookup is a binary search narrowed by the fanout table.
  final Uint8List _names;

  final Uint32List _fanout;
  final List<int> _offsets;

  PackIndex._({
    required this.version,
    required Uint8List names,
    required Uint32List fanout,
    required List<int> offsets,
  })  : _names = names,
        _fanout = fanout,
        _offsets = offsets;

  int get objectCount => _fanout[255];

  factory PackIndex.open(String path) =>
      PackIndex.parse(File(path).readAsBytesSync());

  factory PackIndex.parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final hasMagic = bytes.length >= 4 &&
        bytes[0] == _magic[0] &&
        bytes[1] == _magic[1] &&
        bytes[2] == _magic[2] &&
        bytes[3] == _magic[3];

    if (!hasMagic) return PackIndex._parseV1(bytes, data);

    final version = data.getUint32(4);
    if (version != 2) {
      throw FormatException('unsupported pack index version $version');
    }

    final fanout = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      fanout[i] = data.getUint32(8 + i * 4);
    }
    final count = fanout[255];

    final namesStart = 8 + 256 * 4;
    final names = Uint8List.sublistView(
      bytes,
      namesStart,
      namesStart + count * ObjectId.byteLength,
    );

    // Names, then a CRC per object, then a 32-bit offset per object.
    final offsetsStart = namesStart + count * ObjectId.byteLength + count * 4;
    final bigOffsetsStart = offsetsStart + count * 4;

    final offsets = List<int>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      final raw = data.getUint32(offsetsStart + i * 4);
      if (raw & 0x80000000 == 0) {
        offsets[i] = raw;
      } else {
        // The top bit means "look in the 64-bit table"; the rest is the index.
        final big = raw & 0x7fffffff;
        offsets[i] = data.getUint64(bigOffsetsStart + big * 8);
      }
    }

    return PackIndex._(
      version: 2,
      names: names,
      fanout: fanout,
      offsets: offsets,
    );
  }

  factory PackIndex._parseV1(Uint8List bytes, ByteData data) {
    final fanout = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      fanout[i] = data.getUint32(i * 4);
    }
    final count = fanout[255];

    // Version 1 interleaves a 32-bit offset with each name.
    final names = Uint8List(count * ObjectId.byteLength);
    final offsets = List<int>.filled(count, 0);
    const entrySize = 4 + ObjectId.byteLength;
    for (var i = 0; i < count; i++) {
      final at = 256 * 4 + i * entrySize;
      offsets[i] = data.getUint32(at);
      names.setRange(
        i * ObjectId.byteLength,
        (i + 1) * ObjectId.byteLength,
        bytes,
        at + 4,
      );
    }

    return PackIndex._(
      version: 1,
      names: names,
      fanout: fanout,
      offsets: offsets,
    );
  }

  /// The offset of [id] within the pack, or null if this index does not hold
  /// it.
  int? offsetOf(ObjectId id) {
    final position = _positionOf(id);
    return position == null ? null : _offsets[position];
  }

  bool contains(ObjectId id) => _positionOf(id) != null;

  int? _positionOf(ObjectId id) {
    final first = id.bytes[0];
    var low = first == 0 ? 0 : _fanout[first - 1];
    var high = _fanout[first];

    while (low < high) {
      final middle = (low + high) >> 1;
      final comparison = _compareAt(middle, id.bytes);
      if (comparison < 0) {
        low = middle + 1;
      } else if (comparison > 0) {
        high = middle;
      } else {
        return middle;
      }
    }
    return null;
  }

  int _compareAt(int position, Uint8List target) {
    final base = position * ObjectId.byteLength;
    for (var i = 0; i < ObjectId.byteLength; i++) {
      final d = _names[base + i] - target[i];
      if (d != 0) return d;
    }
    return 0;
  }

  ObjectId nameAt(int position) =>
      ObjectId.fromBytes(_names, position * ObjectId.byteLength);

  /// Every name in the pack, in ascending order.
  Iterable<ObjectId> listAll() sync* {
    for (var i = 0; i < objectCount; i++) {
      yield nameAt(i);
    }
  }

  /// Names in ascending order paired with their offsets — what a reader needs
  /// to walk a pack without repeating the binary search.
  Iterable<({ObjectId id, int offset})> entries() sync* {
    for (var i = 0; i < objectCount; i++) {
      yield (id: nameAt(i), offset: _offsets[i]);
    }
  }
}
