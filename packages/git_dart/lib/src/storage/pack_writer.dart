import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart';

import '../object_id.dart';
import '../objects/git_object.dart';
import 'pack_index_writer.dart';

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

  const BuiltPack({
    required this.bytes,
    required this.objects,
    required this.checksum,
  });

  /// The `.idx` for this pack.
  Uint8List buildIndex() =>
      PackIndexWriter.build(objects: objects, packChecksum: checksum);

  /// The name git would give this pack, without an extension.
  String get name => PackIndexWriter.packName(objects.map((o) => o.id));
}

/// Builds a packfile.
///
/// Every object is written whole, with no deltas. A pack of whole objects is
/// a legal pack — the delta forms are an optimisation the format permits and
/// does not require — so this is correct, and larger on the wire than what git
/// would send. Choosing good delta bases is a separate problem worth solving
/// only once pushing works at all.
class PackWriter {
  final _objects = <ObjectId, ({ObjectKind kind, Uint8List content})>{};

  int get length => _objects.length;

  void add(ObjectId id, ObjectKind kind, Uint8List content) {
    _objects[id] = (kind: kind, content: content);
  }

  bool contains(ObjectId id) => _objects.containsKey(id);

  /// The pack bytes alone, for a caller that only has to send them.
  Uint8List build() => buildWithIndex().bytes;

  /// The pack, with the offsets and checksums its index needs.
  BuiltPack buildWithIndex() {
    final body = BytesBuilder();
    final written = <PackedObject>[];

    body.add(const [0x50, 0x41, 0x43, 0x4b]); // 'PACK'
    body.add(_uint32(2)); // version
    body.add(_uint32(_objects.length));

    for (final entry in _objects.entries) {
      final offset = body.length;
      // The CRC covers the entry as written — header and compressed data
      // together — because that is the unit a repack copies.
      final header = _objectHeader(entry.value.kind, entry.value.content.length);
      final compressed = zlib.encode(entry.value.content);
      body
        ..add(header)
        ..add(compressed);

      written.add(PackedObject(
        id: entry.key,
        offset: offset,
        crc32: getCrc32(compressed, getCrc32(header)),
      ));
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
    );
  }

  static Uint8List _uint32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value);

  /// The type in bits 4 to 6 of the first byte, then the size seven bits at a
  /// time — four in the first byte, because the type took the room.
  static Uint8List _objectHeader(ObjectKind kind, int size) {
    final type = switch (kind) {
      ObjectKind.commit => 1,
      ObjectKind.tree => 2,
      ObjectKind.blob => 3,
      ObjectKind.tag => 4,
    };

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
}
