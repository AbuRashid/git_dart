import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../diff/text_diff.dart';
import '../diff/tree_diff.dart';
import '../fs/git_fs.dart';
import '../graph/graph_walks.dart';
import '../hooks/hook_steps.dart';
import '../hooks/hooks.dart';
import '../index/git_index.dart';
import '../object_id.dart';
import '../objects/git_object.dart';
import '../objects/identity.dart';
import '../objects/tree.dart';
import '../repository.dart';

/// What a merge did.
enum MergeOutcome {
  /// Nothing to do: the other side is already contained in this one.
  alreadyUpToDate,

  /// This side had nothing of its own, so the branch simply moved forward.
  fastForward,

  /// A merge commit was written.
  merged,

  /// Some paths need a person. Nothing was committed; the index holds the
  /// three sides and the working tree holds markers.
  conflicted,
}

class MergeResult {
  final MergeOutcome outcome;

  /// The commit this repository is now on, when one was written or moved to.
  final ObjectId? commit;

  /// Paths that could not be resolved, in the order they were met.
  final List<String> conflicts;

  /// Paths the merge changed in the working tree.
  final List<String> updated;

  const MergeResult({
    required this.outcome,
    this.commit,
    this.conflicts = const [],
    this.updated = const [],
  });

  bool get ok => outcome != MergeOutcome.conflicted;
}

/// The best common ancestors of two commits.
///
/// More than one is possible, and that is what makes some merges genuinely
/// ambiguous rather than merely difficult (`algorithms.merge-base`). This
/// returns them all; a caller that must pick one takes the first.
List<ObjectId> mergeBases(Repository repository, ObjectId a, ObjectId b) =>
    mergeBasesOf(repository, [a], [b]);

/// The best common ancestors of two sets of commits.
///
/// Taking sets rather than single commits is what lets a *virtual* commit — a
/// merge of several bases that was never committed — take part in the search:
/// it has no name in the object store, but its ancestry is exactly the union
/// of its parents' (see [recursiveMergeBase]).
List<ObjectId> mergeBasesOf(
  Repository repository,
  Iterable<ObjectId> a,
  Iterable<ObjectId> b,
) {
  final reader = GraphReader(repository);

  Set<ObjectId> ancestorsOf(Iterable<ObjectId> from) {
    final seen = <ObjectId>{};
    final pending = <ObjectId>[...from];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!seen.add(id)) continue;
      final node = reader[id];
      if (node == null) continue;
      pending.addAll(node.parents);
    }
    return seen;
  }

  final fromA = ancestorsOf(a);
  final fromB = ancestorsOf(b);
  final common = fromA.intersection(fromB);
  if (common.isEmpty) return const [];

  // A best common ancestor is one no other common ancestor can reach: the
  // maximal elements. Anything reachable from another common ancestor is
  // further back and would make a worse base.
  //
  // The walk from each candidate stops at the shallowest generation among the
  // others: nothing below that level can be one of them, so there is no
  // reason to keep descending. Without a commit-graph there are no
  // generations, the floor is absent and the walk runs to the roots as it
  // always did — the same answer, more slowly.
  var floor = -1;
  for (final id in common) {
    final generation = reader[id]?.generation;
    if (generation == null) {
      floor = -1;
      break;
    }
    if (floor < 0 || generation < floor) floor = generation;
  }

  final reachableFromOtherCommon = <ObjectId>{};
  for (final id in common) {
    final node = reader[id];
    if (node == null) continue;
    final pending = <ObjectId>[...node.parents];
    final seen = <ObjectId>{};
    while (pending.isNotEmpty) {
      final ancestor = pending.removeLast();
      if (!seen.add(ancestor)) continue;
      if (common.contains(ancestor)) reachableFromOtherCommon.add(ancestor);
      final parent = reader[ancestor];
      if (parent == null) continue;
      if (floor >= 0 &&
          parent.generation != null &&
          parent.generation! < floor) {
        continue;
      }
      pending.addAll(parent.parents);
    }
  }

  return [
    for (final id in common)
      if (!reachableFromOtherCommon.contains(id)) id,
  ];
}

/// One path, as the three sides have it.
class _Sides {
  final TreeEntry? base;
  final TreeEntry? ours;
  final TreeEntry? theirs;
  const _Sides({this.base, this.ours, this.theirs});
}

/// A base to merge against: a tree, and the real commits it stands for.
///
/// When there is one best common ancestor these are that commit's tree and
/// that commit. When there are several, the tree is one nothing ever
/// committed.
class MergeBase {
  final ObjectId? tree;

  /// The real commits this base was built from. More than one means the tree
  /// is virtual.
  final List<ObjectId> commits;

  const MergeBase({required this.tree, required this.commits});

  bool get isVirtual => commits.length > 1;
  bool get exists => commits.isNotEmpty;
}

