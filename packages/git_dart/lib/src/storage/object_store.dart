import 'dart:typed_data';

import '../object_id.dart';
import '../objects/git_object.dart';
import 'loose_object_store.dart';
import 'pack_file.dart';

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

  ObjectStore({
    required this.loose,
    required this.packs,
    this.alternates = const [],
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
  factory ObjectStore.open(String objectsDirectory) {
    return ObjectStore(
      loose: LooseObjectStore(objectsDirectory),
      packs: openPacks(objectsDirectory),
      alternates: [
        for (final path in readAlternates(objectsDirectory))
          ObjectStore.open(path),
      ],
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

  ObjectId write(GitObject object) => loose.write(object);

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
