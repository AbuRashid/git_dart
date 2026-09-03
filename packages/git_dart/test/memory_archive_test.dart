/// Packing a filesystem into one buffer, and getting the same one back.
///
/// This is how a repository is kept in a browser, so what matters is not that
/// the bytes round-trip but that a *repository* does: the same history, the
/// same refs, and git's own opinion that the result is sound.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' as io;

import 'package:git_dart/git_dart.dart';
import 'package:git_dart/src/fs/git_fs.dart' show fs;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late io.Directory scratch;
late String repoPath;

var _clock = 1700000000;

String git(List<String> arguments, {String? cwd}) {
  final when = '$_clock +0000';
  final result = io.Process.runSync(
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

void commit(String message) {
  io.File(p.join(repoPath, 'f.txt')).writeAsStringSync('$message\n');
  git(['add', '-A']);
  _clock += 60;
  git(['commit', '-q', '-m', message]);
}

MemoryGitFs loadIntoMemory(String root) {
  final memory = MemoryGitFs();
  memory.directory(root).createSync(recursive: true);
  for (final entity in io.Directory(root).listSync(recursive: true)) {
    if (entity is io.Directory) {
      memory.directory(entity.path).createSync(recursive: true);
    } else if (entity is io.File) {
      memory.file(entity.path).writeAsBytesSync(entity.readAsBytesSync());
    }
  }
  memory.markClean();
  return memory;
}

T onMemory<T>(MemoryGitFs memory, T Function() body) {
  useGitFileSystem(memory);
  try {
    return body();
  } finally {
    useGitFileSystem(IoGitFs());
  }
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = io.Directory.systemTemp.createTempSync('git_dart_archive_fs');
    repoPath = p.join(scratch.path, 'repo');
    io.Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
  });

  tearDown(() {
    useGitFileSystem(IoGitFs());
    try {
      scratch.deleteSync(recursive: true);
    } on io.FileSystemException {
      // Read-only objects under .git survive on Windows.
    }
  });

  test('a repository survives being packed and unpacked', () {
    commit('one');
    commit('two');
    git(['branch', 'side']);
    git(['tag', '-a', 'v1', '-m', 'a release']);
    final head = git(['rev-parse', 'HEAD']).trim();

    final memory = loadIntoMemory(repoPath);
    final packed = packMemoryFs(memory, under: repoPath);

    // Unpacked somewhere else entirely, because the archive is portable: a
    // browser calls the repository whatever it likes.
    // Somewhere absolute, because p.absolute turns a rooted path into a
    // drive-qualified one on Windows and the two must agree.
    final elsewhere = p.join(scratch.path, 'elsewhere', 'repo');
    final restored = unpackMemoryFs(packed, under: elsewhere);

    onMemory(restored, () {
      final repo = Repository.open(elsewhere);
      expect(repo.headId!.hex, head);
      expect(
        repo.log().map((c) => c.message.trim()).toList(),
        ['two', 'one'],
      );
      expect(
        repo.refs.branches.map((r) => r.shortName).toList(),
        ['main', 'side'],
      );
      expect(repo.refs.tags.map((r) => r.shortName).toList(), ['v1']);
      expect(utf8.decode(repo.readFile('f.txt')!), 'two\n');
      repo.close();
    });
  });

  test('git accepts a repository that has been through the archive', () {
    commit('one');
    commit('two');

    final packed = packMemoryFs(loadIntoMemory(repoPath), under: repoPath);
    final restored = unpackMemoryFs(packed, under: '/x');

    // Written back to a real disk and handed to git, which is the only
    // opinion that settles whether the round trip preserved a repository.
    final out = p.join(scratch.path, 'rebuilt');
    restored.files.forEach((path, bytes) {
      final relative = path.substring('x/'.length);
      io.File(p.join(out, relative.replaceAll('/', p.separator)))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);
    });

    expect(git(['rev-parse', 'HEAD'], cwd: out).trim(),
        git(['rev-parse', 'HEAD']).trim());
    git(['fsck', '--strict', '--no-progress'], cwd: out);
  });

  test('an empty directory survives, which a packed repository needs', () {
    commit('one');
    // `git gc` packs every ref away and leaves `.git/refs` empty. A store that
    // recorded only files would not bring it back, and the result would stop
    // being recognisable as a repository.
    git(['gc', '-q', '--aggressive']);
    // gc leaves refs/heads and refs/tags behind as empty directories, which
    // is exactly the case that matters: no files, and still meaningful.
    expect(
      io.Directory(p.join(repoPath, '.git', 'refs'))
          .listSync(recursive: true)
          .whereType<io.File>(),
      isEmpty,
      reason: 'gc should have packed every ref away',
    );

    final where = p.join(scratch.path, 'unpacked');
    final packed = packMemoryFs(loadIntoMemory(repoPath), under: repoPath);
    final restored = unpackMemoryFs(packed, under: where);

    onMemory(restored, () {
      expect(fs.directory(p.join(where, '.git', 'refs')).existsSync(), isTrue);
      expect(
        fs.directory(p.join(where, '.git', 'refs', 'heads')).existsSync(),
        isTrue,
        reason: 'an empty directory has to survive the archive',
      );
      final repo = Repository.open(where);
      expect(repo.log().length, 1);
      repo.close();
    });
  });

  test('the same filesystem packs to the same bytes twice', () {
    commit('one');
    final memory = loadIntoMemory(repoPath);
    // Sorted on the way out, so a caller can tell whether anything changed.
    expect(packMemoryFs(memory, under: repoPath),
        packMemoryFs(memory, under: repoPath));
  });

  test('what is unpacked is clean, since it is what the store holds', () {
    commit('one');
    final packed = packMemoryFs(loadIntoMemory(repoPath), under: repoPath);
    final restored = unpackMemoryFs(packed, under: '/x');

    expect(restored.hasChanges, isFalse);
    expect(restored.changedPaths, isEmpty);

    // And writing marks it dirty again, which is what makes a save skippable.
    restored.file('/x/new.txt').writeAsStringSync('hi');
    expect(restored.hasChanges, isTrue);
    expect(restored.changedPaths, contains('x/new.txt'));
  });

  test('paths outside the base are left out', () {
    final memory = MemoryGitFs();
    memory.file('/keep/a.txt').writeAsStringSync('in');
    memory.file('/other/b.txt').writeAsStringSync('out');

    final restored =
        unpackMemoryFs(packMemoryFs(memory, under: '/keep'), under: '/keep');

    expect(restored.file('/keep/a.txt').existsSync(), isTrue);
    expect(restored.file('/other/b.txt').existsSync(), isFalse);
  });

  test('binary content comes back byte for byte', () {
    final memory = MemoryGitFs();
    final bytes = List<int>.generate(1024, (i) => i % 256);
    memory.file('/x/blob.bin').writeAsBytesSync(bytes);

    final restored =
        unpackMemoryFs(packMemoryFs(memory, under: '/x'), under: '/x');
    expect(restored.file('/x/blob.bin').readAsBytesSync(), bytes);
  });

  test('an empty file is a file, not an absence', () {
    final memory = MemoryGitFs();
    memory.file('/x/empty').writeAsBytesSync(const []);

    final restored =
        unpackMemoryFs(packMemoryFs(memory, under: '/x'), under: '/x');
    expect(restored.file('/x/empty').existsSync(), isTrue);
    expect(restored.file('/x/empty').readAsBytesSync(), isEmpty);
  });

  group('refusals', () {
    test('something that is not an archive', () {
      expect(
        () => unpackMemoryFs(bytesOf('not an archive at all')),
        throwsA(isA<MemoryArchiveException>()),
      );
    });

    test('something too short to be one', () {
      expect(
        () => unpackMemoryFs(bytesOf('GIT')),
        throwsA(isA<MemoryArchiveException>()),
      );
    });

    test('an archive that stops in the middle', () {
      final memory = MemoryGitFs();
      memory.file('/x/a.txt').writeAsStringSync('some content here');
      final packed = packMemoryFs(memory, under: '/x');

      // Truncated the way a half-written file would be.
      expect(
        () => unpackMemoryFs(packed.sublist(0, packed.length - 5)),
        throwsA(isA<MemoryArchiveException>()),
      );
    });
  });
}

/// A byte view of some text, for the malformed-input cases.
Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));
