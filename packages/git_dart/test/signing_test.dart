/// Signed commits and tags — checked against git, with git's own programs.
///
/// A signature is only right if the *other* implementation agrees: git must
/// accept what this library signs, and this library must reach the same
/// verdict as git on what git signed. So every test here runs real `gpg` or
/// `ssh-keygen`, against keys made for the test in a temporary directory —
/// never the user's keyring or `~/.ssh` — and skips when the program is not
/// installed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

/// Environment for every program run, git included: the temporary keyring.
Map<String, String> toolEnvironment = {};

ProcessResult runGit(List<String> arguments) => Process.runSync(
      'git',
      arguments,
      workingDirectory: repoPath,
      environment: toolEnvironment,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

String git(List<String> arguments) {
  final result = runGit(arguments);
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// Where Git for Windows keeps the Unix tools it runs — gpg and ssh-keygen
/// among them — which are not on the Windows PATH.
String? get _gitUsrBin {
  if (!Platform.isWindows) return null;
  final execPath =
      (Process.runSync('git', ['--exec-path']).stdout as String).trim();
  final usrBin = p.normalize(p.join(execPath, '..', '..', '..', 'usr', 'bin'));
  return Directory(usrBin).existsSync() ? usrBin : null;
}

/// [name] as git would find it, or null when it is not installed.
String? findTool(String name) {
  final bundled = _gitUsrBin;
  if (bundled != null) {
    final candidate = p.join(bundled, '$name.exe');
    if (File(candidate).existsSync()) return candidate;
  }
  try {
    final result = Process.runSync(name, ['--version']);
    // ssh-keygen has no --version and says so with a usage message.
    if (result.exitCode == 0 || name == 'ssh-keygen') return name;
  } on ProcessException {
    return null;
  }
  return null;
}

/// MSYS programs read `C:\…` in an environment variable as a relative path;
/// they want `/c/…`.
String forTool(String program, String path) {
  if (!Platform.isWindows || !program.contains(p.join('usr', 'bin'))) {
    return path;
  }
  final full = p.absolute(path);
  return '/${full[0].toLowerCase()}${full.substring(2).replaceAll(r'\', '/')}';
}

Repository openRepo() {
  final repo = Repository.open(repoPath);
  repo.signatureTool = ProcessSignatureTool(environment: toolEnvironment);
  return repo;
}

void write(String name, String contents) {
  File(p.join(repoPath, name)).writeAsStringSync(contents);
}

/// A copy of [id] with its message changed and every header — the signature
/// included — left alone: the forgery a signature exists to catch.
ObjectId tamper(Repository repo, ObjectId id) {
  final content = repo.objects.read(id).content;
  final text = latin1.decode(content);
  final forged = latin1.encode(text.replaceFirst('signed\n', 'forged\n'));
  expect(forged, isNot(equals(content)));
  return repo.objects.write(Commit.parse(Uint8List.fromList(forged)));
}

/// What git says about a commit: `%G?`, the signer, and the key.
({String status, String signer, String key}) gitView(ObjectId id) {
  final line = git(['log', '-1', '--format=%G?|%GS|%GK', id.hex]).trim();
  final parts = line.split('|');
  return (status: parts[0], signer: parts[1], key: parts[2]);
}

void initRepo() {
  scratch = Directory.systemTemp.createTempSync('gds');
  repoPath = p.join(scratch.path, 'repo');
  Directory(repoPath).createSync(recursive: true);
  git(['init', '-q', '-b', 'main']);
  git(['config', 'user.name', 'A U Thor']);
  git(['config', 'user.email', 'a@x']);
  write('a.txt', 'one\n');
  git(['add', 'a.txt']);
  git(['commit', '-q', '--no-gpg-sign', '-m', 'first']);
}

void main() {
  // -------------------------------------------------------------------------
  group('ssh', () {
    String? sshKeygen;
    late Directory keys;
    late String signingKey;
    late String strangerKey;
    late String allowedSigners;

    setUpAll(() {
      sshKeygen = findTool('ssh-keygen');
      if (sshKeygen == null) return;
      keys = Directory.systemTemp.createTempSync('gdk');
      String generate(String name) {
        final path = p.join(keys.path, name);
        final result = Process.runSync(sshKeygen!, [
          '-q',
          '-t',
          'ed25519',
          '-N',
          '',
          '-C',
          name,
          '-f',
          path,
        ]);
        if (result.exitCode != 0) {
          sshKeygen = null;
          return path;
        }
        return path;
      }

      signingKey = generate('signer');
      strangerKey = generate('stranger');
      if (sshKeygen == null) return;
      final public = File('$signingKey.pub').readAsStringSync().trim();
      allowedSigners = p.join(keys.path, 'allowed_signers');
      File(allowedSigners).writeAsStringSync('a@x namespaces="git" $public\n');
    });

    tearDownAll(() {
      if (sshKeygen != null) keys.deleteSync(recursive: true);
    });

    setUp(() {
      if (sshKeygen == null) return;
      toolEnvironment = {};
      initRepo();
      git(['config', 'gpg.format', 'ssh']);
      git(['config', 'gpg.ssh.program', sshKeygen!]);
      git(['config', 'gpg.ssh.allowedSignersFile', allowedSigners]);
      git(['config', 'user.signingKey', signingKey]);
    });

    tearDown(() {
      if (sshKeygen != null) scratch.deleteSync(recursive: true);
    });

    bool skipped() {
      if (sshKeygen != null) return false;
      markTestSkipped('ssh-keygen with -Y support is not available');
      return true;
    }

    test('a commit git signed verifies as git says', () {
      if (skipped()) return;
      write('a.txt', 'two\n');
      git(['commit', '-q', '-a', '-S', '-m', 'signed']);

      final repo = openRepo();
      final check = repo.verifyCommit(repo.headId!);
      repo.close();

      final view = gitView(repo.headId!);
      expect(check.status, SignatureStatus.good);
      expect(check.isVerified, isTrue);
      expect(check.format, SignatureFormat.ssh);
      expect(check.status.code, view.status);
      expect(check.signer, view.signer);
      expect(check.key, view.key);
      expect(check.signer, 'a@x');

      final raw = runGit(['verify-commit', '--raw', 'HEAD']);
      expect(raw.exitCode, 0);
      expect(check.rawOutput, raw.stderr);
    });

    test('a commit git_dart signed is one git verifies', () {
      if (skipped()) return;
      write('a.txt', 'two\n');
      git(['add', 'a.txt']);

      final repo = openRepo();
      final id = repo.commitIndex(message: 'signed', sign: true);
      final check = repo.verifyCommit(id);
      repo.close();

      expect(check.status, SignatureStatus.good);
      final verify = runGit(['verify-commit', id.hex]);
      expect(verify.exitCode, 0, reason: verify.stderr as String);
      expect(gitView(id).status, 'G');

      // The signature header is the last one, where git puts it.
      final lines = git(['cat-file', 'commit', id.hex]).split('\n');
      expect(lines[3], startsWith('committer '));
      expect(lines[4], 'gpgsig -----BEGIN SSH SIGNATURE-----');
    });

    test('commit.gpgSign signs without being asked, and false wins over it',
        () {
      if (skipped()) return;
      git(['config', 'commit.gpgSign', 'true']);
      write('a.txt', 'two\n');
      git(['add', 'a.txt']);

      final repo = openRepo();
      final signed = repo.commitIndex(message: 'signed');
      final unsigned = repo.commitTree(
        tree: repo.objects.readTyped<Commit>(signed).tree,
        message: 'unsigned',
        author: repo.identityFromConfig()!,
        sign: false,
      );
      repo.close();

      expect(gitView(signed).status, 'G');
      expect(gitView(unsigned).status, 'N');
    });

    test('a tampered commit is bad, to both', () {
      if (skipped()) return;
      write('a.txt', 'two\n');
      git(['commit', '-q', '-a', '-S', '-m', 'signed']);

      final repo = openRepo();
      final forged = tamper(repo, repo.headId!);
      final check = repo.verifyCommit(forged);
      repo.close();

      expect(check.status, SignatureStatus.bad);
      expect(check.isVerified, isFalse);
      expect(gitView(forged).status, 'B');
      expect(runGit(['verify-commit', forged.hex]).exitCode, isNot(0));
    });

    test('an unsigned commit has no signature, to both', () {
      if (skipped()) return;
      final repo = openRepo();
      final check = repo.verifyCommit(repo.headId!);
      repo.close();

      expect(check.status, SignatureStatus.none);
      expect(check.isSigned, isFalse);
      expect(check.isVerified, isFalse);
      expect(gitView(repo.headId!).status, 'N');
    });

    test('a key nobody allowed is of unknown validity and fails', () {
      if (skipped()) return;
      write('a.txt', 'two\n');
      git(['add', 'a.txt']);

      final repo = openRepo();
      final id = repo.commitIndex(
          message: 'signed', signingKey: strangerKey, sign: true);
      final check = repo.verifyCommit(id);
      repo.close();

      final view = gitView(id);
      expect(check.status, SignatureStatus.unknownValidity);
      expect(check.status.code, view.status);
      expect(check.key, view.key);
      expect(check.isVerified, isFalse);
      expect(runGit(['verify-commit', id.hex]).exitCode, isNot(0));
    });

    test('annotated tags sign and verify both ways', () {
      if (skipped()) return;
      final repo = openRepo();
      final ours = repo.createTag('v1', message: 'release\n', sign: true);
      git(['tag', '-s', '-m', 'theirs', 'v2']);
      final theirs = repo.resolve('refs/tags/v2')!;
      git(['tag', '-a', '-m', 'plain', 'v3']);
      final plain = repo.resolve('refs/tags/v3')!;

      final verify = runGit(['verify-tag', 'v1']);
      expect(verify.exitCode, 0, reason: verify.stderr as String);
      expect(repo.verifyTag(ours).status, SignatureStatus.good);

      final check = repo.verifyTag(theirs);
      expect(check.status, SignatureStatus.good);
      expect(check.signer, 'a@x');
      expect(check.rawOutput, runGit(['verify-tag', '--raw', 'v2']).stderr);

      expect(repo.verifyTag(plain).status, SignatureStatus.none);
      expect(
        () => repo.createTag('v4', sign: true),
        throwsArgumentError,
      );
      repo.close();
    });

    test('tag.gpgSign signs annotated tags only', () {
      if (skipped()) return;
      git(['config', 'tag.gpgSign', 'true']);
      final repo = openRepo();
      final annotated = repo.createTag('v1', message: 'release');
      final light = repo.createTag('v2');
      repo.close();

      expect(runGit(['verify-tag', annotated.hex]).exitCode, 0);
      expect(git(['cat-file', '-t', 'v2']).trim(), 'commit');
      expect(light, repo.headId);
    });
  });

  // -------------------------------------------------------------------------
  group('openpgp', () {
    String? gpg;
    late Directory home;

    void gpgRun(List<String> arguments) {
      final result =
          Process.runSync(gpg!, arguments, environment: toolEnvironment);
      if (result.exitCode != 0) {
        gpg = null;
      }
    }

    setUpAll(() {
      gpg = findTool('gpg');
      if (gpg == null) return;
      // Short: gpg-agent's socket lives here, and socket paths are limited.
      home = Directory.systemTemp.createTempSync('gdg');
      toolEnvironment = {'GNUPGHOME': forTool(gpg!, home.path)};
      final parameters = p.join(home.path, 'params');
      File(parameters).writeAsStringSync(
        '%no-protection\n'
        'Key-Type: eddsa\n'
        'Key-Curve: ed25519\n'
        'Key-Usage: sign\n'
        'Name-Real: A U Thor\n'
        'Name-Email: a@x\n'
        'Expire-Date: 0\n'
        '%commit\n',
      );
      gpgRun(['--batch', '--gen-key', parameters]);
    });

    tearDownAll(() {
      if (gpg == null && toolEnvironment.isEmpty) return;
      final gpgconf = gpg == null
          ? null
          : p.join(
              p.dirname(gpg!), 'gpgconf${Platform.isWindows ? '.exe' : ''}');
      if (gpgconf != null && File(gpgconf).existsSync()) {
        Process.runSync(gpgconf, ['--kill', 'gpg-agent'],
            environment: toolEnvironment);
      } else {
        try {
          Process.runSync('gpgconf', ['--kill', 'gpg-agent'],
              environment: toolEnvironment);
        } on ProcessException {
          // Nothing to stop.
        }
      }
      try {
        home.deleteSync(recursive: true);
      } on FileSystemException {
        // The agent may still be letting go of its socket.
      }
    });

    setUp(() {
      if (gpg == null) return;
      initRepo();
      git(['config', 'gpg.program', gpg!]);
    });

    tearDown(() {
      if (gpg != null) scratch.deleteSync(recursive: true);
    });

    bool skipped() {
      if (gpg != null) return false;
      markTestSkipped('gpg is not available');
      return true;
    }

    test('a commit git signed verifies as git says', () {
      if (skipped()) return;
      write('a.txt', 'two\n');
      git(['commit', '-q', '-a', '-S', '-m', 'signed']);

      final repo = openRepo();
      final check = repo.verifyCommit(repo.headId!);
      repo.close();

      final view = gitView(repo.headId!);
      expect(check.format, SignatureFormat.openpgp);
      expect(check.status, SignatureStatus.good);
      expect(check.trustLevel, TrustLevel.ultimate);
      expect(check.isVerified, isTrue);
      expect(check.status.code, view.status);
      expect(check.signer, view.signer);
      expect(check.key, view.key);
      expect(check.signer, 'A U Thor <a@x>');
      expect(check.fingerprint, git(['log', '-1', '--format=%GF']).trim());
      expect(check.primaryKeyFingerprint,
          git(['log', '-1', '--format=%GP']).trim());

      final raw = runGit(['verify-commit', '--raw', 'HEAD']);
      expect(raw.exitCode, 0);
      expect(verdictLines(check.rawOutput), verdictLines(raw.stderr as String));
    });

    test('a commit git_dart signed is one git verifies', () {
      if (skipped()) return;
      write('a.txt', 'two\n');
      git(['add', 'a.txt']);

      final repo = openRepo();
      // No user.signingKey: the committer's identity names the key.
      final id = repo.commitIndex(message: 'signed', sign: true);
      repo.close();

      final verify = runGit(['verify-commit', id.hex]);
      expect(verify.exitCode, 0, reason: verify.stderr as String);
      expect(gitView(id).status, 'G');
    });

    test('a tampered commit is bad, to both', () {
      if (skipped()) return;
      write('a.txt', 'two\n');
      git(['commit', '-q', '-a', '-S', '-m', 'signed']);

      final repo = openRepo();
      final forged = tamper(repo, repo.headId!);
      final check = repo.verifyCommit(forged);
      repo.close();

      expect(check.status, SignatureStatus.bad);
      expect(check.isVerified, isFalse);
      expect(check.status.code, gitView(forged).status);
      expect(check.key, gitView(forged).key);
    });

    test('an unsigned commit has no signature', () {
      if (skipped()) return;
      final repo = openRepo();
      expect(repo.verifyCommit(repo.headId!).status, SignatureStatus.none);
      repo.close();
      expect(gitView(repo.headId!).status, 'N');
    });

    test('annotated tags sign and verify both ways', () {
      if (skipped()) return;
      final repo = openRepo();
      repo.createTag('v1', message: 'release', sign: true);
      git(['tag', '-s', '-m', 'theirs', 'v2']);
      final theirs = repo.resolve('refs/tags/v2')!;

      final verify = runGit(['verify-tag', 'v1']);
      expect(verify.exitCode, 0, reason: verify.stderr as String);

      final check = repo.verifyTag(theirs);
      expect(check.status, SignatureStatus.good);
      expect(verdictLines(check.rawOutput),
          verdictLines(runGit(['verify-tag', '--raw', 'v2']).stderr as String));
      repo.close();
    });

    test('gpg.minTrustLevel is honoured, and a bad value refused', () {
      if (skipped()) return;
      write('a.txt', 'two\n');
      git(['commit', '-q', '-a', '-S', '-m', 'signed']);
      // A key made in this keyring is ultimately trusted — the highest level,
      // so the strictest setting still accepts it.
      git(['config', 'gpg.minTrustLevel', 'Ultimate']);
      expect(runGit(['verify-commit', 'HEAD']).exitCode, 0);
      final repo = openRepo();
      expect(repo.verifyCommit(repo.headId!).isVerified, isTrue);
      git(['config', 'gpg.minTrustLevel', 'absolute']);
      repo.reloadConfig();
      expect(() => repo.verifyCommit(repo.headId!), throwsStateError);
      repo.close();
    });
  });

  // -------------------------------------------------------------------------
  group('a supplied tool', () {
    setUp(() {
      toolEnvironment = {};
      initRepo();
    });
    tearDown(() => scratch.deleteSync(recursive: true));

    test('signs exactly the unsigned commit, and is asked to check it', () {
      final repo = Repository.open(repoPath);
      final tool = _FakeTool();
      repo.signatureTool = tool;
      final who = repo.identityFromConfig()!;
      final tree = repo.objects.readTyped<Commit>(repo.headId!).tree;

      final unsigned = repo.commitTree(
        tree: tree,
        message: 'x',
        author: who,
        updateHead: false,
      );
      final signed = repo.commitTree(
        tree: tree,
        message: 'x',
        author: who,
        updateHead: false,
        sign: true,
        signingKey: 'KEY',
      );

      // The payload handed to the tool is the unsigned commit, byte for byte.
      expect(tool.signedPayloads.single, repo.objects.read(unsigned).content);
      expect(tool.keys.single, 'KEY');

      final check = repo.verifyCommit(signed);
      expect(check.status, SignatureStatus.good);
      expect(check.isVerified, isTrue);
      expect(check.payload, repo.objects.read(unsigned).content);
      expect(check.signature, _FakeTool.armour);

      // git parses the result and finds the same signature where it looks.
      final shown = git(['cat-file', 'commit', signed.hex]);
      expect(
          shown,
          contains('gpgsig -----BEGIN PGP SIGNATURE-----\n \n'
              ' ZmFrZQ==\n -----END PGP SIGNATURE-----\n\nx\n'));
      repo.close();
    });

    test('a quoted signature in a tag message is not the tag\'s', () {
      final content = utf8.encode(
        'object ${'0' * 40}\ntype commit\ntag t\n\n'
        'see:\n-----BEGIN PGP SIGNATURE-----\nquoted\n'
        '-----END PGP SIGNATURE-----\n'
        '-----BEGIN SSH SIGNATURE-----\nreal\n-----END SSH SIGNATURE-----\n',
      );
      final split = splitSignedTag(Uint8List.fromList(content));
      expect(split.signature, startsWith('-----BEGIN SSH SIGNATURE-----'));
      expect(utf8.decode(split.payload),
          endsWith('-----END PGP SIGNATURE-----\n'));
    });

    test('gpg status with two verdicts is an error with nothing reported', () {
      final check = parseGpgStatus(
        '[GNUPG:] NEWSIG\n'
        '[GNUPG:] GOODSIG AAAA One <1@x>\n'
        '[GNUPG:] NEWSIG\n'
        '[GNUPG:] BADSIG BBBB Two <2@x>\n',
        output: '',
        toolSucceeded: true,
        payload: Uint8List(0),
      );
      expect(check.status, SignatureStatus.cannotCheck);
      expect(check.key, isNull);
      expect(check.signer, isNull);
    });
  });
}

class _FakeTool extends SignatureTool {
  static const armour = '-----BEGIN PGP SIGNATURE-----\n'
      '\n'
      'ZmFrZQ==\n'
      '-----END PGP SIGNATURE-----\n';

  final signedPayloads = <Uint8List>[];
  final keys = <String>[];

  @override
  String sign(Uint8List payload, SigningRequest request) {
    signedPayloads.add(payload);
    keys.add(request.key);
    return armour;
  }

  @override
  SignatureCheck verify(
    Uint8List payload,
    String signature,
    VerificationRequest request,
  ) {
    final matches = signedPayloads.any(
          (signed) => _bytesEqual(signed, payload),
        ) &&
        signature == armour;
    return SignatureCheck(
      result: matches ? SignatureStatus.good : SignatureStatus.bad,
      trustLevel: TrustLevel.fully,
      toolSucceeded: matches,
      signer: 'fake',
      payload: payload,
    );
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// gpg's status lines without KEY_CONSIDERED, which gpg repeats or not
/// depending on whether it has just rechecked its trust database — a fact
/// about the keyring's housekeeping, not about the signature.
List<String> verdictLines(String status) => const LineSplitter()
    .convert(status)
    .where((line) => !line.startsWith('[GNUPG:] KEY_CONSIDERED '))
    .toList();
