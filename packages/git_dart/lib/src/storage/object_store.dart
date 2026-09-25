import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../object_id.dart';
import '../objects/git_object.dart';
import 'loose_object_store.dart';
import 'pack_file.dart';
import 'pack_index_writer.dart';

/// Thrown when an object is asked for by a name the store does not hold.
class MissingObjectException implements Exception {
  final ObjectId id;
  const MissingObjectException(this.id);

  @override
  String toString() => 'object $id is not in this repository';
}

/// Loose and packed storage behind one interface.
///
/// An object's name does not say where it lives, so neither does this API
/// (`storage.both-are-the-same-store`). Alternates are searched too, and are
/// indistinguishable from local storage for the same reason.
class ObjectStore {
  final LooseObjectStore loose;
  final List<PackFile> packs;
  final List<ObjectStore> alternates;

  /// Whether this store refuses to write. Set for a repository opened for
  /// inspection, so that a path which forgot to ask still cannot write.
  final bool readOnly;

  ObjectStore({
    required this.loose,
    required this.packs,
    this.alternates = const [],
    this.readOnly = false,
  }) {
    for (final pack in packs) {
      pack.externalBase = (id) {
        final base = readRaw(id);
        if (base == null) throw MissingObjectException(id);
        return base;
      };
    }
  }

  /// Opens the store rooted at an `objects` directory, following alternates.
  factory ObjectStore.open(String objectsDirectory, {bool readOnly = false}) {
    return ObjectStore(
      loose: LooseObjectStore(objectsDirectory),
      packs: openPacks(objectsDirectory),
      alternates: [
        for (final path in readAlternates(objectsDirectory))
          ObjectStore.open(path, readOnly: readOnly),
      ],
      readOnly: readOnly,
    );
  }

  bool contains(ObjectId id) =>
      loose.contains(id) ||
      packs.any((pack) => pack.contains(id)) ||
      alternates.any((store) => store.contains(id));

  /// The kind and content of [id], or null if it is not here. Loose is tried
  /// first: a loose object is the recently written one, and finding it costs a
  /// single stat.
  ({ObjectKind kind, Uint8List content})? readRaw(ObjectId id) {
    final looseObject = loose.read(id);
    if (looseObject != null) return looseObject;

    for (final pack in packs) {
      final packed = pack.read(id);
      if (packed != null) return packed;
    }

    for (final store in alternates) {
      final borrowed = store.readRaw(id);
      if (borrowed != null) return borrowed;
    }

    return null;
  }

  /// What [id] is and how big it is, without materialising it, or null when
  /// it is not here.
  ///
  /// A loose object states both in a header at the front of its compressed
  /// stream; a packed one states them in its pack header, and a delta states
  /// how long its result will be in the delta's own. So this costs a read of
  /// a few dozen bytes where reading the object costs the object — the
  /// difference between deciding not to show a two-hundred-megabyte blob and
  /// allocating it in order to decide.
  ({ObjectKind kind, int size})? statObject(ObjectId id) {
    final looseObject = loose.stat(id);
    if (looseObject != null) return looseObject;

    for (final pack in packs) {
      final packed = pack.stat(id);
      if (packed != null) return packed;
    }

    for (final store in alternates) {
      final borrowed = store.statObject(id);
      if (borrowed != null) return borrowed;
    }

    return null;
  }

  /// [readRaw], refused when the object is larger than [maxBytes].
  ///
  /// The size is read from the header first, so an object over the limit is
  /// never inflated and never allocated. The refusal carries what is known
  /// about it: "too large to show" and "empty" must not look alike to
  /// whoever asked.
  ObjectReadResult readRawUpTo(ObjectId id, int maxBytes) {
    final stat = statObject(id);
    if (stat == null) return const ObjectMissing();
    if (stat.size > maxBytes) {
      return ObjectTooLarge(kind: stat.kind, size: stat.size);
    }
    final raw = readRaw(id);
    if (raw == null) return const ObjectMissing();
    return ObjectRead(kind: raw.kind, content: raw.content, size: stat.size);
  }

  /// The parsed object named [id].
  GitObject read(ObjectId id) {
    final raw = readRaw(id);
    if (raw == null) throw MissingObjectException(id);
    return GitObject.parse(raw.kind, raw.content);
  }

  /// [read], with the kind checked. Used where the caller already knows what
  /// it is following — a commit's `tree` header, say — so a corrupt repository
  /// fails at the point the assumption breaks rather than later.
  T readTyped<T extends GitObject>(ObjectId id) {
    final object = read(id);
    if (object is! T) {
      throw FormatException('$id is a ${object.kind.name}, expected a $T');
    }
    return object;
  }

  ObjectId write(GitObject object) {
    if (readOnly) {
      throw StateError(
        'writing an object was refused: this store is open for inspection',
      );
    }
    return loose.write(object);
  }

