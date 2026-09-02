/// Blame, checked line by line against git's own.
///
/// Nothing records which commit wrote a line — git stores whole objects and
/// derives this by walking backwards and diffing, exactly as it derives a
/// rename. So the answer is a claim about a sequence of diffs, and the only
/// way to know the claim is right is to make git the same one.
///
/// The walk here follows first parents, so `git blame --first-parent` is the
/// comparison wherever a merge is involved.
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

void write(String name, String contents) =>
    File(p.join(repoPath, name)).writeAsStringSync(contents);

void commit(String message) {
  git(['add', '-A']);
  _clock += 60;
  git(['commit', '-q', '-m', message]);
}

/// The commit git attributes each line to, in order.
///
/// `--porcelain` opens every group with `<sha> <original> <final> [count]`,
/// which is the whole of what is being compared here.
List<String> gitBlame(String file, {List<String> extra = const []}) {
  final output = git(['blame', '--porcelain', ...extra, file]);
  final perLine = <String>[];
  var expecting = 0;
  String? sha;

  for (final line in const LineSplitter().convert(output)) {
    if (expecting > 0 && line.startsWith('\t')) {
      perLine.add(sha!);
      expecting -= 1;
      continue;
    }
    final match = RegExp(r'^([0-9a-f]{40}) \d+ \d+(?: (\d+))?$').firstMatch(line);
    if (match != null) {
      sha = match.group(1);
      expecting = 1;
    }
  }
  return perLine;
}

