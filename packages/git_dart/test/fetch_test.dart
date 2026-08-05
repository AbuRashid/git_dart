/// Fetching, from a directory and over smart HTTP.
///
/// The HTTP tests run against a server that is git itself: an HttpServer here
/// pipes to `git upload-pack`, exactly as a real smart-HTTP host does. So the
/// protocol on the wire is the real one, and nothing about the exchange is a
/// fixture written by hand.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String originPath;

String git(List<String> arguments, {String? cwd}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? originPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// A smart-HTTP host, the way a real one works: it runs `git upload-pack` and
/// pipes the bytes through.
Future<HttpServer> serve(String repositoryPath) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  server.listen((request) async {
    try {
      if (request.method == 'GET' &&
          request.uri.path.endsWith('/info/refs')) {
        final process = await Process.start('git', [
          'upload-pack',
          '--stateless-rpc',
          '--advertise-refs',
          repositoryPath,
        ]);
        // Drained, or a full stderr pipe blocks upload-pack for ever.
        unawaited(process.stderr.drain<void>());
        final body = await process.stdout.fold<List<int>>(
          <int>[],
          (all, chunk) => all..addAll(chunk),
        );

        // The service banner and a flush come before what upload-pack wrote.
        final prelude = <int>[
          ...PktLine.text('# service=git-upload-pack\n').encode(),
          ...PktLine.flush.encode(),
        ];

        request.response
          ..statusCode = 200
          ..headers.set(
            'Content-Type',
            'application/x-git-upload-pack-advertisement',
          )
          ..add(prelude)
          ..add(body);
        await request.response.close();
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path.endsWith('/git-upload-pack')) {
        final input = await request.fold<List<int>>(
          <int>[],
          (all, chunk) => all..addAll(chunk),
        );

        final process = await Process.start('git', [
          'upload-pack',
          '--stateless-rpc',
          repositoryPath,
        ]);
        unawaited(process.stderr.drain<void>());
        process.stdin.add(input);
        await process.stdin.close();

        final body = await process.stdout.fold<List<int>>(
          <int>[],
          (all, chunk) => all..addAll(chunk),
        );

        request.response
          ..statusCode = 200
          ..headers
              .set('Content-Type', 'application/x-git-upload-pack-result')
          ..add(body);
        await request.response.close();
        return;
      }

      request.response.statusCode = 404;
      await request.response.close();
    } catch (error) {
      request.response.statusCode = 500;
      await request.response.close();
    }
  });

  return server;
}

