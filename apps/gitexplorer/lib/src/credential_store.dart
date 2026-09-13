import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:git_dart/git_dart.dart' show Credentials;

import 'vault/secure_host.dart';
import 'vault/vault_store.dart';

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

  /// The saved-credentials vault, on Android — the platform's own answer to
  /// "the store the user already trusts", since there is no `git` binary
  /// there for a helper to be configured in in the first place. Null until
  /// first needed, then held for the process, the same as [_session].
  VaultStore? _vault;

  VaultStore _vaultStore() => _vault ??= VaultStore(const AndroidSecureHost());

  /// Unlocks the vault if it is not already open this session.
  ///
  /// Deliberately not called from [lookup]: that runs before *every* clone,
  /// fetch and push, including ones to a public repository that was never
  /// going to need a credential, and a device-authentication prompt on every
  /// one of those would be the opposite of the point. It only ever unlocks
  /// from [save] — tied to a moment the user is already mid-authenticating —
  /// after which [lookup] can use it silently for the rest of the session.
  Future<void> _ensureVaultUnlocked() async {
    final vault = _vaultStore();
    if (vault.key != null) return;
    await vault.unlock();
  }

  /// The `[protocol, host, path]` fields the vault's Git policy matches on.
  static List<List<String>> _scopeFor(String url) {
    final uri = Uri.parse(url);
    return [
      ['protocol', uri.scheme],
      ['host', uri.hasPort ? '${uri.host}:${uri.port}' : uri.host],
      ['path', uri.path.isEmpty ? '' : uri.path.replaceFirst('/', '')],
    ];
  }

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
    // A browser has no credential helper to shell out to - there is no shell.
    // `Process` compiles here and throws the moment it actually runs, so this
    // has to be turned away before the first call rather than caught after.
    if (kIsWeb) return false;
    if (Platform.isAndroid) {
      // A cheap, unauthenticated probe: `random` never reaches the Keystore
      // or the authentication gate in the native host, so this asks only
      // whether anything answered the channel at all - true from API 33,
      // where the platform side registers it, false below that.
      try {
        await const AndroidSecureHost().call('random', [1]);
        return true;
      } on Object {
        return false;
      }
    }
    try {
      final result = await Process.run('git', ['config', '--get', 'credential.helper']);
      return result.exitCode == 0 &&
          result.stdout.toString().trim().isNotEmpty;
    } on ProcessException {
      return false;
    }
  }

  /// Asks the helper for a stored secret. Null when it has none, when there
  /// is no helper to ask, or — on Android — when the vault is not already
  /// unlocked this session (see [_ensureVaultUnlocked]).
  Future<Credentials?> lookup(String url) async {
    final session = remembered(url);
    if (session != null) return session;

    if (Platform.isAndroid) {
      final vault = _vaultStore();
      if (vault.key == null) return null;
      try {
        final fields = await vault.git('get', _scopeFor(url));
        if (fields.isEmpty) return null;
        final answer = <String, String>{
          for (final pair in fields.cast<List<dynamic>>())
            pair[0] as String: pair[1] as String,
        };
        final username = answer['username'];
        final password = answer['password'];
        if (username == null || password == null) return null;
        final credentials = Credentials(username: username, password: password);
        rememberForSession(url, credentials);
        return credentials;
      } on Object {
        return null;
      }
    }

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

    if (Platform.isAndroid) {
      try {
        await _ensureVaultUnlocked();
        await _vaultStore().git('store', [
          ..._scopeFor(url),
          ['username', credentials.username],
          ['password', credentials.password],
        ]);
        return true;
      } on Object {
        return false;
      }
    }

    final answer = await _run('approve', url, credentials: credentials);
    return answer != null;
  }

  /// Tells the helper to drop a secret that was refused, so the next attempt
  /// asks rather than failing again with the same rejected token.
  Future<void> discard(String url, Credentials credentials) async {
    forget(url);

    if (Platform.isAndroid) {
      try {
        await _ensureVaultUnlocked();
        await _vaultStore().git('erase', [
          ..._scopeFor(url),
          ['username', credentials.username],
          ['password', credentials.password],
        ]);
      } on Object {
        // Nothing further to do; the in-memory copy is already forgotten.
      }
      return;
    }

    await _run('reject', url, credentials: credentials);
  }

  Future<Map<String, String>?> _run(
    String action,
    String url, {
    Credentials? credentials,
  }) async {
    // As in canSave: nothing here to ask on the web.
    if (kIsWeb) return null;
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