List<String> ourBlame(String file, {ObjectId? start}) {
  final repo = Repository.open(repoPath);
  final result = blame(repo, file, start: start)!;
  repo.close();
  return result.lines.map((line) => line.commit.hex).toList();
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_blame');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('a file written once is all one commit', () {
    write('f.txt', 'one\ntwo\nthree\n');
    commit('first');

    final repo = Repository.open(repoPath);
    final result = blame(repo, 'f.txt')!;
    repo.close();

    expect(result.lines, hasLength(3));
    expect(result.contributors, hasLength(1));
    expect(result.lines.map((l) => l.text), ['one', 'two', 'three']);
    expect(ourBlame('f.txt'), gitBlame('f.txt'));
  });

  test('editing one line re-attributes only that line', () {
    write('f.txt', 'one\ntwo\nthree\n');
    commit('first');
    write('f.txt', 'one\nCHANGED\nthree\n');
    commit('second');

    final ours = ourBlame('f.txt');
    expect(ours, gitBlame('f.txt'));
    // The untouched lines still belong to the first commit.
    expect(ours[0], ours[2]);
    expect(ours[1], isNot(ours[0]));
  });

  test('inserted lines belong to the commit that inserted them', () {
    write('f.txt', 'one\ntwo\n');
    commit('first');
    write('f.txt', 'one\ninserted\ntwo\n');
    commit('second');

    expect(ourBlame('f.txt'), gitBlame('f.txt'));

    final repo = Repository.open(repoPath);
    final result = blame(repo, 'f.txt')!;
    repo.close();
    expect(result.lines[1].text, 'inserted');
    expect(result.lines[1].summary, 'second');
  });

  test('a line keeps its original number from when it was written', () {
    write('f.txt', 'first line\n');
    commit('one');
    write('f.txt', 'added above\nfirst line\n');
    commit('two');

    final repo = Repository.open(repoPath);
    final result = blame(repo, 'f.txt')!;
    repo.close();

    // It is line two now and was line one when it was written.
    final original = result.lines[1];
    expect(original.text, 'first line');
    expect(original.number, 2);
    expect(original.originalNumber, 1);
  });

  test('a long history agrees with git line for line', () {
    // Every commit edits a different line, so each one owns exactly one and
    // the answer is fully determined.
    final lines = List.generate(12, (i) => 'line $i');
    write('f.txt', '${lines.join('\n')}\n');
    commit('base');

    for (var i = 0; i < 12; i += 2) {
      lines[i] = 'line $i edited';
      write('f.txt', '${lines.join('\n')}\n');
      commit('edit $i');
    }

    expect(ourBlame('f.txt'), gitBlame('f.txt'));
  });

  test('appends and deletions agree with git', () {
    write('f.txt', 'a\nb\nc\nd\n');
    commit('base');
    write('f.txt', 'a\nc\nd\n'); // b deleted
    commit('delete b');
    write('f.txt', 'a\nc\nd\ne\n'); // e appended
    commit('append e');

    expect(ourBlame('f.txt'), gitBlame('f.txt'));
  });

  test('the author and summary come from the introducing commit', () {
    write('f.txt', 'original\n');
    git(['add', '-A']);
    _clock += 60;
    git(['-c', 'user.name=B', '-c', 'user.email=b@x', 'commit', '-q', '-m',
        'written by B']);

    final repo = Repository.open(repoPath);
    final result = blame(repo, 'f.txt')!;
    repo.close();

    expect(result.lines.single.author.name, 'B');
    expect(result.lines.single.author.email, 'b@x');
    expect(result.lines.single.summary, 'written by B');
  });

  test('blame at an older commit ignores what came after', () {
    write('f.txt', 'one\n');
    commit('first');
    final atFirst = git(['rev-parse', 'HEAD']).trim();
    write('f.txt', 'one\ntwo\n');
    commit('second');

    final repo = Repository.open(repoPath);
    final result = blame(repo, 'f.txt', start: ObjectId.fromHex(atFirst))!;
    repo.close();

    expect(result.lines, hasLength(1));
    expect(result.lines.single.commit.hex, atFirst);
    expect(ourBlame('f.txt', start: ObjectId.fromHex(atFirst)),
        gitBlame('f.txt', extra: [atFirst]));
  });

  test('a file added later is attributed to the commit that added it', () {
    write('a.txt', 'first file\n');
    commit('one');
    write('b.txt', 'second file\n');
    commit('two');

    final added = git(['rev-parse', 'HEAD']).trim();
    final repo = Repository.open(repoPath);
    final result = blame(repo, 'b.txt')!;
    repo.close();

    expect(result.lines.single.commit.hex, added);
    expect(ourBlame('b.txt'), gitBlame('b.txt'));
  });

  test('a path that is not a file gives nothing', () {
    write('f.txt', 'content\n');
    commit('one');

    final repo = Repository.open(repoPath);
    expect(blame(repo, 'nothing-here.txt'), isNull);
    repo.close();
  });

  test('a binary file gives nothing rather than nonsense', () {
    File(p.join(repoPath, 'blob.bin'))
        .writeAsBytesSync([0x01, 0x00, 0x02, 0x00, 0x03]);
    commit('binary');

    final repo = Repository.open(repoPath);
    expect(blame(repo, 'blob.bin'), isNull);
    repo.close();
  });

  test('an empty file has no lines to attribute', () {
    write('empty.txt', '');
    commit('empty');

    final repo = Repository.open(repoPath);
    final result = blame(repo, 'empty.txt');
    repo.close();
    expect(result?.lines, isEmpty);
  });

  test('a merge follows the first parent, as git does with --first-parent',
      () {
    write('f.txt', 'base\nshared\n');
    commit('base');
    git(['branch', 'side']);

    write('f.txt', 'main edit\nshared\n');
    commit('on main');

    git(['checkout', '-q', 'side']);
    write('other.txt', 'side only\n');
    commit('on side');

    git(['checkout', '-q', 'main']);
    _clock += 60;
    git(['merge', '-q', '--no-edit', 'side']);

    expect(ourBlame('f.txt'), gitBlame('f.txt', extra: ['--first-parent']));
  });

  test('contributors lists each commit once, in the order met', () {
    write('f.txt', 'a\nb\n');
    commit('one');
    write('f.txt', 'A\nb\n');
    commit('two');

    final repo = Repository.open(repoPath);
    final result = blame(repo, 'f.txt')!;
    repo.close();

    expect(result.contributors, hasLength(2));
    expect(result.contributors.first, result.lines.first.commit);
  });
}