/// The base to merge [a] and [b] against, merging the bases themselves when
/// there is more than one.
///
/// Two branches can have several best common ancestors — the criss-cross, made
/// by merging each into the other and then carrying on. Picking one of them
/// and calling it *the* base is what the spec's last hazard names: a change
/// that is present in the discarded base but not the chosen one looks, from
/// the chosen base, like something one side did and the other did not, and it
/// is silently resolved the wrong way.
///
/// The answer is to merge the bases into each other and use the result. It is
/// recursive because the bases may themselves have several common ancestors,
/// and it terminates because each level looks strictly further back.
///
/// A conflict inside a virtual base is not a question for anyone: nobody is
/// merging those two commits and there is nothing to resolve. The conflicting
/// region is left in the base with markers, which makes both sides differ from
/// it, so the real merge reports the real conflict rather than inventing an
/// agreement.
MergeBase recursiveMergeBase(
  Repository repository,
  Iterable<ObjectId> a,
  Iterable<ObjectId> b, {
  int depth = 0,
}) {
  final bases = mergeBasesOf(repository, a, b);
  if (bases.isEmpty) return const MergeBase(tree: null, commits: []);
  if (bases.length == 1) {
    return MergeBase(
      tree: repository.treeOf(bases.single)?.id,
      commits: [bases.single],
    );
  }

  // Deeply nested criss-crosses exist and are pathological. Past this the
  // first base is taken, which is what this function exists to avoid — so it
  // is bounded rather than unbounded, and the bound is far past anything a
  // history produced by people reaches.
  if (depth >= 8) {
    return MergeBase(
      tree: repository.treeOf(bases.first)?.id,
      commits: [bases.first],
    );
  }

  var carried = <ObjectId>[bases.first];
  var tree = repository.treeOf(bases.first)?.id;

  for (var i = 1; i < bases.length; i++) {
    final next = bases[i];
    // The base for merging the bases, found the same way.
    final inner = recursiveMergeBase(
      repository,
      carried,
      [next],
      depth: depth + 1,
    );

    tree = _mergeToTree(
      repository,
      base: _flattenId(repository, inner.tree),
      ours: _flattenId(repository, tree),
      theirs: _flatten(repository, repository.treeOf(next)),
    );
    carried = [...carried, next];
  }

  return MergeBase(tree: tree, commits: carried);
}

Map<String, TreeEntry> _flattenId(Repository repository, ObjectId? tree) =>
    tree == null
        ? <String, TreeEntry>{}
        : _flatten(repository, repository.objects.readTyped<Tree>(tree));

/// Merges three flattened trees and writes the result, with conflicts left in
/// place as marked-up content.
///
/// Used only for virtual bases. The real merge needs to know which paths
/// conflicted, so it uses [_mergePaths] directly.
ObjectId _mergeToTree(
  Repository repository, {
  required Map<String, TreeEntry> base,
  required Map<String, TreeEntry> ours,
  required Map<String, TreeEntry> theirs,
}) {
  final merged = _mergePaths(repository, base, ours, theirs);
  final entries = {...merged.resolved};

  for (final entry in merged.conflicts.entries) {
    final sides = entry.value;
    // The old name of a file renamed two ways: neither side has it.
    if (sides.ours == null && sides.theirs == null) continue;
    final marked = _conflictMarkers(repository, sides);
    // Binary, or a delete against an edit: our side stands in, and failing
    // that theirs. Something has to be in the base, and which it is only
    // affects which side the real merge sees as having moved.
    if (marked == null) {
      final fallback = sides.ours ?? sides.theirs;
      if (fallback != null) entries[entry.key] = fallback;
      continue;
    }
    final blob = Blob(marked);
    repository.objects.write(blob);
    entries[entry.key] = TreeEntry.named(
      mode: sides.ours?.mode ?? sides.theirs?.mode ?? FileMode.regularFile,
      name: entry.key.split('/').last,
      id: blob.id,
    );
  }

  return _writeFlatTree(repository, entries);
}

/// Builds and writes tree objects from a flat map of path to entry.
ObjectId _writeFlatTree(
  Repository repository,
  Map<String, TreeEntry> entries,
) {
  final paths = entries.keys.toList()..sort();

  ObjectId level(String prefix, List<String> within) {
    final here = <TreeEntry>[];
    var i = 0;
    while (i < within.length) {
      final rest = within[i].substring(prefix.length);
      final slash = rest.indexOf('/');

      if (slash < 0) {
        final entry = entries[within[i]]!;
        here.add(TreeEntry.named(
          mode: entry.mode,
          name: rest,
          id: entry.id,
        ));
        i += 1;
        continue;
      }

      final name = rest.substring(0, slash);
      final subPrefix = '$prefix$name/';
      final group = <String>[];
      while (i < within.length && within[i].startsWith(subPrefix)) {
        group.add(within[i]);
        i += 1;
      }
      here.add(TreeEntry.named(
        mode: FileMode.directory,
        name: name,
        id: level(subPrefix, group),
      ));
    }
    return repository.objects.write(Tree.build(here));
  }

  return level('', paths);
}

