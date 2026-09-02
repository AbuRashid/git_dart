import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart';

import '../object_id.dart';
import '../objects/git_object.dart';
import 'delta.dart';
import 'pack_index_writer.dart';
import '../platform/compress.dart';

/// A packfile and what a reader needs to index it.
///
/// The two are produced together because only the writer knows where each
/// object landed: a pack records where an object's data begins but not where
/// it ends, so recovering the offsets afterwards means inflating the whole
/// file to learn what was just written.
class BuiltPack {
  final Uint8List bytes;

  /// Every object, with its offset in [bytes] and the CRC of its entry.
  final List<PackedObject> objects;

  /// The pack's own trailing hash, which its index repeats.
  final ObjectId checksum;

  /// How many objects were stored as a difference from another.
  final int deltas;

  /// The longest chain of deltas in the pack, which bounds how much work
  /// reading one object at the end of it costs.
  final int deepestChain;

  const BuiltPack({
    required this.bytes,
    required this.objects,
    required this.checksum,
    this.deltas = 0,
    this.deepestChain = 0,
  });

  /// The `.idx` for this pack.
  Uint8List buildIndex() =>
      PackIndexWriter.build(objects: objects, packChecksum: checksum);

  /// The name git would give this pack, without an extension.
  String get name => PackIndexWriter.packName(objects.map((o) => o.id));
}

/// One object waiting to be packed.
class _Pending {
  final ObjectId id;
  final ObjectKind kind;
  final Uint8List content;

  /// A hash of the path this object was seen at, used only for ordering.
  final int nameHash;

  _Pending({
    required this.id,
    required this.kind,
    required this.content,
    required this.nameHash,
  });
}

/// An object already written, and therefore available as a delta base.
class _Written {
  final _Pending object;
  final int offset;

  /// How many deltas lie between this object and a whole one.
  final int depth;

  DeltaIndex? _index;

  _Written(this.object, this.offset, this.depth);

  /// Built on first use and kept while this stays in the window: the window
  /// compares one base against many targets, and rebuilding the index for
  /// each of them is most of the cost of packing.
  DeltaIndex get index => _index ??= DeltaIndex(object.content);

  void release() => _index = null;
}

/// Builds a packfile, storing objects as differences from one another where
/// that is smaller.
///
/// A pack of whole objects is legal — the delta forms are something the format
/// permits rather than requires — and it is several times larger than what git
/// would send. That cost falls on every push and every repack, so it is worth
/// the machinery.
///
/// Which object to delta against is a guess, and the quality of the guess is
/// most of the result. Git's heuristic, followed here, is to sort so that
/// objects likely to resemble each other end up adjacent — same kind, same
/// filename, largest first — and then to try each object against a small
/// window of its neighbours. Nothing verifies that a base is a *good* base;
/// the delta is simply built and kept if it turned out small.
class PackWriter {
  final _objects = <ObjectId, _Pending>{};

  int get length => _objects.length;

  /// Adds an object.
  ///
  /// [name] is the path this object was found at, when the caller knows it.
  /// It is used only to decide the packing order, and it matters more than it
  /// sounds: revisions of one file resemble each other and almost nothing
  /// else, so grouping by name is what turns a window of ten neighbours into
  /// a window of ten plausible bases. Without it the ordering falls back to
  /// size alone, which still works and compresses less well.
  void add(
    ObjectId id,
    ObjectKind kind,
    Uint8List content, {
    String? name,
  }) {
    _objects[id] = _Pending(
      id: id,
      kind: kind,
      content: content,
      nameHash: _nameHash(name),
    );
  }

  bool contains(ObjectId id) => _objects.containsKey(id);

  /// The pack bytes alone, for a caller that only has to send them.
  Uint8List build() => buildWithIndex().bytes;

