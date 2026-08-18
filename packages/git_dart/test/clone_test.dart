/// Cloning: init, fetch and checkout in the arrangement that makes a copy.
///
/// The source is a real repository built by git itself, and what the clone
/// produces is checked against what git says about it — so agreement here is
/// agreement with git, not with this library's own idea of a clone.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String originPath;

String git(List<String> arguments, {String? cwd}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? originPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_clone');
    originPath = p.join(scratch.path, 'origin');
    Directory(originPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    File(p.join(originPath, 'a.txt')).writeAsStringSync('one\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'first']);
    git(['branch', 'side']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  String into(String name) => p.join(scratch.path, name);

  test('a clone brings the history and checks out the default branch', () async {
    final result = await clone(originPath, into('copy'));

    expect(result.branchName, 'main');
    expect(result.remoteWasEmpty, isFalse);
    expect(File(p.join(into('copy'), 'a.txt')).readAsStringSync(), 'one\n');

    final repo = Repository.open(into('copy'));
    addTearDown(repo.close);
    expect(repo.refs.currentBranch, 'refs/heads/main');
    expect(repo.headId, isNotNull);
    // The same commit, by name, as the source is on.
    expect(repo.headId!.hex, git(['rev-parse', 'HEAD']).trim());
  });

  test('the clone is a repository git itself accepts', () async {
    await clone(originPath, into('copy'));

    // git's own reading of what we wrote: the branch, its upstream, and that
    // the object store passes a full check.
    expect(git(['rev-parse', '--abbrev-ref', 'HEAD'], cwd: into('copy')).trim(),
        'main');
    expect(
      git(['config', 'branch.main.remote'], cwd: into('copy')).trim(),
      'origin',
    );
    expect(
      git(['config', 'remote.origin.url'], cwd: into('copy')).trim(),
      originPath,
    );
    git(['fsck', '--strict'], cwd: into('copy'));
    // Nothing staged or unstaged: the working tree matches what was checked
    // out, which is the thing a checkout is for.
    expect(git(['status', '--porcelain'], cwd: into('copy')).trim(), isEmpty);
  });

  test('every branch on the remote arrives as a tracking ref', () async {
    await clone(originPath, into('copy'));

    final repo = Repository.open(into('copy'));
    addTearDown(repo.close);
    expect(repo.refs.resolve('refs/remotes/origin/main'), isNotNull);
    expect(repo.refs.resolve('refs/remotes/origin/side'), isNotNull);
    // Only the checked-out branch is created locally, as git does.
    expect(repo.refs.resolve('refs/heads/side'), isNull);
  });

  test('a bare clone has the history and no working tree', () async {
    final result = await clone(originPath, into('bare.git'), bare: true);

    expect(result.bare, isTrue);
    expect(File(p.join(into('bare.git'), 'a.txt')).existsSync(), isFalse);
    expect(
      git(['rev-parse', '--is-bare-repository'], cwd: into('bare.git')).trim(),
      'true',
    );
  });

  test('cloning an empty remote leaves a repository with nothing in it',
      () async {
    final emptyPath = p.join(scratch.path, 'empty');
    Directory(emptyPath).createSync();
    git(['init', '-q', '-b', 'main'], cwd: emptyPath);

    final result = await clone(emptyPath, into('copy'));

    expect(result.remoteWasEmpty, isTrue);
    expect(result.branch, isNull);
    // Still a repository, and still on the branch a first commit would start.
    final repo = Repository.open(into('copy'));
    addTearDown(repo.close);
    expect(repo.headId, isNull);
    expect(repo.refs.currentBranch, 'refs/heads/main');
  });

  test('an existing empty directory is cloned into', () async {
    Directory(into('copy')).createSync();
    final result = await clone(originPath, into('copy'));
    expect(result.branchName, 'main');
  });

  test('a directory with anything in it is refused', () async {
    Directory(into('copy')).createSync();
    File(p.join(into('copy'), 'keep.txt')).writeAsStringSync('mine\n');

    await expectLater(
      clone(originPath, into('copy')),
      throwsA(isA<CloneDestinationException>()),
    );
    // Refused before anything was written, so what was there is untouched.
    expect(File(p.join(into('copy'), 'keep.txt')).readAsStringSync(), 'mine\n');
    expect(Directory(p.join(into('copy'), '.git')).existsSync(), isFalse);
  });

  test('a clone that fails leaves nothing behind', () async {
    await expectLater(
      clone(p.join(scratch.path, 'not-here'), into('copy')),
      throwsA(anything),
    );
    // Half a repository looks like a repository until it is opened, so the
    // failure removes what it made.
    expect(Directory(into('copy')).existsSync(), isFalse);
  });

  test('a directory the clone did not create is emptied, not removed',
      () async {
    Directory(into('copy')).createSync();

    await expectLater(
      clone(p.join(scratch.path, 'not-here'), into('copy')),
      throwsA(anything),
    );
    expect(Directory(into('copy')).existsSync(), isTrue);
    expect(Directory(into('copy')).listSync(), isEmpty);
  });
}
