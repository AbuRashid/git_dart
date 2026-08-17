import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../index/git_index.dart';
import '../object_id.dart';
import '../objects/git_object.dart';
import '../objects/tree.dart';
import '../repository.dart';
import 'attributes.dart';
import 'status.dart';

/// Thrown when a checkout would destroy work that is not committed.
class CheckoutConflictException implements Exception {
  final List<String> paths;
  const CheckoutConflictException(this.paths);

  @override
  String toString() => 'local changes would be overwritten by checkout:\n'
      '${paths.map((path) => '  $path').join('\n')}';
}

class CheckoutResult {
  final int written;
  final int removed;

  /// Paths whose mode could not be reproduced — the executable bit, and
  /// symlinks on a system that will not create them. Reported rather than
  /// silently dropped: the working tree does not match the tree that was
  /// checked out, and only the caller can decide whether that matters.
  final List<String> degraded;

  const CheckoutResult({
    required this.written,
    required this.removed,
    required this.degraded,
  });

  @override
  String toString() =>
      'checked out $written files, removed $removed, ${degraded.length} '
      'degraded';
}

/// Writes [target] into the working tree and makes the index describe it.
///
/// Only what differs is touched: an unchanged file is left alone, which keeps
/// build timestamps meaningful and makes a checkout cost the size of the
/// change rather than the size of the tree.
///
/// Refuses when a file that must change has uncommitted modifications, unless
/// [force]. That check is what stands between a branch switch and lost work.
CheckoutResult checkoutTree(
  Repository repo,
  Tree target, {
  bool force = false,
}) {
  final workTree = repo.workTree;
  if (workTree == null) {
    throw StateError('a bare repository has no working tree to check out');
  }

  // The index, not HEAD, is what the working tree currently reflects: a file
  // staged but not committed is present, and a checkout has to account for it.
  final index = repo.index ?? GitIndex.empty();
  final current = {
    for (final entry in index.entries)
      if (entry.stage == MergeStage.ordinary) entry.path: entry,
  };

  final wanted = <String, TreeEntry>{};
  _flattenTree(repo, target, '', wanted);

  final toRemove = current.keys.where((path) => !wanted.containsKey(path));

  // What the working tree actually holds, which is not always what the index
  // says it holds: a file edited and not staged matches the index exactly.
  // Deciding what to write from the index alone therefore leaves such a file
  // untouched — correct for a branch switch, and wrong for a forced checkout,
  // where overwriting local changes is the whole request. Found by a hard
  // reset that did not put a modified file back.
  final dirty = {
    for (final entry in statusOf(repo, includeUntracked: false).entries)
      entry.path,
  };

  final toWrite = [
    for (final entry in wanted.entries)
      if (current[entry.key]?.id != entry.value.id ||
          current[entry.key]?.mode != entry.value.mode.numeric ||
          (force && dirty.contains(entry.key)))
        entry.key,
  ];

  if (!force) {
    final affected = {...toRemove, ...toWrite};
    final blocked = dirty.where(affected.contains).toList();
    if (blocked.isNotEmpty) throw CheckoutConflictException(blocked);
  }

  final degraded = <String>[];
  var written = 0;
  var removed = 0;

  // Removals first: a path that was a file and is now a directory needs the
  // file gone before the directory can be made.
  final removedPaths = toRemove.toList();
  for (final path in removedPaths) {
    final file = fs.file(_absolute(workTree, path));
    if (file.existsSync()) {
      file.deleteSync();
      removed += 1;
    } else if (fs.link(file.path).existsSync()) {
      fs.link(file.path).deleteSync();
      removed += 1;
    }
  }

  for (final path in toWrite) {
    final entry = wanted[path]!;
    // A submodule's commit is not in this repository, so there is nothing to
    // write; the directory is left as it is.
    if (entry.mode.isSubmodule) continue;
    if (_writeEntry(repo, workTree, path, entry.mode, entry.id)) {
      written += 1;
    } else {
      degraded.add(path);
      written += 1;
    }
  }

  _removeEmptyDirectories(workTree, removedPaths);
  _writeIndexFor(repo, workTree, target);

  return CheckoutResult(
    written: written,
    removed: removed,
    degraded: degraded,
  );
}

