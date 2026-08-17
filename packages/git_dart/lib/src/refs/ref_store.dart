import 'dart:convert';

import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../object_id.dart';
import '../objects/identity.dart';
import 'reflog.dart';

/// Thrown when a ref cannot be locked because someone else holds the lock.
///
/// The lock file is created exclusively, so this is a real answer rather than
/// a guess: another writer is in the middle of moving this ref, and the right
/// response is to fail rather than to overwrite whatever they are doing.
class RefLockedException implements Exception {
  final String refPath;
  const RefLockedException(this.refPath);

  @override
  String toString() =>
      'cannot lock $refPath: ${refPath.split('/').last}.lock already exists. '
      'Another process is updating it, or a previous one left the lock behind.';
}

/// Thrown when a ref was not where the caller expected it.
///
/// The whole point of a compare-and-swap: a fetch that saw `abc` and writes
/// `def` must not win over a commit that moved the same branch in between.
class RefRaceException implements Exception {
  final String refPath;
  final ObjectId? expected;
  final ObjectId? found;
  const RefRaceException(this.refPath, this.expected, this.found);

  @override
  String toString() => 'refusing to move $refPath: it was expected at '
      '${expected?.hex ?? 'nothing'} and is at ${found?.hex ?? 'nothing'}';
}

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

  /// Who to record as having moved a ref, asked for at the moment of the move
  /// so the timestamp is the move's own.
  ///
  /// A store with none writes no reflog. That is the honest behaviour rather
  /// than inventing an identity: a log line attributing a branch move to
  /// nobody in particular is worse than no line, because it looks like a
  /// record and is not one.
  Identity? Function()? identityFor;

  RefStore(this.gitDirectory, {this.identityFor});

  String _pathOf(String refPath) =>
      p.join(gitDirectory, refPath.replaceAll('/', p.separator));

  /// Reads one ref without following symbolic targets. Returns null when the
  /// ref does not exist.
  Ref? read(String refPath) {
    final file = fs.file(_pathOf(refPath));
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
    final file = fs.file(p.join(gitDirectory, 'packed-refs'));
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
    final root = fs.directory(p.join(gitDirectory, 'refs'));
    if (root.existsSync()) {
      for (final entry in root.listSync(recursive: true)) {
        if (entry is! GitFsFile) continue;
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

  /// Points [refPath] at [id], and records the move in the reflog.
  ///
  /// Written to a lock file and renamed over the old one: a torn write here
  /// loses a branch, and rename is the only widely available atomic primitive
  /// (`refs.update-must-be-atomic`). The lock is created exclusively, so a
  /// second writer fails rather than quietly racing the first — rename alone
  /// makes each write whole, not each write the only one.
  void write(String refPath, ObjectId id, {String? reflogMessage}) {
    final before = _currentValueOf(refPath);
    _writeAtomically(refPath, '${id.hex}\n');
    _log(refPath, before, id, reflogMessage);
  }

  /// Moves [refPath] only if it is still at [expected], and fails otherwise.
  ///
  /// [expected] of null means the ref must not exist. This is what a fetch or
  /// a push needs: it decided what to write from a value it read some time
  /// ago, and between the reading and the writing a commit may have moved the
  /// same branch. Without the check the later write silently wins and the
  /// commit is lost from the branch — findable in the reflog, and gone from
  /// everything else.
  void compareAndSwap(
    String refPath, {
    required ObjectId? expected,
    required ObjectId to,
    String? reflogMessage,
  }) {
    final found = _currentValueOf(refPath);
    if (found != expected) {
      throw RefRaceException(refPath, expected, found);
    }
    _writeAtomically(refPath, '${to.hex}\n');
    _log(refPath, found, to, reflogMessage);
  }

  /// Points [refPath] at another ref, as `HEAD` points at the checked-out
  /// branch.
  ///
  /// The reflog records where the ref *resolved* before and after, not the
  /// paths: a checkout is a move from one commit to another, and that is what
  /// makes the previous position recoverable.
  void writeSymbolic(String refPath, String target, {String? reflogMessage}) {
    final before = resolve(refPath);
    _writeAtomically(refPath, 'ref: $target\n');
    final after = resolve(refPath);
    if (after != null) _log(refPath, before, after, reflogMessage);
  }

  /// The object [refPath] holds directly, without following symbolic targets
  /// and without failing when it does not exist.
  ObjectId? _currentValueOf(String refPath) {
    final ref = read(refPath);
    return switch (ref?.target) {
      DirectRef(:final id) => id,
      SymbolicRef(:final path) => resolve(path),
      null => null,
    };
  }

  void _writeAtomically(String refPath, String contents) {
    final file = fs.file(_pathOf(refPath));
    final lock = _acquireLock(file);
    try {
      lock.writeAsStringSync(contents);
      lock.renameSync(file.path);
    } catch (_) {
      if (lock.existsSync()) lock.deleteSync();
      rethrow;
    }
  }

  /// Creates `<ref>.lock` exclusively, so that exactly one writer holds it.
  ///
  /// A lock left behind by a process that died stops every later write, which
  /// is deliberate and is what git does: the alternative is deciding on its
  /// owner's behalf that the interrupted update should be abandoned.
  GitFsFile _acquireLock(GitFsFile file) {
    file.parent.createSync(recursive: true);
    final lock = fs.file('${file.path}.lock');
    try {
      lock.createSync(exclusive: true);
    } on GitFsException {
      throw RefLockedException(p.relative(file.path, from: gitDirectory));
    }
    return lock;
  }

  // ---- the reflog ---------------------------------------------------------

  /// Whether a move of [refPath] is worth recording.
  ///
  /// Branches, remote-tracking refs and HEAD are logged always; anything else
  /// is logged only once a log already exists, which is how a caller opts a
  /// ref in. Tags are excluded on purpose: a tag that moves is a mistake
  /// rather than a history worth keeping.
  bool _shouldLog(String refPath) =>
      refPath == 'HEAD' ||
      refPath.startsWith('refs/heads/') ||
      refPath.startsWith('refs/remotes/') ||
      refPath.startsWith('refs/notes/') ||
      fs.file(Reflog.pathOf(gitDirectory, refPath)).existsSync();

  void _log(
    String refPath,
    ObjectId? from,
    ObjectId to,
    String? message,
  ) {
    if (message == null) return;
    if (!_shouldLog(refPath)) return;

    final who = identityFor?.call();
    if (who == null) return;

    final entry = ReflogEntry(
      from: from ?? ObjectId.zero,
      to: to,
      who: who,
      message: message,
    );
    _appendReflog(refPath, entry);

    // Moving the branch HEAD points at moves HEAD too, and HEAD's own log is
    // what `HEAD@{n}` reads. Writing only the branch's log leaves the two
    // disagreeing about where the working tree has been.
    if (refPath != 'HEAD' && currentBranch == refPath) {
      _appendReflog('HEAD', entry);
    }
  }

  void _appendReflog(String refPath, ReflogEntry entry) {
    final file = fs.file(Reflog.pathOf(gitDirectory, refPath));
    file.parent.createSync(recursive: true);
    // Append rather than rewrite: the log is the one part of a repository
    // where losing older lines defeats the purpose, and an append of one short
    // line is as close to atomic as a filesystem offers.
    file.writeAsStringSync(entry.line, append: true, flush: true);
  }

  /// The recorded history of one ref, oldest first. Empty when nothing has
  /// been logged, which is not an error.
  Reflog reflogFor(String refPath) => Reflog.read(gitDirectory, refPath);

  /// Every ref that has a reflog, by path.
  List<String> refsWithReflogs() {
    final root = fs.directory(p.join(gitDirectory, 'logs'));
    if (!root.existsSync()) return const [];
    return [
      for (final entry in root.listSync(recursive: true))
        if (entry is GitFsFile)
          p.relative(entry.path, from: root.path).replaceAll(r'\', '/'),
    ]..sort();
  }

  /// Drops a ref's log, as deleting the ref should.
  void deleteReflog(String refPath) {
    final file = fs.file(Reflog.pathOf(gitDirectory, refPath));
    if (file.existsSync()) file.deleteSync();
  }

  // ---- deleting -----------------------------------------------------------

  /// Removes a loose ref, leaving any packed one in place.
  bool deleteLoose(String refPath) {
    final file = fs.file(_pathOf(refPath));
    if (!file.existsSync()) return false;
    file.deleteSync();
    _pruneEmptyDirectories(file.parent);
    return true;
  }

  /// Removes directories left empty under `refs/`.
  ///
  /// They are not harmless: with `refs/heads/feature/one` gone, the empty
  /// `feature` directory stops a branch called `feature` from being created,
  /// because a file and a directory cannot share a name.
  void _pruneEmptyDirectories(GitFsDirectory directory) {
    final root = p.join(gitDirectory, 'refs');
    var current = directory;
    while (p.isWithin(root, current.path)) {
      if (!current.existsSync() || current.listSync().isNotEmpty) return;
      current.deleteSync();
      current = current.parent;
    }
  }

  /// Removes a ref wherever it lives.
  ///
  /// A branch may exist only as a line in `packed-refs`, where deleting the
  /// loose file does nothing at all and the ref appears to come back. So the
  /// packed file is rewritten too, whole and atomically.
  bool delete(String refPath) {
    // The log goes with the ref: it records where *this* ref has been, and a
    // later ref of the same name has not been anywhere.
    deleteReflog(refPath);
    final hadLoose = deleteLoose(refPath);
    final packed = fs.file(p.join(gitDirectory, 'packed-refs'));
    if (!packed.existsSync()) return hadLoose;

    final kept = <String>[];
    var removedPacked = false;
    var dropNextPeeled = false;

    for (final line in LineSplitter.split(packed.readAsStringSync())) {
      // A `^` line carries the object an annotated tag points at and belongs
      // to the line above it, so it goes when that line goes.
      if (line.startsWith('^')) {
        if (dropNextPeeled) {
          dropNextPeeled = false;
          continue;
        }
        kept.add(line);
        continue;
      }
      dropNextPeeled = false;

      final space = line.indexOf(' ');
      if (space == ObjectId.hexLength &&
          line.substring(space + 1).trim() == refPath) {
        removedPacked = true;
        dropNextPeeled = true;
        continue;
      }
      kept.add(line);
    }

    if (removedPacked) {
      final temporary = fs.file('${packed.path}.lock');
      temporary.writeAsStringSync(
        kept.isEmpty ? '' : '${kept.join('\n')}\n',
      );
      temporary.renameSync(packed.path);
    }

    return hadLoose || removedPacked;
  }
}
