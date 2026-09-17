/// Signing and verifying by running the programs git runs.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../platform/host.dart' show homeDirectory;
import 'signature.dart';

SignatureTool get platformSignatureTool => const ProcessSignatureTool();

/// A [SignatureTool] that runs `gpg`, `gpgsm` or `ssh-keygen` with the
/// arguments `gpg-interface.c` uses, so that a wrapper configured as
/// `gpg.program` sees exactly what git would have given it.
///
/// One difference cannot be avoided: this library is synchronous, and
/// [Process.runSync] cannot write to a child's standard input. Where git pipes
/// the payload in, this writes it to a temporary file and has a shell
/// redirect it — `sh` on POSIX, `cmd` on Windows — so the program's arguments
/// are still git's, `-` and all.
class ProcessSignatureTool extends SignatureTool {
  /// Extra environment for every program run — `GNUPGHOME`, say, to point
  /// gpg at a keyring other than the user's.
  final Map<String, String>? environment;

  const ProcessSignatureTool({this.environment});

  @override
  String sign(Uint8List payload, SigningRequest request) {
    final program = request.format.programFrom(request.config);
    try {
      return _withTemporaryDirectory(
        (directory) => _sign(directory, program, payload, request),
      );
    } on ProcessException catch (error) {
      throw StateError('cannot run $program: ${error.message}');
    }
  }

  String _sign(
    String directory,
    String program,
    Uint8List payload,
    SigningRequest request,
  ) {
    switch (request.format) {
      case SignatureFormat.openpgp:
      case SignatureFormat.x509:
        final input = _writeFile(directory, 'payload', payload);
        final result = _run(
          program,
          ['--status-fd=2', '-bsau', request.key],
          stdinFile: input,
        );
        // gpg can exit zero having signed nothing; the status line is the
        // only proof a signature was made.
        if (result.exitCode != 0 ||
            !result.stderr.contains('\n[GNUPG:] SIG_CREATED ')) {
          throw StateError('gpg failed to sign the data:\n${result.stderr}');
        }
        return normaliseSignature(result.stdout);

      case SignatureFormat.ssh:
        final key = request.key;
        if (key.isEmpty) {
          throw StateError('user.signingKey needs to be set for ssh signing');
        }
        final literal = _literalSshKey(key);
        final String keyFile;
        if (literal != null) {
          // The private half is in the agent; ssh-keygen finds it from the
          // public half, which it will only read from a file.
          keyFile = p.join(directory, 'signing_key.pub');
          File(keyFile).writeAsStringSync(literal);
        } else {
          keyFile = _expandHome(key);
        }
        final buffer = _writeFile(directory, 'buffer', payload);
        final result = _run(program, [
          '-Y',
          'sign',
          '-n',
          'git',
          '-f',
          keyFile,
          if (literal != null) '-U',
          buffer,
        ]);
        if (result.exitCode != 0) {
          if (result.stderr.contains('usage:')) {
            throw StateError(
              'ssh-keygen -Y sign is needed for ssh signing '
              '(available in openssh version 8.2p1+)',
            );
          }
          throw StateError('ssh-keygen failed to sign:\n${result.stderr}');
        }
        final signature = File('$buffer.sig');
        if (!signature.existsSync()) {
          throw StateError('ssh-keygen wrote no signature');
        }
        return normaliseSignature(signature.readAsStringSync());
    }
  }

  @override
  SignatureCheck verify(
    Uint8List payload,
    String signature,
    VerificationRequest request,
  ) {
    return _withTemporaryDirectory((directory) {
      return request.format == SignatureFormat.ssh
          ? _verifySsh(directory, payload, signature, request)
          : _verifyGpg(directory, payload, signature, request);
    });
  }