/// Decides every path from the three sides, then writes the result into the
/// working tree and the index.
///
/// This is the part of a merge that has nothing to do with commits: given
/// three trees it produces one, leaving conflicts staged at three stages and
/// marked up on disk. A merge, a cherry-pick, a revert and a rebase differ in
/// which three trees they hand it and what they do afterwards — not in this.
({List<String> conflicts, List<String> updated}) applyTrees(
  Repository repository, {
  required Map<String, TreeEntry> baseFiles,
  required Map<String, TreeEntry> ourFiles,
  required Map<String, TreeEntry> theirFiles,
}) {
  final workTree = repository.workTree;
  if (workTree == null) {
    throw StateError('a bare repository has no working tree to apply to');
  }

  final decided = _mergePaths(repository, baseFiles, ourFiles, theirFiles);
  final resolved = decided.resolved;
  final updated = decided.updated;
  final conflictStages = decided.conflicts;
  final conflicts = conflictStages.keys.toList();

  final paths = <String>{
    ...baseFiles.keys,
    ...ourFiles.keys,
    ...theirFiles.keys,
  }.toList()
    ..sort();

  for (final path in conflicts) {
    final sides = conflictStages[path]!;
    // A side with nothing here — deleted, or renamed away — has nothing to
    // mark up against. Git leaves the surviving version as it is, which is
    // both less noise and the only version there is; with neither side
    // present (the old name of a file renamed two ways) there is no file.
    final survivor = sides.ours == null
        ? sides.theirs
        : sides.theirs == null
            ? sides.ours
            : null;
    if (sides.ours == null || sides.theirs == null) {
      final content = survivor == null ? null : _contentOf(repository, survivor);
      if (content != null) {
        _writeWorkingFile(repository, workTree, path, content);
      } else if (survivor == null) {
        final file =
            fs.file(p.join(workTree, path.replaceAll('/', p.separator)));
        if (file.existsSync()) file.deleteSync();
      }
      continue;
    }

    // The working tree gets our side with markers around what differs, which
    // is what a person needs to see to resolve it.
    final withMarkers = _conflictMarkers(repository, sides);
    if (withMarkers != null) {
      _writeWorkingFile(repository, workTree, path, withMarkers);
    }
  }

  // ---- the working tree ----
  for (final path in paths) {
    final entry = resolved[path];
    if (conflictStages.containsKey(path)) continue;
    if (entry == null) {
      final file = fs.file(p.join(workTree, path.replaceAll('/', p.separator)));
      if (file.existsSync()) file.deleteSync();
      continue;
    }
    if (!updated.contains(path)) continue;
    _writeWorkingFile(
      repository,
      workTree,
      path,
      repository.objects.readTyped<Blob>(entry.id).content,
    );
  }

  // ---- the index ----
  final entries = <IndexEntry>[];
  for (final entry in resolved.entries) {
    entries.add(IndexEntry(
      path: entry.key,
      id: entry.value.id,
      mode: entry.value.mode.numeric,
    ));
  }
  for (final path in conflicts) {
    final sides = conflictStages[path]!;
    // One, two and three: the base, ours and theirs, which is how a conflicted
    // file is represented without a file of its own (`index.stages`).
    if (sides.base case final base?) {
      entries.add(IndexEntry(
        path: path,
        id: base.id,
        mode: base.mode.numeric,
        stage: MergeStage.base,
      ));
    }
    if (sides.ours case final ours?) {
      entries.add(IndexEntry(
        path: path,
        id: ours.id,
        mode: ours.mode.numeric,
        stage: MergeStage.ours,
      ));
    }
    if (sides.theirs case final theirs?) {
      entries.add(IndexEntry(
        path: path,
        id: theirs.id,
        mode: theirs.mode.numeric,
        stage: MergeStage.theirs,
      ));
    }
  }
  GitIndex(entries: entries)
      .writeTo(p.join(repository.gitDirectory, 'index'));

  return (conflicts: conflicts, updated: updated);
}

/// The files of a commit's tree, flattened, for [applyTrees].
Map<String, TreeEntry> filesOf(Repository repository, ObjectId? commit) =>
    commit == null
        ? <String, TreeEntry>{}
        : _flatten(repository, repository.treeOf(commit));

