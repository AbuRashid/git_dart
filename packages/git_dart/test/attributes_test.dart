/// `.gitattributes` and line-ending conversion, checked against git.
///
/// None of this is visible in the object model: the blob holds the converted
/// form, so two working trees that look different can be the same object and
/// two that look the same can be different ones. That is what makes it worth
/// testing against git rather than against itself — a conversion that is
/// self-consistent and wrong produces a repository where every file is
/// modified and nobody changed anything.
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

/// Written as raw bytes, so the endings are exactly what is asked for and not
/// what the platform prefers.
void writeBytes(String name, String contents) {
  File(p.join(repoPath, name))
      .writeAsBytesSync(Uint8List.fromList(utf8.encode(contents)));
}

Uint8List readBytes(String name) =>
    File(p.join(repoPath, name)).readAsBytesSync();

/// The bytes git has *stored* for a path, which is the thing that matters.
List<int> storedBytes(String revision) {
  final result = Process.runSync(
    'git',
    ['cat-file', 'blob', revision],
    workingDirectory: repoPath,
    stdoutEncoding: null,
  );
  if (result.exitCode != 0) fail('git cat-file failed');
  return result.stdout as List<int>;
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_attrs');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  // -------------------------------------------------------------------------
  group('reading the rules', () {
    test('a pattern and its attributes', () {
      final attributes = Attributes()
        ..addText('*.txt text\n*.png binary\n/only-here.md text=auto\n');

      expect(attributes.forPath('a.txt')['text'], true);
      expect(attributes.forPath('deep/b.txt')['text'], true);
      expect(attributes.forPath('c.png')['text'], false);
      expect(attributes.forPath('c.png')['diff'], false);
      expect(attributes.forPath('only-here.md')['text'], 'auto');
    });

    test('a later rule wins', () {
      final attributes = Attributes()..addText('* text\n*.bin -text\n');
      expect(attributes.forPath('a.txt')['text'], true);
      expect(attributes.forPath('a.bin')['text'], false);
    });

    test('comments and blank lines are skipped', () {
      final attributes = Attributes()..addText('# a comment\n\n*.txt text\n');
      expect(attributes.rules, hasLength(1));
    });

    test('an anchored pattern applies only where it was written', () {
      final attributes = Attributes()..addText('src/*.txt text\n');
      expect(attributes.forPath('src/a.txt')['text'], true);
      expect(attributes.forPath('other/a.txt')['text'], isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('deciding the conversion', () {
    final text = Uint8List.fromList(utf8.encode('one\ntwo\n'));
    final binary = Uint8List.fromList([1, 2, 0, 3, 4]);

    test('nothing said and autocrlf off means no conversion', () {
      final attributes = Attributes();
      expect(attributes.conversionFor('a.txt', text), EolConversion.none);
    });

    test('autocrlf true converts text and leaves binary alone', () {
      final attributes = Attributes(autocrlf: 'true');
      expect(attributes.conversionFor('a.txt', text), EolConversion.crlf);
      expect(attributes.conversionFor('a.bin', binary), EolConversion.none);
    });

    test('autocrlf input stores LF and leaves the working tree alone', () {
      final attributes = Attributes(autocrlf: 'input');
      expect(attributes.conversionFor('a.txt', text), EolConversion.lf);
    });

    test('-text wins over autocrlf', () {
      final attributes = Attributes(autocrlf: 'true')..addText('*.txt -text\n');
      expect(attributes.conversionFor('a.txt', text), EolConversion.none);
    });

    test('an explicit eol wins over the config', () {
      final attributes = Attributes(autocrlf: 'input')
        ..addText('*.txt text eol=crlf\n');
      expect(attributes.conversionFor('a.txt', text), EolConversion.crlf);
    });

    test('a NUL byte stops conversion whatever was asked for', () {
      // Converting a binary file is not recoverable, so nothing overrides it.
      final attributes = Attributes()..addText('*.dat text eol=crlf\n');
      expect(attributes.conversionFor('a.dat', binary), EolConversion.none);
    });
  });

  // -------------------------------------------------------------------------
  group('converting bytes', () {
    test('CRLF becomes LF on the way in', () {
      final input = Uint8List.fromList(utf8.encode('a\r\nb\r\n'));
      expect(
        utf8.decode(toStorage(input, EolConversion.crlf)),
        'a\nb\n',
      );
    });

    test('a lone CR is content and is left alone', () {
      // Old Mac text, or a progress bar in a log. Dropping it would change a
      // file nobody asked to change.
      final input = Uint8List.fromList(utf8.encode('a\rb\r\n'));
      expect(
        utf8.decode(toStorage(input, EolConversion.crlf)),
        'a\rb\n',
      );
    });

    test('LF becomes CRLF on the way out', () {
      final input = Uint8List.fromList(utf8.encode('a\nb\n'));
      expect(
        utf8.decode(toWorkingTree(input, EolConversion.crlf)),
        'a\r\nb\r\n',
      );
    });

    test('converting out twice is the same as once', () {
      final input = Uint8List.fromList(utf8.encode('a\nb\n'));
      final once = toWorkingTree(input, EolConversion.crlf);
      expect(toWorkingTree(once, EolConversion.crlf), once);
    });

    test('input conversion leaves the working tree alone', () {
      final input = Uint8List.fromList(utf8.encode('a\nb\n'));
      expect(toWorkingTree(input, EolConversion.lf), input);
    });
  });

  // -------------------------------------------------------------------------
  group('against git', () {
    test('a CRLF file is stored with LF, as git stores it', () {
      git(['config', 'core.autocrlf', 'true']);
      writeBytes('.gitattributes', '*.txt text\n');
      writeBytes('a.txt', 'one\r\ntwo\r\nthree\r\n');

      final repo = Repository.open(repoPath);
      repo.stage('.gitattributes');
      repo.stage('a.txt');
      repo.commitIndex(message: 'with crlf');
      repo.close();

      // The stored blob has LF endings, whatever the working tree holds.
      expect(utf8.decode(storedBytes('HEAD:a.txt')), 'one\ntwo\nthree\n');
      // And git, which knows the same rules, sees nothing to report.
      expect(git(['status', '--porcelain']).trim(), isEmpty);
      git(['fsck', '--no-progress']);
    });

    test('the same file staged by git gets the same object name', () {
      // The strongest check available: the two implementations converge on one
      // object for one file.
      git(['config', 'core.autocrlf', 'true']);
      writeBytes('.gitattributes', '*.txt text\n');
      writeBytes('a.txt', 'one\r\ntwo\r\n');

      git(['add', '-A']);
      final fromGit = git(['rev-parse', ':a.txt']).trim();

      git(['rm', '-q', '--cached', 'a.txt']);
      final repo = Repository.open(repoPath);
      repo.stage('a.txt');
      final fromUs = repo.index!.entryFor('a.txt')!.id.hex;
      repo.close();

      expect(fromUs, fromGit);
    });

    test('a CRLF working tree is not permanently dirty', () {
      // The failure this prevents: every text file reported modified against
      // an index that holds the LF form, with no change made.
      git(['config', 'core.autocrlf', 'true']);
      writeBytes('.gitattributes', '*.txt text\n');
      writeBytes('a.txt', 'one\r\ntwo\r\n');
      writeBytes('b.txt', 'three\r\nfour\r\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'first']);

      final repo = Repository.open(repoPath);
      final status = repo.status();
      repo.close();

      expect(status.unstaged, isEmpty);
      expect(status.staged, isEmpty);
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });

    test('a binary file is stored byte for byte', () {
      git(['config', 'core.autocrlf', 'true']);
      writeBytes('.gitattributes', '*.bin binary\n');
      final bytes = Uint8List.fromList([0x01, 0x0d, 0x0a, 0x00, 0x0d, 0x0a]);
      File(p.join(repoPath, 'a.bin')).writeAsBytesSync(bytes);

      final repo = Repository.open(repoPath);
      repo.stage('.gitattributes');
      repo.stage('a.bin');
      repo.commitIndex(message: 'binary');
      repo.close();

      expect(storedBytes('HEAD:a.bin'), bytes);
      expect(readBytes('a.bin'), bytes);
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });

    test('a checkout writes the working-tree form back', () {
      git(['config', 'core.autocrlf', 'true']);
      writeBytes('.gitattributes', '*.txt text\n');
      writeBytes('a.txt', 'one\r\ntwo\r\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'first']);

      // A second commit to check out from, then back.
      writeBytes('a.txt', 'one\r\ntwo\r\nthree\r\n');
      git(['commit', '-qam', 'second']);
      git(['branch', 'other', 'HEAD~1']);

      final repo = Repository.open(repoPath);
      repo.checkout('other');
      repo.close();

      // Written out with CRLF, as the config asks, from a blob holding LF.
      expect(utf8.decode(readBytes('a.txt')), 'one\r\ntwo\r\n');
      expect(utf8.decode(storedBytes('HEAD:a.txt')), 'one\ntwo\n');
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });

    test('eol=lf keeps LF in the working tree even with autocrlf on', () {
      git(['config', 'core.autocrlf', 'true']);
      writeBytes('.gitattributes', '*.sh text eol=lf\n');
      writeBytes('run.sh', '#!/bin/sh\necho hello\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'script']);

      final repo = Repository.open(repoPath);
      repo.checkout('main');
      final status = repo.status();
      repo.close();

      // The point of `eol=lf`: a shell script stays runnable on a system whose
      // default would otherwise give it CRLF.
      expect(utf8.decode(readBytes('run.sh')), '#!/bin/sh\necho hello\n');
      expect(status.unstaged, isEmpty);
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });

    test('without autocrlf nothing is converted, as git does nothing', () {
      // Set explicitly: this machine's global config may well turn it on, and
      // honouring that is the correct behaviour — so "off" has to be asked
      // for rather than assumed.
      git(['config', 'core.autocrlf', 'false']);
      writeBytes('a.txt', 'one\r\ntwo\r\n');

      final repo = Repository.open(repoPath);
      repo.stage('a.txt');
      repo.commitIndex(message: 'as is');
      repo.close();

      // Stored exactly as written: git's default does not convert either.
      expect(utf8.decode(storedBytes('HEAD:a.txt')), 'one\r\ntwo\r\n');
      expect(git(['status', '--porcelain']).trim(), isEmpty);
    });
  });
}
