/// Bundles, checked in both directions against git.
///
/// A bundle's whole purpose is to be handed to somebody else, so the test that
/// matters is interoperation: git must be able to verify, clone and fetch from
/// the bundles written here, and the bundles git writes must be readable here.
/// A format that only round-trips through its own implementation would pass a
/// weaker test and be useless.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

({int code, String output}) tryGit(List<String> arguments, {String? cwd}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return (code: result.exitCode, output: '${result.stdout}${result.stderr}');
}

String commit(String message) {
  File(p.join(repoPath, 'f.txt')).writeAsStringSync('$message\n');
  git(['add', '-A']);
  _clock += 60;
  git(['commit', '-q', '-m', message]);
  return git(['rev-parse', 'HEAD']).trim();
}

/// Writes bytes where git can be pointed at them.
String saveBundle(Uint8List bytes, [String name = 'ours.bundle']) {
  final path = p.join(scratch.path, name);
  File(path).writeAsBytesSync(bytes);
  return path;
}

Uint8List ourBundle({
  Map<String, ObjectId>? refs,
  Iterable<ObjectId> since = const [],
  bool includeHead = false,
}) {
  final repo = Repository.open(repoPath);
  final bytes = writeBundle(
    repo,
    refs: refs,
    since: since,
    includeHead: includeHead,
  );
  repo.close();
  return bytes;
}

