/// Shallow clones: history that deliberately stops.
///
/// A depth-limited clone gets the commits near the tips and not their parents.
/// The commits at the edge still *name* those parents, so without a record of
/// which commits were cut the result is indistinguishable from a corrupt
/// repository — `.git/shallow` is that record, and every assertion here is
/// ultimately about whether git agrees the result is a legitimate partial
/// history rather than a broken complete one.
///
/// The server is `git upload-pack` itself, so the deepen negotiation on the
/// wire is the real one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String originPath;

var _clock = 1700000000;

String git(List<String> arguments, {String? cwd}) {
  final when = '$_clock +0000';
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? originPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: {'GIT_AUTHOR_DATE': when, 'GIT_COMMITTER_DATE': when},
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// A smart-HTTP host that is git, relaying `Git-Protocol` so version 2 can be
/// exercised too.
Future<HttpServer> serve(String repositoryPath, {bool allowV2 = true}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  Map<String, String> env(HttpRequest request) {
    final asked = request.headers.value('Git-Protocol');
    if (!allowV2 || asked == null) return const {};
    return {'GIT_PROTOCOL': asked};
  }

  server.listen((request) async {
    try {
      if (request.method == 'GET' && request.uri.path.endsWith('/info/refs')) {
        final process = await Process.start(
          'git',
          ['upload-pack', '--stateless-rpc', '--advertise-refs', repositoryPath],
          environment: env(request),
        );
        unawaited(process.stderr.drain<void>());
        final body = await process.stdout
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
        request.response
          ..statusCode = 200
          ..add([
            ...PktLine.text('# service=git-upload-pack\n').encode(),
            ...PktLine.flush.encode(),
          ])
          ..add(body);
        await request.response.close();
        return;
      }

      if (request.method == 'POST') {
        final input = await request
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
        final process = await Process.start(
          'git',
          ['upload-pack', '--stateless-rpc', repositoryPath],
          environment: env(request),
        );
        unawaited(process.stderr.drain<void>());
        process.stdin.add(input);
        await process.stdin.close();
        final body = await process.stdout
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
        request.response
          ..statusCode = 200
          ..add(body);
        await request.response.close();
        return;
      }

      request.response.statusCode = 404;
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {
        // The client is already gone.
      }
    }
  });

  return server;
}

/// How many commits a repository can actually reach, according to git.
int gitCommitCount(String path) =>
    int.parse(git(['rev-list', '--count', 'HEAD'], cwd: path).trim());

bool gitSaysShallow(String path) =>
    git(['rev-parse', '--is-shallow-repository'], cwd: path).trim() == 'true';

void main() {
  late HttpServer server;
  late String url;

  setUp(() async {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_shallow');
    originPath = p.join(scratch.path, 'origin');
    Directory(originPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    for (var i = 0; i < 10; i++) {
      File(p.join(originPath, 'f.txt')).writeAsStringSync('line $i\n');
      git(['add', '-A']);
      _clock += 60;
      git(['commit', '-q', '-m', 'commit $i']);
    }

    server = await serve(originPath);
    url = 'http://${server.address.address}:${server.port}/origin';
  });

  tearDown(() async {
    await server.close(force: true);
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // git leaves read-only pack files behind.
    }
  });

  test('a depth-limited clone stops where it was told to', () async {
    final path = p.join(scratch.path, 'shallow');
    final result = await clone(url, path, depth: 3);

    expect(result.objectsReceived, greaterThan(0));

    final repo = Repository.open(path);
    expect(repo.isShallow, isTrue, reason: 'the boundary must be recorded');
    expect(repo.shallowCommits, isNotEmpty);
    // Three commits, and their parents deliberately absent.
    expect(repo.log().length, 3);
    repo.close();

    // git's opinion is the one that counts.
    expect(gitSaysShallow(path), isTrue);
    expect(gitCommitCount(path), 3);
    git(['fsck', '--no-progress'], cwd: path);
    expect(File(p.join(path, '.git', 'shallow')).existsSync(), isTrue);
  });

  test('the boundary is the commit git would have cut at', () async {
    // Compared against git's own arithmetic rather than against a second
    // clone: `git clone` cannot be pointed at this test server — it
    // negotiates further than forty lines of harness can answer, which is a
    // limit of the fixture and not of either implementation.
    //
    // Depth four from one tip means the fourth commit back is the one whose
    // parents are withheld, so that is what the boundary must name.
    final expected = git(['rev-parse', 'HEAD~3']).trim();

    final ours = p.join(scratch.path, 'ours');
    await clone(url, ours, depth: 4);

    final boundary = File(p.join(ours, '.git', 'shallow'))
        .readAsLinesSync()
      ..removeWhere((line) => line.trim().isEmpty);

    expect(boundary, [expected]);
    expect(gitCommitCount(ours), 4);
    git(['fsck', '--no-progress'], cwd: ours);
  });

  test('a shallow clone sends less than a full one', () async {
    final shallow = p.join(scratch.path, 'shallow');
    final full = p.join(scratch.path, 'full');

    final shallowResult = await clone(url, shallow, depth: 2);
    final fullResult = await clone(url, full);

    // The point of the exercise: fewer objects cross the wire.
    expect(shallowResult.objectsReceived, lessThan(fullResult.objectsReceived));
    expect(gitCommitCount(shallow), 2);
    expect(gitCommitCount(full), 10);
  });

  test('a depth of one gets only the tip', () async {
    final path = p.join(scratch.path, 'tip');
    await clone(url, path, depth: 1);

    expect(gitCommitCount(path), 1);
    expect(gitSaysShallow(path), isTrue);

    final repo = Repository.open(path);
    // The tip itself is the boundary: it is the commit whose parents were
    // withheld.
    expect(repo.shallowCommits, contains(repo.headId));
    expect(repo.log().length, 1);
    repo.close();
    git(['fsck', '--no-progress'], cwd: path);
  });

  test('deepening moves the boundary back', () async {
    final path = p.join(scratch.path, 'deepen');
    await clone(url, path, depth: 2);
    expect(gitCommitCount(path), 2);

    var repo = Repository.open(path);
    final firstBoundary = {...repo.shallowCommits};
    repo.close();

    repo = Repository.open(path);
    await fetch(repo, repo.remotes.named('origin')!, depth: 5);
    repo.close();

    expect(gitCommitCount(path), 5);
    expect(gitSaysShallow(path), isTrue);

    repo = Repository.open(path);
    // The old boundary is gone — its parents arrived — and a new one took its
    // place further back.
    expect(repo.shallowCommits, isNot(firstBoundary));
    expect(repo.log().length, 5);
    repo.close();

    git(['fsck', '--no-progress'], cwd: path);
  });

  test('a shallow clone can be committed on top of', () async {
    final path = p.join(scratch.path, 'work');
    await clone(url, path, depth: 2);

    File(p.join(path, 'new.txt')).writeAsStringSync('added locally\n');
    final repo = Repository.open(path);
    repo.stage('new.txt');
    final id = repo.commitIndex(
      message: 'on top of a shallow history',
      author: const Identity(
        name: 'A',
        email: 'a@x',
        seconds: 1700009999,
        timezone: '+0000',
      ),
    );
    repo.close();

    expect(git(['rev-parse', 'HEAD'], cwd: path).trim(), id.hex);
    expect(gitCommitCount(path), 3);
    git(['fsck', '--no-progress'], cwd: path);
  });

  test('version 0 gets a shallow clone too', () async {
    await server.close(force: true);
    server = await serve(originPath, allowV2: false);
    url = 'http://${server.address.address}:${server.port}/origin';

    final path = p.join(scratch.path, 'v0');
    await clone(url, path, depth: 3);

    expect(gitCommitCount(path), 3);
    expect(gitSaysShallow(path), isTrue);
    git(['fsck', '--no-progress'], cwd: path);
  });

  test('a depth on a local fetch is refused rather than ignored', () async {
    final path = p.join(scratch.path, 'local');
    Directory(path).createSync(recursive: true);
    final repo = Repository.init(path);
    repo.remotes.add('origin', originPath);

    // A local fetch copies objects directly, so there is nobody to ask for a
    // truncated history. Silently returning a complete one would be telling
    // the caller something untrue about what was downloaded.
    await expectLater(
      fetch(repo, repo.remotes.named('origin')!, depth: 2),
      throwsUnsupportedError,
    );
    repo.close();
  });

  test('a full clone records no boundary', () async {
    final path = p.join(scratch.path, 'full');
    await clone(url, path);

    final repo = Repository.open(path);
    expect(repo.isShallow, isFalse);
    expect(repo.shallowCommits, isEmpty);
    repo.close();

    expect(gitSaysShallow(path), isFalse);
    expect(File(p.join(path, '.git', 'shallow')).existsSync(), isFalse);
  });
}
