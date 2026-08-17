/// The commit-graph: a cache of the commit history's shape.
///
/// Every interesting question about history is a graph walk — is this an
/// ancestor of that, where did these two branches diverge, how far ahead is
/// this branch — and answering one from the object store means reading and
/// inflating a commit object per step. On a large repository that is hundreds
/// of thousands of reads to answer a question about two commits.
///
/// This file holds, for every commit, its tree, its parents *by position*, its
/// commit time, and a generation number. The positions turn parent lookup into
/// an array index. The generation number is what turns the walks from
/// exhaustive into pruned: it is defined so that a parent's generation is
/// always lower than its child's, which means a commit with a higher
/// generation than another cannot possibly be its ancestor — and that single
/// fact ends most searches early.
///
/// It is only a cache. Everything here can be recomputed from the objects, and
/// a repository with no commit-graph gives the same answers more slowly. It is
/// never consulted for what is *true*, only for what can be skipped.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../object_id.dart';

/// What the file records about one commit.
class CommitGraphEntry {
  final ObjectId id;
  final ObjectId tree;
  final List<ObjectId> parents;

  /// Seconds since the epoch, as the commit records.
  final int commitTime;

  /// The topological level: one more than the deepest of its parents, and one
  /// for a commit with none.
  ///
  /// The only property relied on is that a parent's is always lower than its
  /// child's. Git has since defined a second, better generation number based
  /// on corrected commit dates; both satisfy that property, which is why
  /// reading either would do.
  final int generation;

  const CommitGraphEntry({
    required this.id,
    required this.tree,
    required this.parents,
    required this.commitTime,
    required this.generation,
  });

  @override
  String toString() => '${id.hex.substring(0, 8)} gen $generation';
}

/// A commit-graph file, read in place.
class CommitGraph {
  static const List<int> _signature = [0x43, 0x47, 0x50, 0x48]; // 'CGPH'

  /// No parent in this position.
  static const int _noParent = 0x70000000;

  /// The parent list continues in the extra edge chunk.
  static const int _extraEdges = 0x80000000;

  /// The largest generation the format can hold; beyond it git stores this
  /// value and readers stop trusting the number to prune.
  static const int generationMax = 0x3fffffff;

  final Uint8List bytes;
  final int count;

  final Uint32List _fanout;
  final int _namesAt;
  final int _dataAt;
  final int? _edgesAt;

  CommitGraph._({
    required this.bytes,
    required this.count,
    required Uint32List fanout,
    required int namesAt,
    required int dataAt,
    int? edgesAt,
  })  : _fanout = fanout,
        _namesAt = namesAt,
        _dataAt = dataAt,
        _edgesAt = edgesAt;

  /// Opens the graph for a repository, or null when there is none.
  ///
  /// A missing file is the ordinary case, not an error: the cache is optional
  /// and everything works without it.
  static CommitGraph? open(String gitDirectory) {
    final file = fs.file(
      p.join(gitDirectory, 'objects', 'info', 'commit-graph'),
    );
    if (!file.existsSync()) return null;
    try {
      return CommitGraph.parse(file.readAsBytesSync());
    } on FormatException {
      // A cache that cannot be read is a cache that is not used. Refusing to
      // open the repository over it would be letting an optimisation decide
      // whether the repository works.
      return null;
    }
  }

