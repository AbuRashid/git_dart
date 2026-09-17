
import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../index/git_index.dart';
import '../object_id.dart';
import '../objects/git_object.dart';
import '../objects/tree.dart';
import '../repository.dart';
import 'checkout.dart';

/// How far a reset reaches.
///
/// All three move the branch; they differ only in what they leave behind.
/// That is the whole of the distinction, and it is easier to remember as a
/// question of how much is *kept* than of how much is thrown away.
enum ResetMode {
  /// Move the branch and nothing else. The index and working tree still hold
  /// what they held, so what the reset undid is left staged.
  soft,

  /// Move the branch and the index. The working tree is untouched, so the
  /// changes are still there and are no longer staged.
  mixed,

  /// Move the branch, the index and the working tree. What was not committed
  /// is gone — the only one of the three that destroys work, and the reason
  /// `ORIG_HEAD` and the reflog exist.
  hard,
}

class ResetResult {
  final ResetMode mode;
  final ObjectId to;

  /// Where HEAD was, which `ORIG_HEAD` now holds.
  final ObjectId? from;

  /// Files the working tree gained or lost, for a hard reset.
  final CheckoutResult? checkout;

  const ResetResult({
    required this.mode,
    required this.to,
    this.from,
    this.checkout,
  });
}

/// Moves the current branch to [to], and as much else as [mode] says.
///
/// The commits left behind are not deleted — nothing in git deletes a commit.
/// They become unreachable, which is a different thing, and the reflog still
/// names them (`refs.reflog`). That is what makes this recoverable and is why
/// the reflog is written before anything else moves.
ResetResult reset(
  Repository repository,
  ObjectId to, {
  ResetMode mode = ResetMode.mixed,
}) {
  final target = repository.peel(to);
  final id = target.id;

  final tree = repository.treeOf(id);
  if (tree == null) {
    throw ArgumentError.value(to, 'to', 'has no tree to reset to');
  }

  final from = repository.headId;

  // Written before the move, so that `ORIG_HEAD` names where this started
  // even if what follows fails. It is the other half of the reflog: one is a
  // history and the other is the single step a person is most likely to want
  // back.
  if (from != null) {
    fs.file(p.join(repository.gitDirectory, 'ORIG_HEAD'))
        .writeAsStringSync('${from.hex}\n');
  }

  final branch = repository.refs.currentBranch;
  repository.refs.write(
    branch ?? 'HEAD',
    id,
    reflogMessage: 'reset: moving to ${to.hex.substring(0, 8)}',
  );

  if (mode == ResetMode.soft) {
    return ResetResult(mode: mode, to: id, from: from);
  }

  if (mode == ResetMode.mixed) {
    _writeIndexFromTree(repository, tree);
    return ResetResult(mode: mode, to: id, from: from);
  }

  // Hard: the working tree is made to match, and forced, because refusing to
  // overwrite local changes is exactly what a hard reset is being asked to do.
  final result = checkoutTree(repository, tree, force: true);
  return ResetResult(mode: mode, to: id, from: from, checkout: result);
}

/// Rewrites the index to describe [tree], with no stat data.
///
/// The stat fields are left zero rather than filled in from the files that
/// happen to be there: after a mixed reset those files are *not* what the
/// index now says, and a cache claiming otherwise would hide the very changes
/// the reset was meant to unstage.
void _writeIndexFromTree(Repository repository, Tree tree) {
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

  walk(tree, '');
  GitIndex(entries: entries)
      .writeTo(p.join(repository.gitDirectory, 'index'));
}

/// Puts one path back to how [source] has it, in the index and optionally in
/// the working tree — what `git restore` does.
///
/// A path-level reset never moves a branch: it is a different operation
/// wearing the same name in older git, and keeping them apart here means
/// neither has to explain the other's flags.
void restorePath(
  Repository repository,
  String path, {
  ObjectId? source,
  bool worktree = false,
  bool staged = true,
}) {
  final from = source ?? repository.headId;
  final tree = from == null ? null : repository.treeOf(from);
  final entry = tree == null ? null : repository.lookup(tree, path);

  if (staged) {
    final index = repository.index ?? GitIndex.empty();
    final entries = [...index.entries]..removeWhere((e) => e.path == path);
    if (entry != null && !entry.mode.isTree) {
      entries.add(IndexEntry(
        path: path,
        id: entry.id,
        mode: entry.mode.numeric,
      ));
    }
    GitIndex(entries: entries)
        .writeTo(p.join(repository.gitDirectory, 'index'));
  }

  if (!worktree) return;

  final workTree = repository.workTree;
  if (workTree == null) {
    throw StateError('a bare repository has no working tree to restore');
  }
  final file = fs.file(p.join(workTree, path.replaceAll('/', p.separator)));

  if (entry == null || entry.mode.isTree) {
    // The source does not have this path, so restoring it means removing it.
    if (file.existsSync()) file.deleteSync();
    return;
  }
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(
    repository.convertToWorkTree(
      path,
      repository.objects.readTyped<Blob>(entry.id).content,
    ),
  );
}
