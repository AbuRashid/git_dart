/// Notes — things said about a commit after it was made.
///
/// A commit is immutable, so anything learned about it later has nowhere to
/// go. Notes are the answer: a ref, `refs/notes/commits` by default, pointing
/// at a tree whose *paths are object names* and whose blobs are the text. The
/// commit is untouched; the note lives beside it and can be edited, rewritten
/// or dropped without changing a single object name.
///
/// git shows them in `log` by default, which is why a listing that ignores
/// them silently omits content the same repository displays elsewhere.
///
/// The paths are fanned out to keep any one tree small — a name may be stored
/// flat as `a1b2…`, or split as `a1/b2…`, or `a1/b2/c3…`. Nothing records
/// which: the tree is rewritten into whatever shape it has grown to need, so a
/// reader must follow whichever it finds ([_findIn]).
library;

import 'dart:convert';

import '../object_id.dart';
import '../objects/tree.dart';
import '../repository.dart';

/// The notes ref used when none is named.
const String defaultNotesRef = 'refs/notes/commits';

/// One note: some text about an object.
class Note {
  /// The object the note is about — almost always a commit.
  final ObjectId target;

  /// The blob holding the text.
  final ObjectId blob;

  /// The note's text.
  final String text;

  /// The ref it was found under, since a repository can carry several
  /// independent sets of notes about the same commits.
  final String ref;

  const Note({
    required this.target,
    required this.blob,
    required this.text,
    required this.ref,
  });

  @override
  String toString() => '${target.hex.substring(0, 8)}: '
      '${text.split('\n').first.trim()}';
}

/// Every notes ref in the repository, sorted.
///
/// More than one set is ordinary: `refs/notes/commits` is what `git notes`
/// writes by default, and a project may keep review comments or test results
/// under their own refs beside it.
List<String> notesRefs(Repository repository) {
  final out = [
    for (final ref in repository.refs.list(prefix: 'refs/notes/')) ref.path,
  ]..sort();
  return out;
}

/// The ref notes are read from when a caller names none.
///
/// `core.notesRef` moves it, which is how a repository makes a set other than
/// `commits` the one everything sees by default.
String defaultNotesRefOf(Repository repository) =>
    repository.config['core.notesRef'] ?? defaultNotesRef;

/// The note about [target], or null when there is none.
///
/// Absence is the common case — most commits have no note — so this is a
/// directed descent rather than a walk of the whole tree.
Note? noteFor(Repository repository, ObjectId target, {String? ref}) {
  final notesRef = ref ?? defaultNotesRefOf(repository);
  final root = _notesTree(repository, notesRef);
  if (root == null) return null;

  final blob = _findIn(repository, root, target.hex);
  if (blob == null) return null;

  final raw = repository.objects.readRaw(blob);
  if (raw == null) return null;

  return Note(
    target: target,
    blob: blob,
    // Notes are prose written by people, and nothing enforces an encoding.
    text: utf8.decode(raw.content, allowMalformed: true),
    ref: notesRef,
  );
}

/// Every note under [ref], by the object it is about.
///
/// This does walk the whole tree, because "which commits have notes" cannot be
/// answered any other way; a caller displaying a log should prefer [noteFor]
/// per commit, or call this once and keep the map.
Map<ObjectId, Note> allNotes(Repository repository, {String? ref}) {
  final notesRef = ref ?? defaultNotesRefOf(repository);
  final root = _notesTree(repository, notesRef);
  if (root == null) return const {};

  final out = <ObjectId, Note>{};

  void walk(Tree tree, String prefix) {
    for (final entry in tree.entries) {
      final name = '$prefix${entry.name}';
      if (entry.mode.isTree) {
        final subtree = repository.objects.readRaw(entry.id) == null
            ? null
            : repository.objects.readTyped<Tree>(entry.id);
        if (subtree != null) walk(subtree, name);
        continue;
      }
      if (!entry.mode.isBlob) continue;

      // Only a path that spells a whole object name is a note; a notes tree
      // may also carry `.gitattributes` and suchlike, which is not one.
      if (name.length != ObjectId.hexLength) continue;
      final ObjectId target;
      try {
        target = ObjectId.fromHex(name);
      } on FormatException {
        continue;
      }

      final raw = repository.objects.readRaw(entry.id);
      if (raw == null) continue;
      out[target] = Note(
        target: target,
        blob: entry.id,
        text: utf8.decode(raw.content, allowMalformed: true),
        ref: notesRef,
      );
    }
  }

  walk(root, '');
  return out;
}

/// The tree a notes ref points at, or null when the ref does not exist.
Tree? _notesTree(Repository repository, String ref) {
  final id = repository.refs.resolve(ref);
  if (id == null) return null;
  if (repository.objects.readRaw(id) == null) return null;
  return repository.treeOf(id);
}

/// Descends a notes tree looking for one object name.
///
/// At each level the name may be spelled out in full by a blob, or continued
/// by a directory whose name is a prefix of what is left. Both are tried
/// because the fanout depth is a property of how large the tree has grown and
/// is not recorded anywhere.
ObjectId? _findIn(Repository repository, Tree tree, String remaining) {
  if (remaining.isEmpty) return null;

  final direct = tree.entryNamed(remaining);
  if (direct != null && direct.mode.isBlob) return direct.id;

  for (final entry in tree.entries) {
    if (!entry.mode.isTree) continue;
    final name = entry.name;
    if (name.isEmpty || !remaining.startsWith(name)) continue;

    final subtree = repository.objects.readRaw(entry.id) == null
        ? null
        : repository.objects.readTyped<Tree>(entry.id);
    if (subtree == null) continue;

    final found = _findIn(repository, subtree, remaining.substring(name.length));
    if (found != null) return found;
  }

  return null;
}
