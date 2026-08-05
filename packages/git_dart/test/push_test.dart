/// Pushing, to a directory and over smart HTTP.
///
/// The receiving side is always real git — a bare repository it created, or
/// `git receive-pack` behind an HttpServer. So the pack this library builds is
/// judged by git's own unpacker, which is the only judgement that matters.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String workPath;

String git(List<String> arguments, {String? cwd}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? workPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// A smart-HTTP host for receive-pack, the way a real one works.
Future<HttpServer> serve(String repositoryPath) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  server.listen((request) async {
    Future<void> pipe(List<String> arguments, List<int>? input) async {
      final process = await Process.start('git', arguments);
      unawaited(process.stderr.drain<void>());
      if (input != null) {
        process.stdin.add(input);
        await process.stdin.close();
      }
      final body = await process.stdout
          .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
      request.response
        ..statusCode = 200
        ..add(body);
      await request.response.close();
    }

    try {
      if (request.method == 'GET' && request.uri.path.endsWith('/info/refs')) {
        final process = await Process.start('git', [
          'receive-pack',
          '--stateless-rpc',
          '--advertise-refs',
          repositoryPath,
        ]);
        unawaited(process.stderr.drain<void>());
        final body = await process.stdout
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));

        request.response
          ..statusCode = 200
          ..headers.set(
            'Content-Type',
            'application/x-git-receive-pack-advertisement',
          )
          ..add(PktLine.text('# service=git-receive-pack\n').encode())
          ..add(PktLine.flush.encode())
          ..add(body);
        await request.response.close();
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path.endsWith('/git-receive-pack')) {
        final input = await request
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
        await pipe(
          ['receive-pack', '--stateless-rpc', repositoryPath],
          input,
        );
        return;
      }

      request.response.statusCode = 404;
      await request.response.close();
    } catch (_) {
      request.response.statusCode = 500;
      await request.response.close();
    }
  });

  return server;
}

