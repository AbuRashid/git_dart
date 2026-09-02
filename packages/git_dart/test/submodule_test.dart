/// Submodules, checked against `git submodule status`.
///
/// Nothing about a submodule is in one place: the tree holds a commit name,
/// `.gitmodules` holds the URL, and whether anything was ever cloned is a
/// question about the working tree. A reader that consults only the first sees
/// an empty directory it cannot explain, which is exactly what this exists to
/// stop.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;
late String innerPath;

var _clock = 1700000000;

String git(List<String> arguments, {String? cwd}) {
  final when = '$_clock +0000';
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: {
      'GIT_AUTHOR_DATE': when,
      'GIT_COMMITTER_DATE': when,
      // Adding a submodule from a local path is refused by default, because
      // doing it from an untrusted repository is a known attack. This is a
      // fixture pointing at a directory the test just made.
      'GIT_ALLOW_PROTOCOL': 'file:https:http:ssh',
    },
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// A repository to be used as the submodule.
String makeInner() {
  final path = p.join(scratch.path, 'inner');
  Directory(path).createSync(recursive: true);
  git(['init', '-q', '-b', 'main'], cwd: path);
  git(['config', 'user.name', 'A'], cwd: path);
  git(['config', 'user.email', 'a@x'], cwd: path);
  File(p.join(path, 'inner.txt')).writeAsStringSync('inner content\n');
  git(['add', '-A'], cwd: path);
  git(['commit', '-q', '-m', 'inner first'], cwd: path);
  return path;
}

void addSubmodule(String at) {
  final url = 'file:///${innerPath.replaceAll(r'\', '/')}';
  git(['-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', url, at]);
  _clock += 60;
  git(['commit', '-q', '-m', 'add submodule']);
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_submodule');
    repoPath = p.join(scratch.path, 'outer');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);
    File(p.join(repoPath, 'top.txt')).writeAsStringSync('top level\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'first']);

    innerPath = makeInner();
  });

  tearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // git leaves read-only files in the submodule's object store.
    }
  });

  test('a submodule is found with its path, url and recorded commit', () {
    addSubmodule('vendor/lib');

    final repo = Repository.open(repoPath);
    final modules = submodulesOf(repo);
    repo.close();

    expect(modules, hasLength(1));
    final module = modules.single;
    expect(module.path, 'vendor/lib');
    expect(module.name, 'vendor/lib');
    expect(module.url, contains('inner'));

    // The tree records the inner repository's commit, which is not an object
    // this repository holds.
    final innerHead = git(['rev-parse', 'HEAD'], cwd: innerPath).trim();
    expect(module.recorded!.hex, innerHead);

    final outer = Repository.open(repoPath);
    expect(outer.objects.contains(module.recorded!), isFalse,
        reason: 'a gitlink names a commit that lives elsewhere');
    outer.close();
  });

  test('a freshly added submodule is at the commit it should be', () {
    addSubmodule('vendor/lib');

    final repo = Repository.open(repoPath);
    final module = submodulesOf(repo).single;
    repo.close();

    expect(module.state, SubmoduleState.current);
    expect(module.isInitialised, isTrue);
    expect(module.checkedOut, module.recorded);
    // git prints a leading space for exactly this state.
    expect(module.statusSigil, ' ');
    // Not trimmed: the sigil git prints *is* the leading character.
    expect(git(['submodule', 'status']), startsWith(' '));
  });

  test('a submodule moved off its recorded commit is reported as moved', () {
    addSubmodule('vendor/lib');

    // A new commit inside the submodule that the outer tree does not know
    // about — the ordinary state while someone is working in there.
    final inside = p.join(repoPath, 'vendor', 'lib');
    File(p.join(inside, 'inner.txt')).writeAsStringSync('changed\n');
    _clock += 60;
    git(['add', '-A'], cwd: inside);
    git(['commit', '-q', '-m', 'moved on'], cwd: inside);

    final repo = Repository.open(repoPath);
    final module = submodulesOf(repo).single;
    repo.close();

    expect(module.state, SubmoduleState.moved);
    expect(module.checkedOut, isNot(module.recorded));
    expect(module.statusSigil, '+');
    expect(git(['submodule', 'status']), startsWith('+'));
  });

  test('a submodule that was never cloned is reported as not initialised', () {
    addSubmodule('vendor/lib');

    // What a fresh clone of the outer repository looks like: the gitlink and
    // `.gitmodules` are there, the checkout is not.
    final fresh = p.join(scratch.path, 'fresh');
    git(['clone', '-q', repoPath, fresh], cwd: scratch.path);

    final repo = Repository.open(fresh);
    final module = submodulesOf(repo).single;
    repo.close();

    expect(module.state, SubmoduleState.notInitialised);
    expect(module.isInitialised, isFalse);
    expect(module.checkedOut, isNull);
    expect(module.recorded, isNotNull);
    expect(module.url, isNotNull);
    expect(module.statusSigil, '-');
    expect(git(['submodule', 'status'], cwd: fresh), startsWith('-'));
  });

  test('the submodule can be opened as a repository of its own', () {
    addSubmodule('vendor/lib');

    final repo = Repository.open(repoPath);
    final module = submodulesOf(repo).single;
    final inner = openSubmodule(repo, module);
    repo.close();

    expect(inner, isNotNull);
    // git keeps the submodule's git directory under `.git/modules` and leaves
    // a `.git` file behind, which discovery has to follow.
    expect(inner!.headId, module.recorded);
    expect(inner.log().length, 1);
    expect(
      utf8.decode(inner.readFile('inner.txt')!),
      'inner content\n',
    );
    inner.close();
  });

  test('a gitlink with no description is reported rather than dropped', () {
    // A tree can hold mode 160000 with nothing in `.gitmodules` to say where
    // it came from. Legal, and it means nobody can clone it.
    addSubmodule('vendor/lib');
    File(p.join(repoPath, '.gitmodules')).deleteSync();
    git(['add', '-A']);
    _clock += 60;
    git(['commit', '-q', '-m', 'drop gitmodules']);

    final repo = Repository.open(repoPath);
    final module = submodulesOf(repo).single;
    repo.close();

    expect(module.state, SubmoduleState.undescribed);
    expect(module.url, isNull);
    expect(module.recorded, isNotNull);
  });

  test('a repository with no submodules has none', () {
    final repo = Repository.open(repoPath);
    expect(submodulesOf(repo), isEmpty);
    repo.close();
  });

  test('several submodules are listed by path', () {
    addSubmodule('b/second');
    addSubmodule('a/first');

    final repo = Repository.open(repoPath);
    final modules = submodulesOf(repo);
    repo.close();

    expect(modules.map((m) => m.path), ['a/first', 'b/second']);
    expect(modules.every((m) => m.state == SubmoduleState.current), isTrue);
    expect(
      git(['submodule', 'status']).trim().split('\n'),
      hasLength(2),
    );
  });

  test('submodules are read as of an older commit', () {
    final before = git(['rev-parse', 'HEAD']).trim();
    addSubmodule('vendor/lib');

    final repo = Repository.open(repoPath);
    // It exists now and did not exist then.
    expect(submodulesOf(repo), hasLength(1));
    expect(submodulesOf(repo, at: ObjectId.fromHex(before)), isEmpty);
    repo.close();
  });

  test('the walks step over a gitlink rather than into it', () {
    addSubmodule('vendor/lib');

    final repo = Repository.open(repoPath);
    final module = submodulesOf(repo).single;

    // The recorded commit is not this repository's object, so reachability
    // must not chase it — doing so would report every submodule as corrupt.
    final reachable = repo.reachable([repo.headId!]);
    expect(reachable, isNot(contains(module.recorded)));
    repo.close();

    // And git agrees the outer repository is sound.
    git(['fsck', '--no-progress']);
  });
}
