import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart' show Credentials;

/// Where saved credentials are kept.
///
/// Git's own credential helper, which on this machine is whatever
/// `credential.helper` names — the Windows Credential Manager, the macOS
/// keychain, libsecret, or a plain file if that is what the user configured.
///
/// Written this way rather than storing tokens in the application's own file
/// for one reason: a token in a JSON file beside the window's layout is a
/// token in plaintext, and this application has no business being the first
/// place on a machine that keeps one. The helper is the store the user already
/// trusts with the same secret for the same host, and it is what git itself
/// would use.
///
/// When no helper is configured, nothing is saved and the user is asked each
/// time — which is worse to use and better than the alternative.
class CredentialStore {
  /// Held for the life of the process, so one prompt covers a session even
  /// where nothing can be saved.
  final _session = <String, Credentials>{};

  static String keyFor(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return '${uri.scheme}://${uri.host}:${uri.port}';
  }

  Credentials? remembered(String url) => _session[keyFor(url)];

  void rememberForSession(String url, Credentials credentials) {
    _session[keyFor(url)] = credentials;
  }

  void forget(String url) => _session.remove(keyFor(url));

  /// Whether a helper is configured, and so whether saving is possible.
  Future<bool> canSave() async {
    try {
      final result = await Process.run('git', ['config', '--get', 'credential.helper']);
      return result.exitCode == 0 &&
          result.stdout.toString().trim().isNotEmpty;
    } on ProcessException {
      return false;
    }
  }

  /// Asks the helper for a stored secret. Null when it has none, or when
  /// there is no helper to ask.
  Future<Credentials?> lookup(String url) async {
    final session = remembered(url);
    if (session != null) return session;

    final answer = await _run('fill', url);
    if (answer == null) return null;

    final username = answer['username'];
    final password = answer['password'];
    if (username == null || password == null) return null;

    final credentials = Credentials(username: username, password: password);
    rememberForSession(url, credentials);
    return credentials;
  }

  /// Stores a secret that worked.
  Future<bool> save(String url, Credentials credentials) async {
    rememberForSession(url, credentials);
    final answer = await _run('approve', url, credentials: credentials);
    return answer != null;
  }

  /// Tells the helper to drop a secret that was refused, so the next attempt
  /// asks rather than failing again with the same rejected token.
  Future<void> discard(String url, Credentials credentials) async {
    forget(url);
    await _run('reject', url, credentials: credentials);
  }

  Future<Map<String, String>?> _run(
    String action,
    String url, {
    Credentials? credentials,
  }) async {
    // Anything that is not an http(s) URL has no credential of this kind, and
    // an ssh-style `git@host:path` cannot even be parsed as one.
    if (!url.startsWith('http://') && !url.startsWith('https://')) return null;
    final uri = Uri.parse(url);
    final input = StringBuffer()
      ..writeln('protocol=${uri.scheme}')
      ..writeln('host=${uri.hasPort ? '${uri.host}:${uri.port}' : uri.host}');
    if (uri.path.isNotEmpty && uri.path != '/') {
      input.writeln('path=${uri.path.replaceFirst('/', '')}');
    }
    if (credentials != null) {
      input
        ..writeln('username=${credentials.username}')
        ..writeln('password=${credentials.password}');
    }
    input.writeln();

    try {
      final process = await Process.start('git', ['credential', action]);
      process.stdin.write(input.toString());
      await process.stdin.close();

      final output = await process.stdout.transform(utf8.decoder).join();
      await process.stderr.drain<void>();
      final code = await process.exitCode;
      if (code != 0) return null;

      final fields = <String, String>{};
      for (final line in const LineSplitter().convert(output)) {
        final equals = line.indexOf('=');
        if (equals > 0) {
          fields[line.substring(0, equals)] = line.substring(equals + 1);
        }
      }
      return fields;
    } on ProcessException {
      // No git on the path: nothing can be looked up or saved, and the
      // application asks every time instead.
      return null;
    }
  }
}
