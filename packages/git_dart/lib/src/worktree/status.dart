
import 'package:path/path.dart' as p;

import '../cancellation.dart';
import '../diff/tree_diff.dart';
import '../fs/git_fs.dart';
import '../index/git_index.dart';
import '../objects/git_object.dart';
import '../objects/tree.dart';
import '../repository.dart';
import 'ignore.dart';

/// One path's state, on both sides of the index.
///
/// Two changes rather than one, because the index sits between HEAD and the
/// working tree and a path can differ from both — staged one way and modified
/// again since.
class StatusEntry {
  final String path;

  /// Where the path was before a staged rename, and null otherwise.
  ///
  /// Git does not record that a file moved, so this is inferred the same way
  /// a tree diff infers it: an addition and a deletion of the same or nearly
  /// the same content are one change, not two (`algorithms.diff`).
  final String? oldPath;

  /// HEAD to index: what a commit would record.
  final ChangeKind? staged;

  /// Index to working tree: what is not staged.
  final ChangeKind? unstaged;

  final bool isUntracked;
  final bool isConflicted;

  const StatusEntry({
    required this.path,
    this.oldPath,
    this.staged,
    this.unstaged,
    this.isUntracked = false,
    this.isConflicted = false,
  });

  /// The two-letter code `git status --porcelain` prints.
  String get code {
    if (isConflicted) return 'UU';
    if (isUntracked) return '??';
    return '${_letter(staged)}${_letter(unstaged)}';
  }

  static String _letter(ChangeKind? kind) => switch (kind) {
        null => ' ',
        ChangeKind.added => 'A',
        ChangeKind.deleted => 'D',
        ChangeKind.modified => 'M',
        ChangeKind.typeChanged => 'T',
        ChangeKind.renamed => 'R',
      };

  @override
  String toString() =>
      oldPath == null ? '$code $path' : '$code $oldPath -> $path';
}

class RepositoryStatus {
  final List<StatusEntry> entries;

  /// The branch HEAD is on, or null when detached.
  final String? branch;

  /// True when HEAD has no commit yet — a new repository, where everything in
  /// the index is an addition rather than a modification.
  final bool isUnborn;

  const RepositoryStatus({
    required this.entries,
    required this.branch,
    required this.isUnborn,
  });

  bool get isClean => entries.every((e) => e.isUntracked);

  List<StatusEntry> get staged =>
      entries.where((e) => e.staged != null).toList();
  List<StatusEntry> get unstaged =>
      entries.where((e) => e.unstaged != null).toList();
  List<StatusEntry> get untracked =>
      entries.where((e) => e.isUntracked).toList();
  List<StatusEntry> get conflicted =>
      entries.where((e) => e.isConflicted).toList();

  @override
  String toString() => entries.join('\n');
}