/// Decides every path from the three sides, without touching the working tree
/// or the index.
({
  Map<String, TreeEntry> resolved,
  Map<String, _Sides> conflicts,
  List<String> updated,
}) _mergePaths(
  Repository repository,
  Map<String, TreeEntry> baseFiles,
  Map<String, TreeEntry> ourFiles,
  Map<String, TreeEntry> theirFiles,
) {
  final paired = _pairAcrossRenames(repository, baseFiles, ourFiles, theirFiles);
  final base = paired.base;
  final ours = paired.ours;
  final theirs = paired.theirs;
  final forced = paired.forced;

  final paths = <String>{
    ...base.keys,
    ...ours.keys,
    ...theirs.keys,
    ...forced.keys,
  }.toList()
    ..sort();

  final resolved = <String, TreeEntry>{};
  final conflicts = <String, _Sides>{};
  final updated = <String>[];

  for (final path in paths) {
    if (forced[path] case final sides?) {
      conflicts[path] = sides;
      continue;
    }

    final sides = _Sides(
      base: base[path],
      ours: ours[path],
      theirs: theirs[path],
    );

    final ourId = sides.ours?.id;
    final theirId = sides.theirs?.id;
    final baseId = sides.base?.id;

    // Both sides agree, whether that means the same content or the same
    // deletion.
    if (ourId == theirId) {
      if (sides.ours != null) resolved[path] = sides.ours!;
      continue;
    }

    // Only one side moved: take that side, including a deletion.
    if (ourId == baseId) {
      if (sides.theirs != null) resolved[path] = sides.theirs!;
      updated.add(path);
      continue;
    }
    if (theirId == baseId) {
      if (sides.ours != null) resolved[path] = sides.ours!;
      continue;
    }

    // Both moved. Text can often still be merged line by line.
    final merged = _mergeContent(repository, path, sides);
    if (merged != null) {
      final blob = Blob(merged);
      repository.objects.write(blob);
      resolved[path] = TreeEntry.named(
        mode: sides.ours?.mode ?? sides.theirs!.mode,
        name: path.split('/').last,
        id: blob.id,
      );
      updated.add(path);
      continue;
    }

    conflicts[path] = sides;
  }

  // A file they moved is new to our working tree under its new name even
  // where its content is ours, and its old name has to go.
  for (final path in paired.updated) {
    if (!updated.contains(path)) updated.add(path);
  }

  return (resolved: resolved, conflicts: conflicts, updated: updated);
}

