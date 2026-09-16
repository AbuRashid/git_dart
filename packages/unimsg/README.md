# unimsg v0 — pure Dart

A dependency-free Dart implementation of the provisional format described by
[`../../specs/unimsg-v0.umsg`](../../specs/unimsg-v0.umsg). It provides a parser,
canonical formatter, deterministic CBOR encoder, strict CBOR decoder, library
API, and command-line tool.

## Commands

```text
dart pub get
dart run unimsg help
dart run unimsg check ../../specs/unimsg-v0.umsg
dart run unimsg encode message.umsg -o message.cbor
dart run unimsg decode message.cbor -o message.umsg
dart run unimsg format message.umsg
dart test/conformance.dart
dart compile js tool/web_runtime_smoke.dart -o build/web_runtime_smoke.js
node build/web_runtime_smoke.js
```

Omit an input path to read standard input. `format --check` exits
unsuccessfully when the input is not canonical.

## Library

```dart
import 'package:unimsg/unimsg.dart';

final document = parse('status :dispatched\n');
final bytes = encode(document.value);
final decoded = decode(bytes);
assert(encode(decoded).length == bytes.length);

final canonical = formatDocument(document);   // or formatValue(value)
final cbor = textToCbor('status :dispatched\n');
final text = cborToText(cbor);
```

Every failure is a `UnimsgException` carrying the line and column (or byte
offset) it was found at. Nesting is limited to `maxDepth` (1024) levels in the
parser, the formatter and both codecs. Comments written above a pair are kept
on its `MapEntry`; a `UnimsgDocument` holds the header and the value.

The implementation uses only `dart:convert` and `dart:typed_data`. Values use
`BigInt` for arbitrary-precision integers and decimal components. The decoder
rejects non-shortest numbers, indefinite lengths, and non-canonical map order
by comparing every accepted input with its deterministic re-encoding.

See `STABILITY_TESTS.md` for the regression cases added during the Flutter web
integration and the next cases recommended for the shared conformance corpus.
