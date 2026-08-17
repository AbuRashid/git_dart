import 'dart:io';

import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/git_object.dart';
import '../objects/tag.dart';
import '../objects/tree.dart';
import '../refs/reflog.dart';
import '../repository.dart';
import 'pack_writer.dart';

class RepackResult {
  /// Objects written into the new pack.
  final int packed;

  /// Loose files removed because the pack now holds them.
  final int looseRemoved;

  /// Packs removed because the new one contains everything they held.
  final int packsRemoved;

  /// Unreachable objects deleted outright.
  final int pruned;

  final String? packPath;

  const RepackResult({
    required this.packed,
    this.looseRemoved = 0,
    this.packsRemoved = 0,
    this.pruned = 0,
    this.packPath,
  });

  @override
  String toString() => 'packed $packed, removed $looseRemoved loose and '
      '$packsRemoved packs, pruned $pruned';
}

/// Everything a repository must keep: reachable from any ref, from HEAD, from
/// the index, and from anything a reflog still names.
///
/// The reflogs are the part that is easy to leave out and expensive to get
/// wrong. A commit a branch has moved off is unreachable from every ref and is
/// exactly what the reflog exists to keep findable (`refs.reflog`); collecting
/// it because no ref points at it would make every reset and every rebase
/// irreversible the moment a repack ran.
Set<ObjectId> liveObjects(Repository repository) =>
    liveObjectsAndNames(repository).objects;

/// Everything that must be kept, and the name each object was last seen
/// under.
///
/// The names come out of the same walk rather than a second one: it already
/// reads every tree and sees every entry's name, so the information is passing
/// through anyway — and it is what lets the packer put revisions of one file
/// next to each other, which is where most delta compression comes from.
({Set<ObjectId> objects, Map<ObjectId, String> names}) liveObjectsAndNames(
  Repository repository,
) {
  final roots = <ObjectId>[];

  for (final ref in repository.refs.list()) {
    final id = repository.refs.resolve(ref.path);
    if (id != null) roots.add(id);
  }
  final head = repository.headId;
  if (head != null) roots.add(head);

  // Also `refs/stash`, which `list` covers, and every position any log
  // remembers.
  for (final path in repository.refs.refsWithReflogs()) {
    final log = Reflog.read(repository.gitDirectory, path);
    for (final entry in log.entries) {
      if (!entry.from.isZero) roots.add(entry.from);
      if (!entry.to.isZero) roots.add(entry.to);
    }
  }

  // The index holds blobs that no commit does — everything staged and not yet
  // committed.
  final index = repository.index;
  final extra = <ObjectId>[];
  if (index != null) {
    for (final entry in index.entries) {
      extra.add(entry.id);
    }
  }

  // A state file may name a commit that nothing else does, mid-operation.
  for (final name in const [
    'MERGE_HEAD',
    'ORIG_HEAD',
    'CHERRY_PICK_HEAD',
    'REVERT_HEAD',
    'REBASE_HEAD',
  ]) {
    final file = fs.file(p.join(repository.gitDirectory, name));
    if (!file.existsSync()) continue;
    final text = file.readAsStringSync().trim();
    if (text.length == ObjectId.hexLength) {
      try {
        roots.add(ObjectId.fromHex(text));
      } on FormatException {
        // A state file holding something else is not a reason to stop.
      }
    }
  }

  final walked = _reachable(repository, roots);
  walked.objects.addAll(extra);
  return walked;
}

({Set<ObjectId> objects, Map<ObjectId, String> names}) _reachable(
  Repository repository,
  Iterable<ObjectId> roots,
) {
  final seen = <ObjectId>{};
  final names = <ObjectId, String>{};
  final pending = <ObjectId>[...roots];

  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (!seen.add(id)) continue;
    final raw = repository.objects.readRaw(id);
    if (raw == null) {
      // A root naming an object that is not here: a shallow boundary, or a
      // reflog line from before a fetch that was never completed.
      seen.remove(id);
      continue;
    }
    final object = GitObject.parse(raw.kind, raw.content);
    switch (object) {
      case Commit commit:
        pending
          ..add(commit.tree)
          ..addAll(commit.parents);
      case Tree tree:
        for (final entry in tree.entries) {
          if (entry.mode.isSubmodule) continue;
          pending.add(entry.id);
          names.putIfAbsent(entry.id, () => entry.name);
        }
      case Tag tag:
        pending.add(tag.target);
      case Blob():
        break;
    }
  }
  return (objects: seen, names: names);
}

