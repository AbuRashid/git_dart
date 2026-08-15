import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pkt_line.dart';

/// A two-way pkt-line conversation with a server.
///
/// Smart HTTP is request-and-response: each exchange is a separate POST and
/// the server keeps nothing between them. Every other transport — ssh, the git
/// daemon — is a single open connection that both sides talk over until it
/// ends. This is the second shape, and it is the simpler one: what makes HTTP
/// awkward is not the protocol but having to re-send the whole conversation
/// each time.
abstract class PacketConnection {
  /// Writes bytes to the server.
  ///
  /// Queued, not sent: see [flush].
  void send(List<int> bytes);

  /// Pushes everything [send] queued out to the server.
  ///
  /// A sink buffers, and both sides of this protocol wait for the other. Sent
  /// bytes still sitting in a local buffer are bytes the server is waiting for
  /// while we wait for its reply, which is a deadlock and looks exactly like a
  /// hung network. Every write that expects an answer has to be flushed before
  /// the answer is read.
  Future<void> flush();

  /// The next packet, or null when the server has finished speaking.
  Future<PktLine?> receive();

  /// Everything still to come, unframed — the packfile, once the packets
  /// before it have been read.
  Stream<List<int>> get remaining;

  Future<void> close();
}

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

  /// Splits a command into a program and its leading arguments.
  ///
  /// Git lets `core.sshCommand` and `GIT_SSH_COMMAND` carry arguments —
  /// `ssh -F /path/to/config`, `ssh -i key` — and splits them as a shell
  /// would. Treating the whole string as a program name works only for the
  /// one-word case and fails on every configuration anyone actually writes.
  static List<String> splitCommand(String command) {
    final words = <String>[];
    final current = StringBuffer();
    String? quote;

    for (final rune in command.runes) {
      final character = String.fromCharCode(rune);
      if (quote != null) {
        if (character == quote) {
          quote = null;
        } else {
          current.write(character);
        }
        continue;
      }
      if (character == '"' || character == "'") {
        quote = character;
        continue;
      }
      if (character == ' ' || character == '\t') {
        if (current.isNotEmpty) {
          words.add(current.toString());
          current.clear();
        }
        continue;
      }
      current.write(character);
    }
    if (current.isNotEmpty) words.add(current.toString());
    return words;
  }

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

/// Where an ssh URL points.
class SshTarget {
  final String? user;
  final String host;
  final int? port;
  final String path;

  const SshTarget({
    required this.host,
    required this.path,
    this.user,
    this.port,
  });

  /// Parses both spellings git accepts.
  ///
  /// `ssh://[user@]host[:port]/path` is a URL. `[user@]host:path` is the older
  /// scp-style form, which has no scheme and whose colon separates the host
  /// from a path rather than from a port — so `host:1234/x` is a *path*
  /// beginning `1234`, not port 1234. Git resolves that the same way and it
  /// catches everyone once.
  static SshTarget? parse(String url) {
    if (url.startsWith('ssh://')) {
      final uri = Uri.parse(url);
      if (uri.host.isEmpty) return null;
      return SshTarget(
        user: uri.userInfo.isEmpty ? null : uri.userInfo,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path.startsWith('/') ? uri.path.substring(1) : uri.path,
      );
    }

    // scp-style. A scheme rules it out, and so does a single character before
    // the colon, which is a Windows drive letter.
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) return null;
    final colon = url.indexOf(':');
    if (colon <= 1) return null;

    final before = url.substring(0, colon);
    final at = before.indexOf('@');
    return SshTarget(
      user: at < 0 ? null : before.substring(0, at),
      host: at < 0 ? before : before.substring(at + 1),
      path: url.substring(colon + 1),
    );
  }

  @override
  String toString() =>
      'ssh://${user == null ? '' : '$user@'}$host'
      '${port == null ? '' : ':$port'}/$path';
}

/// Opens whichever connection [url] calls for, or null when it names a
/// transport that is not one of these.
Future<PacketConnection?> connectTo(
  String url,
  String service, {
  String sshCommand = 'ssh',
}) async {
  if (url.startsWith('git://')) {
    return DaemonConnection.open(Uri.parse(url), service);
  }
  final ssh = SshTarget.parse(url);
  if (ssh != null) {
    return SshConnection.open(ssh, service, sshCommand: sshCommand);
  }
  return null;
}
