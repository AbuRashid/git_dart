/// Pushing over ssh and the git daemon.
///
/// The receiving side is real `git receive-pack` in both cases. For ssh it is
/// reached the way transport_test.dart reaches upload-pack: the ssh command is
/// pointed at a stand-in that runs the far side locally, which exercises
/// everything except ssh itself. The daemon is a real `git daemon` started
/// with receive-pack enabled, and the group is skipped where there is none.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String workPath;

String git(List<String> arguments, {String? cwd}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? workPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

String bareRepository(String name) {
  final path = p.join(scratch.path, name);
  git(['init', '-q', '--bare', '-b', 'main', path]);
  return path;
}

/// A stand-in for ssh: takes the arguments ssh takes, ignores the host, and
/// runs the named git service locally with its pipes wired up the way ssh
/// would. The environment it passes on is recorded, so a test can see whether
/// the push asked for protocol version 2.
String writeFakeSsh(String directory) {
  final path = p.join(directory, 'fake_ssh.dart');
  final record = p.join(directory, 'ssh_protocol.txt');
  File(path).writeAsStringSync('''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final rest = <String>[];
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '-p' || arguments[i] == '-o') {
      i += 1;
      continue;
    }
    rest.add(arguments[i]);
  }
  final command = rest[1];
  final space = command.indexOf(' ');
  final service = command.substring(0, space);
  var target = command.substring(space + 1).trim();
  if (target.startsWith("'") && target.endsWith("'")) {
    target = target.substring(1, target.length - 1);
  }

  final asked = Platform.environment['GIT_PROTOCOL'] ?? '';
  File(${jsonEncode(record)}).writeAsStringSync(asked);

  final process = await Process.start(
    'git',
    [service.replaceFirst('git-', ''), target],
    environment: {'GIT_PROTOCOL': asked},
  );
  stdin.pipe(process.stdin);
  process.stdout.pipe(stdout);
  process.stderr.pipe(stderr);
  exitCode = await process.exitCode;
}
''');
  return path;
}

/// Replaces the tip of the current branch with a sibling commit, so the next
/// push is a rewind.
void rewrite() {
  git(['reset', '--quiet', '--hard', 'HEAD~1']);
  File(p.join(workPath, 'a.txt')).writeAsStringSync('rewritten\n');
  git(['commit', '-q', '-am', 'rewritten']);
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_push_transport');
    workPath = p.join(scratch.path, 'work');
    Directory(workPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    File(p.join(workPath, 'a.txt')).writeAsStringSync('one\n');
    File(p.join(workPath, 'lib.txt')).writeAsStringSync('library\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'first']);
    File(p.join(workPath, 'a.txt')).writeAsStringSync('one\ntwo\n');
    git(['commit', '-q', '-am', 'second']);
  });

  tearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // A daemon that has not quite finished exiting still holds a handle.
    }
  });

  // -------------------------------------------------------------------------
  group('pushing over ssh', () {
    late String sshCommand;
    late String bare;

    setUp(() {
      final script = writeFakeSsh(scratch.path);
      sshCommand = '"${Platform.resolvedExecutable}" "$script"';
      bare = bareRepository('ssh.git');
    });

    Future<PushResult> pushTo(
      Repository repo, {
      bool force = false,
      PushLease? lease,
      void Function(String)? onProgress,
    }) =>
        push(
          repo,
          repo.remotes.named('origin')!,
          force: force,
          lease: lease,
          sshCommand: sshCommand,
          onProgress: onProgress,
        );

    test('git receive-pack accepts a new branch, and git reads it', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', 'user@somewhere:$bare');

      final result = await pushTo(repo);
      repo.close();

      expect(result.ok, isTrue, reason: result.rejected.toString());
      expect(result.objectsSent, greaterThan(0));
      expect(result.statuses.single.ref, 'refs/heads/main');
      expect(result.statuses.single.from, isNull);

      expect(git(['rev-parse', 'refs/heads/main'], cwd: bare).trim(),
          git(['rev-parse', 'HEAD']).trim());
      git(['fsck', '--no-progress', '--strict'], cwd: bare);
      expect(git(['rev-list', '--count', 'main'], cwd: bare).trim(), '2');
      expect(
        git(['cat-file', 'blob', 'main:lib.txt'], cwd: bare),
        'library\n',
      );
      // The tracking ref moves, as it does over http.
      expect(git(['rev-parse', 'refs/remotes/origin/main']).trim(),
          git(['rev-parse', 'HEAD']).trim());
    });

    test('a push does not ask receive-pack for version 2', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', 'user@somewhere:$bare');
      await pushTo(repo);
      repo.close();

      expect(
        File(p.join(scratch.path, 'ssh_protocol.txt')).readAsStringSync(),
        isNot(contains('version=2')),
      );
    });

    test('a fast-forward lands on top, and a repeat sends nothing', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', 'ssh://user@somewhere/$bare');
      await pushTo(repo);

      File(p.join(workPath, 'd.txt')).writeAsStringSync('four\n');
      git(['add', '.']);
      git(['commit', '-q', '-m', 'fourth']);

      final progress = <String>[];
      final result = await pushTo(repo, onProgress: progress.add);
      expect(result.ok, isTrue, reason: result.rejected.toString());
      expect(result.statuses.single.from, isNotNull);
      expect(result.statuses.single.forced, isFalse);
      expect(progress, isNotEmpty);
      expect(git(['rev-list', '--count', 'main'], cwd: bare).trim(), '3');
      expect(git(['rev-parse', 'main'], cwd: bare).trim(),
          git(['rev-parse', 'HEAD']).trim());
      git(['fsck', '--no-progress', '--strict'], cwd: bare);

      final again = await pushTo(repo);
      repo.close();
      expect(again.isEmpty, isTrue);
      expect(again.objectsSent, 0);
    });

    test("the server's hook output arrives on the side-band", () async {
      final hook = File(p.join(bare, 'hooks', 'post-receive'))
        ..writeAsStringSync('#!/bin/sh\necho "hello from the hook"\n');
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['+x', hook.path]);
      }
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', 'user@somewhere:$bare');

      final progress = <String>[];
      final result = await pushTo(repo, onProgress: progress.add);
      repo.close();

      expect(result.ok, isTrue, reason: result.rejected.toString());
      expect(progress, contains('hello from the hook'));
    });

    test('a non-fast-forward is refused and the server is untouched', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', 'user@somewhere:$bare');
      await pushTo(repo);
      final onServer = git(['rev-parse', 'main'], cwd: bare).trim();

      rewrite();
      final result = await pushTo(repo);
      repo.close();

      expect(result.ok, isFalse);
      expect(result.rejected.single.rejected, 'not a fast-forward');
      expect(result.objectsSent, 0);
      expect(git(['rev-parse', 'main'], cwd: bare).trim(), onServer);
    });

    test('a forced push rewinds the branch', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', 'user@somewhere:$bare');
      await pushTo(repo);

      rewrite();
      final result = await pushTo(repo, force: true);
      repo.close();

      expect(result.ok, isTrue, reason: result.rejected.toString());
      expect(result.statuses.single.forced, isTrue);
      expect(git(['rev-parse', 'main'], cwd: bare).trim(),
          git(['rev-parse', 'HEAD']).trim());
      expect(git(['cat-file', 'blob', 'main:a.txt'], cwd: bare), 'rewritten\n');
      git(['fsck', '--no-progress', '--strict'], cwd: bare);
    });

    test('the server refuses what its own configuration forbids', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', 'user@somewhere:$bare');
      await pushTo(repo);
      git(['config', 'receive.denyNonFastForwards', 'true'], cwd: bare);
      final onServer = git(['rev-parse', 'main'], cwd: bare).trim();

      rewrite();
      final result = await pushTo(repo, force: true);
      repo.close();

      // Refused by git, not by this library: the reason is git's.
      expect(result.ok, isFalse);
      expect(result.rejected.single.rejected, isNotEmpty);
      expect(git(['rev-parse', 'main'], cwd: bare).trim(), onServer);
      expect(
        git(['rev-parse', 'refs/remotes/origin/main']).trim(),
        onServer,
      );
    });

    test('a lease lets a rewind through while nothing has moved', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', 'user@somewhere:$bare');
      await pushTo(repo);

      rewrite();
      final result = await pushTo(repo, lease: PushLease.fromTracking);
      repo.close();

      expect(result.ok, isTrue, reason: result.rejected.toString());
      expect(result.statuses.single.forced, isTrue);
      expect(git(['rev-parse', 'main'], cwd: bare).trim(),
          git(['rev-parse', 'HEAD']).trim());
      git(['fsck', '--no-progress', '--strict'], cwd: bare);
    });

    test('a stale lease is refused', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', 'user@somewhere:$bare');
      await pushTo(repo);
      final seen = repo.refs.resolve('refs/heads/main')!;

      // Somebody else pushes on top.
      final other = p.join(scratch.path, 'other');
      git(['clone', '-q', bare, other]);
      git(['config', 'user.name', 'B'], cwd: other);
      git(['config', 'user.email', 'b@x'], cwd: other);
      File(p.join(other, 'b.txt')).writeAsStringSync('theirs\n');
      git(['add', '.'], cwd: other);
      git(['commit', '-q', '-m', 'theirs'], cwd: other);
      git(['push', '-q', 'origin', 'main'], cwd: other);
      final theirs = git(['rev-parse', 'main'], cwd: bare).trim();

      rewrite();
      final result = await pushTo(repo,
          lease: PushLease.of({
            'refs/heads/main': seen,
          }));
      repo.close();

      expect(result.ok, isFalse);
      expect(result.rejected.single.rejected, contains('stale info'));
      expect(git(['rev-parse', 'main'], cwd: bare).trim(), theirs);
    });

    test('a missing repository is reported, not hung on', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add(
          'origin', 'user@somewhere:${p.join(scratch.path, 'missing.git')}');
      await expectLater(pushTo(repo), throwsA(isA<StateError>()));
      repo.close();
    });
  });

  // -------------------------------------------------------------------------
  group('pushing to the git daemon', () {
    late Process daemon;
    late int port;
    late String bare;

    setUp(() async {
      bare = bareRepository('daemon.git');
      port = 9500 + (DateTime.now().microsecondsSinceEpoch % 400);
      daemon = await Process.start('git', [
        'daemon',
        '--reuseaddr',
        '--listen=127.0.0.1',
        '--port=$port',
        '--export-all',
        // Push is off by default, as it should be: the daemon has no
        // authentication at all.
        '--enable=receive-pack',
        '--base-path=${scratch.path}',
        scratch.path,
      ]);
      daemon.stderr.drain<void>();
      daemon.stdout.drain<void>();
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

    test('a push over a socket lands, and git reads it', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', 'git://127.0.0.1:$port/daemon.git');

      final result = await push(repo, repo.remotes.named('origin')!);
      expect(result.ok, isTrue, reason: result.rejected.toString());
      expect(git(['rev-parse', 'main'], cwd: bare).trim(),
          git(['rev-parse', 'HEAD']).trim());
      git(['fsck', '--no-progress', '--strict'], cwd: bare);

      rewrite();
      final refused = await push(repo, repo.remotes.named('origin')!);
      expect(refused.ok, isFalse);

      final forced =
          await push(repo, repo.remotes.named('origin')!, force: true);
      repo.close();
      expect(forced.ok, isTrue, reason: forced.rejected.toString());
      expect(git(['rev-parse', 'main'], cwd: bare).trim(),
          git(['rev-parse', 'HEAD']).trim());
    });
  }, skip: _hasGitDaemon() ? null : 'git daemon is not available here');
}

bool _hasGitDaemon() {
  final result = Process.runSync('git', ['daemon', '--help'],
      stdoutEncoding: utf8, stderrEncoding: utf8);
  return result.exitCode == 0 ||
      '${result.stdout}${result.stderr}'.contains('daemon');
}
