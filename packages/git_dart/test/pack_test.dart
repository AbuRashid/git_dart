/// Packfile reading against a pack git built with deltas in it.
///
/// `algorithms.where-people-stop`: most reimplementations stall at packs,
/// because a delta chain is the first part that cannot be checked by reading a
/// hex dump. The check used here is the one that cannot be fooled — every
/// object must hash to the name it was found under, so a delta applied wrongly
/// fails immediately and by name.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

void main() {
  setUpAll(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_pack');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    // Many revisions of a file large enough that git prefers a delta to a
    // fresh copy — which is the only way to get delta objects to read.
    final random = Random(20260805);
    final lines = List.generate(
      2000,
      (i) => 'line $i: ${random.nextInt(1 << 32)}',
    );

    for (var revision = 0; revision < 20; revision++) {
      // Change a few lines each time, so successive versions are similar.
      for (var i = 0; i < 25; i++) {
        lines[random.nextInt(lines.length)] = 'changed at $revision:$i';
      }
      File(p.join(repoPath, 'big.txt')).writeAsStringSync(lines.join('\n'));
      File(p.join(repoPath, 'revision.txt')).writeAsStringSync('$revision\n');
      git(['add', '.']);
      git(['commit', '-q', '-m', 'revision $revision']);
    }

    git(['gc', '-q']);
  });

  tearDownAll(() => scratch.deleteSync(recursive: true));

  test('git really did write deltas into this pack', () {
    final idx = Directory(p.join(repoPath, '.git', 'objects', 'pack'))
        .listSync()
        .firstWhere((f) => f.path.endsWith('.idx'));
    final verified = git(['verify-pack', '-v', idx.path]);

    final deltas = LineSplitter.split(verified)
        .where((line) => line.contains('delta'))
        .length;
    // If this ever reaches zero the test below still passes while checking
    // nothing, so the premise is asserted rather than assumed.
    expect(deltas, greaterThan(0), reason: 'no deltas in the pack to resolve');
  });

  test('every object in the pack hashes to the name it is stored under', () {
    final repo = Repository.open(repoPath);
    expect(repo.objects.packs, hasLength(1));

    var checked = 0;
    for (final id in repo.objects.listAll()) {
      final raw = repo.objects.readRaw(id)!;
      expect(hashObject(raw.kind, raw.content), id, reason: id.hex);
      checked += 1;
    }
    expect(checked, greaterThan(40));
    repo.close();
  });

  test('a delta-stored blob matches what git cat-file prints', () {
    final repo = Repository.open(repoPath);
    for (var revision = 0; revision < 20; revision += 7) {
      final rev = 'HEAD~${19 - revision}';
      final ours = repo.readFile('big.txt', revision: rev)!;
      final theirs = git(['cat-file', 'blob', '$rev:big.txt']);
      expect(utf8.decode(ours).length, theirs.length, reason: rev);
      expect(utf8.decode(ours), theirs, reason: rev);
    }
    repo.close();
  });

  test('the whole history walks without touching a loose object', () {
    final repo = Repository.open(repoPath);
    expect(repo.objects.loose.listAll(), isEmpty);

    final ours = repo.log().map((c) => c.summary).toList();
    expect(ours.first, 'revision 19');
    expect(ours.last, 'revision 0');
    expect(ours, hasLength(20));
    repo.close();
  });

  test('the index into the pack finds objects by name and refuses others', () {
    final repo = Repository.open(repoPath);
    final pack = repo.objects.packs.single;

    final head = repo.headId!;
    expect(pack.contains(head), isTrue);
    expect(pack.index.offsetOf(head), isNotNull);
    expect(pack.objectCount, pack.index.objectCount);

    // A name no object has: the fanout narrows the search to a range that
    // does not hold it, and the binary search must not fall off the end.
    expect(pack.contains(ObjectId.zero), isFalse);
    expect(
      pack.contains(ObjectId.fromHex('f' * 40)),
      isFalse,
    );
    repo.close();
  });
}
