import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../object_id.dart';
import '../objects/git_object.dart';

/// Objects stored one per file, zlib-deflated, under `objects/ab/cdef…`.
///
/// The two-character directory is a filesystem accommodation and carries no
/// meaning (`storage.loose.why-split`).
class LooseObjectStore {
  /// The `objects` directory itself, not the repository root.
  final String objectsDirectory;

  LooseObjectStore(this.objectsDirectory);

  String pathFor(ObjectId id) {
    final hex = id.hex;
    return p.join(objectsDirectory, hex.substring(0, 2), hex.substring(2));
  }

  bool contains(ObjectId id) => File(pathFor(id)).existsSync();

  /// Returns the object's kind and content, or null if it is not stored loose.
  ({ObjectKind kind, Uint8List content})? read(ObjectId id) {
    final file = File(pathFor(id));
    if (!file.existsSync()) return null;
    final inflated = Uint8List.fromList(zlib.decode(file.readAsBytesSync()));
    return GitObject.split(inflated);
  }

  /// Writes [object] and returns its name. Writing an object that already
  /// exists is a no-op: identical content has one name, so there is nothing
  /// to overwrite.
  ObjectId write(GitObject object) {
    final id = object.id;
    final file = File(pathFor(id));
    if (file.existsSync()) return id;

    file.parent.createSync(recursive: true);
    // Write to a temporary name and rename, so a reader never sees a partial
    // object under a name that promises complete content.
    final temporary = File('${file.path}.tmp${pid}_${object.hashCode}');
    temporary.writeAsBytesSync(zlib.encode(object.serialise()));
    temporary.renameSync(file.path);
    return id;
  }

  /// Every loose object name in the store. Unordered.
  Iterable<ObjectId> listAll() sync* {
    final root = Directory(objectsDirectory);
    if (!root.existsSync()) return;
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      final prefix = p.basename(entry.path);
      if (prefix.length != 2) continue; // skips info/ and pack/
      for (final file in entry.listSync()) {
        final rest = p.basename(file.path);
        if (rest.length != ObjectId.hexLength - 2) continue;
        yield ObjectId.fromHex('$prefix$rest');
      }
    }
  }
}
