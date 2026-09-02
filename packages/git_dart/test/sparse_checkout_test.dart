/// Sparse checkout, checked against git.
///
/// Two things have to agree with git and they are separable: which paths the
/// patterns select, and what the working tree and index look like afterwards.
/// The first is checked against `git ls-files -t`, whose `S` marks exactly the
/// entries git decided to skip — a per-path answer that a whole-tree
/// comparison would blur. The second is checked by asking git whether the
/// narrowed repository is clean, because the failure this feature invites is a
/// repository that works but reports every absent file as deleted.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

var _clock = 1700000000;

String git(List<String> arguments, {String? cwd}) {
  final when = '$_clock +0000';
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: {'GIT_AUTHOR_DATE': when, 'GIT_COMMITTER_DATE': when},
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

void write(String path, String content) {
  final file = File(p.join(repoPath, path.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

/// The tracked paths git says are skipped, and the ones it says are present.
({Set<String> skipped, Set<String> present}) gitSkipState({String? cwd}) {
  final skipped = <String>{};
  final present = <String>{};
  for (final line in const LineSplitter()
      .convert(git(['ls-files', '-t'], cwd: cwd))
      .where((line) => line.trim().isNotEmpty)) {
    final tag = line[0];
    final path = line.substring(2);
    (tag == 'S' ? skipped : present).add(path);
  }
  return (skipped: skipped, present: present);
}

/// The same, from the index this library wrote.
({Set<String> skipped, Set<String> present}) ourSkipState({String? cwd}) {
  final repo = Repository.open(cwd ?? repoPath);
  final index = repo.index!;
  final skipped = <String>{};
  final present = <String>{};
  for (final entry in index.entries) {
    (entry.skipWorktree ? skipped : present).add(entry.path);
  }
  repo.close();
  return (skipped: skipped, present: present);
}

/// Files actually on disk, relative and slash-separated.
Set<String> filesOnDisk({String? cwd}) {
  final root = cwd ?? repoPath;
  return {
    for (final entity in Directory(root).listSync(recursive: true))
      if (entity is File)
        () {
          final relative =
              p.relative(entity.path, from: root).replaceAll(r'\', '/');
          return relative;
        }(),
  }..removeWhere((path) => path.startsWith('.git/'));
}

/// A repository with a few directories worth narrowing.
void seed() {
  write('top.txt', 'a\n');
  write('keep/k.txt', 'b\n');
  write('keep/sub/s.txt', 'c\n');
  write('drop/d.txt', 'd\n');
  write('other/o.md', 'e\n');
  write('other/o.txt', 'f\n');
  git(['add', '-A']);
  _clock += 60;
  git(['commit', '-q', '-m', 'one']);
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_sparse');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
  });

  tearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Read-only objects under .git survive on Windows.
    }
  });

  group('which paths the patterns select', () {
    /// Applies patterns with git, then asks this library the same question of
    /// every tracked path.
    void agreesWithGit(List<String> patterns) {
      git(['config', 'core.sparseCheckout', 'true']);
      File(p.join(repoPath, '.git', 'info', 'sparse-checkout'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(patterns.map((line) => '$line\n').join());
      git(['read-tree', '-mu', 'HEAD']);

      final theirs = gitSkipState();
      final sparse = SparseCheckout(patterns: patterns);

      for (final path in {...theirs.skipped, ...theirs.present}) {
        expect(
          sparse.includes(path),
          theirs.present.contains(path),
          reason: 'patterns ${patterns.join(' ')} on $path',
        );
      }
    }

    setUp(seed);

    test('a directory named with slashes', () => agreesWithGit(['/keep/']));
    test('a directory named without a leading slash',
        () => agreesWithGit(['keep/']));
    test('a bare directory name', () => agreesWithGit(['keep']));
    test('root files only', () => agreesWithGit(['/*', '!/*/']));
    test('a suffix pattern at any depth', () => agreesWithGit(['*.txt']));
    test('the cone form', () => agreesWithGit(['/*', '!/*/', '/keep/']));
    test('two directories in cone form',
        () => agreesWithGit(['/*', '!/*/', '/keep/', '/other/']));
    test('a nested directory in cone form',
        () => agreesWithGit(['/*', '!/*/', '/keep/', '/keep/sub/']));
    test('a pattern matching nothing', () => agreesWithGit(['/nowhere/']));
    test('a negation that takes back a directory',
        () => agreesWithGit(['*.txt', '!/other/']));
  });

  group('applying it', () {
    setUp(seed);

    test('narrows the working tree and sets the bits git sets', () {
      final repo = Repository.open(repoPath);
      final result = setSparseCheckout(
        repo,
        conePatterns(const ['keep']),
        cone: true,
      );
      repo.close();

      expect(result.removed, containsAll(['drop/d.txt', 'other/o.md']));
      expect(result.kept, isEmpty);

      // The files are gone from disk, and so is the directory they were in.
      expect(filesOnDisk(), {'top.txt', 'keep/k.txt', 'keep/sub/s.txt'});
      expect(Directory(p.join(repoPath, 'drop')).existsSync(), isFalse);

      // git reads the index we wrote and agrees about every path.
      final theirs = gitSkipState();
      expect(theirs.skipped, {
        'drop/d.txt',
        'other/o.md',
        'other/o.txt',
      });
      expect(ourSkipState().skipped, theirs.skipped);
      expect(ourSkipState().present, theirs.present);
    });

    test('the narrowed repository is clean, to git and to us', () {
      final repo = Repository.open(repoPath);
      setSparseCheckout(repo, conePatterns(const ['keep']), cone: true);
      final ours = repo.status();
      repo.close();

      // The failure this whole feature invites: absent files reported deleted.
      expect(git(['status', '--porcelain']).trim(), isEmpty);
      expect(ours.entries, isEmpty);
    });

    test('widening it puts the files back', () {
      final repo = Repository.open(repoPath);
      setSparseCheckout(repo, conePatterns(const ['keep']), cone: true);
      expect(filesOnDisk(), hasLength(3));

      final result = setSparseCheckout(
        repo,
        conePatterns(const ['keep', 'other']),
        cone: true,
      );
      repo.close();

      expect(result.restored, containsAll(['other/o.md', 'other/o.txt']));
      expect(filesOnDisk(), {
        'top.txt',
        'keep/k.txt',
        'keep/sub/s.txt',
        'other/o.md',
        'other/o.txt',
      });
      expect(File(p.join(repoPath, 'other', 'o.md')).readAsStringSync(), 'e\n');

      expect(gitSkipState().skipped, {'drop/d.txt'});
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });

    test('disabling it restores the whole tree', () {
      final repo = Repository.open(repoPath);
      setSparseCheckout(repo, conePatterns(const ['keep']), cone: true);
      final result = disableSparseCheckout(repo);
      repo.close();

      expect(result.restored, hasLength(3));
      expect(filesOnDisk(), {
        'top.txt',
        'keep/k.txt',
        'keep/sub/s.txt',
        'drop/d.txt',
        'other/o.md',
        'other/o.txt',
      });
      expect(gitSkipState().skipped, isEmpty);
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });

    test('a modified file outside the set is kept, not thrown away', () {
      write('drop/d.txt', 'work nobody else has\n');

      final repo = Repository.open(repoPath);
      final result = setSparseCheckout(
        repo,
        conePatterns(const ['keep']),
        cone: true,
      );
      repo.close();

      expect(result.kept, contains('drop/d.txt'));
      expect(result.removed, isNot(contains('drop/d.txt')));
      expect(
        File(p.join(repoPath, 'drop', 'd.txt')).readAsStringSync(),
        'work nobody else has\n',
      );
      // Still tracked normally, so the change is still visible and committable.
      expect(ourSkipState().skipped, isNot(contains('drop/d.txt')));
      expect(git(['status', '--porcelain']), contains('drop/d.txt'));
    });

    test('force removes it anyway, which is what force means', () {
      write('drop/d.txt', 'work nobody else has\n');

      final repo = Repository.open(repoPath);
      final result = setSparseCheckout(
        repo,
        conePatterns(const ['keep']),
        cone: true,
        force: true,
      );
      repo.close();

      expect(result.kept, isEmpty);
      expect(result.removed, contains('drop/d.txt'));
      expect(File(p.join(repoPath, 'drop', 'd.txt')).existsSync(), isFalse);
    });

    test('applying twice changes nothing the second time', () {
      final repo = Repository.open(repoPath);
      setSparseCheckout(repo, conePatterns(const ['keep']), cone: true);
      final again = applySparseCheckout(repo);
      repo.close();

      expect(again.isEmpty, isTrue);
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });
  });

  group('reading git\'s own settings', () {
    test('git sparse-checkout set is read back exactly', () {
      seed();
      // git puts these in `.git/config.worktree` behind
      // `extensions.worktreeConfig`, not in the ordinary config.
      git(['sparse-checkout', 'set', '--cone', 'keep']);

      final repo = Repository.open(repoPath);
      final sparse = SparseCheckout.forRepository(repo);
      final status = repo.status();
      repo.close();

      expect(sparse.enabled, isTrue,
          reason: 'core.sparseCheckout lives in config.worktree');
      expect(sparse.cone, isTrue);
      expect(sparse.patterns, ['/*', '!/*/', '/keep/']);
      expect(sparse.coneDirectories, ['keep']);

      // Every path is decided the same way git decided it.
      final theirs = gitSkipState();
      for (final path in theirs.skipped) {
        expect(sparse.includes(path), isFalse, reason: path);
      }
      for (final path in theirs.present) {
        expect(sparse.includes(path), isTrue, reason: path);
      }

      // And the repository reads as clean, as git says it is.
      expect(status.entries, isEmpty);
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });

    test('a repository without sparse checkout includes everything', () {
      seed();
      final repo = Repository.open(repoPath);
      final sparse = SparseCheckout.forRepository(repo);
      repo.close();

      expect(sparse.enabled, isFalse);
      expect(sparse.includes('anything/at/all.txt'), isTrue);
    });

    test('enabled with no patterns selects nothing, as git does', () {
      seed();
      git(['config', 'core.sparseCheckout', 'true']);
      File(p.join(repoPath, '.git', 'info', 'sparse-checkout'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');

      final repo = Repository.open(repoPath);
      final sparse = SparseCheckout.forRepository(repo);
      repo.close();

      expect(sparse.includes('top.txt'), isFalse);
    });
  });

  group('the cone form we generate', () {
    test('is the form git writes', () {
      seed();
      git(['sparse-checkout', 'set', '--cone', 'keep']);
      final theirs = File(p.join(repoPath, '.git', 'info', 'sparse-checkout'))
          .readAsLinesSync()
          .where((line) => line.trim().isNotEmpty)
          .toList();

      expect(conePatterns(const ['keep']), theirs);
    });

    test('names every parent, and shuts their other children out', () {
      // The walk down has to pass through each parent, and re-including a
      // parent re-includes everything under it - so each one it merely passes
      // through has to exclude its subdirectories again.
      expect(
        conePatterns(const ['keep/sub']),
        ['/*', '!/*/', '/keep/', '!/keep/*/', '/keep/sub/'],
      );
    });

    test('a directory inside another that was asked for adds nothing', () {
      expect(
        conePatterns(const ['keep', 'keep/sub']),
        conePatterns(const ['keep']),
      );
    });

    test('matches git for several directories at mixed depths', () {
      seed();
      write('keep/other/o.txt', 'g');
      git(['add', '-A']);
      _clock += 60;
      git(['commit', '-q', '-m', 'two']);

      for (final dirs in [
        const ['keep/sub', 'other'],
        const ['keep', 'keep/sub'],
        const ['keep/sub', 'keep/other'],
      ]) {
        git(['sparse-checkout', 'set', '--cone', ...dirs]);
        final theirs =
            File(p.join(repoPath, '.git', 'info', 'sparse-checkout'))
                .readAsLinesSync()
                .where((line) => line.trim().isNotEmpty)
                .toList();
        expect(conePatterns(dirs), theirs, reason: dirs.join(' '));
      }
    });

    test('matches what git writes for a nested directory', () {
      seed();
      git(['sparse-checkout', 'set', '--cone', 'keep/sub']);
      final theirs = File(p.join(repoPath, '.git', 'info', 'sparse-checkout'))
          .readAsLinesSync()
          .where((line) => line.trim().isNotEmpty)
          .toList();

      expect(conePatterns(const ['keep/sub']), theirs);
    });
  });

  group('checkout honours it', () {
    test('switching branches does not write what is outside the set', () {
      seed();
      git(['checkout', '-q', '-b', 'other-branch']);
      write('drop/new.txt', 'added on the branch\n');
      write('keep/new.txt', 'also added\n');
      git(['add', '-A']);
      _clock += 60;
      git(['commit', '-q', '-m', 'two']);
      git(['checkout', '-q', 'main']);

      final repo = Repository.open(repoPath);
      setSparseCheckout(repo, conePatterns(const ['keep']), cone: true);

      // Checking out the branch that adds a file in `drop/` must not create
      // it: the whole point is that `drop/` is not on this disk.
      final target = repo.treeOf(repo.resolve('other-branch')!)!;
      checkoutTree(repo, target);
      repo.close();

      expect(File(p.join(repoPath, 'drop', 'new.txt')).existsSync(), isFalse);
      expect(File(p.join(repoPath, 'keep', 'new.txt')).existsSync(), isTrue);

      // The new path is in the index, marked skipped, which is how git
      // records a path it is deliberately not holding.
      final state = ourSkipState();
      expect(state.skipped, contains('drop/new.txt'));
      expect(state.present, contains('keep/new.txt'));
    });

    test('and the result is still clean to git', () {
      seed();
      final repo = Repository.open(repoPath);
      setSparseCheckout(repo, conePatterns(const ['keep']), cone: true);
      final target = repo.treeOf(repo.headId!)!;
      checkoutTree(repo, target);
      repo.close();

      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });
  });
}
