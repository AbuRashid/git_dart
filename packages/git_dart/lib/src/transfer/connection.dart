import 'connection_io.dart' if (dart.library.js_interop) 'connection_web.dart';
import 'pkt_line.dart';

export 'connection_io.dart' if (dart.library.js_interop) 'connection_web.dart';

/// A two-way pkt-line conversation with a server.
///
/// Smart HTTP is request-and-response: each exchange is a separate POST and
/// the server keeps nothing between them. Every other transport — ssh, the git
/// daemon — is a single open connection that both sides talk over until it
/// ends. This is the second shape, and it is the simpler one: what makes HTTP
/// awkward is not the protocol but having to re-send the whole conversation
/// each time.
///
/// Both of those transports need `dart:io`, so their implementations —
/// [SshConnection] and [DaemonConnection] — come from `connection_io.dart`, and
/// in a browser from stand-ins that refuse to open.
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

/// Splits a command into a program and its leading arguments.
///
/// Git lets `core.sshCommand` and `GIT_SSH_COMMAND` carry arguments —
/// `ssh -F /path/to/config`, `ssh -i key` — and splits them as a shell
/// would. Treating the whole string as a program name works only for the
/// one-word case and fails on every configuration anyone actually writes.
List<String> splitSshCommand(String command) {
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
///
/// [requestVersion2] is for fetches. A push turns it off, as git's own client
/// does: `git-receive-pack` has no version 2, so there is nothing to ask for.
Future<PacketConnection?> connectTo(
  String url,
  String service, {
  String sshCommand = 'ssh',
  bool requestVersion2 = true,
}) async {
  if (url.startsWith('git://')) {
    return DaemonConnection.open(
      Uri.parse(url),
      service,
      requestVersion2: requestVersion2,
    );
  }
  final ssh = SshTarget.parse(url);
  if (ssh != null) {
    return SshConnection.open(
      ssh,
      service,
      sshCommand: sshCommand,
      requestVersion2: requestVersion2,
    );
  }
  return null;
}
