/// Stopping a walk that nobody is waiting for any more.
///
/// The reads here are synchronous, so nothing can interrupt one from outside.
/// What a walk can do is ask, between units of work, whether to carry on —
/// and what these check is that it asks often enough to matter, stops where
/// it says it stops, and leaves the repository exactly as it found it.
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

void write(String relative, String contents) {
  final file = File(p.join(repoPath, relative.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// Cancels once it has been asked [after] times, which is how a test says
/// "stop in the middle" without depending on how fast anything is.
class _CancelAfter implements Cancellation {
  final int after;
  int asked = 0;

  _CancelAfter(this.after);

  @override
  bool get isCancelled => ++asked > after;
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_cancel');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
  });

  tearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Read-only objects under .git survive on Windows.
    }
  });

  void commits(int count) {
    for (var i = 0; i < count; i++) {
      write('a.txt', 'version $i\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'commit $i']);
    }
  }

  test('a history walk stops where it is told, having done that much work',
      () {
    commits(30);
    final repo = Repository.open(repoPath);

    // Read to the end, so the walk is known to be longer than where it stops.
    expect(repo.log().length, 30);

    final cancel = _CancelAfter(5);
    final seen = <Commit>[];
    expect(
      () {
        for (final commit in repo.log(cancel: cancel)) {
          seen.add(commit);
        }
      },
      throwsA(isA<CancelledException>()),
    );
    // Five commits came out, not thirty and not none: the walk did the work
    // asked of it and then stopped.
    expect(seen, hasLength(5));

    // And the repository is still usable afterwards — the walk stopped, it
    // did not break anything.
    expect(repo.log().length, 30);
    repo.close();
  });

  test('a status walk stops, and leaves the index exactly as it was', () {
    for (var i = 0; i < 20; i++) {
      write('file$i.txt', 'contents $i\n');
    }
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    for (var i = 0; i < 20; i++) {
      write('file$i.txt', 'changed $i\n');
    }

    final indexFile = File(p.join(repoPath, '.git', 'index'));
    final before = indexFile.readAsBytesSync();

    final repo = Repository.open(repoPath);
    expect(
      () => repo.status(cancel: _CancelAfter(3), trustStatCache: false),
      throwsA(isA<CancelledException>()),
    );

    // A cancelled read is still a read: nothing was written, and asking
    // again answers in full.
    expect(indexFile.readAsBytesSync(), before);
    expect(repo.status(trustStatCache: false).entries, hasLength(20));
    repo.close();
  });

  /// A file each of whose lines came from a different commit, so blame has
  /// to walk back through all of them rather than resolving at the tip.
  void layeredCommits(int count) {
    final lines = <String>[];
    for (var i = 0; i < count; i++) {
      lines.add('line from commit $i');
      write('a.txt', '${lines.join('\n')}\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'commit $i']);
    }
  }

  test('blame stops when it is asked to', () {
    layeredCommits(20);
    final repo = Repository.open(repoPath);
    expect(
      () => blame(repo, 'a.txt', cancel: _CancelAfter(2)),
      throwsA(isA<CancelledException>()),
    );
    expect(blame(repo, 'a.txt')!.lines, isNotEmpty);
    repo.close();
  });

  test("a file's history stops when it is asked to", () {
    layeredCommits(20);
    final repo = Repository.open(repoPath);
    expect(
      () => fileHistory(repo, 'a.txt', cancel: _CancelAfter(2)).toList(),
      throwsA(isA<CancelledException>()),
    );
    expect(fileHistory(repo, 'a.txt').toList(), hasLength(20));
    repo.close();
  });

  test('a cancellation nobody triggers costs nothing and changes nothing', () {
    commits(10);
    final repo = Repository.open(repoPath);
    final source = CancellationSource();
    expect(repo.log(cancel: source).length, 10);

    source.cancel();
    expect(() => repo.log(cancel: source).length,
        throwsA(isA<CancelledException>()));
    repo.close();
  });

  test('the exception says what stopped', () {
    commits(5);
    final repo = Repository.open(repoPath);
    try {
      repo.log(cancel: _CancelAfter(1)).toList();
      fail('the walk did not stop');
    } on CancelledException catch (stopped) {
      expect(stopped.doing, contains('history'));
      expect(stopped.toString(), contains('cancelled'));
    }
    repo.close();
  });
}
