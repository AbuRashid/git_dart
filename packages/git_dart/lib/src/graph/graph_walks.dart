/// Graph questions, answered with the commit-graph's help when it is there.
///
/// Every function here gives the same answer with or without the cache. The
/// cache only decides how much of the history has to be read to reach it —
/// which, on a repository of any size, is the difference between an answer and
/// a wait.
library;

import '../object_id.dart';
import '../objects/commit.dart';
import '../repository.dart';

/// A commit's parents and generation, from the cache or from the object.
class GraphNode {
  final ObjectId id;
  final List<ObjectId> parents;
  final int commitTime;

  /// Null when there is no commit-graph, meaning nothing can be pruned.
  final int? generation;

  const GraphNode({
    required this.id,
    required this.parents,
    required this.commitTime,
    this.generation,
  });
}

/// Reads commits, preferring the graph and falling back to the object store.
///
/// The fallback is not a lesser path — it is the only path in a repository
/// with no cache, and it has to give the same answers. What it cannot give is
/// a generation number, and every caller here is written so that a missing
/// generation costs speed and never correctness.
class GraphReader {
  final Repository repository;
  final _cache = <ObjectId, GraphNode?>{};

  GraphReader(this.repository);

  GraphNode? operator [](ObjectId id) {
    if (_cache.containsKey(id)) return _cache[id];
    return _cache[id] = _read(id);
  }

  GraphNode? _read(ObjectId id) {
    final graph = repository.commitGraph;
    if (graph != null) {
      final entry = graph.entryFor(id);
      if (entry != null) {
        return GraphNode(
          id: id,
          parents: entry.parents,
          commitTime: entry.commitTime,
          generation: entry.generation,
        );
      }
    }

    final raw = repository.objects.readRaw(id);
    if (raw == null) return null;
    final object = repository.objects.read(id);
    if (object is! Commit) return null;
    return GraphNode(
      id: id,
      parents: object.parents,
      commitTime: object.committer.seconds,
    );
  }

  /// True when the graph can be trusted to prune between these two.
  ///
  /// Only when *both* have a generation: comparing a number against a commit
  /// that has none proves nothing.
  bool canPrune(GraphNode a, GraphNode b) =>
      a.generation != null && b.generation != null;
}

/// Whether [ancestor] is reachable from [descendant].
///
/// The generation number ends this early in the common case. If the supposed
/// ancestor sits at a higher level than the commit being searched, no path can
/// run from one to the other, and the answer is no without reading anything —
/// which is what makes "is this branch merged" cheap rather than a full walk.
bool isAncestor(
  Repository repository,
  ObjectId ancestor,
  ObjectId descendant, {
  GraphReader? using,
}) {
  if (ancestor == descendant) return true;

  final reader = using ?? GraphReader(repository);
  final target = reader[ancestor];
  final start = reader[descendant];
  if (target == null || start == null) return false;

  final floor = target.generation;

  final seen = <ObjectId>{};
  // Deepest first, so the walk moves towards the target rather than fanning
  // out across the whole history.
  final queue = HeapPriorityQueue<GraphNode>((a, b) {
    final byGeneration =
        (b.generation ?? 0).compareTo(a.generation ?? 0);
    if (byGeneration != 0) return byGeneration;
    return b.commitTime.compareTo(a.commitTime);
  })
    ..add(start);
  seen.add(descendant);

  while (queue.isNotEmpty) {
    final node = queue.removeFirst();
    if (node.id == ancestor) return true;

    // Everything left in the queue is at or below this level, and the target
    // is above it: no path can reach back up.
    if (floor != null &&
        node.generation != null &&
        node.generation! < floor) {
      continue;
    }

    for (final parent in node.parents) {
      if (!seen.add(parent)) continue;
      final next = reader[parent];
      if (next == null) continue;
      if (floor != null &&
          next.generation != null &&
          next.generation! < floor) {
        // Below the target's level; it cannot be the target and nothing
        // above it lies through here.
        continue;
      }
      queue.add(next);
    }
  }

  return false;
}

/// A minimal priority queue, so this file does not pull in a dependency for
/// one data structure.
class HeapPriorityQueue<T> {
  final int Function(T, T) _compare;
  final List<T> _items = [];

  HeapPriorityQueue(this._compare);

  bool get isNotEmpty => _items.isNotEmpty;
  int get length => _items.length;

  void add(T value) {
    _items.add(value);
    var child = _items.length - 1;
    while (child > 0) {
      final parent = (child - 1) >> 1;
      if (_compare(_items[child], _items[parent]) >= 0) break;
      final swap = _items[child];
      _items[child] = _items[parent];
      _items[parent] = swap;
      child = parent;
    }
  }

  T removeFirst() {
    final first = _items.first;
    final last = _items.removeLast();
    if (_items.isNotEmpty) {
      _items[0] = last;
      var parent = 0;
      while (true) {
        final left = parent * 2 + 1;
        final right = left + 1;
        var smallest = parent;
        if (left < _items.length &&
            _compare(_items[left], _items[smallest]) < 0) {
          smallest = left;
        }
        if (right < _items.length &&
            _compare(_items[right], _items[smallest]) < 0) {
          smallest = right;
        }
        if (smallest == parent) break;
        final swap = _items[parent];
        _items[parent] = _items[smallest];
        _items[smallest] = swap;
        parent = smallest;
      }
    }
    return first;
  }
}