/// Compares HEAD, the index and the working tree.
///
/// [trustStatCache] decides what the index's stat fields are allowed to
/// settle. With it on, a file whose size and mtime match what was recorded is
/// taken to be unchanged and is not read — which is what git does, and is why
/// a file edited within the same second and to the same length can be reported
/// clean by both. With it off every tracked file is hashed, which is slower by
/// the size of the working tree and cannot miss anything.
///
/// The default is git's behaviour, so that this library and git agree. The
/// option exists because `hazards` names exactly this trade, and a caller that
/// needs the truth rather than the fast answer should be able to ask for it
/// (`index.the-stat-fields-are-a-cache`).
/// [collapseUntrackedDirectories] reports a directory with nothing tracked in
/// it as a single entry ending in `/`, which is git's default. Pass false to
/// list every file under it, as `--untracked-files=all` does.
RepositoryStatus statusOf(
  Repository repo, {
  bool includeUntracked = true,
  bool trustStatCache = true,
  bool collapseUntrackedDirectories = true,
  bool detectRenames = true,
  int renameThreshold = 50,
  int renameLimit = 1000,
  Cancellation? cancel,
}) {
  final workTree = repo.workTree;
  if (workTree == null) {
    throw StateError('a bare repository has no working tree to compare');
  }

  final index = repo.index ?? GitIndex.empty();
  final indexFile = fs.file(p.join(repo.gitDirectory, 'index'));
  final indexWrittenAt =
      indexFile.existsSync() ? indexFile.statSync().modified : null;
  final headId = repo.headId;
  final headTree = headId == null ? null : repo.treeOf(headId);

  final unstaged = <String, ChangeKind>{};
  final conflicted = <String>{...index.conflicts.keys};

  // ---- HEAD against the index --------------------------------------------

  final indexByPath = {
    for (final entry in index.entries)
      if (entry.stage == MergeStage.ordinary) entry.path: entry,
  };
  final headByPath = <String, TreeEntry>{};
  if (headTree != null) _flatten(repo, headTree, '', headByPath);

  final stagedChanges = <DiffEntry>[];
  for (final path in {...headByPath.keys, ...indexByPath.keys}) {
    if (conflicted.contains(path)) continue;
    final inHead = headByPath[path];
    final inIndex = indexByPath[path];

    if (inHead == null) {
      stagedChanges.add(DiffEntry(
        kind: ChangeKind.added,
        newPath: path,
        newMode: inIndex!.fileMode,
        newId: inIndex.id,
      ));
    } else if (inIndex == null) {
      stagedChanges.add(DiffEntry(
        kind: ChangeKind.deleted,
        oldPath: path,
        oldMode: inHead.mode,
        oldId: inHead.id,
      ));
    } else if (inHead.id != inIndex.id) {
      stagedChanges.add(DiffEntry(
        kind: ChangeKind.modified,
        oldPath: path,
        newPath: path,
        oldMode: inHead.mode,
        newMode: inIndex.fileMode,
        oldId: inHead.id,
        newId: inIndex.id,
      ));
    } else if (inHead.mode.text != inIndex.fileMode.text) {
      stagedChanges.add(DiffEntry(
        kind: ChangeKind.typeChanged,
        oldPath: path,
        newPath: path,
        oldMode: inHead.mode,
        newMode: inIndex.fileMode,
        oldId: inHead.id,
        newId: inIndex.id,
      ));
    }
  }

  // A staged move is an addition and a deletion in the index, exactly as it
  // is in a tree: git records no such thing as a rename. The same pairing a
  // tree diff makes is made here, so that a moved file is one change with
  // both of its names rather than two changes that have lost each other.
  stagedChanges.sort((a, b) => a.path.compareTo(b.path));
  final staged = <String, ChangeKind>{};
  final renamedFrom = <String, String>{};
  for (final change in detectRenames
      ? pairRenames(
          repo.objects,
          stagedChanges,
          threshold: renameThreshold,
          limit: renameLimit,
        )
      : stagedChanges) {
    staged[change.path] = change.kind;
    if (change.kind == ChangeKind.renamed) {
      renamedFrom[change.path] = change.oldPath!;
    }
  }

  // ---- the index against the working tree ---------------------------------

  for (final entry in indexByPath.values) {
    // One tracked file is the unit, and this is the half of status that
    // reads and hashes files: the expensive half, and the one worth leaving.
    checkCancelled(cancel, 'the status walk');
    if (conflicted.contains(entry.path)) continue;
    // A skip-worktree entry is one the working tree is not expected to hold,
    // which is the whole of what sparse checkout does. Comparing it against
    // the disk would report every deliberately absent file as deleted, and a
    // narrowed checkout would look like a repository somebody had emptied.
    if (entry.skipWorktree) continue;
    final file = fs.file(
      p.join(workTree, entry.path.replaceAll('/', p.separator)),
    );

    if (!file.existsSync()) {
      // A path recorded as a symlink may exist as a link rather than a file.
      final link = fs.link(file.path);
      if (!link.existsSync()) {
        unstaged[entry.path] = ChangeKind.deleted;
        continue;
      }
    }

    if (entry.intentToAdd) {
      unstaged[entry.path] = ChangeKind.added;
      continue;
    }

    final stat = file.statSync();
    // "Racily clean": an entry whose mtime is not older than the index's own
    // is one that could have been written in the same second the index was,
    // so its stat data proves nothing and the file is read. git's rule, and
    // the reason a same-second edit is sometimes caught and sometimes not.
    final racy = indexWrittenAt != null &&
        entry.mtimeSeconds >= indexWrittenAt.millisecondsSinceEpoch ~/ 1000;
    if (trustStatCache && !racy && entry.matchesStat(stat)) continue;

    // Hashed as it would be *stored*, not as it sits on disk. Without the
    // conversion, a CRLF working tree reports every text file as modified
    // against an index that holds the LF form — which is the whole repository
    // permanently dirty and no change made.
    final raw = file.readAsBytesSync();
    final id = hashObject(ObjectKind.blob, repo.convertToGit(entry.path, raw));
    if (id != entry.id) unstaged[entry.path] = ChangeKind.modified;
  }

  // ---- what is in neither -------------------------------------------------

  final untracked = <String>[];
  if (includeUntracked) {
    final rules = loadIgnoreRules(
      workTree,
      repo.gitDirectory,
      config: repo.config,
    );
    _walkWorkTree(
      workTree,
      '',
      rules,
      indexByPath.keys.toSet(),
      untracked,
      collapseDirectories: collapseUntrackedDirectories,
    );
  }

  final entries = <StatusEntry>[
    for (final path in {...staged.keys, ...unstaged.keys, ...conflicted})
      StatusEntry(
        path: path,
        oldPath: renamedFrom[path],
        staged: staged[path],
        unstaged: unstaged[path],
        isConflicted: conflicted.contains(path),
      ),
    for (final path in untracked) StatusEntry(path: path, isUntracked: true),
  ]..sort((a, b) => a.path.compareTo(b.path));

  return RepositoryStatus(
    entries: entries,
    branch: repo.refs.currentBranch,
    isUnborn: headId == null,
  );
}

