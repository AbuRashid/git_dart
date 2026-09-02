/// Reading and writing the 64-bit big-endian fields git's formats use.
///
/// `ByteData.getUint64` exists on every platform except the web: JavaScript has
/// no 64-bit integer, so dart2js refuses with `Uint64 accessor not supported`.
/// The values in question — an offset into a pack, an offset into a
/// commit-graph — are file positions, so they sit far below the 2^53 a double
/// represents exactly. Reading them as two 32-bit halves is therefore not a
/// compromise: it is the same number, and it works everywhere.
library;

import 'dart:typed_data';

/// The 64-bit big-endian value at [offset].
int readUint64(ByteData data, int offset) {
  final high = data.getUint32(offset);
  final low = data.getUint32(offset + 4);
  return high * 0x100000000 + low;
}

/// Writes [value] as 64 bits, big-endian.
void writeUint64(ByteData data, int offset, int value) {
  // `~/` rather than `>>` because a shift past 32 bits is not meaningful in
  // JavaScript, where these are doubles.
  data.setUint32(offset, value ~/ 0x100000000);
  data.setUint32(offset + 4, value % 0x100000000);
}
