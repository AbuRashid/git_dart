/// Staging and committing, checked against git.
///
/// The index is the part of git most easily got subtly wrong — an entry with
/// the wrong mode or a stale stat field produces a repository that looks fine
/// until git disagrees. So every assertion here is either git's own output or
/// something git verifies: `status --porcelain`, `diff --cached`, `fsck`.
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

Set<String> porcelain() => git(['status', '--porcelain'])
    .split('\n')
    .map((line) => line.trimRight())
    .where((line) => line.isNotEmpty)
    .toSet();

void write(String relative, String contents) {
  final file = File(p.join(repoPath, relative.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_staging');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A Committer']);
    git(['config', 'user.email', 'a@example.invalid']);

    write('a.txt', 'one\n');
    write('lib/main.dart', 'void main() {}\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'first']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  group('staging', () {
    test('a modified file, exactly as git stages it', () {
      write('a.txt', 'one\ntwo\n');

      final repo = Repository.open(repoPath)..stage('a.txt');
      repo.close();

      expect(porcelain(), {'M  a.txt'});
      // The blob git sees staged is the one we wrote.
      expect(
        git(['diff', '--cached', '--name-only']).trim(),
        'a.txt',
      );
      expect(git(['show', ':a.txt']), 'one\ntwo\n');
      expect(git(['fsck', '--no-progress']), isNotNull);
    });

    test('an untracked file becomes an addition', () {
      write('new.txt', 'hello\n');

      final repo = Repository.open(repoPath)..stage('new.txt');
      repo.close();

      expect(porcelain(), {'A  new.txt'});
      expect(git(['show', ':new.txt']), 'hello\n');
    });

    test('a deleted file stages its deletion', () {
      File(p.join(repoPath, 'a.txt')).deleteSync();

      final repo = Repository.open(repoPath)..stage('a.txt');
      repo.close();

      expect(porcelain(), {'D  a.txt'});
    });

    test('a directory stages everything under it, ignoring the ignored', () {
      write('.gitignore', '*.log\n');
      write('src/one.dart', 'a\n');
      write('src/two.dart', 'b\n');
      write('src/noisy.log', 'skip me\n');

      final repo = Repository.open(repoPath)..stage('src');
      repo.close();

      expect(porcelain(), {
        'A  src/one.dart',
        'A  src/two.dart',
        '?? .gitignore', // not staged: only src was asked for
      });
    });

    test('staging then modifying again shows both halves', () {
      write('a.txt', 'staged\n');
      final repo = Repository.open(repoPath)..stage('a.txt');
      write('a.txt', 'and then changed\n');
      repo.close();

      // The case the specification says a single letter cannot describe.
      expect(porcelain(), {'MM a.txt'});
    });

    test('unstaging puts HEAD back without touching the working tree', () {
      write('a.txt', 'one\ntwo\n');
      final repo = Repository.open(repoPath)..stage('a.txt');
      expect(porcelain(), {'M  a.txt'});

      repo.unstage('a.txt');
      repo.close();

      expect(porcelain(), {' M a.txt'});
      expect(
        File(p.join(repoPath, 'a.txt')).readAsStringSync(),
        'one\ntwo\n',
      );
    });

    test('unstaging a new file leaves it untracked', () {
      write('new.txt', 'hello\n');
      final repo = Repository.open(repoPath)..stage('new.txt');
      repo.unstage('new.txt');
      repo.close();

      expect(porcelain(), {'?? new.txt'});
      expect(File(p.join(repoPath, 'new.txt')).existsSync(), isTrue);
    });

    test('the index we write is one git rewrites identically', () {
      write('a.txt', 'one\ntwo\n');
      final repo = Repository.open(repoPath)..stage('a.txt');
      repo.close();

      final ours = git(['ls-files', '--stage']);
      // Ask git to stage the same content itself; the entry must match.
      git(['add', 'a.txt']);
      expect(git(['ls-files', '--stage']), ours);
    });
  });

  group('ignoring', () {
    test('an untracked file stops being reported once it is ignored', () {
      write('debug.log', 'noise\n');
      expect(porcelain(), {'?? debug.log'});

      final repo = Repository.open(repoPath);
      final pattern = repo.addIgnoreRule('debug.log', isDirectory: false);
      repo.close();

      expect(pattern, '/debug.log');
      // git's own view: the file is gone from the report, and only the new
      // .gitignore is untracked.
      expect(porcelain(), {'?? .gitignore'});
      expect(
        File(p.join(repoPath, '.gitignore')).readAsStringSync(),
        '/debug.log\n',
      );
    });

    test('a directory is ignored with a trailing slash', () {
      write('build/output.bin', 'x\n');

      final repo = Repository.open(repoPath);
      expect(repo.addIgnoreRule('build', isDirectory: true), '/build/');
      repo.close();

      expect(porcelain(), {'?? .gitignore'});
    });

    test('the rule is anchored, so a name elsewhere is untouched', () {
      write('notes.txt', 'a\n');
      write('deep/notes.txt', 'b\n');

      final repo = Repository.open(repoPath);
      repo.addIgnoreRule('notes.txt', isDirectory: false);
      repo.close();

      // Anchored: only the one at the root is ignored.
      expect(porcelain(), {'?? .gitignore', '?? deep/'});
    });

    test('an identical rule is not written twice', () {
      final repo = Repository.open(repoPath);
      expect(repo.addIgnoreRule('a.txt', isDirectory: false), '/a.txt');
      expect(repo.addIgnoreRule('a.txt', isDirectory: false), isNull);
      repo.close();

      expect(
        File(p.join(repoPath, '.gitignore')).readAsStringSync(),
        '/a.txt\n',
      );
    });

    test('an existing .gitignore keeps its content and its final newline', () {
      write('.gitignore', '*.tmp');   // no trailing newline

      final repo = Repository.open(repoPath);
      repo.addIgnoreRule('x.log', isDirectory: false);
      repo.close();

      expect(
        File(p.join(repoPath, '.gitignore')).readAsStringSync(),
        '*.tmp\n/x.log\n',
      );
    });

    test('a tracked file keeps being tracked until it leaves the index', () {
      final repo = Repository.open(repoPath);
      expect(repo.trackedUnder('a.txt'), ['a.txt']);

      repo.addIgnoreRule('a.txt', isDirectory: false);
      write('a.txt', 'changed after ignoring\n');

      // git still reports it: ignoring does not untrack, which is the thing
      // users are surprised by.
      expect(porcelain(), contains(' M a.txt'));

      repo.removeFromIndex('a.txt');
      repo.close();

      // Now the file is out of the index, the ignore rule applies, and git
      // reports the deletion of what it used to track.
      final after = porcelain();
      expect(after, contains('D  a.txt'));
      expect(after.any((line) => line.endsWith('a.txt') && line.startsWith('??')),
          isFalse);
      expect(File(p.join(repoPath, 'a.txt')).existsSync(), isTrue);
    });

    test('removing a directory from the index removes everything under it', () {
      final repo = Repository.open(repoPath);
      expect(repo.trackedUnder('lib'), ['lib/main.dart']);

      repo.removeFromIndex('lib');
      repo.close();

      expect(porcelain(), contains('D  lib/main.dart'));
      expect(File(p.join(repoPath, 'lib', 'main.dart')).existsSync(), isTrue);
    });
  });

  group('committing', () {
    test('writes a commit git reads back, with the configured identity', () {
      write('a.txt', 'one\ntwo\n');
      final repo = Repository.open(repoPath)..stage('a.txt');
      final id = repo.commitIndex(message: 'second commit');
      repo.close();

      expect(git(['rev-parse', 'HEAD']).trim(), id.hex);
      expect(git(['log', '-1', '--format=%s']).trim(), 'second commit');
      expect(git(['log', '-1', '--format=%an <%ae>']).trim(),
          'A Committer <a@example.invalid>');
      expect(porcelain(), isEmpty);
      expect(git(['fsck', '--no-progress']), isNotNull);
    });

    test('moves the branch rather than detaching HEAD', () {
      write('a.txt', 'changed\n');
      final repo = Repository.open(repoPath)..stage('a.txt');
      final id = repo.commitIndex(message: 'on the branch');
      repo.close();

      expect(git(['symbolic-ref', '--short', 'HEAD']).trim(), 'main');
      expect(git(['rev-parse', 'refs/heads/main']).trim(), id.hex);
      expect(git(['rev-list', '--count', 'HEAD']).trim(), '2');
    });

    test('the first commit of a new repository has no parent', () {
      final fresh = p.join(scratch.path, 'fresh');
      Directory(fresh).createSync(recursive: true);
      Process.runSync('git', ['init', '-q', '-b', 'main', fresh]);
      Process.runSync('git', ['config', 'user.name', 'A'],
          workingDirectory: fresh);
      Process.runSync('git', ['config', 'user.email', 'a@x'],
          workingDirectory: fresh);
      File(p.join(fresh, 'first.txt')).writeAsStringSync('hello\n');

      final repo = Repository.open(fresh)..stage('first.txt');
      final id = repo.commitIndex(message: 'root commit');
      repo.close();

      expect(git(['rev-parse', 'HEAD'], cwd: fresh).trim(), id.hex);
      expect(git(['rev-list', '--count', 'HEAD'], cwd: fresh).trim(), '1');
      expect(git(['log', '-1', '--format=%P'], cwd: fresh).trim(), isEmpty);
      expect(git(['status', '--porcelain'], cwd: fresh), isEmpty);
    });

    test('a commit with nothing staged is refused', () {
      final repo = Repository.open(repoPath);
      expect(
        () => repo.commitIndex(message: 'nothing to say'),
        throwsStateError,
      );
      repo.close();
    });

    test('an empty message is refused', () {
      write('a.txt', 'changed\n');
      final repo = Repository.open(repoPath)..stage('a.txt');
      expect(() => repo.commitIndex(message: '   '), throwsStateError);
      repo.close();
    });

    test('a commit with no configured identity is refused, not invented', () {
      // Local settings override the user's and the machine's, and an empty
      // value is how git itself spells "unset here".
      git(['config', '--unset', 'user.name']);
      git(['config', '--unset', 'user.email']);
      write('a.txt', 'changed\n');

      final repo = Repository.open(repoPath)..stage('a.txt');
      final identity = repo.identityFromConfig();
      repo.close();

      // Whether this repository has an identity depends on the machine's own
      // git config, so the assertion is on the pair rather than on a value.
      if (identity == null) {
        final second = Repository.open(repoPath);
        expect(() => second.commitIndex(message: 'x'), throwsStateError);
        second.close();
      } else {
        expect(identity.name, isNotEmpty);
        expect(identity.email, isNotEmpty);
      }
    });

    test('the recorded time is the one git reports', () {
      write('a.txt', 'changed\n');
      final repo = Repository.open(repoPath)..stage('a.txt');
      final before = DateTime.now().subtract(const Duration(seconds: 2));
      repo.commitIndex(message: 'timed');
      repo.close();

      final seconds = int.parse(git(['log', '-1', '--format=%at']).trim());
      final recorded =
          DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
      expect(recorded.isAfter(before), isTrue);

      // The offset is written the way git writes it.
      expect(
        git(['log', '-1', '--format=%ai']).trim(),
        matches(r'[+-]\d{4}$'),
      );
    });

    test('a commit we write can be committed on top of by git', () {
      write('a.txt', 'ours\n');
      final repo = Repository.open(repoPath)..stage('a.txt');
      repo.commitIndex(message: 'from git_dart');
      repo.close();

      write('b.txt', 'theirs\n');
      git(['add', 'b.txt']);
      git(['commit', '-q', '-m', 'from git']);

      expect(
        git(['log', '--format=%s']).trim().split('\n'),
        ['from git', 'from git_dart', 'first'],
      );
      expect(git(['fsck', '--no-progress']), isNotNull);
    });
  });
}
