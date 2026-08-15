/// The reflog, checked against git's own.
///
/// The spec calls this the thing that makes a lost commit findable
/// (`refs.reflog`). The test that matters is not that we write a file — it is
/// that git reads what we wrote as its own reflog, and that a commit nothing
/// points at is still nameable afterwards.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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

void write(String name, String contents) {
  File(p.join(repoPath, name)).writeAsStringSync(contents);
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_reflog');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    write('a.txt', 'one\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('a commit we write appears in git reflog', () {
    final repo = Repository.open(repoPath);
    write('a.txt', 'two\n');
    repo.stage('a.txt');
    final id = repo.commitIndex(message: 'second');
    repo.close();

    // git's own reader, on our file. If the format were wrong this is where
    // it would show.
    final log = git(['reflog', '--format=%H %gs']);
    expect(log, contains(id.hex));
    expect(log, contains('commit: second'));

    // And the previous position is still named, which is the point.
    expect(git(['rev-parse', 'HEAD@{1}']).trim(),
        git(['rev-parse', '$id^']).trim());
  });

  test('a commit moved off a branch is still findable', () {
    final repo = Repository.open(repoPath);
    write('a.txt', 'two\n');
    repo.stage('a.txt');
    final lost = repo.commitIndex(message: 'second');

    // The branch moves back. Nothing points at `lost` now: it is unreachable
    // from every ref, so the walk cannot see it and neither can `reachable`.
    final first = repo.resolve('$lost^')!;
    repo.refs.write('refs/heads/main', first, reflogMessage: 'reset: to HEAD^');

    expect(repo.reachable([first]).contains(lost), isFalse);
    expect(repo.log().map((c) => c.id), isNot(contains(lost)));

    // The reflog still names it, and resolves it.
    expect(repo.resolve('main@{1}'), lost);
    expect(repo.resolve('HEAD@{1}'), lost);

    final entries = repo.reflogFor('refs/heads/main').entries;
    expect(entries.last.from, lost);
    expect(entries.last.to, first);
    expect(entries.last.message, 'reset: to HEAD^');
    repo.close();

    // git agrees.
    expect(git(['rev-parse', 'main@{1}']).trim(), lost.hex);
  });

  test('our entries parse back to what we wrote', () {
    final repo = Repository.open(repoPath);
    write('a.txt', 'two\n');
    repo.stage('a.txt');
    final id = repo.commitIndex(message: 'second\n\nwith a body');

    final log = repo.reflogFor('refs/heads/main');
    expect(log.isEmpty, isFalse);

    final entry = log.entries.last;
    expect(entry.to, id);
    expect(entry.who.name, 'A');
    expect(entry.who.email, 'a@x');
    // The summary only — a reflog line is one line, and the body is in the
    // commit where it belongs.
    expect(entry.message, 'commit: second');

    expect(log.entryAt(0), id);
    expect(log.entryAt(1), repo.resolve('$id^'));
    expect(log.entryAt(99), isNull);
    repo.close();
  });

  test('a checkout records where HEAD moved from and to', () {
    git(['branch', 'side']);

    final repo = Repository.open(repoPath);
    repo.checkout('side');
    repo.close();

    final head = git(['reflog', 'show', 'HEAD', '--format=%gs']);
    expect(head, contains('checkout: moving from main to side'));
  });

  test('a branch we create and delete logs and then forgets', () {
    final repo = Repository.open(repoPath);
    repo.createBranch('feature');
    expect(repo.reflogFor('refs/heads/feature').isEmpty, isFalse);

    repo.deleteBranch('feature');
    // The log goes with the ref: a later branch of the same name has not been
    // anywhere.
    expect(repo.reflogFor('refs/heads/feature').isEmpty, isTrue);
    repo.close();

    expect(
      File(p.join(repoPath, '.git', 'logs', 'refs', 'heads', 'feature'))
          .existsSync(),
      isFalse,
    );
  });

  test('a renamed branch carries its history with it', () {
    final repo = Repository.open(repoPath);
    write('a.txt', 'two\n');
    repo.stage('a.txt');
    repo.commitIndex(message: 'second');

    final before = repo.reflogFor('refs/heads/main').length;
    repo.renameBranch('main', 'trunk');

    final after = repo.reflogFor('refs/heads/trunk');
    // Everything that was there, plus the rename itself.
    expect(after.length, before + 1);
    expect(after.entries.last.message, 'branch: renamed main to trunk');
    expect(repo.reflogFor('refs/heads/main').isEmpty, isTrue);
    repo.close();

    expect(git(['reflog', 'show', 'trunk', '--format=%gs']),
        contains('commit: second'));
  });

  test('a tag does not get a reflog, a branch does', () {
    final repo = Repository.open(repoPath);
    repo.refs.write('refs/tags/v1', repo.headId!, reflogMessage: 'tagging');
    repo.refs.write('refs/heads/other', repo.headId!, reflogMessage: 'branch');

    expect(repo.reflogFor('refs/tags/v1').isEmpty, isTrue);
    expect(repo.reflogFor('refs/heads/other').isEmpty, isFalse);
    repo.close();
  });

  test('a repository with no configured identity writes no reflog', () {
    // Better than a line attributing the move to nobody: that looks like a
    // record and is not one.
    git(['config', '--unset', 'user.name']);
    git(['config', '--unset', 'user.email']);
    // The global config would otherwise supply one.
    final home = p.join(scratch.path, 'home');
    Directory(home).createSync();

    final repo = Repository.at(p.join(repoPath, '.git'), workTree: repoPath);
    repo.refs.identityFor = () => null;
    repo.refs.write('refs/heads/quiet', repo.headId!, reflogMessage: 'created');
    expect(repo.reflogFor('refs/heads/quiet').isEmpty, isTrue);
    repo.close();
  });
}
