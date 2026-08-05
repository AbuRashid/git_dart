import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../diff/text_diff.dart';
import '../index/git_index.dart';
import '../object_id.dart';
import '../objects/commit.dart';
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
List<ObjectId> mergeBases(Repository repository, ObjectId a, ObjectId b) {
  Set<ObjectId>? ancestorsOf(ObjectId from) {
    final seen = <ObjectId>{};
    final pending = <ObjectId>[from];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!seen.add(id)) continue;
      final raw = repository.objects.readRaw(id);
      if (raw == null) continue;
      final object = GitObject.parse(raw.kind, raw.content);
      if (object is Commit) pending.addAll(object.parents);
    }
    return seen;
  }

  final fromA = ancestorsOf(a);
  final fromB = ancestorsOf(b);
  final common = fromA!.intersection(fromB!);
  if (common.isEmpty) return const [];

  // A best common ancestor is one no other common ancestor can reach: the
  // maximal elements. Anything reachable from another common ancestor is
  // further back and would make a worse base.
  final reachableFromOtherCommon = <ObjectId>{};
  for (final id in common) {
    final raw = repository.objects.readRaw(id);
    if (raw == null) continue;
    final object = GitObject.parse(raw.kind, raw.content);
    if (object is! Commit) continue;
    final pending = <ObjectId>[...object.parents];
    final seen = <ObjectId>{};
    while (pending.isNotEmpty) {
      final ancestor = pending.removeLast();
      if (!seen.add(ancestor)) continue;
      if (common.contains(ancestor)) reachableFromOtherCommon.add(ancestor);
      final parentRaw = repository.objects.readRaw(ancestor);
      if (parentRaw == null) continue;
      final parent = GitObject.parse(parentRaw.kind, parentRaw.content);
      if (parent is Commit) pending.addAll(parent.parents);
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
    repository.refs.write(branch ?? 'HEAD', theirs);
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

  // More than one best ancestor is possible. Picking the first is what makes
  // such a merge a guess rather than a derivation, so the caller is told.
  final base = bases.first;

  final baseFiles = _flatten(repository, repository.treeOf(base));
  final ourFiles = _flatten(repository, repository.treeOf(ours));
  final theirFiles = _flatten(repository, repository.treeOf(theirs));

  final paths = <String>{
    ...baseFiles.keys,
    ...ourFiles.keys,
    ...theirFiles.keys,
  }.toList()
    ..sort();

  final resolved = <String, TreeEntry>{};
  final conflicts = <String>[];
  final updated = <String>[];
  final conflictStages = <String, _Sides>{};

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
      if (sides.theirs != null) {
        resolved[path] = sides.theirs!;
      }
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

    conflicts.add(path);
    conflictStages[path] = sides;
    // The working tree gets our side with markers around what differs, which
    // is what a person needs to see to resolve it.
    final withMarkers = _conflictMarkers(repository, sides);
    if (withMarkers != null) {
      _writeWorkingFile(workTree, path, withMarkers);
    }
  }

  // ---- the working tree ----
  for (final path in paths) {
    final entry = resolved[path];
    if (conflictStages.containsKey(path)) continue;
    if (entry == null) {
      final file = File(p.join(workTree, path.replaceAll('/', p.separator)));
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
    // One, two and three: the base, ours and theirs, which is how a
    // conflicted file is represented without a file of its own (`index.stages`).
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

  if (conflicts.isNotEmpty) {
    // What is being merged, so a later commit can record the second parent —
    // and so the repository can say it is mid-merge.
    File(p.join(repository.gitDirectory, 'MERGE_HEAD'))
        .writeAsStringSync('${theirs.hex}\n');
    File(p.join(repository.gitDirectory, 'MERGE_MSG')).writeAsStringSync(
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
  final file = File(p.join(workTree, path.replaceAll('/', p.separator)))
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

  bool overlaps(_Region other) => start < other.end && other.start < end;
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
