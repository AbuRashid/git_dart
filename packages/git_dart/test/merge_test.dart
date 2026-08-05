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