/// The three sides of a merge re-keyed so that a renamed file is compared
/// with itself, plus the paths a rename has already made a conflict of.
///
/// Git stores no renames, so a file one side moved looks, path by path, like a
/// deletion at its old name and an addition at its new one. Merged that way, a
/// rename on one side and an edit on the other is a delete against a modify —
/// a conflict nobody caused — and the edit never reaches the new name. `ort`
/// infers the renames first, base to each side, and then merges the content
/// wherever the file went. This does the same, and then hands the path-by-path
/// merge sides in which a renamed file's base and other-side versions sit at
/// the name it was renamed to.
///
/// Most renames need nothing more than that. The rest are decided here,
/// because only here is it known that a rename was involved, and each is
/// staged the way git stages it:
///
/// * renamed on both sides to the same name is not a conflict at all: the
///   base moves with it and the content merges as usual;
/// * renamed to different names (rename/rename) keeps both names, each
///   holding the merged content, at stage 2 and 3 respectively, with the base
///   at stage 1 under the old name — so nothing is lost whichever the person
///   picks;
/// * renamed on one side and deleted on the other (rename/delete) is staged
///   at the new name with the base and the renaming side, even when the
///   rename changed nothing: the path-by-path rule would otherwise quietly
///   take the deletion, and git asks;
/// * renamed onto a name the other side added (rename/add) is staged like two
///   additions — no base — with the renamed side holding its content already
///   merged with whatever the other side did to the old name.
///
/// Directory renames are not inferred: a file the other side added inside a
/// directory this side renamed stays where it was added.
({
  Map<String, TreeEntry> base,
  Map<String, TreeEntry> ours,
  Map<String, TreeEntry> theirs,
  Map<String, _Sides> forced,
  List<String> updated,
}) _pairAcrossRenames(
  Repository repository,
  Map<String, TreeEntry> baseFiles,
  Map<String, TreeEntry> ourFiles,
  Map<String, TreeEntry> theirFiles,
) {
  final settings = _renameSettings(repository);
  final ourRenames = settings.enabled
      ? _renamesBetween(repository, baseFiles, ourFiles, settings.limit)
      : const <String, String>{};
  final theirRenames = settings.enabled
      ? _renamesBetween(repository, baseFiles, theirFiles, settings.limit)
      : const <String, String>{};

  if (ourRenames.isEmpty && theirRenames.isEmpty) {
    return (
      base: baseFiles,
      ours: ourFiles,
      theirs: theirFiles,
      forced: const {},
      updated: const [],
    );
  }

  final base = {...baseFiles};
  final ours = {...ourFiles};
  final theirs = {...theirFiles};
  final updated = <String>[];

  // What a conflict caused by a rename holds at each stage, where that is not
  // simply what the side has at that path. Kept per stage rather than per
  // path because two renames can land on one name from different sides, and
  // each contributes its own stage.
  final forcedPaths = <String>{};
  final forcedBase = <String, TreeEntry>{};
  final forcedOurs = <String, TreeEntry>{};
  final forcedTheirs = <String, TreeEntry>{};

  final sources = {...ourRenames.keys, ...theirRenames.keys}.toList()..sort();
  for (final source in sources) {
    final original = baseFiles[source]!;
    final ourTarget = ourRenames[source];
    final theirTarget = theirRenames[source];
    base.remove(source);

    if (ourTarget != null && theirTarget != null) {
      if (ourTarget == theirTarget) {
        // Both moved it to the same place: an ordinary merge at that place.
        base[ourTarget] = original;
        continue;
      }
      // rename/rename. Both names are kept, each holding the content merged
      // from all three — the disagreement is about where it lives, not what
      // it says.
      final merged = _mergedEntry(
        repository,
        ourTarget,
        _Sides(
          base: original,
          ours: ourFiles[ourTarget],
          theirs: theirFiles[theirTarget],
        ),
      );
      forcedPaths.addAll([source, ourTarget, theirTarget]);
      forcedBase[source] = original;
      forcedOurs[ourTarget] = _renamed(merged, ourFiles[ourTarget]!, ourTarget);
      forcedTheirs[theirTarget] =
          _renamed(merged, theirFiles[theirTarget]!, theirTarget);
      continue;
    }

    // Renamed on exactly one side. Which one only decides which maps play
    // which part; git's staging is symmetrical.
    final weRenamed = ourTarget != null;
    final target = (ourTarget ?? theirTarget)!;
    final renamer = weRenamed ? ourFiles : theirFiles;
    final other = weRenamed ? theirFiles : ourFiles;
    final otherView = weRenamed ? theirs : ours;
    final forcedRenamer = weRenamed ? forcedOurs : forcedTheirs;

    final otherVersion = other[source];
    otherView.remove(source);

    if (otherVersion == null) {
      // rename/delete.
      forcedPaths.add(target);
      forcedBase[target] = original;
      continue;
    }

    if (other.containsKey(target)) {
      // rename/add: the renamed file's content, merged with what the other
      // side did to it under its old name, against what the other side put
      // at the new name.
      final merged = _mergedEntry(
        repository,
        target,
        weRenamed
            ? _Sides(
                base: original,
                ours: renamer[target],
                theirs: otherVersion,
              )
            : _Sides(
                base: original,
                ours: otherVersion,
                theirs: renamer[target],
              ),
      );
      forcedPaths.add(target);
      forcedRenamer[target] = _renamed(merged, renamer[target]!, target);
      continue;
    }

    // The common case: the other side's version, and the base, move to the
    // new name and the ordinary merge takes it from there.
    base[target] = original;
    otherView[target] = otherVersion;
    // Our working tree still has the file under the old name when it was
    // them who moved it.
    if (!weRenamed) updated.addAll([source, target]);
  }

  return (
    base: base,
    ours: ours,
    theirs: theirs,
    forced: {
      for (final path in forcedPaths)
        path: _Sides(
          base: forcedBase[path] ?? base[path],
          ours: forcedOurs[path] ?? ours[path],
          theirs: forcedTheirs[path] ?? theirs[path],
        ),
    },
    updated: updated,
  );
}

/// Whether a merge looks for renames, and how many candidates it compares
/// before giving up on the inexact ones.
///
/// `merge.renames` falls back to `diff.renames` and both default to on, as in
/// git. `copies` counts as on: a merge has no use for copies, but asking for
/// them certainly did not mean "no renames". The limit is
/// `merge.renameLimit`, then `diff.renameLimit`, then git's merge default of
/// 7000, and as in git it bounds sources times destinations by its square. Zero
/// or less means no limit.
({bool enabled, int limit}) _renameSettings(Repository repository) {
  final config = repository.config;

  bool? flag(String key) {
    final raw = config[key]?.toLowerCase();
    if (raw == 'copies' || raw == 'copy') return true;
    return config.boolean(key);
  }

  final enabled = flag('merge.renames') ?? flag('diff.renames') ?? true;
  final limit = config.number('merge.renameLimit') ??
      config.number('diff.renameLimit') ??
      7000;
  // The largest integer exact on every platform, web included.
  const unlimited = 9007199254740991;
  return (
    enabled: enabled,
    limit: limit <= 0 || limit > 94906265 ? unlimited : limit * limit,
  );
}

