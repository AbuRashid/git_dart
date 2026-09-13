// Reusable asynchronous bridge to Android native crypto/custody/private files.
import 'package:flutter/services.dart';
import 'dart:typed_data';
class AndroidSecureHost {
  final MethodChannel channel;
  const AndroidSecureHost([this.channel = const MethodChannel('org.unimsg/secure-host/v1')]);
  dynamic wire(dynamic value) {
    if (value is BigInt) return value.toInt();
    if (value is Uint8List) return value;
    if (value is List) return value.map(wire).toList();
    return value;
  }
  // Platform responses may be read-only views into channel-owned memory.
  // Give callers owned buffers, including nested cryptographic results.
  dynamic owned(dynamic value) {
    if (value is Uint8List) return Uint8List.fromList(value);
    if (value is List) return value.map(owned).toList();
    if (value is Map) return value.map((key, item) => MapEntry(key, owned(item)));
    return value;
  }
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async =>
      owned(await channel.invokeMethod(method, wire(args)));
  Future<dynamic> drive(dynamic Function(dynamic) run, List<dynamic> command) async {
    var current = run(command) as List;
    while (true) {
      final effect = current[1] as List;
      if (effect[0] == 'done') return effect[1];
      if (effect[0] == 'fail') throw StateError('Encrypted document was rejected');
      List<dynamic> event;
      try { event = ['ok', await call('crypto', effect.cast<dynamic>())]; }
      catch (_) { event = ['host']; }
      current = run(['step', current[0], event]) as List;
    }
  }
}
