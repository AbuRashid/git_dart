/// Tests for the parts of the application that are not widgets: the persisted
/// list, the generated tokens, and the worker that every git call goes through.
///
/// The worker is exercised against a repository built by real git, for the
/// same reason git_dart's own suite is: agreement with git is the property
/// that matters, and a fixture written by hand only proves the author
/// consistent.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitexplorer/src/generated/tokens.dart';
import 'package:gitexplorer/src/git_worker.dart';
import 'package:gitexplorer/src/models.dart';
import 'package:gitexplorer/src/repository_store.dart';
import 'package:path/path.dart' as p;

import '../tool/generate_tokens.dart';

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

/// A store that keeps its file in [directory].
///
/// The store itself takes read and write functions rather than a directory,
/// because it has to compile for the web, where there is no directory to be
/// given. Putting the file back is the test's business.
RepositoryStore storeIn(Directory directory) {
  final file = File(p.join(directory.path, RepositoryStore.fileName));
  return RepositoryStore(
    read: (_) async => file.existsSync() ? file.readAsStringSync() : null,
    write: (_, value) async {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(value);
    },
  );
}

/// The commit blamed for each final line number, straight from git.
///
/// `HEAD` by default and not the working tree - `git blame` with nothing
/// named blames whatever is on disk, uncommitted changes included, which is
/// a different question from the one being checked here.
Map<int, String> _gitBlameShas(String path, [String revision = 'HEAD']) {
  final output = git(['blame', '--porcelain', revision, '--', path]);
  final shas = <int, String>{};
  for (final line in const LineSplitter().convert(output)) {
    final match = RegExp(r'^([0-9a-f]{40}) \d+ (\d+)').firstMatch(line);
    if (match != null) shas[int.parse(match.group(2)!)] = match.group(1)!;
  }
  return shas;
}

/// The commit a gitlink names in the tree, straight from git.
String _gitlinkSha(String repo, String path, [String revision = 'HEAD']) {
  final output = git(['ls-tree', revision, '--', path], cwd: repo);
  final match =
      RegExp(r'^160000 commit ([0-9a-f]{40})').firstMatch(output.trim());
  if (match == null) fail('no gitlink for $path in $repo at $revision');
  return match.group(1)!;
}

