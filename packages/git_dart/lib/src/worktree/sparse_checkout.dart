/// Sparse checkout — having only part of the repository on disk.
///
/// A large repository is often larger than any one person needs. Sparse
/// checkout is the answer that does not lie about history: every object is
/// still here and every commit is still complete, but the paths outside a
/// chosen set are simply not written to the working tree. Nothing about the
/// commits changes, which is what separates this from a partial clone — that
/// one is missing *objects*, this one is missing *files*.
///
/// The mechanism is one bit in the index. `SKIP_WORKTREE` on an entry means
/// "the working tree is not expected to hold this", and every operation that
/// compares the index to the disk has to honour it. Without that, the files
/// deliberately left out look exactly like files somebody deleted, and the
/// repository reports itself as extensively modified while being perfectly
/// clean (`index.skip-worktree`).
///
/// The patterns live in `.git/info/sparse-checkout` and are read with the
/// `.gitignore` syntax and the opposite meaning: a match *includes*. They are
/// evaluated down the path — each ancestor directory, then the path itself,
/// with the last matching pattern at each level deciding and the decision
/// carried forward. That is what makes a directory pattern cover its whole
/// subtree, and what lets a later pattern re-include a directory an earlier
/// one excluded — the mechanism cone mode is built out of.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../index/git_index.dart';
import '../config/config_writer.dart';
import '../repository.dart';
import 'ignore.dart';
import 'status.dart';

/// The sparse-checkout patterns in force, and how to read them.
class SparseCheckout {
  /// The patterns as written, in order.
  final List<String> patterns;

  /// Whether `core.sparseCheckout` is on. When it is not, everything is
  /// included however the file reads.
  final bool enabled;

  /// Whether the patterns were written in cone form.
  ///
  /// Cone mode is a restricted spelling — whole directories only — that git
  /// can match by prefix instead of by pattern. The patterns it writes mean
  /// the same thing under the general rules, so this is remembered for
  /// round-tripping the config and for [coneDirectories] rather than for
  /// matching.
  final bool cone;

  final IgnoreRules _rules;

  SparseCheckout({
    required this.patterns,
    this.enabled = true,
    this.cone = false,
  }) : _rules = IgnoreRules() {
    for (final pattern in patterns) {
      _rules.addText(pattern);
    }
  }

  /// Everything included — what a repository without sparse checkout has.
  static final SparseCheckout everything =
      SparseCheckout(patterns: const [], enabled: false);

  /// Reads the patterns and config of [repository].
  ///
  /// The file lives beside the repository rather than in it: which part of a
  /// tree somebody wants on their disk is theirs, not the project's, and is
  /// not something to commit.
  factory SparseCheckout.forRepository(Repository repository) {
    final enabled =
        repository.config.boolean('core.sparseCheckout') ?? false;
    final cone = repository.config.boolean('core.sparseCheckoutCone') ?? false;

    final file = fs.file(
      p.join(repository.commonDirectory, 'info', 'sparse-checkout'),
    );
    if (!file.existsSync()) {
      return SparseCheckout(patterns: const [], enabled: enabled, cone: cone);
    }

    return SparseCheckout(
      patterns: [
        for (final line in const LineSplitter().convert(file.readAsStringSync()))
          if (line.trim().isNotEmpty) line,
      ],
      enabled: enabled,
      cone: cone,
    );
  }

  /// Whether [path] belongs in the working tree.
  ///
  /// Walks the path from the top: each ancestor directory is decided in turn
  /// and the answer is carried down, so a pattern naming a directory covers
  /// everything under it without naming any of it. A level nothing matches
  /// leaves the decision where it was, which is what lets `/keep/` re-include
  /// a directory that `!/*/` had just excluded.
  bool includes(String path) {
    if (!enabled) return true;
    // Every pattern excludes everything else, so no patterns at all excludes
    // the whole tree — which is what git does, and is why disabling sparse
    // checkout is a separate act from emptying the file.
    if (patterns.isEmpty) return false;

    var included = false;

    final segments = path.split('/');
    for (var i = 0; i < segments.length; i++) {
      final atThisLevel = segments.take(i + 1).join('/');
      final isDirectory = i < segments.length - 1;
      final decision = _rules.decide(
        atThisLevel,
        isDirectory: isDirectory,
        exact: true,
      );
      if (decision != null) included = decision;
    }

    return included;
  }

