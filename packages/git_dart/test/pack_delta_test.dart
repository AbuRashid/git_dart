/// Packs that store objects as differences, checked by git.
///
/// A delta in a pack is the one place where being *nearly* right is worse than
/// being wrong: an entry that points at the wrong base, or a chain the reader
/// walks differently from the writer, produces an object that inflates to
/// plausible bytes under the wrong name. `git verify-pack` checks every CRC
/// and `git fsck` re-hashes every object, so between them they catch exactly
/// that.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

String git(List<String> arguments, {String? cwd}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// A history where the same files grow steadily — the shape deltas exist for.
void buildHistory({int commits = 40, int files = 3}) {
  final lines = <int, List<String>>{
    for (var f = 0; f < files; f++) f: <String>[],
  };

  for (var commit = 0; commit < commits; commit++) {
    for (var f = 0; f < files; f++) {
      lines[f]!.add(
        'file $f line $commit with a reasonable amount of text on it so that '
        'the blob is worth delta compressing at all\n',
      );
      File(p.join(repoPath, 'file$f.txt')).writeAsStringSync(lines[f]!.join());
    }
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'commit $commit']);
  }
}

/// Everything reachable from HEAD, packed by us.
BuiltPack packEverything(Repository repo, {bool deltas = true}) {
  final walked = liveObjectsAndNames(repo);
  final writer = PackWriter();
  for (final id in walked.objects) {
    final raw = repo.objects.readRaw(id);
    if (raw == null) continue;
    writer.add(id, raw.kind, raw.content, name: walked.names[id]);
  }
  return writer.buildWithIndex(deltas: deltas);
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_packdelta');
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
      // A read-only object git wrote; not what is under test.
    }
  });

  test('git verify-pack accepts a pack with deltas in it', () {
    buildHistory();
    final repo = Repository.open(repoPath);
    final built = packEverything(repo);
    repo.close();

    expect(built.deltas, greaterThan(0),
        reason: 'this history should compress');

    final target = Directory(p.join(scratch.path, 'out'))..createSync();
    File(p.join(target.path, '${built.name}.pack'))
        .writeAsBytesSync(built.bytes);
    File(p.join(target.path, '${built.name}.idx'))
        .writeAsBytesSync(built.buildIndex());

    // verify-pack checks every CRC against the bytes in the pack and reports
    // the chain each delta sits at the end of.
    final verified = git(
      ['verify-pack', '-v', p.join(target.path, '${built.name}.idx')],
      cwd: target.path,
    );
    expect(verified, contains('chain length'),
        reason: 'git should see real delta chains');

    // Every object we said was in there, and nothing else.
    final listed = <String>{};
    for (final line in const LineSplitter().convert(verified)) {
      final match = RegExp(r'^([0-9a-f]{40}) ').firstMatch(line);
      if (match != null) listed.add(match.group(1)!);
    }
    expect(listed, built.objects.map((o) => o.id.hex).toSet());
  });

  test('a repository holding only our delta pack is sound', () {
    buildHistory();
    var repo = Repository.open(repoPath);
    final expected = repo.reachable([repo.headId!]);
    final built = packEverything(repo);
    repo.close();

    final bare = Repository.init(p.join(scratch.path, 'bare'), bare: true);
    bare.objects.writePack(
      packBytes: built.bytes,
      objects: built.objects,
      packChecksum: built.checksum,
    );

    // Every object comes back, and the name it comes back under is the hash
    // of what came out — so a delta resolved to the wrong bytes would show
    // here rather than later.
    for (final id in expected) {
      final raw = bare.objects.readRaw(id);
      expect(raw, isNotNull, reason: '$id did not come back');
      expect(hashObject(raw!.kind, raw.content), id);
    }
    bare.close();

    final barePath = p.join(scratch.path, 'bare');
    // fsck re-hashes everything, which is the check that matters.
    git(['fsck', '--no-progress', '--strict'], cwd: barePath);
  });

  test('deltas make the pack substantially smaller', () {
    buildHistory(commits: 60);
    final repo = Repository.open(repoPath);

    final whole = packEverything(repo, deltas: false);
    final delta = packEverything(repo, deltas: true);
    repo.close();

    expect(whole.deltas, 0);
    expect(delta.deltas, greaterThan(0));

    // The whole point of the exercise. A history of steadily growing files is
    // the friendly case, so this should be a large margin rather than a
    // marginal one.
    expect(delta.bytes.length, lessThan(whole.bytes.length ~/ 2),
        reason: 'delta pack ${delta.bytes.length} vs whole '
            '${whole.bytes.length}');
  });

  test('our pack is in the same range as git\'s own', () {
    buildHistory(commits: 60);
    final repo = Repository.open(repoPath);
    final built = packEverything(repo);
    repo.close();

    git(['repack', '-adq']);
    final theirs = Directory(p.join(repoPath, '.git', 'objects', 'pack'))
        .listSync()
        .firstWhere((e) => e.path.endsWith('.pack'));
    final theirSize = File(theirs.path).lengthSync();

    // Not a claim of parity: git picks bases more cleverly and packs the
    // objects it knows it needs. Within a small multiple means the heuristic
    // is working rather than accidentally producing whole objects.
    expect(built.bytes.length, lessThan(theirSize * 3),
        reason: 'ours ${built.bytes.length}, git\'s $theirSize');
  });

  test('the chain depth is bounded', () {
    buildHistory(commits: 60);
    final repo = Repository.open(repoPath);

    final shallow = packEverything(repo);
    expect(shallow.deepestChain, lessThanOrEqualTo(50));

    // Asked for a tighter cap, it obeys — and the pack is still readable,
    // which is the part worth checking.
    final walked = liveObjectsAndNames(repo);
    final writer = PackWriter();
    for (final id in walked.objects) {
      final raw = repo.objects.readRaw(id)!;
      writer.add(id, raw.kind, raw.content, name: walked.names[id]);
    }
    final capped = writer.buildWithIndex(maxDepth: 3);
    repo.close();

    expect(capped.deepestChain, lessThanOrEqualTo(3));

    final bare = Repository.init(p.join(scratch.path, 'capped'), bare: true);
    bare.objects.writePack(
      packBytes: capped.bytes,
      objects: capped.objects,
      packChecksum: capped.checksum,
    );
    for (final object in capped.objects) {
      final raw = bare.objects.readRaw(object.id)!;
      expect(hashObject(raw.kind, raw.content), object.id);
    }
    bare.close();
  });

  test('our own indexer agrees about a pack we deltified', () {
    buildHistory();
    final repo = Repository.open(repoPath);
    final built = packEverything(repo);
    repo.close();

    final path = p.join(scratch.path, 'indexed.pack');
    File(path).writeAsBytesSync(built.bytes);

    final indexed = PackIndexer(path).run();
    expect(indexed.count, built.objects.length);
    expect(indexed.checksum, built.checksum);

    final ours = {for (final o in built.objects) o.id.hex: o.offset};
    final read = {for (final o in indexed.objects) o.id.hex: o.offset};
    expect(read, ours);

    // And the CRCs agree, which they only can if the writer and the reader
    // draw the entry boundaries in the same places.
    final ourCrcs = {for (final o in built.objects) o.id.hex: o.crc32};
    final readCrcs = {for (final o in indexed.objects) o.id.hex: o.crc32};
    expect(readCrcs, ourCrcs);
  });

  test('a repack of a real repository shrinks it and git still reads it', () {
    buildHistory(commits: 50);

    final looseSize = _directorySize(p.join(repoPath, '.git', 'objects'));

    final repo = Repository.open(repoPath);
    final result = repack(repo);
    repo.close();

    expect(result.packed, greaterThan(0));
    final packedSize = _directorySize(p.join(repoPath, '.git', 'objects'));
    expect(packedSize, lessThan(looseSize));

    git(['fsck', '--no-progress', '--strict']);
    expect(git(['rev-list', '--count', 'HEAD']).trim(), '50');
    expect(
      git(['cat-file', 'blob', 'HEAD:file1.txt']).split('\n').length,
      51,
    );
  });

  test('a push sends a deltified pack git receive-pack accepts', () async {
    buildHistory(commits: 30);
    final bare = p.join(scratch.path, 'remote.git');
    git(['init', '-q', '--bare', bare], cwd: scratch.path);

    final repo = Repository.open(repoPath);
    repo.remotes.add('origin', bare);
    final result = await push(repo, repo.remotes.named('origin')!);
    repo.close();

    expect(result.ok, isTrue);
    expect(result.objectsSent, greaterThan(0));

    // The far side is git, and it validates everything it is given.
    git(['fsck', '--no-progress', '--strict'], cwd: bare);
    expect(git(['rev-list', '--count', 'main'], cwd: bare).trim(), '30');
  });
}

int _directorySize(String path) {
  final directory = Directory(path);
  if (!directory.existsSync()) return 0;
  var total = 0;
  for (final entry in directory.listSync(recursive: true)) {
    if (entry is File) total += entry.lengthSync();
  }
  return total;
}
