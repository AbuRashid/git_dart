import 'dart:typed_data';

import 'package:archive/archive.dart'
    show Inflate, InputStream, ZLibDecoder, ZLibEncoder;

/// Pure-Dart compression, for a browser.
///
/// `ZLibEncoder` writes the zlib header and the trailing Adler-32 itself, so
/// what comes out is the same shape `dart:io` produces and git reads — the
/// difference is speed, not format.
Uint8List deflate(List<int> bytes) =>
    Uint8List.fromList(const ZLibEncoder().encode(bytes));

Uint8List inflate(List<int> bytes) =>
    Uint8List.fromList(const ZLibDecoder().decodeBytes(bytes));

/// The two bytes of zlib framing before the deflate stream itself.
const int _zlibHeader = 2;

/// Stops at [expectedSize], which `Inflate.buffer` takes directly — it is the
/// reason this package's inflate is the pure-Dart one rather than a wrapper
/// over something that insists on knowing where the input ends.
Uint8List inflateExactly(List<int> bytes, int expectedSize) {
  final all = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final input = InputStream(Uint8List.sublistView(all, _zlibHeader));
  final out = Inflate.buffer(input, expectedSize).getBytes();

  if (out.length < expectedSize) {
    throw FormatException(
      'the stream ended after ${out.length} bytes, its header said '
      '$expectedSize',
    );
  }
  return out.length == expectedSize
      ? Uint8List.fromList(out)
      : Uint8List.fromList(out.sublist(0, expectedSize));
}

/// Stops at [limit], and is content with a stream that ends before it.
Uint8List inflateAtMost(List<int> bytes, int limit) {
  final all = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final input = InputStream(Uint8List.sublistView(all, _zlibHeader));
  final out = Inflate.buffer(input, limit).getBytes();
  return out.length <= limit
      ? Uint8List.fromList(out)
      : Uint8List.fromList(out.sublist(0, limit));
}
