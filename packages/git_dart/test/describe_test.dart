/// `describe`, checked against git.
///
/// The whole value of the string is that people paste it into bug reports and
/// version numbers, so it has to be the same string git would have produced —
/// a name that is merely *plausible* is worse than none, because nobody can
/// tell it apart from a real one.
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

/// git's answer, or null where it refuses because nothing describes it.
String? gitDescribe({List<String> extra = const []}) {
  final result = Process.runSync(
    'git',
    ['describe', ...extra],
    workingDirectory: repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return result.exitCode == 0 ? (result.stdout as String).trim() : null;
}

void commit(String message) {
  File(p.join(repoPath, 'f.txt')).writeAsStringSync('$message\n');
  git(['add', '-A']);
  _clock += 60;
  git(['commit', '-q', '-m', message]);
}

String? ours({bool annotatedOnly = false}) {
  final repo = Repository.open(repoPath);
  final result = describe(repo, annotatedOnly: annotatedOnly);
  repo.close();
  return result?.toString();
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_describe');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('a tagged commit describes as the tag alone', () {
    commit('one');
    git(['tag', '-a', 'v1.0.0', '-m', 'release one']);

    expect(ours(), 'v1.0.0');
    expect(ours(), gitDescribe());

    final repo = Repository.open(repoPath);
    expect(describe(repo)!.isExact, isTrue);
    expect(describe(repo)!.distance, 0);
    repo.close();
  });

  test('commits after a tag are counted', () {
    commit('one');
    git(['tag', '-a', 'v1.0.0', '-m', 'release one']);
    commit('two');
    commit('three');

    // v1.0.0-2-g<hash>, and git's string exactly.
    expect(ours(), gitDescribe());
    expect(ours(), startsWith('v1.0.0-2-g'));

    final repo = Repository.open(repoPath);
    expect(describe(repo)!.distance, 2);
    expect(describe(repo)!.isExact, isFalse);
    repo.close();
  });

  test('the nearest tag wins, not the newest', () {
    commit('one');
    git(['tag', '-a', 'v1.0.0', '-m', 'one']);
    commit('two');
    commit('three');
    git(['tag', '-a', 'v2.0.0', '-m', 'two']);
    commit('four');

    // v2.0.0 is one commit back; v1.0.0 is three.
    expect(ours(), gitDescribe());
    expect(ours(), startsWith('v2.0.0-1-g'));
  });

  test('a lightweight tag is used unless only annotated ones are asked for',
      () {
    commit('one');
    git(['tag', 'plain']); // no -a: a ref and nothing else
    commit('two');

    // git needs --tags to consider lightweight ones; so does this, via the
    // flag that says which kind counts.
    expect(ours(), gitDescribe(extra: ['--tags']));
    expect(ours(), startsWith('plain-1-g'));

    // Asked for annotated tags only, there are none to find.
    expect(ours(annotatedOnly: true), isNull);
    expect(gitDescribe(), isNull);
  });

  test('a repository with no tags describes as nothing', () {
    commit('one');

    expect(ours(), isNull);
    // git treats it as an error; this reports it as an answer.
    expect(gitDescribe(), isNull);
  });

  test('an unborn repository describes as nothing', () {
    final repo = Repository.open(repoPath);
    expect(describe(repo), isNull);
    repo.close();
  });

  test('the abbreviation is long enough to be unambiguous', () {
    commit('one');
    git(['tag', '-a', 'v1.0.0', '-m', 'one']);
    commit('two');

    final repo = Repository.open(repoPath);
    final result = describe(repo)!;
    repo.close();

    expect(result.abbreviation, greaterThanOrEqualTo(7));
    // And it really does name this commit.
    expect(
      git(['rev-parse', result.commit.hex.substring(0, result.abbreviation)])
          .trim(),
      result.commit.hex,
    );
  });

  test('describing an older commit ignores tags made after it', () {
    commit('one');
    git(['tag', '-a', 'v1.0.0', '-m', 'one']);
    commit('two');
    final middle = git(['rev-parse', 'HEAD']).trim();
    commit('three');
    git(['tag', '-a', 'v2.0.0', '-m', 'two']);

    final repo = Repository.open(repoPath);
    final result = describe(repo, commit: ObjectId.fromHex(middle))!;
    repo.close();

    // v2.0.0 is not reachable from here, so the older tag is the answer.
    expect(result.tag, 'v1.0.0');
    expect(result.distance, 1);
    expect(result.toString(), gitDescribe(extra: [middle]));
  });

  test('distance counts commits, not steps, across a merge', () {
    commit('base');
    git(['tag', '-a', 'v1.0.0', '-m', 'base']);
    git(['branch', 'side']);

    File(p.join(repoPath, 'main.txt')).writeAsStringSync('main\n');
    git(['add', '-A']);
    _clock += 60;
    git(['commit', '-q', '-m', 'on main']);

    git(['checkout', '-q', 'side']);
    File(p.join(repoPath, 'side.txt')).writeAsStringSync('side\n');
    git(['add', '-A']);
    _clock += 60;
    git(['commit', '-q', '-m', 'on side']);

    git(['checkout', '-q', 'main']);
    _clock += 60;
    git(['merge', '-q', '--no-edit', 'side']);

    // Three commits are reachable from HEAD and not from the tag, however
    // many steps any single path takes.
    expect(ours(), gitDescribe());
    expect(ours(), startsWith('v1.0.0-3-g'));
  });

  test('the tag it names is the commit the tag points at', () {
    commit('one');
    git(['tag', '-a', 'v1.0.0', '-m', 'one']);
    final tagged = git(['rev-parse', 'v1.0.0^{commit}']).trim();
    commit('two');

    final repo = Repository.open(repoPath);
    final result = describe(repo)!;
    repo.close();

    // Peeled: an annotated tag's own object is not the commit.
    expect(result.taggedCommit.hex, tagged);
  });
}
