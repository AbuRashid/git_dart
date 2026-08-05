/// Diff, status and checkout, checked against git's own answers.
///
/// Every assertion that can be compared with a git command is, rather than
/// with a value written here by hand: a test that agrees only with its author
/// proves the author consistent (`failure-modes.prose-that-looks-normative`).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

void write(String relative, String contents) {
  final file = File(p.join(repoPath, relative.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// git's own status, as the set of porcelain lines, for comparison.
Set<String> gitStatus() => git(['status', '--porcelain'])
    .split('\n')
    .map((line) => line.trimRight())
    .where((line) => line.isNotEmpty)
    .toSet();

Set<String> ourStatus(Repository repo) => repo
    .status()
    .entries
    .map((entry) => '${entry.code} ${entry.path}')
    .toSet();

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_worktree');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    git(['config', 'core.autocrlf', 'false']);

    write('a.txt', 'one\ntwo\nthree\n');
    write('src/main.dart', 'void main() {}\n');
    write('docs/readme.md', '# docs\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'first']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  group('tree diff', () {
    test('matches git diff --name-status across two commits', () {
      write('a.txt', 'one\ntwo\nthree\nfour\n');
      write('added.txt', 'new\n');
      File(p.join(repoPath, 'docs', 'readme.md')).deleteSync();
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'second']);

      final repo = Repository.open(repoPath);
      final ours = repo
          .diff(repo.resolve('HEAD~1'), repo.resolve('HEAD'))
          .map((change) => '${change.toString().substring(0, 1)}\t'
              '${change.path}')
          .toSet();

      final theirs = git(['diff', '--name-status', 'HEAD~1', 'HEAD'])
          .trim()
          .split('\n')
          .map((line) => line.trimRight())
          .toSet();

      expect(ours, theirs);
      repo.close();
    });

    test('the first commit is diffed against nothing', () {
      final repo = Repository.open(repoPath);
      final changes = repo.changesIn(repo.headId!);
      expect(
        changes.map((c) => c.path).toList(),
        ['a.txt', 'docs/readme.md', 'src/main.dart'],
      );
      expect(changes.every((c) => c.kind == ChangeKind.added), isTrue);
      repo.close();
    });

    test('an unchanged subtree is not walked into', () {
      write('a.txt', 'changed\n');
      git(['commit', '-q', '-am', 'second']);

      final repo = Repository.open(repoPath);
      final changes = repo.changesIn(repo.headId!);
      // src/ and docs/ are untouched, so nothing under them appears.
      expect(changes.map((c) => c.path), ['a.txt']);
      repo.close();
    });

    test('an exact rename is detected, not reported as add plus delete', () {
      git(['mv', 'a.txt', 'renamed.txt']);
      git(['commit', '-q', '-m', 'move']);

      final repo = Repository.open(repoPath);
      final changes = repo.changesIn(repo.headId!);
      expect(changes, hasLength(1));
      expect(changes.single.kind, ChangeKind.renamed);
      expect(changes.single.oldPath, 'a.txt');
      expect(changes.single.newPath, 'renamed.txt');
      // git agrees, given the same instruction to look.
      expect(git(['diff', '--name-status', '-M', 'HEAD~1', 'HEAD']),
          startsWith('R100'));
      repo.close();
    });
  });

  group('text diff', () {
    test('counts the same insertions and deletions as git diff --numstat', () {
      write('a.txt', 'one\nTWO\nthree\nfour\n');
      git(['commit', '-q', '-am', 'second']);

      final repo = Repository.open(repoPath);
      final change = repo.changesIn(repo.headId!).single;
      final diff = repo.diffBlobs(change.oldId, change.newId);

      final numstat = git(['diff', '--numstat', 'HEAD~1', 'HEAD']).trim();
      final fields = numstat.split(RegExp(r'\s+'));
      expect(diff.insertions, int.parse(fields[0]));
      expect(diff.deletions, int.parse(fields[1]));
      repo.close();
    });

    test('produces the hunk header git produces', () {
      write(
        'a.txt',
        List.generate(40, (i) => i == 20 ? 'changed' : 'line $i').join('\n') +
            '\n',
      );
      write('base.txt', List.generate(40, (i) => 'line $i').join('\n') + '\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'lines']);
      write(
        'base.txt',
        List.generate(40, (i) => i == 20 ? 'changed' : 'line $i').join('\n') +
            '\n',
      );
      git(['commit', '-q', '-am', 'change one line']);

      final repo = Repository.open(repoPath);
      final change =
          repo.changesIn(repo.headId!).firstWhere((c) => c.path == 'base.txt');
      final diff = repo.diffBlobs(change.oldId, change.newId);

      expect(diff.hunks, hasLength(1));
      // Three lines of context either side of one changed line.
      expect(diff.hunks.single.header, '@@ -18,7 +18,7 @@');
      expect(
        git(['diff', '-U3', 'HEAD~1', 'HEAD', '--', 'base.txt']),
        contains('@@ -18,7 +18,7 @@'),
      );
      repo.close();
    });

    test('binary content is reported, not rendered', () {
      final repo = Repository.open(repoPath);
      final a = repo.writeObject(Blob(
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x00, 0x01, 0x02]),
      ));
      final b = repo.writeObject(Blob(
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x00, 0x03, 0x04]),
      ));
      final diff = repo.diffBlobs(a, b);
      expect(diff.isBinary, isTrue);
      expect(diff.hunks, isEmpty);
      repo.close();
    });

    test('an added file is diffed against nothing', () {
      final repo = Repository.open(repoPath);
      final change = repo
          .changesIn(repo.headId!)
          .firstWhere((c) => c.path == 'a.txt');
      final diff = repo.diffBlobs(null, change.newId);
      expect(diff.insertions, 3);
      expect(diff.deletions, 0);
      repo.close();
    });
  });

  group('status', () {
    test('a clean tree is clean', () {
      final repo = Repository.open(repoPath);
      expect(repo.status().isClean, isTrue);
      expect(ourStatus(repo), gitStatus());
      repo.close();
    });

    test('agrees with git on modified, staged, deleted and untracked', () {
      write('a.txt', 'modified\n');            // unstaged modification
      write('src/main.dart', 'void main() { print(1); }\n');
      git(['add', 'src/main.dart']);           // staged modification
      File(p.join(repoPath, 'docs', 'readme.md')).deleteSync(); // deleted
      write('untracked.txt', 'hello\n');       // untracked

      final repo = Repository.open(repoPath);
      expect(ourStatus(repo), gitStatus());
      expect(repo.status().isClean, isFalse);
      repo.close();
    });

    test('a staged addition and a later edit of the same file', () {
      write('new.txt', 'staged\n');
      git(['add', 'new.txt']);
      write('new.txt', 'and then changed\n');

      final repo = Repository.open(repoPath);
      expect(ourStatus(repo), gitStatus());
      final entry = repo.status().entries.single;
      expect(entry.staged, ChangeKind.added);
      expect(entry.unstaged, ChangeKind.modified);
      repo.close();
    });

    test('ignored files do not appear, and a negation rescues one', () {
      write('.gitignore', 'build/\n*.log\n!keep.log\n');
      write('build/output.bin', 'x\n');
      write('debug.log', 'x\n');
      write('keep.log', 'x\n');
      git(['add', '.gitignore']);
      git(['commit', '-q', '-m', 'ignores']);

      final repo = Repository.open(repoPath);
      expect(ourStatus(repo), gitStatus());
      final untracked = repo.status().untracked.map((e) => e.path).toList();
      expect(untracked, ['keep.log']);
      repo.close();
    });

    test('a .gitignore in a subdirectory applies from there down', () {
      write('.gitignore', '');
      write('src/.gitignore', 'generated/\n');
      write('src/generated/thing.dart', 'x\n');
      write('src/kept.dart', 'x\n');
      git(['add', '.gitignore', 'src/.gitignore']);
      git(['commit', '-q', '-m', 'nested ignores']);

      final repo = Repository.open(repoPath);
      expect(ourStatus(repo), gitStatus());
      repo.close();
    });

    test('the stat cache hides a same-size same-second edit, as git does', () {
      final repo = Repository.open(repoPath);
      final file = File(p.join(repoPath, 'a.txt'));
      final before = file.statSync();

      // Exactly the case `hazards` names: the content changed and the stat
      // data did not.
      file.writeAsStringSync('ONE\ntwo\nthree\n');
      file.setLastModifiedSync(before.modified);

      // What git reports here is not fixed: when the file's timestamp is not
      // older than the index's, git calls the entry racily clean and reads the
      // file; otherwise it believes the stat data. Both this library and git
      // therefore answer according to timing, so the assertion is on the
      // option that removes the question rather than on the racy answer.

      // With the cache off, the file is read and the change is always found.
      final thorough = repo.status(trustStatCache: false);
      expect(thorough.unstaged.single.path, 'a.txt');
      expect(thorough.unstaged.single.unstaged, ChangeKind.modified);
      repo.close();
    });

    test('a wholly untracked directory is one entry, as git reports it', () {
      write('newpkg/lib/a.dart', 'x\n');
      write('newpkg/lib/b.dart', 'x\n');
      write('newpkg/pubspec.yaml', 'name: x\n');

      final repo = Repository.open(repoPath);
      expect(ourStatus(repo), gitStatus());
      expect(repo.status().untracked.map((e) => e.path), ['newpkg/']);

      // The other question the same walk answers, which git spells
      // --untracked-files=all.
      final all = repo.status(collapseUntrackedDirectories: false);
      expect(
        all.untracked.map((e) => e.path).toList(),
        ['newpkg/lib/a.dart', 'newpkg/lib/b.dart', 'newpkg/pubspec.yaml'],
      );
      repo.close();
    });

    test('a directory with something tracked in it is listed by file', () {
      write('src/added.dart', 'x\n');
      final repo = Repository.open(repoPath);
      expect(ourStatus(repo), gitStatus());
      expect(repo.status().untracked.map((e) => e.path), ['src/added.dart']);
      repo.close();
    });

    test('an untracked directory holding only ignored files is not reported',
        () {
      write('.gitignore', '*.log\n');
      git(['add', '.gitignore']);
      git(['commit', '-q', '-m', 'ignore logs']);
      write('logs/a.log', 'x\n');
      write('logs/b.log', 'x\n');

      final repo = Repository.open(repoPath);
      expect(ourStatus(repo), gitStatus());
      expect(repo.status().untracked, isEmpty);
      repo.close();
    });

    test('an unborn HEAD reports additions rather than failing', () {
      final fresh = p.join(scratch.path, 'fresh');
      final repo = Repository.init(fresh);
      File(p.join(fresh, 'a.txt')).writeAsStringSync('x\n');
      final status = repo.status();
      expect(status.isUnborn, isTrue);
      expect(status.untracked.single.path, 'a.txt');
      repo.close();
    });
  });

  group('checkout', () {
    setUp(() {
      write('a.txt', 'second revision\n');
      write('only-on-main.txt', 'x\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'second']);
      git(['branch', 'side', 'HEAD~1']);
    });

    test('switching branches rewrites the working tree and the index', () {
      final repo = Repository.open(repoPath);
      final result = repo.checkout('side');

      expect(File(p.join(repoPath, 'a.txt')).readAsStringSync(),
          'one\ntwo\nthree\n');
      expect(File(p.join(repoPath, 'only-on-main.txt')).existsSync(), isFalse);
      expect(result.removed, 1);
      expect(repo.refs.currentBranch, 'refs/heads/side');

      // git itself must agree the result is clean, which checks the index as
      // well as the files.
      expect(gitStatus(), isEmpty);
      expect(git(['rev-parse', '--abbrev-ref', 'HEAD']).trim(), 'side');
      repo.close();
    });

    test('switching back restores what was removed', () {
      final repo = Repository.open(repoPath);
      repo.checkout('side');
      repo.checkout('main');

      expect(File(p.join(repoPath, 'a.txt')).readAsStringSync(),
          'second revision\n');
      expect(File(p.join(repoPath, 'only-on-main.txt')).existsSync(), isTrue);
      expect(gitStatus(), isEmpty);
      repo.close();
    });

    test('a directory left empty by a checkout is removed', () {
      write('nested/deep/file.txt', 'x\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'nested']);

      final repo = Repository.open(repoPath);
      repo.checkout('side');
      expect(Directory(p.join(repoPath, 'nested')).existsSync(), isFalse);
      repo.close();
    });

    test('local changes are not overwritten', () {
      final repo = Repository.open(repoPath);
      write('a.txt', 'work in progress\n');

      expect(
        () => repo.checkout('side'),
        throwsA(isA<CheckoutConflictException>()),
      );
      // The file is untouched, which is the point.
      expect(File(p.join(repoPath, 'a.txt')).readAsStringSync(),
          'work in progress\n');

      repo.checkout('side', force: true);
      expect(File(p.join(repoPath, 'a.txt')).readAsStringSync(),
          'one\ntwo\nthree\n');
      repo.close();
    });

    test('checking out a commit detaches HEAD', () {
      final repo = Repository.open(repoPath);
      final target = repo.resolve('HEAD~1')!;
      repo.checkout(target.hex);

      expect(repo.refs.isDetached, isTrue);
      expect(repo.headId, target);
      expect(git(['rev-parse', 'HEAD']).trim(), target.hex);
      expect(gitStatus(), isEmpty);
      repo.close();
    });

    test('a branch we create is one git can check out', () {
      final repo = Repository.open(repoPath);
      repo.createBranch('from-git-dart');
      expect(
        git(['branch', '--list', 'from-git-dart']).trim(),
        contains('from-git-dart'),
      );
      git(['checkout', '-q', 'from-git-dart']);
      expect(gitStatus(), isEmpty);
      repo.close();
    });
  });
}