/// An empty repository to unbundle into.
///
/// Bare, because git refuses to fetch into a branch that is checked out - and
/// because a repository being brought up to date from a bundle is usually a
/// mirror rather than somewhere anyone is working.
String emptyRepo(String name) {
  final path = p.join(scratch.path, name);
  Directory(path).createSync(recursive: true);
  git(['init', '-q', '--bare', '-b', 'main'], cwd: path);
  git(['config', 'user.name', 'A'], cwd: path);
  git(['config', 'user.email', 'a@x'], cwd: path);
  return path;
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_bundle');
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

  group('reading what git writes', () {
    test('a whole-history bundle', () {
      commit('one');
      commit('two');
      git(['tag', '-a', 'v1', '-m', 'one']);
      git(['branch', 'side']);
      git(['bundle', 'create', p.join(scratch.path, 'git.bundle'), '--all']);

      final bytes = Uint8List.fromList(
        File(p.join(scratch.path, 'git.bundle')).readAsBytesSync(),
      );
      final header = readBundleHeader(bytes);

      expect(header.version, 2);
      expect(header.isComplete, isTrue);
      expect(header.prerequisites, isEmpty);
      expect(
        header.refs.keys,
        containsAll(['refs/heads/main', 'refs/heads/side', 'refs/tags/v1']),
      );
      expect(
        header.refs['refs/heads/main']!.hex,
        git(['rev-parse', 'main']).trim(),
      );
      // The packfile really does start where the header says.
      expect(
        utf8.decode(bytes.sublist(header.packOffset, header.packOffset + 4)),
        'PACK',
      );
    });

    test('an incremental bundle names its prerequisites', () {
      commit('one');
      final base = commit('two');
      commit('three');
      git([
        'bundle',
        'create',
        p.join(scratch.path, 'git.bundle'),
        'HEAD~1..HEAD',
      ]);

      final header = readBundleHeader(Uint8List.fromList(
        File(p.join(scratch.path, 'git.bundle')).readAsBytesSync(),
      ));

      expect(header.isComplete, isFalse);
      expect(header.prerequisites.single.id.hex, base);
      // The comment is the commit's subject, written for a person to read.
      expect(header.prerequisites.single.comment, 'two');
    });

    test('its objects can be unbundled into an empty repository', () {
      commit('one');
      commit('two');
      git(['bundle', 'create', p.join(scratch.path, 'git.bundle'), '--all']);
      final head = git(['rev-parse', 'HEAD']).trim();

      final target = emptyRepo('target');
      final repo = Repository.open(target);
      final result = unbundle(
        repo,
        Uint8List.fromList(
          File(p.join(scratch.path, 'git.bundle')).readAsBytesSync(),
        ),
        writeRefs: true,
      );
      repo.close();

      expect(result.refs['refs/heads/main']!.hex, head);
      expect(result.objects, greaterThan(0));
      expect(result.written.keys, contains('refs/heads/main'));

      // git agrees the objects arrived intact and the branch is there.
      expect(git(['rev-parse', 'main'], cwd: target).trim(), head);
      expect(git(['log', '--format=%s', 'main'], cwd: target).trim(),
          'two\none');
      git(['fsck', '--no-progress'], cwd: target);
    });

    test('a file that is not a bundle is refused', () {
      final bytes = Uint8List.fromList(utf8.encode('not a bundle at all\n'));
      expect(() => readBundleHeader(bytes),
          throwsA(isA<BundleFormatException>()));
    });

    test('a truncated header is refused rather than half read', () {
      final bytes = Uint8List.fromList(utf8.encode('# v2 git bundle\n'));
      expect(() => readBundleHeader(bytes),
          throwsA(isA<BundleFormatException>()));
    });
  });

  group('writing what git reads', () {
    test('git verifies a whole-history bundle', () {
      commit('one');
      commit('two');
      git(['tag', '-a', 'v1', '-m', 'one']);

      final path = saveBundle(ourBundle());
      final verified = tryGit(['bundle', 'verify', path]);
      expect(verified.code, 0, reason: verified.output);
      expect(verified.output, contains('is okay'));
    });

    test('git lists the refs we put in it', () {
      commit('one');
      git(['branch', 'side']);
      git(['tag', '-a', 'v1', '-m', 'one']);

      final path = saveBundle(ourBundle());
      final listed = git(['bundle', 'list-heads', path]);

      expect(listed, contains('refs/heads/main'));
      expect(listed, contains('refs/heads/side'));
      expect(listed, contains('refs/tags/v1'));
    });

    test('git can clone from it', () {
      commit('one');
      commit('two');
      final head = git(['rev-parse', 'HEAD']).trim();

      final path = saveBundle(ourBundle(includeHead: true));
      final clone = p.join(scratch.path, 'clone');
      final cloned = tryGit(['clone', '-q', path, clone], cwd: scratch.path);
      expect(cloned.code, 0, reason: cloned.output);

      expect(git(['rev-parse', 'HEAD'], cwd: clone).trim(), head);
      expect(
        git(['log', '--format=%s'], cwd: clone).trim(),
        'two\none',
      );
      git(['fsck', '--no-progress'], cwd: clone);
    });

    test('git can fetch from it', () {
      commit('one');
      commit('two');
      final head = git(['rev-parse', 'HEAD']).trim();

      final path = saveBundle(ourBundle());
      final target = emptyRepo('target');
      final fetched =
          tryGit(['fetch', path, 'refs/heads/main:refs/heads/main'], cwd: target);
      expect(fetched.code, 0, reason: fetched.output);

      expect(git(['rev-parse', 'main'], cwd: target).trim(), head);
      git(['fsck', '--no-progress'], cwd: target);
    });

    test('an annotated tag survives the trip', () {
      commit('one');
      git(['tag', '-a', 'v1', '-m', 'the first release']);
      final tag = git(['rev-parse', 'v1']).trim();

      final path = saveBundle(ourBundle());
      final target = emptyRepo('target');
      git(['fetch', path, 'refs/tags/v1:refs/tags/v1'], cwd: target);

      expect(git(['rev-parse', 'v1'], cwd: target).trim(), tag);
      // The tag object itself, not just the commit it points at.
      expect(
        git(['cat-file', '-t', 'v1'], cwd: target).trim(),
        'tag',
      );
      expect(
        git(['tag', '-l', '-n1', 'v1'], cwd: target),
        contains('the first release'),
      );
    });
  });

  group('incremental bundles', () {
    test('one carries only what came after, and git accepts it', () {
      commit('one');
      final base = commit('two');
      commit('three');
      commit('four');

      final path = saveBundle(
        ourBundle(since: [ObjectId.fromHex(base)]),
      );

      final header = readBundleHeader(
        Uint8List.fromList(File(path).readAsBytesSync()),
      );
      expect(header.isComplete, isFalse);
      expect(header.prerequisites.single.id.hex, base);
      expect(header.prerequisites.single.comment, 'two');

      // Verified against a repository that has the prerequisite.
      final verified = tryGit(['bundle', 'verify', path]);
      expect(verified.code, 0, reason: verified.output);
    });

    test('git refuses it where the prerequisite is absent', () {
      commit('one');
      final base = commit('two');
      commit('three');

      final path = saveBundle(ourBundle(since: [ObjectId.fromHex(base)]));

      // A repository that has never seen the earlier history.
      final target = emptyRepo('target');
      final verified = tryGit(['bundle', 'verify', path], cwd: target);
      expect(verified.code, isNot(0));
    });

    test('we refuse it too, naming what is missing', () {
      commit('one');
      final base = commit('two');
      commit('three');

      final bytes = ourBundle(since: [ObjectId.fromHex(base)]);
      final target = emptyRepo('target');
      final repo = Repository.open(target);

      final header = readBundleHeader(bytes);
      expect(
        missingPrerequisites(repo, header).map((id) => id.hex),
        [base],
      );
      expect(
        () => unbundle(repo, bytes),
        throwsA(isA<BundleFormatException>()),
      );
      repo.close();
    });

    test('it applies cleanly where the prerequisite is present', () {
      commit('one');
      final base = commit('two');

      // A second repository brought up to the base, the ordinary situation
      // for an incremental bundle.
      final target = emptyRepo('target');
      final full = saveBundle(ourBundle(), 'full.bundle');
      git(['fetch', full, 'refs/heads/main:refs/heads/main'], cwd: target);
      expect(git(['rev-parse', 'main'], cwd: target).trim(), base);

      final head = commit('three');
      final increment =
          saveBundle(ourBundle(since: [ObjectId.fromHex(base)]), 'inc.bundle');

      final repo = Repository.open(target);
      final result = unbundle(
        repo,
        Uint8List.fromList(File(increment).readAsBytesSync()),
        writeRefs: true,
      );
      repo.close();

      expect(result.refs['refs/heads/main']!.hex, head);
      expect(git(['rev-parse', 'main'], cwd: target).trim(), head);
      expect(
        git(['log', '--format=%s', 'main'], cwd: target).trim(),
        'three\ntwo\none',
      );
      git(['fsck', '--no-progress'], cwd: target);
    });

    test('a merge\'s excluded parents are both named', () {
      commit('base');
      git(['branch', 'side']);
      File(p.join(repoPath, 'main.txt')).writeAsStringSync('main\n');
      git(['add', '-A']);
      _clock += 60;
      git(['commit', '-q', '-m', 'on main']);
      final mainTip = git(['rev-parse', 'HEAD']).trim();

      git(['checkout', '-q', 'side']);
      File(p.join(repoPath, 'side.txt')).writeAsStringSync('side\n');
      git(['add', '-A']);
      _clock += 60;
      git(['commit', '-q', '-m', 'on side']);
      final sideTip = git(['rev-parse', 'HEAD']).trim();

      git(['checkout', '-q', 'main']);
      _clock += 60;
      git(['merge', '-q', '--no-edit', 'side']);

      // Bundling only the merge means both of its parents are assumed.
      final bytes = ourBundle(
        refs: {'refs/heads/main': ObjectId.fromHex(git(['rev-parse', 'HEAD']).trim())},
        since: [ObjectId.fromHex(mainTip), ObjectId.fromHex(sideTip)],
      );
      final header = readBundleHeader(bytes);

      expect(
        header.prerequisites.map((r) => r.id.hex).toSet(),
        {mainTip, sideTip},
      );

      final verified = tryGit(['bundle', 'verify', saveBundle(bytes)]);
      expect(verified.code, 0, reason: verified.output);
    });
  });

  group('refusals', () {
    test('bundling nothing is refused rather than written empty', () {
      commit('one');

      final repo = Repository.open(repoPath);
      expect(
        () => writeBundle(repo, refs: const {}),
        throwsStateError,
      );
      // Everything named is already covered by what the receiver has.
      expect(
        () => writeBundle(repo, since: [repo.headId!]),
        throwsStateError,
      );
      repo.close();
    });

    test('a repository with no refs has nothing to bundle', () {
      final repo = Repository.open(repoPath);
      expect(() => writeBundle(repo), throwsStateError);
      repo.close();
    });
  });

  group('determinism', () {
    test('the same repository bundles to the same bytes twice', () {
      commit('one');
      commit('two');
      git(['branch', 'side']);
      git(['tag', '-a', 'v1', '-m', 'one']);

      // The header is sorted for exactly this reason: a bundle that differed
      // run to run could not be checksummed or compared.
      expect(ourBundle(), ourBundle());
    });
  });
}
