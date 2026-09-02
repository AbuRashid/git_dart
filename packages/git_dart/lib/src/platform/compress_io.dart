import 'dart:io';
import 'dart:typed_data';

/// The platform's own zlib, which is native code and considerably faster than
/// anything written in Dart. Used wherever `dart:io` exists.
Uint8List deflate(List<int> bytes) => Uint8List.fromList(zlib.encode(bytes));

Uint8List inflate(List<int> bytes) => Uint8List.fromList(zlib.decode(bytes));
