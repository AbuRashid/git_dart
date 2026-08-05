/// Authenticating to an HTTP remote.
///
/// The server here is git behind a check for the `Authorization` header, which
/// is what a real host does. A 401 must arrive as a question the caller can
/// answer, not as a failure — the difference decides whether the application
/// can offer a sign-in or only an error message.
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

/// A host that wants Basic auth, like the one this was built for.
Future<HttpServer> serve(
  String repositoryPath, {
  required String username,
  required String password,
  List<String>? seenAuthorization,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final expected =
      'Basic ${base64.encode(utf8.encode('$username:$password'))}';

  server.listen((request) async {
    final offered = request.headers.value(HttpHeaders.authorizationHeader);
    seenAuthorization?.add(offered ?? '');

    if (offered != expected) {
      request.response
        ..statusCode = 401
        ..headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Basic realm="Gitea"',
        );
      await request.response.close();
      return;
    }

    try {
      if (request.method == 'GET' && request.uri.path.endsWith('/info/refs')) {
        final process = await Process.start('git', [
          'upload-pack',
          '--stateless-rpc',
          '--advertise-refs',
          repositoryPath,
        ]);
        unawaited(process.stderr.drain<void>());
        final body = await process.stdout
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
        request.response
          ..statusCode = 200
          ..add(PktLine.text('# service=git-upload-pack\n').encode())
          ..add(PktLine.flush.encode())
          ..add(body);
        await request.response.close();
        return;
      }

      if (request.method == 'POST' &&
          request.uri.path.endsWith('/git-upload-pack')) {
        final input = await request
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
        final process = await Process.start(
          'git',
          ['upload-pack', '--stateless-rpc', repositoryPath],
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
      request.response.statusCode = 500;
      await request.response.close();
    }
  });

  return server;
}

String emptyClone(String name) {
  final path = p.join(scratch.path, name);
  Directory(path).createSync(recursive: true);
  Repository.init(path).close();
  return path;
}

void main() {
  late HttpServer server;
  late String host;
  late List<String> seen;

  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('git_dart_auth');
    originPath = p.join(scratch.path, 'origin');
    Directory(originPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    File(p.join(originPath, 'a.txt')).writeAsStringSync('one\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'first']);

    seen = [];
    server = await serve(
      originPath,
      username: 'someone',
      password: 'a-token',
      seenAuthorization: seen,
    );
    host = 'http://${server.address.address}:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
    scratch.deleteSync(recursive: true);
  });

  test('a remote that wants credentials asks rather than failing', () async {
    final repo = Repository.open(emptyClone('anonymous'));
    repo.remotes.add('origin', '$host/origin.git');

    await expectLater(
      fetch(repo, repo.remotes.named('origin')!),
      throwsA(
        isA<AuthenticationRequired>()
            .having((e) => e.wereRejected, 'wereRejected', isFalse)
            .having((e) => e.realm, 'realm', 'Gitea'),
      ),
    );
    repo.close();
  });

  test('credentials that are supplied get through', () async {
    final path = emptyClone('signed-in');
    final repo = Repository.open(path);
    repo.remotes.add('origin', '$host/origin.git');

    final result = await fetch(
      repo,
      repo.remotes.named('origin')!,
      credentials: const Credentials(
        username: 'someone',
        password: 'a-token',
      ),
    );

    expect(result.objectsReceived, greaterThan(0));
    expect(
      repo.refs.resolve('refs/remotes/origin/main')!.hex,
      git(['rev-parse', 'main']).trim(),
    );
    // Sent on both requests, not just the first: a server that challenges the
    // advertisement challenges the pack too.
    expect(seen.where((h) => h.startsWith('Basic')).length, greaterThan(1));
    repo.close();
  });

  test('the wrong secret is reported as refused, not as missing', () async {
    final repo = Repository.open(emptyClone('wrong'));
    repo.remotes.add('origin', '$host/origin.git');

    await expectLater(
      fetch(
        repo,
        repo.remotes.named('origin')!,
        credentials: const Credentials(
          username: 'someone',
          password: 'not-the-token',
        ),
      ),
      throwsA(
        isA<AuthenticationRequired>()
            .having((e) => e.wereRejected, 'wereRejected', isTrue),
      ),
    );
    repo.close();
  });

  test('a user:password in the URL is used and not sent in the path',
      () async {
    final path = emptyClone('url-credentials');
    final repo = Repository.open(path);
    // What `git remote add https://user:token@host/x.git` leaves behind.
    repo.remotes.add(
      'origin',
      'http://someone:a-token@${server.address.address}:${server.port}'
          '/origin.git',
    );

    final result = await fetch(repo, repo.remotes.named('origin')!);
    expect(result.objectsReceived, greaterThan(0));
    expect(seen.every((h) => h.startsWith('Basic')), isTrue);
    repo.close();
  });

  test('a username alone in the URL still needs a secret', () async {
    final repo = Repository.open(emptyClone('name-only'));
    // The shape from the report: the name is in the URL, the token is not.
    repo.remotes.add(
      'origin',
      'http://someone@${server.address.address}:${server.port}/origin.git',
    );

    await expectLater(
      fetch(repo, repo.remotes.named('origin')!),
      throwsA(isA<AuthenticationRequired>()),
    );

    // And the name is there to offer back in the prompt.
    expect(
      splitCredentials(repo.remotes.named('origin')!.url).credentials?.username,
      'someone',
    );
    repo.close();
  });

  test('pushing asks for credentials the same way', () async {
    final repo = Repository.open(emptyClone('push-auth'));
    repo.remotes.add('origin', '$host/origin.git');
    // Something to push.
    repo.refs.write('refs/heads/main', ObjectId.fromHex(
      git(['rev-parse', 'main']).trim(),
    ));

    await expectLater(
      push(repo, repo.remotes.named('origin')!, branches: ['main']),
      throwsA(isA<AuthenticationRequired>()),
    );
    repo.close();
  });
}