  /// The pack, with the offsets and checksums its index needs.
  ///
  /// [window] is how many recent objects each one is tried against, and
  /// [maxDepth] how long a delta chain may grow. Both are git's defaults. The
  /// depth cap is not about correctness: every chain terminates because a base
  /// is always an object already written. It is about the cost of reading, at
  /// the far end of a chain, an object that has to be rebuilt from fifty
  /// others.
  ///
  /// Pass [deltas] false to store everything whole, which is what a caller
  /// wants when the objects are about to be read back immediately and the
  /// packing was only a way of moving them.
  BuiltPack buildWithIndex({
    int window = 10,
    int maxDepth = 50,
    bool deltas = true,
  }) {
    final body = BytesBuilder();
    final written = <PackedObject>[];

    body.add(const [0x50, 0x41, 0x43, 0x4b]); // 'PACK'
    body.add(_uint32(2)); // version
    body.add(_uint32(_objects.length));

    final order = deltas ? _packingOrder() : _objects.values.toList();
    final recent = <_Written>[];
    var deltaCount = 0;
    var deepest = 0;

    for (final object in order) {
      final offset = body.length;

      _Written? base;
      Uint8List? delta;

      if (deltas && object.content.length >= _minimumWorthDeltaing) {
        final chosen = _chooseBase(object, recent, maxDepth);
        base = chosen?.base;
        delta = chosen?.delta;
      }

      final Uint8List header;
      final Uint8List payload;
      int depth;

      if (base != null && delta != null) {
        // An offset delta, not a name delta: the base is always something
        // already written, so it is always behind us, and a backward distance
        // is shorter than twenty bytes of object name.
        header = _header(6, delta.length);
        final distance = _offsetDistance(offset - base.offset);
        payload = delta;
        depth = base.depth + 1;

        final compressed = deflate(payload);
        body
          ..add(header)
          ..add(distance)
          ..add(compressed);

        written.add(PackedObject(
          id: object.id,
          offset: offset,
          crc32: getCrc32(
            compressed,
            getCrc32(distance, getCrc32(header)),
          ),
        ));

        deltaCount += 1;
        if (depth > deepest) deepest = depth;
      } else {
        header = _header(_typeOf(object.kind), object.content.length);
        payload = object.content;
        depth = 0;

        final compressed = deflate(payload);
        body
          ..add(header)
          ..add(compressed);

        written.add(PackedObject(
          id: object.id,
          offset: offset,
          // The CRC covers the entry as written — header and compressed data
          // together — because that is the unit a repack copies.
          crc32: getCrc32(compressed, getCrc32(header)),
        ));
      }

      if (deltas) {
        recent.add(_Written(object, offset, depth));
        while (recent.length > window) {
          recent.removeAt(0).release();
        }
      }
    }

    final bytes = body.takeBytes();
    // The file ends with the hash of everything before it.
    final checksum = ObjectId(
      Uint8List.fromList(sha1.convert(bytes).bytes),
    );

    final complete = Uint8List(bytes.length + ObjectId.byteLength)
      ..setRange(0, bytes.length, bytes)
      ..setRange(bytes.length, bytes.length + ObjectId.byteLength,
          checksum.bytes);

    return BuiltPack(
      bytes: complete,
      objects: written,
      checksum: checksum,
      deltas: deltaCount,
      deepestChain: deepest,
    );
  }

  /// Below this an object is stored whole regardless.
  ///
  /// A delta carries two sizes and at least one instruction before it says
  /// anything, so for a very small object the difference cannot be smaller
  /// than the object.
  static const int _minimumWorthDeltaing = 64;

  /// Above this no delta is attempted, because indexing the base costs memory
  /// proportional to its size and a window of them at once is what would
  /// actually run out.
  static const int _maximumWorthDeltaing = 64 * 1024 * 1024;

  /// The order objects are written in, and therefore which ones are near
  /// enough to each other to be tried as bases.
  ///
  /// Kind first, so a tree is never offered a blob as a base. Then the name
  /// hash, which puts revisions of one file together. Then size descending,
  /// which means the window ahead of an object holds things at least as large
  /// as it — and a delta against a larger base is the one likely to be small,
  /// since it can copy rather than insert.
  List<_Pending> _packingOrder() {
    final order = _objects.values.toList();
    order.sort((a, b) {
      final byKind = _typeOf(a.kind).compareTo(_typeOf(b.kind));
      if (byKind != 0) return byKind;
      final byName = b.nameHash.compareTo(a.nameHash);
      if (byName != 0) return byName;
      final bySize = b.content.length.compareTo(a.content.length);
      if (bySize != 0) return bySize;
      return a.id.compareTo(b.id);
    });
    return order;
  }

