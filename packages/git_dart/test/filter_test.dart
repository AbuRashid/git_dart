/// Clean and smudge filter drivers (`filter=<driver>`), checked against git.
///
/// A filter changes what is stored, so the only meaningful check is that the
/// same working tree produces the same object id git produces, and the same
/// object comes back out as the same bytes git writes. The driver used for
/// that is rot13 with `tr`: reversible, so the two halves are inverses, and
/// obvious in a hex dump when one of them did not run.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

const rot13 = "tr 'A-Za-z' 'N-ZA-Mn-za-m'";

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

void writeBytes(String name, String contents) {
  final file = File(p.join(repoPath, name))..parent.createSync(recursive: true);
  file.writeAsBytesSync(Uint8List.fromList(utf8.encode(contents)));
}

String readText(String name) =>
    utf8.decode(File(p.join(repoPath, name)).readAsBytesSync());

String storedText(String revision) {
  final result = Process.runSync(
    'git',
    ['cat-file', 'blob', revision],
    workingDirectory: repoPath,
    stdoutEncoding: null,
  );
  if (result.exitCode != 0) fail('git cat-file $revision failed');
  return utf8.decode(result.stdout as List<int>);
}

/// The id git would store for a working-tree file, filters and all.
String gitHash(String name) => git(['hash-object', '--', name]).trim();

String stagedId(Repository repo, String path) =>
    repo.index!.entryFor(path)!.id.hex;

