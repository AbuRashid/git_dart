import 'dart:typed_data';

/// The name of an object: the SHA-1 of its serialised form.
///
/// Held as the twenty raw bytes, because that is what a tree entry and a pack
/// index store. Hex is a rendering, not the value — see `objects.tree-entry`
/// in systems/git/v0.
class ObjectId implements Comparable<ObjectId> {
  static const int byteLength = 20;
  static const int hexLength = byteLength * 2;

  final Uint8List bytes;

  ObjectId(this.bytes) {
    if (bytes.length != byteLength) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'an object name is $byteLength bytes',
      );
    }
  }

  /// The all-zero name, used by git to mean "no object" in a reflog line or a
  /// ref update.
  static final ObjectId zero = ObjectId(Uint8List(byteLength));

  factory ObjectId.fromHex(String hex) {
    if (hex.length != hexLength) {
      throw FormatException(
        'an object name is $hexLength hex characters, got ${hex.length}',
        hex,
      );
    }
    final out = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) {
        throw FormatException('not hexadecimal', hex, i * 2);
      }
      out[i] = byte;
    }
    return ObjectId(out);
  }

  /// Reads a name from [source] at [offset]; the twenty raw bytes are copied,
  /// so the result does not alias a buffer the caller may reuse.
  factory ObjectId.fromBytes(List<int> source, [int offset = 0]) =>
      ObjectId(Uint8List.fromList(source.sublist(offset, offset + byteLength)));

  static const _hexDigits = '0123456789abcdef';

  String get hex {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(_hexDigits[byte >> 4]);
      buffer.write(_hexDigits[byte & 0x0f]);
    }
    return buffer.toString();
  }

  bool get isZero => bytes.every((b) => b == 0);

  @override
  int compareTo(ObjectId other) {
    for (var i = 0; i < byteLength; i++) {
      final d = bytes[i] - other.bytes[i];
      if (d != 0) return d;
    }
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is ObjectId && compareTo(other) == 0;

  @override
  int get hashCode {
    // The name is already a hash; the first four bytes are as good as any.
    return bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3];
  }

  @override
  String toString() => hex;
}
