/// Opening a repository without letting it run anything.
///
/// A repository is not only data. Its own configuration can name programs —
/// a clean filter, a signing tool, the hooks in its directory — and git runs
/// them, which is what makes git a client. Anything that opens repositories
/// it did not create is in a different position: writing a `.git/config`
/// should not be a way to run a command on the machine of whoever looks at
/// the repository.
///
/// These check the guarantee the way it would be broken: by a repository that
/// tries.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

String git(List<String> arguments, {String? cwd}) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

void write(String relative, String contents) {
  final file = File(p.join(repoPath, relative.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

File marker() => File(p.join(repoPath, '.git', 'filter-marker'));

/// A repository whose configuration runs a command when a tracked file is
/// hashed — the shape of the thing being defended against.
void repositoryThatRunsSomething() {
  git(['init', '-q', '-b', 'main']);
  git(['config', 'user.name', 'A']);
  git(['config', 'user.email', 'a@x']);
  write('old.txt', 'original\n');
  write('.gitattributes', 'old.txt filter=probe\n');
  git(['add', '-A']);
  git(['commit', '-q', '-m', 'first']);

  // Configured only after committing, so nothing above ran it.
  git(['config', 'filter.probe.clean', 'printf invoked > .git/filter-marker']);
  git(['config', 'filter.probe.required', 'true']);
  // The file differs from what is stored, so status must hash it, which is
  // where the clean filter is applied.
  write('old.txt', 'changed\n');
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_inspect');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);
  });

  tearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Read-only objects under .git survive on Windows.
    }
  });

  test('a full client runs the configured filter, as git does', () {
    repositoryThatRunsSomething();
    expect(marker().existsSync(), isFalse);

    final repo = Repository.open(repoPath);
    repo.status(trustStatCache: false);
    repo.close();

    // Not a defect: this is what git does, and a client that did not would
    // disagree with git about what is modified.
    expect(marker().existsSync(), isTrue);
  });

  test('inspection runs nothing the repository asked for', () {
    repositoryThatRunsSomething();
    expect(marker().existsSync(), isFalse);

    final repo = Repository.open(repoPath, access: RepositoryAccess.inspection);
    final status = repo.status(trustStatCache: false);
    repo.close();

    expect(marker().existsSync(), isFalse,
        reason: 'the configured filter command ran');

    // And the comparison it could not normalise is named rather than passed
    // off as an ordinary one.
    expect(status.unnormalised, ['old.txt']);
  });

  test('a driver the caller registered still runs: it is the caller\'s own',
      () {
    repositoryThatRunsSomething();

    var asked = 0;
    final repo = Repository.open(repoPath, access: RepositoryAccess.inspection);
    repo.filters['probe'] = FilterDriver(
      clean: (path, content) {
        asked++;
        return content;
      },
    );
    final status = repo.status(trustStatCache: false);
    repo.close();

    expect(asked, greaterThan(0));
    expect(marker().existsSync(), isFalse);
    // Normalised after all, by code the caller chose.
    expect(status.unnormalised, isEmpty);
  });

  test('nothing is written: not an object, not a ref, not the index', () {
    repositoryThatRunsSomething();
    final repo = Repository.open(repoPath, access: RepositoryAccess.inspection);

    expect(
      () => repo.stage('old.txt'),
      throwsA(isA<RepositoryIsReadOnly>()),
    );
    expect(
      () => repo.createBranch('nope'),
      throwsA(isA<RepositoryIsReadOnly>()),
    );
    expect(
      () => repo.checkout('main'),
      throwsA(isA<RepositoryIsReadOnly>()),
    );
    // The stores refuse as well, so a path that forgot to ask still cannot
    // write.
    expect(
      () => repo.objects.write(Blob(utf8.encode('x'))),
      throwsStateError,
    );
    expect(
      () => repo.refs.write('refs/heads/nope', repo.headId!),
      throwsStateError,
    );
    repo.close();
  });

  test('the repository is exactly as it was afterwards', () {
    repositoryThatRunsSomething();

    String snapshot() => [
          git(['rev-parse', 'HEAD']).trim(),
          git(['status', '--porcelain']),
          git(['config', '--local', '--list']),
          File(p.join(repoPath, '.git', 'index')).readAsBytesSync().length,
          File(p.join(repoPath, 'old.txt')).readAsStringSync(),
        ].join('|');

    final before = snapshot();
    final repo = Repository.open(repoPath, access: RepositoryAccess.inspection);
    repo.status(trustStatCache: false);
    repo.log().toList();
    repo.readFile('old.txt');
    repo.close();

    expect(snapshot(), before);
    expect(marker().existsSync(), isFalse);
  });

  test('no hook fires, whatever the repository put in its hooks directory',
      () {
    repositoryThatRunsSomething();
    final repo = Repository.open(repoPath, access: RepositoryAccess.inspection);
    expect(repo.hooks, same(HookRunner.none));
    repo.close();
  });

  test('a signature is reported unchecked rather than checked by a program',
      () {
    repositoryThatRunsSomething();
    final repo = Repository.open(repoPath, access: RepositoryAccess.inspection);
    final check = repo.signatureTool.verify(
      utf8.encode('payload'),
      '-----BEGIN PGP SIGNATURE-----\n-----END PGP SIGNATURE-----\n',
      VerificationRequest(
        format: SignatureFormat.openpgp,
        config: repo.config,
      ),
    );
    repo.close();

    expect(check.result, SignatureStatus.cannotCheck);
    expect(check.output, contains('inspection'));
  });

  test('a network operation is refused before it opens a connection', () async {
    repositoryThatRunsSomething();
    final other = p.join(scratch.path, 'other.git');
    Process.runSync('git', ['init', '-q', '--bare', other]);
    git(['remote', 'add', 'origin', other]);

    final repo = Repository.open(repoPath, access: RepositoryAccess.inspection);
    final remote = repo.remotes.named('origin')!;
    await expectLater(
      fetch(repo, remote),
      throwsA(isA<RepositoryIsReadOnly>()),
    );
    await expectLater(
      push(repo, remote),
      throwsA(isA<RepositoryIsReadOnly>()),
    );
    repo.close();
  });

  test('an ordinary repository is unaffected by any of this', () {
    repositoryThatRunsSomething();
    final repo = Repository.open(repoPath);
    expect(repo.isInspectionOnly, isFalse);
    expect(repo.status(trustStatCache: false).unnormalised, isEmpty);
    repo.stage('old.txt');
    expect(repo.status(trustStatCache: false).staged, isNotEmpty);
    repo.close();
  });
}
