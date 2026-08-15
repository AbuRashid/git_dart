/// Indexing a pack from disk, without holding it in memory.
///
/// The packs here are git's own, built by `git repack -ad`, so they contain
/// real delta chains — both kinds — rather than the whole objects our own
/// writer produces. That matters: an indexer that only ever saw undeltified
/// packs would pass every test and fail on the first thing it fetched.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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

/// The `.pack` git wrote, after packing everything into one.
String packEverything() {
  git(['repack', '-adq']);
  final directory = Directory(p.join(repoPath, '.git', 'objects', 'pack'));
  return directory
      .listSync()
      .map((e) => e.path)
      .firstWhere((path) => path.endsWith('.pack'));
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_indexer');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    // A file that grows a line at a time over many commits is what git
    // delta-compresses hardest, which is the point.
    final lines = <String>[];
    for (var commit = 0; commit < 30; commit++) {
      lines.add('line $commit with enough text on it to be worth a delta\n');
      File(p.join(repoPath, 'grows.txt')).writeAsStringSync(lines.join());
      File(p.join(repoPath, 'also-$commit.txt'))
          .writeAsStringSync('side file $commit\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'commit $commit']);
    }
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('agrees with git verify-pack about every object', () {
    final packPath = packEverything();
    final indexPath = '${p.withoutExtension(packPath)}.idx';

    // What git says is in there, from its own index.
    final expected = <String, int>{};
    for (final line
        in const LineSplitter().convert(git(['verify-pack', '-v', indexPath]))) {
      final match =
          RegExp(r'^([0-9a-f]{40}) (\w+)\s+\d+ \d+ (\d+)').firstMatch(line);
      if (match != null) {
        expected[match.group(1)!] = int.parse(match.group(3)!);
      }
    }
    expect(expected, isNotEmpty);

    final result = PackIndexer(packPath).run();
    expect(result.count, expected.length);

    // Same names, at the same offsets.
    final ours = {for (final o in result.objects) o.id.hex: o.offset};
    expect(ours, expected);
  });

  test('the index we build from it is one git accepts', () {
    final packPath = packEverything();
    final result = PackIndexer(packPath).run();

    // Beside git's pack rather than over it: git writes a `.idx` read-only,
    // and the point is that our index describes the same pack, not that it
    // can overwrite one.
    final target = Directory(p.join(scratch.path, 'ours'))..createSync();
    final name = p.basenameWithoutExtension(packPath);
    File(p.join(target.path, '$name.pack'))
        .writeAsBytesSync(File(packPath).readAsBytesSync());
    final indexPath = p.join(target.path, '$name.idx');
    File(indexPath).writeAsBytesSync(PackIndexWriter.build(
      objects: result.objects,
      packChecksum: result.checksum,
    ));

    // verify-pack checks every CRC against the bytes in the pack, so this is
    // where a wrong entry boundary would show.
    final verified = git(['verify-pack', '-v', indexPath], cwd: target.path);
    expect(verified, contains('chain length'),
        reason: 'the pack should hold real delta chains');
    git(['fsck', '--no-progress']);
    expect(git(['rev-list', '--count', 'HEAD']).trim(), '30');
  });

  test('a small cache forces re-inflation and changes nothing', () {
    // With room for almost nothing, every delta base has to be rebuilt from
    // its recorded position. The answer must be identical — the cache is a
    // speed decision and never a correctness one.
    final packPath = packEverything();

    final generous = PackIndexer(packPath).run();
    final starved = PackIndexer(packPath, cacheBytes: 1024).run();

    expect(starved.count, generous.count);
    expect(starved.checksum, generous.checksum);
    expect(
      {for (final o in starved.objects) o.id.hex: o.crc32},
      {for (final o in generous.objects) o.id.hex: o.crc32},
    );
  });

  test('an object that does not compress is still bounded correctly', () {
    // Incompressible content comes out of zlib slightly larger than it went
    // in, so a read window sized to the uncompressed length falls short. The
    // failure would be an entry boundary one object early and every offset
    // after it wrong.
    final random = Random(20260815);
    for (final size in [1, 3, 1 << 16, (1 << 20) + 7]) {
      final bytes = Uint8List.fromList(
        List.generate(size, (_) => random.nextInt(256)),
      );
      File(p.join(repoPath, 'noise-$size.bin')).writeAsBytesSync(bytes);
    }
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'incompressible']);

    final packPath = packEverything();
    final result = PackIndexer(packPath).run();

    final expected = <String>{};
    for (final line in const LineSplitter()
        .convert(git(['verify-pack', '-v', '${p.withoutExtension(packPath)}.idx']))) {
      final match = RegExp(r'^([0-9a-f]{40}) ').firstMatch(line);
      if (match != null) expected.add(match.group(1)!);
    }
    expect(result.objects.map((o) => o.id.hex).toSet(), expected);
  });

  test('a corrupt pack is refused rather than half-read', () {
    final packPath = packEverything();
    final bytes = File(packPath).readAsBytesSync();
    // Flip a byte in the middle of the data. The trailing hash covers it.
    bytes[bytes.length ~/ 2] ^= 0xff;

    final corrupt = p.join(scratch.path, 'corrupt.pack');
    File(corrupt).writeAsBytesSync(bytes);

    expect(() => PackIndexer(corrupt).run(), throwsA(isA<FormatException>()));
  });

  test('a pack we index round-trips through our own reader', () {
    final packPath = packEverything();
    final result = PackIndexer(packPath).run();

    final target = Directory(p.join(scratch.path, 'store'))..createSync();
    final name = PackIndexWriter.packName(result.objects.map((o) => o.id));
    File(p.join(target.path, '$name.pack'))
        .writeAsBytesSync(File(packPath).readAsBytesSync());
    File(p.join(target.path, '$name.idx')).writeAsBytesSync(
      PackIndexWriter.build(
        objects: result.objects,
        packChecksum: result.checksum,
      ),
    );

    final pack = PackFile.open(p.join(target.path, '$name.pack'));
    for (final object in result.objects) {
      final read = pack.read(object.id);
      expect(read, isNotNull, reason: '${object.id} did not come back');
      // The name is the hash of what came out, so this checks the delta
      // chain resolved to the right bytes and not merely to some bytes.
      expect(hashObject(read!.kind, read.content), object.id);
    }
    pack.close();
  });
}
