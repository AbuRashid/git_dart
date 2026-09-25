/// Names that are not text.
///
/// Git stores a path as bytes and does not require them to be valid UTF-8.
/// A Dart string cannot hold such a name: decoding replaces each bad byte
/// with U+FFFD, and encoding that back gives different bytes. Two things
/// follow, and both are checked here. An index read and written again must
/// not rename the file. And a name must not be addressable by the string
/// that merely displays it, because two different names can display alike.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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

/// An index holding one entry whose path byte [at] has been replaced by
/// [byte], with the checksum recomputed so the file is well formed.
///
/// Built rather than created on disk: a filesystem need not accept such a
/// name, and the defect is in what this library does with the bytes, not in
/// whether the platform can store them.
Uint8List indexWithByte(String path, int at, int byte) {
  final bytes = GitIndex(
    entries: [IndexEntry(path: path, id: ObjectId.zero, mode: 33188)],
  ).serialise();
  final pathAt = bytes.length - ObjectId.byteLength - 8 - path.length;
  // Find the path rather than assuming its offset: the header is fixed, the
  // padding is not.
  final start = _indexOf(bytes, utf8.encode(path), from: 12);
  expect(start, greaterThan(0), reason: 'path not found in the index');
  bytes[start + at] = byte;
  expect(pathAt, isNotNull);

  final digest = sha1.convert(
    bytes.sublist(0, bytes.length - ObjectId.byteLength),
  );
  bytes.setRange(
    bytes.length - ObjectId.byteLength,
    bytes.length,
    digest.bytes,
  );
  return bytes;
}

int _indexOf(Uint8List haystack, List<int> needle, {int from = 0}) {
  outer:
  for (var i = from; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_rawpath');
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

  test('an index round trip keeps a name that is not valid UTF-8', () {
    // `xz` with the z replaced by 0xff: one byte, invalid on its own.
    final original = indexWithByte('xz', 1, 0xff);

    final parsed = GitIndex.parse(original);
    expect(parsed.entries.single.rawPath, [0x78, 0xff]);
    // It still renders, with the replacement character, for anything that
    // shows a list of files.
    expect(parsed.entries.single.path.runes.toList(), [0x78, 0xfffd]);
    expect(parsed.entries.single.pathIsText, isFalse);

    final written = GitIndex.parse(parsed.serialise());
    expect(
      written.entries.single.rawPath,
      [0x78, 0xff],
      reason: 'the round trip renamed the file',
    );
  });

  test('an ordinary name is unaffected, and still sorts as git sorts it', () {
    final index = GitIndex(entries: [
      IndexEntry(path: 'b.txt', id: ObjectId.zero, mode: 33188),
      IndexEntry(path: 'a.txt', id: ObjectId.zero, mode: 33188),
      IndexEntry(path: 'a/b.txt', id: ObjectId.zero, mode: 33188),
    ]);
    final written = GitIndex.parse(index.serialise());
    expect(
      written.entries.map((e) => e.path),
      // Byte order, in which '/' (0x2f) comes before '.' — no, after: this
      // is git's order, which is plain bytes.
      ['a.txt', 'a/b.txt', 'b.txt'],
    );
    expect(written.entries.every((e) => e.pathIsText), isTrue);
  });

  test('two names that display alike are kept apart in a tree', () {
    final one = TreeEntry(
      mode: FileMode.regularFile,
      rawName: Uint8List.fromList([0x78, 0xff]),
      id: ObjectId.fromHex('1' * 40),
    );
    final other = TreeEntry(
      mode: FileMode.regularFile,
      rawName: Uint8List.fromList([0x78, 0xfe]),
      id: ObjectId.fromHex('2' * 40),
    );
    // The point: they are different names that look the same.
    expect(one.name, other.name);
    expect(one.rawName, isNot(other.rawName));

    final tree = Tree([one, other]);

    // Asking by the rendering finds neither, rather than whichever came
    // first: a repaired label must not address a file.
    expect(tree.entryNamed(one.name), isNull);

    // Asking by the bytes finds exactly the one asked for.
    expect(tree.entryWithRawName([0x78, 0xff])!.id, one.id);
    expect(tree.entryWithRawName([0x78, 0xfe])!.id, other.id);
  });

  test('a path lookup by bytes reaches a file a string cannot name', () {
    final odd = TreeEntry(
      mode: FileMode.regularFile,
      rawName: Uint8List.fromList([0x78, 0xff]),
      id: ObjectId.fromHex('3' * 40),
    );
    final plain = TreeEntry.named(
      mode: FileMode.regularFile,
      name: 'plain.txt',
      id: ObjectId.fromHex('4' * 40),
    );
    final inner = Tree([odd, plain]);

    final repo = Repository.open(repoPath);
    repo.writeObject(inner);
    final outer = Tree([
      TreeEntry.named(
        mode: FileMode.directory,
        name: 'dir',
        id: inner.id,
      ),
    ]);
    repo.writeObject(outer);

    expect(repo.lookup(outer, 'dir/plain.txt')!.id, plain.id);
    expect(repo.lookup(outer, 'dir/x�'), isNull);
    expect(
      repo.lookupRaw(outer, [...utf8.encode('dir/'), 0x78, 0xff])!.id,
      odd.id,
    );
    repo.close();
  });

  test('status names the tracked paths no string can address', () {
    // A real repository, with the odd entry put into its index directly.
    File(p.join(repoPath, 'ordinary.txt')).writeAsStringSync('one\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);

    final indexPath = p.join(repoPath, '.git', 'index');
    final index = GitIndex.open(indexPath)!;
    final odd = IndexEntry.raw(
      rawPath: Uint8List.fromList([0x78, 0xff]),
      id: index.entries.first.id,
      mode: 33188,
    );
    GitIndex(entries: [...index.entries, odd]).writeTo(indexPath);

    final repo = Repository.open(repoPath);
    final status = repo.status(trustStatCache: false);
    repo.close();

    expect(status.unrepresentable, hasLength(1));
    expect(status.unrepresentable.single.runes.toList(), [0x78, 0xfffd]);

    // And git can still read the index we wrote, which is the check that the
    // bytes went back exactly as they came.
    expect(git(['ls-files']), contains('ordinary.txt'));
  });

  test('staging an unrelated file leaves an odd path exactly as it was', () {
    // The case the report worried about: an ordinary operation rewrites the
    // index, and every entry it did not touch must come back unchanged.
    File(p.join(repoPath, 'ordinary.txt')).writeAsStringSync('one\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);

    final indexPath = p.join(repoPath, '.git', 'index');
    final first = GitIndex.open(indexPath)!;
    GitIndex(entries: [
      ...first.entries,
      IndexEntry.raw(
        rawPath: Uint8List.fromList([0x78, 0xff]),
        id: first.entries.first.id,
        mode: 33188,
      ),
    ]).writeTo(indexPath);

    File(p.join(repoPath, 'another.txt')).writeAsStringSync('two\n');
    final repo = Repository.open(repoPath);
    repo.stage('another.txt');
    repo.close();

    final after = GitIndex.open(indexPath)!;
    final kept = after.entries.where((e) => !e.pathIsText).toList();
    expect(kept, hasLength(1));
    expect(kept.single.rawPath, [0x78, 0xff]);
    expect(after.entries.map((e) => e.path), contains('another.txt'));
  });
}
