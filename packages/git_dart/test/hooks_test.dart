/// Client-side hooks, as real scripts in a repository real git made.
///
/// Every hook here is a shell script run the way git runs it — through the
/// kernel's `#!` elsewhere, through Git for Windows' `sh` on Windows — so what
/// these tests check is that the hook was found where git finds it, handed
/// git's arguments, and obeyed as git obeys it. What was committed or pushed
/// is read back with git itself.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

String git(List<String> arguments, {String? cwd}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

void write(String relative, String contents) {
  final file = File(p.join(repoPath, relative.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// Installs a hook script, executable as git requires.
void hook(String name, String body, {String? directory}) {
  final dir = directory ?? p.join(repoPath, '.git', 'hooks');
  Directory(dir).createSync(recursive: true);
  final path = p.join(dir, name);
  File(path).writeAsStringSync('#!/bin/sh\n$body\n');
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['+x', path]);
  }
}

String? readGitFile(String name) {
  final file = File(p.join(repoPath, '.git', name));
  return file.existsSync() ? file.readAsStringSync() : null;
}

String head() => git(['rev-parse', 'HEAD']).trim();

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_hooks');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A Committer']);
    git(['config', 'user.email', 'a@example.invalid']);
    // A user-level hooksPath would redirect every test here.
    git(['config', 'core.hooksPath', '.git/hooks']);

    write('a.txt', 'one\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'first']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  group('commit', () {
    test('a failing pre-commit aborts: no commit, index untouched', () {
      hook('pre-commit', 'echo "lint says no"; echo "on stderr" >&2; exit 3');
      write('a.txt', 'two\n');
      git(['add', 'a.txt']);
      final before = head();
      final staged = git(['diff', '--cached', '--name-status']);

      final repo = Repository.open(repoPath);
      expect(
        () => repo.commitIndex(message: 'blocked'),
        throwsA(isA<HookFailedException>()
            .having((e) => e.hook, 'hook', 'pre-commit')
            .having((e) => e.exitCode, 'exitCode', 3)
            .having((e) => e.toString(), 'message',
                allOf(contains('lint says no'), contains('on stderr')))),
      );
      repo.close();

      expect(head(), before);
      expect(git(['diff', '--cached', '--name-status']), staged);
      expect(staged, contains('a.txt'));
    });

    test('commit-msg can rewrite the message', () {
      hook('commit-msg', r'''
printf 'Rewritten: %s\n\nSigned-off-by: Hook\n' "$(head -n1 "$1")" > "$1"
''');
      write('a.txt', 'two\n');
      final repo = Repository.open(repoPath)..stage('a.txt');
      final id = repo.commitIndex(message: 'original');
      repo.close();

      expect(head(), id.hex);
      expect(git(['log', '-1', '--format=%B']),
          'Rewritten: original\n\nSigned-off-by: Hook\n\n');
      expect(git(['fsck', '--strict']), isEmpty);
    });

    test('commit-msg failing aborts, and gets the message file', () {
      hook('commit-msg', r'''
grep -q JIRA- "$1" || { echo "missing ticket in $1"; exit 1; }
''');
      write('a.txt', 'two\n');
      final before = head();
      final repo = Repository.open(repoPath)..stage('a.txt');
      expect(
        () => repo.commitIndex(message: 'no ticket'),
        throwsA(isA<HookFailedException>().having((e) => e.output, 'output',
            contains('missing ticket in .git/COMMIT_EDITMSG'))),
      );
      expect(head(), before);
      repo.commitIndex(message: 'JIRA-1 has a ticket');
      repo.close();
      expect(git(['log', '-1', '--format=%s']).trim(), 'JIRA-1 has a ticket');
    });

    test('prepare-commit-msg gets the file and the source', () {
      hook('prepare-commit-msg', r'''
echo "$1 $2" > .git/prepare-args
echo "[prefix] $(cat "$1")" > "$1"
''');
      write('a.txt', 'two\n');
      final repo = Repository.open(repoPath)..stage('a.txt');
      repo.commitIndex(message: 'body');
      repo.close();

      expect(readGitFile('prepare-args'), '.git/COMMIT_EDITMSG message\n');
      expect(git(['log', '-1', '--format=%s']).trim(), '[prefix] body');
    });

    test('noVerify skips pre-commit and commit-msg, not the others', () {
      hook('pre-commit', 'exit 1');
      hook('commit-msg', 'exit 1');
      hook('prepare-commit-msg', 'touch .git/prepared');
      hook('post-commit', 'touch .git/posted');
      write('a.txt', 'two\n');

      final repo = Repository.open(repoPath)..stage('a.txt');
      final id = repo.commitIndex(message: 'unverified', noVerify: true);
      repo.close();

      expect(head(), id.hex);
      expect(readGitFile('prepared'), isNotNull);
      expect(readGitFile('posted'), isNotNull);
    });

    test('post-commit runs after the branch moved, with git\'s environment',
        () {
      hook('post-commit', r'''
git rev-parse HEAD > .git/post-commit-head
echo "${GIT_INDEX_FILE:+index}" > .git/post-commit-env
git rev-parse --absolute-git-dir > .git/post-commit-gitdir
exit 7
''');
      write('a.txt', 'two\n');
      final repo = Repository.open(repoPath)..stage('a.txt');
      // A post hook's exit status decides nothing.
      final id = repo.commitIndex(message: 'second');
      repo.close();

      expect(readGitFile('post-commit-head')!.trim(), id.hex);
      expect(readGitFile('post-commit-env')!.trim(), 'index');
      expect(
        p.equals(
              p.normalize(readGitFile('post-commit-gitdir')!.trim()),
              p.normalize(File(p.join(repoPath, '.git')).absolute.path),
            ) ||
            // Git for Windows may answer with a POSIX-style path.
            readGitFile('post-commit-gitdir')!.trim().endsWith('/repo/.git'),
        isTrue,
      );
    });
  });

  group('where hooks are found', () {
    test('core.hooksPath is honoured, relative to the working tree', () {
      git(['config', 'core.hooksPath', 'my-hooks']);
      hook('pre-commit', 'exit 1'); // in .git/hooks: must not run
      hook('post-commit', 'touch .git/from-hooks-path',
          directory: p.join(repoPath, 'my-hooks'));
      write('a.txt', 'two\n');

      final repo = Repository.open(repoPath)..stage('a.txt');
      repo.commitIndex(message: 'via hooksPath');
      repo.close();

      expect(readGitFile('from-hooks-path'), isNotNull);
      final reopened = Repository.open(repoPath);
      expect(
          DiskHookRunner.directoryFor(reopened), p.join(repoPath, 'my-hooks'));
      reopened.close();
    });

    test('without core.hooksPath, .git/hooks', () {
      git(['config', '--unset', 'core.hooksPath']);
      final repo = Repository.open(repoPath);
      // Only meaningful when the user has no global hooksPath of their own.
      if (repo.config['core.hooksPath'] == null) {
        expect(DiskHookRunner.directoryFor(repo),
            p.join(repoPath, '.git', 'hooks'));
      }
      repo.close();
    });

    test('.sample files never run', () {
      hook('pre-commit.sample', 'exit 1');
      hook('post-commit.sample', 'touch .git/sample-ran');
      write('a.txt', 'two\n');

      final repo = Repository.open(repoPath)..stage('a.txt');
      repo.commitIndex(message: 'samples are inert');
      repo.close();

      expect(readGitFile('sample-ran'), isNull);
      expect(git(['log', '-1', '--format=%s']).trim(), 'samples are inert');
    });

    test('a hook without the execute bit is ignored, as git ignores it', () {
      final path = p.join(repoPath, '.git', 'hooks', 'pre-commit');
      File(path).writeAsStringSync('#!/bin/sh\nexit 1\n');
      Process.runSync('chmod', ['-x', path]);
      write('a.txt', 'two\n');

      final repo = Repository.open(repoPath)..stage('a.txt');
      repo.commitIndex(message: 'not executable');
      repo.close();
      expect(git(['log', '-1', '--format=%s']).trim(), 'not executable');
    }, testOn: '!windows');
  });

  group('choosing the runner', () {
    test('HookRunner.none runs nothing', () {
      hook('pre-commit', 'exit 1');
      write('a.txt', 'two\n');
      final repo = Repository.open(repoPath)
        ..hooks = HookRunner.none
        ..stage('a.txt');
      repo.commitIndex(message: 'no hooks');
      repo.close();
      expect(git(['log', '-1', '--format=%s']).trim(), 'no hooks');
    });

    test('in-process hooks, falling back to the disk', () {
      hook('post-commit', 'touch .git/disk-post-commit');
      final seen = <String>[];
      write('a.txt', 'two\n');
      final repo = Repository.open(repoPath)
        ..hooks = HookRunner.inProcess({
          'pre-commit': (invocation) {
            seen.add('pre-commit ${invocation.environment['GIT_INDEX_FILE']}');
            return HookResult.success;
          },
          'commit-msg': (invocation) {
            final file = invocation.arguments.single;
            invocation.writeFile(
                file, '${invocation.readFile(file).trim()}  \n\n\n(checked)\n');
            return HookResult.success;
          },
        }, fallback: HookRunner.disk)
        ..stage('a.txt');
      repo.commitIndex(message: 'in process');

      expect(seen.single, startsWith('pre-commit '));
      expect(git(['log', '-1', '--format=%B']), 'in process\n\n(checked)\n\n');
      expect(readGitFile('disk-post-commit'), isNotNull);

      repo.hooks = HookRunner.inProcess({
        'pre-commit': (_) => const HookResult(1, 'refused in Dart'),
      });
      write('a.txt', 'three\n');
      repo.stage('a.txt');
      expect(
        () => repo.commitIndex(message: 'refused'),
        throwsA(isA<HookFailedException>()
            .having((e) => e.toString(), 'text', contains('refused in Dart'))),
      );
      repo.close();
    });
  });

  group('checkout', () {
    test('post-checkout gets the old HEAD, the new HEAD and 1', () {
      final first = head();
      git(['checkout', '-q', '-b', 'topic']);
      write('a.txt', 'topic\n');
      git(['commit', '-q', '-am', 'on topic']);
      final topic = head();
      git(['checkout', '-q', 'main']);
      hook('post-checkout', r'echo "$1 $2 $3" > .git/post-checkout-args');

      final repo = Repository.open(repoPath);
      repo.checkout('topic');
      expect(readGitFile('post-checkout-args'), '$first $topic 1\n');

      repo.checkout('main');
      expect(readGitFile('post-checkout-args'), '$topic $first 1\n');
      repo.close();
    });

    test('its exit status does not undo the checkout', () {
      git(['branch', 'other']);
      hook('post-checkout', 'exit 1');
      final repo = Repository.open(repoPath);
      repo.checkout('other');
      repo.close();
      expect(git(['symbolic-ref', 'HEAD']).trim(), 'refs/heads/other');
    });
  });

  group('merge', () {
    late String topic;

    setUp(() {
      git(['checkout', '-q', '-b', 'topic']);
      write('b.txt', 'theirs\n');
      git(['add', 'b.txt']);
      git(['commit', '-q', '-m', 'topic work']);
      topic = head();
      git(['checkout', '-q', 'main']);
      write('c.txt', 'ours\n');
      git(['add', 'c.txt']);
      git(['commit', '-q', '-m', 'main work']);
    });

    test('a failing pre-merge-commit leaves the merge for a commit to finish',
        () {
      hook('pre-merge-commit', 'echo "not now"; exit 1');
      hook('post-merge', 'touch .git/post-merge-ran');
      final ours = head();

      final repo = Repository.open(repoPath);
      expect(
        () => merge(repo, ObjectId.fromHex(topic), message: 'Merge topic'),
        throwsA(isA<HookFailedException>()
            .having((e) => e.toString(), 'text', contains('not now'))),
      );
      expect(head(), ours);
      expect(repo.isMerging, isTrue);
      expect(readGitFile('post-merge-ran'), isNull);

      repo.hooks = HookRunner.none;
      repo.commitIndex();
      repo.close();
      expect(git(['log', '-1', '--format=%P']).trim(), '$ours $topic');
      expect(git(['log', '-1', '--format=%s']).trim(), 'Merge topic');
    });

    test('commit-msg edits the merge message; post-merge runs with 0', () {
      hook('prepare-commit-msg', r'echo "$1 $2" > .git/prepare-args');
      hook('commit-msg', r'echo "Edited merge" > "$1"');
      hook('post-merge', r'echo "$1" > .git/post-merge-args');

      final repo = Repository.open(repoPath);
      final result = merge(repo, ObjectId.fromHex(topic));
      repo.close();

      expect(result.outcome, MergeOutcome.merged);
      expect(git(['log', '-1', '--format=%B']), 'Edited merge\n\n');
      expect(readGitFile('prepare-args'), '.git/MERGE_MSG merge\n');
      expect(readGitFile('post-merge-args'), '0\n');
      expect(readGitFile('MERGE_MSG'), isNull);
    });

    test('a fast-forward runs post-merge, not post-checkout', () {
      git(['reset', '-q', '--hard', 'HEAD~1']);
      hook('post-merge', r'echo "$1" > .git/post-merge-args');
      hook('post-checkout', 'touch .git/post-checkout-ran');

      final repo = Repository.open(repoPath);
      final result = merge(repo, ObjectId.fromHex(topic));
      repo.close();

      expect(result.outcome, MergeOutcome.fastForward);
      expect(readGitFile('post-merge-args'), '0\n');
      expect(readGitFile('post-checkout-ran'), isNull);
    });
  });

  group('rebase', () {
    test('a failing pre-rebase aborts before anything moves', () {
      git(['checkout', '-q', '-b', 'topic']);
      write('b.txt', 'topic\n');
      git(['add', 'b.txt']);
      git(['commit', '-q', '-m', 'topic work']);
      final before = head();
      git(['checkout', '-q', 'main']);
      write('c.txt', 'main\n');
      git(['add', 'c.txt']);
      git(['commit', '-q', '-m', 'main work']);
      final main = head();
      git(['checkout', '-q', 'topic']);
      hook('pre-rebase', r'echo "$1" > .git/pre-rebase-args; exit 1');

      final repo = Repository.open(repoPath);
      expect(() => rebase(repo, ObjectId.fromHex(main)),
          throwsA(isA<HookFailedException>()));
      expect(head(), before);
      expect(readGitFile('pre-rebase-args'), '$main\n');

      final result = rebase(repo, ObjectId.fromHex(main), noVerify: true);
      repo.close();
      expect(result.outcome, RebaseOutcome.done);
      expect(git(['rev-parse', 'HEAD~1']).trim(), main);
    });
  });

  group('push', () {
    late String bare;

    setUp(() {
      bare = p.join(scratch.path, 'remote.git');
      git(['init', '-q', '--bare', bare], cwd: scratch.path);
    });

    test('a failing pre-push aborts and the remote is unchanged', () async {
      hook('pre-push', r'''
echo "$1 $2" > .git/pre-push-args
cat > .git/pre-push-input
echo "push refused"
exit 1
''');
      final repo = Repository.open(repoPath);
      repo.remotes.add('origin', bare);

      await expectLater(
        push(repo, repo.remotes.named('origin')!),
        throwsA(isA<HookFailedException>()
            .having((e) => e.toString(), 'text', contains('push refused'))),
      );
      repo.close();

      expect(git(['for-each-ref'], cwd: bare), isEmpty);
      expect(readGitFile('pre-push-args'), 'origin $bare\n');
      expect(readGitFile('pre-push-input'),
          'refs/heads/main ${head()} refs/heads/main ${'0' * 40}\n');
    });

    test('a passing pre-push sees the remote\'s current value', () async {
      final repo = Repository.open(repoPath);
      repo.remotes.add('origin', bare);
      await push(repo, repo.remotes.named('origin')!);
      final old = head();

      write('a.txt', 'two\n');
      repo.stage('a.txt');
      final next = repo.commitIndex(message: 'second');
      hook('pre-push', r'cat > .git/pre-push-input');

      final result = await push(repo, repo.remotes.named('origin')!);
      expect(result.ok, isTrue);
      expect(readGitFile('pre-push-input'),
          'refs/heads/main ${next.hex} refs/heads/main $old\n');
      expect(git(['rev-parse', 'main'], cwd: bare).trim(), next.hex);

      // noVerify skips it.
      hook('pre-push', 'exit 1');
      write('a.txt', 'three\n');
      repo.stage('a.txt');
      final third = repo.commitIndex(message: 'third');
      await push(repo, repo.remotes.named('origin')!, noVerify: true);
      repo.close();
      expect(git(['rev-parse', 'main'], cwd: bare).trim(), third.hex);
    });
  });
}
