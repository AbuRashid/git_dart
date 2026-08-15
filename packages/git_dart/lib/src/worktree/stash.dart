import 'dart:io';

import 'package:path/path.dart' as p;

import '../index/git_index.dart';
import '../merge/merge.dart';
import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/git_object.dart';
import '../objects/identity.dart';
import '../objects/tree.dart';
import '../refs/reflog.dart';
import '../repository.dart';
import 'reset.dart';

/// One saved state, as `refs/stash@{n}` names it.
class StashEntry {
  /// Where in the stack this sits: 0 is the most recent.
  final int index;

  /// The commit holding the working tree state.
  final ObjectId commit;

  final String message;

  const StashEntry({
    required this.index,
    required this.commit,
    required this.message,
  });

  String get name => 'stash@{$index}';

  @override
  String toString() => '$name: $message';
}

/// Saves the working tree and index, and puts the working tree back to HEAD.
///
/// A stash is not a special kind of storage. It is two or three ordinary
/// commits that no branch points at, hung off `refs/stash`, whose reflog is
/// the stack — which is why `stash@{2}` is spelled like a reflog entry and is
/// one. Nothing new was invented for this; it is refs and commits used at a
/// slant, and it is worth knowing because it explains every otherwise odd
/// thing about the feature.
///
/// The commit has two parents: HEAD, so the stash knows where it was taken
/// from, and a commit holding the *index* as it was, so that what was staged
/// can be told from what was not. Returns null when there is nothing to save.
ObjectId? stashSave(
  Repository repository, {
  String? message,
  Identity? author,
  bool includeUntracked = false,
}) {
  final workTree = repository.workTree;
  if (workTree == null) {
    throw StateError('a bare repository has no working tree to stash');
  }

  final head = repository.headId;
  if (head == null) {
    throw StateError('there is nothing to stash before the first commit');
  }

  final status = repository.status(includeUntracked: includeUntracked);
  final untracked = [
    for (final entry in status.entries)
      if (entry.isUntracked) entry.path,
  ];
  final changed = status.entries.any((entry) => !entry.isUntracked);

  if (!changed && (!includeUntracked || untracked.isEmpty)) return null;

  final who = author ?? repository.identityFromConfig();
  if (who == null) {
    throw StateError(
      'no user.name and user.email are configured for this repository',
    );
  }

  final headCommit = repository.objects.readTyped<Commit>(head);
  final branch = repository.refs.currentBranch;
  final shortBranch = branch == null
      ? 'detached HEAD'
      : branch.substring('refs/heads/'.length);
  final summary = headCommit.message.split('\n').first.trim();
  final text = message ??
      'WIP on $shortBranch: ${head.hex.substring(0, 7)} $summary';

  // ---- the index, as its own commit ----
  //
  // Without this the stash could restore the content but not the staging, and
  // "what was staged" is information that exists nowhere else once the index
  // is reset.
  final indexTree = repository.writeTreeFromIndex();
  final indexCommit = repository.commitTree(
    tree: indexTree,
    message: 'index on $shortBranch: ${head.hex.substring(0, 7)} $summary\n',
    author: who,
    parents: [head],
    updateHead: false,
  );

  final parents = <ObjectId>[head, indexCommit];

  // ---- untracked files, as their own commit ----
  if (includeUntracked && untracked.isNotEmpty) {
    final entries = <TreeEntry>[];
    final flat = <String, TreeEntry>{};
    for (final path in untracked) {
      final file = File(p.join(workTree, path.replaceAll('/', p.separator)));
      if (!file.existsSync()) continue;
      final blob = Blob(file.readAsBytesSync());
      repository.objects.write(blob);
      flat[path] = TreeEntry.named(
        mode: FileMode.regularFile,
        name: path.split('/').last,
        id: blob.id,
      );
    }
    entries.clear();
    if (flat.isNotEmpty) {
      parents.add(repository.commitTree(
        tree: _writeTreeFrom(repository, flat),
        message: 'untracked files on $shortBranch\n',
        author: who,
        parents: const [],
        updateHead: false,
      ));
    }
  }

  // ---- the working tree, as the stash commit itself ----
  final workingTree = _treeOfWorkingState(repository, workTree);
  final stash = repository.commitTree(
    tree: workingTree,
    message: '$text\n',
    author: who,
    parents: parents,
    updateHead: false,
  );

  // The reflog is the stack, so the ref must be logged even though it is not
  // a branch. It already would be by name, and this makes it explicit.
  final logPath = Reflog.pathOf(repository.gitDirectory, 'refs/stash');
  File(logPath).parent.createSync(recursive: true);
  if (!File(logPath).existsSync()) File(logPath).createSync();
  repository.refs.write('refs/stash', stash, reflogMessage: text);

  // ---- put the working tree back ----
  reset(repository, head, mode: ResetMode.hard);
  if (includeUntracked) {
    for (final path in untracked) {
      final file = File(p.join(workTree, path.replaceAll('/', p.separator)));
      if (file.existsSync()) file.deleteSync();
    }
  }

  return stash;
}

