/// Merging, checked against git.
///
/// The case that prompted this: two sides that each changed a different file.
/// Git merges that without asking anyone, and so must this — comparing the two
/// sides alone cannot tell "they changed it" from "we both changed it", which
/// is the whole reason a merge uses the common ancestor.
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

void commitAll(String message) {
  git(['add', '-A']);
  git(['commit', '-q', '-m', message]);
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_merge');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    write('shared.txt', 'one\ntwo\nthree\nfour\nfive\n');
    write('ours.txt', 'ours\n');
    write('theirs.txt', 'theirs\n');
    commitAll('base');
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('two sides that touched different files merge without asking', () {
    git(['branch', 'side']);
    write('ours.txt', 'ours, changed\n');
    commitAll('ours');

    git(['checkout', '-q', 'side']);
    write('theirs.txt', 'theirs, changed\n');
    commitAll('theirs');
    git(['checkout', '-q', 'main']);

    final repo = Repository.open(repoPath);
    final result = merge(repo, repo.resolve('side')!);
    repo.close();

    expect(result.outcome, MergeOutcome.merged);
    expect(result.conflicts, isEmpty);

    // Both changes are present, and git agrees the result is sound.
    expect(File(p.join(repoPath, 'ours.txt')).readAsStringSync(),
        'ours, changed\n');
    expect(File(p.join(repoPath, 'theirs.txt')).readAsStringSync(),
        'theirs, changed\n');
    expect(git(['status', '--porcelain']), isEmpty);
    expect(git(['fsck', '--no-progress']), isNotNull);

    // A merge commit with both parents, in the order git records them.
    expect(git(['rev-list', '--count', 'HEAD']).trim(), '4');
    final parents = git(['log', '-1', '--format=%P']).trim().split(' ');
    expect(parents, hasLength(2));
    expect(parents.last, git(['rev-parse', 'side']).trim());
  });

  test('the same file, different lines, merges line by line', () {
    git(['branch', 'side']);
    write('shared.txt', 'ONE\ntwo\nthree\nfour\nfive\n');
    commitAll('ours change the first line');

    git(['checkout', '-q', 'side']);
    write('shared.txt', 'one\ntwo\nthree\nfour\nFIVE\n');
    commitAll('theirs change the last line');
    git(['checkout', '-q', 'main']);

    final repo = Repository.open(repoPath);
    final result = merge(repo, repo.resolve('side')!);
    repo.close();

    expect(result.outcome, MergeOutcome.merged);
    expect(
      File(p.join(repoPath, 'shared.txt')).readAsStringSync(),
      'ONE\ntwo\nthree\nfour\nFIVE\n',
    );
    expect(git(['status', '--porcelain']), isEmpty);
  });

  test('the same lines on both sides is a conflict, staged as three sides',
      () {
    git(['branch', 'side']);
    write('shared.txt', 'ours\ntwo\nthree\nfour\nfive\n');
    commitAll('ours');

    git(['checkout', '-q', 'side']);
    write('shared.txt', 'theirs\ntwo\nthree\nfour\nfive\n');
    commitAll('theirs');
    git(['checkout', '-q', 'main']);

    final repo = Repository.open(repoPath);
    final result = merge(repo, repo.resolve('side')!);
    repo.close();

    expect(result.outcome, MergeOutcome.conflicted);
    expect(result.conflicts, ['shared.txt']);

    // git sees the conflict the way it sees its own: unmerged, three stages.
    expect(git(['status', '--porcelain']), contains('shared.txt'));
    final staged = git(['ls-files', '--unmerged']);
    expect(staged, contains('shared.txt'));
    expect(RegExp(r'\s1\s').hasMatch(staged), isTrue); // base
    expect(RegExp(r'\s2\s').hasMatch(staged), isTrue); // ours
    expect(RegExp(r'\s3\s').hasMatch(staged), isTrue); // theirs

    // And the working tree has markers for a person to resolve.
    final content = File(p.join(repoPath, 'shared.txt')).readAsStringSync();
    expect(content, contains('<<<<<<<'));
    expect(content, contains('======='));
    expect(content, contains('>>>>>>>'));

    // The merge is recorded as in progress, so a later commit knows its
    // second parent.
    expect(
      File(p.join(repoPath, '.git', 'MERGE_HEAD')).readAsStringSync().trim(),
      git(['rev-parse', 'side']).trim(),
    );
  });

  test('resolving a conflict and committing writes a merge commit', () {
    git(['branch', 'side']);
    write('shared.txt', 'ours\ntwo\nthree\nfour\nfive\n');
    commitAll('ours');

    git(['checkout', '-q', 'side']);
    write('shared.txt', 'theirs\ntwo\nthree\nfour\nfive\n');
    commitAll('theirs');
    git(['checkout', '-q', 'main']);

    final sideTip = git(['rev-parse', 'side']).trim();

    var repo = Repository.open(repoPath);
    expect(merge(repo, repo.resolve('side')!).outcome,
        MergeOutcome.conflicted);
    expect(repo.isMerging, isTrue);
    repo.close();

    // A person resolves it and stages the result, as they would.
    write('shared.txt', 'resolved\ntwo\nthree\nfour\nfive\n');
    repo = Repository.open(repoPath);
    repo.stage('shared.txt');
    final id = repo.commitIndex(message: 'resolve the conflict');
    repo.close();

    // Two parents, ours first: the first parent is the branch merged into
    // (`objects.commit-format`). Without reading MERGE_HEAD back this commit
    // has one parent and the merge is silently lost.
    final parents = git(['rev-list', '--parents', '-n', '1', id.hex])
        .trim()
        .split(RegExp(r'\s+'));
    expect(parents.length, 3, reason: 'a merge commit has two parents');
    expect(parents[2], sideTip);

    // git agrees the branch is now merged, and the state is cleared.
    expect(git(['branch', '--merged']), contains('side'));
    expect(File(p.join(repoPath, '.git', 'MERGE_HEAD')).existsSync(), isFalse);
    expect(File(p.join(repoPath, '.git', 'MERGE_MSG')).existsSync(), isFalse);
  });

  test('a merge that resolved to our own tree still commits', () {
    // Both sides changed the same lines, and the person resolving picks ours
    // wholesale. The tree is then identical to HEAD's — and the commit still
    // has to happen, because its point is the second parent, not the tree.
    git(['branch', 'side']);
    write('shared.txt', 'ours\ntwo\nthree\nfour\nfive\n');
    commitAll('ours');

    git(['checkout', '-q', 'side']);
    write('shared.txt', 'theirs\ntwo\nthree\nfour\nfive\n');
    commitAll('theirs');
    git(['checkout', '-q', 'main']);

    final headTree = git(['rev-parse', 'HEAD^{tree}']).trim();

    var repo = Repository.open(repoPath);
    merge(repo, repo.resolve('side')!);
    repo.close();

    write('shared.txt', 'ours\ntwo\nthree\nfour\nfive\n');
    repo = Repository.open(repoPath);
    repo.stage('shared.txt');
    final id = repo.commitIndex(message: 'take ours');
    repo.close();

    expect(git(['rev-parse', '$id^{tree}']).trim(), headTree);
    expect(git(['rev-list', '--parents', '-n', '1', id.hex]).trim().split(' ').length, 3);
  });

  group('where two changes are close together', () {
    /// git merges changes with an untouched line between them and conflicts on
    /// changes that touch. Each case here was run through git first and the
    /// answer copied down, rather than reasoned about.
    void bothChange(String base, String ours, String theirs) {
      write('near.txt', base);
      commitAll('near base');
      git(['branch', '-f', 'near-side', 'HEAD']);

      write('near.txt', ours);
      commitAll('ours');
      git(['checkout', '-q', 'near-side']);
      write('near.txt', theirs);
      commitAll('theirs');
      git(['checkout', '-q', 'main']);
    }

    MergeOutcome outcomeOf() {
      final repo = Repository.open(repoPath);
      final result = merge(repo, repo.resolve('near-side')!);
      repo.close();
      return result.outcome;
    }

    test('one untouched line between them merges', () {
      bothChange('a\nb\nc\nd\ne\n', 'A\nb\nc\nd\ne\n', 'a\nb\nC\nd\ne\n');
      expect(outcomeOf(), MergeOutcome.merged);
      expect(File(p.join(repoPath, 'near.txt')).readAsStringSync(),
          'A\nb\nC\nd\ne\n');
    });

    test('changes on neighbouring lines conflict', () {
      bothChange('a\nb\nc\nd\ne\n', 'A\nb\nc\nd\ne\n', 'a\nB\nc\nd\ne\n');
      expect(outcomeOf(), MergeOutcome.conflicted);
    });

    test('both appending at the end conflicts', () {
      // Nothing says whose line comes first, so keeping both in some order
      // would be inventing an answer.
      bothChange('a\nb\n', 'a\nb\nOURS\n', 'a\nb\nTHEIRS\n');
      expect(outcomeOf(), MergeOutcome.conflicted);
    });

    test('both inserting at the same point conflicts', () {
      bothChange('a\nb\nc\n', 'a\nOURS\nb\nc\n', 'a\nTHEIRS\nb\nc\n');
      expect(outcomeOf(), MergeOutcome.conflicted);
    });

    test('both appending the identical line agrees', () {
      bothChange('a\nb\n', 'a\nb\nSAME\n', 'a\nb\nSAME\n');
      expect(outcomeOf(), MergeOutcome.merged);
      expect(File(p.join(repoPath, 'near.txt')).readAsStringSync(),
          'a\nb\nSAME\n');
    });
  });

  group('a criss-cross history', () {
    /// Two branches that have each merged the other and then carried on. The
    /// result has two best common ancestors and neither is a sound base on its
    /// own — which is the spec's last hazard.
    ///
    ///        A---B---M1---D      (main)
    ///         \ /   /
    ///          X   /
    ///         / \ /
    ///        C---E--M2---F       (side)
    void buildCrissCross() {
      // A is the commit setUp already made.
      git(['branch', 'side']);
      write('ours.txt', 'from main\n');
      commitAll('B');

      git(['checkout', '-q', 'side']);
      write('theirs.txt', 'from side\n');
      commitAll('C');
      final c = git(['rev-parse', 'HEAD']).trim();

      // Each side merges the *other's tip as it was*, not as it has since
      // become. Merging the branch name instead makes the second merge a
      // fast-forward — the first merge already contained everything — and
      // leaves a history with one base rather than two.
      git(['merge', '-q', '--no-edit', 'main']); // side = M2(C, B)
      git(['checkout', '-q', 'main']);
      git(['merge', '-q', '--no-edit', c]); // main = M1(B, C)
    }

    test('has more than one merge base, and git agrees which', () {
      buildCrissCross();

      final repo = Repository.open(repoPath);
      final ours = repo.resolve('main')!;
      final theirs = repo.resolve('side')!;
      final bases = mergeBases(repo, ours, theirs);
      repo.close();

      final fromGit = git(['merge-base', '--all', 'main', 'side'])
          .trim()
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toSet();

      expect(fromGit.length, greaterThan(1),
          reason: 'the history should be a genuine criss-cross');
      expect(bases.map((b) => b.hex).toSet(), fromGit);
    });

    test('merges to the same tree git merges to', () {
      buildCrissCross();

      // Each side now changes a different region of the same file. Against
      // either base alone this reads correctly; the point of the recursive
      // base is that it keeps reading correctly.
      write('shared.txt', 'ONE\ntwo\nthree\nfour\nfive\n');
      commitAll('D');

      git(['checkout', '-q', 'side']);
      write('shared.txt', 'one\ntwo\nthree\nfour\nFIVE\n');
      commitAll('F');
      git(['checkout', '-q', 'main']);

      var repo = Repository.open(repoPath);
      final result = merge(repo, repo.resolve('side')!);
      repo.close();

      expect(result.outcome, MergeOutcome.merged);
      expect(result.conflicts, isEmpty);
      final ourTree = git(['rev-parse', 'HEAD^{tree}']).trim();

      // Now let git do the same merge from the same starting point, and
      // compare the trees. git's recursive strategy is the reference.
      git(['reset', '-q', '--hard', 'HEAD^']);
      git(['merge', '-q', '--no-edit', 'side']);
      expect(git(['rev-parse', 'HEAD^{tree}']).trim(), ourTree);
    });

    test('a virtual base is built rather than one being picked', () {
      buildCrissCross();

      final repo = Repository.open(repoPath);
      final base = recursiveMergeBase(
        repo,
        [repo.resolve('main')!],
        [repo.resolve('side')!],
      );

      expect(base.isVirtual, isTrue);
      expect(base.commits.length, greaterThan(1));
      expect(base.tree, isNotNull);

      // The virtual tree holds both sides' additions, because both are in
      // both bases — which is exactly what picking one base would have
      // preserved too, and what makes the two indistinguishable here. The
      // real check is the tree comparison against git above.
      final tree = repo.objects.readTyped<Tree>(base.tree!);
      final names = tree.entries.map((e) => e.name).toSet();
      expect(names, containsAll(['ours.txt', 'theirs.txt']));
      repo.close();
    });
  });

  test('an aborted merge puts the working tree back and forgets the merge',
      () {
    git(['branch', 'side']);
    write('shared.txt', 'ours\ntwo\nthree\nfour\nfive\n');
    commitAll('ours');

    git(['checkout', '-q', 'side']);
    write('shared.txt', 'theirs\ntwo\nthree\nfour\nfive\n');
    commitAll('theirs');
    git(['checkout', '-q', 'main']);

    final repo = Repository.open(repoPath);
    merge(repo, repo.resolve('side')!);
    expect(repo.isMerging, isTrue);

    repo.abortMerge();
    expect(repo.isMerging, isFalse);
    repo.close();

    // The conflict markers are gone and git sees a clean tree.
    final content = File(p.join(repoPath, 'shared.txt')).readAsStringSync();
    expect(content, 'ours\ntwo\nthree\nfour\nfive\n');
    expect(git(['status', '--porcelain']).trim(), isEmpty);
  });

  test('a side that only moved forward is a fast-forward, not a commit', () {
    git(['branch', 'side']);
    git(['checkout', '-q', 'side']);
    write('theirs.txt', 'moved on\n');
    commitAll('theirs');
    git(['checkout', '-q', 'main']);

    final repo = Repository.open(repoPath);
    final result = merge(repo, repo.resolve('side')!);
    repo.close();

    expect(result.outcome, MergeOutcome.fastForward);
    expect(git(['rev-parse', 'HEAD']).trim(), git(['rev-parse', 'side']).trim());
    // No merge commit: the branch simply moved.
    expect(git(['log', '-1', '--format=%P']).trim().split(' '), hasLength(1));
    expect(File(p.join(repoPath, 'theirs.txt')).readAsStringSync(), 'moved on\n');
    expect(git(['status', '--porcelain']), isEmpty);
  });

  test('a side already contained is already up to date', () {
    git(['branch', 'side']);
    write('ours.txt', 'ahead\n');
    commitAll('ours');

    final repo = Repository.open(repoPath);
    final result = merge(repo, repo.resolve('side')!);
    repo.close();

    expect(result.outcome, MergeOutcome.alreadyUpToDate);
    expect(git(['status', '--porcelain']), isEmpty);
  });

  test('a file added on one side arrives', () {
    git(['branch', 'side']);
    git(['checkout', '-q', 'side']);
    write('new.txt', 'brand new\n');
    commitAll('theirs add a file');
    git(['checkout', '-q', 'main']);
    write('ours.txt', 'ours moved too\n');
    commitAll('ours');

    final repo = Repository.open(repoPath);
    final result = merge(repo, repo.resolve('side')!);
    repo.close();

    expect(result.outcome, MergeOutcome.merged);
    expect(File(p.join(repoPath, 'new.txt')).readAsStringSync(), 'brand new\n');
    expect(git(['status', '--porcelain']), isEmpty);
  });

  test('a file deleted on one side goes', () {
    git(['branch', 'side']);
    git(['checkout', '-q', 'side']);
    File(p.join(repoPath, 'theirs.txt')).deleteSync();
    commitAll('theirs delete a file');
    git(['checkout', '-q', 'main']);
    write('ours.txt', 'ours moved\n');
    commitAll('ours');

    final repo = Repository.open(repoPath);
    final result = merge(repo, repo.resolve('side')!);
    repo.close();

    expect(result.outcome, MergeOutcome.merged);
    expect(File(p.join(repoPath, 'theirs.txt')).existsSync(), isFalse);
    expect(git(['status', '--porcelain']), isEmpty);
  });

  test('deleted on one side and changed on the other needs a person', () {
    git(['branch', 'side']);
    File(p.join(repoPath, 'theirs.txt')).deleteSync();
    commitAll('ours delete it');

    git(['checkout', '-q', 'side']);
    write('theirs.txt', 'still here, and changed\n');
    commitAll('theirs change it');
    git(['checkout', '-q', 'main']);

    final repo = Repository.open(repoPath);
    final result = merge(repo, repo.resolve('side')!);
    repo.close();

    expect(result.outcome, MergeOutcome.conflicted);
    expect(result.conflicts, ['theirs.txt']);
  });

  test('the merge base is the one git reports', () {
    git(['branch', 'side']);
    write('ours.txt', 'ours moved\n');
    commitAll('ours');
    git(['checkout', '-q', 'side']);
    write('theirs.txt', 'theirs moved\n');
    commitAll('theirs');
    git(['checkout', '-q', 'main']);

    final repo = Repository.open(repoPath);
    final bases = mergeBases(
      repo,
      repo.resolve('main')!,
      repo.resolve('side')!,
    );
    repo.close();

    expect(bases, hasLength(1));
    expect(bases.single.hex, git(['merge-base', 'main', 'side']).trim());
  });
}
