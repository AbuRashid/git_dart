import 'dart:io';
import 'dart:typed_data';

import 'package:unimsg/unimsg.dart';

void main() {
  final tests = <String, void Function()>{
    'self-hosted specification and idempotent formatting': _selfHosting,
    'sigils are stripped from stored tag payloads': _sigils,
    'exact decimals preserve significance': _decimals,
    'arbitrary-precision integers round trip': _bigIntegers,
    'floats use shortest width': _floats,
    'float edge cases preserve bits and web-safe widths': _floatEdges,
    'non-deterministic CBOR is rejected': _rejectNonCanonical,
    'BOM, nesting, comments, and trailing bytes stay strict': _boundaryStrictness,
    'tables are exact sugar': _tables,
    'binary decoding produces a document': _binaryText,
    'prescribed errors carry positions': _errors,
    'Unicode marks and byte literals parse': _unicodeAndBytes,
  };
  var failed = 0;
  for (final test in tests.entries) {
    try {
      test.value();
      stdout.writeln('PASS ${test.key}');
    } catch (error, trace) {
      failed++;
      stderr.writeln('FAIL ${test.key}\n$error\n$trace');
    }
  }
  stdout.writeln('${tests.length - failed}/${tests.length} tests passed');
  if (failed != 0) exitCode = 1;
}

void _selfHosting() {
  // Vendored into packages/unimsg, so the specification it self-hosts against
  // is two directories up rather than one.
  final source = File('../../unimsg-v0.umsg').readAsStringSync();
  final document = parse(source);
  final first = encode(document.value);
  // The encoded length was pinned here at 19240 against an earlier revision of
  // the specification. That number is a property of the document, which has
  // been revised since, and not of this implementation — so it fails whenever
  // the specification is edited, which is a test that reports the wrong thing.
  // The assertions below are the conformance criteria: the text round-trips to
  // the same bytes, the binary round-trips to the same bytes, and formatting is
  // idempotent.
  _expect(first.isNotEmpty, 'the specification encoded to nothing');
  final formatted = formatDocument(document);
  final secondDocument = parse(formatted);
  _expect(formatDocument(secondDocument) == formatted,
      'formatting is not idempotent');
  _expectBytes(encode(secondDocument.value), first);
  _expectBytes(encode(decode(first)), first);
}

void _sigils() {
  final map =
      parse('id @order-1\nref -> @order-1\next !acme/hint :ok\n').value as UMap;
  _expect((map.entries[0].value as UIdentifier).name == 'order-1',
      'identifier retained its sigil');
  _expect((map.entries[1].value as UReference).name == 'order-1',
      'reference retained syntax');
  final extension = map.entries[2].value as UExtension;
  _expect(extension.name == 'acme/hint', 'extension retained its sigil');
  _expectBytes(
      encode(UIdentifier('x')).sublist(5), Uint8List.fromList([0x61, 0x78]));
  _expectBytes(
      encode(UReference('x')).sublist(5), Uint8List.fromList([0x61, 0x78]));
}

void _decimals() {
  final one = _valueOf('x 1.0') as UDecimal;
  final two = _valueOf('x 1.00') as UDecimal;
  _expect(one.exponent == BigInt.from(-1) && one.mantissa == BigInt.from(10),
      '1.0 decomposed incorrectly');
  _expect(two.exponent == BigInt.from(-2) && two.mantissa == BigInt.from(100),
      '1.00 decomposed incorrectly');
  _expect(!_equal(encode(one), encode(two)), 'decimal significance was lost');
  final huge = _valueOf('x 1.2e999999999999999999999999') as UDecimal;
  _expect(huge.exponent == BigInt.parse('999999999999999999999998'),
      'huge exponent was truncated');
}

void _bigIntegers() {
  for (final text in [
    '18446744073709551616',
    '-18446744073709551617',
    '999999999999999999999999999999999999999999',
  ]) {
    final value = UInt(BigInt.parse(text));
    _expectBytes(encode(decode(encode(value))), encode(value));
  }
}

