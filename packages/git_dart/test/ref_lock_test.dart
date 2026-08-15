/// Ref updates that are exclusive, not merely whole.
///
/// The rename dance makes each write all-or-nothing. It does not make each
/// write the only one: two writers that both rename over the same ref both
/// succeed, and the loser's commit is on no branch. The lock is what stops
/// that, and the compare-and-swap is what stops the slower version of the same
/// race — deciding what to write from a value read some time ago.
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

void main() {
  late Repository repo;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_lock');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    File(p.join(repoPath, 'a.txt')).writeAsStringSync('one\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);

    repo = Repository.open(repoPath);
  });

  tearDown(() {
    repo.close();
    scratch.deleteSync(recursive: true);
  });

  test('a held lock refuses a second writer', () {
    final lock = File(p.join(repoPath, '.git', 'refs', 'heads', 'main.lock'))
      ..createSync(recursive: true);

    expect(
      () => repo.refs.write('refs/heads/main', repo.headId!,
          reflogMessage: 'test'),
      throwsA(isA<RefLockedException>()),
    );

    // And the ref is untouched: refusing is the whole point.
    expect(repo.refs.resolve('refs/heads/main'), isNotNull);
    lock.deleteSync();

    // With the lock gone the same write goes through.
    repo.refs.write('refs/heads/main', repo.headId!, reflogMessage: 'test');
  });

  test('the lock is released after a write', () {
    repo.refs.write('refs/heads/main', repo.headId!, reflogMessage: 'test');
    expect(
      File(p.join(repoPath, '.git', 'refs', 'heads', 'main.lock')).existsSync(),
      isFalse,
    );
  });

  test('a compare-and-swap refuses when the ref moved underneath', () {
    final original = repo.headId!;

    // What a fetch does: read the ref, decide, and in between someone else
    // commits.
    File(p.join(repoPath, 'a.txt')).writeAsStringSync('two\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'meanwhile']);
    final moved = repo.refs.resolve('refs/heads/main')!;
    expect(moved, isNot(original));

    expect(
      () => repo.refs.compareAndSwap(
        'refs/heads/main',
        expected: original,
        to: original,
        reflogMessage: 'stale write',
      ),
      throwsA(isA<RefRaceException>()),
    );

    // The commit made in between survives, which is the point.
    expect(repo.refs.resolve('refs/heads/main'), moved);
  });

  test('a compare-and-swap succeeds when the ref is where it was', () {
    final at = repo.refs.resolve('refs/heads/main')!;
    repo.refs.compareAndSwap(
      'refs/heads/side',
      expected: null, // must not exist
      to: at,
      reflogMessage: 'branch: created',
    );
    expect(repo.refs.resolve('refs/heads/side'), at);

    // Creating it again fails: it exists now.
    expect(
      () => repo.refs.compareAndSwap('refs/heads/side',
          expected: null, to: at, reflogMessage: 'again'),
      throwsA(isA<RefRaceException>()),
    );
  });
}
