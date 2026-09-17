/// Merging across renames, checked against git.
///
/// Git records no renames; a merge infers them, base to each side, and then
/// merges a file's content wherever it went. Without that a file renamed on
/// one side and edited on the other reads as a deletion against an edit, and
/// git's `ort` strategy — which merges it cleanly — disagrees.
///
/// Every case builds the same history twice: one copy is merged by git, the
/// other by git_dart, and the index (all stages), the status and the files
/// git leaves without markers are compared. Git's own marker layout is not
/// compared: git_dart marks up whole files rather than hunks, as the rest of
/// the merge code does.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;
late String gitCopy;

String git(List<String> arguments, {String? cwd, bool check = true}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (check && result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

void write(String name, String contents) {
  File(p.join(repoPath, name)).writeAsStringSync(contents);
}

String edit(String name, String from, String to) {
  final file = File(p.join(repoPath, name));
  final text = file.readAsStringSync();
  expect(text, contains(from));
  final changed = text.replaceFirst(from, to);
  file.writeAsStringSync(changed);
  return changed;
}

void commitAll(String message) {
  git(['add', '-A']);
  git(['commit', '-q', '-m', message]);
}

void copyDirectory(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync()) {
    final target = p.join(to.path, p.basename(entity.path));
    if (entity is Directory) {
      copyDirectory(entity, Directory(target));
    } else if (entity is File) {
      entity.copySync(target);
    }
  }
}

const baseText = 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n';

/// Builds base, then `main` with [ours] applied and `side` with [theirs].
void history(void Function() ours, void Function() theirs) {
  write('a.txt', baseText);
  write('o.txt', 'other\n');
  commitAll('base');
  git(['branch', 'side']);

  ours();
  commitAll('ours');
  git(['checkout', '-q', 'side']);
  theirs();
  commitAll('theirs');
  git(['checkout', '-q', 'main']);

  // The copy git merges.
  copyDirectory(Directory(repoPath), Directory(gitCopy));
}

/// What a merge left behind: every index stage, and the status.
({String stages, String status}) stateOf(String path) => (
      stages: git(['ls-files', '-s'], cwd: path),
      status: git(['status', '--porcelain'], cwd: path),
    );

/// Runs both merges and checks they agree. Returns git_dart's result.
MergeResult mergeBoth({List<String> unmarked = const []}) {
  final repo = Repository.open(repoPath);
  final result = merge(repo, repo.resolve('side')!, message: 'merge\n');
  repo.close();

  final gitResult = Process.runSync(
    'git',
    ['merge', '-q', '--no-edit', 'side'],
    workingDirectory: gitCopy,
  );
  final gitClean = gitResult.exitCode == 0;

  expect(result.ok, gitClean,
      reason: 'git ${gitClean ? 'merged cleanly' : 'reported a conflict'}');

  if (gitClean) {
    // Two merge commits differ in their dates; their trees must not.
    expect(
      git(['rev-parse', 'HEAD^{tree}']),
      git(['rev-parse', 'HEAD^{tree}'], cwd: gitCopy),
    );
    expect(git(['status', '--porcelain']), isEmpty);
  }

  final ours = stateOf(repoPath);
  final theirs = stateOf(gitCopy);
  expect(ours.stages, theirs.stages);
  expect(ours.status, theirs.status);

  // The conflicted paths git_dart reported are the ones git left unmerged.
  final unmerged = git(['diff', '--name-only', '--diff-filter=U'], cwd: gitCopy)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .toSet();
  expect(result.conflicts.toSet(), unmerged);

  for (final name in unmarked) {
    final mine = File(p.join(repoPath, name));
    final gits = File(p.join(gitCopy, name));
    expect(mine.existsSync(), gits.existsSync(), reason: name);
    if (gits.existsSync()) {
      expect(mine.readAsStringSync(), gits.readAsStringSync(), reason: name);
    }
  }
  return result;
}

void gitMv(String from, String to) => git(['mv', from, to]);
void gitRm(String path) => git(['rm', '-q', path]);

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_merge_renames');
    repoPath = p.join(scratch.path, 'repo');
    gitCopy = p.join(scratch.path, 'git');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    git(['config', 'core.autocrlf', 'false']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('renamed by us, edited by them: the edit follows the file', () {
    history(
      () => gitMv('a.txt', 'b.txt'),
      () => edit('a.txt', 'l8', 'L8'),
    );
    final result = mergeBoth(unmarked: ['a.txt', 'b.txt']);
    expect(result.outcome, MergeOutcome.merged);
    expect(File(p.join(repoPath, 'b.txt')).readAsStringSync(),
        baseText.replaceFirst('l8', 'L8'));
    expect(File(p.join(repoPath, 'a.txt')).existsSync(), isFalse);
  });

  test('edited by us, renamed by them: the file moves with our edit', () {
    history(
      () => edit('a.txt', 'l8', 'L8'),
      () => gitMv('a.txt', 'b.txt'),
    );
    final result = mergeBoth(unmarked: ['a.txt', 'b.txt']);
    expect(result.outcome, MergeOutcome.merged);
    expect(File(p.join(repoPath, 'a.txt')).existsSync(), isFalse);
  });

  test('renamed and edited by them, edited elsewhere by us, merges by line',
      () {
    history(
      () => edit('a.txt', 'l1', 'L1'),
      () {
        gitMv('a.txt', 'b.txt');
        edit('b.txt', 'l8', 'L8');
      },
    );
    final result = mergeBoth(unmarked: ['a.txt', 'b.txt']);
    expect(result.outcome, MergeOutcome.merged);
  });

  test('renamed by us, edited on the same line by them, conflicts in place',
      () {
    history(
      () {
        gitMv('a.txt', 'b.txt');
        edit('b.txt', 'l8', 'OURS');
      },
      () => edit('a.txt', 'l8', 'THEIRS'),
    );
    final result = mergeBoth(unmarked: ['a.txt']);
    expect(result.conflicts, ['b.txt']);
  });

  test('renamed to the same name on both sides merges the content', () {
    history(
      () {
        gitMv('a.txt', 'b.txt');
        edit('b.txt', 'l1', 'L1');
      },
      () {
        gitMv('a.txt', 'b.txt');
        edit('b.txt', 'l8', 'L8');
      },
    );
    final result = mergeBoth(unmarked: ['a.txt', 'b.txt']);
    expect(result.outcome, MergeOutcome.merged);
  });

  test('renamed to different names is a conflict that keeps both', () {
    history(
      () {
        gitMv('a.txt', 'b.txt');
        edit('b.txt', 'l1', 'L1');
      },
      () {
        gitMv('a.txt', 'c.txt');
        edit('c.txt', 'l8', 'L8');
      },
    );
    final result = mergeBoth(unmarked: ['a.txt', 'b.txt', 'c.txt']);
    expect(result.conflicts.toSet(), {'a.txt', 'b.txt', 'c.txt'});
  });

  test('renamed to different names with clashing edits still keeps both', () {
    history(
      () {
        gitMv('a.txt', 'b.txt');
        edit('b.txt', 'l8', 'OURS');
      },
      () {
        gitMv('a.txt', 'c.txt');
        edit('c.txt', 'l8', 'THEIRS');
      },
    );
    // The stages hold a marked-up blob, and git's markup differs from ours,
    // so only the conflict's shape can be compared.
    final repo = Repository.open(repoPath);
    final result = merge(repo, repo.resolve('side')!);
    repo.close();
    expect(result.conflicts.toSet(), {'a.txt', 'b.txt', 'c.txt'});

    git(['merge', '-q', 'side'], cwd: gitCopy, check: false);
    String shape(String cwd) => git(['ls-files', '-s'], cwd: cwd)
        .split('\n')
        .map((line) => line.replaceFirst(RegExp(r' [0-9a-f]{40} '), ' '))
        .join('\n');
    expect(shape(repoPath), shape(gitCopy));
    expect(git(['status', '--porcelain']),
        git(['status', '--porcelain'], cwd: gitCopy));
    expect(File(p.join(repoPath, 'b.txt')).readAsStringSync(),
        contains('OURS'));
    expect(File(p.join(repoPath, 'c.txt')).readAsStringSync(),
        contains('THEIRS'));
  });

  test('renamed by us, deleted by them, is a conflict', () {
    history(
      () => gitMv('a.txt', 'b.txt'),
      () => gitRm('a.txt'),
    );
    final result = mergeBoth(unmarked: ['a.txt', 'b.txt']);
    expect(result.conflicts, ['b.txt']);
  });

  test('deleted by us, renamed and edited by them, is a conflict', () {
    history(
      () => gitRm('a.txt'),
      () {
        gitMv('a.txt', 'c.txt');
        edit('c.txt', 'l1', 'L1');
      },
    );
    final result = mergeBoth(unmarked: ['a.txt', 'c.txt']);
    expect(result.conflicts, ['c.txt']);
  });

  test('renamed by us onto a name they added is a conflict', () {
    history(
      () => gitMv('a.txt', 'b.txt'),
      () {
        write('b.txt', 'x\ny\n');
        edit('a.txt', 'l8', 'L8');
      },
    );
    final result = mergeBoth(unmarked: ['a.txt']);
    expect(result.conflicts, ['b.txt']);
  });

  test('renamed by them onto a name we added is a conflict', () {
    history(
      () => write('c.txt', 'x\ny\n'),
      () => gitMv('a.txt', 'c.txt'),
    );
    final result = mergeBoth(unmarked: ['a.txt']);
    expect(result.conflicts, ['c.txt']);
  });

  test('merge.renames=false merges as git does without renames', () {
    history(
      () => gitMv('a.txt', 'b.txt'),
      () => edit('a.txt', 'l8', 'L8'),
    );
    git(['config', 'merge.renames', 'false']);
    git(['config', 'merge.renames', 'false'], cwd: gitCopy);
    final result = mergeBoth(unmarked: ['a.txt', 'b.txt']);
    expect(result.conflicts, ['a.txt']);
  });
}