void _flatten(
  Repository repo,
  Tree tree,
  String prefix,
  Map<String, TreeEntry> out,
) {
  for (final entry in tree.entries) {
    final path = '$prefix${entry.name}';
    if (entry.mode.isTree) {
      _flatten(repo, repo.objects.readTyped<Tree>(entry.id), '$path/', out);
    } else {
      out[path] = entry;
    }
  }
}

void _walkWorkTree(
  String workTree,
  String prefix,
  IgnoreRules rules,
  Set<String> tracked,
  List<String> out, {
  bool collapseDirectories = true,
}) {
  final directory = fs.directory(
    prefix.isEmpty
        ? workTree
        : p.join(workTree, prefix.replaceAll('/', p.separator)),
  );
  if (!directory.existsSync()) return;

  // A `.gitignore` in a subdirectory applies from there down, so the rules
  // grow as the walk descends and are discarded on the way back up.
  final local = fs.file(p.join(directory.path, '.gitignore'));
  if (prefix.isNotEmpty && local.existsSync()) {
    rules = IgnoreRules()
      ..patterns.addAll(rules.patterns)
      ..addFile(local.path, base: prefix.substring(0, prefix.length - 1));
  }

  for (final entry in directory.listSync(followLinks: false)) {
    final name = p.basename(entry.path);
    // The repository's own directory is never part of the working tree.
    if (prefix.isEmpty && name == '.git') continue;
    final path = '$prefix$name';

    if (entry is GitFsDirectory) {
      if (rules.isIgnored(path, isDirectory: true)) continue;

      // A nested repository is one entry, not its contents: its files belong
      // to it, and reporting them here would be reporting another
      // repository's business.
      final isNestedRepository =
          fs.directory(p.join(entry.path, '.git')).existsSync() ||
              fs.file(p.join(entry.path, '.git')).existsSync();

      final holdsTrackedFiles = tracked.any((t) => t.startsWith('$path/'));

      // A directory with nothing tracked in it is reported as one entry
      // rather than as its contents — git's default, and the right one: a
      // newly created package is one fact, not forty.
      if (isNestedRepository || (collapseDirectories && !holdsTrackedFiles)) {
        final children = <String>[];
        _walkWorkTree(
          workTree,
          '$path/',
          rules,
          tracked,
          children,
          collapseDirectories: collapseDirectories,
        );
        // Nothing unignored inside means nothing to report at all.
        if (children.isNotEmpty || isNestedRepository) out.add('$path/');
        continue;
      }

      _walkWorkTree(
        workTree,
        '$path/',
        rules,
        tracked,
        out,
        collapseDirectories: collapseDirectories,
      );
      continue;
    }

    if (tracked.contains(path)) continue;
    if (rules.isIgnored(path)) continue;
    out.add(path);
  }
}