/// The stack, most recent first.
///
/// Read from the reflog rather than from the ref, because the ref names only
/// the top of it: every older stash is reachable exactly because the reflog
/// still records where `refs/stash` used to point.
List<StashEntry> stashList(Repository repository) {
  final log = repository.refs.reflogFor('refs/stash');
  final entries = <StashEntry>[];
  // Newest first, which is the order `stash@{0}` counts in.
  final lines = log.entries.reversed.toList();
  for (var i = 0; i < lines.length; i++) {
    entries.add(StashEntry(
      index: i,
      commit: lines[i].to,
      message: lines[i].message,
    ));
  }
  return entries;
}

/// Restores a stash into the working tree, as a merge against where it was
/// taken from.
///
/// A merge rather than a checkout, because the working tree has usually moved
/// on: the stash's own parent is the base, what is there now is our side, and
/// the stash is theirs. Restoring by overwriting would discard whatever was
/// done in between, which is the opposite of what a stash is for.
MergeOutcome stashApply(
  Repository repository, {
  int index = 0,
  bool restoreIndex = false,
}) {
  final entries = stashList(repository);
  if (index < 0 || index >= entries.length) {
    throw RangeError('there is no stash@{$index}');
  }

  final stash = repository.objects.readTyped<Commit>(entries[index].commit);
  if (stash.parents.isEmpty) {
    throw StateError('stash@{$index} records no commit it was taken from');
  }

  final head = repository.headId;
  if (head == null) throw StateError('there is no HEAD to restore onto');

  final applied = applyTrees(
    repository,
    baseFiles: filesOf(repository, stash.parents.first),
    ourFiles: filesOf(repository, head),
    theirFiles: filesOf(repository, stash.id),
  );

  if (applied.conflicts.isNotEmpty) return MergeOutcome.conflicted;

  // The index normally comes back as "everything unstaged", which is what a
  // stash restores by default: the changes are yours again, and whether they
  // were staged is a detail most people do not want back.
  if (restoreIndex && stash.parents.length > 1) {
    final staged = repository.objects.readTyped<Commit>(stash.parents[1]);
    _writeIndexFromTree(repository, staged.tree);
  } else {
    _writeIndexFromTree(
      repository,
      repository.objects.readTyped<Commit>(head).tree,
    );
  }

  // Untracked files, when the stash carried them.
  if (stash.parents.length > 2) {
    final workTree = repository.workTree!;
    final tree = repository.objects
        .readTyped<Commit>(stash.parents[2])
        .tree;
    _restoreUntracked(repository, workTree, tree);
  }

  return MergeOutcome.merged;
}

/// Applies a stash and, if that worked, removes it from the stack.
MergeOutcome stashPop(
  Repository repository, {
  int index = 0,
  bool restoreIndex = false,
}) {
  final outcome =
      stashApply(repository, index: index, restoreIndex: restoreIndex);
  // A conflicted apply keeps the stash: dropping it would leave the only copy
  // of the work in a half-merged working tree.
  if (outcome == MergeOutcome.merged) stashDrop(repository, index: index);
  return outcome;
}

