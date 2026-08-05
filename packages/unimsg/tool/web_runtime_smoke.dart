// ignore_for_file: avoid_print
import 'package:unimsg/unimsg.dart';

void main() {
  final values = <UValue>[
    const UFloat(0.0),
    const UFloat(-0.0),
    const UFloat(1.5),
    const UFloat(1.1),
    const UFloat(double.nan),
    const UFloat(double.infinity),
  ];
  for (final value in values) {
    final bytes = encode(value);
    if (encode(decode(bytes)).length != bytes.length) {
      throw StateError('float failed deterministic JavaScript round-trip');
    }
  }
  print('UNIMSG_WEB_RUNTIME_OK');
}