/// The renames from [base] to [side], old path to new.
///
/// Only a path gone from the side can be a source and only a path new to it a
/// destination, which is also how git's merge looks: a file still present
/// under its name was edited, not moved, whatever else appeared. Regular
/// files only — a symlink or a submodule turning into a file is not a rename.
Map<String, String> _renamesBetween(
  Repository repository,
  Map<String, TreeEntry> base,
  Map<String, TreeEntry> side,
  int limit,
) {
  final changes = <DiffEntry>[];
  for (final MapEntry(key: path, value: entry) in base.entries) {
    if (side.containsKey(path) || !entry.mode.isBlob) continue;
    changes.add(DiffEntry(
      kind: ChangeKind.deleted,
      oldPath: path,
      oldMode: entry.mode,
      oldId: entry.id,
    ));
  }
  if (changes.isEmpty) return const {};
  final deletions = changes.length;
  for (final MapEntry(key: path, value: entry) in side.entries) {
    if (base.containsKey(path) || !entry.mode.isBlob) continue;
    changes.add(DiffEntry(
      kind: ChangeKind.added,
      newPath: path,
      newMode: entry.mode,
      newId: entry.id,
    ));
  }
  if (changes.length == deletions) return const {};
  changes.sort((a, b) => a.path.compareTo(b.path));

  return {
    for (final change in pairRenames(
      repository.objects,
      changes,
      limit: limit,
    ))
      if (change.kind == ChangeKind.renamed) change.oldPath!: change.newPath!,
  };
}

/// The three versions of one file merged into one, whether or not they merge
/// cleanly.
///
/// A rename conflict still has to stage *something* as the renamed content,
/// and git stages the merge — with markers in it when the edits clashed too.
TreeEntry _mergedEntry(Repository repository, String path, _Sides sides) {
  final ours = sides.ours!;
  final theirs = sides.theirs!;
  final baseId = sides.base?.id;
  if (ours.id == theirs.id || theirs.id == baseId) return ours;
  if (ours.id == baseId) return theirs;

  final content = _mergeContent(repository, path, sides) ??
      _conflictMarkers(repository, sides);
  if (content == null) return ours;
  final blob = Blob(content);
  repository.objects.write(blob);
  return TreeEntry.named(mode: ours.mode, name: ours.name, id: blob.id);
}

/// [merged]'s content under [at]'s mode and name.
TreeEntry _renamed(TreeEntry merged, TreeEntry at, String path) =>
    TreeEntry.named(
      mode: at.mode,
      name: path.split('/').last,
      id: merged.id,
    );

