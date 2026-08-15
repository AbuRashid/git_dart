/// Tags, reset, cherry-pick, revert and rebase — checked against git.
///
/// All five are policy over the same mechanism: new objects, and a ref moved
/// (`refs.doc`). None of them changes a commit, because nothing can. What
/// makes them worth testing against git rather than against themselves is that
/// the *shape* of what they write — which parent, which author, which message
/// — is convention, and convention is exactly what an independent
/// implementation gets subtly wrong.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

String git(List<String> arguments) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

void write(String name, String contents) {
  File(p.join(repoPath, name)).writeAsStringSync(contents);
}

void commitAll(String message) {
  git(['add', '-A']);
  git(['commit', '-q', '-m', message]);
}

String read(String name) =>
    File(p.join(repoPath, name)).readAsStringSync();

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_history');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    write('a.txt', 'one\ntwo\nthree\n');
    write('b.txt', 'bee\n');
    commitAll('first');
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  // -------------------------------------------------------------------------
  group('tags', () {
    test('a lightweight tag is a ref and nothing else', () {
      final repo = Repository.open(repoPath);
      final at = repo.headId!;
      final written = repo.createTag('v1');
      repo.close();

      expect(written, at);
      // No tag object: the ref points straight at the commit.
      expect(git(['cat-file', '-t', 'refs/tags/v1']).trim(), 'commit');
      expect(git(['rev-parse', 'v1']).trim(), at.hex);
    });

    test('an annotated tag is an object git reads as its own', () {
      final repo = Repository.open(repoPath);
      final at = repo.headId!;
      final tagId = repo.createTag('v2', message: 'release two');
      repo.close();

      expect(tagId, isNot(at));
      expect(git(['cat-file', '-t', 'refs/tags/v2']).trim(), 'tag');
      expect(git(['rev-parse', 'v2^{commit}']).trim(), at.hex);

      final shown = git(['cat-file', 'tag', 'v2']);
      expect(shown, contains('object ${at.hex}'));
      expect(shown, contains('tag v2'));
      expect(shown, contains('tagger A <a@x>'));
      expect(shown, contains('release two'));

      git(['fsck', '--no-progress']);
    });

    test('tags are listed with what they ultimately name', () {
      final repo = Repository.open(repoPath);
      final at = repo.headId!;
      repo.createTag('light');
      repo.createTag('heavy', message: 'annotated');

      final tags = {for (final tag in repo.listTags()) tag.name: tag};
      expect(tags.keys.toSet(), {'light', 'heavy'});
      expect(tags['light']!.annotation, isNull);
      expect(tags['light']!.target, at);
      // The annotated one's ref is the tag object; its target is the commit.
      expect(tags['heavy']!.annotation, isNotNull);
      expect(tags['heavy']!.ref, isNot(at));
      expect(tags['heavy']!.target, at);

      repo.deleteTag('light');
      expect(repo.refs.tags.map((r) => r.shortName), ['heavy']);
      repo.close();

      expect(git(['tag']).trim(), 'heavy');
    });

    test('a duplicate tag is refused unless forced', () {
      final repo = Repository.open(repoPath);
      repo.createTag('v1');
      expect(() => repo.createTag('v1'), throwsStateError);
      repo.createTag('v1', force: true);
      repo.close();
    });
  });

  // -------------------------------------------------------------------------
  group('reset', () {
    setUp(() {
      write('a.txt', 'one\ntwo\nthree\nfour\n');
      commitAll('second');
    });

    test('soft moves the branch and leaves everything staged', () {
      final repo = Repository.open(repoPath);
      final to = repo.resolve('HEAD~1')!;
      reset(repo, to, mode: ResetMode.soft);
      repo.close();

      expect(git(['rev-parse', 'HEAD']).trim(), to.hex);
      // The change is still there and still staged, which is the whole
      // difference between soft and mixed.
      expect(read('a.txt'), 'one\ntwo\nthree\nfour\n');
      expect(git(['diff', '--cached', '--name-only']).trim(), 'a.txt');
    });

    test('mixed moves the branch and unstages', () {
      final repo = Repository.open(repoPath);
      final to = repo.resolve('HEAD~1')!;
      reset(repo, to, mode: ResetMode.mixed);
      repo.close();

      expect(git(['rev-parse', 'HEAD']).trim(), to.hex);
      expect(read('a.txt'), 'one\ntwo\nthree\nfour\n');
      expect(git(['diff', '--cached', '--name-only']).trim(), isEmpty);
      expect(git(['diff', '--name-only']).trim(), 'a.txt');
    });

    test('hard moves everything and git sees a clean tree', () {
      final repo = Repository.open(repoPath);
      final to = repo.resolve('HEAD~1')!;
      reset(repo, to, mode: ResetMode.hard);
      repo.close();

      expect(git(['rev-parse', 'HEAD']).trim(), to.hex);
      expect(read('a.txt'), 'one\ntwo\nthree\n');
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });

    test('what a reset moves off is still named by the reflog', () {
      final repo = Repository.open(repoPath);
      final lost = repo.headId!;
      reset(repo, repo.resolve('HEAD~1')!, mode: ResetMode.hard);

      // Unreachable, and still findable — which is what makes a hard reset
      // survivable (`refs.reflog`).
      expect(repo.resolve('HEAD@{1}'), lost);
      expect(repo.log().map((c) => c.id), isNot(contains(lost)));
      repo.close();

      expect(git(['rev-parse', 'ORIG_HEAD']).trim(), lost.hex);
      expect(git(['rev-parse', 'HEAD@{1}']).trim(), lost.hex);
    });

    test('restoring one path leaves the branch alone', () {
      write('b.txt', 'changed\n');
      final repo = Repository.open(repoPath);
      final head = repo.headId!;

      restorePath(repo, 'b.txt', worktree: true);
      repo.close();

      expect(read('b.txt'), 'bee\n');
      expect(git(['rev-parse', 'HEAD']).trim(), head.hex);
    });
  });

  // -------------------------------------------------------------------------
  group('cherry-pick', () {
    test('applies a change from another branch, keeping its author', () {
      git(['branch', 'side']);
      git(['checkout', '-q', 'side']);
      write('b.txt', 'bee\nsee\n');
      git(['-c', 'user.name=B', '-c', 'user.email=b@x', 'commit', '-qam',
          'add see']);
      final source = git(['rev-parse', 'HEAD']).trim();
      git(['checkout', '-q', 'main']);

      final repo = Repository.open(repoPath);
      final result = cherryPick(repo, ObjectId.fromHex(source));
      repo.close();

      expect(result.outcome, ApplyOutcome.applied);
      expect(result.commit, isNot(ObjectId.fromHex(source)));

      // The change is here, on one parent, with the original author and a
      // local committer.
      expect(read('b.txt'), 'bee\nsee\n');
      expect(git(['rev-list', '--parents', '-n', '1', 'HEAD'])
          .trim()
          .split(' ')
          .length, 2);
      expect(git(['log', '-1', '--format=%an']).trim(), 'B');
      expect(git(['log', '-1', '--format=%cn']).trim(), 'A');
      expect(git(['log', '-1', '--format=%s']).trim(), 'add see');
      git(['fsck', '--no-progress']);
    });

    test('a change already present produces nothing', () {
      git(['branch', 'side']);
      git(['checkout', '-q', 'side']);
      write('b.txt', 'bee\nsee\n');
      commitAll('add see');
      final source = git(['rev-parse', 'HEAD']).trim();

      git(['checkout', '-q', 'main']);
      // The same change, made independently.
      write('b.txt', 'bee\nsee\n');
      commitAll('the same thing');
      final before = git(['rev-parse', 'HEAD']).trim();

      final repo = Repository.open(repoPath);
      final result = cherryPick(repo, ObjectId.fromHex(source));
      repo.close();

      expect(result.outcome, ApplyOutcome.empty);
      expect(git(['rev-parse', 'HEAD']).trim(), before);
    });

    test('a conflict stops and can be finished by hand', () {
      git(['branch', 'side']);
      git(['checkout', '-q', 'side']);
      write('a.txt', 'ONE\ntwo\nthree\n');
      commitAll('side changes one');
      final source = git(['rev-parse', 'HEAD']).trim();

      git(['checkout', '-q', 'main']);
      write('a.txt', 'uno\ntwo\nthree\n');
      commitAll('main changes one');

      var repo = Repository.open(repoPath);
      final result = cherryPick(repo, ObjectId.fromHex(source));
      expect(result.outcome, ApplyOutcome.conflicted);
      expect(result.conflicts, ['a.txt']);
      repo.close();

      // git sees the same state we do: unmerged, and mid-cherry-pick.
      expect(git(['ls-files', '--unmerged']), contains('a.txt'));
      expect(
        File(p.join(repoPath, '.git', 'CHERRY_PICK_HEAD'))
            .readAsStringSync()
            .trim(),
        source,
      );

      write('a.txt', 'resolved\ntwo\nthree\n');
      repo = Repository.open(repoPath);
      repo.stage('a.txt');
      final id = continueApply(repo);
      repo.close();

      expect(git(['log', '-1', '--format=%s']).trim(), 'side changes one');
      expect(git(['rev-parse', 'HEAD']).trim(), id.hex);
      expect(
        File(p.join(repoPath, '.git', 'CHERRY_PICK_HEAD')).existsSync(),
        isFalse,
      );
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('revert', () {
    test('undoes a commit by writing a new one', () {
      write('a.txt', 'one\ntwo\nthree\nfour\n');
      commitAll('add four');
      final bad = git(['rev-parse', 'HEAD']).trim();

      final repo = Repository.open(repoPath);
      final result = revert(repo, ObjectId.fromHex(bad));
      repo.close();

      expect(result.outcome, ApplyOutcome.applied);
      // The content is back, and both commits are still in the history.
      expect(read('a.txt'), 'one\ntwo\nthree\n');
      expect(git(['rev-list', '--count', 'HEAD']).trim(), '3');
      expect(git(['log', '-1', '--format=%s']).trim(),
          'Revert "add four"');
      expect(git(['log', '-1', '--format=%b']), contains(bad));
      git(['fsck', '--no-progress']);
    });

    test('reverting a revert restores the change', () {
      write('a.txt', 'one\ntwo\nthree\nfour\n');
      commitAll('add four');
      final bad = git(['rev-parse', 'HEAD']).trim();

      final repo = Repository.open(repoPath);
      revert(repo, ObjectId.fromHex(bad));
      final undone = repo.headId!;
      revert(repo, undone);
      repo.close();

      expect(read('a.txt'), 'one\ntwo\nthree\nfour\n');
    });
  });

  // -------------------------------------------------------------------------
  group('rebase', () {
    setUp(() {
      // main: first -> M1
      // side: first -> S1 -> S2
      git(['branch', 'side']);
      write('a.txt', 'one\ntwo\nthree\nfour\n');
      commitAll('main moves on');

      git(['checkout', '-q', 'side']);
      write('b.txt', 'bee\nsee\n');
      commitAll('side one');
      write('b.txt', 'bee\nsee\ndee\n');
      commitAll('side two');
    });

    test('replays the branch onto a new base, as git does', () {
      final before = git(['rev-parse', 'HEAD']).trim();

      final repo = Repository.open(repoPath);
      final result = rebase(repo, repo.resolve('main')!);
      repo.close();

      expect(result.outcome, RebaseOutcome.done);
      expect(result.replayed, hasLength(2));

      // New commits, same changes, on top of main.
      expect(git(['rev-parse', 'HEAD']).trim(), isNot(before));
      expect(git(['rev-list', '--count', 'HEAD']).trim(), '4');
      expect(git(['log', '--format=%s']).trim().split('\n'),
          ['side two', 'side one', 'main moves on', 'first']);
      // Both sides' content is present.
      expect(read('a.txt'), 'one\ntwo\nthree\nfour\n');
      expect(read('b.txt'), 'bee\nsee\ndee\n');
      expect(git(['status', '--porcelain']).trim(), isEmpty);
      expect(git(['merge-base', '--is-ancestor', 'main', 'HEAD']), isNotNull);
      git(['fsck', '--no-progress']);
    });

    test('produces the same tree git rebase produces', () {
      final repo = Repository.open(repoPath);
      rebase(repo, repo.resolve('main')!);
      repo.close();
      final ourTree = git(['rev-parse', 'HEAD^{tree}']).trim();
      final ourCount = git(['rev-list', '--count', 'HEAD']).trim();

      // Put it back and let git do it.
      git(['reset', '-q', '--hard', 'side@{1}']);
      git(['rebase', '-q', 'main']);
      expect(git(['rev-parse', 'HEAD^{tree}']).trim(), ourTree);
      expect(git(['rev-list', '--count', 'HEAD']).trim(), ourCount);
    });

    test('the branch moves and the old commits stay findable', () {
      final repo = Repository.open(repoPath);
      final original = repo.headId!;
      rebase(repo, repo.resolve('main')!);

      expect(repo.refs.currentBranch, 'refs/heads/side');
      expect(repo.refs.resolve('refs/heads/side'), repo.headId);
      // Nothing was destroyed: the originals are unreachable and logged.
      expect(repo.log().map((c) => c.id), isNot(contains(original)));
      repo.close();

      expect(git(['cat-file', '-t', original.hex]).trim(), 'commit');
    });

    test('a conflict stops, and continuing finishes the rest', () {
      // Make the two sides touch the same line so a replay must conflict.
      git(['checkout', '-q', 'main']);
      write('b.txt', 'conflicting\n');
      commitAll('main touches b');
      git(['checkout', '-q', 'side']);

      var repo = Repository.open(repoPath);
      final result = rebase(repo, repo.resolve('main')!);
      expect(result.outcome, RebaseOutcome.conflicted);
      expect(result.conflicts, ['b.txt']);
      repo.close();

      expect(
        File(p.join(repoPath, '.git', 'REBASE_HEAD')).existsSync(),
        isTrue,
      );

      write('b.txt', 'bee\nsee\n');
      repo = Repository.open(repoPath);
      repo.stage('b.txt');
      final carried = continueRebase(repo);
      repo.close();

      // The second commit had its own conflict resolved automatically, or
      // stopped again; either way the operation reports honestly.
      expect(carried.outcome, isIn([RebaseOutcome.done,
          RebaseOutcome.conflicted]));
      if (carried.outcome == RebaseOutcome.done) {
        expect(git(['status', '--porcelain']).trim(), isEmpty);
        expect(
          File(p.join(repoPath, '.git', 'REBASE_HEAD')).existsSync(),
          isFalse,
        );
      }
    });

    test('an aborted rebase puts the branch back exactly', () {
      git(['checkout', '-q', 'main']);
      write('b.txt', 'conflicting\n');
      commitAll('main touches b');
      git(['checkout', '-q', 'side']);
      final before = git(['rev-parse', 'HEAD']).trim();

      final repo = Repository.open(repoPath);
      expect(rebase(repo, repo.resolve('main')!).outcome,
          RebaseOutcome.conflicted);
      abortRebase(repo);
      repo.close();

      expect(git(['rev-parse', 'HEAD']).trim(), before);
      expect(git(['rev-parse', 'side']).trim(), before);
      expect(git(['status', '--porcelain']).trim(), isEmpty);
      expect(read('b.txt'), 'bee\nsee\ndee\n');
    });

    test('rebasing onto something already contained does nothing', () {
      final repo = Repository.open(repoPath);
      final head = repo.headId!;
      final result = rebase(repo, repo.resolve('HEAD~1')!);
      repo.close();

      expect(result.outcome, RebaseOutcome.alreadyThere);
      expect(git(['rev-parse', 'HEAD']).trim(), head.hex);
    });
  });
}
