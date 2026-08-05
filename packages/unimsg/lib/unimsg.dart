library;

import 'dart:convert';
import 'dart:typed_data';

part 'src/model.dart';
part 'src/parser.dart';
part 'src/cbor.dart';
part 'src/format.dart';

Uint8List textToCbor(String source) => encode(parse(source).value);

String cborToText(List<int> bytes) {
  final value = decode(bytes);
  if (value is! UMap) {
    throw const UnimsgException(
      'a unimsg document must decode to a top-level map',
      1,
      1,
    );
  }
  return formatDocument(UnimsgDocument(null, value));
}