  /// Stores a packfile whole, alongside an index built for it, and makes it
  /// readable straight away.
  ///
  /// The alternative — inflating every object and writing it loose — is what
  /// this replaces. It is correct and it is why a first clone of anything real
  /// produces several hundred thousand files, most of a gigabyte of directory
  /// entries for a repository whose pack is a tenth of that, and a working
  /// tree the filesystem struggles to walk. Objects arrive packed; keeping
  /// them packed is not an optimisation so much as declining to undo one.
  ///
  /// Returns the path of the pack that was written, or null when [objects] is
  /// empty — an empty pack is legal and there is nothing to gain by keeping
  /// one.
  String? writePack({
    required Uint8List packBytes,
    required List<PackedObject> objects,
    required ObjectId packChecksum,
    bool promisor = false,
  }) =>
      _install(
        objects: objects,
        packChecksum: packChecksum,
        promisor: promisor,
        place: (destination) => fs.file('$destination.tmp')
          ..writeAsBytesSync(packBytes, flush: true),
      );

  /// Stores a packfile that is already on disk, moving it into place rather
  /// than copying its bytes through memory.
  ///
  /// This is what a fetch uses: the pack was streamed to a temporary file as
  /// it arrived, and reading it back only to write it out again would undo the
  /// point of streaming it.
  String? writePackFile({
    required String packPath,
    required List<PackedObject> objects,
    required ObjectId packChecksum,
    bool promisor = false,
  }) =>
      _install(
        objects: objects,
        packChecksum: packChecksum,
        promisor: promisor,
        place: (_) => fs.file(packPath),
      );

  /// Writes the index, puts the pack beside it, and opens the pair.
  ///
  /// [place] returns a file holding the pack, which is then renamed into its
  /// final name — so the caller decides whether that file was written here or
  /// arrived already.
  String? _install({
    required List<PackedObject> objects,
    required ObjectId packChecksum,
    required GitFsFile Function(String destination) place,
    bool promisor = false,
  }) {
    if (objects.isEmpty) return null;

    final directory = fs.directory(p.join(loose.objectsDirectory, 'pack'))
      ..createSync(recursive: true);
    final name = PackIndexWriter.packName(objects.map((o) => o.id));
    final packPath = p.join(directory.path, '$name.pack');
    final indexPath = p.join(directory.path, '$name.idx');

    // Already here: the name is a hash of the object set, so an identical set
    // has been stored before and rewriting it would only risk truncating a
    // pack something else is reading.
    if (fs.file(packPath).existsSync() && fs.file(indexPath).existsSync()) {
      return packPath;
    }

    // The index goes down first and the pack is renamed into place after it.
    // A reader skips a pack with no index, so the window where the pair is
    // incomplete is a window where neither is used, rather than one where a
    // pack is read with an index that does not describe it.
    fs.file(indexPath).writeAsBytesSync(
      PackIndexWriter.build(objects: objects, packChecksum: packChecksum),
      flush: true,
    );
    place(packPath).renameSync(packPath);

    // A pack from a filtered fetch may reference objects nobody sent. The
    // marker beside it is what tells every reader — git included — that those
    // absences were promised rather than lost; without it the same repository
    // reads as corrupt.
    if (promisor) {
      fs.file(p.join(directory.path, '$name.promisor'))
          .writeAsStringSync('');
    }

    final pack = PackFile.open(packPath);
    pack.externalBase = (id) {
      final base = readRaw(id);
      if (base == null) throw MissingObjectException(id);
      return base;
    };
    // Newest first, which is where a recently fetched object is most likely
    // to be.
    packs.insert(0, pack);

    return packPath;
  }

  /// Every name the store holds, loose and packed. Names may repeat when an
  /// object is stored both ways, which is legal and common after a repack.
  Iterable<ObjectId> listAll() sync* {
    yield* loose.listAll();
    for (final pack in packs) {
      yield* pack.listAll();
    }
    for (final store in alternates) {
      yield* store.listAll();
    }
  }

  void close() {
    for (final pack in packs) {
      pack.close();
    }
    for (final store in alternates) {
      store.close();
    }
  }
}

/// What a bounded read found: the object, a refusal with its size, or
/// nothing at all.
///
/// Three outcomes rather than a nullable result, because a caller that shows
/// what it gets must be able to tell an object it may not show from one that
/// is not there and from one that is genuinely empty. Collapsing those is how
/// a refusal ends up on screen as a blank file.
sealed class ObjectReadResult {
  const ObjectReadResult();
}

class ObjectRead extends ObjectReadResult {
  final ObjectKind kind;
  final Uint8List content;

  /// What the header said, which is what was checked against the limit.
  final int size;

  const ObjectRead({
    required this.kind,
    required this.content,
    required this.size,
  });
}

class ObjectTooLarge extends ObjectReadResult {
  final ObjectKind kind;

  /// The whole object's size, from its header — the thing worth telling
  /// someone who has just been told they cannot have it.
  final int size;

  const ObjectTooLarge({required this.kind, required this.size});
}

class ObjectMissing extends ObjectReadResult {
  const ObjectMissing();
}
