/// A tour of git_dart: a repository made, changed, branched, merged, read back
/// and carried somewhere else — all in Dart, with no `git` binary involved.
///
///   dart run example/example.dart
///
/// Everything happens in a temporary directory that is removed at the end.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;

void main() {
  final scratch = Directory.systemTemp.createTempSync('git_dart_example');
  try {
    tour(scratch.path);
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

void tour(String root) {
  final path = p.join(root, 'project');

  // ---- create a repository and commit to it ------------------------------
  section('init and commit');
  final repo = Repository.init(path);

  write(path, 'README.md', '# Project\n\nA small example.\n');
  write(path, 'lib/greet.dart', "String greet() => 'hello';\n");
  repo.stage('README.md');
  repo.stage('lib/greet.dart');
  final first = repo.commitIndex(message: 'Start the project', author: me());
  print('committed ${short(first)} on ${repo.refs.currentBranch}');

  // ---- status: what changed since the last commit ------------------------
  section('status');
  write(path, 'README.md', '# Project\n\nA small example, now with a tour.\n');
  write(path, 'notes.txt', 'not tracked yet\n');
  for (final entry in repo.status().entries) {
    print('${entry.code} ${entry.path}');
  }
  repo.stage('README.md');
  final second = repo.commitIndex(message: 'Describe the tour', author: me());
  print('committed ${short(second)}');

  // ---- branch, and diverge on both sides ---------------------------------
  section('branches');
  repo.createBranch('shout');
  repo.checkout('shout');
  write(path, 'lib/greet.dart', "String greet() => 'HELLO';\n");
  repo.stage('lib/greet.dart');
  repo.commitIndex(message: 'Greet loudly', author: me());

  repo.checkout('main');
  write(path, 'lib/farewell.dart', "String farewell() => 'bye';\n");
  repo.stage('lib/farewell.dart');
  repo.commitIndex(message: 'Say goodbye too', author: me());
  print('branches: ${repo.refs.branches.map((b) => b.shortName).join(', ')}');

  // ---- merge: the two sides touched different files ----------------------
  section('merge');
  final merged = merge(repo, repo.resolve('shout')!);
  print('outcome: ${merged.outcome}, conflicts: ${merged.conflicts.length}');
  print('greet.dart now reads: ${read(path, 'lib/greet.dart').trim()}');

  // ---- tag the result ----------------------------------------------------
  repo.createTag('v1.0', message: 'The first release', tagger: me());

  // ---- history -----------------------------------------------------------
  section('log');
  for (final commit in repo.log()) {
    final parents = commit.parents.length > 1 ? ' (merge)' : '';
    print('${short(commit.id)} ${commit.summary}$parents');
  }

  // ---- what a commit changed, as a tree diff and a line diff -------------
  section('diff of "Describe the tour"');
  for (final change in repo.changesIn(second)) {
    print('${change.kind.name} ${change.path}');
    final text = repo.diffBlobs(change.oldId, change.newId);
    for (final hunk in text.hunks) {
      print(hunk.header);
      hunk.lines.forEach(print);
    }
  }

  // ---- blame: which commit wrote each line -------------------------------
  section('blame README.md');
  final blamed = blame(repo, 'README.md')!;
  for (final line in blamed.lines) {
    print('${short(line.commit)} ${line.number}: ${line.text}');
  }

  // ---- read a file at an older revision ----------------------------------
  section('README.md as first committed');
  stdout.write(utf8.decode(repo.readFile('README.md', revision: short(first))!));

  // ---- carry the whole history elsewhere in one file ---------------------
  section('bundle and archive');
  final bundle = writeBundle(repo, includeHead: true);
  final copy = Repository.init(p.join(root, 'copy'));
  final received = unbundle(copy, bundle, writeRefs: true);
  print('bundle: ${bundle.length} bytes, ${received.objects} objects, '
      '${received.written.length} refs');
  print('the copy has ${copy.log(start: copy.resolve('v1.0')).length} commits '
      'reachable from v1.0');

  final zip = writeArchive(repo, format: ArchiveFormat.zip, prefix: 'project/');
  print('zip of HEAD: ${zip.length} bytes');

  copy.close();
  repo.close();
}

/// The author of every commit here, stamped with the current time.
Identity me() => Identity(
      name: 'Example Author',
      email: 'author@example.com',
      seconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      timezone: '+0000',
    );

void write(String repository, String name, String contents) {
  File(p.join(repository, name))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

String read(String repository, String name) =>
    File(p.join(repository, name)).readAsStringSync();

String short(ObjectId id) => id.hex.substring(0, 7);

void section(String title) => print('\n== $title');
