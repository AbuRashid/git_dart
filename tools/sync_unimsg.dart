// Copies the canonical unimsg Dart implementation into packages/unimsg/, and
// the canonical specification into unimsg-v0.umsg at the repository root.
//
//   dart tools/sync_unimsg.dart           copy, reporting what changed
//   dart tools/sync_unimsg.dart --check   exit non-zero if anything is stale
//
// The copy is placed here by this script and never edited. A fork looks exactly
// like a dependency until somebody diffs it, and this repository has already
// paid for that twice: the vendored parser sat one fix behind upstream, and the
// specification beside it was sixty-nine lines behind the real one while four
// packages read it — one of them as a CONFORMANCE test, which therefore passed
// against a document the format had moved on from.
//
// Set UNIMSG_REPO if the canonical repository is not at ../unimsg.

import 'dart:io';

void main(List<String> args) {
  final check = args.contains('--check');
  final repo = Platform.environment['UNIMSG_REPO'] ?? '../unimsg';

  if (!Directory(repo).existsSync()) {
    stderr.writeln('the canonical repository is not at $repo');
    stderr.writeln('set UNIMSG_REPO to its location');
    exit(1);
  }

  // source path -> destination path, both relative to their own roots.
  final files = <String, String>{
    'implementations/dart/lib/unimsg.dart': 'packages/unimsg/lib/unimsg.dart',
    'implementations/dart/lib/src/parser.dart': 'packages/unimsg/lib/src/parser.dart',
    'implementations/dart/lib/src/cbor.dart': 'packages/unimsg/lib/src/cbor.dart',
    'implementations/dart/lib/src/format.dart': 'packages/unimsg/lib/src/format.dart',
    'implementations/dart/lib/src/model.dart': 'packages/unimsg/lib/src/model.dart',
    'implementations/dart/bin/unimsg.dart': 'packages/unimsg/bin/unimsg.dart',
    'spec/unimsg-v0.umsg': 'unimsg-v0.umsg',
  };

  final stale = <String>[];
  var copied = 0;

  for (final entry in files.entries) {
    final src = File('$repo/${entry.key}');
    if (!src.existsSync()) {
      stderr.writeln('missing upstream: ${entry.key}');
      exit(1);
    }
    final dst = File(entry.value);
    final want = src.readAsBytesSync();
    final have = dst.existsSync() ? dst.readAsBytesSync() : null;

    // Compared as bytes, so a line-ending change counts as a difference rather
    // than hiding under one.
    final same = have != null &&
        have.length == want.length &&
        List.generate(have.length, (i) => have[i] == want[i]).every((b) => b);

    if (same) continue;
    stale.add(entry.value);
    if (!check) {
      dst.parent.createSync(recursive: true);
      dst.writeAsBytesSync(want);
      copied++;
    }
  }

  if (check) {
    if (stale.isEmpty) {
      stdout.writeln('packages/unimsg and unimsg-v0.umsg are current '
          '(${files.length} files)');
      exit(0);
    }
    stderr.writeln('stale: ${stale.join(', ')}');
    stderr.writeln('run: dart tools/sync_unimsg.dart');
    exit(1);
  }

  if (copied == 0) {
    stdout.writeln('already current (${files.length} files)');
  } else {
    stdout.writeln('copied $copied of ${files.length} files: '
        '${stale.join(', ')}');
  }
}
