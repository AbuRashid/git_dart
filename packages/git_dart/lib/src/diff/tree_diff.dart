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
/// and does not write down that a file moved (`algorithms.diff`). Only exact
/// renames are found here — a deletion and an addition of the identical blob.
/// Similarity detection, which is what finds a file that moved *and* changed,
/// is not implemented.
List<DiffEntry> diffTrees(
  ObjectStore objects,
  Tree? before,
  Tree? after, {
  bool detectRenames = true,
}) {
  final changes = <DiffEntry>[];
  _walk(objects, before, after, '', changes);
  changes.sort((a, b) => a.path.compareTo(b.path));
  return detectRenames ? _pairExactRenames(changes) : changes;
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

List<DiffEntry> _pairExactRenames(List<DiffEntry> changes) {
  final deletions = <ObjectId, DiffEntry>{};
  for (final change in changes) {
    if (change.kind == ChangeKind.deleted && change.oldId != null) {
      deletions[change.oldId!] = change;
    }
  }
  if (deletions.isEmpty) return changes;

  final paired = <DiffEntry>{};
  final renames = <DiffEntry, DiffEntry>{};
  for (final change in changes) {
    if (change.kind != ChangeKind.added) continue;
    final deletion = deletions[change.newId];
    if (deletion == null || paired.contains(deletion)) continue;
    paired.add(deletion);
    renames[change] = deletion;
  }

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