  factory CommitGraph.parse(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const FormatException('commit-graph is too short');
    }
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _signature[i]) {
        throw const FormatException('not a commit-graph: no CGPH signature');
      }
    }

    final version = bytes[4];
    if (version != 1) {
      throw FormatException('unsupported commit-graph version $version');
    }
    final hashVersion = bytes[5];
    if (hashVersion != 1) {
      throw FormatException(
        'commit-graph uses hash version $hashVersion, not SHA-1',
      );
    }
    final chunkCount = bytes[6];
    final baseGraphs = bytes[7];
    if (baseGraphs != 0) {
      // A split graph is a chain of files, each layered on the last. Refused
      // rather than half-read: reading only the top layer would report a
      // commit as absent that is merely in a lower one.
      throw const FormatException(
        'split commit-graphs are not read by this implementation',
      );
    }

    final view = ByteData.sublistView(bytes);
    final chunks = <int, int>{};
    var at = 8;
    for (var i = 0; i <= chunkCount; i++) {
      if (at + 12 > bytes.length) {
        throw const FormatException('commit-graph chunk table is truncated');
      }
      final id = view.getUint32(at);
      final offset = view.getUint64(at + 4);
      chunks[id] = offset;
      at += 12;
    }

    int? chunk(String name) => chunks[_chunkId(name)];

    final fanoutAt = chunk('OIDF');
    final namesAt = chunk('OIDL');
    final dataAt = chunk('CDAT');
    if (fanoutAt == null || namesAt == null || dataAt == null) {
      throw const FormatException(
        'commit-graph is missing one of OIDF, OIDL or CDAT',
      );
    }

    final fanout = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      fanout[i] = view.getUint32(fanoutAt + i * 4);
    }

    return CommitGraph._(
      bytes: bytes,
      count: fanout[255],
      fanout: fanout,
      namesAt: namesAt,
      dataAt: dataAt,
      edgesAt: chunk('EDGE'),
    );
  }

  static int _chunkId(String name) =>
      (name.codeUnitAt(0) << 24) |
      (name.codeUnitAt(1) << 16) |
      (name.codeUnitAt(2) << 8) |
      name.codeUnitAt(3);

  /// Each entry is the tree, two parent slots, then the packed generation and
  /// commit time.
  static const int _entrySize = ObjectId.byteLength + 16;

  ObjectId nameAt(int position) =>
      ObjectId.fromBytes(bytes, _namesAt + position * ObjectId.byteLength);

  /// Where [id] sits, or null when the graph does not hold it.
  ///
  /// The fanout narrows the search to one 256th before the binary search
  /// starts, exactly as a pack index does.
  int? positionOf(ObjectId id) {
    final first = id.bytes[0];
    var low = first == 0 ? 0 : _fanout[first - 1];
    var high = _fanout[first];

    while (low < high) {
      final middle = (low + high) >> 1;
      final comparison = _compareAt(middle, id.bytes);
      if (comparison < 0) {
        low = middle + 1;
      } else if (comparison > 0) {
        high = middle;
      } else {
        return middle;
      }
    }
    return null;
  }

  int _compareAt(int position, Uint8List target) {
    final base = _namesAt + position * ObjectId.byteLength;
    for (var i = 0; i < ObjectId.byteLength; i++) {
      final d = bytes[base + i] - target[i];
      if (d != 0) return d;
    }
    return 0;
  }

  bool contains(ObjectId id) => positionOf(id) != null;

  CommitGraphEntry? entryFor(ObjectId id) {
    final position = positionOf(id);
    return position == null ? null : entryAt(position);
  }

  CommitGraphEntry entryAt(int position) {
    final view = ByteData.sublistView(bytes);
    final at = _dataAt + position * _entrySize;

    final tree = ObjectId.fromBytes(bytes, at);
    final first = view.getUint32(at + ObjectId.byteLength);
    final second = view.getUint32(at + ObjectId.byteLength + 4);
    final packed = view.getUint32(at + ObjectId.byteLength + 8);
    final lowTime = view.getUint32(at + ObjectId.byteLength + 12);

    final parents = <ObjectId>[];
    if (first != _noParent) parents.add(nameAt(first));

    if (second != _noParent) {
      if (second & _extraEdges != 0) {
        // Three parents or more: the rest live in their own chunk, ending
        // with one that has its top bit set.
        final edges = _edgesAt;
        if (edges == null) {
          throw const FormatException(
            'commit-graph names extra edges but has no EDGE chunk',
          );
        }
        var index = second & ~_extraEdges;
        while (true) {
          final value = view.getUint32(edges + index * 4);
          parents.add(nameAt(value & ~_extraEdges));
          if (value & _extraEdges != 0) break;
          index += 1;
        }
      } else {
        parents.add(nameAt(second));
      }
    }

    // The generation takes the top thirty bits; the commit time is the other
    // thirty-four, its highest two sharing the first word.
    return CommitGraphEntry(
      id: nameAt(position),
      tree: tree,
      parents: parents,
      generation: packed >> 2,
      commitTime: ((packed & 0x3) << 32) | lowTime,
    );
  }

  /// Every commit in the graph, in the order it stores them.
  Iterable<CommitGraphEntry> entries() sync* {
    for (var i = 0; i < count; i++) {
      yield entryAt(i);
    }
  }

  Iterable<ObjectId> listAll() sync* {
    for (var i = 0; i < count; i++) {
      yield nameAt(i);
    }
  }
}