/// Packs everything into one packfile and removes what the pack replaces.
///
/// A repository that only ever writes loose objects is correct and grows
/// without bound: one file per version of every file, forever, uncompressed
/// against each other. Repacking is what makes the size of a repository track
/// the size of its history rather than the number of edits in it — the last
/// step of the build order, and the one that makes the rest sustainable
/// (`algorithms.build-order`).
///
/// With [prune], objects nothing can reach are deleted rather than carried
/// into the new pack. Without it they are packed like everything else, which
/// is slower to grow and never loses anything.
RepackResult repack(
  Repository repository, {
  bool prune = false,
  void Function(String message)? onProgress,
}) {
  final walked = liveObjectsAndNames(repository);
  final live = walked.objects;

  // Everything the store holds, once: an object may be both loose and packed
  // after an earlier repack, which is legal and means the same object.
  final all = <ObjectId>{...repository.objects.listAll()};
  final keep = prune ? live : all;

  onProgress?.call('packing ${keep.length} objects');

  final writer = PackWriter();
  for (final id in keep) {
    final raw = repository.objects.readRaw(id);
    if (raw == null) continue;
    // The name is what groups revisions of one file together, which is where
    // most of the delta compression comes from. An object nothing names — an
    // unreachable blob being carried along — simply sorts by size.
    writer.add(id, raw.kind, raw.content, name: walked.names[id]);
  }

  if (writer.length == 0) {
    return const RepackResult(packed: 0);
  }

  final built = writer.buildWithIndex();
  final packPath = repository.objects.writePack(
    packBytes: built.bytes,
    objects: built.objects,
    packChecksum: built.checksum,
  );

  final packed = {for (final object in built.objects) object.id};

  // ---- the old copies ----
  //
  // Removed only after the new pack is in place and readable, so that at no
  // point is an object in neither.
  var looseRemoved = 0;
  var pruned = 0;
  final toDelete = <GitFsFile>[];
  final wasPacked = <String, bool>{};

  for (final id in repository.objects.loose.listAll().toList()) {
    final isLive = live.contains(id);
    if (!packed.contains(id) && (isLive || !prune)) continue;
    final file = fs.file(repository.objects.loose.pathFor(id));
    if (!file.existsSync()) continue;
    toDelete.add(file);
    wasPacked[file.path] = packed.contains(id);
  }

  for (final file in _deleteAll(toDelete)) {
    if (wasPacked[file.path] ?? false) {
      looseRemoved += 1;
    } else {
      pruned += 1;
    }
  }

  // ---- packs the new one supersedes ----
  var packsRemoved = 0;
  final packDirectory =
      fs.directory(p.join(repository.objects.loose.objectsDirectory, 'pack'));
  if (packDirectory.existsSync()) {
    for (final entry in packDirectory.listSync()) {
      if (entry is! GitFsFile || !entry.path.endsWith('.pack')) continue;
      if (packPath != null && p.equals(entry.path, packPath)) continue;

      final base = p.withoutExtension(entry.path);

      // A `.keep` is a request not to remove this pack — left by a fetch in
      // progress, or by someone who meant it. It is not ours to overrule.
      if (fs.file('$base.keep').existsSync()) continue;

      // A pack is dropped only when every object in it is in the new one.
      // Anything less and this would be deleting the only copy of something.
      final index = '$base.idx';
      if (!fs.file(index).existsSync()) continue;

      final held = repository.objects.packs
          .where((pack) => p.equals(pack.packPath, entry.path))
          .expand((pack) => pack.listAll())
          .toSet();
      if (held.isEmpty || !held.every(packed.contains)) continue;

      // Closed first: an open handle on Windows stops the file being removed,
      // and leaving it open would leak one per repack besides.
      for (final pack in [...repository.objects.packs]) {
        if (!p.equals(pack.packPath, entry.path)) continue;
        pack.close();
        repository.objects.packs.remove(pack);
      }

      // A pack is more than two files. Git writes a reverse index beside it,
      // and may write a bitmap or a promisor marker; each names the pack it
      // belongs to and is meaningless without it. Leaving one behind is not
      // untidiness — git reads them, and a companion whose pack has gone is
      // a repository that no longer passes `fsck`.
      _deleteAll([
        entry,
        fs.file(index),
        for (final companion in const [
          '.rev',
          '.bitmap',
          '.promisor',
          '.mtimes',
        ])
          if (fs.file('$base$companion').existsSync())
            fs.file('$base$companion'),
      ]);
      packsRemoved += 1;
    }
  }

  if (packsRemoved > 0 || packPath != null) {
    _dropStalePackIndexes(packDirectory);
  }

  // Empty fan-out directories left behind by the loose objects that went.
  _pruneEmptyFanout(repository.objects.loose.objectsDirectory);

  // The commit-graph is a cache of the history's shape, and a repack is when
  // reading that history has just become cheapest to cache and most expensive
  // to leave stale. Failing to write it is not a reason to fail the repack:
  // everything works without one.
  try {
    repository.writeCommitGraph();
  } catch (_) {
    // A cache that could not be written is a cache that is not there.
  }

  return RepackResult(
    packed: built.objects.length,
    looseRemoved: looseRemoved,
    packsRemoved: packsRemoved,
    pruned: pruned,
    packPath: packPath,
  );
}

