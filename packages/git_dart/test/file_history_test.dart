/// File history — `git log -- <path>` — checked against git's own answer.
///
/// The interesting part is not the filtering but the *simplification*: git
/// hides a commit whose version of the file matches a parent, and follows that
/// parent alone. A merge that took one side wholesale vanishes, and so does
/// the branch it came from. Getting that wrong produces a listing that is not
/// obviously wrong — just longer than it should be — which is why every case
/// here is compared against git rather than reasoned about.
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

void write(String name, String contents) {
  final file = File(p.join(repoPath, name.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

void commit(String message) {
  git(['add', '-A']);
  _clock += 60;
  git(['commit', '-q', '-m', message]);
}

List<String> gitHistory(String path, {bool follow = false}) =>
    git([
      'log',
      if (follow) '--follow',
      '--format=%H',
      '--',
      path,
    ]).trim().split('\n').where((line) => line.isNotEmpty).toList();

List<String> ourHistory(String path, {bool follow = false}) {
  final repo = Repository.open(repoPath);
  final out = fileHistory(repo, path, follow: follow)
      .map((entry) => entry.commit.id.hex)
      .toList();
  repo.close();
  return out;
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_filehistory');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('only the commits that touched the file', () {
    write('a.txt', 'one\n');
    write('b.txt', 'other\n');
    commit('both added');

    write('b.txt', 'other changed\n');
    commit('only b');

    write('a.txt', 'one\ntwo\n');
    commit('only a');

    // Two of the three commits touched a.txt.
    expect(ourHistory('a.txt'), gitHistory('a.txt'));
    expect(ourHistory('a.txt'), hasLength(2));
    expect(ourHistory('b.txt'), gitHistory('b.txt'));
  });

  test('a file in a subdirectory', () {
    write('src/deep/thing.txt', 'one\n');
    commit('added');
    write('other.txt', 'unrelated\n');
    commit('unrelated');
    write('src/deep/thing.txt', 'two\n');
    commit('changed');

    expect(ourHistory('src/deep/thing.txt'),
        gitHistory('src/deep/thing.txt'));
  });

  test('the commit that added the file is the last one', () {
    write('a.txt', 'one\n');
    commit('added');
    final added = git(['rev-parse', 'HEAD']).trim();
    write('a.txt', 'two\n');
    commit('changed');

    final repo = Repository.open(repoPath);
    final entries = fileHistory(repo, 'a.txt').toList();
    repo.close();

    expect(entries.last.commit.id.hex, added);
    expect(entries.last.kind, ChangeKind.added);
    expect(entries.first.kind, ChangeKind.modified);
  });

  test('a deletion is reported and ends the history', () {
    write('a.txt', 'one\n');
    commit('added');
    git(['rm', '-q', 'a.txt']);
    commit('deleted');

    final repo = Repository.open(repoPath);
    final entries = fileHistory(repo, 'a.txt').toList();
    repo.close();

    expect(entries.first.kind, ChangeKind.deleted);
    expect(entries.first.blob, isNull);
    expect(ourHistory('a.txt'), gitHistory('a.txt'));
  });

  test('a limit stops the listing without changing it', () {
    write('a.txt', 'nought\n');
    commit('first');
    for (var i = 0; i < 5; i++) {
      write('a.txt', 'revision $i\n');
      commit('edit $i');
    }

    final repo = Repository.open(repoPath);
    final all = fileHistory(repo, 'a.txt').map((e) => e.commit.id).toList();
    final capped =
        fileHistory(repo, 'a.txt', limit: 3).map((e) => e.commit.id).toList();
    repo.close();

    expect(capped, all.take(3));
  });

  test('history is simplified across a merge, as git simplifies it', () {
    // The file is changed on one side only. The merge took that side, so git
    // shows neither the merge nor the untouched branch.
    write('shared.txt', 'base\n');
    write('other.txt', 'other\n');
    commit('base');
    git(['branch', 'side']);

    write('other.txt', 'main touched this\n');
    commit('on main');

    git(['checkout', '-q', 'side']);
    write('shared.txt', 'changed on side\n');
    commit('on side');

    git(['checkout', '-q', 'main']);
    _clock += 60;
    git(['merge', '-q', '--no-edit', 'side']);

    expect(ourHistory('shared.txt'), gitHistory('shared.txt'));
    // The merge itself is not in the listing: it changed nothing about the
    // file that its side had not already changed.
    final merge = git(['rev-parse', 'HEAD']).trim();
    expect(ourHistory('shared.txt'), isNot(contains(merge)));
  });

  test('a merge that resolved the file itself is shown', () {
    write('shared.txt', 'base\n');
    commit('base');
    git(['branch', 'side']);

    write('shared.txt', 'main version\n');
    commit('on main');

    git(['checkout', '-q', 'side']);
    write('shared.txt', 'side version\n');
    commit('on side');

    git(['checkout', '-q', 'main']);
    _clock += 60;
    // Resolved by hand to something neither side had, so the merge genuinely
    // changed the file and has to appear.
    final merged = Process.runSync('git', ['merge', '--no-edit', 'side'],
        workingDirectory: repoPath);
    expect(merged.exitCode, isNot(0), reason: 'this should conflict');
    write('shared.txt', 'resolved differently\n');
    git(['add', '-A']);
    _clock += 60;
    git(['commit', '-q', '--no-edit']);

    expect(ourHistory('shared.txt'), gitHistory('shared.txt'));
    expect(ourHistory('shared.txt'), contains(git(['rev-parse', 'HEAD']).trim()));
  });

  test('without follow, history stops at the rename', () {
    write('old.txt', 'content\n' * 10);
    commit('added as old');
    git(['mv', 'old.txt', 'new.txt']);
    commit('renamed');
    write('new.txt', '${'content\n' * 10}more\n');
    commit('changed after rename');

    // git shows the rename as the point the file appeared.
    expect(ourHistory('new.txt'), gitHistory('new.txt'));
    expect(ourHistory('new.txt'), hasLength(2));
  });

  test('with follow, history continues under the old name', () {
    write('old.txt', 'content\n' * 10);
    commit('added as old');
    final added = git(['rev-parse', 'HEAD']).trim();
    git(['mv', 'old.txt', 'new.txt']);
    commit('renamed');
    write('new.txt', '${'content\n' * 10}more\n');
    commit('changed after rename');

    final ours = ourHistory('new.txt', follow: true);
    expect(ours, gitHistory('new.txt', follow: true));
    // The commit that created it under the old name is reached.
    expect(ours, contains(added));
    expect(ours, hasLength(3));
  });

  test('a rename is reported with the name it had before', () {
    write('old.txt', 'content\n' * 10);
    commit('added as old');
    git(['mv', 'old.txt', 'new.txt']);
    commit('renamed');

    final repo = Repository.open(repoPath);
    final entries = fileHistory(repo, 'new.txt', follow: true).toList();
    repo.close();

    final rename = entries.firstWhere((e) => e.isRename);
    expect(rename.path, 'new.txt');
    expect(rename.previousPath, 'old.txt');
  });

  test('a rename that also edited the file is still followed', () {
    // Similarity rather than an identical blob, which is the case exact
    // matching alone would miss.
    write('old.txt', List.generate(20, (i) => 'line $i').join('\n'));
    commit('added');
    final added = git(['rev-parse', 'HEAD']).trim();

    git(['mv', 'old.txt', 'new.txt']);
    write('new.txt',
        '${List.generate(20, (i) => 'line $i').join('\n')}\nand one more');
    commit('renamed and edited');

    final ours = ourHistory('new.txt', follow: true);
    expect(ours, contains(added));
  });

  test('a path that never existed has no history', () {
    write('a.txt', 'one\n');
    commit('added');

    expect(ourHistory('nothing.txt'), isEmpty);
    expect(ourHistory('nothing.txt'), gitHistory('nothing.txt'));
  });

  test('a long history agrees with git throughout', () {
    write('tracked.txt', 'start\n');
    write('noise.txt', 'start\n');
    commit('base');

    for (var i = 0; i < 15; i++) {
      // Only every third commit touches the file being followed.
      if (i % 3 == 0) {
        write('tracked.txt', 'revision $i\n');
      } else {
        write('noise.txt', 'revision $i\n');
      }
      commit('commit $i');
    }

    expect(ourHistory('tracked.txt'), gitHistory('tracked.txt'));
  });
}