/// Merges [theirs] into the current branch.
///
/// Each path is decided against the common ancestor rather than against the
/// other side: a file only one side touched takes that side's version with no
/// conflict, which is the whole point of a three-way merge and the thing that
/// comparing two sides alone cannot do (`algorithms.three-way-merge`).
///
/// The hooks are `git merge`'s. A merge that writes a commit runs
/// `pre-merge-commit`, then `prepare-commit-msg` and `commit-msg` on
/// `MERGE_MSG`; if any of them fails, the merged index and working tree stay
/// as they are, the merge is left in progress for [Repository.commitIndex] to
/// finish — git's "Not committing merge" — and [HookFailedException] is
/// thrown. Every merge that updates the branch, fast-forwards included, ends
/// with `post-merge` and an argument of 0. [noVerify] skips
/// `pre-merge-commit` and `commit-msg`.
MergeResult merge(
  Repository repository,
  ObjectId theirs, {
  String? message,
  Identity? author,
  bool noVerify = false,
}) {
  final workTree = repository.workTree;
  if (workTree == null) {
    throw StateError('a bare repository has no working tree to merge into');
  }

  final ours = repository.headId;
  if (ours == null) {
    throw StateError('this branch has no commits to merge into');
  }

  final index = repository.index;
  if (index != null && index.hasConflicts) {
    throw StateError('a merge is already in progress');
  }

  final bases = mergeBases(repository, ours, theirs);
  if (bases.contains(theirs) || ours == theirs) {
    return const MergeResult(outcome: MergeOutcome.alreadyUpToDate);
  }

  // Nothing of our own since the base: the branch just moves forward.
  if (bases.length == 1 && bases.single == ours) {
    final result =
        repository.checkout(theirs.hex, detach: true, runHooks: false);
    final branch = repository.refs.currentBranch;
    repository.refs.write(
      branch ?? 'HEAD',
      theirs,
      reflogMessage: 'merge: fast-forward',
    );
    if (branch != null) repository.refs.writeSymbolic('HEAD', branch);
    runHook(repository, 'post-merge', arguments: const ['0'], veto: false);
    return MergeResult(
      outcome: MergeOutcome.fastForward,
      commit: theirs,
      updated: [
        for (var i = 0; i < result.written; i++) '',
      ]..removeWhere((path) => path.isEmpty),
    );
  }

  if (bases.isEmpty) {
    throw StateError(
      'these histories share no commit, so there is nothing to merge against',
    );
  }

  // More than one best ancestor: the bases are merged into each other and the
  // result is what both sides are compared against, so that a change carried
  // by a base we did not pick is not mistaken for a change one side made.
  final base = recursiveMergeBase(repository, [ours], [theirs]);

  final baseFiles = _flattenId(repository, base.tree);
  final ourFiles = _flatten(repository, repository.treeOf(ours));
  final theirFiles = _flatten(repository, repository.treeOf(theirs));

  final applied = applyTrees(
    repository,
    baseFiles: baseFiles,
    ourFiles: ourFiles,
    theirFiles: theirFiles,
  );
  final updated = applied.updated;
  final conflicts = applied.conflicts;

  if (conflicts.isNotEmpty) {
    // What is being merged, so a later commit can record the second parent —
    // and so the repository can say it is mid-merge.
    fs.file(p.join(repository.gitDirectory, 'MERGE_HEAD'))
        .writeAsStringSync('${theirs.hex}\n');
    fs.file(p.join(repository.gitDirectory, 'MERGE_MSG')).writeAsStringSync(
      message ?? 'Merge ${theirs.hex.substring(0, 8)}\n',
    );
    return MergeResult(
      outcome: MergeOutcome.conflicted,
      conflicts: conflicts,
      updated: updated,
    );
  }

  final who = author ?? repository.identityFromConfig();
  if (who == null) {
    throw StateError(
      'no user.name and user.email are configured for this repository',
    );
  }

  final tree = repository.writeTreeFromIndex();
  final String text;
  try {
    if (!noVerify) {
      runHook(repository, 'pre-merge-commit', commitEnvironment: true);
    }
    text = messageThroughHooks(
      repository,
      message: message ?? 'Merge ${theirs.hex.substring(0, 8)}\n',
      file: p.join(repository.gitDirectory, 'MERGE_MSG'),
      source: 'merge',
      noVerify: noVerify,
    );
    if (text.trim().isEmpty) {
      throw StateError('a hook left the merge message empty');
    }
  } on Object {
    // Left mid-merge, with the message as the hooks last saw it, so that
    // committing finishes this merge rather than writing a one-parent commit.
    fs
        .file(p.join(repository.gitDirectory, 'MERGE_HEAD'))
        .writeAsStringSync('${theirs.hex}\n');
    final messageFile = fs.file(p.join(repository.gitDirectory, 'MERGE_MSG'));
    if (!messageFile.existsSync()) {
      messageFile.writeAsStringSync(
        message ?? 'Merge ${theirs.hex.substring(0, 8)}\n',
      );
    }
    rethrow;
  }

  final id = repository.commitTree(
    tree: tree,
    message: text,
    author: who,
    parents: [ours, theirs],
    reflogMessage: 'merge',
  );
  repository.clearMergeState();
  runHook(repository, 'post-merge', arguments: const ['0'], veto: false);

  return MergeResult(
    outcome: MergeOutcome.merged,
    commit: id,
    updated: updated,
  );
}

Map<String, TreeEntry> _flatten(Repository repository, Tree? tree) {
  final out = <String, TreeEntry>{};
  if (tree == null) return out;

  void walk(Tree tree, String prefix) {
    for (final entry in tree.entries) {
      final path = '$prefix${entry.name}';
      if (entry.mode.isTree) {
        walk(repository.objects.readTyped<Tree>(entry.id), '$path/');
      } else {
        out[path] = entry;
      }
    }
  }

  walk(tree, '');
  return out;
}

/// Writes a merge result, converted for the working tree as a checkout would
/// convert it — conflict markers included, as git does.
void _writeWorkingFile(
  Repository repository,
  String workTree,
  String path,
  Uint8List content,
) {
  final file = fs.file(p.join(workTree, path.replaceAll('/', p.separator)))
    ..parent.createSync(recursive: true);
  file.writeAsBytesSync(repository.convertToWorkTree(path, content));
}

Uint8List? _contentOf(Repository repository, TreeEntry? entry) {
  if (entry == null) return Uint8List(0);
  if (!entry.mode.isBlob) return null;
  return repository.objects.readTyped<Blob>(entry.id).content;
}

/// Merges the two sides line by line, or null when they cannot be.
///
/// Each side's changes against the base are found separately, and a line one
/// side changed is taken from that side. Only where both changed the same
/// lines is there nothing to decide from.
Uint8List? _mergeContent(Repository repository, String path, _Sides sides) {
  final base = _contentOf(repository, sides.base);
  final ours = _contentOf(repository, sides.ours);
  final theirs = _contentOf(repository, sides.theirs);
  if (base == null || ours == null || theirs == null) return null;

  // A file deleted on one side and changed on the other is a decision for a
  // person: keeping it silently would discard the deletion and dropping it
  // would discard the change.
  if (sides.ours == null || sides.theirs == null) return null;
  if (looksBinary(base) || looksBinary(ours) || looksBinary(theirs)) {
    return null;
  }

  final merged = mergeLines(
    splitLines(base),
    splitLines(ours),
    splitLines(theirs),
  );
  if (merged == null) return null;

  return Uint8List.fromList(
    utf8.encode(merged.isEmpty ? '' : '${merged.join('\n')}\n'),
  );
}

