/// `--force-with-lease`, checked against git.
///
/// The whole point is the race, so every test here stages one: somebody else
/// pushes between the fetch and the push. A lease that lets that through is
/// worse than no lease, because it looks like a safety net and is not — so the
/// cases that must be *refused* matter more here than the ones that go
/// through, and git is asked the same question each time.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String minePath;
late String serverPath;
late String otherPath;

var _clock = 1700000000;

String git(List<String> arguments, {String? cwd}) {
  final when = '$_clock +0000';
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? minePath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: {'GIT_AUTHOR_DATE': when, 'GIT_COMMITTER_DATE': when},
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// Runs git and hands back the exit code, for the commands meant to fail.
({int code, String output}) tryGit(List<String> arguments, {String? cwd}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? minePath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: {
      'GIT_AUTHOR_DATE': '$_clock +0000',
      'GIT_COMMITTER_DATE': '$_clock +0000',
    },
  );
  return (
    code: result.exitCode,
    output: '${result.stdout}${result.stderr}',
  );
}

void commit(String message, {String? cwd}) {
  File(p.join(cwd ?? minePath, 'f.txt')).writeAsStringSync('$message\n');
  git(['add', '-A'], cwd: cwd);
  _clock += 60;
  git(['commit', '-q', '-m', message], cwd: cwd);
}

/// Somebody else pushes to the server behind our back.
///
/// They catch up first, because a person who is behind cannot push either -
/// the race being staged is between our fetch and our push, not between two
/// people who are both out of date.
void someoneElsePushes(String message) {
  git(['fetch', '-q', 'origin'], cwd: otherPath);
  git(['reset', '-q', '--hard', 'origin/main'], cwd: otherPath);
  commit(message, cwd: otherPath);
  git(['push', '-q', 'origin', 'main'], cwd: otherPath);
}

/// Rewinds our branch so the next push is not a fast-forward.
void rewindAndRewrite(String message) {
  git(['reset', '-q', '--hard', 'HEAD~1']);
  commit(message);
}

Future<PushResult> pushOurs({
  bool force = false,
  PushLease? lease,
}) async {
  final repo = Repository.open(minePath);
  final remote = repo.remotes.named('origin')!;
  final result = await push(
    repo,
    remote,
    branches: const ['main'],
    force: force,
    lease: lease,
  );
  repo.close();
  return result;
}