/// Removes one entry from the stack.
///
/// The stack is the reflog, so dropping an entry means rewriting that log —
/// and re-pointing `refs/stash` when the top one goes.
void stashDrop(Repository repository, {int index = 0}) {
  final log = repository.refs.reflogFor('refs/stash');
  final lines = [...log.entries];
  if (index < 0 || index >= lines.length) {
    throw RangeError('there is no stash@{$index}');
  }

  // The list counts from the newest, the file stores oldest first.
  lines.removeAt(lines.length - 1 - index);

  final path = Reflog.pathOf(repository.gitDirectory, 'refs/stash');
  if (lines.isEmpty) {
    repository.refs.delete('refs/stash');
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
    return;
  }

  File(path).writeAsStringSync(lines.map((e) => e.line).join());
  // The ref names the top of the stack, which has just changed if the top is
  // what went.
  final top = lines.last.to;
  if (repository.refs.resolve('refs/stash') != top) {
    File(p.join(repository.gitDirectory, 'refs', 'stash'))
        .writeAsStringSync('${top.hex}\n');
  }
}

/// Drops every stash.
void stashClear(Repository repository) {
  repository.refs.delete('refs/stash');
  final file =
      File(Reflog.pathOf(repository.gitDirectory, 'refs/stash'));
  if (file.existsSync()) file.deleteSync();
}

// ---------------------------------------------------------------------------

/// A tree describing the working tree as it is now, tracked files only.
ObjectId _treeOfWorkingState(Repository repository, String workTree) {
  final index = repository.index ?? GitIndex.empty();
  final flat = <String, TreeEntry>{};

  for (final entry in index.entries) {
    if (entry.stage != MergeStage.ordinary) continue;
    final file =
        File(p.join(workTree, entry.path.replaceAll('/', p.separator)));

    if (!file.existsSync()) continue; // deleted: left out of the tree
    final blob = Blob(file.readAsBytesSync());
    repository.objects.write(blob);
    flat[entry.path] = TreeEntry.named(
      mode: entry.fileMode,
      name: entry.path.split('/').last,
      id: blob.id,
    );
  }

  return _writeTreeFrom(repository, flat);
}

ObjectId _writeTreeFrom(Repository repository, Map<String, TreeEntry> flat) {
  final paths = flat.keys.toList()..sort();

  ObjectId level(String prefix, List<String> within) {
    final here = <TreeEntry>[];
    var i = 0;
    while (i < within.length) {
      final rest = within[i].substring(prefix.length);
      final slash = rest.indexOf('/');

      if (slash < 0) {
        final entry = flat[within[i]]!;
        here.add(TreeEntry.named(mode: entry.mode, name: rest, id: entry.id));
        i += 1;
        continue;
      }

      final name = rest.substring(0, slash);
      final subPrefix = '$prefix$name/';
      final group = <String>[];
      while (i < within.length && within[i].startsWith(subPrefix)) {
        group.add(within[i]);
        i += 1;
      }
      here.add(TreeEntry.named(
        mode: FileMode.directory,
        name: name,
        id: level(subPrefix, group),
      ));
    }
    return repository.objects.write(Tree.build(here));
  }

  return level('', paths);
}

void _writeIndexFromTree(Repository repository, ObjectId tree) {
  final entries = <IndexEntry>[];

  void walk(Tree tree, String prefix) {
    for (final entry in tree.entries) {
      final path = '$prefix${entry.name}';
      if (entry.mode.isTree) {
        walk(repository.objects.readTyped<Tree>(entry.id), '$path/');
        continue;
      }
      if (entry.mode.isSubmodule) continue;
      entries.add(IndexEntry(
        path: path,
        id: entry.id,
        mode: entry.mode.numeric,
      ));
    }
  }

  walk(repository.objects.readTyped<Tree>(tree), '');
  GitIndex(entries: entries)
      .writeTo(p.join(repository.gitDirectory, 'index'));
}

void _restoreUntracked(
  Repository repository,
  String workTree,
  ObjectId tree,
) {
  void walk(Tree tree, String prefix) {
    for (final entry in tree.entries) {
      final path = '$prefix${entry.name}';
      if (entry.mode.isTree) {
        walk(repository.objects.readTyped<Tree>(entry.id), '$path/');
        continue;
      }
      final file =
          File(p.join(workTree, path.replaceAll('/', p.separator)))
            ..parent.createSync(recursive: true);
      file.writeAsBytesSync(
        repository.objects.readTyped<Blob>(entry.id).content,
      );
    }
  }

  walk(repository.objects.readTyped<Tree>(tree), '');
}