  SignatureCheck _verifyGpg(
    String directory,
    Uint8List payload,
    String signature,
    VerificationRequest request,
  ) {
    final program = request.format.programFrom(request.config);
    final signatureFile =
        _writeFile(directory, 'signature', utf8.encode(signature));
    final input = _writeFile(directory, 'payload', payload);
    final _Result result;
    try {
      result = _run(
        program,
        [
          if (request.format == SignatureFormat.openpgp) '--keyid-format=long',
          '--status-fd=1',
          '--verify',
          signatureFile,
          '-',
        ],
        stdinFile: input,
      );
    } on ProcessException catch (error) {
      return _couldNotRun(program, error, payload, signature, request.format);
    }

    return parseGpgStatus(
      result.stdout,
      output: result.stderr,
      toolSucceeded:
          result.exitCode == 0 && result.stdout.contains('\n[GNUPG:] GOODSIG '),
      payload: payload,
      signature: signature,
      format: request.format,
    );
  }

  /// `verify_ssh_signed_buffer`: find which allowed signers the key belongs
  /// to, then verify as each until one succeeds. A key belonging to nobody is
  /// still checked, without validation, so that the output can say whose key
  /// it was — but the verdict is a failure.
  SignatureCheck _verifySsh(
    String directory,
    Uint8List payload,
    String signature,
    VerificationRequest request,
  ) {
    final config = request.config;
    final program = request.format.programFrom(config);
    final allowedSetting = config['gpg.ssh.allowedSignersFile'];
    final allowed = allowedSetting == null ? null : _expandHome(allowedSetting);
    if (allowed == null || !File(allowed).existsSync()) {
      // Git reports this and returns before any verdict is formed, which
      // leaves the result as "no signature".
      return SignatureCheck(
        result: SignatureStatus.none,
        format: SignatureFormat.ssh,
        output: 'gpg.ssh.allowedSignersFile needs to be configured and exist '
            'for ssh signature verification\n',
        payload: payload,
        signature: signature,
      );
    }

    final signatureFile =
        _writeFile(directory, 'signature', utf8.encode(signature));
    final input = _writeFile(directory, 'payload', payload);
    final timestamp = request.payloadTimestamp;
    final verifyTime =
        timestamp == null ? null : '-Overify-time=${_compactUtc(timestamp)}';

    try {
      final principals = _run(program, [
        '-Y',
        'find-principals',
        '-f',
        allowed,
        '-s',
        signatureFile,
        if (verifyTime != null) verifyTime,
      ]);
      if (principals.exitCode != 0 && principals.stderr.contains('usage:')) {
        return SignatureCheck(
          result: SignatureStatus.none,
          format: SignatureFormat.ssh,
          output: 'ssh-keygen -Y find-principals/verify is needed for ssh '
              'signature verification (available in openssh version 8.2p1+)\n',
          payload: payload,
          signature: signature,
        );
      }

      _Result verdict;
      var succeeded = false;
      if (principals.exitCode != 0 || principals.stdout.isEmpty) {
        verdict = _run(
          program,
          [
            '-Y',
            'check-novalidate',
            '-n',
            'git',
            '-s',
            signatureFile,
            if (verifyTime != null) verifyTime,
          ],
          stdinFile: input,
        );
      } else {
        final revocation = config['gpg.ssh.revocationFile'];
        final revocationFile =
            revocation == null ? null : _expandHome(revocation);
        verdict = const _Result(1, '', '');
        for (final principal in const LineSplitter()
            .convert(principals.stdout)
            .where((line) => line.isNotEmpty)) {
          verdict = _run(
            program,
            [
              '-Y',
              'verify',
              '-n',
              'git',
              '-f',
              allowed,
              '-I',
              principal,
              '-s',
              signatureFile,
              if (verifyTime != null) verifyTime,
              if (revocationFile != null &&
                  File(revocationFile).existsSync()) ...['-r', revocationFile],
            ],
            stdinFile: input,
          );
          succeeded =
              verdict.exitCode == 0 && verdict.stdout.startsWith('Good');
          if (succeeded) break;
        }
      }

      final output = stripSpace(verdict.stdout) +
          principals.stderr +
          stripSpace(verdict.stderr);
      return parseSshOutput(
        output,
        toolSucceeded: succeeded,
        payload: payload,
        signature: signature,
      );
    } on ProcessException catch (error) {
      return _couldNotRun(program, error, payload, signature, request.format);
    }
  }

