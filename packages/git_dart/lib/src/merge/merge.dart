import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../diff/text_diff.dart';
import '../fs/git_fs.dart';
import '../graph/graph_walks.dart';
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
    // The working tree gets our side with markers around what differs, which
    // is what a person needs to see to resolve it.
    final withMarkers = _conflictMarkers(repository, conflictStages[path]!);
    if (withMarkers != null) {
      _writeWorkingFile(workTree, path, withMarkers);
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
  final paths = <String>{
    ...baseFiles.keys,
    ...ourFiles.keys,
    ...theirFiles.keys,
  }.toList()
    ..sort();

  final resolved = <String, TreeEntry>{};
  final conflicts = <String, _Sides>{};
  final updated = <String>[];

  for (final path in paths) {
    final sides = _Sides(
      base: baseFiles[path],
      ours: ourFiles[path],
      theirs: theirFiles[path],
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

  return (resolved: resolved, conflicts: conflicts, updated: updated);
}

/// Merges [theirs] into the current branch.
///
/// Each path is decided against the common ancestor rather than against the
/// other side: a file only one side touched takes that side's version with no
/// conflict, which is the whole point of a three-way merge and the thing that
/// comparing two sides alone cannot do (`algorithms.three-way-merge`).
MergeResult merge(
  Repository repository,
  ObjectId theirs, {
  String? message,
  Identity? author,
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
    final result = repository.checkout(theirs.hex, detach: true);
    final branch = repository.refs.currentBranch;
    repository.refs.write(
      branch ?? 'HEAD',
      theirs,
      reflogMessage: 'merge: fast-forward',
    );
    if (branch != null) repository.refs.writeSymbolic('HEAD', branch);
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
  final id = repository.commitTree(
    tree: tree,
    message: message ?? 'Merge ${theirs.hex.substring(0, 8)}\n',
    author: who,
    parents: [ours, theirs],
    reflogMessage: 'merge',
  );

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

void _writeWorkingFile(String workTree, String path, Uint8List content) {
  final file = fs.file(p.join(workTree, path.replaceAll('/', p.separator)))
    ..parent.createSync(recursive: true);
  file.writeAsBytesSync(content);
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
  );
}
