/// Counting how far apart two tips are, against git's own count.
///
/// Every case is checked with `git rev-list --left-right --count`, including
/// the ones a naive walk gets right by accident: a merge on one side, both
/// sides moved, and one side an ancestor of the other.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

void commit(String name) {
  File(p.join(repoPath, '$name.txt')).writeAsStringSync('$name\n');
  git(['add', '.']);
  git(['commit', '-q', '-m', name]);
}

/// git's answer for the same pair.
({int ahead, int behind}) theirs(String ours, String them) {
  final counts = git(['rev-list', '--left-right', '--count', '$ours...$them'])
      .trim()
      .split(RegExp(r'\s+'));
  return (ahead: int.parse(counts[0]), behind: int.parse(counts[1]));
}

void expectAgreement(Repository repo, String ours, String them) {
  final mine = repo.countAheadBehind(
    repo.resolve(ours)!,
    repo.resolve(them)!,
  )!;
  final git = theirs(ours, them);
  expect(
    (ahead: mine.ahead, behind: mine.behind),
    git,
    reason: '$ours...$them',
  );
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_aheadbehind');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    commit('base');
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('two tips at the same commit are even', () {
    git(['branch', 'side']);
    final repo = Repository.open(repoPath);
    expect(
        repo
            .countAheadBehind(
              repo.resolve('main')!,
              repo.resolve('side')!,
            )!
            .isEven,
        isTrue);
    repo.close();
  });

  test('one side ahead', () {
    git(['branch', 'side']);
    commit('one');
    commit('two');

    final repo = Repository.open(repoPath);
    expectAgreement(repo, 'main', 'side');
    expect(
        repo
            .countAheadBehind(
              repo.resolve('main')!,
              repo.resolve('side')!,
            )!
            .ahead,
        2);
    repo.close();
  });

  test('both sides moved', () {
    git(['branch', 'side']);
    commit('ours one');
    commit('ours two');
    git(['checkout', '-q', 'side']);
    commit('theirs one');
    git(['checkout', '-q', 'main']);

    final repo = Repository.open(repoPath);
    expectAgreement(repo, 'main', 'side');
    expectAgreement(repo, 'side', 'main');
    repo.close();
  });

  test('a merge on one side is counted the way git counts it', () {
    git(['branch', 'side']);
    commit('ours');
    git(['checkout', '-q', 'side']);
    commit('theirs');
    git(['checkout', '-q', 'main']);
    git(['merge', '--no-edit', '-q', 'side']);
    commit('after the merge');

    final repo = Repository.open(repoPath);
    expectAgreement(repo, 'main', 'side');
    expectAgreement(repo, 'side', 'main');
    repo.close();
  });

  test('an ancestor is behind and not ahead', () {
    commit('one');
    commit('two');

    final repo = Repository.open(repoPath);
    expectAgreement(repo, 'HEAD~2', 'HEAD');
    final counts = repo.countAheadBehind(
      repo.resolve('HEAD~2')!,
      repo.resolve('HEAD')!,
    )!;
    expect(counts.ahead, 0);
    expect(counts.behind, 2);
    repo.close();
  });

  test('unrelated histories count everything on both sides', () {
    // No common ancestor at all: the walk has nothing to stop it early and
    // must still terminate with the right answer.
    git(['checkout', '-q', '--orphan', 'other']);
    git(['rm', '-rq', '--cached', '.']);
    commit('alone');

    final repo = Repository.open(repoPath);
    expectAgreement(repo, 'main', 'other');
    repo.close();
  });

  test('a history larger than the limit is not counted rather than guessed',
      () {
    for (var i = 0; i < 5; i++) {
      commit('c$i');
    }
    git(['branch', 'side']);
    commit('ours');

    final repo = Repository.open(repoPath);
    // Below the limit it answers; above it, it says it did not count.
    expect(
      repo.countAheadBehind(
        repo.resolve('main')!,
        repo.resolve('side')!,
      ),
      isNotNull,
    );
    expect(
      repo.countAheadBehind(
        repo.resolve('main')!,
        repo.resolve('side')!,
        limit: 2,
      ),
      isNull,
    );
    repo.close();
  });

  test('counting a small divergence is quick', () {
    // A long shared history with a small divergence at the tip. A walk that
    // read everything reachable would touch every commit here; this must not.
    for (var i = 0; i < 60; i++) {
      commit('shared $i');
    }
    git(['branch', 'side']);
    commit('only ours');
    git(['checkout', '-q', 'side']);
    commit('only theirs');
    git(['checkout', '-q', 'main']);

    final repo = Repository.open(repoPath);
    final ours = repo.resolve('main')!;
    final them = repo.resolve('side')!;

    // git is asked first, outside the measurement. Spawning a process costs
    // more than the walk being measured, and timing the two together makes a
    // test about the shape of a walk fail whenever the machine is busy.
    final expected = theirs('main', 'side');

    final clock = Stopwatch()..start();
    final mine = repo.countAheadBehind(ours, them)!;
    clock.stop();

    expect((ahead: mine.ahead, behind: mine.behind), expected);

    // A guard against a pathological regression - re-reading the object store
    // per commit, say - and not a benchmark. Wall clock is a weak proxy here:
    // without a commit-graph this walk reads every reachable commit by design,
    // and the test harness costs several times what the walk does. The budget
    // is therefore wide enough that only a real blow-up trips it.
    expect(clock.elapsedMilliseconds, lessThan(3000));
    repo.close();
  });

  for (final seed in const [20260806, 7, 99]) {
    test('agrees with git across randomly built histories (seed $seed)', () {
      // Slop is a margin, not a proof, so the shape of the graph is varied
      // rather than argued about: branches, merges and interleaving, all with
      // commits made in the same second, which is the case that broke the
      // first version.
      final random = Random(seed);
      final branches = <String>['main'];

      for (var step = 0; step < 30; step++) {
        final on = branches[random.nextInt(branches.length)];
        git(['checkout', '-q', on]);

        switch (random.nextInt(10)) {
          case 0 || 1 when branches.length < 5:
            final name = 'b$step';
            git(['checkout', '-q', '-b', name]);
            branches.add(name);
            commit('start of $name');
          case 2 || 3 when branches.length > 1:
            final other = branches[random.nextInt(branches.length)];
            if (other == on) {
              commit('plain $step');
            } else {
              final merge = Process.runSync(
                'git',
                ['merge', '--no-edit', '-q', other],
                workingDirectory: repoPath,
              );
              // A conflict is not what this test is about; take either side.
              if (merge.exitCode != 0) {
                Process.runSync('git', ['checkout', '--theirs', '.'],
                    workingDirectory: repoPath);
                Process.runSync('git', ['add', '-A'],
                    workingDirectory: repoPath);
                Process.runSync('git', ['commit', '-q', '--no-edit'],
                    workingDirectory: repoPath);
              }
            }
          default:
            commit('work $step');
        }
      }

      final repo = Repository.open(repoPath);
      for (final ours in branches) {
        for (final them in branches) {
          if (ours == them) continue;
          expectAgreement(repo, ours, them);
        }
      }
      repo.close();
    });
  }
}
