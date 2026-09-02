/// `.mailmap`, checked against `git log --format=%aN <%aE>`.
///
/// git applies the mailmap by default wherever it shows an author, so the test
/// for "did we read it right" is simply whether the same repository reports the
/// same person twice — once through git and once through here.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

var _clock = 1700000000;

String git(List<String> arguments, {Map<String, String> environment = const {}}) {
  final when = '$_clock +0000';
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: {
      'GIT_AUTHOR_DATE': when,
      'GIT_COMMITTER_DATE': when,
      ...environment,
    },
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// A commit by a named person, so several identities can share a history.
void commitAs(String name, String email, String message) {
  File(p.join(repoPath, 'f.txt')).writeAsStringSync('$message\n');
  git(['add', '-A']);
  _clock += 60;
  git(
    ['commit', '-q', '-m', message],
    environment: {'GIT_AUTHOR_NAME': name, 'GIT_AUTHOR_EMAIL': email},
  );
}

void writeMailmap(String text) {
  File(p.join(repoPath, '.mailmap')).writeAsStringSync(text);
}

/// What git says every commit's author is, newest first.
List<String> gitAuthors() =>
    git(['log', '--format=%aN <%aE>']).trim().split('\n');

/// The same, through the mailmap here.
List<String> ourAuthors() {
  final repo = Repository.open(repoPath);
  final mailmap = repo.mailmap;
  final result = [
    for (final commit in repo.log())
      () {
        final author = mailmap.resolve(commit.author);
        return '${author.name} <${author.email}>';
      }(),
  ];
  repo.close();
  return result;
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_mailmap');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'Committer']);
    git(['config', 'user.email', 'c@x']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('with no mailmap the identities are shown as written', () {
    commitAs('Ada', 'ada@old.example', 'one');
    commitAs('Ada L', 'ada@new.example', 'two');

    final repo = Repository.open(repoPath);
    expect(repo.mailmap.isEmpty, isTrue);
    repo.close();

    expect(ourAuthors(), gitAuthors());
    expect(ourAuthors(), ['Ada L <ada@new.example>', 'Ada <ada@old.example>']);
  });

  test('two addresses are folded into one person', () {
    commitAs('Ada', 'ada@old.example', 'one');
    commitAs('Ada L', 'ada@new.example', 'two');
    writeMailmap('Ada Lovelace <ada@new.example> <ada@old.example>\n');

    expect(ourAuthors(), gitAuthors());
    expect(
      ourAuthors(),
      // The second rule form does not touch the address it is keyed on, so
      // only the older commit is rewritten.
      ['Ada L <ada@new.example>', 'Ada Lovelace <ada@new.example>'],
    );
  });

  test('a name alone corrects everyone using that address', () {
    commitAs('ada', 'ada@example.com', 'one');
    commitAs('Ada!!', 'ada@example.com', 'two');
    writeMailmap('Ada Lovelace <ada@example.com>\n');

    expect(ourAuthors(), gitAuthors());
    expect(
      ourAuthors(),
      ['Ada Lovelace <ada@example.com>', 'Ada Lovelace <ada@example.com>'],
    );
  });

  test('an address alone rewrites the address and keeps the name', () {
    commitAs('Ada', 'ada@old.example', 'one');
    writeMailmap('<ada@new.example> <ada@old.example>\n');

    expect(ourAuthors(), gitAuthors());
    expect(ourAuthors(), ['Ada <ada@new.example>']);
  });

  test('a commit name narrows the rule, telling a shared account apart', () {
    // The case the four-field form exists for: one address, two people.
    commitAs('Ada', 'shared@example.com', 'one');
    commitAs('Grace', 'shared@example.com', 'two');
    writeMailmap(
      'Ada Lovelace <ada@example.com> Ada <shared@example.com>\n'
      'Grace Hopper <grace@example.com> Grace <shared@example.com>\n',
    );

    expect(ourAuthors(), gitAuthors());
    expect(
      ourAuthors(),
      ['Grace Hopper <grace@example.com>', 'Ada Lovelace <ada@example.com>'],
    );
  });

  test('a rule naming the commit name beats the one that takes any', () {
    commitAs('Ada', 'shared@example.com', 'one');
    commitAs('Someone', 'shared@example.com', 'two');
    writeMailmap(
      'The Team <team@example.com> <shared@example.com>\n'
      'Ada Lovelace <ada@example.com> Ada <shared@example.com>\n',
    );

    expect(ourAuthors(), gitAuthors());
    expect(
      ourAuthors(),
      ['The Team <team@example.com>', 'Ada Lovelace <ada@example.com>'],
    );
  });

  test('matching ignores case, since addresses are not case sensitive', () {
    commitAs('ADA', 'Ada@Old.Example', 'one');
    writeMailmap('Ada Lovelace <ada@new.example> <ada@old.example>\n');

    expect(ourAuthors(), gitAuthors());
    expect(ourAuthors(), ['Ada Lovelace <ada@new.example>']);
  });

  test('comments and blank lines are ignored, bad lines skipped', () {
    commitAs('Ada', 'ada@old.example', 'one');
    writeMailmap(
      '# who is who\n'
      '\n'
      'this line has no address at all\n'
      'Ada Lovelace <ada@new.example> <ada@old.example>   # trailing note\n',
    );

    expect(ourAuthors(), gitAuthors());
    expect(ourAuthors(), ['Ada Lovelace <ada@new.example>']);
  });

  test('an identity nothing matches is returned untouched, timestamp and all',
      () {
    commitAs('Ada', 'ada@old.example', 'one');
    writeMailmap('Grace Hopper <grace@example.com> <grace@old.example>\n');

    final repo = Repository.open(repoPath);
    final original = repo.log().first.author;
    final resolved = repo.mailmap.resolve(original);
    repo.close();

    expect(resolved.name, original.name);
    expect(resolved.email, original.email);
    expect(resolved.seconds, original.seconds);
  });

  test('the mailmap corrects who, never when', () {
    commitAs('Ada', 'ada@old.example', 'one');
    writeMailmap('Ada Lovelace <ada@new.example> <ada@old.example>\n');

    final repo = Repository.open(repoPath);
    final original = repo.log().first.author;
    final resolved = repo.mailmap.resolve(original);
    repo.close();

    expect(resolved.name, 'Ada Lovelace');
    expect(resolved.seconds, original.seconds);
    expect(resolved.timezone, original.timezone);
  });

  test('blame shows the mailmapped name, as git blame does', () {
    commitAs('Ada', 'ada@old.example', 'one');
    writeMailmap('Ada Lovelace <ada@new.example> <ada@old.example>\n');

    final repo = Repository.open(repoPath);
    final result = blame(repo, 'f.txt')!;
    repo.close();

    expect(result.lines.single.author.name, 'Ada Lovelace');
    expect(result.lines.single.author.email, 'ada@new.example');

    // And git agrees, line for line.
    final porcelain = git(['blame', '--line-porcelain', 'f.txt']);
    expect(porcelain, contains('author Ada Lovelace'));
    expect(porcelain, contains('author-mail <ada@new.example>'));
  });

  test('mailmap.blob is used where there is no file to read', () {
    commitAs('Ada', 'ada@old.example', 'one');
    // Committed rather than left in the working tree, which is the only way a
    // bare repository can have a mailmap at all.
    writeMailmap('Ada Lovelace <ada@new.example> <ada@old.example>\n');
    git(['add', '.mailmap']);
    _clock += 60;
    git(['commit', '-q', '-m', 'add mailmap']);
    File(p.join(repoPath, '.mailmap')).deleteSync();
    git(['config', 'mailmap.blob', 'HEAD:.mailmap']);

    expect(ourAuthors(), gitAuthors());
    expect(ourAuthors().last, 'Ada Lovelace <ada@new.example>');
  });

  test('mailmap.file names a file outside the working tree', () {
    commitAs('Ada', 'ada@old.example', 'one');
    final elsewhere = p.join(scratch.path, 'shared.mailmap');
    File(elsewhere)
        .writeAsStringSync('Ada Lovelace <ada@new.example> <ada@old.example>\n');
    git(['config', 'mailmap.file', elsewhere]);

    expect(ourAuthors(), gitAuthors());
    expect(ourAuthors(), ['Ada Lovelace <ada@new.example>']);
  });
}
