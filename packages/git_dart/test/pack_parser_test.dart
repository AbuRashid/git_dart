/// Reading a packfile with no index, as one arrives over the wire.
///
/// The check is the one that cannot be fooled: every object must hash to the
/// name it is stored under, and the set must match what `git verify-pack`
/// lists. A delta applied wrongly, or a compressed stream whose end was
/// mislocated, fails immediately.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  setUpAll(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_packparse');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    // Enough similar revisions that git chooses to store some as deltas.
    final random = Random(20260805);
    final lines = List.generate(800, (i) => 'line $i: ${random.nextInt(1 << 30)}');
    for (var revision = 0; revision < 12; revision++) {
      for (var i = 0; i < 15; i++) {
        lines[random.nextInt(lines.length)] = 'changed $revision:$i';
      }
      File(p.join(repoPath, 'big.txt')).writeAsStringSync(lines.join('\n'));
      File(p.join(repoPath, 'small.txt')).writeAsStringSync('$revision\n');
      git(['add', '.']);
      git(['commit', '-q', '-m', 'revision $revision']);
    }
    git(['gc', '-q']);
  });

  tearDownAll(() => scratch.deleteSync(recursive: true));

  test('reads every object of a real pack, without its index', () {
    final packDirectory = Directory(p.join(repoPath, '.git', 'objects', 'pack'));
    final pack = packDirectory
        .listSync()
        .firstWhere((f) => f.path.endsWith('.pack')) as File;
    final idx = '${p.withoutExtension(pack.path)}.idx';

    // The pack really does contain deltas, or this test proves little.
    final verified = git(['verify-pack', '-v', idx]);
    expect(
      LineSplitter.split(verified).where((l) => l.contains('delta')).length,
      greaterThan(0),
    );

    final objects = PackParser(pack.readAsBytesSync()).parse();

    // Every name git lists in the index is one we produced, and every object
    // hashes to the name it is filed under.
    final theirs = {
      for (final line in LineSplitter.split(verified))
        if (RegExp(r'^[0-9a-f]{40} ').hasMatch(line)) line.split(' ').first,
    };
    expect(objects.length, theirs.length);
    expect(objects.keys.map((id) => id.hex).toSet(), theirs);

    objects.forEach((id, object) {
      expect(hashObject(object.kind, object.content), id);
    });
  });

  test('the content matches what git prints for the same object', () {
    final pack = Directory(p.join(repoPath, '.git', 'objects', 'pack'))
        .listSync()
        .firstWhere((f) => f.path.endsWith('.pack')) as File;
    final objects = PackParser(pack.readAsBytesSync()).parse();

    final head = ObjectId.fromHex(git(['rev-parse', 'HEAD']).trim());
    final commit = objects[head]!;
    expect(commit.kind, ObjectKind.commit);
    expect(
      utf8.decode(commit.content),
      git(['cat-file', 'commit', head.hex]),
    );

    final blob = ObjectId.fromHex(git(['rev-parse', 'HEAD:big.txt']).trim());
    expect(
      utf8.decode(objects[blob]!.content),
      git(['cat-file', 'blob', blob.hex]),
    );
  });

  test('a truncated pack is refused rather than half-read', () {
    final pack = Directory(p.join(repoPath, '.git', 'objects', 'pack'))
        .listSync()
        .firstWhere((f) => f.path.endsWith('.pack')) as File;
    final bytes = pack.readAsBytesSync();

    expect(
      () => PackParser(bytes.sublist(0, bytes.length ~/ 2)).parse(),
      throwsA(isA<FormatException>()),
    );
  });

  test('a corrupted byte is caught by the pack\'s own checksum', () {
    final pack = Directory(p.join(repoPath, '.git', 'objects', 'pack'))
        .listSync()
        .firstWhere((f) => f.path.endsWith('.pack')) as File;
    final bytes = pack.readAsBytesSync();
    bytes[bytes.length ~/ 2] ^= 0xff;

    expect(() => PackParser(bytes).parse(), throwsA(isA<FormatException>()));
  });
}
