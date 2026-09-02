/// A readable name for a commit — `v1.2.0-14-gabc1234`.
///
/// Three parts: the nearest tag that can reach the commit, how many commits
/// lie between them, and an abbreviation of the commit's own name. Together
/// they answer "where am I?" in a way a bare object name cannot, which is why
/// this string ends up in version numbers and bug reports.
///
/// "Nearest" is measured in commits, not in time: the tag with the fewest
/// commits between it and here wins. A tag on a branch that was merged long
/// ago can therefore be closer than one made yesterday, and that is the right
/// answer — it is the tag whose release this commit is built on.
library;

import 'dart:collection';

import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/tag.dart';
import '../repository.dart';

class Description {
  /// The tag that was found, without its `refs/tags/` prefix.
  final String tag;

  /// The commit the tag names, after peeling an annotated tag.
  final ObjectId taggedCommit;

  /// How many commits are reachable from the described commit but not from
  /// the tag. Zero means the commit *is* the tagged one.
  final int distance;

  final ObjectId commit;

  /// How much of the object name to show. Grown until it is unambiguous, the
  /// way git grows it.
  final int abbreviation;

  const Description({
    required this.tag,
    required this.taggedCommit,
    required this.distance,
    required this.commit,
    required this.abbreviation,
  });

  bool get isExact => distance == 0;

  /// `v1.2.0` when the commit is the tagged one, `v1.2.0-14-gabc1234` when it
  /// is not.
  ///
  /// The `g` is not decoration: it says the hex that follows is a git object
  /// name, which is what lets a reader tell this from a version number that
  /// happens to end in hex.
  @override
  String toString() => isExact
      ? tag
      : '$tag-$distance-g${commit.hex.substring(0, abbreviation)}';
}

/// Names [commit] by the nearest tag that can reach it.
///
/// Returns null when no tag can — which is not a failure but an answer: a
/// repository with no tags, or a commit on a branch that predates all of
/// them, genuinely has no such name. Git reports the same case as an error;
/// callers here can decide.
///
/// [candidates] bounds how many tagged commits are considered and
/// [maxCommits] how far the walk goes, because the search is over the history
/// and a repository can have a great deal of it.
Description? describe(
  Repository repository, {
  ObjectId? commit,
  bool annotatedOnly = false,
  int candidates = 10,
  int maxCommits = 100000,
}) {
  final target = commit ?? repository.headId;
  if (target == null) return null;

  final peeled = repository.peel(target);
  if (peeled is! Commit) return null;

  // Every tag, by the commit it ultimately points at. An annotated tag and a
  // lightweight one are the same thing here: what matters is where it lands.
  final tagsByCommit = <ObjectId, String>{};
  for (final ref in repository.refs.tags) {
    final id = repository.refs.resolve(ref.path);
    if (id == null) continue;

    final object = repository.objects.readRaw(id) == null
        ? null
        : repository.objects.read(id);
    if (annotatedOnly && object is! Tag) continue;

    final landsOn = object is Tag ? repository.peel(id) : object;
    if (landsOn is! Commit) continue;

    // A commit with two tags keeps the first by name, so the answer does not
    // depend on the order the refs happened to be listed in.
    final existing = tagsByCommit[landsOn.id];
    if (existing == null || ref.shortName.compareTo(existing) < 0) {
      tagsByCommit[landsOn.id] = ref.shortName;
    }
  }

  if (tagsByCommit.isEmpty) return null;

  // Walk back from the commit, newest first, counting as we go. The first
  // tagged commit met is the nearest by depth, which is what git reports.
  final queue = SplayTreeSet<Commit>((a, b) {
    final byDate = b.committer.seconds.compareTo(a.committer.seconds);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  });
  final seen = <ObjectId>{peeled.id};
  queue.add(peeled);

  ({String tag, ObjectId at})? best;
  var walked = 0;
  var found = 0;

  while (queue.isNotEmpty && walked < maxCommits) {
    final current = queue.first;
    queue.remove(current);
    walked += 1;

    final tag = tagsByCommit[current.id];
    if (tag != null) {
      best ??= (tag: tag, at: current.id);
      found += 1;
      // Deeper tags can only be further away, and git stops looking after a
      // handful for the same reason: the nearest is nearly always the first.
      if (found >= candidates) break;
      continue;
    }

    for (final parent in repository.presentParentsOf(current)) {
      if (!seen.add(parent)) continue;
      final object = repository.objects.readRaw(parent) == null
          ? null
          : repository.objects.read(parent);
      if (object is Commit) queue.add(object);
    }
  }

  if (best == null) return null;

  // The distance is what the tag cannot reach, not the number of steps the
  // walk happened to take: a merge means several paths of different lengths,
  // and git counts commits rather than steps.
  final distance = _countAhead(repository, peeled.id, best.at, maxCommits);

  return Description(
    tag: best.tag,
    taggedCommit: best.at,
    distance: distance,
    commit: peeled.id,
    abbreviation: _abbreviationFor(repository, peeled.id),
  );
}

/// Commits reachable from [from] and not from [notFrom].
int _countAhead(
  Repository repository,
  ObjectId from,
  ObjectId notFrom,
  int maxCommits,
) {
  if (from == notFrom) return 0;

  final excluded = <ObjectId>{};
  final pending = <ObjectId>[notFrom];
  while (pending.isNotEmpty && excluded.length < maxCommits) {
    final id = pending.removeLast();
    if (!excluded.add(id)) continue;
    final object = repository.objects.readRaw(id) == null
        ? null
        : repository.objects.read(id);
    if (object is Commit) pending.addAll(repository.presentParentsOf(object));
  }

  final counted = <ObjectId>{};
  final walk = <ObjectId>[from];
  while (walk.isNotEmpty && counted.length < maxCommits) {
    final id = walk.removeLast();
    if (excluded.contains(id) || !counted.add(id)) continue;
    final object = repository.objects.readRaw(id) == null
        ? null
        : repository.objects.read(id);
    if (object is Commit) walk.addAll(repository.presentParentsOf(object));
  }

  return counted.length;
}

/// The shortest prefix that names this commit and no other.
///
/// Seven characters is git's traditional floor and is usually enough; it grows
/// only where the repository has two objects sharing that prefix, which is
/// exactly when showing seven would be a lie.
int _abbreviationFor(Repository repository, ObjectId id) {
  const minimum = 7;
  final hex = id.hex;

  var length = minimum;
  while (length < ObjectId.hexLength) {
    final prefix = hex.substring(0, length);
    var matches = 0;
    for (final other in repository.objects.listAll()) {
      if (!other.hex.startsWith(prefix)) continue;
      matches += 1;
      if (matches > 1) break;
    }
    if (matches <= 1) return length;
    length += 1;
  }
  return ObjectId.hexLength;
}