String bareRepository(String name) {
  final path = p.join(scratch.path, name);
  Process.runSync('git', ['init', '-q', '--bare', '-b', 'main', path]);
  return path;
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_push');
    workPath = p.join(scratch.path, 'work');
    Directory(workPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    File(p.join(workPath, 'a.txt')).writeAsStringSync('one\n');
    File(p.join(workPath, 'lib.txt')).writeAsStringSync('library\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'first']);

    File(p.join(workPath, 'a.txt')).writeAsStringSync('one\ntwo\n');
    git(['commit', '-q', '-am', 'second']);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  group('the pack we build', () {
    test('is one git can index and unpack', () {
      final repo = Repository.open(workPath);
      final writer = PackWriter();
      for (final id in repo.reachable([repo.headId!])) {
        final raw = repo.objects.readRaw(id)!;
        writer.add(id, raw.kind, raw.content);
      }
      final bytes = writer.build();
      repo.close();

      final packPath = p.join(scratch.path, 'built.pack');
      File(packPath).writeAsBytesSync(bytes);

      // git's own verdict on the pack: it indexes it and reports the objects.
      final result = Process.runSync(
        'git',
        ['index-pack', '-v', packPath],
        workingDirectory: workPath,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');

      // And our own reader agrees with what went in.
      final read = PackParser(bytes).parse();
      expect(read.length, writer.length);
      read.forEach((id, object) {
        expect(hashObject(object.kind, object.content), id);
      });
    });
  });

  group('pushing to a directory', () {
    test('a bare repository receives the branch, and git reads it', () async {
      final bare = bareRepository('bare.git');
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', bare);

      final result = await push(repo, repo.remotes.named('origin')!);

      expect(result.ok, isTrue);
      expect(result.objectsSent, greaterThan(0));
      expect(result.statuses.single.ref, 'refs/heads/main');
      expect(result.statuses.single.from, isNull);

      // git's view of what arrived.
      expect(git(['rev-parse', 'refs/heads/main'], cwd: bare).trim(),
          git(['rev-parse', 'HEAD']).trim());
      expect(git(['rev-list', '--count', 'main'], cwd: bare).trim(), '2');
      expect(git(['fsck', '--no-progress'], cwd: bare), isNotNull);
      expect(
        git(['cat-file', 'blob', 'main:a.txt'], cwd: bare),
        'one\ntwo\n',
      );
      repo.close();
    });

    test("a successful push moves this repository's copy of the branch",
        () async {
      final bare = bareRepository('tracking.git');
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', bare);

      // Nothing local knows about the remote before the first push.
      expect(git(['for-each-ref', 'refs/remotes']).trim(), isEmpty);

      await push(repo, repo.remotes.named('origin')!);
      repo.close();

      // Git does this on every successful push; without it a repository that
      // has only ever pushed has nothing to compare a branch against.
      expect(
        git(['rev-parse', 'refs/remotes/origin/main']).trim(),
        git(['rev-parse', 'HEAD']).trim(),
      );

      // And it keeps up as the branch moves.
      File(p.join(workPath, 'more.txt')).writeAsStringSync('more\n');
      git(['add', '.']);
      git(['commit', '-q', '-m', 'more']);

      final second = Repository.open(workPath);
      await push(second, second.remotes.named('origin')!);
      second.close();

      expect(
        git(['rev-parse', 'refs/remotes/origin/main']).trim(),
        git(['rev-parse', 'HEAD']).trim(),
      );
    });

    test('a second push with nothing new sends nothing', () async {
      final bare = bareRepository('twice.git');
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', bare);

      await push(repo, repo.remotes.named('origin')!);
      final again = await push(repo, repo.remotes.named('origin')!);

      expect(again.objectsSent, 0);
      expect(again.statuses, isEmpty);
      repo.close();
    });

    test('only the new objects are sent on a later push', () async {
      final bare = bareRepository('incremental.git');
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', bare);
      await push(repo, repo.remotes.named('origin')!);

      File(p.join(workPath, 'c.txt')).writeAsStringSync('three\n');
      git(['add', '.']);
      git(['commit', '-q', '-m', 'third']);

      final result = await push(repo, repo.remotes.named('origin')!);

      // A commit, a tree and a blob — not the whole history again.
      expect(result.objectsSent, lessThan(6));
      expect(result.statuses.single.from, isNotNull);
      expect(git(['rev-list', '--count', 'main'], cwd: bare).trim(), '3');
      repo.close();
    });

    test('a push that is not a fast-forward is refused', () async {
      final bare = bareRepository('diverged.git');
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', bare);
      await push(repo, repo.remotes.named('origin')!);
      final beforeRewrite = git(['rev-parse', 'HEAD']).trim();

      // Rewrite history so the new tip does not contain the old one.
      git(['reset', '--quiet', '--hard', 'HEAD~1']);
      File(p.join(workPath, 'a.txt')).writeAsStringSync('different\n');
      git(['commit', '-q', '-am', 'a different second']);

      final refused = await push(repo, repo.remotes.named('origin')!);
      expect(refused.ok, isFalse);
      expect(refused.rejected.single.rejected, 'not a fast-forward');
      // The remote still holds what it had.
      expect(git(['rev-parse', 'main'], cwd: bare).trim(), beforeRewrite);

      final forced =
          await push(repo, repo.remotes.named('origin')!, force: true);
      expect(forced.ok, isTrue);
      expect(forced.statuses.single.forced, isTrue);
      expect(
        git(['rev-parse', 'main'], cwd: bare).trim(),
        git(['rev-parse', 'HEAD']).trim(),
      );
      repo.close();
    });

    test('pushing to a checked-out branch is refused, as git refuses it',
        () async {
      final other = p.join(scratch.path, 'other');
      Directory(other).createSync(recursive: true);
      git(['init', '-q', '-b', 'main', other], cwd: scratch.path);

      final repo = Repository.open(workPath);
      repo.remotes.add('other', other);

      final result = await push(repo, repo.remotes.named('other')!);
      expect(result.ok, isFalse);
      expect(result.rejected.single.rejected, contains('checked out'));
      repo.close();
    });
  });

  group('pushing over smart HTTP', () {
    late HttpServer server;
    late String url;
    late String bare;

    setUp(() async {
      bare = bareRepository('http.git');
      server = await serve(bare);
      url = 'http://${server.address.address}:${server.port}/http.git';
    });

    tearDown(() => server.close(force: true));

    test('git receive-pack accepts what this library sends', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', url);

      final progress = <String>[];
      final result = await push(
        repo,
        repo.remotes.named('origin')!,
        onProgress: progress.add,
      );

      expect(result.ok, isTrue, reason: result.rejected.toString());
      expect(result.objectsSent, greaterThan(0));
      expect(result.statuses.single.ref, 'refs/heads/main');

      // The receiving repository is git's, and this is git's opinion of it.
      expect(git(['rev-parse', 'refs/heads/main'], cwd: bare).trim(),
          git(['rev-parse', 'HEAD']).trim());
      expect(git(['fsck', '--no-progress'], cwd: bare), isNotNull);
      expect(git(['rev-list', '--count', 'main'], cwd: bare).trim(), '2');
      expect(
        git(['cat-file', 'blob', 'main:lib.txt'], cwd: bare),
        'library\n',
      );
      repo.close();
    });

    test('over http the tracking ref moves too', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', url);

      await push(repo, repo.remotes.named('origin')!);
      repo.close();

      expect(
        git(['rev-parse', 'refs/remotes/origin/main']).trim(),
        git(['rev-parse', 'HEAD']).trim(),
      );
    });

    test('a later commit is pushed on top of what is already there', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', url);
      await push(repo, repo.remotes.named('origin')!);

      File(p.join(workPath, 'd.txt')).writeAsStringSync('four\n');
      git(['add', '.']);
      git(['commit', '-q', '-m', 'fourth']);

      final result = await push(repo, repo.remotes.named('origin')!);
      expect(result.ok, isTrue);
      expect(result.statuses.single.from, isNotNull);
      expect(git(['rev-list', '--count', 'main'], cwd: bare).trim(), '3');
      expect(git(['fsck', '--no-progress'], cwd: bare), isNotNull);
      repo.close();
    });

    test('a non-fast-forward is refused before anything is sent', () async {
      final repo = Repository.open(workPath);
      repo.remotes.add('origin', url);
      await push(repo, repo.remotes.named('origin')!);
      final onServer = git(['rev-parse', 'main'], cwd: bare).trim();

      git(['reset', '--quiet', '--hard', 'HEAD~1']);
      File(p.join(workPath, 'a.txt')).writeAsStringSync('rewritten\n');
      git(['commit', '-q', '-am', 'rewritten']);

      final result = await push(repo, repo.remotes.named('origin')!);
      expect(result.ok, isFalse);
      expect(result.objectsSent, 0);
      expect(git(['rev-parse', 'main'], cwd: bare).trim(), onServer);
      repo.close();
    });
  });
}
