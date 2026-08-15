import '../object_id.dart';
import '../objects/tree.dart';
import '../storage/object_store.dart';

enum ChangeKind {
  added,
  deleted,
  modified,

  /// A path that changed between a file, a symlink, a directory and a
  /// submodule. Distinguished from [modified] because the working tree has to
  /// be changed differently for it.
  typeChanged,

  /// The same content under a new path. Never stored, always inferred after
  /// the fact (`algorithms.diff`).
  renamed,
}

class DiffEntry {
  final ChangeKind kind;

  /// The path before the change; null for an addition.
  final String? oldPath;

  /// The path after the change; null for a deletion.
  final String? newPath;

  final FileMode? oldMode;
  final FileMode? newMode;
  final ObjectId? oldId;
  final ObjectId? newId;

  const DiffEntry({
    required this.kind,
    this.oldPath,
    this.newPath,
    this.oldMode,
    this.newMode,
    this.oldId,
    this.newId,
  });

  /// The path to show for this change — the new one where there is one.
  String get path => newPath ?? oldPath!;

  @override
  String toString() => switch (kind) {
        ChangeKind.renamed => 'R  $oldPath -> $newPath',
        ChangeKind.added => 'A  $newPath',
        ChangeKind.deleted => 'D  $oldPath',
        ChangeKind.typeChanged => 'T  $path',
        ChangeKind.modified => 'M  $path',
      };
}

/// Compares two trees, recursively.
///
/// Either side may be null, which is how the first commit is diffed: against
/// nothing. Entries come back sorted by path.
///
/// Renames are detected rather than recorded, because git stores whole objects
/// and does not write down that a file moved: it is inferred by similarity,
/// after the fact, and heuristically (`algorithms.diff`).
///
/// Two passes. Identical content is paired first and exactly — a file that
/// moved and was not touched. What is left is compared by content, and a
/// deletion and an addition that are at least [renameThreshold] percent alike
/// are called a rename. Without the second pass a file that moved *and* was
/// edited reads as an unrelated deletion and addition, which loses its history
/// at exactly the moment someone is trying to follow it.
///
/// The comparison is quadratic in the number of unpaired files, so it stops
/// at [renameLimit] pairs and leaves the rest as adds and deletes. Git draws
/// the same line for the same reason, and says so rather than getting slow.
List<DiffEntry> diffTrees(
  ObjectStore objects,
  Tree? before,
  Tree? after, {
  bool detectRenames = true,
  int renameThreshold = 50,
  int renameLimit = 1000,
}) {
  final changes = <DiffEntry>[];
  _walk(objects, before, after, '', changes);
  changes.sort((a, b) => a.path.compareTo(b.path));
  return detectRenames
      ? _pairRenames(
          objects,
          changes,
          threshold: renameThreshold,
          limit: renameLimit,
        )
      : changes;
}

void _walk(
  ObjectStore objects,
  Tree? before,
  Tree? after,
  String prefix,
  List<DiffEntry> out,
) {
  final oldEntries = {
    for (final entry in before?.entries ?? const <TreeEntry>[])
      entry.name: entry,
  };
  final newEntries = {
    for (final entry in after?.entries ?? const <TreeEntry>[])
      entry.name: entry,
  };

  for (final name in {...oldEntries.keys, ...newEntries.keys}) {
    final oldEntry = oldEntries[name];
    final newEntry = newEntries[name];
    final path = '$prefix$name';

    // Both sides are directories: recurse, and skip identical subtrees
    // outright — an unchanged tree has an unchanged name, which is the whole
    // point of content addressing.
    if (oldEntry != null &&
        newEntry != null &&
        oldEntry.mode.isTree &&
        newEntry.mode.isTree) {
      if (oldEntry.id == newEntry.id) continue;
      _walk(
        objects,
        objects.readTyped<Tree>(oldEntry.id),
        objects.readTyped<Tree>(newEntry.id),
        '$path/',
        out,
      );
      continue;
    }

    if (oldEntry == null) {
      _expand(objects, newEntry!, path, ChangeKind.added, out);
      continue;
    }
    if (newEntry == null) {
      _expand(objects, oldEntry, path, ChangeKind.deleted, out);
      continue;
    }

    // One side is a directory and the other is not, or a file became a
    // symlink: the tree side has to be expanded into its files.
    if (oldEntry.mode.isTree != newEntry.mode.isTree) {
      _expand(objects, oldEntry, path, ChangeKind.deleted, out);
      _expand(objects, newEntry, path, ChangeKind.added, out);
      continue;
    }

    if (oldEntry.id == newEntry.id && oldEntry.mode == newEntry.mode) continue;

    out.add(DiffEntry(
      kind: oldEntry.mode == newEntry.mode
          ? ChangeKind.modified
          : ChangeKind.typeChanged,
      oldPath: path,
      newPath: path,
      oldMode: oldEntry.mode,
      newMode: newEntry.mode,
      oldId: oldEntry.id,
      newId: newEntry.id,
    ));
  }
}

/// Records an added or deleted entry, expanding a directory into every file
/// under it — a diff is over files, and a caller shown one line for a deleted
/// directory cannot tell what it lost.
void _expand(
  ObjectStore objects,
  TreeEntry entry,
  String path,
  ChangeKind kind,
  List<DiffEntry> out,
) {
  if (entry.mode.isTree) {
    final tree = objects.readTyped<Tree>(entry.id);
    for (final child in tree.entries) {
      _expand(objects, child, '$path/${child.name}', kind, out);
    }
    return;
  }

  final isAdd = kind == ChangeKind.added;
  out.add(DiffEntry(
    kind: kind,
    oldPath: isAdd ? null : path,
    newPath: isAdd ? path : null,
    oldMode: isAdd ? null : entry.mode,
    newMode: isAdd ? entry.mode : null,
    oldId: isAdd ? null : entry.id,
    newId: isAdd ? entry.id : null,
  ));
}