  /// The directories a cone-form pattern list names.
  ///
  /// Empty for patterns that are not in cone form, which is not an error: a
  /// caller asking this of a general pattern list is asking a question that
  /// has no answer.
  List<String> get coneDirectories => [
        for (final pattern in patterns)
          if (pattern.startsWith('/') &&
              pattern.endsWith('/') &&
              pattern.length > 2 &&
              !pattern.startsWith('!'))
            pattern.substring(1, pattern.length - 1),
      ];
}

/// The cone-form patterns for a set of directories.
///
/// The shape is git's. `/*` takes the files at the root and `!/*/` puts back
/// the directories it just took; then, for each directory on the way down to
/// something that was asked for, `/dir/` re-includes it and `!/dir/*/` shuts
/// its *other* subdirectories out again. That second line is the part that is
/// easy to leave out and wrong to: without it, asking for `keep/sub` also
/// hands over `keep/anything-else`, because re-including `keep` re-includes
/// everything under it.
///
/// A directory that was asked for outright gets no such line — everything
/// below it is wanted. So `keep` and `keep/sub` together are just `keep`,
/// since the second is already inside the first.
List<String> conePatterns(Iterable<String> directories) {
  final requested = <String>{};
  for (final directory in directories) {
    final segments = directory.replaceAll(r'\', '/').split('/')
      ..removeWhere((segment) => segment.isEmpty);
    if (segments.isNotEmpty) requested.add(segments.join('/'));
  }

  // A directory inside another that was asked for adds nothing: the outer one
  // already carries it, and naming it would emit an exclusion that narrows
  // what the outer one was meant to include.
  final wanted = requested
      .where((directory) => !requested.any(
            (other) => other != directory && directory.startsWith('$other/'),
          ))
      .toSet();

  // Every directory the walk has to pass through on the way to a wanted one.
  final onTheWay = <String>{};
  for (final directory in wanted) {
    final segments = directory.split('/');
    for (var i = 1; i <= segments.length; i++) {
      onTheWay.add(segments.take(i).join('/'));
    }
  }

  return [
    '/*',
    '!/*/',
    for (final directory in onTheWay.toList()..sort()) ...[
      '/$directory/',
      // Passed through rather than asked for, so only its own files come with
      // it and the next line down decides which of its subdirectories do.
      if (!wanted.contains(directory)) '!/$directory/*/',
    ],
  ];
}

/// What applying a sparse checkout did.
class SparseCheckoutResult {
  /// Paths written back into the working tree.
  final List<String> restored;

  /// Paths taken out of it.
  final List<String> removed;

  /// Paths left in place despite being outside the set, because they hold
  /// changes that removing them would destroy.
  final List<String> kept;

  const SparseCheckoutResult({
    this.restored = const [],
    this.removed = const [],
    this.kept = const [],
  });

  bool get isEmpty =>
      restored.isEmpty && removed.isEmpty && kept.isEmpty;
}

/// Makes the working tree match the sparse-checkout patterns.
///
/// Sets `SKIP_WORKTREE` and removes the file for every path now outside the
/// set, and clears the bit and writes the file back for every path now inside
/// it. The index is rewritten once at the end.
///
/// A file outside the set that has been modified is left alone and reported in
/// [SparseCheckoutResult.kept] — removing it would throw away work that exists
/// nowhere else, and the request was to narrow a view, not to discard changes.
/// [force] removes it anyway.
SparseCheckoutResult applySparseCheckout(
  Repository repository, {
  bool force = false,
}) {
  final workTree = repository.workTree;
  if (workTree == null) {
    throw StateError('a bare repository has no working tree to narrow');
  }

  final index = repository.index;
  if (index == null) return const SparseCheckoutResult();

  final sparse = SparseCheckout.forRepository(repository);

  // What differs from the index right now, so a file with changes is not
  // quietly deleted for being outside the new set.
  final dirty = {
    for (final entry
        in statusOf(repository, includeUntracked: false).entries)
      entry.path,
  };

  final restored = <String>[];
  final removed = <String>[];
  final kept = <String>[];
  final entries = <IndexEntry>[];

  for (final entry in index.entries) {
    if (entry.stage != MergeStage.ordinary) {
      // A conflicted path is mid-operation and is not something to narrow.
      entries.add(entry);
      continue;
    }

    final wanted = sparse.includes(entry.path);
    final file = fs.file(
      p.join(workTree, entry.path.replaceAll('/', p.separator)),
    );

    if (wanted && entry.skipWorktree) {
      final raw = repository.objects.readRaw(entry.id);
      if (raw == null) {
        // Nothing to write it from, so the bit stays and the absence remains
        // explained rather than becoming an unexplained missing file.
        entries.add(entry);
        continue;
      }
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(
        repository.convertToWorkTree(entry.path, raw.content),
        flush: true,
      );
      restored.add(entry.path);
      entries.add(_withSkip(entry, false, file));
      continue;
    }

    if (!wanted && !entry.skipWorktree) {
      if (dirty.contains(entry.path) && !force) {
        kept.add(entry.path);
        entries.add(entry);
        continue;
      }
      if (file.existsSync()) file.deleteSync();
      removed.add(entry.path);
      entries.add(_withSkip(entry, true, null));
      continue;
    }

    entries.add(entry);
  }

  GitIndex(entries: entries)
      .writeTo(p.join(repository.gitDirectory, 'index'));

  if (removed.isNotEmpty) _pruneEmptyDirectories(workTree, removed);

  return SparseCheckoutResult(
    restored: restored,
    removed: removed,
    kept: kept,
  );
}

/// Turns sparse checkout on with [patterns] and applies it.
///
/// [cone] records that the patterns are in cone form; use [conePatterns] to
/// build them. The file is written whole rather than appended to, because a
/// half-updated pattern list describes a working tree nobody asked for.
SparseCheckoutResult setSparseCheckout(
  Repository repository,
  List<String> patterns, {
  bool cone = false,
  bool force = false,
}) {
  final file = fs.file(
    p.join(repository.commonDirectory, 'info', 'sparse-checkout'),
  )..parent.createSync(recursive: true);
  file.writeAsStringSync(
    patterns.map((pattern) => '$pattern\n').join(),
    flush: true,
  );

  final config = ConfigWriter(repository.commonDirectory);
  config.set('core.sparseCheckout', 'true', ConfigScope.local);
  config.set(
    'core.sparseCheckoutCone',
    cone ? 'true' : 'false',
    ConfigScope.local,
  );
  repository.reloadConfig();

  return applySparseCheckout(repository, force: force);
}

/// Turns sparse checkout off and puts the whole tree back.
///
/// The pattern file is left alone: it is what the person had, and turning the
/// feature off is not a reason to forget which part of the tree they wanted.
SparseCheckoutResult disableSparseCheckout(Repository repository) {
  ConfigWriter(repository.commonDirectory)
      .set('core.sparseCheckout', 'false', ConfigScope.local);
  repository.reloadConfig();
  return applySparseCheckout(repository);
}

IndexEntry _withSkip(IndexEntry entry, bool skip, GitFsFile? file) {
  // A file that was just written has stat data worth recording; one that was
  // just removed has none, and git zeroes it so the entry cannot appear to
  // match something on disk.
  final stat = file != null && file.existsSync() ? file.statSync() : null;
  final seconds =
      stat == null ? 0 : stat.modified.millisecondsSinceEpoch ~/ 1000;

  return IndexEntry(
    path: entry.path,
    id: entry.id,
    mode: entry.mode,
    ctimeSeconds: skip ? 0 : seconds,
    ctimeNanoseconds: 0,
    mtimeSeconds: skip ? 0 : seconds,
    mtimeNanoseconds: 0,
    device: 0,
    inode: 0,
    uid: 0,
    gid: 0,
    size: skip ? 0 : (stat?.size ?? entry.size),
    stage: entry.stage,
    assumeValid: entry.assumeValid,
    intentToAdd: entry.intentToAdd,
    skipWorktree: skip,
  );
}

/// Removes the directories that emptying paths out of the tree left behind.
void _pruneEmptyDirectories(String workTree, List<String> removed) {
  final directories = <String>{};
  for (final path in removed) {
    final segments = path.split('/');
    for (var i = 1; i < segments.length; i++) {
      directories.add(segments.take(i).join('/'));
    }
  }

  // Deepest first, so a directory is considered after the ones inside it have
  // had their chance to go.
  final ordered = directories.toList()
    ..sort((a, b) => b.split('/').length.compareTo(a.split('/').length));

  for (final relative in ordered) {
    final directory = fs.directory(
      p.join(workTree, relative.replaceAll('/', p.separator)),
    );
    if (!directory.existsSync()) continue;
    if (directory.listSync().isEmpty) directory.deleteSync();
  }
}
