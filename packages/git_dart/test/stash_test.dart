/// Stashing, checked against git.
///
/// A stash is not special storage: it is ordinary commits hung off
/// `refs/stash`, whose *reflog* is the stack. That is why `stash@{2}` is
/// spelled like a reflog entry — it is one — and it is the thing most worth
/// checking against git, because a stash written any other way would look
/// right to us and be invisible to `git stash list`.
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

void write(String name, String contents) =>
    File(p.join(repoPath, name)).writeAsStringSync(contents);

String read(String name) =>
    File(p.join(repoPath, name)).readAsStringSync();

void main() {
  late Repository repo;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_stash');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    write('a.txt', 'one\ntwo\nthree\n');
    write('b.txt', 'bee\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);

    repo = Repository.open(repoPath);
  });

  tearDown(() {
    repo.close();
    scratch.deleteSync(recursive: true);
  });

  test('saving puts the working tree back and git lists the stash', () {
    write('a.txt', 'one\ntwo\nthree\nfour\n');
    final saved = stashSave(repo);

    expect(saved, isNotNull);
    // The working tree is back at HEAD.
    expect(read('a.txt'), 'one\ntwo\nthree\n');
    expect(git(['status', '--porcelain']).trim(), isEmpty);

    // git reads our stash as its own, from the reflog we wrote.
    final listed = git(['stash', 'list']).trim();
    expect(listed, contains('stash@{0}'));
    expect(listed, contains('WIP on main'));
    git(['fsck', '--no-progress']);
  });

  test('a clean tree stashes nothing', () {
    expect(stashSave(repo), isNull);
    expect(git(['stash', 'list']).trim(), isEmpty);
  });

  test('applying brings the change back', () {
    write('a.txt', 'one\ntwo\nthree\nfour\n');
    stashSave(repo);
    expect(read('a.txt'), 'one\ntwo\nthree\n');

    expect(stashApply(repo), MergeOutcome.merged);
    expect(read('a.txt'), 'one\ntwo\nthree\nfour\n');
    // Applying leaves the stash in place.
    expect(stashList(repo), hasLength(1));
  });

  test('popping brings it back and drops it', () {
    write('a.txt', 'one\ntwo\nthree\nfour\n');
    stashSave(repo);

    expect(stashPop(repo), MergeOutcome.merged);
    expect(read('a.txt'), 'one\ntwo\nthree\nfour\n');
    expect(stashList(repo), isEmpty);
    expect(git(['stash', 'list']).trim(), isEmpty);
  });

  test('the stack is a stack, and git counts it the same way', () {
    write('a.txt', 'one\ntwo\nthree\nfirst change\n');
    stashSave(repo, message: 'first stash');
    write('b.txt', 'bee\nsecond change\n');
    stashSave(repo, message: 'second stash');

    final entries = stashList(repo);
    expect(entries, hasLength(2));
    // Newest first, which is what @{0} means.
    expect(entries[0].message, 'second stash');
    expect(entries[1].message, 'first stash');

    final listed = git(['stash', 'list']).trim().split('\n');
    expect(listed[0], contains('second stash'));
    expect(listed[1], contains('first stash'));
    expect(git(['rev-parse', 'stash@{1}']).trim(), entries[1].commit.hex);
  });

  test('the older stash can be applied by index', () {
    write('a.txt', 'one\ntwo\nthree\nfirst change\n');
    stashSave(repo, message: 'first stash');
    write('b.txt', 'bee\nsecond change\n');
    stashSave(repo, message: 'second stash');

    expect(stashApply(repo, index: 1), MergeOutcome.merged);
    expect(read('a.txt'), 'one\ntwo\nthree\nfirst change\n');
    expect(read('b.txt'), 'bee\n');
  });

  test('dropping the top re-points the ref, as git sees it', () {
    write('a.txt', 'one\ntwo\nthree\nfirst\n');
    stashSave(repo, message: 'first stash');
    write('b.txt', 'bee\nsecond\n');
    stashSave(repo, message: 'second stash');

    final older = stashList(repo)[1].commit;
    stashDrop(repo);

    expect(stashList(repo), hasLength(1));
    expect(repo.refs.resolve('refs/stash'), older);
    expect(git(['stash', 'list']).trim().split('\n'), hasLength(1));
    expect(git(['rev-parse', 'stash@{0}']).trim(), older.hex);
  });

  test('dropping an older one leaves the top alone', () {
    write('a.txt', 'one\ntwo\nthree\nfirst\n');
    stashSave(repo, message: 'first stash');
    write('b.txt', 'bee\nsecond\n');
    stashSave(repo, message: 'second stash');

    final top = stashList(repo)[0].commit;
    stashDrop(repo, index: 1);

    expect(stashList(repo), hasLength(1));
    expect(stashList(repo).single.commit, top);
    expect(repo.refs.resolve('refs/stash'), top);
  });

  test('clearing removes the ref and the log', () {
    write('a.txt', 'changed\n');
    stashSave(repo);
    stashClear(repo);

    expect(stashList(repo), isEmpty);
    expect(repo.refs.read('refs/stash'), isNull);
    expect(git(['stash', 'list']).trim(), isEmpty);
  });

  test('what was staged is recorded and can be restored', () {
    write('a.txt', 'one\ntwo\nthree\nstaged\n');
    repo.stage('a.txt');
    write('b.txt', 'bee\nunstaged\n');

    stashSave(repo);
    expect(git(['status', '--porcelain']).trim(), isEmpty);

    // By default everything comes back unstaged, which is what git does.
    expect(stashApply(repo), MergeOutcome.merged);
    expect(read('a.txt'), 'one\ntwo\nthree\nstaged\n');
    expect(read('b.txt'), 'bee\nunstaged\n');
    expect(git(['diff', '--cached', '--name-only']).trim(), isEmpty);
  });

  test('restoring the index puts the staging back', () {
    write('a.txt', 'one\ntwo\nthree\nstaged\n');
    repo.stage('a.txt');
    stashSave(repo);

    expect(stashApply(repo, restoreIndex: true), MergeOutcome.merged);
    expect(git(['diff', '--cached', '--name-only']).trim(), 'a.txt');
  });

  test('a stash applied onto changed work merges rather than overwrites', () {
    write('a.txt', 'one\ntwo\nthree\nfrom the stash\n');
    stashSave(repo);

    // Different file, changed while the stash was away. Overwriting would
    // lose it, which is the whole reason applying is a merge.
    write('b.txt', 'bee\nmade meanwhile\n');
    git(['commit', '-qam', 'meanwhile']);

    expect(stashApply(repo), MergeOutcome.merged);
    expect(read('a.txt'), 'one\ntwo\nthree\nfrom the stash\n');
    expect(read('b.txt'), 'bee\nmade meanwhile\n');
  });

  test('a conflicting pop keeps the stash', () {
    write('a.txt', 'one\ntwo\nstashed\n');
    stashSave(repo);

    write('a.txt', 'one\ntwo\nconflicting\n');
    git(['commit', '-qam', 'meanwhile']);

    expect(stashPop(repo), MergeOutcome.conflicted);
    // Dropping it here would leave the only copy of the work in a half-merged
    // tree.
    expect(stashList(repo), hasLength(1));
  });

  test('untracked files can be carried and come back', () {
    write('a.txt', 'one\ntwo\nthree\nchanged\n');
    write('new.txt', 'brand new\n');

    stashSave(repo, includeUntracked: true);
    expect(File(p.join(repoPath, 'new.txt')).existsSync(), isFalse);
    expect(read('a.txt'), 'one\ntwo\nthree\n');

    expect(stashApply(repo), MergeOutcome.merged);
    expect(read('new.txt'), 'brand new\n');
    expect(read('a.txt'), 'one\ntwo\nthree\nchanged\n');
  });

  test('a stash we wrote can be applied by git', () {
    write('a.txt', 'one\ntwo\nthree\nours\n');
    stashSave(repo, message: 'written by us');
    repo.close();

    // The real check: git's own stash apply on our commits.
    git(['stash', 'apply']);
    expect(read('a.txt'), 'one\ntwo\nthree\nours\n');

    repo = Repository.open(repoPath);
  });
}
