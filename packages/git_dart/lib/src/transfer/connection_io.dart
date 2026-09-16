/// The ssh and git-daemon transports, which need `dart:io`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'connection.dart';
import 'pkt_line.dart';

/// Reads packets out of a byte stream, holding back a partial one.
class _PacketReader {
  final StreamIterator<List<int>> _chunks;
  final _reader = PktLineStreamReader();
  final _ready = <PktLine>[];
  var _done = false;

  /// Bytes that arrived after the caller stopped asking for packets.
  final _leftover = BytesBuilder();

  _PacketReader(Stream<List<int>> source)
      : _chunks = StreamIterator(source.map((c) => c));

  Future<PktLine?> next() async {
    while (_ready.isEmpty) {
      if (_done) return null;
      if (!await _chunks.moveNext()) {
        _done = true;
        return null;
      }
      _ready.addAll(_reader.add(_chunks.current));
    }
    return _ready.removeAt(0);
  }

  /// Whatever is left, once packet reading stops.
  Stream<List<int>> rest() async* {
    // Anything already decoded into packets is re-encoded: the caller has
    // stopped treating the stream as framed, so it wants the bytes back as
    // they were.
    for (final packet in _ready) {
      yield packet.encode();
    }
    _ready.clear();

    final held = _leftover.takeBytes();
    if (held.isNotEmpty) yield held;

    while (!_done && await _chunks.moveNext()) {
      yield _chunks.current;
    }
    _done = true;
  }

  Future<void> cancel() => _chunks.cancel();
}

/// A connection over an `ssh` subprocess.
///
/// The server side of git over ssh is just `git-upload-pack <path>` run on the
/// far end with its input and output attached to the connection. There is no
/// git-specific protocol layer above ssh at all: ssh moves bytes, and the same
/// pkt-line conversation happens over them. That is why any host with git and
/// an ssh account can serve repositories without running anything else.
class SshConnection implements PacketConnection {
  final Process process;
  late final _PacketReader _reader = _PacketReader(process.stdout);

  SshConnection(this.process) {
    // Drained, or a full stderr pipe blocks the far end for ever. ssh puts
    // its own diagnostics here, so it is kept for the error message.
    process.stderr.transform(utf8.decoder).listen(_stderr.write);
  }

  final _stderr = StringBuffer();

  /// What ssh said on its error channel, which is where a refused key or a
  /// missing repository is explained.
  String get diagnostics => _stderr.toString().trim();

  /// See [splitSshCommand].
  static List<String> splitCommand(String command) => splitSshCommand(command);

  static Future<SshConnection> open(
    SshTarget target,
    String service, {
    String sshCommand = 'ssh',
    bool requestVersion2 = true,
  }) async {
    final words = splitCommand(sshCommand);
    if (words.isEmpty) {
      throw ArgumentError.value(sshCommand, 'sshCommand', 'is empty');
    }
    final program = words.first;
    final leading = words.skip(1).toList();

    final arguments = <String>[
      ...leading,
      if (target.port != null) ...['-p', '${target.port}'],
      // Version 2 is asked for through an environment variable, which only
      // reaches the server if ssh is told to forward it and the server is
      // configured to accept it. Neither is guaranteed, so this is a request
      // and not an assumption: a server that does not receive it answers in
      // version 0 and the reply says which happened.
      if (requestVersion2) ...['-o', 'SendEnv=GIT_PROTOCOL'],
      target.user == null ? target.host : '${target.user}@${target.host}',
      // Quoted, because a path may contain spaces and the far end runs this
      // through a shell.
      "$service '${target.path}'",
    ];

    final process = await Process.start(
      program,
      arguments,
      environment: requestVersion2 ? {'GIT_PROTOCOL': 'version=2'} : null,
      includeParentEnvironment: true,
    );
    return SshConnection(process);
  }

  @override
  void send(List<int> bytes) => process.stdin.add(bytes);

  @override
  Future<void> flush() => process.stdin.flush();

  @override
  Future<PktLine?> receive() => _reader.next();

  @override
  Stream<List<int>> get remaining => _reader.rest();

  @override
  Future<void> close() async {
    try {
      await process.stdin.close();
    } catch (_) {
      // Already gone.
    }
    await _reader.cancel();
    process.kill();
  }
}

/// A connection to a git daemon, which speaks the same protocol over a bare
/// TCP socket on port 9418.
///
/// The only difference from ssh is how the conversation is started: instead of
/// running a command, the client sends one pkt-line naming the service, the
/// path, and the host. Everything after that is identical, which is the point
/// of putting the framing below the transport rather than inside it.
class DaemonConnection implements PacketConnection {
  final Socket socket;
  late final _PacketReader _reader = _PacketReader(socket);

  DaemonConnection(this.socket);

  static Future<DaemonConnection> open(
    Uri url,
    String service, {
    bool requestVersion2 = true,
  }) async {
    final socket = await Socket.connect(
      url.host,
      url.hasPort ? url.port : 9418,
    );

    // `<service> <path>\0host=<host>\0` — the NULs are inside the payload,
    // which is why this is a pkt-line and not a text line.
    final request = StringBuffer()
      ..write(service)
      ..write(' ')
      ..write(url.path)
      ..writeCharCode(0)
      ..write('host=')
      ..write(url.host)
      ..writeCharCode(0);

    // Asking for version 2 costs an extra NUL and a string. A daemon that does
    // not know it answers in version 0, so the reply is examined rather than
    // assumed.
    if (requestVersion2) {
      request
        ..writeCharCode(0)
        ..write('version=2')
        ..writeCharCode(0);
    }

    socket.add(PktLine.data(utf8.encode(request.toString())).encode());
    await socket.flush();
    return DaemonConnection(socket);
  }

  @override
  void send(List<int> bytes) => socket.add(bytes);

  @override
  Future<void> flush() => socket.flush();

  @override
  Future<PktLine?> receive() => _reader.next();

  @override
  Stream<List<int>> get remaining => _reader.rest();

  @override
  Future<void> close() async {
    await _reader.cancel();
    socket.destroy();
  }
}