String serverHead() => git(['rev-parse', 'main'], cwd: serverPath).trim();

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_lease');

    serverPath = p.join(scratch.path, 'server.git');
    minePath = p.join(scratch.path, 'mine');
    otherPath = p.join(scratch.path, 'other');

    Directory(serverPath).createSync(recursive: true);
    git(['init', '-q', '--bare', '-b', 'main'], cwd: serverPath);
    // This library writes a reflog only when it can say who moved the ref,
    // so without an identity here the server's log is empty — the library
    // behaving as documented, and the test quietly depending on whoever the
    // machine happens to be configured as.
    git(['config', 'user.name', 'Server'], cwd: serverPath);
    git(['config', 'user.email', 'server@x'], cwd: serverPath);

    // A seed commit, pushed, then cloned twice: two people with the same
    // starting point, which is what a race needs.
    Directory(minePath).createSync(recursive: true);
    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    git(['remote', 'add', 'origin', serverPath]);
    commit('one');
    git(['push', '-q', '-u', 'origin', 'main']);

    git(['clone', '-q', serverPath, otherPath], cwd: scratch.path);
    git(['config', 'user.name', 'B'], cwd: otherPath);
    git(['config', 'user.email', 'b@x'], cwd: otherPath);
  });

  tearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Read-only objects under .git survive on Windows.
    }
  });

  group('with nobody else pushing', () {
    test('a fast-forward needs no lease at all', () async {
      commit('two');

      final result = await pushOurs();
      expect(result.ok, isTrue, reason: result.statuses.join('; '));
      expect(serverHead(), git(['rev-parse', 'HEAD']).trim());
    });

    test('a rewind is refused without force or lease', () async {
      commit('two');
      await pushOurs();
      rewindAndRewrite('two rewritten');

      final result = await pushOurs();
      expect(result.ok, isFalse);
      expect(result.rejected.single.rejected, 'not a fast-forward');

      // git refuses the same push for the same reason.
      final theirs = tryGit(['push', 'origin', 'main']);
      expect(theirs.code, isNot(0));
      expect(theirs.output, contains('rejected'));
    });

    test('a rewind goes through with a lease, when nothing has moved', () async {
      commit('two');
      await pushOurs();
      final replaced = serverHead();
      rewindAndRewrite('two rewritten');

      final result = await pushOurs(lease: PushLease.fromTracking);
      expect(result.ok, isTrue, reason: result.statuses.join('; '));
      expect(result.statuses.single.forced, isTrue);
      expect(serverHead(), git(['rev-parse', 'HEAD']).trim());
      expect(serverHead(), isNot(replaced));

      // git agrees the push it would have made is the same one.
      expect(
        tryGit(['push', '--force-with-lease', 'origin', 'main']).code,
        0,
        reason: 'already up to date, so this is a no-op for git',
      );
    });

    test('the reflog records a leased rewind as forced', () async {
      commit('two');
      await pushOurs();
      rewindAndRewrite('two rewritten');
      await pushOurs(lease: PushLease.fromTracking);

      final log = git(['reflog', 'show', 'main'], cwd: serverPath);
      expect(log, contains('forced'));
    });
  });

  group('when somebody else has pushed', () {
    /// The race: we fetch, they push, we try to rewind.
    Future<void> setUpRace() async {
      commit('two');
      await pushOurs();
      // Our tracking ref is now current, and then it stops being current.
      someoneElsePushes('theirs');
      rewindAndRewrite('two rewritten');
    }

    test('a lease refuses the push, naming stale info', () async {
      await setUpRace();
      final theirCommit = serverHead();

      final result = await pushOurs(lease: PushLease.fromTracking);
      expect(result.ok, isFalse);
      expect(result.rejected.single.rejected, contains('stale info'));

      // The point of all this: their commit is still there.
      expect(serverHead(), theirCommit);

      // git refuses it too.
      final theirs = tryGit(['push', '--force-with-lease', 'origin', 'main']);
      expect(theirs.code, isNot(0));
      expect(theirs.output.toLowerCase(), contains('stale info'));
    });

    test('plain force takes it anyway, which is what force means', () async {
      await setUpRace();
      final theirCommit = serverHead();

      final result = await pushOurs(force: true);
      expect(result.ok, isTrue, reason: result.statuses.join('; '));
      expect(result.statuses.single.forced, isTrue);
      // Their work is gone. This is the outcome a lease exists to prevent.
      expect(serverHead(), isNot(theirCommit));
      expect(serverHead(), git(['rev-parse', 'HEAD']).trim());
    });

    test('force wins over a lease when both are asked for', () async {
      await setUpRace();

      final result = await pushOurs(force: true, lease: PushLease.fromTracking);
      expect(result.ok, isTrue, reason: result.statuses.join('; '));
      expect(serverHead(), git(['rev-parse', 'HEAD']).trim());
    });

    test('fetching first makes the lease current, and the push goes through',
        () async {
      await setUpRace();

      // What a person actually does after a refusal: look, then decide.
      git(['fetch', '-q', 'origin']);

      final result = await pushOurs(lease: PushLease.fromTracking);
      expect(result.ok, isTrue, reason: result.statuses.join('; '));
      expect(serverHead(), git(['rev-parse', 'HEAD']).trim());
    });
  });

  group('an explicit lease', () {
    test('the right value lets the rewind through', () async {
      commit('two');
      await pushOurs();
      final onServer = ObjectId.fromHex(serverHead());
      rewindAndRewrite('two rewritten');

      final result = await pushOurs(
        lease: PushLease.of({'refs/heads/main': onServer}),
      );
      expect(result.ok, isTrue, reason: result.statuses.join('; '));
    });

    test('a wrong value refuses it, even with the tracking ref current',
        () async {
      commit('two');
      await pushOurs();
      rewindAndRewrite('two rewritten');

      // The tracking ref would have allowed this; the caller said otherwise.
      final wrong = ObjectId.fromHex(git(['rev-parse', 'HEAD']).trim());
      final result = await pushOurs(
        lease: PushLease.of({'refs/heads/main': wrong}),
      );
      expect(result.ok, isFalse);
      expect(result.rejected.single.rejected, contains('stale info'));
    });

    test('a ref the lease does not name is refused rather than assumed',
        () async {
      commit('two');
      await pushOurs();
      rewindAndRewrite('two rewritten');

      // An explicit lease that says nothing about this ref holds no opinion,
      // and a rewind on no opinion is exactly what must not happen.
      final result = await pushOurs(
        lease: PushLease.of({'refs/heads/other': null}),
      );
      expect(result.ok, isFalse);
      expect(result.rejected.single.rejected, contains('no lease'));
    });
  });

  group('with no tracking ref', () {
    test('a lease refuses rather than falling back to force', () async {
      commit('two');
      await pushOurs();
      rewindAndRewrite('two rewritten');

      // Never fetched, so nothing here records what the server held. A lease
      // with nothing behind it must refuse.
      final tracking = p.join(minePath, '.git', 'refs', 'remotes', 'origin');
      Directory(tracking).deleteSync(recursive: true);
      // packed-refs can hold it too, and would otherwise answer instead.
      final packed = File(p.join(minePath, '.git', 'packed-refs'));
      if (packed.existsSync()) packed.deleteSync();

      final result = await pushOurs(lease: PushLease.fromTracking);
      expect(result.ok, isFalse);
      expect(result.rejected.single.rejected, contains('no lease'));

      // git refuses for the same reason.
      final theirs = tryGit(['push', '--force-with-lease', 'origin', 'main']);
      expect(theirs.code, isNot(0));
    });
  });
}