/// What `git gc` is: repack, and drop what nothing can reach.
///
/// The two are one operation here because doing either alone is the awkward
/// half — packing without pruning keeps everything forever, and pruning
/// without packing leaves the survivors in the shape that was the problem.
RepackResult gc(
  Repository repository, {
  void Function(String message)? onProgress,
}) =>
    repack(repository, prune: true, onProgress: onProgress);

/// Objects nothing can reach — what a prune would delete.
///
/// Offered separately because "what would this throw away" is a question worth
/// being able to ask before throwing it away.
Set<ObjectId> unreachableObjects(Repository repository) {
  final live = liveObjects(repository);
  return {
    for (final id in repository.objects.listAll())
      if (!live.contains(id)) id,
  };
}

/// Deletes [files], returning those that went.
///
/// Git writes a loose object and a pack index read-only, on the reasoning that
/// an object's content is its name and may never change. On Windows a
/// read-only file cannot be deleted at all, so a repack of a repository git
/// created fails on the first object it tries to remove — while succeeding
/// everywhere else, which is how this was missed until it ran here.
///
/// The attribute is cleared for the whole batch in one go rather than per
/// file: this runs over every loose object in the repository, and a process
/// each would cost more than the repack.
List<GitFsFile> _deleteAll(List<GitFsFile> files) {
  final gone = <GitFsFile>[];
  final stubborn = <GitFsFile>[];

  for (final file in files) {
    try {
      file.deleteSync();
      gone.add(file);
    } on GitFsException {
      stubborn.add(file);
    }
  }

  if (stubborn.isEmpty || !Platform.isWindows) return gone;

  // One call over the shared root, rather than one per file.
  final roots = {for (final file in stubborn) p.dirname(file.path)};
  for (final root in roots) {
    Process.runSync('attrib', ['-R', p.join(root, '*'), '/S']);
  }

  for (final file in stubborn) {
    try {
      file.deleteSync();
      gone.add(file);
    } on GitFsException {
      // Held open by something else. Left behind rather than fought over:
      // an extra copy of an object that is also in the pack is waste, not
      // corruption.
    }
  }
  return gone;
}

/// Removes the indexes that describe *which* packs a repository has, once that
/// set has changed.
///
/// A multi-pack-index names the packs it covers by position and is read before
/// the packs themselves; one that names a pack which is no longer there makes
/// `fsck` fail on a repository whose objects are all present and correct. It
/// is a cache, so deleting it is always safe and git rebuilds it on request.
/// The same goes for `info/packs`, which is the list a dumb-HTTP client reads
/// and which would otherwise send that client after a file that has gone.
void _dropStalePackIndexes(GitFsDirectory packDirectory) {
  if (!packDirectory.existsSync()) return;

  final stale = <GitFsFile>[];
  for (final entry in packDirectory.listSync()) {
    if (entry is! GitFsFile) continue;
    final name = p.basename(entry.path);
    if (name == 'multi-pack-index' || name.startsWith('multi-pack-index-')) {
      stale.add(entry);
    }
  }

  final info = fs.file(p.join(
    p.dirname(packDirectory.path),
    'info',
    'packs',
  ));
  if (info.existsSync()) stale.add(info);

  _deleteAll(stale);
}

void _pruneEmptyFanout(String objectsDirectory) {
  final root = fs.directory(objectsDirectory);
  if (!root.existsSync()) return;
  for (final entry in root.listSync()) {
    if (entry is! GitFsDirectory) continue;
    final name = p.basename(entry.path);
    if (name.length != 2) continue; // not a fan-out directory
    if (entry.listSync().isEmpty) entry.deleteSync();
  }
}
