# unimsg implementation stability cases

These cases were identified while integrating unimsg with a Flutter web port.
They complement the normative vectors in `unimsg-v0.umsg`; portable vectors
should eventually move into that specification so every implementation runs
the same corpus.

## Added in this package

| ID | Case | Expected result | Guards against |
|---|---|---|---|
| U-S01 | Compile `tool/web_runtime_smoke.dart` with dart2js and execute it | `UNIMSG_WEB_RUNTIME_OK` | `ByteData.getUint64` and 64-bit bitwise code that compiles for web but throws or truncates at runtime |
| U-S02 | Encode `0.0f` and `-0.0f` | `f90000` and `f98000`; canonical text retains `-0.0f` | signed zero collapsing through host-language equality |
| U-S03 | Encode `1.5f`, `1.1f`, infinities, and NaN | shortest exact width; canonical NaN | toolkit/default float widening and non-deterministic NaN payloads |
| U-S04 | Parse a leading UTF-8 BOM | BOM ignored; following document unchanged | editor-added BOM becoming content or a parse failure |
| U-S05 | Parse a duplicate key inside a nested map | rejected with a positioned error | duplicate checking applied only to the top-level map |
| U-S06 | Decode a valid item followed by another byte | rejected as trailing data | prefix-only decoders accepting ambiguous messages |
| U-S07 | Decode a map whose keys are in non-canonical byte order | rejected | a decoder silently repairing deterministic input |
| U-S08 | Encode a document with leading and trailing comments | identical CBOR to the uncommented document | comments leaking into content-addressed bytes |

The native conformance runner now covers U-S02 through U-S08. U-S01 must be a
separate CI job because compiling JavaScript is insufficient: the generated
program has to execute in Node or a browser.

## Recommended additions to the shared corpus

| ID | Case | Expected result | Why it matters |
|---|---|---|---|
| U-R01 | Integer boundaries at 23/24, 255/256, 65535/65536, 2^32−1/2^32, and 2^64−1/2^64, positive and negative | shortest core integer or bignum tag | boundary errors are usually one byte and remain internally round-trippable |
| U-R02 | Decimal forms `0.0`, `-0.0`, `1e+0`, `1.2300`, and huge positive/negative exponents | written mantissa and exponent preserved | significance is part of the value, unlike ordinary numeric equality |
| U-R03 | Timestamp month/date/minute/second/fraction variants with `Z` and signed offsets | literal reproduced verbatim | timestamp precision and observer offset are information |
| U-R04 | Quoted table headers, a combining-mark header, row underflow, and row overflow | valid headers equal longhand; wrong cell counts fail at the row | table sugar has historically produced misleading errors |
| U-R05 | Duplicate keys that differ in Unicode normalization only | both remain distinct | v0 explicitly performs no normalization |
| U-R06 | Unknown escapes, reserved sigils, malformed numbers, and reserved words used as symbols | positioned error naming the fix where prescribed | prevents permissive lexer drift between implementations |
| U-R07 | Comment binding before/after values through canonical reordering | comments move with their pair; formatting is idempotent | a correct value with the wrong comment is a semantic documentation bug |
| U-R08 | Nesting at the supported maximum and one level beyond | maximum succeeds; next level fails without stack exhaustion | total, side-effect-free decoding includes adversarial depth |
| U-R09 | Every tag with the wrong content shape | rejected at the tag offset | generic tag decoders otherwise admit values no encoder can emit |
| U-R10 | Random valid values encoded by two implementations plus single-byte mutations | byte-identical encodings; mutated non-canonical inputs rejected | broad differential coverage beyond hand-selected examples |

When `unimsg-v0.umsg` changes, update the self-hosted encoding-length sentinel
only after the idempotent format and byte-identical decode/re-encode checks pass.
The sentinel detects corpus drift; it is not itself a semantic conformance rule.
