/// Reads a repository with git_dart and prints what it found.
///
/// A smoke test with a human-readable output, and the shape the Flutter
/// explorer will consume: open, list refs, walk the log, read a tree.
///
///   dart run example/inspect.dart <path to a repository>
library;

import 'dart:io';

import 'package:git_dart/git_dart.dart';

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    stderr.writeln('usage: dart run example/inspect.dart <repository>');
    exit(2);
  }

  final clock = Stopwatch()..start();
  final repo = Repository.open(arguments.first);

  print('git directory : ${repo.gitDirectory}');
  print('bare          : ${repo.isBare}');
  print('branch        : ${repo.refs.currentBranch ?? '(detached)'}');
  print('packs         : ${repo.objects.packs.length}');
  print('packed refs   : ${repo.refs.readPackedRefs().length}');
  print('branches      : ${repo.refs.branches.length}');
  print('tags          : ${repo.refs.tags.length}');

  final head = repo.headCommit;
  if (head == null) {
    print('head          : (no commits yet)');
    repo.close();
    return;
  }

  print('head          : ${head.id} "${head.summary}"');
  print('author        : ${head.author.name} <${head.author.email}> '
      '${head.author.local}');

  var walked = 0;
  Commit? oldest;
  for (final commit in repo.log(limit: 2000)) {
    walked += 1;
    oldest = commit;
  }
  print('walked        : $walked commits in ${clock.elapsedMilliseconds}ms');
  print('oldest seen   : ${oldest!.id} "${oldest.summary}"');

  final tree = repo.treeOf(head.id)!;
  print('root tree     : ${tree.entries.length} entries');
  for (final entry in tree.entries.take(8)) {
    print('  $entry');
  }

  // The check that cannot be fooled: every object reachable from the head
  // tree must hash to the name it was found under.
  var verified = 0;
  for (final id in repo.reachable([head.tree])) {
    final raw = repo.objects.readRaw(id);
    if (raw == null) continue;
    if (hashObject(raw.kind, raw.content) != id) {
      stderr.writeln('MISMATCH: $id does not hash to its own name');
      exit(1);
    }
    verified += 1;
  }
  print('verified      : $verified objects of the head tree');

  final index = repo.index;
  print('index         : ${index == null ? '(none)' : '${index.entries.length} '
      'entries, version ${index.version}, '
      'extensions ${index.extensions.keys.toList()}'}');
  print('elapsed       : ${clock.elapsedMilliseconds}ms');

  repo.close();
}