/// Returns false when the file was written but its mode could not be.
bool _writeEntry(
  Repository repo,
  String workTree,
  String path,
  FileMode mode,
  ObjectId id,
) {
  final absolute = _absolute(workTree, path);
  final stored = repo.objects.readTyped<Blob>(id).content;
  // The working tree gets the converted form; the object holds LF endings
  // whatever this system uses.
  final content = mode == FileMode.symlink
      ? stored
      : toWorkingTree(stored, repo.attributes.conversionFor(path, stored));
  fs.directory(p.dirname(absolute)).createSync(recursive: true);

  final existingLink = fs.link(absolute);
  if (existingLink.existsSync()) existingLink.deleteSync();

  if (mode == FileMode.symlink) {
    // The blob holds the target path (`objects.modes-in-a-tree`).
    try {
      final file = fs.file(absolute);
      if (file.existsSync()) file.deleteSync();
      fs.link(absolute).createSync(utf8.decode(content, allowMalformed: true));
      return true;
    } on GitFsException {
      // Windows needs a privilege for this that a normal process does not
      // have. Writing the target as file content is what git itself does when
      // symlinks are unavailable, and it is recorded as degraded.
      fs.file(absolute).writeAsBytesSync(content);
      return false;
    }
  }

  fs.file(absolute).writeAsBytesSync(content);

  // dart:io cannot change a file's permissions, so the executable bit of
  // mode 100755 is not reproduced. On Windows there is nothing to reproduce;
  // elsewhere the file is written readable and not executable.
  return !(mode == FileMode.executableFile && !Platform.isWindows);
}

void _flattenTree(
  Repository repo,
  Tree tree,
  String prefix,
  Map<String, TreeEntry> out,
) {
  for (final entry in tree.entries) {
    final path = '$prefix${entry.name}';
    if (entry.mode.isTree) {
      _flattenTree(repo, repo.objects.readTyped<Tree>(entry.id), '$path/', out);
    } else {
      out[path] = entry;
    }
  }
}

void _removeEmptyDirectories(String workTree, List<String> removedPaths) {
  final candidates = <String>{};
  for (final path in removedPaths) {
    var directory = p.dirname(path);
    while (directory != '.' && directory.isNotEmpty) {
      candidates.add(directory);
      directory = p.dirname(directory);
    }
  }

  // Deepest first, so a directory emptied by removing its subdirectories is
  // itself removed.
  final ordered = candidates.toList()
    ..sort((a, b) => b.split('/').length.compareTo(a.split('/').length));

  for (final relative in ordered) {
    final directory = fs.directory(_absolute(workTree, relative));
    if (!directory.existsSync()) continue;
    if (directory.listSync().isEmpty) directory.deleteSync();
  }
}

/// Rewrites the index so that it describes [tree] exactly, with the stat data
/// of the files just written.
///
/// The stat fields are filled in because they are a cache and an empty cache
/// makes every later status re-read every file — correct, and slow
/// (`index.the-stat-fields-are-a-cache`).
void _writeIndexFor(Repository repo, String workTree, Tree tree) {
  final entries = <IndexEntry>[];
  _collect(repo, tree, '', workTree, entries);
  GitIndex(entries: entries).writeTo(p.join(repo.gitDirectory, 'index'));
}

void _collect(
  Repository repo,
  Tree tree,
  String prefix,
  String workTree,
  List<IndexEntry> out,
) {
  for (final entry in tree.entries) {
    final path = '$prefix${entry.name}';
    if (entry.mode.isTree) {
      _collect(
        repo,
        repo.objects.readTyped<Tree>(entry.id),
        '$path/',
        workTree,
        out,
      );
      continue;
    }
    if (entry.mode.isSubmodule) continue;

    final file = fs.file(_absolute(workTree, path));
    final stat = file.existsSync() ? file.statSync() : null;
    final seconds = stat == null
        ? 0
        : stat.modified.millisecondsSinceEpoch ~/ 1000;

    out.add(IndexEntry(
      path: path,
      id: entry.id,
      mode: entry.mode.numeric,
      ctimeSeconds: seconds,
      mtimeSeconds: seconds,
      size: stat?.size ?? 0,
    ));
  }
}

String _absolute(String workTree, String path) =>
    p.join(workTree, path.replaceAll('/', p.separator));
