/// Staged renames, as status reports them.
///
/// Git records no such thing as a rename: a move is an addition and a
/// deletion, and both git and this library infer the pairing afterwards. What
/// this checks is that status infers it where git does, keeps both names, and
/// leaves everything else alone — a reader following a file through a move is
/// exactly who is served by getting this right, and exactly who is lost when
/// it is wrong.
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

/// What git reports, with renames asked for as status asks for them.
List<String> gitStatus() => [
      for (final line in const LineSplitter().convert(
        git(['status', '--porcelain=v1', '--find-renames']),
      ))
        if (line.trim().isNotEmpty) line,
    ];

/// Ours in the same shape: two letters, a space, and the path or pair.
List<String> ourStatus({bool detectRenames = true}) {
  final repo = Repository.open(repoPath);
  final status = repo.status(
    trustStatCache: false,
    detectRenames: detectRenames,
  );
  repo.close();
  return [
    for (final entry in status.entries)
      '${entry.code} ${entry.oldPath == null ? entry.path : '${entry.oldPath} -> ${entry.path}'}',
    // Untracked files are entries too, carrying git's own `??`.
  ]..sort();
}

/// Several lines of something, so a rename with an edit stays similar enough
/// to pair.
String lines(String marker) =>
    List.generate(40, (i) => 'line $i of $marker').join('\n') + '\n';

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_rename');
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

  test('a staged move is one rename, with both names', () {
    write('old.txt', lines('content'));
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['mv', 'old.txt', 'new.txt']);

    expect(gitStatus(), ['R  old.txt -> new.txt']);
    expect(ourStatus(), ['R  old.txt -> new.txt']);

    final repo = Repository.open(repoPath);
    final entry = repo.status(trustStatCache: false).entries.single;
    repo.close();
    expect(entry.path, 'new.txt');
    expect(entry.oldPath, 'old.txt');
    expect(entry.staged, ChangeKind.renamed);
    expect(entry.unstaged, isNull);
  });

  test('reading status writes nothing', () {
    write('old.txt', lines('content'));
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['mv', 'old.txt', 'new.txt']);

    final indexFile = File(p.join(repoPath, '.git', 'index'));
    final before = indexFile.readAsBytesSync();
    ourStatus();
    expect(indexFile.readAsBytesSync(), before);
  });

  test('a move with an edit since is a rename and an unstaged change', () {
    write('old.txt', lines('content'));
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['mv', 'old.txt', 'new.txt']);
    // Changed after the move was staged: the rename stands, and the edit is
    // the other half of the same row.
    write('new.txt', '${lines('content')}one more line\n');

    expect(gitStatus(), ['RM old.txt -> new.txt']);
    expect(ourStatus(), ['RM old.txt -> new.txt']);
  });

  test('a move that also rewrote the file is paired by similarity', () {
    write('old.txt', lines('content'));
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['mv', 'old.txt', 'new.txt']);
    write('new.txt', '${lines('content')}and a tail\n');
    git(['add', '-A']);

    expect(gitStatus(), ['R  old.txt -> new.txt']);
    expect(ourStatus(), ['R  old.txt -> new.txt']);
  });

  test('a whole directory moved is each file renamed', () {
    write('src/one.txt', lines('one'));
    write('src/two.txt', lines('two'));
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['mv', 'src', 'lib']);

    expect(gitStatus(), [
      'R  src/one.txt -> lib/one.txt',
      'R  src/two.txt -> lib/two.txt',
    ]);
    expect(ourStatus(), [
      'R  src/one.txt -> lib/one.txt',
      'R  src/two.txt -> lib/two.txt',
    ]);
  });

  test('a new file taking the old name is not the same file moved', () {
    write('old.txt', lines('original'));
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['mv', 'old.txt', 'new.txt']);
    // Something unrelated now occupies the name that was vacated.
    write('old.txt', lines('something else entirely'));
    git(['add', '-A']);

    expect(ourStatus(), gitStatus());
  });

  test('two unrelated files added and deleted are not called a move', () {
    write('kept.txt', lines('kept'));
    write('gone.txt', lines('gone'));
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['rm', '-q', 'gone.txt']);
    write('fresh.txt', lines('nothing like the other one'));
    git(['add', '-A']);

    expect(ourStatus(), gitStatus());
  });

  test('detection can be turned off, and then it is two changes', () {
    write('old.txt', lines('content'));
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['mv', 'old.txt', 'new.txt']);

    expect(
      ourStatus(detectRenames: false),
      ['A  new.txt', 'D  old.txt'],
    );
    // Which is what git reports when asked the same way.
    expect(
      const LineSplitter()
          .convert(git(['status', '--porcelain=v1', '--no-renames']))
          .where((line) => line.trim().isNotEmpty)
          .toList()
        ..sort(),
      ['A  new.txt', 'D  old.txt'],
    );
  });

  test('an unstaged move is a deletion and an untracked file, as git has it',
      () {
    write('old.txt', lines('content'));
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    // Moved on disk without telling git: the new name is not in the index,
    // so there is nothing to pair it with.
    File(p.join(repoPath, 'old.txt'))
        .renameSync(p.join(repoPath, 'new.txt'));

    expect(ourStatus(), gitStatus());
  });
}
