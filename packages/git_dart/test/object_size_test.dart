/// Learning how big an object is without building it.
///
/// A preview that refuses files over a megabyte still has to read the file to
/// find out it is over a megabyte, unless the store can be asked first. Every
/// storage form states the size somewhere small: a loose object in the header
/// at the front of its compressed stream, a packed one in its pack header,
/// and a delta in the header of the delta itself. This checks that each is
/// read from there, that the answers agree with git, and that a bounded read
/// refuses without materialising what it refuses.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

void write(String relative, String contents) {
  final file = File(p.join(repoPath, relative.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// What git says, so the comparison is against the format rather than against
/// this implementation's own idea of it.
int gitSize(String revision) =>
    int.parse(git(['cat-file', '-s', revision]).trim());

String gitKind(String revision) => git(['cat-file', '-t', revision]).trim();

ObjectId idOf(String revision) =>
    ObjectId.fromHex(git(['rev-parse', revision]).trim());

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_size');
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
      // Read-only objects under .git survive on Windows.
    }
  });

  test('a loose object states its kind and size, and git agrees', () {
    write('a.txt', 'x' * 5000);
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);

    final repo = Repository.open(repoPath);
    for (final revision in ['HEAD:a.txt', 'HEAD^{tree}', 'HEAD']) {
      final stat = repo.objects.statObject(idOf(revision))!;
      expect(stat.size, gitSize(revision), reason: revision);
      expect(stat.kind.name, gitKind(revision), reason: revision);
    }
    repo.close();
  });

  test('an empty object is a size of zero, not a missing one', () {
    write('empty.txt', '');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);

    final repo = Repository.open(repoPath);
    final stat = repo.objects.statObject(idOf('HEAD:empty.txt'))!;
    repo.close();
    expect(stat.size, 0);
    expect(stat.kind, ObjectKind.blob);
  });

  test('a packed object states its size, and so does a delta', () {
    // Two versions of one long file, so that packing deltifies the second
    // against the first — the case where the size is in the delta's header
    // and not in the pack's.
    final first = List.generate(4000, (i) => 'line $i').join('\n');
    write('big.txt', first);
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    write('big.txt', '$first\nand one more line');
    git(['commit', '-q', '-am', 'second']);
    git(['gc', '-q', '--aggressive']);

    // Nothing loose is left, so every answer below comes from the pack.
    expect(
      Directory(p.join(repoPath, '.git', 'objects'))
          .listSync()
          .whereType<Directory>()
          .where((d) => p.basename(d.path).length == 2)
          .expand((d) => d.listSync())
          .toList(),
      isEmpty,
      reason: 'gc did not pack everything',
    );

    final repo = Repository.open(repoPath);
    for (final revision in ['HEAD:big.txt', 'HEAD~1:big.txt', 'HEAD']) {
      final stat = repo.objects.statObject(idOf(revision))!;
      expect(stat.size, gitSize(revision), reason: revision);
      expect(stat.kind.name, gitKind(revision), reason: revision);
    }
    repo.close();
  });

  test('a bounded read returns what fits and refuses what does not', () {
    write('small.txt', 'small\n');
    write('large.txt', 'x' * 100000);
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);

    final repo = Repository.open(repoPath);

    final small = repo.objects.readRawUpTo(idOf('HEAD:small.txt'), 1024);
    expect(small, isA<ObjectRead>());
    expect((small as ObjectRead).content, utf8.encode('small\n'));
    expect(small.size, 6);

    final large = repo.objects.readRawUpTo(idOf('HEAD:large.txt'), 1024);
    expect(large, isA<ObjectTooLarge>());
    expect((large as ObjectTooLarge).size, 100000);
    expect(large.kind, ObjectKind.blob);

    // A limit exactly the size of the object is not too large: the file fits.
    expect(
      repo.objects.readRawUpTo(idOf('HEAD:large.txt'), 100000),
      isA<ObjectRead>(),
    );

    expect(
      repo.objects.readRawUpTo(ObjectId.fromHex('0' * 40), 1024),
      isA<ObjectMissing>(),
    );
    repo.close();
  });

  test('a refused read does not go through the object cache', () {
    // What is not built cannot be held: the proof that the refusal happened
    // before the object was materialised, rather than after it was thrown
    // away.
    final content = List.generate(20000, (i) => 'line $i').join('\n');
    write('big.txt', content);
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['gc', '-q']);

    final repo = Repository.open(repoPath);
    final pack = repo.objects.packs.single;
    pack.cacheBytes = 1024 * 1024;

    final refused = repo.objects.readRawUpTo(idOf('HEAD:big.txt'), 1024);
    expect(refused, isA<ObjectTooLarge>());
    expect(
      pack.cachedBytes,
      0,
      reason: 'the object was built despite being refused',
    );

    // And the same object read without a limit does land in the cache, so
    // the measurement above means something.
    repo.objects.readRaw(idOf('HEAD:big.txt'));
    expect(pack.cachedBytes, greaterThan(0));
    repo.close();
  });

  test('the pack cache is bounded by bytes, not by how many objects', () {
    for (var i = 0; i < 12; i++) {
      write('file$i.txt', List.generate(3000, (n) => 'file $i line $n').join('\n'));
    }
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    git(['gc', '-q']);

    final repo = Repository.open(repoPath);
    final pack = repo.objects.packs.single;
    // Room for a couple of these files at most.
    pack.cacheBytes = 80000;

    for (var i = 0; i < 12; i++) {
      repo.objects.readRaw(idOf('HEAD:file$i.txt'));
      expect(pack.cachedBytes, lessThanOrEqualTo(pack.cacheBytes));
    }
    repo.close();
  });

  test('readFileUpTo answers by path, at a revision', () {
    write('a.txt', 'one\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);
    write('a.txt', 'x' * 50000);
    write('dir/b.txt', 'two\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'second']);

    final repo = Repository.open(repoPath);

    final old = repo.readFileUpTo('a.txt', 1024, revision: 'HEAD~1');
    expect((old as ObjectRead).content, utf8.encode('one\n'));

    final now = repo.readFileUpTo('a.txt', 1024);
    expect((now as ObjectTooLarge).size, 50000);

    // A directory is not a file to read, and neither is a path that is not
    // there; both are nothing rather than an empty file.
    expect(repo.readFileUpTo('dir', 1024), isA<ObjectMissing>());
    expect(repo.readFileUpTo('nope.txt', 1024), isA<ObjectMissing>());
    repo.close();
  });

  test('a blob of unusual bytes keeps its size and its content', () {
    // Binary content, which a preview must be able to refuse or return
    // without anything having tried to decode it as text on the way.
    final bytes = Uint8List.fromList(List.generate(5000, (i) => i % 256));
    File(p.join(repoPath, 'blob.bin')).writeAsBytesSync(bytes);
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);

    final repo = Repository.open(repoPath);
    final id = idOf('HEAD:blob.bin');
    expect(repo.objects.statObject(id)!.size, 5000);
    final read = repo.objects.readRawUpTo(id, 8192) as ObjectRead;
    expect(read.content, bytes);
    repo.close();
  });
}