List<DiffEntry> _pairRenames(
  ObjectStore objects,
  List<DiffEntry> changes, {
  required int threshold,
  required int limit,
}) {
  final byOldId = <ObjectId, DiffEntry>{};
  for (final change in changes) {
    if (change.kind == ChangeKind.deleted && change.oldId != null) {
      byOldId[change.oldId!] = change;
    }
  }

  final paired = <DiffEntry>{};
  final renames = <DiffEntry, DiffEntry>{};

  // ---- pass one: identical content ----
  //
  // A file that moved and was not touched. Exact, cheap, and the common case,
  // so it runs first and takes those pairs out of the expensive pass.
  if (byOldId.isNotEmpty) {
    for (final change in changes) {
      if (change.kind != ChangeKind.added) continue;
      final deletion = byOldId[change.newId];
      if (deletion == null || paired.contains(deletion)) continue;
      paired.add(deletion);
      renames[change] = deletion;
    }
  }

  // ---- pass two: similar content ----
  final deletions = [
    for (final change in changes)
      if (change.kind == ChangeKind.deleted &&
          change.oldId != null &&
          !paired.contains(change))
        change,
  ];
  final additions = [
    for (final change in changes)
      if (change.kind == ChangeKind.added &&
          change.newId != null &&
          !renames.containsKey(change))
        change,
  ];

  if (deletions.isNotEmpty &&
      additions.isNotEmpty &&
      deletions.length * additions.length <= limit) {
    // Fingerprints are taken once per file rather than once per pair: the
    // comparison is quadratic and reading each blob for every candidate would
    // make it quadratic in bytes too.
    final sources = {
      for (final deletion in deletions)
        deletion: _fingerprint(objects, deletion.oldId!),
    };

    final takenSource = <DiffEntry>{};
    for (final addition in additions) {
      final target = _fingerprint(objects, addition.newId!);
      if (target == null) continue;

      DiffEntry? best;
      var bestScore = threshold - 1;

      for (final deletion in deletions) {
        if (takenSource.contains(deletion)) continue;
        final source = sources[deletion];
        if (source == null) continue;

        final score = _similarity(source, target);
        // Ties go to the first by path, which is the order `changes` is
        // already in — so the answer does not depend on map iteration order.
        if (score > bestScore) {
          bestScore = score;
          best = deletion;
        }
      }

      if (best != null) {
        takenSource.add(best);
        paired.add(best);
        renames[addition] = best;
      }
    }
  }

  if (renames.isEmpty) return changes;

  return [
    for (final change in changes)
      if (!paired.contains(change))
        if (renames.containsKey(change))
          DiffEntry(
            kind: ChangeKind.renamed,
            oldPath: renames[change]!.oldPath,
            newPath: change.newPath,
            oldMode: renames[change]!.oldMode,
            newMode: change.newMode,
            oldId: renames[change]!.oldId,
            newId: change.newId,
          )
        else
          change,
  ];
}

/// How much of a file is worth comparing before it is called too big.
///
/// A rename between two very large files is worth less than the time to prove
/// it, and holding two of them to find out is worse. Git has the same cutoff
/// and calls it `core.bigFileThreshold`.
const _bigFile = 32 * 1024 * 1024;

/// A file reduced to what it is made of: how many bytes fall on each distinct
/// line, and how many bytes in total.
///
/// Lines rather than bytes because a rename that also edits a file keeps most
/// of its lines and almost none of its byte offsets. Null when the object is
/// missing or too large to be worth comparing.
({Map<int, int> weights, int total})? _fingerprint(
  ObjectStore objects,
  ObjectId id,
) {
  final raw = objects.readRaw(id);
  if (raw == null) return null;
  final content = raw.content;
  if (content.length > _bigFile) return null;

  final weights = <int, int>{};
  var start = 0;
  var hash = 0;

  for (var i = 0; i <= content.length; i++) {
    if (i == content.length || content[i] == 0x0a) {
      if (i > start || i < content.length) {
        final length = i - start + 1;
        weights[hash] = (weights[hash] ?? 0) + length;
      }
      start = i + 1;
      hash = 0;
      continue;
    }
    // FNV-1a over the line. Any spreading hash does; this one is short and
    // does not need a table.
    hash = ((hash ^ content[i]) * 0x01000193) & 0xffffffff;
  }

  return (weights: weights, total: content.length);
}

/// How alike two files are, as a percentage.
///
/// The shared weight over the larger of the two, so that a file which grew is
/// not called a rename of everything smaller than it. A heuristic, and
/// deliberately so: nothing recorded that the file moved, and this is an
/// inference about intent from content.
int _similarity(
  ({Map<int, int> weights, int total}) source,
  ({Map<int, int> weights, int total}) target,
) {
  if (source.total == 0 && target.total == 0) return 100;

  final larger = source.total > target.total ? source.total : target.total;
  if (larger == 0) return 0;

  // A file cannot be half-alike to one twice its size, so pairs that far apart
  // are rejected without looking at their content.
  final smaller = source.total < target.total ? source.total : target.total;
  if (smaller * 100 < larger * 20) return 0;

  var common = 0;
  final walk = source.weights.length < target.weights.length
      ? source.weights
      : target.weights;
  final other = identical(walk, source.weights)
      ? target.weights
      : source.weights;

  for (final entry in walk.entries) {
    final theirs = other[entry.key];
    if (theirs == null) continue;
    common += entry.value < theirs ? entry.value : theirs;
  }

  return (common * 100) ~/ larger;
}
