/// Revision syntax, checked against `git rev-parse`.
///
/// A revision is what people actually type, and the forms are not
/// interchangeable: `HEAD~1` walks the graph, `HEAD@{1}` reads the reflog,
/// `HEAD:file` looks inside a tree, `:file` looks in the index. Getting one of
/// them subtly wrong hands back a real object that answers a different
/// question, which is worse than an error — so every case here asks git the
/// same thing.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

var _clock = 1700000000;

String git(List<String> arguments) {
  final when = '$_clock +0000';
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: {'GIT_AUTHOR_DATE': when, 'GIT_COMMITTER_DATE': when},
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// What git makes of a revision, or null where it refuses it.
String? gitRev(String revision) {
  final result = Process.runSync(
    'git',
    ['rev-parse', '--verify', '--quiet', revision],
    workingDirectory: repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return result.exitCode == 0 ? (result.stdout as String).trim() : null;
}

String? ours(String revision) {
  final repo = Repository.open(repoPath);
  final id = repo.resolve(revision);
  repo.close();
  return id?.hex;
}

/// Both answers, so a mismatch names the revision that produced it.
void agrees(String revision) {
  expect(ours(revision), gitRev(revision), reason: 'resolving `$revision`');
}

void commit(String message, {String file = 'f.txt', String? content}) {
  File(p.join(repoPath, file)).writeAsStringSync(content ?? '$message\n');
  git(['add', '-A']);
  _clock += 60;
  git(['commit', '-q', '-m', message]);
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_revision');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  group('inside a revision', () {
    setUp(() {
      Directory(p.join(repoPath, 'lib')).createSync();
      commit('one', file: p.join('lib', 'x.dart'), content: 'first\n');
      commit('two', file: p.join('lib', 'x.dart'), content: 'second\n');
    });

    test('a path names the blob at it, not the commit', () {
      agrees('HEAD:lib/x.dart');

      // And it really is the blob's content, not the commit's name.
      final repo = Repository.open(repoPath);
      final id = repo.resolve('HEAD:lib/x.dart')!;
      expect(utf8.decode(repo.objects.readRaw(id)!.content), 'second\n');
      repo.close();
    });

    test('an older revision gives that revision\'s version of the file', () {
      agrees('HEAD~1:lib/x.dart');
      expect(ours('HEAD~1:lib/x.dart'), isNot(ours('HEAD:lib/x.dart')));

      final repo = Repository.open(repoPath);
      final id = repo.resolve('HEAD~1:lib/x.dart')!;
      expect(utf8.decode(repo.objects.readRaw(id)!.content), 'first\n');
      repo.close();
    });

    test('a directory names a tree', () {
      agrees('HEAD:lib');

      final repo = Repository.open(repoPath);
      expect(repo.objects.read(repo.resolve('HEAD:lib')!), isA<Tree>());
      repo.close();
    });

    test('an empty path names the commit\'s own tree', () {
      agrees('HEAD:');
      expect(ours('HEAD:'), ours('HEAD^{tree}'));
    });

    test('a path that is not there resolves to nothing', () {
      expect(ours('HEAD:lib/missing.dart'), isNull);
      expect(gitRev('HEAD:lib/missing.dart'), isNull);
    });

    test('a tag can be looked inside as well as a commit', () {
      git(['tag', '-a', 'v1', '-m', 'one']);
      agrees('v1:lib/x.dart');
      expect(ours('v1:lib/x.dart'), ours('HEAD:lib/x.dart'));
    });
  });

  group('inside the index', () {
    test('a bare colon reads what is staged, not what is committed', () {
      commit('one');
      // Staged and deliberately not committed: the two differ, so an
      // implementation that quietly read HEAD would still look right.
      File(p.join(repoPath, 'f.txt')).writeAsStringSync('staged\n');
      git(['add', '-A']);

      agrees(':f.txt');
      expect(ours(':f.txt'), isNot(ours('HEAD:f.txt')));

      final repo = Repository.open(repoPath);
      final id = repo.resolve(':f.txt')!;
      expect(utf8.decode(repo.objects.readRaw(id)!.content), 'staged\n');
      repo.close();
    });

    test('a stage number reads one side of a conflict', () {
      commit('base', content: 'base\n');
      git(['branch', 'side']);
      commit('ours', content: 'ours\n');
      git(['checkout', '-q', 'side']);
      commit('theirs', content: 'theirs\n');
      git(['checkout', '-q', 'main']);

      // Left conflicted on purpose: the three stages only exist here.
      final merge = Process.runSync(
        'git',
        ['merge', '--no-edit', 'side'],
        workingDirectory: repoPath,
      );
      expect(merge.exitCode, isNot(0), reason: 'the merge should conflict');

      agrees(':1:f.txt');
      agrees(':2:f.txt');
      agrees(':3:f.txt');

      final repo = Repository.open(repoPath);
      expect(
        utf8.decode(repo.objects.readRaw(repo.resolve(':2:f.txt')!)!.content),
        'ours\n',
      );
      expect(
        utf8.decode(repo.objects.readRaw(repo.resolve(':3:f.txt')!)!.content),
        'theirs\n',
      );
      repo.close();

      // While conflicted, stage 0 is exactly what is absent.
      expect(ours(':f.txt'), isNull);
      expect(gitRev(':f.txt'), isNull);
    });

    test('a path that is not staged resolves to nothing', () {
      commit('one');
      expect(ours(':nope.txt'), isNull);
      expect(gitRev(':nope.txt'), isNull);
    });
  });

  group('by message', () {
    test(':/text finds the newest commit whose message contains it', () {
      commit('add the parser');
      commit('fix the parser');
      commit('unrelated');

      agrees(':/the parser');
      // Newest wins: two commits match and the later one is the answer.
      expect(ours(':/the parser'), ours('HEAD~1'));
      agrees(':/add the');
      expect(ours(':/add the'), ours('HEAD~2'));
    });

    test('text nothing said resolves to nothing', () {
      commit('one');
      expect(ours(':/nothing said this'), isNull);
      expect(gitRev(':/nothing said this'), isNull);
    });
  });

  group('the previous checkout', () {
    test('@{-1} is the branch that was checked out before', () {
      commit('one');
      git(['checkout', '-q', '-b', 'feature']);
      commit('two');
      git(['checkout', '-q', 'main']);

      agrees('@{-1}');
      expect(ours('@{-1}'), ours('feature'));
      expect(ours('@{-1}'), isNot(ours('HEAD')));
    });

    test('@{-2} goes back one checkout further', () {
      commit('one');
      git(['checkout', '-q', '-b', 'first']);
      commit('two');
      git(['checkout', '-q', '-b', 'second']);
      commit('three');
      git(['checkout', '-q', 'main']);

      agrees('@{-1}');
      agrees('@{-2}');
      expect(ours('@{-1}'), ours('second'));
      expect(ours('@{-2}'), ours('first'));
    });

    test('it names the branch now, not where the branch stood then', () {
      commit('one');
      git(['checkout', '-q', '-b', 'feature']);
      commit('two');
      git(['checkout', '-q', 'main']);
      // feature moves after we left it.
      git(['checkout', '-q', 'feature']);
      commit('three');
      git(['checkout', '-q', 'main']);

      agrees('@{-1}');
      expect(ours('@{-1}'), ours('feature'));
    });

    test('further back than there are checkouts resolves to nothing', () {
      commit('one');
      expect(ours('@{-5}'), isNull);
      expect(gitRev('@{-5}'), isNull);
    });
  });

  group('the forms that already worked still do', () {
    setUp(() {
      commit('one');
      git(['tag', '-a', 'v1', '-m', 'one']);
      commit('two');
      commit('three');
    });

    test('names, walks and peels', () {
      for (final revision in [
        'HEAD',
        'main',
        'v1',
        'HEAD~1',
        'HEAD~2',
        'HEAD^',
        'v1^{commit}',
        'v1^{}',
        'HEAD^{tree}',
        'refs/heads/main',
      ]) {
        agrees(revision);
      }
    });

    test('a colon does not swallow a reflog or a suffix', () {
      agrees('HEAD@{0}');
      agrees('HEAD~1');
      expect(ours('HEAD@{0}'), ours('HEAD'));
    });
  });
}