  SignatureCheck _couldNotRun(
    String program,
    ProcessException error,
    Uint8List payload,
    String signature,
    SignatureFormat format,
  ) =>
      SignatureCheck(
        result: SignatureStatus.none,
        format: format,
        output: 'cannot run $program: ${error.message}\n',
        payload: payload,
        signature: signature,
      );

  _Result _run(String program, List<String> arguments, {String? stdinFile}) {
    final ProcessResult result;
    if (stdinFile == null) {
      result = Process.runSync(
        program,
        arguments,
        environment: environment,
        stdoutEncoding: null,
        stderrEncoding: null,
      );
    } else if (Platform.isWindows) {
      // cmd expands %VAR% before it parses redirections and quotes, so the
      // whole command can travel in the environment, where Dart's own
      // argument quoting — which cmd does not understand — never touches it.
      final line = [
        for (final word in [program, ...arguments]) _quoteForWindows(word),
        '<',
        _quoteForWindows(stdinFile),
      ].join(' ');
      result = Process.runSync(
        Platform.environment['ComSpec'] ?? 'cmd.exe',
        ['/d', '/c', '%GIT_DART_SIGNING_COMMAND%'],
        environment: {...?environment, 'GIT_DART_SIGNING_COMMAND': line},
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      // cmd reports a program it could not find as its own failure.
      if (result.exitCode == 9009) {
        throw ProcessException(program, arguments, 'program not found', 9009);
      }
    } else {
      result = Process.runSync(
        '/bin/sh',
        ['-c', r'exec "$0" "$@" < "$GIT_DART_STDIN"', program, ...arguments],
        environment: {...?environment, 'GIT_DART_STDIN': stdinFile},
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      if (result.exitCode == 127) {
        throw ProcessException(program, arguments, 'program not found', 127);
      }
    }
    String text(Object? bytes) => utf8
        .decode(bytes as List<int>, allowMalformed: true)
        .replaceAll('\r\n', '\n');
    return _Result(result.exitCode, text(result.stdout), text(result.stderr));
  }
}

class _Result {
  final int exitCode;
  final String stdout;
  final String stderr;
  const _Result(this.exitCode, this.stdout, this.stderr);
}

T _withTemporaryDirectory<T>(T Function(String directory) body) {
  final directory = Directory.systemTemp.createTempSync('git_dart_sign');
  try {
    return body(directory.path);
  } finally {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // A program still holding a file open on Windows; the OS cleans temp.
    }
  }
}

String _writeFile(String directory, String name, List<int> bytes) {
  final path = p.join(directory, name);
  File(path).writeAsBytesSync(bytes);
  return path;
}

/// `is_literal_ssh_key`: a signing key given as the public key itself rather
/// than as a file.
String? _literalSshKey(String key) {
  if (key.startsWith('key::')) return key.substring('key::'.length);
  if (key.startsWith('ssh-')) return key;
  return null;
}

/// `interpolate_path`, as far as it goes on a config value: `~/`.
String _expandHome(String path) {
  final home = homeDirectory;
  if (home != null && (path == '~' || path.startsWith('~/'))) {
    return p.join(home, path.length > 2 ? path.substring(2) : '');
  }
  return path;
}

/// `YYYYMMDDHHMMSS`, which is what ssh-keygen's `verify-time` takes. Git
/// formats the object's time without its zone, so this is UTC too.
String _compactUtc(int seconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// One word for cmd and then for the program's own argument parser.
///
/// Always quoted, so that cmd treats `&`, `<`, `^` and spaces inside as text;
/// backslashes before the closing quote doubled, as the C runtime requires. A
/// quote inside a word cannot survive both parsers and is refused.
String _quoteForWindows(String word) {
  if (word.contains('"')) {
    throw ArgumentError.value(word, 'argument', 'cannot contain a quote');
  }
  var trailing = 0;
  while (trailing < word.length && word[word.length - 1 - trailing] == r'\') {
    trailing++;
  }
  return '"$word${r'\' * trailing}"';
}