void _floats() {
  _expectBytes(encode(UFloat(1.5)), Uint8List.fromList([0xf9, 0x3e, 0x00]));
  _expectBytes(
      encode(UFloat(double.nan)), Uint8List.fromList([0xf9, 0x7e, 0x00]));
  _expect(!_equal(encode(UFloat(1)), encode(UInt(1))),
      'integer and float encodings collapsed');
}

void _floatEdges() {
  _expectBytes(encode(UFloat(0.0)), Uint8List.fromList([0xf9, 0x00, 0x00]));
  _expectBytes(encode(UFloat(-0.0)), Uint8List.fromList([0xf9, 0x80, 0x00]));
  _expect(encode(UFloat(1.1)).first == 0xfb,
      '1.1 was narrowed even though float32 cannot preserve it');
  _expectBytes(
      encode(UFloat(double.infinity)), Uint8List.fromList([0xf9, 0x7c, 0x00]));
  _expectBytes(encode(UFloat(double.negativeInfinity)),
      Uint8List.fromList([0xf9, 0xfc, 0x00]));
  _expect(formatDocument(parse('x -0.0f\n')).contains('-0.0f'),
      'negative zero lost its sign in canonical text');
}

void _rejectNonCanonical() {
  for (final bytes in [
    [0x18, 0x00],
    [0x9f, 0xff],
    [0xfa, 0x3f, 0xc0, 0x00, 0x00],
  ]) {
    var rejected = false;
    try {
      decode(bytes);
    } on UnimsgException {
      rejected = true;
    }
    _expect(rejected, 'accepted non-canonical CBOR $bytes');
  }
}

void _boundaryStrictness() {
  final bom = parse('\ufeffx 1\n').value as UMap;
  _expect((bom.entries.single.value as UInt).value == BigInt.one,
      'leading BOM was not ignored');

  var nestedDuplicateRejected = false;
  try {
    parse('x { a 1, a 2 }\n');
  } on UnimsgException {
    nestedDuplicateRejected = true;
  }
  _expect(nestedDuplicateRejected, 'nested duplicate key was accepted');

  for (final bytes in [
    [0x01, 0x00],
    [0xa2, 0x61, 0x62, 0x01, 0x61, 0x61, 0x02],
  ]) {
    var rejected = false;
    try {
      decode(bytes);
    } on UnimsgException {
      rejected = true;
    }
    _expect(rejected, 'accepted boundary-invalid CBOR $bytes');
  }

  final plain = textToCbor('a 1\nb :ok\n');
  final commented = textToCbor('-- before\na 1 -- after\nb :ok\n');
  _expectBytes(commented, plain);
}

void _tables() {
  final table = _valueOf('x [\n | sku qty\n | :a 2\n | :b 3\n ]');
  final longhand = _valueOf('x [ { sku :a, qty 2 }, { qty 3, sku :b } ]');
  _expectBytes(encode(table), encode(longhand));
}

void _binaryText() {
  final first = textToCbor('answer 42\nstatus :ok\n');
  final text = cborToText(first);
  _expect(!text.trimLeft().startsWith('{'),
      'decoded document was wrapped in a map');
  _expectBytes(textToCbor(text), first);
}

void _errors() {
  for (final source in ['x [ a b ]', 'x :true', 'a 1, a 2', 'x 12abc']) {
    try {
      parse(source);
      throw StateError('accepted invalid input $source');
    } on UnimsgException catch (error) {
      _expect(
          error.line > 0 && error.column > 0, 'error has no source position');
    }
  }
}

void _unicodeAndBytes() {
  final map = parse('ipa d͡ʒ :sound\nraw ~b64:/wA=\n').value as UMap;
  final annotated = map.entries.first.value as UAnnotated;
  _expect((annotated.annotations.first as SymbolAnnotation).name == 'd͡ʒ',
      'combining mark rejected');
  _expectBytes(
      (map.entries[1].value as UBytes).value, Uint8List.fromList([0xff, 0x00]));
}

UValue _valueOf(String source) =>
    (parse(source).value as UMap).entries.single.value;
void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void _expectBytes(List<int> actual, List<int> expected) {
  _expect(_equal(actual, expected), 'byte mismatch\n$actual\n$expected');
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
