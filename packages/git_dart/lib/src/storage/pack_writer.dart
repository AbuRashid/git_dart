import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../object_id.dart';
import '../objects/git_object.dart';

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

  Uint8List build() {
    final body = BytesBuilder();

    body.add(const [0x50, 0x41, 0x43, 0x4b]); // 'PACK'
    body.add(_uint32(2)); // version
    body.add(_uint32(_objects.length));

    for (final object in _objects.values) {
      body.add(_objectHeader(object.kind, object.content.length));
      body.add(zlib.encode(object.content));
    }

    final bytes = body.takeBytes();
    // The file ends with the hash of everything before it.
    final checksum = sha1.convert(bytes).bytes;

    return Uint8List(bytes.length + ObjectId.byteLength)
      ..setRange(0, bytes.length, bytes)
      ..setRange(bytes.length, bytes.length + ObjectId.byteLength, checksum);
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