/// Commits reachable from [from] and not from [notFrom].
///
/// The pair of these is what `ahead` and `behind` are, and computing them by
/// collecting both full ancestries and subtracting is exact and costs the size
/// of the history. This walks both frontiers together, deepest first, and
/// stops as soon as everything left is common — which on two branches that
/// diverged recently is a handful of commits rather than all of them.
({int ahead, int behind}) countDivergence(
  Repository repository,
  ObjectId ours,
  ObjectId theirs, {
  GraphReader? using,
}) {
  if (ours == theirs) return (ahead: 0, behind: 0);

  final reader = using ?? GraphReader(repository);

  // Which side each commit has been reached from. A commit reached from both
  // is common, and neither side counts it.
  const fromOurs = 1;
  const fromTheirs = 2;
  const fromBoth = 3;

  final flags = <ObjectId, int>{};
  final queue = HeapPriorityQueue<GraphNode>((a, b) {
    final byGeneration = (b.generation ?? 0).compareTo(a.generation ?? 0);
    if (byGeneration != 0) return byGeneration;
    final byTime = b.commitTime.compareTo(a.commitTime);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });

  void start(ObjectId id, int flag) {
    final node = reader[id];
    if (node == null) return;
    flags[id] = (flags[id] ?? 0) | flag;
    queue.add(node);
  }

  start(ours, fromOurs);
  start(theirs, fromTheirs);

  var ahead = 0;
  var behind = 0;
  // How many entries in the queue are not yet known to be common. Once that
  // reaches zero every remaining path leads only through shared history.
  var interesting = queue.length;

  while (queue.isNotEmpty && interesting > 0) {
    final node = queue.removeFirst();
    final flag = flags[node.id] ?? 0;

    if (flag != fromBoth) {
      if (flag == fromOurs) {
        ahead += 1;
      } else if (flag == fromTheirs) {
        behind += 1;
      }
      interesting -= 1;
    }

    for (final parent in node.parents) {
      final already = flags[parent] ?? 0;
      final now = already | flag;
      if (already == now) continue;

      flags[parent] = now;
      final next = reader[parent];
      if (next == null) continue;

      if (already == 0) {
        queue.add(next);
        if (now != fromBoth) interesting += 1;
      } else if (already != fromBoth && now == fromBoth) {
        // It was counted as one side's and has turned out to be shared.
        interesting -= 1;
      }
    }
  }

  return (ahead: ahead, behind: behind);
}

/// Commits reachable from [start], parents always after their children.
///
/// Date order is what a log listing usually wants and it is not a *shape*: two
/// commits made in the same second order arbitrarily, and a merge whose sides
/// were committed out of order interleaves. Topological order is the honest
/// one — it never shows a commit before something it is built on — and it
/// costs a pass over the reachable set to find, because a commit cannot be
/// emitted until everything that reaches it has been.
Iterable<ObjectId> topologicalOrder(
  Repository repository,
  ObjectId start, {
  GraphReader? using,
  int? limit,
}) sync* {
  final reader = using ?? GraphReader(repository);

  // How many children still have to be emitted before each commit may be.
  final pending = <ObjectId, int>{};
  final order = <ObjectId>[];
  final seen = <ObjectId>{start};
  final walk = <ObjectId>[start];

  while (walk.isNotEmpty) {
    final id = walk.removeLast();
    final node = reader[id];
    if (node == null) continue;
    order.add(id);
    for (final parent in node.parents) {
      pending[parent] = (pending[parent] ?? 0) + 1;
      if (seen.add(parent)) walk.add(parent);
    }
  }

  // Among those ready to be emitted, newest first — so the order is
  // topological but still reads like a history.
  //
  // Deliberately *not* ordered by generation, even though it is to hand. A
  // generation is null when there is no commit-graph, so using it would make
  // the order depend on whether the cache exists — and a cache that changes
  // the answer is not a cache. Commits sharing a second fall back to their
  // names, which is arbitrary but is at least the same arbitrary every time.
  final ready = HeapPriorityQueue<GraphNode>((a, b) {
    final byTime = b.commitTime.compareTo(a.commitTime);
    if (byTime != 0) return byTime;
    return a.id.compareTo(b.id);
  });

  for (final id in order) {
    if ((pending[id] ?? 0) == 0) {
      final node = reader[id];
      if (node != null) ready.add(node);
    }
  }

  var emitted = 0;
  while (ready.isNotEmpty) {
    final node = ready.removeFirst();
    yield node.id;
    emitted += 1;
    if (limit != null && emitted >= limit) return;

    for (final parent in node.parents) {
      final left = (pending[parent] ?? 0) - 1;
      pending[parent] = left;
      if (left > 0) continue;
      final next = reader[parent];
      if (next != null) ready.add(next);
    }
  }
}