void configureRot13() {
  git(['config', 'filter.rot13.clean', rot13]);
  git(['config', 'filter.rot13.smudge', rot13]);
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_filters');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    git(['config', 'core.autocrlf', 'false']);
  });

  tearDown(() {
    FilterDriver.registry.clear();
    scratch.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  group('configured commands', () {
    test('staging stores the same blob git add does', () {
      configureRot13();
      writeBytes('.gitattributes', '*.r filter=rot13\n');
      writeBytes('a.r', 'Hello World\n');
      writeBytes('plain.txt', 'Hello World\n');

      final repo = Repository.open(repoPath);
      repo.stage('a.r');
      repo.stage('plain.txt');
      final ours = stagedId(repo, 'a.r');
      final plain = stagedId(repo, 'plain.txt');
      repo.close();

      expect(ours, gitHash('a.r'));
      expect(ours, isNot(plain), reason: 'the clean step did not run');
      expect(plain, gitHash('plain.txt'));
    });

    test('clean runs before line-ending conversion, as in git', () {
      // A driver that records what it was given shows the order: git hands
      // the clean step the file as it is on disk, CRLF and all, and
      // normalises the endings in what comes back.
      configureRot13();
      writeBytes('.gitattributes', '*.r filter=rot13 text eol=crlf\n');
      writeBytes('a.r', 'Hello\r\nWorld\r\n');

      var seen = '';
      final repo = Repository.open(repoPath);
      repo.filters['rot13'] = FilterDriver(clean: (path, content) {
        seen = utf8.decode(content);
        return Uint8List.fromList(
          utf8.encode(_rot13(utf8.decode(content))),
        );
      });
      repo.stage('a.r');
      final ours = stagedId(repo, 'a.r');
      repo.close();

      expect(seen, 'Hello\r\nWorld\r\n');
      expect(ours, gitHash('a.r'));
      git(['add', 'a.r']);
      expect(storedText(':a.r'), 'Uryyb\nJbeyq\n');
    });

    test('checkout writes the bytes git checkout writes', () {
      configureRot13();
      writeBytes('.gitattributes', '*.r filter=rot13 text eol=crlf\n');
      writeBytes('a.r', 'Hello\r\nWorld\r\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'first']);
      git(['branch', 'other']);
      writeBytes('a.r', 'Changed\r\n');
      git(['commit', '-qam', 'second']);

      // What git itself writes for the first commit's blob.
      git(['checkout', '-q', 'other']);
      final fromGit = readText('a.r');
      git(['checkout', '-q', 'main']);
      expect(readText('a.r'), 'Changed\r\n');

      final repo = Repository.open(repoPath);
      repo.checkout('other');
      final status = repo.status();
      repo.close();

      expect(fromGit, 'Hello\r\nWorld\r\n');
      expect(readText('a.r'), fromGit);
      expect(storedText('HEAD:a.r'), 'Uryyb\nJbeyq\n');

      // And nothing looks modified, to us or to git.
      expect(status.isClean, isTrue);
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });

    test('status sees a filtered file as unchanged, then as changed', () {
      configureRot13();
      writeBytes('.gitattributes', '*.r filter=rot13\n');
      writeBytes('a.r', 'Hello\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'first']);

      final repo = Repository.open(repoPath);
      // Not trusting the stat cache forces the content to be hashed.
      expect(repo.status(trustStatCache: false).isClean, isTrue);
      writeBytes('a.r', 'Goodbye\n');
      expect(repo.status(trustStatCache: false).isClean, isFalse);
      repo.close();
    });

    test('restore and stash go through the filter', () {
      configureRot13();
      writeBytes('.gitattributes', '*.r filter=rot13\n');
      writeBytes('a.r', 'Hello\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'first']);

      final repo = Repository.open(repoPath);

      writeBytes('a.r', 'Scribbled\n');
      restorePath(repo, 'a.r', worktree: true, staged: false);
      expect(readText('a.r'), 'Hello\n');

      writeBytes('a.r', 'Edited\n');
      stashSave(repo);
      expect(readText('a.r'), 'Hello\n');
      final stashed = git(['rev-parse', 'stash@{0}:a.r']).trim();
      writeBytes('a.r', 'Edited\n');
      expect(stashed, gitHash('a.r'), reason: 'stash stored the clean form');
      restorePath(repo, 'a.r', worktree: true, staged: false);

      stashApply(repo);
      repo.close();
      expect(readText('a.r'), 'Edited\n');
    });

    test('%f is replaced with the quoted path', () {
      git(['config', 'filter.named.clean', 'cat; echo %f']);
      writeBytes('.gitattributes', '*.n filter=named\n');
      writeBytes("dir/it's here!.n", 'body\n');

      final repo = Repository.open(repoPath);
      repo.stage("dir/it's here!.n");
      final ours = stagedId(repo, "dir/it's here!.n");
      repo.close();

      git(['add', '-A']);
      expect(storedText(":dir/it's here!.n"), "body\ndir/it's here!.n\n");
      expect(ours, git(['rev-parse', ":dir/it's here!.n"]).trim());
    });

    test('a driver with no command passes the content through', () {
      writeBytes('.gitattributes', '*.m filter=nowhere\n');
      writeBytes('a.m', 'untouched\n');

      final repo = Repository.open(repoPath);
      repo.stage('a.m');
      final ours = stagedId(repo, 'a.m');
      repo.close();

      git(['add', 'a.m']);
      expect(ours, gitHash('a.m'));
      expect(storedText(':a.m'), 'untouched\n');
    });

    test('a failing filter passes the content through unless required', () {
      git(['config', 'filter.broken.clean', 'exit 3']);
      writeBytes('.gitattributes', '*.b filter=broken\n');
      writeBytes('a.b', 'as is\n');

      final repo = Repository.open(repoPath);
      repo.stage('a.b');
      expect(stagedId(repo, 'a.b'), git(['hash-object', 'a.b']).trim());
      repo.close();

      // git reports the failure and stores the file unfiltered.
      git(['add', 'a.b']);
      expect(storedText(':a.b'), 'as is\n');

      git(['config', 'filter.broken.required', 'true']);
      writeBytes('a.b', 'changed\n');
      final required = Repository.open(repoPath);
      expect(
        () => required.stage('a.b'),
        throwsA(isA<FilterException>()
            .having((e) => e.direction, 'direction', 'clean')
            .having((e) => e.exitCode, 'exitCode', 3)),
      );
      required.close();
      expect(
        Process.runSync('git', ['add', 'a.b'], workingDirectory: repoPath)
            .exitCode,
        isNot(0),
        reason: 'git refuses too',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('in-process drivers', () {
    test('an LFS-style driver round-trips through a checkout', () {
      // A fake large-file store: the repository holds a pointer, the store
      // holds the content, and nothing leaves the process.
      final store = <String, Uint8List>{};
      final lfs = FilterDriver(
        clean: (path, content) {
          final oid = crypto.sha256.convert(content).toString();
          store[oid] = content;
          return Uint8List.fromList(utf8.encode(
            'version https://git-lfs.github.com/spec/v1\n'
            'oid sha256:$oid\nsize ${content.length}\n',
          ));
        },
        smudge: (path, pointer) {
          final oid = RegExp(r'oid sha256:([0-9a-f]+)')
              .firstMatch(utf8.decode(pointer))!
              .group(1)!;
          return store[oid]!;
        },
      );

      writeBytes('.gitattributes', '*.bin filter=lfs -text\n');
      File(p.join(repoPath, 'big.bin'))
          .writeAsBytesSync([0, 1, 2, 3, 255, 254]);

      final repo = Repository.open(repoPath);
      repo.filters['lfs'] = lfs;
      repo.stage('.gitattributes');
      repo.stage('big.bin');
      repo.commitIndex(message: 'large file');

      expect(storedText('HEAD:big.bin'), startsWith('version https://'));
      expect(repo.status(trustStatCache: false).isClean, isTrue);

      File(p.join(repoPath, 'big.bin')).deleteSync();
      restorePath(repo, 'big.bin', worktree: true, staged: false);
      repo.close();

      expect(
        File(p.join(repoPath, 'big.bin')).readAsBytesSync(),
        [0, 1, 2, 3, 255, 254],
      );
    });

    test('a registered driver wins over the configured command', () {
      configureRot13();
      writeBytes('.gitattributes', '*.r filter=rot13\n');
      writeBytes('a.r', 'Hello\n');

      final repo = Repository.open(repoPath);
      repo.filters['rot13'] = const FilterDriver(); // both halves pass through
      repo.stage('a.r');
      expect(stagedId(repo, 'a.r'),
          git(['hash-object', '--no-filters', 'a.r']).trim());
      repo.close();
    });

    test('the global registry applies to every repository', () {
      writeBytes('.gitattributes', '*.u filter=upper\n');
      writeBytes('a.u', 'shout\n');
      FilterDriver.registry['upper'] = FilterDriver(
        clean: (path, content) => Uint8List.fromList(
          utf8.encode(utf8.decode(content).toUpperCase()),
        ),
      );

      final repo = Repository.open(repoPath);
      repo.stage('a.u');
      repo.commitIndex(message: 'upper');
      repo.close();

      expect(storedText('HEAD:a.u'), 'SHOUT\n');
    });
  });
}

String _rot13(String text) => String.fromCharCodes(text.codeUnits.map((c) {
      if (c >= 0x41 && c <= 0x5a) return (c - 0x41 + 13) % 26 + 0x41;
      if (c >= 0x61 && c <= 0x7a) return (c - 0x61 + 13) % 26 + 0x61;
      return c;
    }));
