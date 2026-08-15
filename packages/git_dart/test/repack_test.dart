/// Repacking and garbage collection, checked against git.
///
/// The dangerous half is not the packing, it is deciding what may go. A
/// collector that walks only the refs will happily delete the commit a branch
/// was reset off ten seconds ago — reachable from nothing, and the one thing
/// the reflog exists to keep findable. So most of this is about what survives.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

String git(List<String> arguments) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

void write(String name, String contents) =>
    File(p.join(repoPath, name)).writeAsStringSync(contents);

int countLoose() =>
    Directory(p.join(repoPath, '.git', 'objects'))
        .listSync()
        .whereType<Directory>()
        .where((d) => p.basename(d.path).length == 2)
        .fold(0, (total, d) => total + d.listSync().length);

int countPacks() {
  final directory = Directory(p.join(repoPath, '.git', 'objects', 'pack'));
  if (!directory.existsSync()) return 0;
  return directory
      .listSync()
      .where((e) => e.path.endsWith('.pack'))
      .length;
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_repack');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    for (var i = 0; i < 8; i++) {
      write('a.txt', List.generate(i + 1, (n) => 'line $n\n').join());
      write('b$i.txt', 'file $i\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'commit $i']);
    }
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('packs the loose objects and removes them', () {
    expect(countLoose(), greaterThan(0));

    final repo = Repository.open(repoPath);
    final result = repack(repo);
    repo.close();

    expect(result.packed, greaterThan(0));
    expect(result.looseRemoved, greaterThan(0));
    expect(countLoose(), 0);
    expect(countPacks(), 1);

    // The only opinion that counts: git can still read the whole repository.
    git(['fsck', '--no-progress']);
    expect(git(['rev-list', '--count', 'HEAD']).trim(), '8');
    expect(git(['cat-file', 'blob', 'HEAD:b3.txt']), 'file 3\n');
  });

  test('everything is still readable through our own reader', () {
    var repo = Repository.open(repoPath);
    final before = repo.reachable([repo.headId!]);
    repack(repo);
    repo.close();

    repo = Repository.open(repoPath);
    for (final id in before) {
      expect(repo.objects.contains(id), isTrue, reason: '$id went missing');
      final raw = repo.objects.readRaw(id)!;
      expect(hashObject(raw.kind, raw.content), id);
    }
    expect(repo.log().length, 8);
    repo.close();
  });

  test('a repack of an already packed repository supersedes the old pack', () {
    var repo = Repository.open(repoPath);
    repack(repo);
    repo.close();

    write('new.txt', 'something new\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'after packing']);

    repo = Repository.open(repoPath);
    final second = repack(repo);
    repo.close();

    // The new pack holds everything the old one did, so the old one goes
    // rather than accumulating.
    expect(second.packsRemoved, 1);
    expect(countPacks(), 1);
    expect(countLoose(), 0);
    git(['fsck', '--no-progress']);
    expect(git(['rev-list', '--count', 'HEAD']).trim(), '9');
  });

  test('gc keeps a commit the reflog still names', () {
    var repo = Repository.open(repoPath);
    final lost = repo.headId!;
    reset(repo, repo.resolve('HEAD~2')!, mode: ResetMode.hard);

    // Unreachable from every ref, and the reflog remembers it.
    expect(repo.log().map((c) => c.id), isNot(contains(lost)));
    expect(repo.resolve('HEAD@{1}'), lost);

    gc(repo);
    repo.close();

    // Still here, so the reset is still reversible — which is the whole
    // bargain the reflog offers.
    repo = Repository.open(repoPath);
    expect(repo.objects.contains(lost), isTrue);
    expect(repo.resolve('HEAD@{1}'), lost);
    repo.close();

    expect(git(['cat-file', '-t', lost.hex]).trim(), 'commit');
    git(['reset', '-q', '--hard', lost.hex]);
    expect(git(['rev-list', '--count', 'HEAD']).trim(), '8');
  });

  test('gc drops an object nothing can reach at all', () {
    final repo = Repository.open(repoPath);
    // A blob written and never referenced by anything: no tree, no index, no
    // reflog. Nothing can name it once this returns.
    final orphan = repo.objects.write(Blob(utf8.encode('unreferenced\n')));
    expect(repo.objects.contains(orphan), isTrue);
    expect(unreachableObjects(repo), contains(orphan));

    final result = gc(repo);
    repo.close();

    expect(result.pruned, greaterThan(0));

    final after = Repository.open(repoPath);
    expect(after.objects.contains(orphan), isFalse);
    after.close();
    git(['fsck', '--no-progress']);
  });

  test('a repack without pruning keeps the unreachable object', () {
    var repo = Repository.open(repoPath);
    final orphan = repo.objects.write(Blob(utf8.encode('kept anyway\n')));
    repack(repo);
    repo.close();

    repo = Repository.open(repoPath);
    expect(repo.objects.contains(orphan), isTrue);
    repo.close();
  });

  test('a staged but uncommitted blob survives gc', () {
    write('staged.txt', 'staged and not committed\n');
    final repo = Repository.open(repoPath);
    repo.stage('staged.txt');
    final staged = repo.index!.entryFor('staged.txt')!.id;

    gc(repo);
    repo.close();

    // The index is the only thing naming it, and it is enough.
    final after = Repository.open(repoPath);
    expect(after.objects.contains(staged), isTrue);
    after.close();
    expect(git(['diff', '--cached', '--name-only']).trim(), 'staged.txt');
    git(['fsck', '--no-progress']);
  });

  test('a stash survives gc', () {
    write('a.txt', 'work in progress\n');
    var repo = Repository.open(repoPath);
    final stash = stashSave(repo)!;

    gc(repo);
    repo.close();

    repo = Repository.open(repoPath);
    expect(repo.objects.contains(stash), isTrue);
    expect(stashList(repo), hasLength(1));
    expect(stashApply(repo), MergeOutcome.merged);
    repo.close();

    expect(File(p.join(repoPath, 'a.txt')).readAsStringSync(),
        'work in progress\n');
  });

  test('a tag keeps what it points at', () {
    var repo = Repository.open(repoPath);
    final tagged = repo.resolve('HEAD~3')!;
    repo.createTag('keepme', at: tagged, message: 'annotated');
    reset(repo, repo.resolve('HEAD~1')!, mode: ResetMode.hard);
    gc(repo);
    repo.close();

    repo = Repository.open(repoPath);
    expect(repo.objects.contains(tagged), isTrue);
    repo.close();
    expect(git(['rev-parse', 'keepme^{commit}']).trim(), tagged.hex);
  });

  test('the pack we leave behind is one git verifies', () {
    final repo = Repository.open(repoPath);
    repack(repo);
    repo.close();

    final index = Directory(p.join(repoPath, '.git', 'objects', 'pack'))
        .listSync()
        .map((e) => e.path)
        .firstWhere((path) => path.endsWith('.idx'));
    git(['verify-pack', '-v', index]);
  });
}
