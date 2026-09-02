/// `git archive`, checked against git.
///
/// The tar is compared byte for byte, because it can be: the format has no
/// timestamps of its own beyond the commit's and no compression, so two
/// correct writers produce the same file. That is a much stronger test than
/// "it unpacks", and it is what caught the checksum written six digits wide
/// instead of seven, and the device fields left NUL instead of octal zero.
///
/// The zip cannot be compared that way — deflate output depends on the
/// compressor — so it is compared decoded: the same entries, the same modes,
/// the same bytes.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

var _clock = 1700000000;

String git(List<String> arguments, {String? cwd}) {
  final when = '$_clock +0000';
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: {'GIT_AUTHOR_DATE': when, 'GIT_COMMITTER_DATE': when},
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// git's own archive, as bytes.
Uint8List gitArchive(List<String> arguments) {
  final result = Process.runSync(
    'git',
    ['archive', ...arguments],
    workingDirectory: repoPath,
    stdoutEncoding: null,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git archive ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return Uint8List.fromList(result.stdout as List<int>);
}

void write(String path, String content) {
  final file = File(p.join(repoPath, path.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void commit(String message) {
  git(['add', '-A']);
  _clock += 60;
  git(['commit', '-q', '-m', message]);
}

/// Ours, for the same arguments.
Uint8List ours({
  ArchiveFormat format = ArchiveFormat.tar,
  String prefix = '',
  ObjectId? treeish,
}) {
  final repo = Repository.open(repoPath);
  final bytes =
      writeArchive(repo, format: format, prefix: prefix, treeish: treeish);
  repo.close();
  return bytes;
}

/// Both archives decoded to name, mode and content, which is what a zip has
/// to agree about even though its bytes cannot.
///
/// Flattened to strings deliberately: a record holding a Uint8List compares by
/// identity, so two entries with the same bytes would read as different and
/// the test would fail while showing two identical lines.
List<String> zipEntries(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  return [
    for (final file in archive.files)
      [
        file.name,
        file.mode.toRadixString(8),
        base64.encode(
          file.isFile ? (file.content as List<int>) : const <int>[],
        ),
      ].join(' '),
  ];
}

/// A tar decoded to the fields that describe each entry.
///
/// Used only where the bytes cannot be compared: git stamps an archive of a
/// bare tree with the time it ran, having no commit to take a time from, so
/// two runs of git do not agree with each other either.
List<String> tarEntries(Uint8List bytes) {
  final out = <String>[];
  var at = 0;
  while (at + 512 <= bytes.length) {
    final block = bytes.sublist(at, at + 512);
    if (block.every((byte) => byte == 0)) break;

    String field(int start, int length) {
      final raw = block.sublist(start, start + length);
      final end = raw.indexOf(0);
      return utf8.decode(end < 0 ? raw : raw.sublist(0, end)).trim();
    }

    final name = field(0, 100);
    final prefix = field(345, 155);
    final size = int.parse(field(124, 12).isEmpty ? '0' : field(124, 12),
        radix: 8);

    out.add([
      String.fromCharCode(block[156]), // type flag
      field(100, 8), // mode
      '$size',
      prefix.isEmpty ? name : '$prefix/$name',
      field(157, 100), // link target
      base64.encode(bytes.sublist(at + 512, at + 512 + size)),
    ].join(' '));

    at += 512 + ((size + 511) ~/ 512) * 512;
  }
  return out;
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_archive');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  group('tar', () {
    test('a flat tree is byte for byte what git writes', () {
      write('README.md', 'hello\n');
      write('LICENSE', 'terms\n');
      commit('one');

      expect(ours(), gitArchive(['--format=tar', 'HEAD']));
    });

    test('nested directories, in the order git writes them', () {
      write('README.md', 'hello\n');
      write('src/main.dart', 'code\n');
      write('src/deep/x.txt', 'nested\n');
      commit('one');

      expect(ours(), gitArchive(['--format=tar', 'HEAD']));
    });

    test('an executable keeps its bit', () {
      write('run.sh', '#!/bin/sh\n');
      git(['add', '-A']);
      git(['update-index', '--chmod=+x', 'run.sh']);
      commit('one');

      expect(ours(), gitArchive(['--format=tar', 'HEAD']));

      // And the mode really is the executable one, not merely equal to git's
      // by both being wrong.
      final repo = Repository.open(repoPath);
      final entry = archiveEntries(repo).single;
      repo.close();
      expect(entry.mode, FileMode.executableFile);
    });

    test('a symlink is written as a link, not as its target\'s content', () {
      write('README.md', 'hello\n');
      git(['add', '-A']);
      // Built through the index so the test does not need a real symlink,
      // which Windows will not always let it make.
      final linkBlob = _hashObject('README.md');
      git(['update-index', '--add', '--cacheinfo', '120000,$linkBlob,link.txt']);
      // Committed straight from the index: `git add -A` would stage the link's
      // deletion, because it is an index entry and not a file on disk.
      _clock += 60;
      git(['commit', '-q', '-m', 'one']);

      expect(ours(), gitArchive(['--format=tar', 'HEAD']));

      final repo = Repository.open(repoPath);
      final link =
          archiveEntries(repo).firstWhere((e) => e.path == 'link.txt');
      repo.close();
      expect(link.isSymlink, isTrue);
      expect(utf8.decode(link.content), 'README.md');
    });

    test('a path too long for the name field is split, as git splits it', () {
      final directory = 'a_directory_component_${'x' * 40}';
      final file = 'a_file_${'y' * 60}.txt';
      write('$directory/$file', 'long path content\n');
      write('short.txt', 'short\n');
      commit('one');

      // Over 100 bytes, so it cannot live in the header's name field alone.
      expect('$directory/$file'.length, greaterThan(100));
      expect(ours(), gitArchive(['--format=tar', 'HEAD']));
    });

    test('a prefix becomes a directory entry of its own', () {
      write('a.txt', 'hi\n');
      write('src/b.txt', 'there\n');
      commit('one');

      expect(
        ours(prefix: 'myproj-1.0/'),
        gitArchive(['--format=tar', '--prefix=myproj-1.0/', 'HEAD']),
      );

      final repo = Repository.open(repoPath);
      final entries = archiveEntries(repo, prefix: 'myproj-1.0/');
      repo.close();
      // One entry for the whole prefix, not one per component.
      expect(entries.first.path, 'myproj-1.0/');
      expect(entries.first.isDirectory, isTrue);
    });

    test('a multi-level prefix is still one entry', () {
      write('a.txt', 'hi\n');
      commit('one');

      expect(
        ours(prefix: 'a/b/c/'),
        gitArchive(['--format=tar', '--prefix=a/b/c/', 'HEAD']),
      );
    });

    test('a prefix without a trailing slash is given one', () {
      write('a.txt', 'hi\n');
      commit('one');

      expect(ours(prefix: 'myproj'), ours(prefix: 'myproj/'));
    });

    test('archiving the same commit twice gives the same bytes', () {
      write('a.txt', 'hi\n');
      commit('one');

      // The point of stamping entries with the commit's time: a release
      // tarball that changed every build could not be checksummed.
      expect(ours(), ours());
    });

    test('a tree can be archived directly, not only a commit', () {
      write('a.txt', 'hi\n');
      write('src/b.txt', 'there\n');
      commit('one');

      final tree = ObjectId.fromHex(git(['rev-parse', 'HEAD^{tree}']).trim());
      // A tree names no commit, so there is no global header and no commit
      // time to stamp entries with. git uses the time it ran, which makes its
      // output differ between two runs of git; this uses the epoch, so an
      // archive of a tree is reproducible. Everything else must still agree.
      expect(
        tarEntries(ours(treeish: tree)),
        tarEntries(gitArchive(['--format=tar', tree.hex])),
      );
      expect(ours(treeish: tree), ours(treeish: tree));
    });

    test('a subdirectory\'s tree archives as its own root', () {
      write('src/b.txt', 'there\n');
      write('src/deep/c.txt', 'deeper\n');
      commit('one');

      final tree = ObjectId.fromHex(git(['rev-parse', 'HEAD:src']).trim());
      expect(
        tarEntries(ours(treeish: tree)),
        tarEntries(gitArchive(['--format=tar', tree.hex])),
      );
    });

    test('a tag archives the commit it points at', () {
      write('a.txt', 'hi\n');
      commit('one');
      git(['tag', '-a', 'v1', '-m', 'one']);

      final tag = ObjectId.fromHex(git(['rev-parse', 'v1']).trim());
      expect(ours(treeish: tag), gitArchive(['--format=tar', 'v1']));
    });

    test('a repository with no commits refuses rather than writes nothing',
        () {
      final repo = Repository.open(repoPath);
      expect(() => writeArchive(repo), throwsStateError);
      repo.close();
    });
  });

  group('export-ignore', () {
    test('a named directory is left out, with everything under it', () {
      write('README.md', 'hello\n');
      write('ci/build.yml', 'ci config\n');
      write('ci/deep/fixture.bin', 'fixture\n');
      write('.gitattributes', 'ci/ export-ignore\n');
      commit('one');

      expect(ours(), gitArchive(['--format=tar', 'HEAD']));

      final repo = Repository.open(repoPath);
      final paths = archiveEntries(repo).map((e) => e.path).toList();
      repo.close();
      expect(paths, isNot(contains('ci/')));
      expect(paths.any((path) => path.startsWith('ci/')), isFalse);
      expect(paths, contains('README.md'));
    });

    test('a directory named without a trailing slash is also left out', () {
      // The two spellings mean the same thing to a reader and match
      // differently, so both have to be tested.
      write('README.md', 'hello\n');
      write('docs/a.md', 'docs\n');
      write('.gitattributes', 'docs export-ignore\n');
      commit('one');

      expect(ours(), gitArchive(['--format=tar', 'HEAD']));
    });

    test('a single file is left out', () {
      write('README.md', 'hello\n');
      write('secret.txt', 'not for release\n');
      write('.gitattributes', 'secret.txt export-ignore\n');
      commit('one');

      expect(ours(), gitArchive(['--format=tar', 'HEAD']));

      final repo = Repository.open(repoPath);
      expect(
        archiveEntries(repo).map((e) => e.path),
        isNot(contains('secret.txt')),
      );
      repo.close();
    });

    test('a pattern is used', () {
      write('README.md', 'hello\n');
      write('a.tmp', 'scratch\n');
      write('src/b.tmp', 'scratch\n');
      write('.gitattributes', '*.tmp export-ignore\n');
      commit('one');

      expect(ours(), gitArchive(['--format=tar', 'HEAD']));
    });

    test('rules come from the tree, so a bare repository agrees', () {
      write('README.md', 'hello\n');
      write('ci/build.yml', 'ci\n');
      write('.gitattributes', 'ci/ export-ignore\n');
      commit('one');

      final bare = p.join(scratch.path, 'bare.git');
      git(['clone', '-q', '--bare', repoPath, bare], cwd: scratch.path);

      final repo = Repository.open(bare);
      final paths = archiveEntries(repo).map((e) => e.path).toList();
      repo.close();

      // No working tree to read `.gitattributes` from, and it still applies.
      expect(paths.any((path) => path.startsWith('ci/')), isFalse);
      expect(paths, contains('README.md'));
    });
  });

  group('zip', () {
    test('the same entries, modes and contents as git writes', () {
      write('README.md', 'hello\n');
      write('src/main.dart', 'code\n');
      write('src/deep/x.txt', 'nested\n');
      commit('one');

      expect(
        zipEntries(ours(format: ArchiveFormat.zip)),
        zipEntries(gitArchive(['--format=zip', 'HEAD'])),
      );
    });

    test('an executable survives the round trip', () {
      write('run.sh', '#!/bin/sh\necho hello\n');
      write('plain.txt', 'ordinary\n');
      git(['add', '-A']);
      git(['update-index', '--chmod=+x', 'run.sh']);
      commit('one');

      final mine = zipEntries(ours(format: ArchiveFormat.zip));
      expect(mine, zipEntries(gitArchive(['--format=zip', 'HEAD'])));

      // The executable bit is the thing a zip most easily loses.
      final run = mine.firstWhere((e) => e.startsWith('run.sh '));
      final mode = int.parse(run.split(' ')[1], radix: 8);
      expect(mode & 0x49, isNot(0), reason: 'no execute bits in $run');
    });

    test('a symlink survives the round trip', () {
      write('README.md', 'hello\n');
      git(['add', '-A']);
      final linkBlob = _hashObject('README.md');
      git(['update-index', '--add', '--cacheinfo', '120000,$linkBlob,link.txt']);
      _clock += 60;
      git(['commit', '-q', '-m', 'one']);

      // The link is really there, so this is not two empty listings agreeing.
      expect(
        zipEntries(ours(format: ArchiveFormat.zip)).any(
          (entry) => entry.startsWith('link.txt '),
        ),
        isTrue,
      );
      expect(
        zipEntries(ours(format: ArchiveFormat.zip)),
        zipEntries(gitArchive(['--format=zip', 'HEAD'])),
      );
    });

    test('a prefix applies as it does to a tar', () {
      write('a.txt', 'hi\n');
      write('src/b.txt', 'there\n');
      commit('one');

      expect(
        zipEntries(ours(format: ArchiveFormat.zip, prefix: 'myproj-1.0/')),
        zipEntries(
          gitArchive(['--format=zip', '--prefix=myproj-1.0/', 'HEAD']),
        ),
      );
    });

    test('export-ignore applies as it does to a tar', () {
      write('README.md', 'hello\n');
      write('ci/build.yml', 'ci\n');
      write('.gitattributes', 'ci/ export-ignore\n');
      commit('one');

      expect(
        zipEntries(ours(format: ArchiveFormat.zip)),
        zipEntries(gitArchive(['--format=zip', 'HEAD'])),
      );
    });

    test('a large compressible file is deflated, and reads back intact', () {
      final content = 'the same line over and over\n' * 500;
      write('big.txt', content);
      commit('one');

      final bytes = ours(format: ArchiveFormat.zip);
      // Worth compressing, and compressed.
      expect(bytes.length, lessThan(content.length));

      final entries = zipEntries(bytes);
      final big = entries.firstWhere((e) => e.startsWith('big.txt '));
      expect(utf8.decode(base64.decode(big.split(' ')[2])), content);

      expect(entries, zipEntries(gitArchive(['--format=zip', 'HEAD'])));
    });

    test('archiving the same commit twice gives the same bytes', () {
      write('a.txt', 'hi\n');
      commit('one');

      expect(
        ours(format: ArchiveFormat.zip),
        ours(format: ArchiveFormat.zip),
      );
    });
  });

  group('listing without writing', () {
    test('entries carry the blob each path came from', () {
      write('a.txt', 'hi\n');
      commit('one');

      final repo = Repository.open(repoPath);
      final entry = archiveEntries(repo).single;
      repo.close();

      expect(entry.path, 'a.txt');
      expect(entry.id.hex, git(['rev-parse', 'HEAD:a.txt']).trim());
      expect(utf8.decode(entry.content), 'hi\n');
    });

    test('a submodule is not descended into', () {
      write('a.txt', 'hi\n');
      commit('one');
      // A gitlink names a commit that is not here; there is nothing to write.
      final commitId = git(['rev-parse', 'HEAD']).trim();
      git(['update-index', '--add', '--cacheinfo', '160000,$commitId,vendor']);
      git(['write-tree']);
      final tree = git(['write-tree']).trim();

      final repo = Repository.open(repoPath);
      final paths = archiveEntries(repo, treeish: ObjectId.fromHex(tree))
          .map((e) => e.path);
      repo.close();

      expect(paths, contains('a.txt'));
      expect(paths, isNot(contains('vendor')));
      expect(paths, isNot(contains('vendor/')));
    });

    test('an unborn repository lists nothing rather than throwing', () {
      final repo = Repository.open(repoPath);
      expect(archiveEntries(repo), isEmpty);
      repo.close();
    });
  });
}

/// Writes the given text as a blob and returns its name, for building a
/// symlink entry without needing the filesystem to support one.
String _hashObject(String content) {
  // Written outside the repository so it does not become an untracked file
  // that the archive would then have to explain.
  final holding = File(p.join(scratch.path, 'blob-source'));
  holding.writeAsStringSync(content);
  final result = Process.runSync(
    'git',
    ['hash-object', '-w', holding.path],
    workingDirectory: repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) fail('hash-object failed');
  return (result.stdout as String).trim();
}
