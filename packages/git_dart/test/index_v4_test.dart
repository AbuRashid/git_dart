/// Index version 4, which spells each path against the one before it.
///
/// A path is stored as "drop this many bytes from the end of the previous
/// path, then these" — a variable-width count in git's own encoding, followed
/// by the rest, and no padding between entries. Git writes this whenever
/// `index.version` says 4 or `update-index --index-version 4` is run, and a
/// reader that cannot follow it cannot report status on an ordinary
/// repository.
///
/// Checked against git rather than against a fixture written here: the whole
/// risk is that a plausible reading of the format disagrees with the one that
/// produced the file.
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

String indexPath() => p.join(repoPath, '.git', 'index');

int indexVersion() {
  final bytes = File(indexPath()).readAsBytesSync();
  return (bytes[4] << 24) | (bytes[5] << 16) | (bytes[6] << 8) | bytes[7];
}

/// What git says the index holds: path, mode, id and stage, in its order.
List<String> gitStaged() => [
      for (final line in const LineSplitter().convert(
        git(['ls-files', '--stage']),
      ))
        if (line.trim().isNotEmpty) line,
    ];

List<String> oursStaged() {
  final index = GitIndex.open(indexPath())!;
  return [
    for (final entry in index.entries)
      '${entry.mode.toRadixString(8).padLeft(6, '0')} ${entry.id.hex} '
          '${entry.stage.index}\t${entry.path}',
  ];
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_index4');
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

  test('a converted index reads back exactly as git lists it', () {
    // Paths that share long prefixes are the case the format exists for, and
    // the case a naive reader gets wrong.
    write('lib/src/index/git_index.dart', 'one\n');
    write('lib/src/index/git_index_writer.dart', 'two\n');
    write('lib/src/objects/tree.dart', 'three\n');
    write('README.md', 'four\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);

    git(['update-index', '--index-version', '4']);
    expect(indexVersion(), 4, reason: 'git did not write a v4 index');

    expect(oursStaged(), gitStaged());
  });

  test('status works on a v4 index, and agrees with git', () {
    write('a.txt', 'one\n');
    write('deep/nested/b.txt', 'two\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['update-index', '--index-version', '4']);

    write('a.txt', 'changed\n');
    write('untracked.txt', 'new\n');

    final repo = Repository.open(repoPath);
    final status = repo.status();
    repo.close();

    expect(
      status.entries.where((e) => !e.isUntracked).map((e) => e.path),
      ['a.txt'],
    );
    expect(status.untracked.map((e) => e.path), ['untracked.txt']);
    expect(git(['status', '--porcelain']), contains('M a.txt'));
  });

  test('a path that only lengthens the previous one drops nothing', () {
    // strip == 0, which is the shortest varint and the easiest to misread as
    // "no prefix at all".
    write('a', 'one\n');
    write('ab', 'two\n');
    write('abc', 'three\n');
    git(['add', '-A']);
    git(['update-index', '--index-version', '4']);

    expect(oursStaged(), gitStaged());
    expect(
      GitIndex.open(indexPath())!.entries.map((e) => e.path),
      ['a', 'ab', 'abc'],
    );
  });

  test('a long shared prefix, past what one varint byte can count', () {
    // A strip count above 127 needs the second byte of git's encoding, where
    // the extra increment before each shift is easy to leave out.
    final deep = List.filled(20, 'a-directory-with-a-long-name').join('/');
    write('$deep/one.txt', 'one\n');
    write('$deep/two.txt', 'two\n');
    write('short.txt', 'three\n');
    git(['add', '-A']);
    git(['update-index', '--index-version', '4']);

    expect(oursStaged(), gitStaged());
  });

  test('conflict stages survive the conversion', () {
    write('a.txt', 'base\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'base']);
    git(['checkout', '-q', '-b', 'side']);
    write('a.txt', 'theirs\n');
    git(['commit', '-q', '-am', 'theirs']);
    git(['checkout', '-q', 'main']);
    write('a.txt', 'ours\n');
    git(['commit', '-q', '-am', 'ours']);
    // A conflicted merge, left unresolved.
    Process.runSync('git', ['merge', 'side'], workingDirectory: repoPath);
    git(['update-index', '--index-version', '4']);

    expect(oursStaged(), gitStaged());
    expect(GitIndex.open(indexPath())!.hasConflicts, isTrue);
  });

  test('writing back produces an index git reads, at a version it states',
      () {
    write('lib/a.txt', 'one\n');
    write('lib/b.txt', 'two\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['update-index', '--index-version', '4']);
    final before = gitStaged();

    // This library writes v2, or v3 where a flag needs it: reading v4 does
    // not commit it to writing v4, and the conversion is git's own downgrade
    // rather than a loss.
    final index = GitIndex.open(indexPath())!;
    index.writeTo(indexPath());

    expect(indexVersion(), 2);
    expect(gitStaged(), before);
    expect(git(['status', '--porcelain']), isEmpty);
  });
}
