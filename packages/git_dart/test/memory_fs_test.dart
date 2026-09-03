/// The library, running on a filesystem that is not `dart:io`.
///
/// This is the test the web build rests on. Every other test in this suite
/// reaches the disk through `io_git_fs.dart`, so all of them together say
/// nothing about whether the [GitFs] seam actually holds — a call site that
/// slipped past it and used `dart:io` directly would pass every one of them and
/// fail in a browser.
///
/// So: a repository real git built is copied into memory, the filesystem is
/// swapped, and the library is asked the same questions. Then the reverse —
/// a repository written entirely in memory is copied back to disk and handed
/// to `git fsck`, which is the only opinion that settles whether what came out
/// is a git repository or merely something this package can read back.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:git_dart/git_dart.dart';
// The active filesystem is deliberately not exported; a test that swaps it
// has to reach for it where it lives.
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

void commit(String message, {String file = 'f.txt', String? content}) {
  final target = io.File(p.join(repoPath, file.replaceAll('/', p.separator)));
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(content ?? '$message\n');
  git(['add', '-A']);
  _clock += 60;
  git(['commit', '-q', '-m', message]);
}

/// Copies a directory tree on disk into a fresh in-memory filesystem.
///
/// Paths are kept exactly as they are, so the same absolute path opens the
/// repository whichever filesystem is in force.
MemoryGitFs loadIntoMemory(String root) {
  final memory = MemoryGitFs();
  memory.directory(root).createSync(recursive: true);
  for (final entity in io.Directory(root).listSync(recursive: true)) {
    if (entity is io.Directory) {
      // Directories are copied even when empty. `git gc` packs every ref away
      // and leaves `.git/refs` with nothing in it, and a loader that inferred
      // directories from the files inside them would not recreate it - so the
      // repository would stop looking like one. Anything reading a repository
      // out of OPFS has the same job.
      memory.directory(entity.path).createSync(recursive: true);
      continue;
    }
    if (entity is! io.File) continue;
    // A symlink to a file reads as a file here, which is what git would see on
    // a platform without links anyway.
    memory.file(entity.path).writeAsBytesSync(entity.readAsBytesSync());
  }
  return memory;
}

/// Writes an in-memory filesystem back out under [root].
void saveToDisk(MemoryGitFs memory, String root) {
  memory.files.forEach((path, bytes) {
    // Paths were normalised on the way in; put them back under a real root.
    final relative = path.startsWith(_normalisedRoot)
        ? path.substring(_normalisedRoot.length + 1)
        : path;
    final file = io.File(p.join(root, relative.replaceAll('/', p.separator)))
      ..parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  });
}

late String _normalisedRoot;

/// Who the in-memory commits are by. Passed explicitly rather than read from
/// config, so the test does not depend on the machine it runs on.
const _who = Identity(
  name: 'A',
  email: 'a@x',
  seconds: 1700000000,
  timezone: '+0000',
);

