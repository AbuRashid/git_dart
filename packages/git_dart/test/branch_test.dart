/// Renaming and deleting branches, checked against git.
///
/// Three things make a rename more than writing one ref, and each has a test:
/// the branch may live in `packed-refs`, HEAD may be pointing at it, and
/// `branch.<name>.*` records what it tracks. Missing any leaves a repository
/// that looks renamed and behaves oddly afterwards.
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

List<String> branches({String? cwd}) => git(['branch', '--format=%(refname:short)'], cwd: cwd)
    .trim()
    .split('\n')
    .where((line) => line.isNotEmpty)
    .toList();

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_branch');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    File(p.join(repoPath, 'a.txt')).writeAsStringSync('one\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'first']);
    git(['branch', 'feature']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('renames a branch that is not checked out', () {
    final repo = Repository.open(repoPath);
    final before = repo.refs.resolve('refs/heads/feature');

    repo.renameBranch('feature', 'feature/renamed');
    repo.close();

    expect(branches(), ['feature/renamed', 'main']);
    expect(
      git(['rev-parse', 'refs/heads/feature/renamed']).trim(),
      before!.hex,
    );
    expect(git(['fsck', '--no-progress']), isNotNull);
  });

  test('renaming the checked-out branch takes HEAD with it', () {
    final repo = Repository.open(repoPath);
    repo.renameBranch('main', 'trunk');
    repo.close();

    // HEAD must follow, or the repository reads as being on an unborn branch.
    expect(git(['symbolic-ref', '--short', 'HEAD']).trim(), 'trunk');
    expect(branches(), ['feature', 'trunk']);
    expect(git(['status', '--porcelain']), isEmpty);
    expect(git(['rev-list', '--count', 'HEAD']).trim(), '1');
  });

  test('a branch that lives only in packed-refs is really removed', () {
    // `git pack-refs` moves the loose files into one file; deleting the loose
    // one then does nothing and the branch appears to come back.
    git(['pack-refs', '--all']);
    expect(
      File(p.join(repoPath, '.git', 'refs', 'heads', 'feature')).existsSync(),
      isFalse,
    );

    final repo = Repository.open(repoPath);
    repo.renameBranch('feature', 'moved');
    repo.close();

    expect(branches(), ['main', 'moved']);
    expect(git(['rev-parse', '--verify', '--quiet', 'refs/heads/moved']).trim(),
        isNotEmpty);
    expect(
      Process.runSync('git', ['rev-parse', '--verify', 'refs/heads/feature'],
              workingDirectory: repoPath)
          .exitCode,
      isNot(0),
    );
  });

  test('tracking configuration moves with the branch', () {
    git(['config', 'branch.feature.remote', 'origin']);
    git(['config', 'branch.feature.merge', 'refs/heads/feature']);

    final repo = Repository.open(repoPath);
    repo.renameBranch('feature', 'renamed');
    repo.close();

    expect(git(['config', '--get', 'branch.renamed.remote']).trim(), 'origin');
    expect(
      Process.runSync('git', ['config', '--get', 'branch.feature.remote'],
              workingDirectory: repoPath)
          .exitCode,
      isNot(0),
    );
  });

  test('renaming onto an existing name is refused unless forced', () {
    final repo = Repository.open(repoPath);
    expect(() => repo.renameBranch('feature', 'main'), throwsStateError);
    expect(branches(), ['feature', 'main']);

    repo.renameBranch('feature', 'main', force: true);
    repo.close();
    expect(branches(), ['main']);
  });

  test('a name git would refuse is refused here, with a reason', () {
    final repo = Repository.open(repoPath);
    for (final bad in const [
      '',
      '-leading-dash',
      'has space',
      'two..dots',
      'ends.lock',
      'star*',
      'colon:',
      'back\\slash',
      'trailing/',
    ]) {
      expect(
        () => repo.renameBranch('feature', bad),
        throwsArgumentError,
        reason: bad,
      );
      // And git agrees it is not a usable branch name.
      expect(
        Process.runSync('git', ['check-ref-format', '--branch', bad],
                workingDirectory: repoPath)
            .exitCode,
        isNot(0),
        reason: bad,
      );
    }
    expect(branches(), ['feature', 'main']);
    repo.close();
  });

  test('a name with a slash in the middle is allowed, as git allows it', () {
    final repo = Repository.open(repoPath);
    repo.renameBranch('feature', 'feature/one');
    repo.close();
    expect(branches(), contains('feature/one'));
  });

  test('deleting a branch leaves the checked-out one alone', () {
    final repo = Repository.open(repoPath);
    expect(() => repo.deleteBranch('main'), throwsStateError);

    repo.deleteBranch('feature');
    repo.close();

    expect(branches(), ['main']);
    expect(git(['fsck', '--no-progress']), isNotNull);
  });
}
