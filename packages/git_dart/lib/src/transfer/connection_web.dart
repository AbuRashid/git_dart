/// The ssh and git-daemon transports in a browser, which can neither start a
/// process nor open a raw socket.
///
/// The same names as `connection_io.dart`, so code that mentions them compiles
/// for the web; opening one fails with an error that says why.
library;

import 'connection.dart';
import 'pkt_line.dart';

Never _unavailable(String transport) => throw UnsupportedError(
      '$transport needs dart:io, which a browser does not have; '
      'use an HTTP(S) remote instead',
    );

class SshConnection implements PacketConnection {
  SshConnection._();

  String get diagnostics => '';

  /// See [splitSshCommand].
  static List<String> splitCommand(String command) => splitSshCommand(command);

  static Future<SshConnection> open(
    SshTarget target,
    String service, {
    String sshCommand = 'ssh',
    bool requestVersion2 = true,
  }) async =>
      _unavailable('ssh');

  @override
  void send(List<int> bytes) => _unavailable('ssh');

  @override
  Future<void> flush() => _unavailable('ssh');

  @override
  Future<PktLine?> receive() => _unavailable('ssh');

  @override
  Stream<List<int>> get remaining => _unavailable('ssh');

  @override
  Future<void> close() async {}
}

class DaemonConnection implements PacketConnection {
  DaemonConnection._();

  static Future<DaemonConnection> open(
    Uri url,
    String service, {
    bool requestVersion2 = true,
  }) async =>
      _unavailable('git://');

  @override
  void send(List<int> bytes) => _unavailable('git://');

  @override
  Future<void> flush() => _unavailable('git://');

  @override
  Future<PktLine?> receive() => _unavailable('git://');

  @override
  Stream<List<int>> get remaining => _unavailable('git://');

  @override
  Future<void> close() async {}
}