/// Runs [body] with the in-memory filesystem in force, then puts back the
/// real one however it ends.
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
    scratch = io.Directory.systemTemp.createTempSync('git_dart_memfs');
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

  group('the filesystem itself', () {
    test('files, directories and listing behave as the interface says', () {
      final memory = MemoryGitFs();
      onMemory(memory, () {
        fs.directory('/root/a/b').createSync(recursive: true);
        fs.file('/root/a/b/one.txt').writeAsStringSync('hello');
        fs.file('/root/a/two.txt').writeAsStringSync('there');

        expect(fs.file('/root/a/b/one.txt').existsSync(), isTrue);
        expect(fs.file('/root/a/b/one.txt').readAsStringSync(), 'hello');
        expect(fs.file('/root/nope.txt').existsSync(), isFalse);
        expect(fs.directory('/root/a/b').existsSync(), isTrue);

        final shallow = fs.directory('/root/a').listSync();
        expect(shallow.map((e) => e.path), ['root/a/b', 'root/a/two.txt']);

        final deep = fs.directory('/root/a').listSync(recursive: true);
        expect(deep, hasLength(3));
      });
    });

    test('a separator is a separator, whichever way it was written', () {
      final memory = MemoryGitFs();
      onMemory(memory, () {
        fs.file(r'C:\repo\.git\HEAD').writeAsStringSync('ref: refs/heads/main');
        // The same file, joined the other way, as `package:path` would on a
        // platform that is not Windows.
        expect(fs.file('C:/repo/.git/HEAD').existsSync(), isTrue);
        expect(
          fs.file('C:/repo/./.git/../.git/HEAD').readAsStringSync(),
          'ref: refs/heads/main',
        );
      });
    });

    test('exclusive create is how a lock is taken', () {
      final memory = MemoryGitFs();
      onMemory(memory, () {
        fs.file('/a/lock').createSync(recursive: true, exclusive: true);
        // The second writer must not also believe it holds the lock.
        expect(
          () => fs.file('/a/lock').createSync(exclusive: true),
          throwsA(isA<GitFsException>()),
        );
      });
    });

    test('rename replaces the destination, which atomic writes depend on', () {
      final memory = MemoryGitFs();
      onMemory(memory, () {
        fs.file('/a/real').writeAsStringSync('old');
        fs.file('/a/temp').writeAsStringSync('new');
        fs.file('/a/temp').renameSync('/a/real');

        expect(fs.file('/a/real').readAsStringSync(), 'new');
        expect(fs.file('/a/temp').existsSync(), isFalse);
      });
    });

    test('appending adds rather than replaces, as a reflog needs', () {
      final memory = MemoryGitFs();
      onMemory(memory, () {
        fs.file('/a/log').writeAsStringSync('one\n');
        fs.file('/a/log').writeAsStringSync('two\n', append: true);
        expect(fs.file('/a/log').readAsStringSync(), 'one\ntwo\n');
      });
    });

    test('a handle reads at arbitrary offsets, as a pack is read', () {
      final memory = MemoryGitFs();
      onMemory(memory, () {
        fs.file('/a/pack').writeAsBytesSync(
          List<int>.generate(256, (i) => i),
        );
        final handle = fs.file('/a/pack').openSync();
        handle.setPositionSync(100);
        final buffer = List<int>.filled(8, 0);
        expect(handle.readIntoSync(buffer), 8);
        expect(buffer, [100, 101, 102, 103, 104, 105, 106, 107]);
        handle.closeSync();
      });
    });

    test('deleting a directory takes what is under it', () {
      final memory = MemoryGitFs();
      onMemory(memory, () {
        fs.file('/a/b/c/one').writeAsStringSync('x');
        fs.file('/a/b/two').writeAsStringSync('y');
        fs.directory('/a/b').deleteSync(recursive: true);

        expect(fs.file('/a/b/c/one').existsSync(), isFalse);
        expect(fs.directory('/a/b').existsSync(), isFalse);
      });
    });
  });

  group('reading a real repository from memory', () {
    test('history, refs and file contents match what git reports', () {
      commit('one');
      commit('two');
      commit('three');
      git(['tag', '-a', 'v1', '-m', 'a release']);
      git(['branch', 'side']);

      final head = git(['rev-parse', 'HEAD']).trim();
      final subjects = git(['log', '--format=%s']).trim().split('\n');

      final memory = loadIntoMemory(repoPath);
      onMemory(memory, () {
        final repo = Repository.open(repoPath);

        expect(repo.headId!.hex, head);
        expect(repo.log().map((c) => c.message.trim()).toList(), subjects);
        expect(
          repo.refs.branches.map((r) => r.shortName).toList(),
          ['main', 'side'],
        );
        expect(repo.refs.tags.map((r) => r.shortName).toList(), ['v1']);
        expect(utf8.decode(repo.readFile('f.txt')!), 'three\n');

        repo.close();
      });
    });

    test('a packed repository is read through the pack, not loose objects', () {
      for (var i = 0; i < 30; i++) {
        commit('commit $i');
      }
      // Everything into one pack, so reading depends on seeking a pack file
      // through the handle rather than on reading loose paths.
      git(['gc', '-q', '--aggressive']);
      expect(
        io.Directory(p.join(repoPath, '.git', 'objects', 'pack'))
            .listSync()
            .whereType<io.File>()
            .where((f) => f.path.endsWith('.pack'))
            .length,
        greaterThan(0),
      );

      final head = git(['rev-parse', 'HEAD']).trim();
      final memory = loadIntoMemory(repoPath);

      onMemory(memory, () {
        final repo = Repository.open(repoPath);
        expect(repo.headId!.hex, head);
        expect(repo.log().length, 30);
        expect(utf8.decode(repo.readFile('f.txt')!), 'commit 29\n');
        repo.close();
      });
    });

    test('status reads the working tree from memory too', () {
      commit('one');
      io.File(p.join(repoPath, 'f.txt')).writeAsStringSync('edited\n');
      io.File(p.join(repoPath, 'new.txt')).writeAsStringSync('fresh\n');

      final memory = loadIntoMemory(repoPath);
      onMemory(memory, () {
        final repo = Repository.open(repoPath);
        final status = repo.status();
        final byPath = {
          for (final entry in status.entries) entry.path: entry,
        };
        expect(byPath['f.txt']!.unstaged, ChangeKind.modified);
        expect(byPath['new.txt']!.isUntracked, isTrue);
        repo.close();
      });
    });

    test('a diff between two commits agrees with git', () {
      commit('one', content: 'first\n');
      commit('two', content: 'second\n');

      final before = git(['rev-parse', 'HEAD~1']).trim();
      final after = git(['rev-parse', 'HEAD']).trim();
      final theirs = git(['diff', '--name-status', before, after]).trim();

      final memory = loadIntoMemory(repoPath);
      onMemory(memory, () {
        final repo = Repository.open(repoPath);
        final changes = repo.diff(
          ObjectId.fromHex(before),
          ObjectId.fromHex(after),
        );
        expect(changes, hasLength(1));
        expect(changes.single.newPath, 'f.txt');
        expect(changes.single.kind, ChangeKind.modified);
        repo.close();
      });

      expect(theirs, 'M\tf.txt');
    });
  });

  group('writing a repository in memory', () {
    test('git accepts what came out of it', () {
      // Nothing on disk at all: the repository is created, committed to, and
      // read back entirely through the in-memory filesystem.
      final memory = MemoryGitFs();
      final root = '/built/repo';
      // Set from the repository itself once it exists: p.absolute turns a
      // rooted path into a drive-qualified one on Windows, so the work tree is
      // not always spelled the way it was asked for.

      late final String head;
      onMemory(memory, () {
        final repo = Repository.init(root);
        _normalisedRoot = repo.workTree!
            .replaceAll(r'\', '/')
            .split('/')
            .where((segment) => segment.isNotEmpty)
            .join('/');

        fs.file(p.join(repo.workTree!, 'hello.txt')).writeAsStringSync('hello from memory\n');
        repo.stage('hello.txt');
        final first = repo.commitIndex(message: 'first commit', author: _who);

        fs.file(p.join(repo.workTree!, 'hello.txt')).writeAsStringSync('second version\n');
        repo.stage('hello.txt');
        final second =
            repo.commitIndex(message: 'second commit', author: _who);

        expect(repo.log().length, 2);
        expect(second, isNot(first));
        head = repo.headId!.hex;
        repo.close();
      });

      // The only opinion that counts: is it a git repository?
      final out = p.join(scratch.path, 'rebuilt');
      io.Directory(out).createSync(recursive: true);
      saveToDisk(memory, out);

      expect(git(['rev-parse', 'HEAD'], cwd: out).trim(), head);
      expect(
        git(['log', '--format=%s'], cwd: out).trim(),
        'second commit\nfirst commit',
      );
      expect(
        git(['show', 'HEAD:hello.txt'], cwd: out),
        'second version\n',
      );
      git(['fsck', '--strict', '--no-progress'], cwd: out);
    });

    test('a branch and a tag written in memory are the ones git sees', () {
      final memory = MemoryGitFs();
      final root = '/built/repo';
      // Set from the repository itself once it exists: p.absolute turns a
      // rooted path into a drive-qualified one on Windows, so the work tree is
      // not always spelled the way it was asked for.

      onMemory(memory, () {
        final repo = Repository.init(root);
        _normalisedRoot = repo.workTree!
            .replaceAll(r'\', '/')
            .split('/')
            .where((segment) => segment.isNotEmpty)
            .join('/');
        fs.file(p.join(repo.workTree!, 'a.txt')).writeAsStringSync('a');
        repo.stage('a.txt');
        repo.commitIndex(message: 'one', author: _who);
        repo.createBranch('feature');
        repo.close();
      });

      final out = p.join(scratch.path, 'rebuilt2');
      io.Directory(out).createSync(recursive: true);
      saveToDisk(memory, out);

      expect(
        git(['branch', '--format=%(refname:short)'], cwd: out).trim().split('\n'),
        containsAll(['main', 'feature']),
      );
      git(['fsck', '--strict', '--no-progress'], cwd: out);
    });
  });

  group('what the web build needs from it', () {
    test('the whole repository can be handed back as bytes', () {
      commit('one');
      commit('two');

      final memory = loadIntoMemory(repoPath);
      // What a browser writes back into OPFS.
      final files = memory.files;

      expect(files, isNotEmpty);
      expect(files.keys.any((path) => path.endsWith('.git/HEAD')), isTrue);
      expect(memory.byteCount, greaterThan(0));

      // And a filesystem rebuilt from those bytes reads the same repository.
      final restored = MemoryGitFs.of(files);
      onMemory(restored, () {
        final repo = Repository.open(repoPath);
        expect(repo.log().length, 2);
        repo.close();
      });
    });
  });
}
