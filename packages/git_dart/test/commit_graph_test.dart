/// The commit-graph, both directions, checked against git.
///
/// This is a cache, which makes it unusually dangerous: a wrong answer from a
/// cache looks exactly like a right one, and nothing downstream re-derives it.
/// So the tests come in pairs — read what git wrote, and have git read what we
/// wrote — and every walk that consults it is checked against the same walk
/// with the cache removed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

/// Commits are dated a minute apart rather than all within one second.
///
/// Topological order is not unique: among commits that no path connects, any
/// order is valid, and both git and this library break the tie by date. Making
/// every commit share a second would leave the order genuinely ambiguous, so
/// comparing ours to git's would be testing which arbitrary answer each
/// happened to pick. Distinct times make the expected order the only one.
var _clock = 1700000000;

String git(List<String> arguments, {String? cwd}) {
  final when = '${_clock} +0000';
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: cwd ?? repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
    environment: {
      'GIT_AUTHOR_DATE': when,
      'GIT_COMMITTER_DATE': when,
    },
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

/// [into] names the file, so two branches can be built that merge cleanly.
/// Both appending to one file is a conflict — neither side's line has a reason
/// to come first — which is a merge this fixture does not want.
void commit(String message, {String into = 'f.txt'}) {
  // Appended by reading and rewriting: `FileMode` here means a tree entry's
  // mode, not dart:io's, and the collision is not worth an import prefix.
  final file = File(p.join(repoPath, into));
  final existing = file.existsSync() ? file.readAsStringSync() : '';
  file.writeAsStringSync('$existing$message\n');
  git(['add', '-A']);
  _clock += 60;
  git(['commit', '-q', '-m', message]);
}

String graphPath() =>
    p.join(repoPath, '.git', 'objects', 'info', 'commit-graph');

/// main and side diverge, meet, and carry on — enough shape that generation
/// numbers and merges both matter.
void buildHistory() {
  for (var i = 0; i < 5; i++) {
    commit('base $i');
  }
  git(['branch', 'side']);
  for (var i = 0; i < 4; i++) {
    commit('main $i', into: 'main.txt');
  }
  git(['checkout', '-q', 'side']);
  for (var i = 0; i < 6; i++) {
    commit('side $i', into: 'side.txt');
  }
  git(['checkout', '-q', 'main']);
  _clock += 60;
  git(['merge', '-q', '--no-edit', 'side']);
  for (var i = 0; i < 3; i++) {
    commit('after $i');
  }
}

/// Clears the read-only bit git puts on a commit-graph.
///
/// git writes the file 0444 on every platform, so rewriting it to corrupt it
/// is refused until the bit goes. Each platform spells that differently, and
/// neither spelling exists on the other.
void _makeWritable(String path) {
  if (Platform.isWindows) {
    Process.runSync('attrib', ['-R', path]);
  } else {
    Process.runSync('chmod', ['u+w', path]);
  }
}

void main() {
  setUp(() {
    _clock = 1700000000;
    scratch = Directory.systemTemp.createTempSync('git_dart_cgraph');
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
      // git writes the graph read-only.
    }
  });

  // -------------------------------------------------------------------------
  group('reading what git wrote', () {
    test('every commit, its parents and its tree', () {
      buildHistory();
      git(['commit-graph', 'write', '--reachable']);

      final repo = Repository.open(repoPath);
      final graph = repo.commitGraph;
      expect(graph, isNotNull, reason: 'git just wrote one');

      final expected = git(['rev-list', '--all']).trim().split('\n');
      expect(graph!.count, expected.length);

      for (final hex in expected) {
        final id = ObjectId.fromHex(hex);
        final entry = graph.entryFor(id);
        expect(entry, isNotNull, reason: '$hex is missing from the graph');

        final commit = repo.objects.readTyped<Commit>(id);
        expect(entry!.tree, commit.tree);
        expect(entry.parents, commit.parents);
        expect(entry.commitTime, commit.committer.seconds);
      }
      repo.close();
    });

    test('a merge commit keeps both parents in order', () {
      buildHistory();
      git(['commit-graph', 'write', '--reachable']);

      final merge = git(['rev-list', '--merges', '-n', '1', 'HEAD']).trim();
      final parents = git(['rev-list', '--parents', '-n', '1', merge])
          .trim()
          .split(' ')
          .skip(1)
          .toList();
      expect(parents, hasLength(2));

      final repo = Repository.open(repoPath);
      final entry = repo.commitGraph!.entryFor(ObjectId.fromHex(merge))!;
      repo.close();

      // Order is meaningful: the first parent is the branch merged into.
      expect(entry.parents.map((p) => p.hex).toList(), parents);
    });

    test('an octopus merge is read from the extra edge chunk', () {
      // Three parents, so the second slot points into EDGE rather than
      // naming a commit.
      commit('root');
      git(['branch', 'one']);
      git(['branch', 'two']);
      git(['checkout', '-q', 'one']);
      commit('on one', into: 'one.txt');
      git(['checkout', '-q', 'two']);
      commit('on two', into: 'two.txt');
      git(['checkout', '-q', 'main']);
      commit('on main', into: 'main.txt');
      _clock += 60;
      git(['merge', '-q', '--no-edit', 'one', 'two']);
      git(['commit-graph', 'write', '--reachable']);

      final merge = git(['rev-parse', 'HEAD']).trim();
      final parents = git(['rev-list', '--parents', '-n', '1', merge])
          .trim()
          .split(' ')
          .skip(1)
          .toList();
      expect(parents, hasLength(3));

      final repo = Repository.open(repoPath);
      final entry = repo.commitGraph!.entryFor(ObjectId.fromHex(merge))!;
      repo.close();

      expect(entry.parents.map((p) => p.hex).toList(), parents);
    });

    test('generations rise from parent to child', () {
      buildHistory();
      git(['commit-graph', 'write', '--reachable']);

      final repo = Repository.open(repoPath);
      final graph = repo.commitGraph!;

      // The one property everything else leans on.
      for (final entry in graph.entries()) {
        for (final parent in entry.parents) {
          final above = graph.entryFor(parent);
          if (above == null) continue;
          expect(above.generation, lessThan(entry.generation),
              reason: '${parent.hex} is a parent of ${entry.id.hex}');
        }
      }
      repo.close();
    });

    test('a missing graph is not an error', () {
      buildHistory();
      final repo = Repository.open(repoPath);
      expect(repo.commitGraph, isNull);
      // And everything still works.
      expect(repo.log().length, 19);
      repo.close();
    });

    test('a corrupt graph is ignored rather than fatal', () {
      buildHistory();
      git(['commit-graph', 'write', '--reachable']);

      final bytes = File(graphPath()).readAsBytesSync();
      bytes[4] = 99; // an impossible version
      final broken = File(graphPath());
      _makeWritable(graphPath());
      broken.writeAsBytesSync(bytes);

      // A cache that cannot be read is a cache that is not used. Refusing to
      // open the repository over it would let an optimisation decide whether
      // the repository works.
      final repo = Repository.open(repoPath);
      expect(repo.commitGraph, isNull);
      expect(repo.log().length, 19);
      repo.close();
    });
  });

  // -------------------------------------------------------------------------
  group('writing one git accepts', () {
    test('git commit-graph verify passes', () {
      buildHistory();

      final repo = Repository.open(repoPath);
      final written = repo.writeCommitGraph();
      repo.close();

      expect(written, 19);
      expect(File(graphPath()).existsSync(), isTrue);

      // git's own checker: the header, the chunk table, the fanout, the
      // ordering, every parent position and every generation number.
      git(['commit-graph', 'verify']);
      git(['fsck', '--no-progress']);
      // And it is actually used rather than merely tolerated.
      expect(git(['rev-list', '--count', 'HEAD']).trim(), '19');
    });

    test('git verifies a graph with an octopus merge in it', () {
      commit('root');
      git(['branch', 'one']);
      git(['branch', 'two']);
      git(['checkout', '-q', 'one']);
      commit('on one', into: 'one.txt');
      git(['checkout', '-q', 'two']);
      commit('on two', into: 'two.txt');
      git(['checkout', '-q', 'main']);
      commit('on main', into: 'main.txt');
      _clock += 60;
      git(['merge', '-q', '--no-edit', 'one', 'two']);

      final repo = Repository.open(repoPath);
      repo.writeCommitGraph();
      repo.close();

      git(['commit-graph', 'verify']);
    });

    test('what we write, we read back identically', () {
      buildHistory();
      final repo = Repository.open(repoPath);
      repo.writeCommitGraph();

      final graph = repo.commitGraph!;
      for (final entry in graph.entries()) {
        final commit = repo.objects.readTyped<Commit>(entry.id);
        expect(entry.tree, commit.tree);
        expect(entry.parents, commit.parents);
        expect(entry.commitTime, commit.committer.seconds);
      }
      repo.close();
    });

    test('our generations match the ones git computes', () {
      buildHistory();

      // Ours.
      var repo = Repository.open(repoPath);
      repo.writeCommitGraph();
      final ours = {
        for (final entry in repo.commitGraph!.entries())
          entry.id.hex: entry.generation,
      };
      repo.close();

      // git's, from a graph it wrote itself.
      _makeWritable(graphPath());
      File(graphPath()).deleteSync();
      git(['commit-graph', 'write', '--reachable']);

      repo = Repository.open(repoPath);
      final theirs = {
        for (final entry in repo.commitGraph!.entries())
          entry.id.hex: entry.generation,
      };
      repo.close();

      expect(ours, theirs);
    });

    test('a repository with no commits writes nothing', () {
      final repo = Repository.open(repoPath);
      expect(repo.writeCommitGraph(), 0);
      expect(File(graphPath()).existsSync(), isFalse);
      repo.close();
    });
  });

  // -------------------------------------------------------------------------
  group('the walks that use it', () {
    /// Runs [body] both with and without a commit-graph, and insists the
    /// answers match. The cache must never change what is true.
    T bothWays<T>(T Function(Repository) body) {
      var repo = Repository.open(repoPath);
      final without = body(repo);
      repo.writeCommitGraph();
      repo.close();

      repo = Repository.open(repoPath);
      expect(repo.commitGraph, isNotNull);
      final with_ = body(repo);
      repo.close();

      expect(with_, without, reason: 'the cache changed the answer');
      return with_;
    }

    test('is-ancestor agrees with git, cache or no cache', () {
      buildHistory();
      final head = git(['rev-parse', 'HEAD']).trim();
      final old = git(['rev-parse', 'HEAD~10']).trim();
      final side = git(['rev-parse', 'side']).trim();

      final answers = bothWays((repo) => [
            repo.isAncestorOf(ObjectId.fromHex(old), ObjectId.fromHex(head)),
            repo.isAncestorOf(ObjectId.fromHex(head), ObjectId.fromHex(old)),
            repo.isAncestorOf(ObjectId.fromHex(side), ObjectId.fromHex(head)),
            repo.isAncestorOf(ObjectId.fromHex(head), ObjectId.fromHex(side)),
          ]);

      bool gitSays(String a, String b) =>
          Process.runSync('git', ['merge-base', '--is-ancestor', a, b],
                  workingDirectory: repoPath)
              .exitCode ==
          0;

      expect(answers, [
        gitSays(old, head),
        gitSays(head, old),
        gitSays(side, head),
        gitSays(head, side),
      ]);
      expect(answers[0], isTrue);
      expect(answers[1], isFalse);
    });

    test('ahead and behind agree with git, cache or no cache', () {
      buildHistory();
      // Move side on, so the two have genuinely diverged.
      git(['checkout', '-q', 'side']);
      commit('side later', into: 'side.txt');
      commit('side later again', into: 'side.txt');
      git(['checkout', '-q', 'main']);

      final counted = bothWays((repo) {
        final ours = repo.refs.resolve('refs/heads/main')!;
        final theirs = repo.refs.resolve('refs/heads/side')!;
        final result = repo.countAheadBehind(ours, theirs)!;
        return [result.ahead, result.behind];
      });

      final fromGit = git(['rev-list', '--left-right', '--count',
              'main...side'])
          .trim()
          .split(RegExp(r'\s+'))
          .map(int.parse)
          .toList();
      expect(counted, fromGit);
    });

    test('merge-base agrees with git, cache or no cache', () {
      buildHistory();
      git(['checkout', '-q', 'side']);
      commit('side later', into: 'side.txt');
      git(['checkout', '-q', 'main']);

      final bases = bothWays((repo) {
        final ours = repo.refs.resolve('refs/heads/main')!;
        final theirs = repo.refs.resolve('refs/heads/side')!;
        return mergeBases(repo, ours, theirs).map((b) => b.hex).toList()
          ..sort();
      });

      final fromGit = git(['merge-base', '--all', 'main', 'side'])
          .trim()
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList()
        ..sort();
      expect(bases, fromGit);
    });

    test('topological order matches git log --topo-order', () {
      buildHistory();

      final ours = bothWays((repo) =>
          repo.logTopological().map((c) => c.id.hex).toList());
      final theirs =
          git(['log', '--topo-order', '--format=%H']).trim().split('\n');

      expect(ours, theirs);
    });

    test('topological order never shows a child after its parent', () {
      buildHistory();
      final repo = Repository.open(repoPath);
      repo.writeCommitGraph();
      repo.close();

      final again = Repository.open(repoPath);
      final order = again.logTopological().map((c) => c.id).toList();
      final position = {
        for (var i = 0; i < order.length; i++) order[i]: i,
      };

      for (final id in order) {
        final commit = again.objects.readTyped<Commit>(id);
        for (final parent in commit.parents) {
          final at = position[parent];
          if (at == null) continue;
          expect(at, greaterThan(position[id]!),
              reason: 'parent ${parent.hex} came before its child ${id.hex}');
        }
      }
      again.close();
    });

    test('a graph missing some commits still gives the right answer', () {
      // The graph is written, then history moves on. Every walk has to cope
      // with a cache that covers only part of what it is asked about.
      buildHistory();
      var repo = Repository.open(repoPath);
      repo.writeCommitGraph();
      final covered = repo.commitGraph!.count;
      repo.close();

      commit('after the graph was written');
      commit('and another');

      repo = Repository.open(repoPath);
      expect(repo.commitGraph!.count, covered);
      expect(repo.commitGraph!.contains(repo.headId!), isFalse);

      final head = repo.headId!;
      final old = repo.resolve('HEAD~12')!;
      expect(repo.isAncestorOf(old, head), isTrue);
      expect(repo.isAncestorOf(head, old), isFalse);
      expect(repo.logTopological().length, 21);
      repo.close();

      expect(
        git(['log', '--topo-order', '--format=%H']).trim().split('\n').length,
        21,
      );
    });
  });
}
