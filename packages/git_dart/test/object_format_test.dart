/// Repositories whose objects are not named with SHA-1.
///
/// Git can be told to name objects with SHA-256, and such a repository looks
/// ordinary from the outside: it has a `.git` directory, refs, and a HEAD.
/// Every object name this library builds is twenty bytes wide, so opening one
/// and reading from it produces a complaint about the length of an id that is
/// perfectly good — a diagnostic that sends the reader looking in the wrong
/// place. It is refused by name instead, when it is opened.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;

String git(List<String> arguments, {required String cwd}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// A repository in [format], with one commit in it.
String repositoryIn(String name, String format) {
  final path = p.join(scratch.path, name);
  Directory(path).createSync(recursive: true);
  git(['init', '-q', '-b', 'main', '--object-format=$format'], cwd: path);
  git(['config', 'user.name', 'A'], cwd: path);
  git(['config', 'user.email', 'a@x'], cwd: path);
  File(p.join(path, 'a.txt')).writeAsStringSync('one\n');
  git(['add', '-A'], cwd: path);
  git(['commit', '-q', '-m', 'first'], cwd: path);
  return path;
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_format');
  });

  tearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Read-only objects under .git survive on Windows.
    }
  });

  test('a sha256 repository is refused when it is opened, by name', () {
    final path = repositoryIn('sha256', 'sha256');
    // git reads it perfectly well, which is the point: the repository is
    // valid and this library is the one that cannot follow it.
    expect(git(['rev-parse', 'HEAD'], cwd: path).trim(), hasLength(64));

    expect(
      () => Repository.open(path),
      throwsA(
        isA<UnsupportedObjectFormatException>()
            .having((e) => e.format, 'format', 'sha256')
            .having((e) => e.toString(), 'message', contains('sha256')),
      ),
    );

    // Discovery from a subdirectory refuses for the same reason rather than
    // reporting that there is no repository here.
    final inside = Directory(p.join(path, 'deep'))..createSync();
    expect(
      () => Repository.discover(inside.path),
      throwsA(isA<UnsupportedObjectFormatException>()),
    );
  });

  test('a sha1 repository opens as before', () {
    final path = repositoryIn('sha1', 'sha1');
    final repo = Repository.open(path);
    expect(repo.headId!.hex, git(['rev-parse', 'HEAD'], cwd: path).trim());
    expect(repo.status().isClean, isTrue);
    repo.close();
  });

  test('a repository that states no format at all opens', () {
    // `extensions.objectFormat` is absent in an ordinary repository, and an
    // absent value must not be read as an unknown one.
    final path = repositoryIn('plain', 'sha1');
    final config = File(p.join(path, '.git', 'config'));
    config.writeAsStringSync(
      config
          .readAsLinesSync()
          .where((line) => !line.contains('objectformat'))
          .join('\n'),
    );

    final repo = Repository.open(path);
    expect(repo.headId, isNotNull);
    repo.close();
  });
}
