import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibDecoder, ZLibEncoder;

/// Pure-Dart compression, for a browser.
///
/// `ZLibEncoder` writes the zlib header and the trailing Adler-32 itself, so
/// what comes out is the same shape `dart:io` produces and git reads — the
/// difference is speed, not format.
Uint8List deflate(List<int> bytes) =>
    Uint8List.fromList(const ZLibEncoder().encode(bytes));

Uint8List inflate(List<int> bytes) =>
    Uint8List.fromList(const ZLibDecoder().decodeBytes(bytes));
