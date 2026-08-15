/// Index version 3, and the flags only it can hold.
///
/// `intent-to-add` and `skip-worktree` live in an extended flags field that
/// version 2 has no room for. Writing v2 regardless parses cleanly and clears
/// them, which is the worst kind of bug: the file is valid, git reads it
/// without complaint, and a path the user marked is quietly back under
/// management.
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

String indexPath() => p.join(repoPath, '.git', 'index');

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_index3');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    for (final name in ['a.txt', 'b.txt', 'c.txt']) {
      File(p.join(repoPath, name)).writeAsStringSync('$name\n');
    }
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('skip-worktree survives a read and a write', () {
    git(['update-index', '--skip-worktree', 'b.txt']);
    expect(git(['ls-files', '-v']), contains('S b.txt'));

    final before = GitIndex.open(indexPath())!;
    expect(before.version, 3);
    expect(before.entryFor('b.txt')!.skipWorktree, isTrue);

    // Write it back untouched — what staging any other path does.
    before.writeTo(indexPath());

    final after = GitIndex.open(indexPath())!;
    expect(after.version, 3);
    expect(after.entryFor('b.txt')!.skipWorktree, isTrue);
    expect(after.entryFor('a.txt')!.skipWorktree, isFalse);

    // git's own reader is the one that has to agree.
    expect(git(['ls-files', '-v']), contains('S b.txt'));
    git(['fsck', '--no-progress']);
  });

  test('intent-to-add survives a read and a write', () {
    File(p.join(repoPath, 'new.txt')).writeAsStringSync('new\n');
    git(['add', '-N', 'new.txt']);

    final before = GitIndex.open(indexPath())!;
    expect(before.version, 3);
    expect(before.entryFor('new.txt')!.intentToAdd, isTrue);

    before.writeTo(indexPath());

    final after = GitIndex.open(indexPath())!;
    expect(after.entryFor('new.txt')!.intentToAdd, isTrue);
    // An intent-to-add path shows as an unstaged addition, not a staged one.
    expect(git(['status', '--porcelain']), contains('new.txt'));
    expect(git(['diff', '--name-only']), contains('new.txt'));
  });

  test('staging an unrelated path does not clear another path\'s flag', () {
    // The actual failure this prevents: touch one file, lose a mark on
    // another.
    git(['update-index', '--skip-worktree', 'b.txt']);

    final repo = Repository.open(repoPath);
    File(p.join(repoPath, 'a.txt')).writeAsStringSync('changed\n');
    repo.stage('a.txt');
    repo.close();

    expect(git(['ls-files', '-v']), contains('S b.txt'));
  });

  test('an index with nothing extended is still written as version 2', () {
    // The version is chosen, not fixed: v2 is what git writes for an ordinary
    // index and what the widest range of tools reads.
    final repo = Repository.open(repoPath);
    File(p.join(repoPath, 'a.txt')).writeAsStringSync('changed\n');
    repo.stage('a.txt');
    repo.close();

    final bytes = File(indexPath()).readAsBytesSync();
    expect(ByteData.sublistView(bytes).getUint32(4), 2);
    expect(GitIndex.open(indexPath())!.version, 2);
  });

  test('a held lock refuses a second writer', () {
    final lock = File('${indexPath()}.lock')..createSync();
    final repo = Repository.open(repoPath);
    File(p.join(repoPath, 'a.txt')).writeAsStringSync('changed\n');

    expect(() => repo.stage('a.txt'), throwsA(isA<IndexLockedException>()));
    repo.close();

    lock.deleteSync();
  });
}