void main() {
  setUpAll(() {
    scratch = Directory.systemTemp.createTempSync('gitexplorer_test');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    write('a.txt', 'one\ntwo\n');
    write('lib/main.dart', 'void main() {}\n');
    write('lib/src/deep.dart', 'const x = 1;\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'first']);

    write('lib/main.dart', 'void main() {\n  print(1);\n}\n');
    git(['commit', '-q', '-am', 'second']);

    // Left dirty on purpose: the working tree view is the one with status.
    write('a.txt', 'one\ntwo\nthree\n');
    write('untracked.txt', 'new\n');
    git(['branch', 'side']);
  });

  tearDownAll(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // A worker isolate may still hold a pack open for a moment, and on
      // Windows an open file cannot be deleted. The directory is the
      // system's temporary one; leaving it is not worth failing a suite that
      // has already made its point.
    }
  });

  group('the persisted list', () {
    late RepositoryStore store;
    late Directory home;

    setUp(() {
      home = Directory(p.join(scratch.path, 'support${_counter++}'))
        ..createSync(recursive: true);
      store = storeIn(home);
    });

    test('round-trips what was added, in the order it was added', () async {
      // A path in this platform's own shape, because the name is derived by
      // splitting it: a backslash separates directories on Windows and is an
      // ordinary character everywhere else.
      final picked = p.join(
        Platform.isWindows ? r'C:\dev' : '/home/a/dev',
        'flutter',
      );

      await store.save(SavedState(repositories: [
        SavedRepository.forPath(picked),
        // A path from another platform is carried unchanged: the store keeps
        // what it was given rather than interpreting it.
        const SavedRepository(path: r'C:\dev\work', name: 'work'),
      ]));

      final loaded = await store.load();
      expect(
        loaded.repositories.map((r) => r.path),
        [picked, r'C:\dev\work'],
      );
      expect(loaded.repositories.first.name, 'flutter');
    });

    test('round-trips the theme, and defaults it when absent', () async {
      await store.save(const SavedState(theme: ThemeChoice.light));
      expect((await store.load()).theme, ThemeChoice.light);

      // A file written before the key existed still loads.
      File(p.join(home.path, RepositoryStore.fileName)).writeAsStringSync(
        jsonEncode({'version': 1, 'repositories': []}),
      );
      expect((await store.load()).theme, ThemeChoice.system);

      // As does one with a choice this build does not know.
      File(p.join(home.path, RepositoryStore.fileName)).writeAsStringSync(
        jsonEncode({'version': 1, 'repositories': [], 'theme': 'sepia'}),
      );
      expect((await store.load()).theme, ThemeChoice.system);
    });

    test('writes the shape the specification pins', () async {
      // The name is given rather than derived from the path: what this pins
      // is the shape written to the file, and deriving it would make the
      // vector depend on which platform is splitting `C:\dev\flutter`.
      await store.save(
        const SavedState(repositories: [
          SavedRepository(path: r'C:\dev\flutter', name: 'flutter'),
        ]),
      );
      final written =
          File(p.join(home.path, RepositoryStore.fileName)).readAsStringSync();

      // The vector of `persistence.vector`, transcribed.
      expect(
        written,
        r'{"version":1,"repositories":[{"path":"C:\\dev\\flutter",'
        r'"name":"flutter"}],"theme":"system"}',
      );
    });

    test('an absent file is an empty list, not a failure', () async {
      expect((await store.load()).repositories, isEmpty);
    });

    test('a corrupt file is an empty list, not a failure', () async {
      File(p.join(home.path, RepositoryStore.fileName))
          .writeAsStringSync('{not json');
      expect((await store.load()).repositories, isEmpty);
    });

    test('a newer version is refused rather than half-read', () async {
      File(p.join(home.path, RepositoryStore.fileName)).writeAsStringSync(
        jsonEncode({'version': 99, 'repositories': []}),
      );
      expect(store.load(), throwsStateError);
    });
  });

  group('the generated tokens', () {
    test('are what the specification says', () {
      // Spot checks against explorer.umsg, so that a token drifting from the
      // document fails here as well as in the generator's check mode.
      expect(persistedStateVersion, 1);
      expect(FileState.modified.code, 'M');
      expect(FileState.clean.shown, isFalse);
      expect(EntryKind.file.expands, isFalse);
      expect(EntryKind.directory.expands, isTrue);
      expect(RevisionKind.workingTree.hasStatus, isTrue);
      expect(RevisionKind.head.hasStatus, isFalse);
    });

    test('the artefact matches what the document renders to', () {
      // The generator's own check, run in-process. Starting a second Dart
      // process here deadlocks against the test runner's package lock, which
      // is why this calls the function rather than the command line.
      final where = locate();
      expect(
        where.output.readAsStringSync(),
        renderTokens(where.specification.readAsStringSync()),
        reason: 'lib/src/generated/tokens.dart is stale; run '
            'dart run tool/generate_tokens.dart',
      );
    });
  });

  group('the worker', () {
    late GitService service;

    setUp(() async {
      service = GitService();
      await service.start();
    });

    tearDown(() => service.dispose());

    test('opens a repository and reports what git reports', () async {
      final summary = await service.open(repoPath, 'repo');
      expect(summary.available, isTrue);
      expect(summary.branch, 'main');
      expect(summary.headSummary, 'second');
      expect(summary.branches, ['main', 'side']);

      final porcelain = git(['status', '--porcelain'])
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      expect(
        summary.changedCount + summary.untrackedCount,
        porcelain.length,
      );
    });

    test('cloning copies a repository and adds what arrived', () async {
      final into = p.join(scratch.path, 'cloned');
      final outcome = await service.cloneRepository(repoPath, into);

      expect(outcome.error, isNull);
      expect(outcome.succeeded, isTrue);
      expect(outcome.branch, 'main');
      expect(outcome.remoteWasEmpty, isFalse);

      // The clone is a repository this application can open, on the same
      // commit as the one it was taken from.
      final summary = await service.open(into, 'cloned');
      expect(summary.available, isTrue);
      expect(summary.headId, git(['rev-parse', 'HEAD']).trim());
      expect(File(p.join(into, 'a.txt')).existsSync(), isTrue);
    });

    test('cloning reports progress along the way, across the worker boundary',
        () async {
      // git_dart only bothers reporting progress on a local copy once there
      // is enough of it to be worth mentioning - `unpackLimit`, 100 objects -
      // so the fixture has to actually be that big, or nothing would ever
      // cross the wire to prove the relay works.
      final big = p.join(scratch.path, 'big-source');
      Directory(big).createSync(recursive: true);
      git(['init', '-q', '-b', 'main'], cwd: big);
      git(['config', 'user.name', 'A'], cwd: big);
      git(['config', 'user.email', 'a@x'], cwd: big);
      for (var i = 0; i < 120; i++) {
        File(p.join(big, 'file$i.txt')).writeAsStringSync('$i\n');
      }
      git(['add', '.'], cwd: big);
      git(['commit', '-q', '-m', 'a lot of files'], cwd: big);

      final into = p.join(scratch.path, 'cloned-with-progress');
      final seen = <String>[];

      final outcome = await service.cloneRepository(
        big,
        into,
        onProgress: seen.add,
      );

      expect(outcome.succeeded, isTrue);
      // Not asserting every word of it - that is git_dart's own contract,
      // proven by its suite - only that the one message this fixture is
      // guaranteed to produce actually crossed the worker boundary, which is
      // the part this test exists to check.
      expect(seen, contains(contains('packing')));
    });

    test('cloning into a folder with something in it is reported, not thrown',
        () async {
      final into = p.join(scratch.path, 'occupied');
      Directory(into).createSync();
      File(p.join(into, 'mine.txt')).writeAsStringSync('keep\n');

      final outcome = await service.cloneRepository(repoPath, into);

      expect(outcome.succeeded, isFalse);
      expect(outcome.error, isNotNull);
      expect(outcome.path, isNull);
      // Refused without touching what was there.
      expect(File(p.join(into, 'mine.txt')).readAsStringSync(), 'keep\n');
    });

    test('a folder holding no repository offers to become one', () async {
      final plain = Directory(p.join(scratch.path, 'plain'))
        ..createSync(recursive: true);
      final summary = await service.open(plain.path, 'plain');

      expect(summary.available, isFalse);
      expect(summary.reason, UnavailableReason.notARepository);
      expect(summary.canInitialise, isTrue);
    });

    test('a path that is gone is not offered anything', () async {
      final summary = await service.open(
        p.join(scratch.path, 'never-existed'),
        'gone',
      );
      expect(summary.available, isFalse);
      expect(summary.reason, UnavailableReason.missing);
      // There is nowhere to write, so nothing is offered
      // (`initialising.only-not-a-repository-is-offered`).
      expect(summary.canInitialise, isFalse);
    });

    test('a folder inside a repository finds that repository, and is not '
        'offered a nested one', () async {
      final inside = p.join(repoPath, 'lib');
      final summary = await service.open(inside, 'lib');
      expect(summary.available, isTrue);
      expect(summary.canInitialise, isFalse);
      expect(summary.branch, 'main');
    });

    test('initialising creates a repository git accepts', () async {
      final fresh = Directory(p.join(scratch.path, 'fresh'))
        ..createSync(recursive: true);

      final before = await service.open(fresh.path, 'fresh');
      expect(before.canInitialise, isTrue);

      final after = await service.initialise(fresh.path, 'fresh');
      expect(after.available, isTrue);
      expect(after.headId, isNull); // no commit yet, which is not an error
      expect(after.changedCount, 0);

      // git's opinion is the one that matters.
      expect(
        git(['rev-parse', '--is-inside-work-tree'], cwd: fresh.path).trim(),
        'true',
      );
      expect(git(['status', '--porcelain'], cwd: fresh.path), isEmpty);
      expect(
        git(['symbolic-ref', 'HEAD'], cwd: fresh.path).trim(),
        startsWith('refs/heads/'),
      );
    });

    test('the new repository takes the branch name git would have used',
        () async {
      final fresh = Directory(p.join(scratch.path, 'branch-name'))
        ..createSync(recursive: true);
      await service.initialise(fresh.path, 'branch-name');

      // Whatever init.defaultBranch says on this machine — read from the
      // user's own config rather than fixed (`initialising.default-branch`).
      final configured = Process.runSync(
        'git',
        ['config', '--get', 'init.defaultBranch'],
        stdoutEncoding: utf8,
      ).stdout.toString().trim();

      expect(
        git(['symbolic-ref', '--short', 'HEAD'], cwd: fresh.path).trim(),
        configured.isEmpty ? 'main' : configured,
      );
    });

    test('initialising refuses to write over an existing repository',
        () async {
      await expectLater(
        service.initialise(repoPath, 'repo'),
        throwsA(isA<GitWorkerException>()),
      );
      // And the repository it refused to touch is untouched.
      expect(git(['rev-parse', 'HEAD']).trim(), isNotEmpty);
    });

    test('initialising a folder that is not there fails rather than creating '
        'it', () async {
      await expectLater(
        service.initialise(p.join(scratch.path, 'nowhere'), 'nowhere'),
        throwsA(isA<GitWorkerException>()),
      );
      expect(Directory(p.join(scratch.path, 'nowhere')).existsSync(), isFalse);
    });

    test('lists the working tree with directories first', () async {
      final entries =
          await service.directory(repoPath, Revision.workingTree, '');
      expect(entries.first.kind, EntryKind.directory);
      expect(entries.map((e) => e.name), contains('a.txt'));
      expect(entries.map((e) => e.name), isNot(contains('.git')));
    });

    test('carries a file\'s state, and a directory\'s worst', () async {
      final root =
          await service.directory(repoPath, Revision.workingTree, '');
      final a = root.firstWhere((e) => e.name == 'a.txt');
      final untracked = root.firstWhere((e) => e.name == 'untracked.txt');
      expect(a.state, FileState.modified);
      expect(untracked.state, FileState.untracked);

      // lib/ is clean here, so it must not be marked.
      final lib = root.firstWhere((e) => e.name == 'lib');
      expect(lib.state, FileState.clean);
    });

    test('a historical tree has no status and matches git ls-tree', () async {
      final entries = await service.directory(repoPath, Revision.head, 'lib');
      // Directories first, which is the explorer's order and deliberately not
      // git's: a tree sorts `main.dart` before `src/`, and this list is for
      // reading rather than for hashing.
      expect(entries.map((e) => e.name), ['src', 'main.dart']);
      expect(entries.every((e) => e.state == FileState.clean), isTrue);

      // The names must still be git's, whatever order they are shown in.
      final theirs = {
        for (final line in git(['ls-tree', 'HEAD', 'lib/']).trim().split('\n'))
          line.split('\t')[1].split('/').last: line.split(RegExp(r'\s+'))[2],
      };
      expect({for (final e in entries) e.name: e.objectId}, theirs);
    });

    test('reads a file at a revision and from the working tree', () async {
      final atHead =
          await service.file(repoPath, Revision.head, 'a.txt');
      expect(atHead.text, 'one\ntwo\n');

      final onDisk =
          await service.file(repoPath, Revision.workingTree, 'a.txt');
      expect(onDisk.text, 'one\ntwo\nthree\n');
    });

    test('diffs a working-tree file against HEAD', () async {
      final diff =
          await service.fileDiff(repoPath, Revision.workingTree, 'a.txt');
      expect(diff.insertions, 1);
      expect(diff.deletions, 0);
      expect(diff.against, 'HEAD and the working tree');
      expect(diff.hunks.single.lines.last.text, 'three');
    });

    test('blames a file at HEAD, matching git line for line', () async {
      final blame = await service.blame(repoPath, Revision.head, 'a.txt');
      expect(blame.unavailable, isNull);
      expect(blame.at, git(['rev-parse', 'HEAD']).trim());

      final theirs = _gitBlameShas('a.txt');
      expect(blame.lines.length, theirs.length);
      for (final line in blame.lines) {
        expect(line.commitId, theirs[line.number], reason: 'line ${line.number}');
      }
    });

    test('blames a file that changed across two commits, matching git',
        () async {
      final blame =
          await service.blame(repoPath, Revision.head, 'lib/main.dart');
      final theirs = _gitBlameShas('lib/main.dart');
      expect(blame.lines.length, theirs.length);
      for (final line in blame.lines) {
        expect(line.commitId, theirs[line.number], reason: 'line ${line.number}');
      }
    });

    test('blaming the working tree blames HEAD, not the dirty file', () async {
      // a.txt has an uncommitted third line; blame has nothing to say about
      // it and reports HEAD's two lines instead.
      final blame =
          await service.blame(repoPath, Revision.workingTree, 'a.txt');
      expect(blame.at, git(['rev-parse', 'HEAD']).trim());
      expect(blame.lines.length, 2);
    });

    test('blaming a path that does not exist says why, not with an error',
        () async {
      final blame = await service.blame(repoPath, Revision.head, 'nope.txt');
      expect(blame.unavailable, isNotNull);
      expect(blame.lines, isEmpty);
    });

    test('history matches git rev-list', () async {
      final commits = await service.history(repoPath);
      expect(
        commits.map((c) => c.id).toList(),
        git(['rev-list', 'HEAD']).trim().split('\n'),
      );
      expect(commits.first.summary, 'second');
    });

    test('a commit reports the files it changed', () async {
      final head = git(['rev-parse', 'HEAD']).trim();
      final loaded = await service.commit(repoPath, head);
      expect(loaded.commit.summary, 'second');
      expect(loaded.changes.map((c) => c.path), ['lib/main.dart']);
      expect(loaded.changes.single.state, FileState.modified);

      final diff = await service.commitDiff(repoPath, head, 'lib/main.dart');
      final numstat = git(['diff', '--numstat', 'HEAD~1', 'HEAD'])
          .trim()
          .split(RegExp(r'\s+'));
      expect(diff.insertions, int.parse(numstat[0]));
      expect(diff.deletions, int.parse(numstat[1]));
      expect(diff.against, 'its first parent');
    });

    test('writes a file, and git sees the change', () async {
      await service.writeFile(
        repository: repoPath,
        path: 'lib/main.dart',
        contents: 'void main() {\n  print(2);\n}\n',
      );

      expect(
        File(p.join(repoPath, 'lib', 'main.dart')).readAsStringSync(),
        'void main() {\n  print(2);\n}\n',
      );
      expect(git(['status', '--porcelain']), contains('lib/main.dart'));

      // The cached status was dropped, so the tree is told the truth next time.
      final entries =
          await service.directory(repoPath, Revision.workingTree, 'lib');
      expect(
        entries.firstWhere((e) => e.name == 'main.dart').state,
        FileState.modified,
      );

      git(['checkout', '--', 'lib/main.dart']);
    });

    test('a save is refused when the file moved on under it', () async {
      const path = 'racy.txt';
      File(p.join(repoPath, path)).writeAsStringSync('first\n');
      final opened = await service.file(repoPath, Revision.workingTree, path);

      // Something else writes: another editor, a build, a checkout.
      File(p.join(repoPath, path)).writeAsStringSync('written by someone else\n');

      await expectLater(
        service.writeFile(
          repository: repoPath,
          path: path,
          contents: 'my version\n',
          expectedSize: opened.size,
          expectedModified: opened.modified,
        ),
        throwsA(isA<GitWorkerException>()),
      );
      // The other writer's content survives, which is the point.
      expect(
        File(p.join(repoPath, path)).readAsStringSync(),
        'written by someone else\n',
      );
    });

    test('creates a file and a folder, and refuses to overwrite', () async {
      final file = await service.createEntry(
        repository: repoPath,
        path: 'notes/today.md',
        kind: EntryKind.file,
      );
      expect(file.state, FileState.untracked);
      expect(File(p.join(repoPath, 'notes', 'today.md')).existsSync(), isTrue);

      // Every directory on the way, in one action.
      await service.createEntry(
        repository: repoPath,
        path: 'a/b/c',
        kind: EntryKind.directory,
      );
      expect(Directory(p.join(repoPath, 'a', 'b', 'c')).existsSync(), isTrue);

      await expectLater(
        service.createEntry(
          repository: repoPath,
          path: 'notes/today.md',
          kind: EntryKind.file,
        ),
        throwsA(isA<GitWorkerException>()),
      );
    });

    test('a write outside the working tree is refused', () async {
      for (final path in const [
        '../escaped.txt',
        'lib/../../escaped.txt',
        '.git/config',
        '.git/hooks/pre-commit',
      ]) {
        await expectLater(
          service.writeFile(
            repository: repoPath,
            path: path,
            contents: 'no',
          ),
          throwsA(isA<GitWorkerException>()),
          reason: path,
        );
      }
      expect(
        File(p.join(scratch.path, 'escaped.txt')).existsSync(),
        isFalse,
      );
      // The repository's own config is untouched.
      expect(git(['config', '--get', 'user.name']).trim(), 'A');
    });

    test('reports both halves of the status', () async {
      final staging = await service.staging(repoPath);

      // a.txt is modified but not staged; untracked.txt is neither.
      final a = staging.rows.firstWhere((r) => r.path == 'a.txt');
      expect(a.unstaged, FileState.modified);
      expect(a.staged, isNull);
      expect(a.canStage, isTrue);
      expect(a.canUnstage, isFalse);

      expect(
        staging.rows.firstWhere((r) => r.path == 'untracked.txt').isUntracked,
        isTrue,
      );
      expect(staging.hasStagedChanges, isFalse);
      expect(staging.identity, 'A <a@x>');
    });

    test('stages, and git agrees it is staged', () async {
      final after = await service.setStaged(repoPath, 'a.txt', staged: true);

      // Not trimmed: the first column of a porcelain line is the staged state,
      // and trimming would eat the space that says "nothing staged".
      expect(git(['status', '--porcelain']), contains('M  a.txt'));
      final a = after.rows.firstWhere((r) => r.path == 'a.txt');
      expect(a.staged, FileState.modified);
      expect(a.unstaged, isNull);
      expect(after.hasStagedChanges, isTrue);

      // And back again, without touching the file.
      final undone = await service.setStaged(repoPath, 'a.txt', staged: false);
      expect(undone.rows.firstWhere((r) => r.path == 'a.txt').staged, isNull);
      expect(git(['status', '--porcelain']), contains(' M a.txt'));
      expect(
        File(p.join(repoPath, 'a.txt')).readAsStringSync(),
        'one\ntwo\nthree\n',
      );
    });

    test('a file staged and then modified again appears in both halves',
        () async {
      await service.setStaged(repoPath, 'a.txt', staged: true);
      File(p.join(repoPath, 'a.txt')).writeAsStringSync('changed again\n');

      final staging = await service.staging(repoPath);
      final a = staging.rows.firstWhere((r) => r.path == 'a.txt');
      expect(a.staged, isNotNull);
      expect(a.unstaged, isNotNull);
      expect(staging.staged.map((r) => r.path), contains('a.txt'));
      expect(staging.notStaged.map((r) => r.path), contains('a.txt'));

      await service.setStaged(repoPath, 'a.txt', staged: false);
      File(p.join(repoPath, 'a.txt')).writeAsStringSync('one\ntwo\nthree\n');
    });

    test('commits what is staged, and git reads the commit', () async {
      await service.setStaged(repoPath, 'a.txt', staged: true);
      final commit = await service.commitStaged(repoPath, 'from the app');

      expect(git(['rev-parse', 'HEAD']).trim(), commit.id);
      expect(git(['log', '-1', '--format=%s']).trim(), 'from the app');
      expect(git(['status', '--porcelain']), isNot(contains('a.txt')));
      expect(commit.summary, 'from the app');

      // The repository is still one git considers sound.
      expect(git(['fsck', '--no-progress']), isNotNull);
      git(['reset', '--quiet', '--soft', 'HEAD~1']);
      git(['restore', '--staged', 'a.txt']);
    });

    test('a commit with nothing staged is refused', () async {
      await expectLater(
        service.commitStaged(repoPath, 'nothing here'),
        throwsA(isA<GitWorkerException>()),
      );
    });

    test('a commit with an empty message is refused', () async {
      await service.setStaged(repoPath, 'a.txt', staged: true);
      await expectLater(
        service.commitStaged(repoPath, '   '),
        throwsA(isA<GitWorkerException>()),
      );
      await service.setStaged(repoPath, 'a.txt', staged: false);
    });

    test('staging a directory stages everything under it', () async {
      File(p.join(repoPath, 'lib', 'extra.dart')).writeAsStringSync('x\n');
      await service.setStaged(repoPath, 'lib', staged: true);

      expect(git(['status', '--porcelain']).trim(), contains('A  lib/extra.dart'));

      await service.setStaged(repoPath, 'lib/extra.dart', staged: false);
      File(p.join(repoPath, 'lib', 'extra.dart')).deleteSync();
    });

    test('adds, lists and fetches a remote that is a folder', () async {
      // A second repository to fetch from, made with real git.
      final origin = p.join(scratch.path, 'origin');
      Directory(origin).createSync(recursive: true);
      git(['init', '-q', '-b', 'main'], cwd: origin);
      git(['config', 'user.name', 'A'], cwd: origin);
      git(['config', 'user.email', 'a@x'], cwd: origin);
      File(p.join(origin, 'shared.txt')).writeAsStringSync('hello\n');
      git(['add', '.'], cwd: origin);
      git(['commit', '-q', '-m', 'from the origin'], cwd: origin);

      final remotes = await service.addRemote(repoPath, 'origin', origin);
      expect(remotes.map((r) => r.name), ['origin']);
      expect(remotes.single.isLocal, isTrue);
      expect(remotes.single.canFetch, isTrue);

      final outcome = await service.fetchRemote(repoPath, 'origin');
      expect(outcome.error, isNull);
      expect(outcome.objectsReceived, greaterThan(0));
      expect(outcome.updated.single, contains('refs/remotes/origin/main'));

      // git's opinion of what arrived.
      expect(
        git(['rev-parse', 'refs/remotes/origin/main']).trim(),
        git(['rev-parse', 'main'], cwd: origin).trim(),
      );
      expect(
        git(['cat-file', 'blob', 'refs/remotes/origin/main:shared.txt']),
        'hello\n',
      );

      // Fetching again finds nothing new.
      final again = await service.fetchRemote(repoPath, 'origin');
      expect(again.objectsReceived, 0);
      expect(again.updated, isEmpty);

      // The tile's counts: this repository's branch against what the remote
      // had at the last fetch. Unrelated histories here, so everything on
      // both sides counts.
      final tile = (await service.remotes(repoPath)).single;
      expect(tile.trackingRef, 'refs/remotes/origin/main');
      expect(tile.hasCounts, isTrue);
      final gitCounts = git([
        'rev-list',
        '--left-right',
        '--count',
        'main...refs/remotes/origin/main',
      ]).trim().split(RegExp(r'\s+'));
      expect(tile.ahead, int.parse(gitCounts[0]));
      expect(tile.behind, int.parse(gitCounts[1]));

      await service.removeRemote(repoPath, 'origin');
      expect(await service.remotes(repoPath), isEmpty);
    });

    /// A repository of its own, so a test that rewrites history cannot
    /// disturb the fixture every other test in this file shares.
    String ownRepository(String name) {
      final path = p.join(scratch.path, name);
      Directory(path).createSync(recursive: true);
      git(['init', '-q', '-b', 'main'], cwd: path);
      git(['config', 'user.name', 'A'], cwd: path);
      git(['config', 'user.email', 'a@x'], cwd: path);
      File(p.join(path, 'a.txt')).writeAsStringSync('one\n');
      git(['add', '.'], cwd: path);
      git(['commit', '-q', '-m', 'first'], cwd: path);
      return path;
    }

    test('pushes the current branch to a bare repository', () async {
      final source = ownRepository('push-source');
      final bare = p.join(scratch.path, 'push-target.git');
      Process.runSync('git', ['init', '-q', '--bare', '-b', 'main', bare]);

      await service.addRemote(source, 'target', bare);
      final outcome = await service.pushRemote(source, 'target');

      expect(outcome.ok, isTrue, reason: '${outcome.rejected}${outcome.error}');
      expect(outcome.objectsSent, greaterThan(0));
      expect(outcome.updated.single, contains('refs/heads/main'));

      // git's opinion of what it received.
      expect(
        git(['rev-parse', 'refs/heads/main'], cwd: bare).trim(),
        git(['rev-parse', 'HEAD'], cwd: source).trim(),
      );
      expect(git(['fsck', '--no-progress'], cwd: bare), isNotNull);

      // Pushing again sends nothing.
      final again = await service.pushRemote(source, 'target');
      expect(again.ok, isTrue);
      expect(again.objectsSent, 0);
    });

    test('a push that would overwrite is refused until it is forced',
        () async {
      final source = ownRepository('force-source');
      final bare = p.join(scratch.path, 'force-target.git');
      Process.runSync('git', ['init', '-q', '--bare', '-b', 'main', bare]);

      await service.addRemote(source, 'force', bare);
      await service.pushRemote(source, 'force');
      final before = git(['rev-parse', 'main'], cwd: bare).trim();

      // A second commit on the source, then a rewrite that drops it.
      File(p.join(source, 'a.txt')).writeAsStringSync('two\n');
      git(['commit', '-q', '-am', 'second'], cwd: source);
      await service.pushRemote(source, 'force');

      git(['reset', '--quiet', '--hard', 'HEAD~1'], cwd: source);
      File(p.join(source, 'a.txt')).writeAsStringSync('rewritten\n');
      git(['commit', '-q', '-am', 'rewritten'], cwd: source);
      await service.refresh(source);

      final refused = await service.pushRemote(source, 'force');
      expect(refused.ok, isFalse);
      expect(refused.canForce, isTrue);
      expect(git(['rev-parse', 'main'], cwd: bare).trim(), isNot(before));

      final forced = await service.pushRemote(source, 'force', force: true);
      expect(forced.ok, isTrue);
      expect(
        git(['rev-parse', 'main'], cwd: bare).trim(),
        git(['rev-parse', 'HEAD'], cwd: source).trim(),
      );
    });
    test('pulls: fetches, then merges what arrived', () async {
      // An origin that moves on while this repository also moves on — the
      // case that needs a real merge rather than a fast-forward.
      final origin = p.join(scratch.path, 'pull-origin');
      Directory(origin).createSync(recursive: true);
      git(['init', '-q', '-b', 'main'], cwd: origin);
      git(['config', 'user.name', 'B'], cwd: origin);
      git(['config', 'user.email', 'b@x'], cwd: origin);
      File(p.join(origin, 'shared.txt')).writeAsStringSync('base\n');
      git(['add', '.'], cwd: origin);
      git(['commit', '-q', '-m', 'base'], cwd: origin);

      // A local clone of it, made with git so the setup is not in question.
      final local = p.join(scratch.path, 'pull-local');
      Process.runSync('git', ['clone', '-q', origin, local]);
      git(['config', 'user.name', 'A'], cwd: local);
      git(['config', 'user.email', 'a@x'], cwd: local);

      // Each side changes a different file.
      File(p.join(origin, 'theirs.txt')).writeAsStringSync('theirs\n');
      git(['add', '.'], cwd: origin);
      git(['commit', '-q', '-m', 'theirs'], cwd: origin);

      File(p.join(local, 'ours.txt')).writeAsStringSync('ours\n');
      git(['add', '.'], cwd: local);
      git(['commit', '-q', '-m', 'ours'], cwd: local);

      final outcome = await service.pullRemote(local, 'origin');

      expect(outcome.error, isNull);
      expect(outcome.conflicts, isEmpty);
      expect(outcome.mergeOutcome, 'merged');

      // Both sides' work is present and git is content.
      expect(File(p.join(local, 'ours.txt')).existsSync(), isTrue);
      expect(File(p.join(local, 'theirs.txt')).existsSync(), isTrue);
      expect(git(['status', '--porcelain'], cwd: local), isEmpty);
      expect(git(['fsck', '--no-progress'], cwd: local), isNotNull);
      expect(
        git(['log', '-1', '--format=%P'], cwd: local).trim().split(' '),
        hasLength(2),
      );
    });

    group('branches, tags, merging and undoing', () {
      String lines(String output) => output.trim();

      test('creates a branch and checks it out, and git agrees', () async {
        final path = ownRepository('checkout-create');

        final created =
            await service.createBranch(path, 'feature', checkout: true);
        expect(created.ok, isTrue);
        expect(created.summary.branch, 'feature');
        expect(created.summary.branches, ['feature', 'main']);
        expect(lines(git(['symbolic-ref', '--short', 'HEAD'], cwd: path)),
            'feature');

        File(p.join(path, 'b.txt')).writeAsStringSync('on feature\n');
        git(['add', '.'], cwd: path);
        git(['commit', '-q', '-m', 'feature work'], cwd: path);

        final back = await service.checkoutBranch(path, 'main');
        expect(back.ok, isTrue);
        expect(back.summary.branch, 'main');
        expect(File(p.join(path, 'b.txt')).existsSync(), isFalse);
        expect(git(['status', '--porcelain'], cwd: path), isEmpty);
      });

      test('a checkout that would overwrite a change is refused, naming it, '
          'until forced', () async {
        final path = ownRepository('checkout-blocked');
        git(['checkout', '-q', '-b', 'other'], cwd: path);
        File(p.join(path, 'a.txt')).writeAsStringSync('other\n');
        git(['commit', '-q', '-am', 'other'], cwd: path);
        git(['checkout', '-q', 'main'], cwd: path);
        File(p.join(path, 'a.txt')).writeAsStringSync('uncommitted\n');

        final refused = await service.checkoutBranch(path, 'other');
        expect(refused.ok, isFalse);
        expect(refused.blockedBy, ['a.txt']);
        expect(lines(git(['symbolic-ref', '--short', 'HEAD'], cwd: path)),
            'main');
        expect(
          File(p.join(path, 'a.txt')).readAsStringSync(),
          'uncommitted\n',
        );

        final forced =
            await service.checkoutBranch(path, 'other', force: true);
        expect(forced.ok, isTrue);
        expect(forced.summary.branch, 'other');
        expect(File(p.join(path, 'a.txt')).readAsStringSync(), 'other\n');
        expect(git(['status', '--porcelain'], cwd: path), isEmpty);
      });

      test('a remote branch checks out as a local branch that follows it',
          () async {
        final origin = ownRepository('track-origin');
        git(['branch', 'topic'], cwd: origin);
        final path = ownRepository('track-local');
        await service.addRemote(path, 'origin', origin);
        await service.fetchRemote(path, 'origin');

        final summary = await service.open(path, 'local');
        expect(summary.remoteBranches, containsAll(['origin/main', 'origin/topic']));

        final outcome = await service.createBranch(
          path,
          'topic',
          startPoint: 'origin/topic',
          fromRemote: true,
          checkout: true,
        );
        expect(outcome.summary.branch, 'topic');
        expect(outcome.summary.upstreams['topic'], 'origin/topic');
        expect(
          lines(git(['rev-parse', '--abbrev-ref', 'topic@{upstream}'],
              cwd: path)),
          'origin/topic',
        );
        expect(
          lines(git(['rev-parse', 'HEAD'], cwd: path)),
          lines(git(['rev-parse', 'topic'], cwd: origin)),
        );
      });

      test('the upstream can be set and forgotten', () async {
        final origin = ownRepository('upstream-origin');
        final path = ownRepository('upstream-local');
        await service.addRemote(path, 'origin', origin);
        await service.fetchRemote(path, 'origin');

        var summary = await service.setUpstream(path, 'main', 'origin/main');
        expect(summary.upstreams, {'main': 'origin/main'});
        expect(
          lines(git(['rev-parse', '--abbrev-ref', 'main@{upstream}'],
              cwd: path)),
          'origin/main',
        );

        summary = await service.setUpstream(path, 'main', null);
        expect(summary.upstreams, isEmpty);
        expect(
          Process.runSync('git', ['config', 'branch.main.merge'],
                  workingDirectory: path)
              .exitCode,
          1,
        );
      });

      test('merges a branch, writing a commit with both parents', () async {
        final path = ownRepository('merge-clean');
        git(['checkout', '-q', '-b', 'side'], cwd: path);
        File(p.join(path, 'side.txt')).writeAsStringSync('side\n');
        git(['add', '.'], cwd: path);
        git(['commit', '-q', '-m', 'side'], cwd: path);
        git(['checkout', '-q', 'main'], cwd: path);
        File(p.join(path, 'main.txt')).writeAsStringSync('main\n');
        git(['add', '.'], cwd: path);
        git(['commit', '-q', '-m', 'main'], cwd: path);

        final merged = await service.mergeBranch(path, 'side');
        expect(merged.ok, isTrue, reason: merged.error);
        expect(merged.outcome, 'merged');
        expect(
          lines(git(['log', '-1', '--format=%P'], cwd: path)).split(' '),
          hasLength(2),
        );
        expect(lines(git(['log', '-1', '--format=%s'], cwd: path)),
            "Merge branch 'side'");
        expect(git(['status', '--porcelain'], cwd: path), isEmpty);
      });

      test('a merge is refused while tracked files have changes', () async {
        final path = ownRepository('merge-dirty');
        git(['branch', 'side'], cwd: path);
        File(p.join(path, 'a.txt')).writeAsStringSync('dirty\n');

        await expectLater(
          service.mergeBranch(path, 'side'),
          throwsA(isA<GitWorkerException>()),
        );
        expect(File(p.join(path, 'a.txt')).readAsStringSync(), 'dirty\n');
      });

      /// Two branches that changed the same line.
      String conflicted(String name) {
        final path = ownRepository(name);
        git(['checkout', '-q', '-b', 'side'], cwd: path);
        File(p.join(path, 'a.txt')).writeAsStringSync('theirs\n');
        git(['commit', '-q', '-am', 'theirs'], cwd: path);
        git(['checkout', '-q', 'main'], cwd: path);
        File(p.join(path, 'a.txt')).writeAsStringSync('ours\n');
        git(['commit', '-q', '-am', 'ours'], cwd: path);
        return path;
      }

      test('a conflicted merge is reported, and can be abandoned', () async {
        final path = conflicted('merge-abort');
        final head = lines(git(['rev-parse', 'HEAD'], cwd: path));

        final merged = await service.mergeBranch(path, 'side');
        expect(merged.outcome, 'conflicted');
        expect(merged.conflicts, ['a.txt']);

        final during = await service.open(path, 'repo');
        expect(during.merging, isTrue);
        expect(during.preparedMessage, contains("Merge branch 'side'"));
        expect(
          File(p.join(path, '.git', 'MERGE_HEAD')).existsSync(),
          isTrue,
        );

        // Checking out elsewhere is not a way out of a merge.
        await expectLater(
          service.checkoutBranch(path, 'side'),
          throwsA(isA<GitWorkerException>()),
        );

        final after = await service.abortOperation(path);
        expect(after.merging, isFalse);
        expect(lines(git(['rev-parse', 'HEAD'], cwd: path)), head);
        expect(git(['status', '--porcelain'], cwd: path), isEmpty);
        expect(File(p.join(path, 'a.txt')).readAsStringSync(), 'ours\n');
      });

      test('a conflicted merge is finished by staging and committing', () async {
        final path = conflicted('merge-finish');
        await service.mergeBranch(path, 'side');

        File(p.join(path, 'a.txt')).writeAsStringSync('both\n');
        final staging = await service.setStaged(path, 'a.txt', staged: true);
        expect(staging.hasConflicts, isFalse);

        // The prepared message is used when none is typed.
        final commit = await service.commitStaged(path, '');
        expect(commit.parents, hasLength(2));
        expect(commit.summary, "Merge branch 'side'");
        expect((await service.open(path, 'repo')).merging, isFalse);
        expect(git(['status', '--porcelain'], cwd: path), isEmpty);
        expect(git(['fsck', '--no-progress'], cwd: path), isNotNull);
      });

      test('creates and deletes tags, lightweight and annotated', () async {
        final path = ownRepository('tags');
        final first = lines(git(['rev-parse', 'HEAD'], cwd: path));
        File(p.join(path, 'a.txt')).writeAsStringSync('two\n');
        git(['commit', '-q', '-am', 'second'], cwd: path);

        await service.createTag(path, 'light');
        final summary = await service.createTag(
          path,
          'v1.0',
          at: first,
          message: 'the first release',
        );
        expect(summary.tags, ['light', 'v1.0']);

        expect(lines(git(['cat-file', '-t', 'light'], cwd: path)), 'commit');
        expect(lines(git(['cat-file', '-t', 'v1.0'], cwd: path)), 'tag');
        expect(lines(git(['rev-parse', 'v1.0^{commit}'], cwd: path)), first);
        expect(
          git(['tag', '-l', '--format=%(contents)', 'v1.0'], cwd: path),
          contains('the first release'),
        );

        final after = await service.deleteTag(path, 'v1.0');
        expect(after.tags, ['light']);
        expect(lines(git(['tag', '-l'], cwd: path)), 'light');
      });

      test('renaming a remote keeps what was fetched from it', () async {
        final origin = ownRepository('rename-origin');
        final path = ownRepository('rename-local');
        await service.addRemote(path, 'origin', origin);
        await service.fetchRemote(path, 'origin');

        final remotes = await service.renameRemote(path, 'origin', 'upstream');
        expect(remotes.map((r) => r.name), ['upstream']);
        expect(remotes.single.neverFetched, isFalse);
        expect(
          lines(git(['rev-parse', 'refs/remotes/upstream/main'], cwd: path)),
          lines(git(['rev-parse', 'main'], cwd: origin)),
        );
      });

      test('discarding puts a file back to HEAD, staged half included',
          () async {
        final path = ownRepository('discard');
        File(p.join(path, 'a.txt')).writeAsStringSync('staged\n');
        git(['add', '.'], cwd: path);
        File(p.join(path, 'a.txt')).writeAsStringSync('staged and more\n');

        final staging = await service.discardChanges(path, 'a.txt');
        expect(staging.isEmpty, isTrue);
        expect(File(p.join(path, 'a.txt')).readAsStringSync(), 'one\n');
        expect(git(['status', '--porcelain'], cwd: path), isEmpty);
      });

      test('discarding a file HEAD does not have is refused, and deletes '
          'nothing', () async {
        final path = ownRepository('discard-new');
        File(p.join(path, 'new.txt')).writeAsStringSync('only copy\n');
        git(['add', '.'], cwd: path);

        await expectLater(
          service.discardChanges(path, 'new.txt'),
          throwsA(isA<GitWorkerException>()),
        );
        expect(File(p.join(path, 'new.txt')).existsSync(), isTrue);
      });

      test('resets in each strength, keeping what each says it keeps',
          () async {
        for (final strength in ResetStrength.values) {
          final path = ownRepository('reset-${strength.name}');
          final first = lines(git(['rev-parse', 'HEAD'], cwd: path));
          File(p.join(path, 'a.txt')).writeAsStringSync('two\n');
          git(['commit', '-q', '-am', 'second'], cwd: path);
          final second = lines(git(['rev-parse', 'HEAD'], cwd: path));

          final summary = await service.resetBranch(path, first, strength);
          expect(summary.headId, first);
          expect(lines(git(['rev-parse', 'ORIG_HEAD'], cwd: path)), second);

          final status = lines(git(['status', '--porcelain'], cwd: path));
          switch (strength) {
            case ResetStrength.soft:
              expect(status, 'M  a.txt');
            case ResetStrength.mixed:
              expect(status, 'M a.txt');
            case ResetStrength.hard:
              expect(status, isEmpty);
              expect(File(p.join(path, 'a.txt')).readAsStringSync(), 'one\n');
          }
        }
      });
    });

    group('stashing, cherry-picking, reverting and rebasing', () {
      String out(String path, List<String> arguments) =>
          git(arguments, cwd: path).trim();

      void commitFile(String path, String file, String text, String message) {
        File(p.join(path, file)).writeAsStringSync(text);
        git(['add', '.'], cwd: path);
        git(['commit', '-q', '-m', message], cwd: path);
      }

      test('stashes, lists, applies and drops, as git stash does', () async {
        final path = ownRepository('stash');
        File(p.join(path, 'a.txt')).writeAsStringSync('edited\n');

        var summary = await service.saveStash(path, message: 'half done');
        expect(summary.stashes.map((s) => s.message), ['half done']);
        expect(summary.changedCount, 0);
        expect(File(p.join(path, 'a.txt')).readAsStringSync(), 'one\n');
        // git sees the same stack.
        expect(out(path, ['stash', 'list']), contains('half done'));

        final applied = await service.applyStash(path, 0);
        expect(applied.ok, isTrue);
        expect(File(p.join(path, 'a.txt')).readAsStringSync(), 'edited\n');
        expect((await service.open(path, 'r')).stashes, hasLength(1));

        // Applying again is refused: the tree is no longer clean.
        await expectLater(
          service.applyStash(path, 0),
          throwsA(isA<GitWorkerException>()),
        );

        summary = await service.dropStash(path, 0);
        expect(summary.stashes, isEmpty);
        expect(out(path, ['stash', 'list']), isEmpty);
      });

      test('popping drops the stash, and untracked files can go too',
          () async {
        final path = ownRepository('stash-pop');
        File(p.join(path, 'a.txt')).writeAsStringSync('edited\n');
        File(p.join(path, 'new.txt')).writeAsStringSync('new\n');

        await service.saveStash(path, includeUntracked: true);
        expect(File(p.join(path, 'new.txt')).existsSync(), isFalse);

        final popped = await service.applyStash(path, 0, pop: true);
        expect(popped.ok, isTrue);
        expect(File(p.join(path, 'new.txt')).readAsStringSync(), 'new\n');
        expect(File(p.join(path, 'a.txt')).readAsStringSync(), 'edited\n');
        expect((await service.open(path, 'r')).stashes, isEmpty);
      });

      test('stashing nothing is refused', () async {
        final path = ownRepository('stash-empty');
        await expectLater(
          service.saveStash(path),
          throwsA(isA<GitWorkerException>()),
        );
      });

      test('cherry-picks a commit from another branch, listing what it can '
          'pick', () async {
        final path = ownRepository('pick');
        git(['checkout', '-q', '-b', 'side'], cwd: path);
        commitFile(path, 'b.txt', 'bee\n', 'add b');
        commitFile(path, 'c.txt', 'see\n', 'add c');
        git(['checkout', '-q', 'main'], cwd: path);

        final offered = await service.unmerged(path, 'side');
        expect(offered.map((c) => c.summary), ['add c', 'add b']);

        final picked = await service.cherryPick(path, offered.last.id);
        expect(picked.ok, isTrue);
        expect(picked.outcome, 'applied');
        expect(out(path, ['log', '-1', '--format=%s']), 'add b');
        expect(File(p.join(path, 'b.txt')).existsSync(), isTrue);
        expect(File(p.join(path, 'c.txt')).existsSync(), isFalse);
        expect(out(path, ['status', '--porcelain']), isEmpty);

        // Picking it again changes nothing, and says so.
        final again = await service.cherryPick(path, offered.last.id);
        expect(again.outcome, 'empty');
      });

      test('a conflicted cherry-pick is finished from the commit box, with '
          'an edited message', () async {
        final path = ownRepository('pick-conflict');
        git(['checkout', '-q', '-b', 'side'], cwd: path);
        commitFile(path, 'a.txt', 'theirs\n', 'side edits a');
        final source = out(path, ['rev-parse', 'HEAD']);
        git(['checkout', '-q', 'main'], cwd: path);
        commitFile(path, 'a.txt', 'ours\n', 'main edits a');

        final picked = await service.cherryPick(path, source);
        expect(picked.outcome, 'conflicted');
        expect(picked.conflicts, ['a.txt']);

        final during = await service.open(path, 'r');
        expect(during.inProgress, InProgress.cherryPick);
        expect(during.inProgressCommit, startsWith(source.substring(0, 8)));
        expect(during.preparedMessage, contains('side edits a'));

        // Nothing else that moves HEAD is allowed meanwhile.
        await expectLater(
          service.checkoutBranch(path, 'side'),
          throwsA(isA<GitWorkerException>()),
        );
        await expectLater(
          service.commitStaged(path, 'an ordinary commit'),
          throwsA(isA<GitWorkerException>()),
        );

        File(p.join(path, 'a.txt')).writeAsStringSync('both\n');
        await service.setStaged(path, 'a.txt', staged: true);
        final finished =
            await service.continueOperation(path, 'both edits of a');
        expect(finished.ok, isTrue);

        expect(out(path, ['log', '-1', '--format=%s']), 'both edits of a');
        expect(out(path, ['log', '-1', '--format=%P']).split(' '),
            hasLength(1));
        expect((await service.open(path, 'r')).busy, isFalse);
        expect(out(path, ['status', '--porcelain']), isEmpty);
      });

      test('a conflicted cherry-pick can be abandoned', () async {
        final path = ownRepository('pick-abort');
        git(['checkout', '-q', '-b', 'side'], cwd: path);
        commitFile(path, 'a.txt', 'theirs\n', 'side edits a');
        final source = out(path, ['rev-parse', 'HEAD']);
        git(['checkout', '-q', 'main'], cwd: path);
        commitFile(path, 'a.txt', 'ours\n', 'main edits a');
        final head = out(path, ['rev-parse', 'HEAD']);

        await service.cherryPick(path, source);
        final after = await service.abortOperation(path);
        expect(after.busy, isFalse);
        expect(out(path, ['rev-parse', 'HEAD']), head);
        expect(out(path, ['status', '--porcelain']), isEmpty);
        expect(File(p.join(path, 'a.txt')).readAsStringSync(), 'ours\n');
      });

      test('reverts a commit with a new one, as git revert does', () async {
        final path = ownRepository('revert');
        commitFile(path, 'b.txt', 'bee\n', 'add b');
        final bad = out(path, ['rev-parse', 'HEAD']);
        commitFile(path, 'c.txt', 'see\n', 'add c');

        final reverted = await service.revertCommit(path, bad);
        expect(reverted.ok, isTrue);
        expect(File(p.join(path, 'b.txt')).existsSync(), isFalse);
        expect(File(p.join(path, 'c.txt')).existsSync(), isTrue);
        expect(out(path, ['log', '-1', '--format=%s']), 'Revert "add b"');
        expect(out(path, ['status', '--porcelain']), isEmpty);
      });

      test('a merge commit is not reverted or cherry-picked here', () async {
        final path = ownRepository('revert-merge');
        git(['checkout', '-q', '-b', 'side'], cwd: path);
        commitFile(path, 'b.txt', 'bee\n', 'add b');
        git(['checkout', '-q', 'main'], cwd: path);
        commitFile(path, 'c.txt', 'see\n', 'add c');
        git(['merge', '-q', '--no-edit', 'side'], cwd: path);
        final merge = out(path, ['rev-parse', 'HEAD']);

        await expectLater(
          service.revertCommit(path, merge),
          throwsA(isA<GitWorkerException>()),
        );
        expect(out(path, ['rev-parse', 'HEAD']), merge);
      });

      test('rebases the current branch onto another, as git rebase does',
          () async {
        final path = ownRepository('rebase');
        git(['checkout', '-q', '-b', 'side'], cwd: path);
        commitFile(path, 'b.txt', 'bee\n', 'add b');
        commitFile(path, 'c.txt', 'see\n', 'add c');
        git(['checkout', '-q', 'main'], cwd: path);
        commitFile(path, 'd.txt', 'dee\n', 'add d');
        git(['checkout', '-q', 'side'], cwd: path);

        final rebased = await service.rebaseOnto(path, 'main');
        expect(rebased.ok, isTrue);
        expect(rebased.outcome, 'done');
        expect(rebased.replayed, 2);

        expect(out(path, ['symbolic-ref', '--short', 'HEAD']), 'side');
        expect(
          out(path, ['log', '--format=%s', 'main..side']).split('\n'),
          ['add c', 'add b'],
        );
        expect(out(path, ['merge-base', 'main', 'side']),
            out(path, ['rev-parse', 'main']));
        expect(out(path, ['status', '--porcelain']), isEmpty);

        final again = await service.rebaseOnto(path, 'main');
        expect(again.outcome, 'alreadyThere');
      });

      test('a rebase is refused while tracked files have changes', () async {
        final path = ownRepository('rebase-dirty');
        git(['branch', 'other'], cwd: path);
        File(p.join(path, 'a.txt')).writeAsStringSync('mine\n');

        await expectLater(
          service.rebaseOnto(path, 'other'),
          throwsA(isA<GitWorkerException>()),
        );
        expect(File(p.join(path, 'a.txt')).readAsStringSync(), 'mine\n');
      });

      /// A branch `side` with two commits, the first of which conflicts with
      /// `main`, checked out.
      String conflictedRebase(String name) {
        final path = ownRepository(name);
        git(['checkout', '-q', '-b', 'side'], cwd: path);
        commitFile(path, 'a.txt', 'theirs\n', 'side edits a');
        commitFile(path, 'b.txt', 'bee\n', 'side adds b');
        git(['checkout', '-q', 'main'], cwd: path);
        commitFile(path, 'a.txt', 'ours\n', 'main edits a');
        git(['checkout', '-q', 'side'], cwd: path);
        return path;
      }

      test('a conflicted rebase stops, says where, and continues', () async {
        final path = conflictedRebase('rebase-continue');

        final stopped = await service.rebaseOnto(path, 'main');
        expect(stopped.outcome, 'conflicted');
        expect(stopped.conflicts, ['a.txt']);

        final during = await service.open(path, 'r');
        expect(during.inProgress, InProgress.rebase);
        expect(during.inProgressCommit, endsWith('side edits a'));
        expect(during.rebaseRemaining, 1);
        expect(during.preparedMessage, contains('side edits a'));

        File(p.join(path, 'a.txt')).writeAsStringSync('both\n');
        await service.setStaged(path, 'a.txt', staged: true);
        final finished = await service.continueOperation(path, '');
        expect(finished.ok, isTrue);
        expect(finished.outcome, 'done');

        expect((await service.open(path, 'r')).busy, isFalse);
        expect(out(path, ['symbolic-ref', '--short', 'HEAD']), 'side');
        expect(
          out(path, ['log', '--format=%s', 'main..side']).split('\n'),
          ['side adds b', 'side edits a'],
        );
        expect(out(path, ['status', '--porcelain']), isEmpty);
      });

      test('a conflicted rebase can be abandoned, putting the branch back',
          () async {
        final path = conflictedRebase('rebase-abort');
        final before = out(path, ['rev-parse', 'side']);

        await service.rebaseOnto(path, 'main');
        final after = await service.abortOperation(path);
        expect(after.busy, isFalse);
        expect(out(path, ['rev-parse', 'side']), before);
        expect(out(path, ['symbolic-ref', '--short', 'HEAD']), 'side');
        expect(out(path, ['status', '--porcelain']), isEmpty);
      });
    });

    group('cancelling a read', () {
      /// A repository with enough history that a walk of it takes long
      /// enough to be cancelled part-way rather than winning the race.
      String longHistory(String name, {int commits = 120}) {
        final path = p.join(scratch.path, name);
        Directory(path).createSync(recursive: true);
        git(['init', '-q', '-b', 'main'], cwd: path);
        git(['config', 'user.name', 'A'], cwd: path);
        git(['config', 'user.email', 'a@x'], cwd: path);
        final lines = <String>[];
        for (var i = 0; i < commits; i++) {
          lines.add('line from commit $i');
          File(p.join(path, 'a.txt')).writeAsStringSync('${lines.join('\n')}\n');
          git(['add', '-A'], cwd: path);
          git(['commit', '-q', '-m', 'commit $i'], cwd: path);
        }
        return path;
      }

      test('a cancelled request stops, and the worker answers the next one',
          timeout: const Timeout(Duration(minutes: 3)), () async {
        final path = longHistory('cancel-history');
        await service.open(path, 'repo');

        final request = service.cancellable<List<CommitData>>(
          (handle) => service.history(path, limit: 100000, cancelHandle: handle),
        );
        // Cancelled immediately: the flag is a word of memory the worker
        // reads between commits, so it does not have to wait for the walk to
        // finish to be told.
        request.cancel();

        await expectLater(request.result, throwsA(isA<RequestCancelled>()));

        // The point of cancelling rather than disposing: the worker is still
        // there, with the repository still open.
        final summary = await service.open(path, 'repo');
        expect(summary.available, isTrue);
        final history = await service.history(path, limit: 10);
        expect(history, hasLength(10));
      });

      test('cancelling after the answer arrives changes nothing',
          timeout: const Timeout(Duration(minutes: 2)), () async {
        final path = longHistory('cancel-late', commits: 5);
        await service.open(path, 'repo');

        final request = service.cancellable<List<CommitData>>(
          (handle) => service.history(path, limit: 100, cancelHandle: handle),
        );
        final history = await request.result;
        expect(history, hasLength(5));

        // The flag has been released by now; saying stop to something that
        // already stopped must not throw or corrupt anything.
        request.cancel();
        expect(await service.history(path, limit: 5), hasLength(5));
      });

      test('a cancelled read leaves the repository untouched',
          timeout: const Timeout(Duration(minutes: 3)), () async {
        final path = longHistory('cancel-clean', commits: 60);
        await service.open(path, 'repo');
        final before = git(['rev-parse', 'HEAD'], cwd: path).trim();
        final indexBefore =
            File(p.join(path, '.git', 'index')).readAsBytesSync();

        final request = service.cancellable<StagingArea>(
          (handle) => service.staging(path),
        );
        request.cancel();
        // Staging is quick enough that it may well finish first; either
        // outcome is fine, and neither may have written anything.
        try {
          await request.result;
        } on RequestCancelled {
          // Also fine.
        }

        expect(git(['rev-parse', 'HEAD'], cwd: path).trim(), before);
        expect(
          File(p.join(path, '.git', 'index')).readAsBytesSync(),
          indexBefore,
        );
        expect(git(['status', '--porcelain'], cwd: path), isEmpty);
      });
    });

    test('a remote this build cannot reach says so rather than failing later',
        () async {
      final remotes =
          await service.addRemote(repoPath, 'ssh', 'git@example.invalid:x.git');
      expect(remotes.single.canFetch, isFalse);

      // Asking anyway is an outcome with a reason, not a crash.
      final outcome = await service.fetchRemote(repoPath, 'ssh');
      expect(outcome.error, isNotNull);

      await service.removeRemote(repoPath, 'ssh');
    });

    test('a failure comes back as a failed future, not a dead worker',
        () async {
      await expectLater(
        service.commit(repoPath, 'no-such-revision'),
        throwsA(isA<GitWorkerException>()),
      );
      // The worker is still answering, which is the point.
      final summary = await service.open(repoPath, 'repo');
      expect(summary.available, isTrue);
    });

    group('submodules', () {
      late String libPath;
      late String outerPath;

      setUpAll(() {
        libPath = p.join(scratch.path, 'submodule-lib');
        Directory(libPath).createSync(recursive: true);
        git(['init', '-q', '-b', 'main'], cwd: libPath);
        git(['config', 'user.name', 'A'], cwd: libPath);
        git(['config', 'user.email', 'a@x'], cwd: libPath);
        File(p.join(libPath, 'lib.txt')).writeAsStringSync('a library\n');
        git(['add', '.'], cwd: libPath);
        git(['commit', '-q', '-m', 'lib commit'], cwd: libPath);

        outerPath = p.join(scratch.path, 'submodule-outer');
        Directory(outerPath).createSync(recursive: true);
        git(['init', '-q', '-b', 'main'], cwd: outerPath);
        git(['config', 'user.name', 'A'], cwd: outerPath);
        git(['config', 'user.email', 'a@x'], cwd: outerPath);
        File(p.join(outerPath, 'readme.txt')).writeAsStringSync('outer\n');
        git(['add', '.'], cwd: outerPath);
        git(['commit', '-q', '-m', 'outer commit'], cwd: outerPath);

        // Recent git refuses to clone a bare local path unless told it is
        // allowed to, which `submodule add` does under the hood.
        for (final path in ['vendor/lib', 'vendor/uninit']) {
          git([
            '-c', 'protocol.file.allow=always',
            'submodule', 'add', '-q', libPath, path,
          ], cwd: outerPath);
        }
        git(['commit', '-q', '-m', 'add submodules'], cwd: outerPath);

        // Deinitialising empties the working tree but leaves the gitlink and
        // `.gitmodules` entry exactly as committed — the state a fresh clone
        // is in before anyone runs `submodule update --init`.
        git(['submodule', 'deinit', '-f', 'vendor/uninit'], cwd: outerPath);
      });

      test('reports a cloned submodule, matching git', () async {
        final data =
            await service.submodule(outerPath, Revision.head, 'vendor/lib');
        expect(data.unavailable, isNull);
        expect(data.name, 'vendor/lib');
        expect(data.url, libPath);
        expect(data.status, SubmoduleStatus.current);
        expect(data.recordedCommit, _gitlinkSha(outerPath, 'vendor/lib'));

        final checkedOut = git(['rev-parse', 'HEAD'],
                cwd: p.join(outerPath, 'vendor', 'lib'))
            .trim();
        expect(data.checkedOutCommit, checkedOut);
        expect(data.checkedOutCommit, data.recordedCommit);

        // What is offered to open really does hold a repository, agreeing
        // with git about where the submodule's checkout lives.
        expect(data.openableAt, p.join(outerPath, 'vendor', 'lib'));
        expect(
          git(['rev-parse', '--is-inside-work-tree'], cwd: data.openableAt!)
              .trim(),
          'true',
        );
      });

      test('a submodule with nothing cloned reports so, with nothing to open',
          () async {
        final data = await service.submodule(
            outerPath, Revision.head, 'vendor/uninit');
        expect(data.unavailable, isNull);
        expect(data.status, SubmoduleStatus.notInitialised);
        expect(data.checkedOutCommit, isNull);
        expect(data.openableAt, isNull);
        expect(data.url, libPath);
        expect(data.recordedCommit, _gitlinkSha(outerPath, 'vendor/uninit'));

        // git agrees: a deinitialised submodule's status line starts with
        // '-', the same sigil `Submodule.statusSigil` reports.
        final status =
            git(['submodule', 'status', 'vendor/uninit'], cwd: outerPath);
        expect(status.trim(), startsWith('-'));
      });

      test('a path with no submodule recorded says why, not with an error',
          () async {
        final data =
            await service.submodule(outerPath, Revision.head, 'readme.txt');
        expect(data.unavailable, isNotNull);
        expect(data.recordedCommit, isNull);
        expect(data.openableAt, isNull);
      });
    });
  });
}

int _counter = 0;
