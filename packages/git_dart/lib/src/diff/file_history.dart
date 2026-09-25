/// The commits that touched one path — `git log -- <path>`.
///
/// Not a filter over the full log, though it is easy to mistake for one. Git
/// *simplifies* history against the path: a commit whose version of the file
/// matches one of its parents did not change it, so it is not shown, and the
/// walk continues down that parent alone. A merge that took one side's version
/// wholesale therefore disappears from the listing, along with the entire other
/// branch — which is what makes the result readable rather than a list of every
/// commit that happened to be nearby.
///
/// With [follow] the path itself can change. Nothing records that a file moved
/// (`algorithms.diff`), so when the file vanishes going backwards the previous
/// commit's diff is examined for a rename that produced it, and the walk
/// carries on under the older name.
library;

import 'dart:collection';

import '../cancellation.dart';
import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/tree.dart';
import '../repository.dart';
import 'tree_diff.dart';

/// One commit that changed the path, and what it did to it.
class FileHistoryEntry {
  final Commit commit;

  /// The path as it was at this commit. Differs from the path asked about
  /// once the walk has gone back past a rename.
  final String path;

  final ChangeKind kind;

  /// Where the file was before, when this commit renamed it.
  final String? previousPath;

  /// The blob at this commit, or null where the commit deleted the file.
  final ObjectId? blob;

  const FileHistoryEntry({
    required this.commit,
    required this.path,
    required this.kind,
    this.blob,
    this.previousPath,
  });

  bool get isRename => kind == ChangeKind.renamed;

  @override
  String toString() => isRename
      ? '${commit.id.hex.substring(0, 8)} R $previousPath -> $path'
      : '${commit.id.hex.substring(0, 8)} ${kind.name} $path';
}

/// The commits that changed [path], newest first.
///
/// [limit] caps how many are returned, not how far the walk goes: a file
/// touched twice in a long history still costs the walk to find the second
/// one. [maxCommits] is the walk's own bound, for a caller that would rather
/// have a short answer than a long wait.
Iterable<FileHistoryEntry> fileHistory(
  Repository repository,
  String path, {
  ObjectId? start,
  int? limit,
  bool follow = true,
  int maxCommits = 50000,
  Cancellation? cancel,
}) sync* {
  final from = start ?? repository.headId;
  if (from == null) return;

  final head = repository.peel(from);
  if (head is! Commit) return;

  // Newest first, and more than one line of history at a time: a commit that
  // changed the file against *every* parent is kept, and then every parent is
  // followed, because each side may have changed it too. Walking only the
  // first parent would silently drop the other branch — a listing that is not
  // obviously wrong, merely missing things.
  final queue = SplayTreeSet<_Pending>((a, b) {
    final byDate =
        b.commit.committer.seconds.compareTo(a.commit.committer.seconds);
    if (byDate != 0) return byDate;
    return a.commit.id.compareTo(b.commit.id);
  });
  final seen = <ObjectId>{};

  queue.add(_Pending(head, path));
  seen.add(head.id);

  var emitted = 0;
  var walked = 0;

  while (queue.isNotEmpty && walked < maxCommits) {
    checkCancelled(cancel, "the file's history walk");
    final pending = queue.first;
    queue.remove(pending);
    walked += 1;

    final current = pending.commit;
    final currentPath = pending.path;

    final here = _blobAt(repository, current, currentPath);
    final parents = repository.presentParentsOf(current);

    if (parents.isEmpty) {
      // A root commit introduced the file if it has it at all.
      if (here != null) {
        yield FileHistoryEntry(
          commit: current,
          path: currentPath,
          kind: ChangeKind.added,
          blob: here,
        );
        emitted += 1;
        if (limit != null && emitted >= limit) return;
      }
      continue;
    }

    // Which parents agree with this commit about the file. Matching any of
    // them means this commit did not change it — the change came from that
    // side, and following only that side is what keeps a merge out of the
    // listing along with the branch it merged.
    Commit? sameAs;
    final versions = <ObjectId, ObjectId?>{};
    for (final id in parents) {
      final parent = _commitOrNull(repository, id);
      if (parent == null) continue;
      final there = _blobAt(repository, parent, currentPath);
      versions[id] = there;
      if (there == here && sameAs == null) sameAs = parent;
    }

    if (sameAs != null) {
      if (seen.add(sameAs.id)) queue.add(_Pending(sameAs, currentPath));
      continue;
    }

    final firstParentId = parents.first;
    final inFirstParent = versions[firstParentId];

    var kind = ChangeKind.modified;
    String? previousPath;

    if (here == null) {
      kind = ChangeKind.deleted;
    } else if (inFirstParent == null) {
      kind = ChangeKind.added;

      if (follow) {
        // The file appears here and not in the parent. It may have been
        // written from nothing, or be the same file under an older name —
        // only comparing the two trees can tell.
        final renamedFrom = _renameInto(
          repository,
          firstParentId,
          current.id,
          currentPath,
        );
        if (renamedFrom != null) {
          kind = ChangeKind.renamed;
          previousPath = renamedFrom;
        }
      }
    }

    yield FileHistoryEntry(
      commit: current,
      path: currentPath,
      kind: kind,
      blob: here,
      previousPath: previousPath,
    );

    emitted += 1;
    if (limit != null && emitted >= limit) return;

    // Changed against all of them, so each parent's line may have changed it
    // as well and each is worth following. Past a rename the older history is
    // under the older name, which only the first-parent line knows about.
    for (final id in parents) {
      final parent = _commitOrNull(repository, id);
      if (parent == null) continue;
      if (!seen.add(id)) continue;
      queue.add(_Pending(
        parent,
        id == firstParentId && previousPath != null
            ? previousPath
            : currentPath,
      ));
    }
  }
}

/// A commit still to examine, and the name the file went by there.
class _Pending {
  final Commit commit;
  final String path;
  const _Pending(this.commit, this.path);
}

/// The blob [path] names at [commit], or null when it is not a file there.
ObjectId? _blobAt(Repository repository, Commit commit, String path) {
  final tree = repository.objects.readRaw(commit.tree) == null
      ? null
      : repository.objects.readTyped<Tree>(commit.tree);
  if (tree == null) return null;
  final entry = repository.lookup(tree, path);
  if (entry == null || entry.mode.isTree) return null;
  return entry.id;
}

Commit? _commitOrNull(Repository repository, ObjectId id) {
  if (repository.objects.readRaw(id) == null) return null;
  final object = repository.objects.read(id);
  return object is Commit ? object : null;
}

/// The path [target] was renamed from between the two commits, if it was.
///
/// Only asked when the file appears from nothing, which is rare, because the
/// answer costs a full tree diff with similarity detection.
String? _renameInto(
  Repository repository,
  ObjectId before,
  ObjectId after,
  String target,
) {
  final changes = repository.diff(before, after);
  for (final change in changes) {
    if (change.kind != ChangeKind.renamed) continue;
    if (change.newPath == target) return change.oldPath;
  }
  return null;
}
