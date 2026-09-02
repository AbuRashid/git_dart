/// Notes, checked against `git notes show`.
///
/// The tricky part is not the format but the fanout: git rewrites the notes
/// tree into a deeper shape as it grows, and nothing records which shape it is
/// in. A reader that assumes one depth works perfectly on a small repository
/// and finds nothing on a large one, so the fanout cases here are built by
/// hand rather than waiting for git to grow into them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

var _clock = 1700000000;

String git(List<String> arguments) {
  final when = '$_clock +0000';
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: {'GIT_AUTHOR_DATE': when, 'GIT_COMMITTER_DATE': when},
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// What git shows for a commit's note, or null where there is none.
String? gitNote(String revision, {String? ref}) {
  final result = Process.runSync(
    'git',
    ['notes', if (ref != null) ...['--ref', ref], 'show', revision],
    workingDirectory: repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return result.exitCode == 0 ? result.stdout as String : null;
}

String commit(String message) {
  File(p.join(repoPath, 'f.txt')).writeAsStringSync('$message\n');
  git(['add', '-A']);
  _clock += 60;
  git(['commit', '-q', '-m', message]);
  return git(['rev-parse', 'HEAD']).trim();
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_notes');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('a commit with no note has none', () {
    final head = commit('one');

    final repo = Repository.open(repoPath);
    expect(noteFor(repo, ObjectId.fromHex(head)), isNull);
    expect(allNotes(repo), isEmpty);
    expect(notesRefs(repo), isEmpty);
    repo.close();

    expect(gitNote('HEAD'), isNull);
  });

  test('a note is read back with the text git shows', () {
    final head = commit('one');
    git(['notes', 'add', '-m', 'reviewed by nobody']);

    final repo = Repository.open(repoPath);
    final note = noteFor(repo, ObjectId.fromHex(head))!;
    repo.close();

    expect(note.text, gitNote('HEAD'));
    expect(note.text.trim(), 'reviewed by nobody');
    expect(note.target.hex, head);
    expect(note.ref, 'refs/notes/commits');
  });

  test('a multi-line note keeps its lines', () {
    commit('one');
    git(['notes', 'add', '-m', 'first line', '-m', 'second para']);

    final repo = Repository.open(repoPath);
    final note = noteFor(repo, repo.headId!)!;
    repo.close();

    expect(note.text, gitNote('HEAD'));
    expect(note.text, contains('first line'));
    expect(note.text, contains('second para'));
  });

  test('notes on several commits are each found', () {
    final one = commit('one');
    final two = commit('two');
    final three = commit('three');

    git(['notes', 'add', '-m', 'note on one', one]);
    git(['notes', 'add', '-m', 'note on three', three]);

    final repo = Repository.open(repoPath);
    expect(noteFor(repo, ObjectId.fromHex(one))!.text.trim(), 'note on one');
    expect(noteFor(repo, ObjectId.fromHex(two)), isNull);
    expect(
      noteFor(repo, ObjectId.fromHex(three))!.text.trim(),
      'note on three',
    );

    final all = allNotes(repo);
    expect(all.keys.map((k) => k.hex).toSet(), {one, three});
    repo.close();
  });

  test('a note that was changed reads as the new text', () {
    commit('one');
    git(['notes', 'add', '-m', 'first thought']);
    git(['notes', 'add', '-f', '-m', 'second thought']);

    final repo = Repository.open(repoPath);
    expect(noteFor(repo, repo.headId!)!.text.trim(), 'second thought');
    repo.close();
    expect(gitNote('HEAD')!.trim(), 'second thought');
  });

  test('a note that was removed is gone', () {
    commit('one');
    git(['notes', 'add', '-m', 'temporary']);
    git(['notes', 'remove']);

    final repo = Repository.open(repoPath);
    expect(noteFor(repo, repo.headId!), isNull);
    expect(allNotes(repo), isEmpty);
    repo.close();
    expect(gitNote('HEAD'), isNull);
  });

  test('the commit itself is untouched by gaining a note', () {
    final before = commit('one');
    git(['notes', 'add', '-m', 'said afterwards']);
    final after = git(['rev-parse', 'HEAD']).trim();

    // The whole point: a note is not a change to the commit.
    expect(after, before);
  });

  group('several sets of notes', () {
    test('each ref is read separately', () {
      commit('one');
      git(['notes', '--ref', 'reviews', 'add', '-m', 'looks fine']);
      git(['notes', '--ref', 'builds', 'add', '-m', 'green']);

      final repo = Repository.open(repoPath);
      final head = repo.headId!;

      expect(
        noteFor(repo, head, ref: 'refs/notes/reviews')!.text.trim(),
        'looks fine',
      );
      expect(
        noteFor(repo, head, ref: 'refs/notes/builds')!.text.trim(),
        'green',
      );
      // The default set has nothing in it.
      expect(noteFor(repo, head), isNull);

      expect(notesRefs(repo), ['refs/notes/builds', 'refs/notes/reviews']);
      repo.close();

      expect(gitNote('HEAD', ref: 'reviews')!.trim(), 'looks fine');
      expect(gitNote('HEAD', ref: 'builds')!.trim(), 'green');
    });

    test('core.notesRef moves which set is the default', () {
      commit('one');
      git(['notes', '--ref', 'reviews', 'add', '-m', 'looks fine']);
      git(['config', 'core.notesRef', 'refs/notes/reviews']);

      final repo = Repository.open(repoPath);
      expect(defaultNotesRefOf(repo), 'refs/notes/reviews');
      expect(noteFor(repo, repo.headId!)!.text.trim(), 'looks fine');
      repo.close();

      // And git reads the same set without being told which.
      expect(gitNote('HEAD')!.trim(), 'looks fine');
    });
  });

  group('fanout', () {
    /// Builds a notes ref by hand with the paths split at [depth] bytes.
    ///
    /// git only fans a tree out once it is large enough to need it, so the
    /// deeper shapes cannot be produced by adding a handful of notes — they
    /// have to be written directly.
    void writeFannedNotes(Map<String, String> byCommit, {required int depth}) {
      for (final entry in byCommit.entries) {
        final hex = entry.key;
        final segments = <String>[];
        var at = 0;
        for (var i = 0; i < depth; i++) {
          segments.add(hex.substring(at, at + 2));
          at += 2;
        }
        segments.add(hex.substring(at));

        final path = p.joinAll([repoPath, 'notes-staging', ...segments]);
        Directory(p.dirname(path)).createSync(recursive: true);
        File(path).writeAsStringSync(entry.value);
      }

      // Built in a scratch index so the working tree is not disturbed.
      final indexFile = p.join(scratch.path, 'notes.index');
      Process.runSync(
        'git',
        ['add', '-A', 'notes-staging'],
        workingDirectory: repoPath,
        environment: {'GIT_INDEX_FILE': indexFile},
      );
      final tree = Process.runSync(
        'git',
        ['write-tree', '--prefix=notes-staging'],
        workingDirectory: repoPath,
        stdoutEncoding: utf8,
        environment: {'GIT_INDEX_FILE': indexFile},
      );
      final treeId = (tree.stdout as String).trim();

      final commitId = git([
        'commit-tree',
        treeId,
        '-m',
        'notes',
      ]).trim();
      git(['update-ref', 'refs/notes/commits', commitId]);

      Directory(p.join(repoPath, 'notes-staging')).deleteSync(recursive: true);
      File(indexFile).deleteSync();
    }

    test('a flat tree is read', () {
      final one = commit('one');
      writeFannedNotes({one: 'flat note\n'}, depth: 0);

      final repo = Repository.open(repoPath);
      expect(noteFor(repo, ObjectId.fromHex(one))!.text, 'flat note\n');
      expect(allNotes(repo), hasLength(1));
      repo.close();

      expect(gitNote(one), 'flat note\n');
    });

    test('a tree split once is read', () {
      final one = commit('one');
      writeFannedNotes({one: 'fanned once\n'}, depth: 1);

      final repo = Repository.open(repoPath);
      expect(noteFor(repo, ObjectId.fromHex(one))!.text, 'fanned once\n');
      expect(allNotes(repo).keys.single.hex, one);
      repo.close();

      expect(gitNote(one), 'fanned once\n');
    });

    test('a tree split twice is read', () {
      final one = commit('one');
      writeFannedNotes({one: 'fanned twice\n'}, depth: 2);

      final repo = Repository.open(repoPath);
      expect(noteFor(repo, ObjectId.fromHex(one))!.text, 'fanned twice\n');
      expect(allNotes(repo).keys.single.hex, one);
      repo.close();

      expect(gitNote(one), 'fanned twice\n');
    });

    test('depths mixed in one tree are all read', () {
      // Legal, and what a tree looks like mid-rewrite: git splits the
      // subtrees that have grown and leaves the rest alone.
      final one = commit('one');
      final two = commit('two');
      final three = commit('three');

      final notes = <String, String>{one: 'a\n'};
      writeFannedNotes(notes, depth: 0);
      // Layer the other two in at different depths on top of the first.
      final staged = <String, String>{two: 'b\n'};
      final third = <String, String>{three: 'c\n'};

      // Rebuild the whole ref with all three at their own depths.
      for (final entry in [
        (notes, 0),
        (staged, 1),
        (third, 2),
      ]) {
        for (final e in entry.$1.entries) {
          final hex = e.key;
          final segments = <String>[];
          var at = 0;
          for (var i = 0; i < entry.$2; i++) {
            segments.add(hex.substring(at, at + 2));
            at += 2;
          }
          segments.add(hex.substring(at));
          final path = p.joinAll([repoPath, 'notes-staging', ...segments]);
          Directory(p.dirname(path)).createSync(recursive: true);
          File(path).writeAsStringSync(e.value);
        }
      }

      final indexFile = p.join(scratch.path, 'mixed.index');
      Process.runSync(
        'git',
        ['add', '-A', 'notes-staging'],
        workingDirectory: repoPath,
        environment: {'GIT_INDEX_FILE': indexFile},
      );
      final tree = Process.runSync(
        'git',
        ['write-tree', '--prefix=notes-staging'],
        workingDirectory: repoPath,
        stdoutEncoding: utf8,
        environment: {'GIT_INDEX_FILE': indexFile},
      );
      final commitId =
          git(['commit-tree', (tree.stdout as String).trim(), '-m', 'mixed'])
              .trim();
      git(['update-ref', 'refs/notes/commits', commitId]);
      Directory(p.join(repoPath, 'notes-staging')).deleteSync(recursive: true);

      final repo = Repository.open(repoPath);
      expect(noteFor(repo, ObjectId.fromHex(one))!.text, 'a\n');
      expect(noteFor(repo, ObjectId.fromHex(two))!.text, 'b\n');
      expect(noteFor(repo, ObjectId.fromHex(three))!.text, 'c\n');
      expect(allNotes(repo), hasLength(3));
      repo.close();

      expect(gitNote(one), 'a\n');
      expect(gitNote(two), 'b\n');
      expect(gitNote(three), 'c\n');
    });

    test('a path that is not an object name is not a note', () {
      final one = commit('one');
      writeFannedNotes({one: 'real note\n'}, depth: 1);

      // A notes tree may carry other files; only full object names count.
      Directory(p.join(repoPath, 'extra')).createSync();
      final repo = Repository.open(repoPath);
      final all = allNotes(repo);
      expect(all.keys.single.hex, one);
      repo.close();
      Directory(p.join(repoPath, 'extra')).deleteSync();
    });
  });
}
