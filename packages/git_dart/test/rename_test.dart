/// Rename detection by similarity, checked against git's own.
///
/// Nothing records that a file moved: git stores whole objects and works it
/// out afterwards, by content, heuristically (`algorithms.diff`). Exact
/// matching finds a file that moved and was not touched, which is the easy
/// half. A file that moved *and* was edited is the half that matters, because
/// that is the case where reading it as an unrelated deletion and addition
/// loses the history someone is trying to follow.
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

void write(String relative, String contents) {
  final file = File(p.join(repoPath, relative.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// What git reports for the last commit, as `STATUS\tpaths` lines.
Set<String> gitStatus({int threshold = 50}) => git([
      'diff',
      '--name-status',
      '-M$threshold%',
      'HEAD~1',
      'HEAD',
    ])
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        // R100, R087 — the score varies with the algorithm and is not what is
        // being compared here.
        .map((line) => line.replaceFirst(RegExp(r'^R\d+'), 'R'))
        .toSet();

/// The same, from us.
Set<String> ourStatus(Repository repo, {int threshold = 50}) {
  final changes = repo.diff(
    repo.resolve('HEAD~1'),
    repo.headId,
    renameThreshold: threshold,
  );
  return {
    for (final change in changes)
      switch (change.kind) {
        ChangeKind.renamed => 'R\t${change.oldPath}\t${change.newPath}',
        ChangeKind.added => 'A\t${change.newPath}',
        ChangeKind.deleted => 'D\t${change.oldPath}',
        ChangeKind.typeChanged => 'T\t${change.path}',
        ChangeKind.modified => 'M\t${change.path}',
      },
  };
}

/// Twenty lines of plausible source, so a small edit leaves most of it alone.
String body(String marker) => [
      for (var i = 0; i < 20; i++) 'line $i of $marker with some text on it',
    ].join('\n');

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_rename');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    write('one.txt', '${body('one')}\n');
    write('two.txt', '${body('two')}\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('a rename with a small edit is detected, as git detects it', () {
    git(['mv', 'one.txt', 'moved.txt']);
    write('moved.txt', '${body('one')}\nand one more line\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'move and edit']);

    final repo = Repository.open(repoPath);
    final changes = repo.diff(repo.resolve('HEAD~1'), repo.headId);
    expect(changes, hasLength(1));
    expect(changes.single.kind, ChangeKind.renamed);
    expect(changes.single.oldPath, 'one.txt');
    expect(changes.single.newPath, 'moved.txt');

    expect(ourStatus(repo), gitStatus());
    repo.close();
  });

  test('a rewritten file under a new name is not called a rename', () {
    // Wholly different content. Calling this a rename would be worse than
    // useless: it claims a history the file does not have.
    git(['rm', '-q', 'one.txt']);
    write('unrelated.txt', 'nothing at all like the other file\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'replace']);

    final repo = Repository.open(repoPath);
    final kinds = repo.diff(repo.resolve('HEAD~1'), repo.headId)
        .map((c) => c.kind)
        .toSet();
    expect(kinds, {ChangeKind.added, ChangeKind.deleted});
    expect(ourStatus(repo), gitStatus());
    repo.close();
  });

  test('the threshold decides the borderline case, as it does for git', () {
    // About half the lines change, which is where the threshold bites.
    git(['mv', 'one.txt', 'half.txt']);
    final lines = body('one').split('\n');
    for (var i = 0; i < 10; i++) {
      lines[i] = 'wholly different line $i';
    }
    write('half.txt', '${lines.join('\n')}\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'half rewritten']);

    final repo = Repository.open(repoPath);
    // Demanding: not a rename, for us and for git.
    expect(ourStatus(repo, threshold: 90), gitStatus(threshold: 90));
    // Forgiving: a rename, for both.
    expect(ourStatus(repo, threshold: 20), gitStatus(threshold: 20));
    expect(
      repo
          .diff(repo.resolve('HEAD~1'), repo.headId, renameThreshold: 20)
          .single
          .kind,
      ChangeKind.renamed,
    );
    repo.close();
  });

  test('each file is paired at most once', () {
    // Two files that are similar to each other and both move. Pairing one
    // deletion with two additions would report a file that does not exist.
    git(['mv', 'one.txt', 'first-moved.txt']);
    git(['mv', 'two.txt', 'second-moved.txt']);
    git(['commit', '-q', '-m', 'both moved']);

    final repo = Repository.open(repoPath);
    final changes = repo.diff(repo.resolve('HEAD~1'), repo.headId);
    expect(changes.every((c) => c.kind == ChangeKind.renamed), isTrue);
    expect(changes.map((c) => c.oldPath).toSet(), {'one.txt', 'two.txt'});
    expect(changes.map((c) => c.newPath).toSet(),
        {'first-moved.txt', 'second-moved.txt'});
    expect(ourStatus(repo), gitStatus());
    repo.close();
  });

  test('a move into a subdirectory is still a move', () {
    git(['mv', 'one.txt', 'nested-one.txt']);
    Directory(p.join(repoPath, 'src')).createSync();
    git(['mv', 'nested-one.txt', p.join('src', 'one.txt')]);
    write(p.join('src', 'one.txt'), '${body('one')}\nplus a line\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'into src']);

    final repo = Repository.open(repoPath);
    final change = repo
        .diff(repo.resolve('HEAD~1'), repo.headId)
        .firstWhere((c) => c.kind == ChangeKind.renamed);
    expect(change.oldPath, 'one.txt');
    expect(change.newPath, 'src/one.txt');
    expect(ourStatus(repo), gitStatus());
    repo.close();
  });

  test('detection can be turned off', () {
    git(['mv', 'one.txt', 'moved.txt']);
    git(['commit', '-q', '-m', 'move']);

    final repo = Repository.open(repoPath);
    final kinds = repo
        .diff(repo.resolve('HEAD~1'), repo.headId, detectRenames: false)
        .map((c) => c.kind)
        .toSet();
    expect(kinds, {ChangeKind.added, ChangeKind.deleted});
    repo.close();
  });

  test('an exact rename is still found without reading content', () {
    // The cheap pass, which must keep working now that there is a second one.
    git(['mv', 'one.txt', 'untouched.txt']);
    git(['commit', '-q', '-m', 'pure move']);

    final repo = Repository.open(repoPath);
    final change = repo.diff(repo.resolve('HEAD~1'), repo.headId).single;
    expect(change.kind, ChangeKind.renamed);
    expect(change.oldId, change.newId);
    expect(gitStatus(), contains('R\tone.txt\tuntouched.txt'));
    repo.close();
  });
}
