import 'dart:io';
import 'dart:typed_data';

/// The platform's own zlib, which is native code and considerably faster than
/// anything written in Dart. Used wherever `dart:io` exists.
Uint8List deflate(List<int> bytes) => Uint8List.fromList(zlib.encode(bytes));

Uint8List inflate(List<int> bytes) => Uint8List.fromList(zlib.decode(bytes));

/// Stops at [expectedSize] rather than at the end of [bytes], which may hold
/// whatever followed the stream in the pack.
Uint8List inflateExactly(List<int> bytes, int expectedSize) {
  final filter = RawZLibFilter.inflateFilter();
  final out = BytesBuilder(copy: false);

  filter.process(bytes is Uint8List ? bytes : Uint8List.fromList(bytes), 0,
      bytes.length);
  List<int>? produced;
  while ((produced = filter.processed(flush: false)) != null) {
    out.add(produced!);
    if (out.length >= expectedSize) break;
  }

  final result = out.takeBytes();
  if (result.length < expectedSize) {
    throw FormatException(
      'the stream ended after ${result.length} bytes, its header said '
      '$expectedSize',
    );
  }
  // Trailing bytes are whatever the pack held after this object.
  return result.length == expectedSize
      ? result
      : Uint8List.sublistView(result, 0, expectedSize);
}

/// Stops at [limit], and is content with a stream that ends before it.
Uint8List inflateAtMost(List<int> bytes, int limit) {
  final filter = RawZLibFilter.inflateFilter();
  final out = BytesBuilder(copy: false);

  filter.process(
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    0,
    bytes.length,
  );
  List<int>? produced;
  while ((produced = filter.processed(flush: false)) != null) {
    out.add(produced!);
    if (out.length >= limit) break;
  }

  final result = out.takeBytes();
  return result.length <= limit
      ? result
      : Uint8List.sublistView(result, 0, limit);
}
