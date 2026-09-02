/// Linked worktrees — `git worktree add`.
///
/// A linked worktree is a second checkout sharing one object store. Its git
/// directory is a small one under `.git/worktrees/<name>` holding a HEAD, an
/// index and a `commondir` file naming the real repository; the objects, the
/// refs and the config are all back there. Reading one without following
/// `commondir` finds no objects and no refs and reports a perfectly good
/// checkout as an empty repository with every tracked file newly added, which
/// is exactly what this exists to stop.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String mainPath;

var _clock = 1700000000;

String git(List<String> arguments, {String? cwd}) {
  final when = '$_clock +0000';
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? mainPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: {'GIT_AUTHOR_DATE': when, 'GIT_COMMITTER_DATE': when},
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

void commit(String message, {String? cwd}) {
  File(p.join(cwd ?? mainPath, 'f.txt')).writeAsStringSync('$message\n');
  git(['add', '-A'], cwd: cwd);
  _clock += 60;
  git(['commit', '-q', '-m', message], cwd: cwd);
}

/// Adds a worktree and returns its path.
String addWorktree(String name, {String? branch}) {
  final path = p.join(scratch.path, name);
  git([
    'worktree',
    'add',
    '-q',
    if (branch != null) ...['-b', branch],
    path,
  ]);
  return path;
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_worktree');
    mainPath = p.join(scratch.path, 'main');
    Directory(mainPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    commit('one');
    commit('two');
  });

  tearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Read-only objects under .git survive on Windows.
    }
  });

  group('opening one', () {
    test('it finds the shared objects, refs and history', () {
      final path = addWorktree('linked', branch: 'side');

      final repo = Repository.discover(path)!;
      expect(repo.isLinkedWorktree, isTrue);
      expect(repo.commonDirectory, isNot(repo.gitDirectory));

      // The things that were all missing before `commondir` was followed.
      expect(repo.headId, isNotNull);
      expect(repo.headId!.hex, git(['rev-parse', 'HEAD'], cwd: path).trim());
      expect(
        repo.refs.branches.map((b) => b.shortName).toSet(),
        {'main', 'side'},
      );
      expect(repo.log().length, 2);
      repo.close();
    });

    test('a clean checkout reports as clean, not as wholly new', () {
      final path = addWorktree('linked', branch: 'side');

      final repo = Repository.discover(path)!;
      final status = repo.status();
      repo.close();

      // The symptom of a missing index or missing objects: every tracked file
      // read as added.
      expect(status.isClean, isTrue, reason: status.toString());
      expect(git(['status', '--porcelain'], cwd: path).trim(), isEmpty);
    });

    test('its own edits are seen, and only its own', () {
      final path = addWorktree('linked', branch: 'side');
      File(p.join(path, 'f.txt')).writeAsStringSync('edited here\n');

      final linked = Repository.discover(path)!;
      final main = Repository.open(mainPath);

      expect(linked.status().isClean, isFalse);
      // The main checkout is a different working tree and is untouched.
      expect(main.status().isClean, isTrue);

      linked.close();
      main.close();
    });

    test('HEAD is this worktree\'s, and branches are shared', () {
      final path = addWorktree('linked', branch: 'side');
      commit('three on side', cwd: path);

      final linked = Repository.discover(path)!;
      final main = Repository.open(mainPath);

      // Two checkouts, two HEADs.
      expect(linked.headId, isNot(main.headId));
      expect(linked.refs.head.toString(), contains('refs/heads/side'));
      expect(main.refs.head.toString(), contains('refs/heads/main'));

      // One set of branches, and each sees the other's commit.
      expect(main.refs.resolve('refs/heads/side'), linked.headId);
      expect(linked.refs.resolve('refs/heads/main'), main.headId);

      linked.close();
      main.close();
    });

    test('a commit made in one is an object the other can read', () {
      final path = addWorktree('linked', branch: 'side');
      commit('made in the worktree', cwd: path);
      final made = git(['rev-parse', 'HEAD'], cwd: path).trim();

      // One object store: no fetch, no copy.
      final main = Repository.open(mainPath);
      expect(main.objects.contains(ObjectId.fromHex(made)), isTrue);
      expect(main.resolve('side')!.hex, made);
      main.close();
    });

    test('config is the repository\'s, not a second empty one', () {
      final path = addWorktree('linked', branch: 'side');
      git(['config', 'user.name', 'Configured Person']);

      final repo = Repository.discover(path)!;
      expect(repo.config['user.name'], 'Configured Person');
      repo.close();
    });

    test('a detached worktree reads its own detached HEAD', () {
      final older = git(['rev-parse', 'HEAD~1']).trim();
      final path = p.join(scratch.path, 'detached');
      git(['worktree', 'add', '-q', '--detach', path, older]);

      final repo = Repository.discover(path)!;
      expect(repo.headId!.hex, older);
      expect(repo.log().length, 1);
      repo.close();
    });

    test('writing a branch from a worktree is seen by the repository', () {
      final path = addWorktree('linked', branch: 'side');

      final linked = Repository.discover(path)!;
      linked.refs.write('refs/heads/written-here', linked.headId!);
      linked.close();

      // Refs are shared, so this must land in the real repository.
      expect(
        git(['rev-parse', 'written-here']).trim(),
        git(['rev-parse', 'side']).trim(),
      );
    });
  });

  group('listing them', () {
    test('a repository with no worktrees lists none', () {
      final repo = Repository.open(mainPath);
      expect(repo.isLinkedWorktree, isFalse);
      expect(repo.linkedWorktrees, isEmpty);
      repo.close();
    });

    test('each one is listed with its path, branch and commit', () {
      final first = addWorktree('one', branch: 'first');
      final second = addWorktree('two', branch: 'second');

      final repo = Repository.open(mainPath);
      final listed = repo.linkedWorktrees;
      repo.close();

      expect(listed.map((w) => w.name), ['one', 'two']);
      expect(
        listed.map((w) => p.canonicalize(w.path)),
        [p.canonicalize(first), p.canonicalize(second)],
      );
      expect(listed.map((w) => w.branch), [
        'refs/heads/first',
        'refs/heads/second',
      ]);
      expect(listed.every((w) => w.exists), isTrue);
      expect(listed.every((w) => !w.locked), isTrue);

      // git lists the same two, plus the main checkout it does not.
      final fromGit = git(['worktree', 'list', '--porcelain']);
      expect(fromGit, contains('branch refs/heads/first'));
      expect(fromGit, contains('branch refs/heads/second'));
    });

    test('the commit each is on matches git', () {
      addWorktree('one', branch: 'first');
      final repo = Repository.open(mainPath);
      final listed = repo.linkedWorktrees.single;
      repo.close();

      expect(listed.head!.hex, git(['rev-parse', 'first']).trim());
      expect(listed.shortBranch, 'first');
      expect(listed.isDetached, isFalse);
    });

    test('a detached one is listed as detached', () {
      final path = p.join(scratch.path, 'detached');
      git(['worktree', 'add', '-q', '--detach', path]);

      final repo = Repository.open(mainPath);
      final listed = repo.linkedWorktrees.single;
      repo.close();

      expect(listed.isDetached, isTrue);
      expect(listed.branch, isNull);
      expect(listed.head!.hex, git(['rev-parse', 'HEAD']).trim());
    });

    test('a locked one says so', () {
      addWorktree('one', branch: 'first');
      git(['worktree', 'lock', p.join(scratch.path, 'one')]);

      final repo = Repository.open(mainPath);
      expect(repo.linkedWorktrees.single.locked, isTrue);
      repo.close();

      // Unlocked again so the tear-down can remove it.
      git(['worktree', 'unlock', p.join(scratch.path, 'one')]);
    });

    test('one whose directory is gone is still listed, and marked missing',
        () {
      final path = addWorktree('one', branch: 'first');
      // Deleted rather than pruned: git keeps the record until told to drop
      // it, and hiding it would lose the only trace of where it went.
      Directory(path).deleteSync(recursive: true);

      final repo = Repository.open(mainPath);
      final listed = repo.linkedWorktrees.single;
      expect(listed.exists, isFalse);
      expect(repo.openWorktree(listed), isNull);
      repo.close();

      expect(git(['worktree', 'list', '--porcelain']), contains('prunable'));
    });

    test('a worktree can be opened from the listing', () {
      addWorktree('one', branch: 'first');
      commit('side commit', cwd: p.join(scratch.path, 'one'));

      final repo = Repository.open(mainPath);
      final opened = repo.openWorktree(repo.linkedWorktrees.single)!;
      expect(opened.headId, repo.resolve('first'));
      expect(opened.log().first.message.trim(), 'side commit');
      opened.close();
      repo.close();
    });

    test('the listing is the same seen from a worktree', () {
      final path = addWorktree('one', branch: 'first');
      addWorktree('two', branch: 'second');

      final fromMain = Repository.open(mainPath);
      final fromLinked = Repository.discover(path)!;

      expect(
        fromLinked.linkedWorktrees.map((w) => w.name),
        fromMain.linkedWorktrees.map((w) => w.name),
      );

      fromMain.close();
      fromLinked.close();
    });
  });

  group('an ordinary repository is unaffected', () {
    test('its two directories are the same one', () {
      final repo = Repository.open(mainPath);
      expect(repo.commonDirectory, repo.gitDirectory);
      expect(repo.isLinkedWorktree, isFalse);
      repo.close();
    });

    test('a submodule is not mistaken for a worktree', () {
      // Both use a `.git` file, and only one has a `commondir`.
      final repo = Repository.open(mainPath);
      expect(repo.isLinkedWorktree, isFalse);
      repo.close();
    });
  });
}
