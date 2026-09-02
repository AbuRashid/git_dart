/// Partial clones: history in full, file contents on demand.
///
/// A filtered fetch asks for the commits and trees and leaves the blobs
/// behind. What arrives is not an incomplete repository but a *promised* one:
/// the missing objects are owed by a remote that has been recorded as owing
/// them. The distinction lives entirely in configuration and a marker file
/// beside the pack, and without it git reads exactly the same objects as
/// corruption — so most of this checks that git agrees the result is
/// legitimate.
///
/// The server is `git upload-pack` with `uploadpack.allowFilter` set, because
/// filtering is off by default and a server that has not opted in simply does
/// not offer it.
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
        // The client has already gone.
      }
    }
  });

  return server;
}

/// Objects git can see are missing but promised.
int missingCount(String path) => git(
      ['rev-list', '--objects', '--all', '--missing=print'],
      cwd: path,
    ).split('\n').where((line) => line.startsWith('?')).length;

List<String> packDir(String path) =>
    Directory(p.join(path, '.git', 'objects', 'pack'))
        .listSync()
        .map((e) => p.basename(e.path))
        .toList();

void main() {
  late HttpServer server;
  late String url;

  setUp(() async {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_partial');
    originPath = p.join(scratch.path, 'origin');
    Directory(originPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    // Filtering is opt-in on the server side.
    git(['config', 'uploadpack.allowFilter', 'true']);
    git(['config', 'uploadpack.allowAnySHA1InWant', 'true']);

    // Several revisions of the same files, so the blobs a full clone would
    // carry vastly outnumber the ones a checkout actually needs.
    for (var i = 0; i < 6; i++) {
      for (final name in ['a.txt', 'b.txt']) {
        File(p.join(originPath, name))
            .writeAsStringSync('$name revision $i\n' * 20);
      }
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

  test('a bare filtered clone leaves the blobs behind', () async {
    final path = p.join(scratch.path, 'bare');
    await clone(url, path, bare: true, filter: 'blob:none');

    // The history is complete; the file contents are not here.
    expect(git(['rev-list', '--count', 'HEAD'], cwd: path).trim(), '6');
    expect(missingCount(path), greaterThan(0),
        reason: 'blobs should be promised rather than present');

    // The marker beside the pack is what makes those absences legitimate.
    expect(
      Directory(p.join(path, 'objects', 'pack'))
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.endsWith('.promisor')),
      isNotEmpty,
    );
  });

  test('git accepts the configuration as a partial clone', () async {
    final path = p.join(scratch.path, 'configured');
    await clone(url, path, filter: 'blob:none');

    // Exactly the three settings git writes for itself.
    expect(
      git(['config', 'core.repositoryformatversion'], cwd: path).trim(),
      '1',
    );
    expect(git(['config', 'remote.origin.promisor'], cwd: path).trim(), 'true');
    expect(
      git(['config', 'remote.origin.partialclonefilter'], cwd: path).trim(),
      'blob:none',
    );
  });

  test('a filtered clone sends less than a full one', () async {
    final partial = p.join(scratch.path, 'partial');
    final full = p.join(scratch.path, 'full');

    final partialResult =
        await clone(url, partial, bare: true, filter: 'blob:none');
    final fullResult = await clone(url, full, bare: true);

    // The saving is every historical revision of every file.
    expect(partialResult.objectsReceived, lessThan(fullResult.objectsReceived));
    // Both hold the whole history.
    expect(git(['rev-list', '--count', 'HEAD'], cwd: partial).trim(), '6');
    expect(git(['rev-list', '--count', 'HEAD'], cwd: full).trim(), '6');
  });

  test('a working tree is checked out from promised blobs', () async {
    final path = p.join(scratch.path, 'worktree');
    await clone(url, path, filter: 'blob:none');

    // The blobs at the tip were redeemed so the checkout could happen, and
    // the files on disk hold what they should.
    expect(
      File(p.join(path, 'a.txt')).readAsStringSync(),
      'a.txt revision 5\n' * 20,
    );
    expect(
      File(p.join(path, 'b.txt')).readAsStringSync(),
      'b.txt revision 5\n' * 20,
    );

    // And git sees a clean tree rather than files it thinks were deleted.
    expect(git(['status', '--porcelain'], cwd: path).trim(), isEmpty);
  });

  test('older revisions are still absent after the checkout', () async {
    final path = p.join(scratch.path, 'still-partial');
    await clone(url, path, filter: 'blob:none');

    // Only the tip's blobs were redeemed. Everything behind it is still owed,
    // which is the whole point of the exercise.
    expect(missingCount(path), greaterThan(0));

    final repo = Repository.open(path);
    final old = repo.resolve('HEAD~4')!;
    final tree = repo.treeOf(old)!;
    final entry = repo.lookup(tree, 'a.txt')!;
    expect(repo.objects.contains(entry.id), isFalse,
        reason: 'an old revision should still be a promise');
    repo.close();
  });

  test('a promised object can be redeemed on demand', () async {
    final path = p.join(scratch.path, 'redeem');
    await clone(url, path, filter: 'blob:none');

    var repo = Repository.open(path);
    final old = repo.resolve('HEAD~4')!;
    final entry = repo.lookup(repo.treeOf(old)!, 'a.txt')!;
    expect(repo.objects.contains(entry.id), isFalse);

    await fetchObjects(repo, repo.remotes.named('origin')!, [entry.id]);
    repo.close();

    // Reopened, because the store learned about a new pack.
    repo = Repository.open(path);
    expect(repo.objects.contains(entry.id), isTrue);
    expect(
      utf8.decode(repo.objects.readTyped<Blob>(entry.id).content),
      'a.txt revision 1\n' * 20,
    );
    repo.close();
  });

  test('redeeming an object already here asks for nothing', () async {
    final path = p.join(scratch.path, 'noop');
    await clone(url, path, filter: 'blob:none');

    final repo = Repository.open(path);
    final head = repo.headId!;
    final result =
        await fetchObjects(repo, repo.remotes.named('origin')!, [head]);
    repo.close();

    expect(result.objectsReceived, 0);
  });

  test('version 0 filters too', () async {
    await server.close(force: true);
    server = await serve(originPath, allowV2: false);
    url = 'http://${server.address.address}:${server.port}/origin';

    final path = p.join(scratch.path, 'v0');
    await clone(url, path, bare: true, filter: 'blob:none');

    expect(git(['rev-list', '--count', 'HEAD'], cwd: path).trim(), '6');
    expect(missingCount(path), greaterThan(0));
  });

  test('a server that does not offer filtering says so', () async {
    // `uploadpack.allowFilter` off is the default, and a client that sends the
    // line anyway is quietly given everything.
    git(['config', '--unset', 'uploadpack.allowFilter']);

    final path = p.join(scratch.path, 'unsupported');
    await expectLater(
      clone(url, path, bare: true, filter: 'blob:none'),
      throwsUnsupportedError,
    );
  });

  test('a filter on a local fetch is refused rather than ignored', () async {
    final path = p.join(scratch.path, 'local');
    Directory(path).createSync(recursive: true);
    final repo = Repository.init(path);
    repo.remotes.add('origin', originPath);

    await expectLater(
      fetch(repo, repo.remotes.named('origin')!, filter: 'blob:none'),
      throwsUnsupportedError,
    );
    repo.close();
  });

  test('an unfiltered clone marks no pack as promisor', () async {
    final path = p.join(scratch.path, 'ordinary');
    await clone(url, path);

    expect(packDir(path).where((n) => n.endsWith('.promisor')), isEmpty);
    expect(missingCount(path), 0);

    final repo = Repository.open(path);
    expect(repo.config['remote.origin.promisor'], isNull);
    repo.close();
  });
}