/// One stretch of the base that a side replaced.
class _Region {
  /// Half-open range of base lines, zero-based.
  final int start;
  final int end;
  final List<String> replacement;

  const _Region(this.start, this.end, this.replacement);

  /// Whether two replacements leave no untouched line between them.
  ///
  /// Touching counts, not only overlapping. Two sides that changed adjacent
  /// lines have no common line left to join their versions on, and two that
  /// both inserted at the same point have nothing to say which insertion comes
  /// first — so neither can be resolved without being told. Git draws the line
  /// in the same place: changes one line apart merge, changes on neighbouring
  /// lines do not.
  ///
  /// With strictly half-open ranges a zero-length insertion never overlaps
  /// anything, including another insertion at the same point, and both sides'
  /// additions were silently kept in an order nobody chose.
  bool overlaps(_Region other) => start <= other.end && other.start <= end;
}

/// Three-way merge over lines. Null when both sides changed the same region.
///
/// Each side is compared with the base rather than with the other side, so a
/// region only one side touched is taken from that side with nothing to
/// decide. Only where the two replaced overlapping stretches is there a
/// conflict — which is exactly the distinction a two-way comparison cannot
/// make (`algorithms.three-way-merge`).
List<String>? mergeLines(
  List<String> base,
  List<String> ours,
  List<String> theirs,
) {
  final ourRegions = _regionsAgainst(base, ours);
  final theirRegions = _regionsAgainst(base, theirs);
  if (ourRegions == null || theirRegions == null) return null;

  String key(_Region region) =>
      '${region.start}:${region.end}:${region.replacement.join(" ")}';

  // Where the two replaced overlapping stretches there is nothing to decide
  // from — unless they made exactly the same replacement, which agrees.
  for (final one in ourRegions) {
    for (final other in theirRegions) {
      if (!one.overlaps(other)) continue;
      if (key(one) != key(other)) return null;
    }
  }

  final ordered = <_Region>[...ourRegions, ...theirRegions]
    ..sort((a, b) => a.start.compareTo(b.start));

  final out = <String>[];
  final applied = <String>{};
  var at = 0;

  for (final region in ordered) {
    // The same region from both sides is applied once.
    if (!applied.add(key(region))) continue;
    if (region.start < at) continue;

    out
      ..addAll(base.sublist(at, region.start))
      ..addAll(region.replacement);
    at = region.end;
  }
  out.addAll(base.sublist(at));

  return out;
}

/// The stretches of [base] that [side] replaced.
List<_Region>? _regionsAgainst(List<String> base, List<String> side) {
  final script = editScript(base, side);
  if (script == null) return null;

  final regions = <_Region>[];
  var baseAt = 0;
  var index = 0;

  while (index < script.length) {
    final line = script[index];
    if (line.kind == LineKind.context) {
      baseAt += 1;
      index += 1;
      continue;
    }

    // A run of changes: what it removes from the base, and what it puts back.
    final start = baseAt;
    final replacement = <String>[];
    while (index < script.length && script[index].kind != LineKind.context) {
      if (script[index].kind == LineKind.deleted) {
        baseAt += 1;
      } else {
        replacement.add(script[index].text);
      }
      index += 1;
    }
    regions.add(_Region(start, baseAt, replacement));
  }

  return regions;
}

/// Our side with the usual markers around what differs.
Uint8List? _conflictMarkers(Repository repository, _Sides sides) {
  final ours = _contentOf(repository, sides.ours);
  final theirs = _contentOf(repository, sides.theirs);
  if (ours == null || theirs == null) return null;
  if (looksBinary(ours) || looksBinary(theirs)) return null;

  final out = StringBuffer()
    ..writeln('<<<<<<< ours')
    ..write(utf8.decode(ours, allowMalformed: true))
    ..writeln('=======')
    ..write(utf8.decode(theirs, allowMalformed: true))
    ..writeln('>>>>>>> theirs');
  return Uint8List.fromList(utf8.encode(out.toString()));
}

/// Fetches from a remote and merges what arrived into the current branch.
///
/// Two operations rather than one, which is what a pull has always been. It
/// is offered as one because that is how it is used, and reported as two
/// because when it goes wrong the answer depends on which half went wrong.
Future<MergeResult> mergeTrackingRef(
  Repository repository,
  String trackingRef, {
  String? message,
  Identity? author,
  bool noVerify = false,
}) async {
  final theirs = repository.refs.resolve(trackingRef);
  if (theirs == null) {
    throw StateError('there is no $trackingRef to merge');
  }
  return merge(
    repository,
    theirs,
    message: message ?? 'Merge $trackingRef\n',
    author: author,
    noVerify: noVerify,
  );
}
