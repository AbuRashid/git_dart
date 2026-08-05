/// Compares this library's status with `git status --porcelain` on a real
/// repository, and prints where they disagree.
///
///   dart run example/compare_status.dart <repository> [more…]
///
/// Written as a throwaway and kept, because it found two defects a test suite
/// built on scratch repositories did not: a `.git` directory holding no
/// repository was being opened, and the user's global excludes file was not
/// being read. Both only appear against a machine someone actually works on.
library;

import 'dart:io';

import 'package:git_dart/git_dart.dart';

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    stderr.writeln('usage: dart run example/compare_status.dart <repository>');
    exit(2);
  }

  var disagreements = 0;

  for (final path in arguments) {
    print('=== $path');

    final found = Repository.discover(path);
    final theirs = Process.runSync(
      'git',
      ['status', '--porcelain'],
      workingDirectory: path,
    );

    if (found == null) {
      // Disagreeing about whether this is a repository at all counts too.
      print(theirs.exitCode == 0
          ? '  we found no repository; git did'
          : '  neither of us finds a repository here');
      if (theirs.exitCode == 0) disagreements += 1;
      continue;
    }

    final ours = found.status().entries
        .map((entry) => '${entry.code} ${entry.path}')
        .toSet();
    final gitLines = theirs.stdout
        .toString()
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.isNotEmpty)
        .toSet();

    final onlyOurs = ours.difference(gitLines);
    final onlyGit = gitLines.difference(ours);
    disagreements += onlyOurs.length + onlyGit.length;

    print('  ours ${ours.length}, git ${gitLines.length}');
    for (final line in onlyOurs.take(10)) {
      print('  only ours: $line');
    }
    for (final line in onlyGit.take(10)) {
      print('  only git : $line');
    }

    found.close();
  }

  print(disagreements == 0
      ? 'agreed everywhere'
      : '$disagreements disagreements');
  exit(disagreements == 0 ? 0 : 1);
}