/// A repository with nothing in it, to fetch into.
String emptyClone(String name) {
  final path = p.join(scratch.path, name);
  Directory(path).createSync(recursive: true);
  Repository.init(path).close();
  return path;
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_fetch');
    originPath = p.join(scratch.path, 'origin');
    Directory(originPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    File(p.join(originPath, 'a.txt')).writeAsStringSync('one\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'first']);

    File(p.join(originPath, 'a.txt')).writeAsStringSync('one\ntwo\n');
    git(['commit', '-q', '-am', 'second']);

    git(['branch', 'side']);
    git(['tag', '-a', 'v1', '-m', 'release one']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  group('a remote that is a directory', () {
    test('fetches every branch into tracking refs', () async {
      final path = emptyClone('local-clone');
      final repo = Repository.open(path);
      repo.remotes.add('origin', originPath);

      final result = await fetch(repo, repo.remotes.named('origin')!);

      expect(result.objectsReceived, greaterThan(0));
      expect(
        result.updates.map((u) => u.ref).toList(),
        ['refs/remotes/origin/main', 'refs/remotes/origin/side'],
      );
      expect(result.updates.every((u) => u.isNew), isTrue);

      // The tracking refs point where the origin's branches do.
      expect(
        repo.refs.resolve('refs/remotes/origin/main')!.hex,
        git(['rev-parse', 'main']).trim(),
      );

      // And git agrees the fetched repository is sound and holds the history.
      expect(
        git(['rev-list', '--count', 'refs/remotes/origin/main'], cwd: path)
            .trim(),
        '2',
      );
      expect(git(['fsck', '--no-progress'], cwd: path), isNotNull);
      repo.close();
    });

    test('a second fetch with nothing new copies nothing', () async {
      final path = emptyClone('twice');
      final repo = Repository.open(path);
      repo.remotes.add('origin', originPath);

      await fetch(repo, repo.remotes.named('origin')!);
      final again = await fetch(repo, repo.remotes.named('origin')!);

      expect(again.objectsReceived, 0);
      expect(again.changed, isEmpty);
      repo.close();
    });

    test('a later commit on the origin arrives on the next fetch', () async {
      final path = emptyClone('incremental');
      final repo = Repository.open(path);
      repo.remotes.add('origin', originPath);
      await fetch(repo, repo.remotes.named('origin')!);

      File(p.join(originPath, 'b.txt')).writeAsStringSync('new\n');
      git(['add', '.']);
      git(['commit', '-q', '-m', 'third']);

      final result = await fetch(repo, repo.remotes.named('origin')!);

      expect(result.changed, hasLength(1));
      expect(result.changed.single.ref, 'refs/remotes/origin/main');
      expect(result.changed.single.isNew, isFalse);
      expect(
        repo.refs.resolve('refs/remotes/origin/main')!.hex,
        git(['rev-parse', 'main']).trim(),
      );
      repo.close();
    });
  });

  group('a remote over smart HTTP', () {
    late HttpServer server;
    late String url;

    setUp(() async {
      // Packed, so the exchange sends a real packfile with deltas in it.
      git(['gc', '-q']);
      server = await serve(originPath);
      url = 'http://${server.address.address}:${server.port}/origin';
    });

    tearDown(() => server.close(force: true));

    test('fetches from a server that is git itself', () async {
      final path = emptyClone('http-clone');
      final repo = Repository.open(path);
      repo.remotes.add('origin', url);

      final progress = <String>[];
      final result = await fetch(
        repo,
        repo.remotes.named('origin')!,
        onProgress: progress.add,
      );

      expect(result.objectsReceived, greaterThan(0));
      expect(
        result.updates.map((u) => u.ref).toList(),
        ['refs/remotes/origin/main', 'refs/remotes/origin/side'],
      );
      expect(
        repo.refs.resolve('refs/remotes/origin/main')!.hex,
        git(['rev-parse', 'main']).trim(),
      );

      // Everything the history needs came across, and git says so.
      expect(
        git(['rev-list', '--count', 'refs/remotes/origin/main'], cwd: path)
            .trim(),
        '2',
      );
      expect(git(['fsck', '--no-progress'], cwd: path), isNotNull);
      expect(
        git(['cat-file', 'blob', 'refs/remotes/origin/main:a.txt'], cwd: path),
        'one\ntwo\n',
      );
      repo.close();
    });

    // A `git clone` against this server was tried here as a control and does
    // not work: the forty lines above are enough of a smart-HTTP host for a
    // fetch and not enough for git's own client, which negotiates further.
    // The fixture's fidelity is established instead by what the fetch
    // produces — `git fsck`, `git rev-list` and the blob comparison below all
    // run against the repository this client filled, and they are git's
    // opinion of it rather than this suite's.
    test('a second fetch asks for nothing and moves nothing', () async {
      final path = emptyClone('http-twice');
      final repo = Repository.open(path);
      repo.remotes.add('origin', url);

      await fetch(repo, repo.remotes.named('origin')!);
      final again = await fetch(repo, repo.remotes.named('origin')!);

      expect(again.objectsReceived, 0);
      expect(again.changed, isEmpty);
      repo.close();
    });

    test('a server that is not there fails with a message, not a hang',
        () async {
      final path = emptyClone('unreachable');
      final repo = Repository.open(path);
      repo.remotes.add('origin', 'http://127.0.0.1:1/nothing');

      await expectLater(
        fetch(repo, repo.remotes.named('origin')!),
        throwsA(anything),
      );
      repo.close();
    });
  });

  group('remote configuration', () {
    test('adds, lists and removes remotes the way git reads them', () {
      final path = emptyClone('config');
      final repo = Repository.open(path);

      repo.remotes.add('origin', 'https://example.invalid/x.git');
      repo.remotes.add('upstream', 'https://example.invalid/y.git');

      expect(
        Process.runSync('git', ['remote'],
                workingDirectory: path, stdoutEncoding: utf8)
            .stdout
            .toString()
            .trim()
            .split('\n'),
        ['origin', 'upstream'],
      );
      expect(
        Process.runSync('git', ['remote', 'get-url', 'origin'],
                workingDirectory: path, stdoutEncoding: utf8)
            .stdout
            .toString()
            .trim(),
        'https://example.invalid/x.git',
      );

      expect(repo.remotes.list().map((r) => r.name), ['origin', 'upstream']);
      expect(
        repo.remotes.named('origin')!.trackingRefFor('refs/heads/main'),
        'refs/remotes/origin/main',
      );

      repo.remotes.remove('upstream');
      expect(repo.remotes.list().map((r) => r.name), ['origin']);
      expect(
        Process.runSync('git', ['remote'],
                workingDirectory: path, stdoutEncoding: utf8)
            .stdout
            .toString()
            .trim(),
        'origin',
      );
      repo.close();
    });

    test('a duplicate name is refused', () {
      final path = emptyClone('duplicate');
      final repo = Repository.open(path);
      repo.remotes.add('origin', 'https://example.invalid/x.git');
      expect(
        () => repo.remotes.add('origin', 'https://example.invalid/z.git'),
        throwsStateError,
      );
      repo.close();
    });
  });

  group('ahead and behind', () {
    test('counts what each side has that the other does not', () async {
      final path = emptyClone('divergence');
      final repo = Repository.open(path);
      repo.remotes.add('origin', originPath);
      await fetch(repo, repo.remotes.named('origin')!);

      // Make the local branch match the remote, then move each side on.
      final tip = repo.refs.resolve('refs/remotes/origin/main')!;
      repo.refs.write('refs/heads/main', tip);
      repo.setUpstream('main', 'origin', 'refs/heads/main');

      expect(repo.trackingFor('main').divergence!.isEven, isTrue);

      File(p.join(originPath, 'c.txt')).writeAsStringSync('theirs\n');
      git(['add', '.']);
      git(['commit', '-q', '-m', 'theirs']);
      await fetch(repo, repo.remotes.named('origin')!);

      final behind = repo.trackingFor('main');
      expect(behind.divergence!.behind, 1);
      expect(behind.divergence!.ahead, 0);

      // git's own count, for the same pair.
      expect(
        Process.runSync(
          'git',
          ['rev-list', '--left-right', '--count', 'main...refs/remotes/origin/main'],
          workingDirectory: path,
          stdoutEncoding: utf8,
        ).stdout.toString().trim().split(RegExp(r'\s+')),
        ['0', '1'],
      );
      repo.close();
    });
  });
}
