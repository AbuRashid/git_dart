/// Writing a packfile index, checked by git.
///
/// A pack records where each object's data begins and not where it ends, so a
/// pack without an index can only be read front to back. Building one is the
/// receiver's job, and `git verify-pack` is the only opinion about it that
/// matters: it checks the fanout, the ordering, every CRC and both trailing
/// hashes, which is more than a test of our own would think to.
library;

import 'dart:convert';
import 'dart:io';
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

void main() {
  late Repository repo;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_idx');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    // Enough objects, and enough variety of first byte, that the fanout table
    // has something to say.
    for (var i = 0; i < 40; i++) {
      File(p.join(repoPath, 'f$i.txt')).writeAsStringSync('content $i\n');
    }
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);

    repo = Repository.open(repoPath);
  });

  tearDown(() {
    repo.close();
    scratch.deleteSync(recursive: true);
  });

  /// Every object in the repository, packed.
  BuiltPack packEverything() {
    final writer = PackWriter();
    for (final id in repo.reachable([repo.headId!])) {
      final raw = repo.objects.readRaw(id)!;
      writer.add(id, raw.kind, raw.content);
    }
    return writer.buildWithIndex();
  }

  test('git verify-pack accepts the index we write', () {
    final built = packEverything();
    expect(built.objects.length, greaterThan(40));

    final target = Directory(p.join(scratch.path, 'out'))..createSync();
    File(p.join(target.path, '${built.name}.pack'))
        .writeAsBytesSync(built.bytes);
    File(p.join(target.path, '${built.name}.idx'))
        .writeAsBytesSync(built.buildIndex());

    // git checks the fanout, the sort order, every CRC and both checksums.
    final verified = git(
      ['verify-pack', '-v', p.join(target.path, '${built.name}.idx')],
      cwd: target.path,
    );
    expect(verified, contains('non delta'));

    // And every object it lists is one we put in.
    final listed = <String>{};
    for (final line in const LineSplitter().convert(verified)) {
      final match = RegExp(r'^([0-9a-f]{40}) ').firstMatch(line);
      if (match != null) listed.add(match.group(1)!);
    }
    expect(listed, built.objects.map((o) => o.id.hex).toSet());
  });

  test('a pack we store is read back by name, with no loose copy', () {
    final built = packEverything();
    final ids = built.objects.map((o) => o.id).toList();

    // A fresh repository with nothing in it but this pack.
    final bare = Repository.init(p.join(scratch.path, 'bare'), bare: true);
    bare.objects.writePack(
      packBytes: built.bytes,
      objects: built.objects,
      packChecksum: built.checksum,
    );

    // Readable straight away, without reopening: a fetch that had to reopen
    // the store before it could use what it just received would be a trap.
    for (final id in ids) {
      expect(bare.objects.contains(id), isTrue, reason: '$id is missing');
      final raw = bare.objects.readRaw(id);
      expect(raw, isNotNull);
      expect(hashObject(raw!.kind, raw.content), id);
    }

    // Nothing was inflated into a loose file.
    expect(bare.objects.loose.listAll(), isEmpty);
    bare.close();

    // git agrees the repository is sound and holds what we say it does.
    final barePath = p.join(scratch.path, 'bare');
    git(['fsck', '--no-progress'], cwd: barePath);
    expect(
      git(['cat-file', '-t', ids.first.hex], cwd: barePath).trim(),
      isNotEmpty,
    );
  });

  test('storing the same objects twice does not write a second pack', () {
    final built = packEverything();
    final bare = Repository.init(p.join(scratch.path, 'bare2'), bare: true);

    final first = bare.objects.writePack(
      packBytes: built.bytes,
      objects: built.objects,
      packChecksum: built.checksum,
    );
    final second = bare.objects.writePack(
      packBytes: built.bytes,
      objects: built.objects,
      packChecksum: built.checksum,
    );
    bare.close();

    // The name is a hash of the object set, so the same set lands on the same
    // name — which is what stops a re-fetch from accumulating packs.
    expect(second, first);
    final packs = Directory(p.join(scratch.path, 'bare2', 'objects', 'pack'))
        .listSync()
        .where((e) => e.path.endsWith('.pack'));
    expect(packs.length, 1);
  });

  test('an empty pack is not stored', () {
    final bare = Repository.init(p.join(scratch.path, 'bare3'), bare: true);
    final empty = PackWriter().buildWithIndex();
    expect(
      bare.objects.writePack(
        packBytes: empty.bytes,
        objects: empty.objects,
        packChecksum: empty.checksum,
      ),
      isNull,
    );
    bare.close();
  });

  test('an index cannot name the same object twice', () {
    final id = repo.headId!;
    expect(
      () => PackIndexWriter.build(
        objects: [
          PackedObject(id: id, offset: 12, crc32: 0),
          PackedObject(id: id, offset: 99, crc32: 0),
        ],
        packChecksum: id,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('our index parses back through our own reader', () {
    final built = packEverything();
    final index = PackIndex.parse(built.buildIndex());

    expect(index.version, 2);
    expect(index.objectCount, built.objects.length);
    for (final object in built.objects) {
      expect(index.contains(object.id), isTrue);
      expect(index.offsetOf(object.id), object.offset);
    }

    // Names come out in ascending order, which the fanout depends on.
    final names = index.listAll().toList();
    for (var i = 1; i < names.length; i++) {
      expect(names[i - 1].compareTo(names[i]), lessThan(0));
    }
  });

  test('a pack that arrived over the wire is indexed from its own bytes', () {
    // What a fetch does: parse a pack it has never seen, and build the index
    // from the offsets the parse walked past, rather than inflating twice.
    final built = packEverything();
    final parser = PackParser(built.bytes);
    final objects = parser.parse();
    final entries = parser.indexEntries();

    expect(entries.length, objects.length);
    expect(parser.checksum, built.checksum);

    // The offsets and checksums agree with what the writer recorded.
    final byId = {for (final o in built.objects) o.id: o};
    for (final entry in entries) {
      expect(entry.offset, byId[entry.id]!.offset);
      expect(entry.crc32, byId[entry.id]!.crc32);
    }

    final target = Directory(p.join(scratch.path, 'wire'))..createSync();
    final name = PackIndexWriter.packName(entries.map((e) => e.id));
    File(p.join(target.path, '$name.pack')).writeAsBytesSync(built.bytes);
    File(p.join(target.path, '$name.idx')).writeAsBytesSync(
      PackIndexWriter.build(
        objects: entries,
        packChecksum: parser.checksum!,
      ),
    );
    git(['verify-pack', p.join(target.path, '$name.idx')], cwd: target.path);
  });

  test('the fanout counts objects by first byte', () {
    final built = packEverything();
    final bytes = built.buildIndex();
    final view = ByteData.sublistView(bytes);

    var previous = 0;
    for (var bucket = 0; bucket < 256; bucket++) {
      final value = view.getUint32(8 + bucket * 4);
      // Non-decreasing, since each entry counts everything at or below it.
      expect(value, greaterThanOrEqualTo(previous));
      previous = value;
    }
    // The last entry is the total.
    expect(previous, built.objects.length);
  });
}
