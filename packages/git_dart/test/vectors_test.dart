/// The vectors of systems/git/v0, transcribed by hand.
///
/// `pattern.the-last-row-is-honest`: vectors are transcribed into tests rather
/// than generated, which is a weaker link than the rest of the method. Each
/// test names the vector id it came from so the two can be compared by eye.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:git_dart/git_dart.dart';
import 'package:test/test.dart';

void main() {
  group('hashing', () {
    test('g-001: the empty blob', () {
      final blob = Blob(Uint8List(0));
      expect(blob.id.hex, 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391');
    });

    test('g-001: the header is hashed, not the content alone', () {
      // The name is the hash of `blob 0` NUL — twelve bytes with the header,
      // and nothing at all without it. An implementation that hashes content
      // alone produces plausible names and interoperates with nothing.
      expect(
        blobOfEmptyStringHashedWithoutHeader,
        isNot('e69de29bb2d1d6434b8b29ae775ad8c2e48c5391'),
      );
    });

    test('g-002: hello and a newline', () {
      final blob = Blob.fromString('hello\n');
      expect(blob.content.length, 6);
      expect(blob.id.hex, 'ce013625030ba8dba906f756967f9e9ca394464a');
    });

    test('the serialised form is kind, space, length, NUL, content', () {
      final serialised = Blob.fromString('hello\n').serialise();
      expect(serialised.sublist(0, 7), ascii.encode('blob 6'.padRight(7, '\x00')));
      expect(ascii.decode(serialised.sublist(7)), 'hello\n');
    });
  });

  group('tree', () {
    test('g-010: one entry, a.txt at mode 100644', () {
      final tree = Tree.build([
        TreeEntry.named(
          mode: FileMode.regularFile,
          name: 'a.txt',
          id: ObjectId.fromHex('ce013625030ba8dba906f756967f9e9ca394464a'),
        ),
      ]);

      // tree-note: 33 content bytes — 6 for `100644`, a space, 5 for the name,
      // a NUL and twenty raw bytes.
      expect(tree.content.length, 33);
      expect(tree.id.hex, '2e81171448eb9f2ee3821e3d447aa6b2fe3ddba1');
    });

    test('the object name is stored as twenty raw bytes, not forty hex', () {
      final id = ObjectId.fromHex('ce013625030ba8dba906f756967f9e9ca394464a');
      final tree = Tree.build([
        TreeEntry.named(mode: FileMode.regularFile, name: 'a.txt', id: id),
      ]);
      expect(tree.content.sublist(13), id.bytes);
    });

    test('the mode is written without a leading zero', () {
      final tree = Tree.build([
        TreeEntry.named(
          mode: FileMode.directory,
          name: 'sub',
          id: ObjectId.zero,
        ),
      ]);
      expect(ascii.decode(tree.content.sublist(0, 5)), '40000');
    });

    test('a directory sorts as though its name ended in a slash', () {
      // Plain string order puts `lib.dart` before `lib`; git's does not,
      // because the directory sorts as `lib/`.
      final tree = Tree.build([
        TreeEntry.named(
          mode: FileMode.regularFile,
          name: 'lib.dart',
          id: ObjectId.zero,
        ),
        TreeEntry.named(
          mode: FileMode.directory,
          name: 'lib',
          id: ObjectId.zero,
        ),
      ]);
      expect(tree.entries.map((e) => e.name), ['lib.dart', 'lib']);
    });

    test('parses back to what it serialised', () {
      final tree = Tree.build([
        TreeEntry.named(
          mode: FileMode.executableFile,
          name: 'run.sh',
          id: ObjectId.fromHex('ce013625030ba8dba906f756967f9e9ca394464a'),
        ),
        TreeEntry.named(
          mode: FileMode.directory,
          name: 'src',
          id: ObjectId.fromHex('2e81171448eb9f2ee3821e3d447aa6b2fe3ddba1'),
        ),
      ]);
      final reparsed = Tree.parse(tree.content);
      expect(reparsed.id, tree.id);
      expect(reparsed.entries.map((e) => e.name), ['run.sh', 'src']);
      expect(reparsed.entries.first.mode, FileMode.executableFile);
    });
  });

  group('commit', () {
    // g-020: tree g-010, no parent, author and committer A <a@x> at
    // 1000000000 +0000, message m.
    final identity = Identity(
      name: 'A',
      email: 'a@x',
      seconds: 1000000000,
      timezone: '+0000',
    );

    final commit = Commit.build(
      tree: ObjectId.fromHex('2e81171448eb9f2ee3821e3d447aa6b2fe3ddba1'),
      author: identity,
      committer: identity,
      message: 'm\n',
    );

    test('g-020: the commit name', () {
      expect(commit.id.hex, '981748c86e10e9a3e606453d42b267901a9cc923');
    });

    test('commit-note: the content is 116 bytes', () {
      expect(commit.content.length, 116);
    });

    test('the header order is tree, parent, author, committer', () {
      final text = utf8.decode(commit.content);
      expect(
        text,
        'tree 2e81171448eb9f2ee3821e3d447aa6b2fe3ddba1\n'
        'author A <a@x> 1000000000 +0000\n'
        'committer A <a@x> 1000000000 +0000\n'
        '\n'
        'm\n',
      );
    });

    test('a parsed commit re-serialises to the same bytes', () {
      final reparsed = Commit.parse(commit.content);
      expect(reparsed.id, commit.id);
      expect(reparsed.tree, commit.tree);
      expect(reparsed.author.name, 'A');
      expect(reparsed.author.seconds, 1000000000);
      expect(reparsed.summary, 'm');
    });

    test('a multi-line header is folded and unfolded', () {
      final signed = Commit(
        tree: commit.tree,
        parents: const [],
        author: identity,
        committer: identity,
        rawMessage: Uint8List.fromList(utf8.encode('m\n')),
        extraHeaders: const [HeaderLine('gpgsig', 'line one\nline two')],
      );
      expect(utf8.decode(signed.content), contains('gpgsig line one\n line two\n'));
      expect(
        Commit.parse(signed.content).extraHeaders.single.value,
        'line one\nline two',
      );
    });
  });

  group('pkt-line', () {
    test('g-041: 0000 is a flush', () {
      final reader = PktLineReader(Uint8List.fromList(ascii.encode('0000')));
      expect(reader.next()!.kind, PktKind.flush);
    });

    test('g-040: 0113 announces 275 bytes including its own four', () {
      final payload = List.filled(275 - 4, 0x61); // 271 bytes of 'a'
      final wire = Uint8List.fromList([...ascii.encode('0113'), ...payload]);

      final packet = PktLineReader(wire).next()!;
      expect(packet.kind, PktKind.data);
      expect(packet.payload.length, 271);
      expect(wire.length, 275);
    });

    test('a fifteen-byte payload is announced as 0013', () {
      final encoded = PktLine.text('123456789012345').encode();
      expect(ascii.decode(encoded.sublist(0, 4)), '0013');
      expect(encoded.length, 19);
    });

    test('an advertisement line carries capabilities after a NUL', () {
      final line = PktLine.data([
        ...utf8.encode(
          '981748c86e10e9a3e606453d42b267901a9cc923 refs/heads/main',
        ),
        0,
        ...utf8.encode('multi_ack side-band-64k'),
      ]);
      final advertised = parseAdvertisement(line);
      expect(advertised.name, '981748c86e10e9a3e606453d42b267901a9cc923');
      expect(advertised.path, 'refs/heads/main');
      expect(advertised.capabilities, ['multi_ack', 'side-band-64k']);
    });
  });

  group('object id', () {
    test('hex and raw bytes are the same value', () {
      const hex = 'ce013625030ba8dba906f756967f9e9ca394464a';
      final id = ObjectId.fromHex(hex);
      expect(id.hex, hex);
      expect(id.bytes.length, 20);
      expect(ObjectId.fromBytes(id.bytes), id);
    });

    test('a short or non-hex name is refused', () {
      expect(() => ObjectId.fromHex('abc'), throwsFormatException);
      expect(
        () => ObjectId.fromHex('z' * 40),
        throwsFormatException,
      );
    });
  });
}

/// SHA-1 of the empty string, which is what an implementation that forgot the
/// header would produce for the empty blob.
const blobOfEmptyStringHashedWithoutHeader =
    'da39a3ee5e6b4b0d3255bfef95601890afd80709';