/// One commit, as the writer needs it.
class CommitGraphInput {
  final ObjectId id;
  final ObjectId tree;
  final List<ObjectId> parents;
  final int commitTime;

  const CommitGraphInput({
    required this.id,
    required this.tree,
    required this.parents,
    required this.commitTime,
  });
}

/// Builds a commit-graph file.
class CommitGraphWriter {
  /// Serialises a graph for [commits].
  ///
  /// The set must be closed under parents: a commit whose parent is absent
  /// cannot record a position for it, and a graph that claimed such a commit
  /// had no parent would make every walk through it wrong. Parents that are
  /// missing are therefore a reason to leave the child out, not to write it
  /// with a gap.
  static Uint8List build(Iterable<CommitGraphInput> commits) {
    final present = {for (final commit in commits) commit.id: commit};

    // Only commits whose whole ancestry is here. Dropping one may orphan
    // another, so this settles rather than filtering once.
    final kept = <ObjectId, CommitGraphInput>{...present};
    var settled = false;
    while (!settled) {
      settled = true;
      for (final id in kept.keys.toList()) {
        final commit = kept[id]!;
        if (commit.parents.every(kept.containsKey)) continue;
        kept.remove(id);
        settled = false;
      }
    }

    final sorted = kept.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final positions = <ObjectId, int>{
      for (var i = 0; i < sorted.length; i++) sorted[i].id: i,
    };

    final generations = _generations(sorted, kept);

    // Extra edges, for commits with more than two parents.
    final extra = <int>[];
    final extraAt = <ObjectId, int>{};
    for (final commit in sorted) {
      if (commit.parents.length <= 2) continue;
      extraAt[commit.id] = extra.length;
      for (var i = 1; i < commit.parents.length; i++) {
        final position = positions[commit.parents[i]]!;
        extra.add(
          i == commit.parents.length - 1
              ? position | CommitGraph._extraEdges
              : position,
        );
      }
    }

    final count = sorted.length;
    final chunks = <String>[
      'OIDF',
      'OIDL',
      'CDAT',
      if (extra.isNotEmpty) 'EDGE',
    ];

    const headerSize = 8;
    final tableSize = (chunks.length + 1) * 12;
    final sizes = <String, int>{
      'OIDF': 256 * 4,
      'OIDL': count * ObjectId.byteLength,
      'CDAT': count * CommitGraph._entrySize,
      'EDGE': extra.length * 4,
    };

    var offset = headerSize + tableSize;
    final offsets = <String, int>{};
    for (final chunk in chunks) {
      offsets[chunk] = offset;
      offset += sizes[chunk]!;
    }
    final total = offset + ObjectId.byteLength;

    final out = Uint8List(total);
    final view = ByteData.sublistView(out);

    // ---- header ----
    out.setRange(0, 4, CommitGraph._signature);
    out[4] = 1; // version
    out[5] = 1; // SHA-1
    out[6] = chunks.length;
    out[7] = 0; // no base graphs

    var at = headerSize;
    for (final chunk in chunks) {
      view.setUint32(at, CommitGraph._chunkId(chunk));
      view.setUint64(at + 4, offsets[chunk]!);
      at += 12;
    }
    // The table ends with a zero id whose offset marks where the chunks stop.
    view.setUint32(at, 0);
    view.setUint64(at + 4, offset);

    // ---- fanout ----
    at = offsets['OIDF']!;
    var seen = 0;
    var index = 0;
    for (var bucket = 0; bucket < 256; bucket++) {
      while (index < count && sorted[index].id.bytes[0] == bucket) {
        index += 1;
        seen += 1;
      }
      view.setUint32(at + bucket * 4, seen);
    }

    // ---- names ----
    at = offsets['OIDL']!;
    for (final commit in sorted) {
      out.setRange(at, at + ObjectId.byteLength, commit.id.bytes);
      at += ObjectId.byteLength;
    }

    // ---- commit data ----
    at = offsets['CDAT']!;
    for (final commit in sorted) {
      out.setRange(at, at + ObjectId.byteLength, commit.tree.bytes);

      final first = commit.parents.isEmpty
          ? CommitGraph._noParent
          : positions[commit.parents[0]]!;
      final int second;
      if (commit.parents.length == 1) {
        second = CommitGraph._noParent;
      } else if (commit.parents.length == 2) {
        second = positions[commit.parents[1]]!;
      } else if (commit.parents.isEmpty) {
        second = CommitGraph._noParent;
      } else {
        second = extraAt[commit.id]! | CommitGraph._extraEdges;
      }

      view.setUint32(at + ObjectId.byteLength, first);
      view.setUint32(at + ObjectId.byteLength + 4, second);

      final generation = generations[commit.id]!;
      final time = commit.commitTime;
      view.setUint32(
        at + ObjectId.byteLength + 8,
        ((generation & CommitGraph.generationMax) << 2) |
            ((time >> 32) & 0x3),
      );
      view.setUint32(at + ObjectId.byteLength + 12, time & 0xffffffff);

      at += CommitGraph._entrySize;
    }

    // ---- extra edges ----
    if (extra.isNotEmpty) {
      at = offsets['EDGE']!;
      for (final value in extra) {
        view.setUint32(at, value);
        at += 4;
      }
    }

    // ---- the trailing checksum ----
    final digest = sha1.convert(out.sublist(0, total - ObjectId.byteLength));
    out.setRange(total - ObjectId.byteLength, total, digest.bytes);

    return out;
  }

  /// The topological level of every commit: one more than its deepest parent.
  ///
  /// Computed without recursion, because a history is deep enough to exhaust
  /// the stack — a linear one of a hundred thousand commits is one chain a
  /// hundred thousand deep, and that is the ordinary case rather than the
  /// pathological one.
  static Map<ObjectId, int> _generations(
    List<CommitGraphInput> sorted,
    Map<ObjectId, CommitGraphInput> all,
  ) {
    final generations = <ObjectId, int>{};

    for (final root in sorted) {
      if (generations.containsKey(root.id)) continue;

      final stack = <ObjectId>[root.id];
      while (stack.isNotEmpty) {
        final id = stack.last;
        if (generations.containsKey(id)) {
          stack.removeLast();
          continue;
        }

        final commit = all[id]!;
        var deepest = 0;
        var waiting = false;
        for (final parent in commit.parents) {
          final known = generations[parent];
          if (known == null) {
            stack.add(parent);
            waiting = true;
          } else if (known > deepest) {
            deepest = known;
          }
        }
        if (waiting) continue;

        stack.removeLast();
        final level = deepest + 1;
        generations[id] =
            level > CommitGraph.generationMax ? CommitGraph.generationMax : level;
      }
    }

    return generations;
  }
}