  /// The smallest delta available from the window, or null.
  ({_Written base, Uint8List delta})? _chooseBase(
    _Pending object,
    List<_Written> window,
    int maxDepth,
  ) {
    if (object.content.length > _maximumWorthDeltaing) return null;

    _Written? bestBase;
    Uint8List? bestDelta;

    // Most recent first: with the sort above, the nearest neighbour is the
    // most similar, so the best answer usually arrives before the limit has
    // been tightened much and the rest give up early.
    for (var i = window.length - 1; i >= 0; i--) {
      final candidate = window[i];

      if (candidate.object.kind != object.kind) continue;
      if (candidate.depth >= maxDepth) continue;
      if (candidate.object.content.length > _maximumWorthDeltaing) continue;
      // A base far smaller than the target has too little to copy from to be
      // worth the attempt.
      if (candidate.object.content.length * 32 < object.content.length) {
        continue;
      }

      final limit = bestDelta?.length ?? object.content.length;
      final delta = encodeDelta(
        candidate.index,
        object.content,
        limit: limit,
      );
      if (delta == null) continue;

      if (bestDelta == null || delta.length < bestDelta.length) {
        bestDelta = delta;
        bestBase = candidate;
      }
    }

    if (bestBase == null || bestDelta == null) return null;
    return (base: bestBase, delta: bestDelta);
  }

  /// Git's own ordering hash for a path.
  ///
  /// It weights the *last* characters most, so files sharing an extension or
  /// a name sort together however deep they sit. That is deliberate: what
  /// resembles `src/thing.dart` is `other/thing.dart` and every earlier
  /// version of both, not the file next to it in the same directory.
  static int _nameHash(String? name) {
    if (name == null || name.isEmpty) return 0;
    var hash = 0;
    for (final rune in name.runes) {
      if (rune == 0x20 || rune == 0x09 || rune == 0x0a || rune == 0x0d) {
        continue;
      }
      hash = ((hash >> 2) + ((rune & 0xff) << 24)) & 0xffffffff;
    }
    return hash;
  }

  static int _typeOf(ObjectKind kind) => switch (kind) {
        ObjectKind.commit => 1,
        ObjectKind.tree => 2,
        ObjectKind.blob => 3,
        ObjectKind.tag => 4,
      };

  static Uint8List _uint32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value);

  /// The type in bits 4 to 6 of the first byte, then the size seven bits at a
  /// time — four in the first byte, because the type took the room.
  ///
  /// For a delta the size is the length of the *delta*, not of the object it
  /// produces: the reader needs to know how much to inflate, and how big the
  /// result will be is written inside the delta itself.
  static Uint8List _header(int type, int size) {
    final out = <int>[];
    var byte = (type << 4) | (size & 0x0f);
    var rest = size >> 4;
    while (rest > 0) {
      out.add(byte | 0x80);
      byte = rest & 0x7f;
      rest >>= 7;
    }
    out.add(byte);
    return Uint8List.fromList(out);
  }

  /// How far back the base sits, in the format an offset delta uses.
  ///
  /// Not the ordinary varint: this one is big-endian and adds one to the
  /// running value before each further byte, so that no number has two
  /// encodings. Getting it wrong points the reader at the wrong object, which
  /// then fails a size check rather than silently producing nonsense — the one
  /// mercy in the format.
  static Uint8List _offsetDistance(int distance) {
    if (distance <= 0) {
      throw ArgumentError.value(
        distance,
        'distance',
        'a delta base must lie earlier in the pack',
      );
    }
    final reversed = <int>[];
    var value = distance;
    reversed.add(value & 0x7f);
    value >>= 7;
    while (value != 0) {
      value -= 1;
      reversed.add(0x80 | (value & 0x7f));
      value >>= 7;
    }
    return Uint8List.fromList(reversed.reversed.toList());
  }
}
