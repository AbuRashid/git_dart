/// ssh and the git daemon.
///
/// Git over ssh has no protocol of its own: ssh runs `git-upload-pack <path>`
/// on the far end with its input and output attached to the connection, and
/// the same pkt-line conversation happens over those pipes. That is testable
/// without an ssh server, by pointing the ssh command at something that runs
/// the far side locally — which exercises everything except ssh itself, and
/// ssh itself is not what could be wrong here.
///
/// The daemon is tested against a real `git daemon`, which is a server and
/// costs nothing to start.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String originPath;

String git(List<String> arguments, {String? cwd}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? originPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

String emptyClone(String name) {
  final path = p.join(scratch.path, name);
  Directory(path).createSync(recursive: true);
  Repository.init(path).close();
  return path;
}

/// A stand-in for ssh: takes the arguments ssh takes, ignores the host, and
/// runs the command locally with its pipes wired up the way ssh would.
///
/// Written as a Dart script so it behaves the same on every platform — a shell
/// script would not run on Windows and a batch file would not run anywhere
/// else.
String writeFakeSsh(String directory, {bool offerVersion2 = true}) {
  final path = p.join(directory, 'fake_ssh.dart');
  File(path).writeAsStringSync('''
import 'dart:io';

/// ssh's argument shape: some options, a host, then one command string.
Future<void> main(List<String> arguments) async {
  final rest = <String>[];
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    // -p <port> and -o <option>, which are consumed and ignored.
    if (argument == '-p' || argument == '-o') {
      i += 1;
      continue;
    }
    rest.add(argument);
  }
  // rest[0] is the host, rest[1] is `git-upload-pack '<path>'`.
  final command = rest[1];
  final space = command.indexOf(' ');
  final service = command.substring(0, space);
  var target = command.substring(space + 1).trim();
  if (target.startsWith("'") && target.endsWith("'")) {
    target = target.substring(1, target.length - 1);
  }

  // Relayed the way a real ssh server does when it is configured to accept
  // the variable. Set to empty rather than left out when this stand-in is
  // playing a server that does not: the child inherits our environment, so
  // omitting it would pass on the one ssh set for us.
  final environment = <String, String>{};
  final asked = Platform.environment['GIT_PROTOCOL'];
  environment['GIT_PROTOCOL'] =
      (asked != null && $offerVersion2) ? asked : '';

  final process = await Process.start(
    'git',
    [service.replaceFirst('git-', ''), target],
    environment: environment,
  );
  unawaited(stdin.pipe(process.stdin));
  unawaited(process.stdout.pipe(stdout));
  unawaited(process.stderr.pipe(stderr));
  exitCode = await process.exitCode;
}

void unawaited(Future<void> f) {}
''');
  return path;
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_transport');
    originPath = p.join(scratch.path, 'origin');
    Directory(originPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    File(p.join(originPath, 'a.txt')).writeAsStringSync('one\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    File(p.join(originPath, 'a.txt')).writeAsStringSync('one\ntwo\n');
    git(['commit', '-qam', 'second']);
    git(['branch', 'side']);
    // Packed, so the exchange sends a real packfile with deltas in it.
    git(['gc', '-q']);
  });

  tearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // A daemon that has not quite finished exiting still holds a handle.
    }
  });

  // -------------------------------------------------------------------------
  group('parsing an ssh remote', () {
    test('the scp-style form', () {
      final target = SshTarget.parse('git@github.com:owner/repo.git')!;
      expect(target.user, 'git');
      expect(target.host, 'github.com');
      expect(target.path, 'owner/repo.git');
      expect(target.port, isNull);
    });

    test('without a user', () {
      final target = SshTarget.parse('example.com:/srv/repo.git')!;
      expect(target.user, isNull);
      expect(target.host, 'example.com');
      expect(target.path, '/srv/repo.git');
    });

    test('the URL form, with a port', () {
      final target = SshTarget.parse('ssh://git@example.com:2222/srv/repo')!;
      expect(target.user, 'git');
      expect(target.host, 'example.com');
      expect(target.port, 2222);
      expect(target.path, 'srv/repo');
    });

    test('a colon in the scp form separates a path, not a port', () {
      // `host:1234/x` is a path beginning `1234`. Reading it as a port is the
      // mistake this form catches everyone with once.
      final target = SshTarget.parse('example.com:1234/repo.git')!;
      expect(target.port, isNull);
      expect(target.path, '1234/repo.git');
    });

    test('a Windows drive letter is not a host', () {
      expect(SshTarget.parse(r'C:\repos\thing'), isNull);
      expect(SshTarget.parse('C:/repos/thing'), isNull);
    });

    test('other schemes are not ssh', () {
      expect(SshTarget.parse('https://example.com/repo.git'), isNull);
      expect(SshTarget.parse('git://example.com/repo.git'), isNull);
    });

    test('a remote with an ssh URL is not treated as a local path', () {
      const remote = Remote(name: 'origin', url: 'git@example.com:a/b.git');
      expect(remote.isLocal, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('over ssh', () {
    late String sshCommand;

    setUp(() {
      // `sshCommand` carries arguments, as git's own `core.sshCommand` does,
      // so the stand-in is "the Dart running these tests, with this script" —
      // no shell script or batch file, which do not run the same way on every
      // platform and which Dart cannot execute directly on Windows anyway.
      final script = writeFakeSsh(scratch.path);
      sshCommand = '"${Platform.resolvedExecutable}" "$script"';
    });

    test('fetches over a duplex connection', () async {
      final path = emptyClone('ssh-clone');
      final repo = Repository.open(path);
      repo.remotes.add('origin', 'user@somewhere:$originPath');

      final result = await fetch(
        repo,
        repo.remotes.named('origin')!,
        sshCommand: sshCommand,
      );

      expect(result.objectsReceived, greaterThan(0));
      expect(
        result.updates.map((u) => u.ref).toList(),
        ['refs/remotes/origin/main', 'refs/remotes/origin/side'],
      );
      expect(
        repo.refs.resolve('refs/remotes/origin/main')!.hex,
        git(['rev-parse', 'main']).trim(),
      );
      repo.close();

      git(['fsck', '--no-progress'], cwd: path);
      expect(
        git(['rev-list', '--count', 'refs/remotes/origin/main'], cwd: path)
            .trim(),
        '2',
      );
      expect(
        git(['cat-file', 'blob', 'refs/remotes/origin/main:a.txt'], cwd: path),
        'one\ntwo\n',
      );
    });

    test('a second fetch with nothing new moves nothing', () async {
      final path = emptyClone('ssh-twice');
      final repo = Repository.open(path);
      repo.remotes.add('origin', 'user@somewhere:$originPath');

      await fetch(repo, repo.remotes.named('origin')!,
          sshCommand: sshCommand);
      final again = await fetch(repo, repo.remotes.named('origin')!,
          sshCommand: sshCommand);
      repo.close();

      expect(again.objectsReceived, 0);
      expect(again.changed, isEmpty);
    });

    test('a later commit arrives on the next fetch', () async {
      final path = emptyClone('ssh-later');
      var repo = Repository.open(path);
      repo.remotes.add('origin', 'user@somewhere:$originPath');
      await fetch(repo, repo.remotes.named('origin')!,
          sshCommand: sshCommand);
      repo.close();

      File(p.join(originPath, 'a.txt')).writeAsStringSync('one\ntwo\nthree\n');
      git(['commit', '-qam', 'third']);

      repo = Repository.open(path);
      final second = await fetch(
        repo,
        repo.remotes.named('origin')!,
        sshCommand: sshCommand,
      );
      repo.close();

      expect(second.objectsReceived, greaterThan(0));
      expect(second.changed.map((u) => u.ref), ['refs/remotes/origin/main']);
      expect(
        git(['rev-list', '--count', 'refs/remotes/origin/main'], cwd: path)
            .trim(),
        '3',
      );
      git(['fsck', '--no-progress'], cwd: path);
    });

    test('falls back to version 0 when the far end does not offer 2',
        () async {
      final directory = Directory(p.join(scratch.path, 'v0'))..createSync();
      final script = writeFakeSsh(directory.path, offerVersion2: false);

      final path = emptyClone('ssh-v0');
      final repo = Repository.open(path);
      repo.remotes.add('origin', 'user@somewhere:$originPath');

      final result = await fetch(
        repo,
        repo.remotes.named('origin')!,
        sshCommand: '"${Platform.resolvedExecutable}" "$script"',
      );
      repo.close();

      expect(result.protocolVersion, 0);
      expect(result.objectsReceived, greaterThan(0));
      git(['fsck', '--no-progress'], cwd: path);
    });

    test('a command with arguments is split the way a shell would', () {
      expect(SshConnection.splitCommand('ssh'), ['ssh']);
      expect(SshConnection.splitCommand('ssh -i key'), ['ssh', '-i', 'key']);
      expect(
        SshConnection.splitCommand('"C:/Program Files/ssh.exe" -v'),
        ['C:/Program Files/ssh.exe', '-v'],
      );
      expect(
        SshConnection.splitCommand("ssh -o 'StrictHostKeyChecking no'"),
        ['ssh', '-o', 'StrictHostKeyChecking no'],
      );
    });
  });

  // -------------------------------------------------------------------------
  group('over the git daemon', () {
    late Process daemon;
    late int port;

    setUp(() async {
      port = 9500 + (DateTime.now().microsecondsSinceEpoch % 400);
      daemon = await Process.start('git', [
        'daemon',
        '--reuseaddr',
        '--listen=127.0.0.1',
        '--port=$port',
        '--export-all',
        '--base-path=${scratch.path}',
        scratch.path,
      ]);
      daemon.stderr.drain<void>();
      daemon.stdout.drain<void>();
      // The daemon needs a moment before it is listening.
      for (var i = 0; i < 50; i++) {
        try {
          final probe = await Socket.connect('127.0.0.1', port);
          probe.destroy();
          break;
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    tearDown(() async {
      daemon.kill();
      await daemon.exitCode;
    });

    test('fetches over a socket', () async {
      final path = emptyClone('daemon-clone');
      final repo = Repository.open(path);
      repo.remotes.add('origin', 'git://127.0.0.1:$port/origin');

      final result = await fetch(repo, repo.remotes.named('origin')!);

      expect(result.objectsReceived, greaterThan(0));
      expect(
        repo.refs.resolve('refs/remotes/origin/main')!.hex,
        git(['rev-parse', 'main']).trim(),
      );
      repo.close();

      git(['fsck', '--no-progress'], cwd: path);
      expect(
        git(['rev-list', '--count', 'refs/remotes/origin/main'], cwd: path)
            .trim(),
        '2',
      );
    });

    test('a second fetch with nothing new moves nothing', () async {
      final path = emptyClone('daemon-twice');
      final repo = Repository.open(path);
      repo.remotes.add('origin', 'git://127.0.0.1:$port/origin');

      await fetch(repo, repo.remotes.named('origin')!);
      final again = await fetch(repo, repo.remotes.named('origin')!);
      repo.close();

      expect(again.objectsReceived, 0);
      expect(again.changed, isEmpty);
    });
  }, skip: _hasGitDaemon() ? null : 'git daemon is not available here');
}

bool _hasGitDaemon() {
  final result = Process.runSync('git', ['daemon', '--help'],
      stdoutEncoding: utf8, stderrEncoding: utf8);
  return result.exitCode == 0 ||
      '${result.stdout}${result.stderr}'.contains('daemon');
}
