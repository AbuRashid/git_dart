import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../object_id.dart';

/// What a ref holds: either an object name, or the path of another ref.
sealed class RefTarget {
  const RefTarget();
}

class DirectRef extends RefTarget {
  final ObjectId id;
  const DirectRef(this.id);

  @override
  String toString() => id.hex;
}

class SymbolicRef extends RefTarget {
  /// The full path of the ref pointed at, such as `refs/heads/main`.
  final String path;
  const SymbolicRef(this.path);

  @override
  String toString() => 'ref: $path';
}

class Ref {
  /// The full path — `refs/heads/main`, `HEAD` — not the short name.
  final String path;
  final RefTarget target;

  /// True when this ref was read from `packed-refs` rather than its own file.
  final bool packed;

  const Ref({required this.path, required this.target, this.packed = false});

  String get shortName {
    for (final prefix in const ['refs/heads/', 'refs/tags/', 'refs/remotes/']) {
      if (path.startsWith(prefix)) return path.substring(prefix.length);
    }
    return path;
  }

  bool get isBranch => path.startsWith('refs/heads/');
  bool get isTag => path.startsWith('refs/tags/');
  bool get isRemote => path.startsWith('refs/remotes/');

  @override
  String toString() => '$path -> $target';
}

/// The only mutable state in a repository.
///
/// A ref is a loose file, a line in `packed-refs`, or symbolic. All three are
/// read here and the caller is not told which it got, except through
/// [Ref.packed], which exists for tooling rather than for logic.
class RefStore {
  /// The `.git` directory.
  final String gitDirectory;

  RefStore(this.gitDirectory);

  String _pathOf(String refPath) =>
      p.join(gitDirectory, refPath.replaceAll('/', p.separator));

  /// Reads one ref without following symbolic targets. Returns null when the
  /// ref does not exist.
  Ref? read(String refPath) {
    final file = File(_pathOf(refPath));
    if (file.existsSync()) {
      final text = file.readAsStringSync().trim();
      if (text.startsWith('ref:')) {
        return Ref(path: refPath, target: SymbolicRef(text.substring(4).trim()));
      }
      // A ref file may carry a trailing comment in some tools' output; the
      // object name is the first token.
      final name = text.split(RegExp(r'\s')).first;
      return Ref(path: refPath, target: DirectRef(ObjectId.fromHex(name)));
    }

    final packed = readPackedRefs()[refPath];
    if (packed != null) {
      return Ref(path: refPath, target: DirectRef(packed), packed: true);
    }
    return null;
  }

  /// Follows symbolic refs to an object name. Returns null when the chain ends
  /// at a ref that does not exist — which is the state of `HEAD` on a branch
  /// with no commits yet, and is normal rather than an error.
  ObjectId? resolve(String refPath, {int limit = 10}) {
    var current = refPath;
    for (var i = 0; i < limit; i++) {
      final ref = read(current);
      if (ref == null) return null;
      switch (ref.target) {
        case DirectRef(:final id):
          return id;
        case SymbolicRef(:final path):
          current = path;
      }
    }
    throw FormatException('symbolic ref chain from $refPath does not end');
  }

  /// `HEAD` itself: symbolic when a branch is checked out, direct when
  /// detached. The state needs no separate flag (`refs.head`).
  Ref? get head => read('HEAD');

  /// The branch `HEAD` names, or null when HEAD is detached.
  String? get currentBranch {
    final target = head?.target;
    return target is SymbolicRef ? target.path : null;
  }

  bool get isDetached => head?.target is DirectRef;

  Map<String, ObjectId> readPackedRefs() {
    final file = File(p.join(gitDirectory, 'packed-refs'));
    if (!file.existsSync()) return const {};

    final refs = <String, ObjectId>{};
    for (final line in LineSplitter.split(file.readAsStringSync())) {
      if (line.isEmpty || line.startsWith('#')) continue;
      // A line beginning with ^ is the object an annotated tag points at, and
      // belongs to the ref above it rather than being a ref of its own.
      if (line.startsWith('^')) continue;
      final space = line.indexOf(' ');
      if (space != ObjectId.hexLength) continue;
      refs[line.substring(space + 1).trim()] =
          ObjectId.fromHex(line.substring(0, space));
    }
    return refs;
  }

  /// Every ref under [prefix], loose and packed, sorted by path.
  List<Ref> list({String prefix = 'refs/'}) {
    final found = <String, Ref>{};

    for (final entry in readPackedRefs().entries) {
      if (!entry.key.startsWith(prefix)) continue;
      found[entry.key] = Ref(
        path: entry.key,
        target: DirectRef(entry.value),
        packed: true,
      );
    }

    // A loose ref shadows the packed one of the same name: packed-refs is a
    // snapshot, and the loose file is what moved since.
    final root = Directory(p.join(gitDirectory, 'refs'));
    if (root.existsSync()) {
      for (final entry in root.listSync(recursive: true)) {
        if (entry is! File) continue;
        final refPath =
            p.relative(entry.path, from: gitDirectory).replaceAll(r'\', '/');
        if (!refPath.startsWith(prefix)) continue;
        final ref = read(refPath);
        if (ref != null) found[refPath] = ref;
      }
    }

    final refs = found.values.toList()..sort((a, b) => a.path.compareTo(b.path));
    return refs;
  }

  List<Ref> get branches => list(prefix: 'refs/heads/');
  List<Ref> get tags => list(prefix: 'refs/tags/');
  List<Ref> get remoteBranches => list(prefix: 'refs/remotes/');

  /// Points [refPath] at [id].
  ///
  /// Written to a temporary file and renamed over the old one: a torn write
  /// here loses a branch, and rename is the only widely available atomic
  /// primitive (`refs.update-must-be-atomic`).
  void write(String refPath, ObjectId id) =>
      _writeAtomically(refPath, '${id.hex}\n');

  void writeSymbolic(String refPath, String target) =>
      _writeAtomically(refPath, 'ref: $target\n');

  void _writeAtomically(String refPath, String contents) {
    final file = File(_pathOf(refPath));
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.lock');
    temporary.writeAsStringSync(contents);
    temporary.renameSync(file.path);
  }

  /// Removes a loose ref. A ref that exists only in `packed-refs` is left
  /// alone and reported as false, because deleting it means rewriting that
  /// file — a separate operation with its own atomicity problem.
  bool deleteLoose(String refPath) {
    final file = File(_pathOf(refPath));
    if (!file.existsSync()) return false;
    file.deleteSync();
    return true;
  }
}
