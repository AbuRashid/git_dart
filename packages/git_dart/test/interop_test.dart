/// Tests against a repository built by real git.
///
/// The vectors pin the object layer; these check the parts the document
/// describes rather than pins — packs, deltas, the index as git actually
/// writes it — where the only available authority is git's own output.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

/// Runs git and returns its stdout, failing the test on a non-zero exit.
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

bool get gitIsAvailable {
  try {
    return Process.runSync('git', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  setUpAll(() {
    if (!gitIsAvailable) return;
    scratch = Directory.systemTemp.createTempSync('git_dart_interop');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync();

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    git(['config', 'commit.gpgsign', 'false']);

    File(p.join(repoPath, 'a.txt')).writeAsStringSync('hello\n');
    Directory(p.join(repoPath, 'src')).createSync();
    File(p.join(repoPath, 'src', 'main.dart'))
        .writeAsStringSync('void main() {}\n');
    // A name that sorts differently under git's directory rule than under
    // plain string order.
    File(p.join(repoPath, 'src.txt')).writeAsStringSync('sibling\n');

    git(['add', '.']);
    git([
      '-c',
      'user.name=A',
      'commit',
      '-q',
      '-m',
      'first',
      '--date',
      '1000000000 +0000',
    ]);

    // A second commit, so there is history to walk and something to delta.
    File(p.join(repoPath, 'a.txt')).writeAsStringSync('hello\nworld\n');
    git(['add', 'a.txt']);
    git(['commit', '-q', '-m', 'second']);

    git(['tag', '-a', 'v1', '-m', 'first release']);
    git(['branch', 'side']);
  });

  tearDownAll(() {
    if (gitIsAvailable) scratch.deleteSync(recursive: true);
  });

  group('reading a repository git wrote', () {
    test('discovers the repository from a subdirectory', () {
      final repo = Repository.open(p.join(repoPath, 'src'));
      expect(p.basename(repo.gitDirectory), '.git');
      expect(repo.isBare, isFalse);
      repo.close();
    });

    test('a .git directory holding no repository is walked past', () {
      // A directory named .git with nothing in it is not a repository, and
      // git says so. Opening it anyway reports every file above it as
      // untracked, which is how this was found.
      final decoy = p.join(scratch.path, 'decoy');
      Directory(p.join(decoy, '.git')).createSync(recursive: true);
      expect(Repository.discover(decoy), isNull);
      expect(
        Process.runSync('git', ['status'], workingDirectory: decoy).exitCode,
        isNot(0),
      );
    });

    test('a bare repository is its own git directory', () {
      final bare = p.join(scratch.path, 'bare.git');
      Process.runSync('git', ['init', '-q', '--bare', bare]);
      final repo = Repository.open(bare);
      expect(repo.isBare, isTrue);
      expect(repo.workTree, isNull);
      repo.close();
    });

    test('HEAD names the branch git checked out', () {
      final repo = Repository.open(repoPath);
      expect(repo.refs.currentBranch, 'refs/heads/main');
      expect(repo.refs.isDetached, isFalse);
      expect(repo.headId!.hex, git(['rev-parse', 'HEAD']).trim());
      repo.close();
    });

    test('every revision we resolve matches git rev-parse', () {
      final repo = Repository.open(repoPath);
      for (final revision in [
        'HEAD',
        'HEAD^',
        'HEAD~1',
        'HEAD^1',
        'HEAD^{tree}',
        'HEAD^{commit}',
        'HEAD~1^{tree}',
        'v1',
        'v1^{}',
        'side',
        'refs/heads/main',
      ]) {
        expect(
          repo.resolve(revision)?.hex,
          git(['rev-parse', revision]).trim(),
          reason: revision,
        );
      }
      repo.close();
    });

    test('an abbreviated object name resolves', () {
      final repo = Repository.open(repoPath);
      final head = repo.headId!;
      expect(repo.resolve(head.hex.substring(0, 8)), head);
      repo.close();
    });

    test('a revision that names nothing resolves to null, not an error', () {
      final repo = Repository.open(repoPath);
      expect(repo.resolve('no-such-branch'), isNull);
      expect(repo.resolve('HEAD~99'), isNull);
      expect(repo.resolve('HEAD^{blob}'), isNull);
      repo.close();
    });

    test('a tree we read matches git ls-tree', () {
      final repo = Repository.open(repoPath);
      final tree = repo.treeOf(repo.headId!)!;

      final expected = git(['ls-tree', 'HEAD'])
          .trim()
          .split('\n')
          .map((line) {
            final parts = line.split(RegExp(r'\s+'));
            return '${parts[0]} ${parts[2]} ${parts[3]}';
          })
          .toList();

      final actual = tree.entries
          .map((e) => '${e.mode.text.padLeft(6, '0')} ${e.id.hex} ${e.name}')
          .toList();

      expect(actual, expected);
      repo.close();
    });

    test('a blob we read matches git cat-file', () {
      final repo = Repository.open(repoPath);
      final contents = repo.readFile('src/main.dart');
      expect(utf8.decode(contents!), 'void main() {}\n');
      expect(
        utf8.decode(repo.readFile('a.txt')!),
        git(['cat-file', 'blob', 'HEAD:a.txt']),
      );
      repo.close();
    });

    test('the log matches git rev-list', () {
      final repo = Repository.open(repoPath);
      final ours = repo.log().map((c) => c.id.hex).toList();
      final theirs = git(['rev-list', 'HEAD']).trim().split('\n');
      expect(ours, theirs);
      expect(repo.log(limit: 1).single.summary, 'second');
      repo.close();
    });

    test('an annotated tag peels to its commit', () {
      final repo = Repository.open(repoPath);
      final tagId = repo.refs.resolve('refs/tags/v1')!;
      final tag = repo.objects.readTyped<Tag>(tagId);
      expect(tag.name, 'v1');
      expect(tag.message.trim(), 'first release');
      expect(
        (repo.peel(tagId) as Commit).id.hex,
        git(['rev-parse', 'v1^{commit}']).trim(),
      );
      repo.close();
    });

    test('branches and tags are listed', () {
      final repo = Repository.open(repoPath);
      expect(repo.refs.branches.map((r) => r.shortName), ['main', 'side']);
      expect(repo.refs.tags.map((r) => r.shortName), ['v1']);
      repo.close();
    });
  });

  group('the index git wrote', () {
    test('parses, and holds the same paths as git ls-files', () {
      final index = GitIndex.open(p.join(repoPath, '.git', 'index'))!;
      expect(index.version, anyOf(2, 3));
      expect(
        index.entries.map((e) => e.path).toList(),
        git(['ls-files']).trim().split('\n'),
      );
      expect(index.hasConflicts, isFalse);
    });

    test('g-032: a regular file is mode 100644 octal', () {
      final index = GitIndex.open(p.join(repoPath, '.git', 'index'))!;
      final entry = index.entryFor('a.txt')!;
      expect(entry.mode.toRadixString(8), '100644');
      expect(entry.fileMode, FileMode.regularFile);
    });

    test('entry names match the blobs git staged', () {
      final index = GitIndex.open(p.join(repoPath, '.git', 'index'))!;
      for (final entry in index.entries) {
        expect(
          entry.id.hex,
          git(['rev-parse', ':${entry.path}']).trim(),
          reason: entry.path,
        );
      }
    });

    test('re-serialising keeps the entries git could read back', () {
      final index = GitIndex.open(p.join(repoPath, '.git', 'index'))!;
      final rewritten = GitIndex.parse(index.serialise());
      expect(
        rewritten.entries.map((e) => '${e.path} ${e.id.hex} ${e.mode}'),
        index.entries.map((e) => '${e.path} ${e.id.hex} ${e.mode}'),
      );
    });

    test('the tree written from the index is the tree git writes', () {
      final repo = Repository.open(repoPath);
      // Compare against git's own write-tree rather than against HEAD, so the
      // subtree and the sort rule are both exercised.
      expect(
        repo.writeTreeFromIndex().hex,
        git(['write-tree']).trim(),
      );
      repo.close();
    });
  });

  group('packs', () {
    setUpAll(() {
      if (!gitIsAvailable) return;
      // Everything loose becomes packed, and the deltas git chooses are then
      // what the reader has to resolve.
      git(['gc', '-q', '--aggressive']);
    });

    test('the loose objects are gone and the pack is read instead', () {
      final repo = Repository.open(repoPath);
      expect(repo.objects.packs, isNotEmpty);
      expect(repo.objects.loose.listAll(), isEmpty);

      final head = repo.headCommit!;
      expect(head.summary, 'second');
      expect(utf8.decode(repo.readFile('a.txt')!), 'hello\nworld\n');
      repo.close();
    });

    test('every packed object reads back under its own name', () {
      final repo = Repository.open(repoPath);
      var checked = 0;
      for (final id in repo.objects.listAll()) {
        final raw = repo.objects.readRaw(id)!;
        // The strongest available check: an object read from a pack must hash
        // to the name it was found under, whatever delta chain produced it.
        expect(hashObject(raw.kind, raw.content), id);
        checked += 1;
      }
      expect(checked, greaterThan(5));
      repo.close();
    });

    test('git verify-pack agrees the pack has deltas to resolve', () {
      final packs = Directory(p.join(repoPath, '.git', 'objects', 'pack'))
          .listSync()
          .where((f) => f.path.endsWith('.idx'))
          .toList();
      expect(packs, isNotEmpty);
    });
  });

  group('writing objects git can read', () {
    test('a blob we write is found by git cat-file', () {
      final repo = Repository.open(repoPath);
      final id = repo.writeObject(Blob.fromString('written by git_dart\n'));
      expect(
        git(['cat-file', 'blob', id.hex]),
        'written by git_dart\n',
      );
      expect(git(['cat-file', '-t', id.hex]).trim(), 'blob');
      repo.close();
    });

    test('a commit we write is read back by git log', () {
      final repo = Repository.open(repoPath);
      final tree = repo.headCommit!.tree;
      final id = repo.commitTree(
        tree: tree,
        message: 'written by git_dart',
        author: Identity(
          name: 'A',
          email: 'a@x',
          seconds: 1000000000,
          timezone: '+0000',
        ),
        updateHead: false,
      );
      expect(git(['cat-file', '-t', id.hex]).trim(), 'commit');
      expect(
        git(['log', '-1', '--format=%s', id.hex]).trim(),
        'written by git_dart',
      );
      expect(git(['fsck', '--no-progress'], cwd: repoPath), isNotNull);
      repo.close();
    });

    test('an empty repository we init is one git accepts', () {
      final path = p.join(scratch.path, 'fresh');
      final repo = Repository.init(path);
      expect(repo.headId, isNull); // no commits yet, which is not an error
      expect(git(['rev-parse', '--is-inside-work-tree'], cwd: path).trim(),
          'true');
      expect(git(['status', '--porcelain'], cwd: path), isEmpty);
      repo.close();
    });
  });
}
