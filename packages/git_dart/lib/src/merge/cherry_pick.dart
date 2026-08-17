
import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/identity.dart';
import '../repository.dart';
import 'merge.dart';
import 'sequencer.dart';

/// What applying a commit did.
enum ApplyOutcome {
  /// A commit was written.
  applied,

  /// The change is already present: applying it would produce the tree that
  /// is already there.
  empty,

  /// Some paths need a person. Nothing was committed.
  conflicted,
}

class ApplyResult {
  final ApplyOutcome outcome;
  final ObjectId? commit;

  /// The commit that was being applied, which is not the same as [commit]:
  /// applying a change writes a *new* commit with the same difference.
  final ObjectId source;

  final List<String> conflicts;

  const ApplyResult({
    required this.outcome,
    required this.source,
    this.commit,
    this.conflicts = const [],
  });

  bool get ok => outcome != ApplyOutcome.conflicted;
}

/// Applies the change [commit] made, on top of HEAD.
///
/// A cherry-pick is a three-way merge wearing different clothes. The commit's
/// own parent is the base, HEAD is our side, and the commit is theirs — so
/// "what this commit changed" is derived rather than stored, exactly as a diff
/// is (`algorithms.diff`), and the same machinery that merges two branches
/// applies one commit somewhere else.
///
/// The result is a new commit with a new name. The original is untouched and
/// stays where it is: nothing in git moves a commit, and a cherry-pick least
/// of all — the whole point is to have the change in two places.
///
/// The author is kept and the committer is this repository's: the change is
/// still theirs, and putting it here is someone else's doing. That split is
/// the entire reason a commit carries both.
ApplyResult cherryPick(
  Repository repository,
  ObjectId commit, {
  Identity? committer,
  bool commitResult = true,
  int mainline = 1,
}) =>
    _apply(
      repository,
      commit,
      revert: false,
      committer: committer,
      commitResult: commitResult,
      mainline: mainline,
    );

/// Applies the opposite of what [commit] did, on top of HEAD.
///
/// The same three-way merge with two of the sides exchanged: the commit is the
/// base and its parent is theirs, so what it added is removed and what it
/// removed comes back. A revert is therefore a new commit that undoes an old
/// one, never the removal of the old one — the history keeps both, which is
/// what makes it safe to do on a branch other people have.
ApplyResult revert(
  Repository repository,
  ObjectId commit, {
  Identity? committer,
  bool commitResult = true,
  int mainline = 1,
}) =>
    _apply(
      repository,
      commit,
      revert: true,
      committer: committer,
      commitResult: commitResult,
      mainline: mainline,
    );

ApplyResult _apply(
  Repository repository,
  ObjectId id, {
  required bool revert,
  required bool commitResult,
  required int mainline,
  Identity? committer,
}) {
  final workTree = repository.workTree;
  if (workTree == null) {
    throw StateError('a bare repository has no working tree to apply to');
  }

  final head = repository.headId;
  if (head == null) {
    throw StateError('there is no commit to apply this on top of');
  }

  final index = repository.index;
  if (index != null && index.hasConflicts) {
    throw StateError('the index has conflicts; finish or abort that first');
  }

  final source = repository.peel(id);
  if (source is! Commit) {
    throw ArgumentError.value(id, 'commit', 'is not a commit');
  }

  // A merge commit has no single "change": it has one per parent. Which one
  // is meant has to be said, and git refuses rather than guessing — so this
  // does too, and takes the same answer in the same form.
  if (source.parents.length > 1 && mainline < 1) {
    throw ArgumentError.value(
      mainline,
      'mainline',
      'a merge commit needs a mainline parent to say which change to apply',
    );
  }
  if (source.parents.length > 1 && mainline > source.parents.length) {
    throw ArgumentError.value(
      mainline,
      'mainline',
      'this commit has ${source.parents.length} parents',
    );
  }

  final parent = source.parents.isEmpty
      ? null
      : source.parents[source.parents.length > 1 ? mainline - 1 : 0];

  // The three sides. Reverting swaps which end of the change is the base,
  // and nothing else about the operation differs.
  final theirSide = revert ? parent : source.id;
  final baseSide = revert ? source.id : parent;

  final applied = applyTrees(
    repository,
    baseFiles: filesOf(repository, baseSide),
    ourFiles: filesOf(repository, head),
    theirFiles: filesOf(repository, theirSide),
  );

  final operation =
      revert ? SequencerOperation.revert : SequencerOperation.cherryPick;

  if (applied.conflicts.isNotEmpty) {
    SequencerState(
      operation: operation,
      current: source.id,
      remaining: const [],
      originalHead: head,
      branch: repository.refs.currentBranch,
    ).writeTo(repository.gitDirectory);

    fs.file(p.join(repository.gitDirectory, 'MERGE_MSG'))
        .writeAsStringSync(_messageFor(source, revert: revert));

    return ApplyResult(
      outcome: ApplyOutcome.conflicted,
      source: source.id,
      conflicts: applied.conflicts,
    );
  }

  final tree = repository.writeTreeFromIndex();
  final headCommit = repository.objects.readTyped<Commit>(head);

  if (tree == headCommit.tree) {
    // The change is already here — applied earlier, or reverted twice. There
    // is nothing to record, and recording it anyway would put an empty commit
    // in the history claiming to have done something.
    return ApplyResult(outcome: ApplyOutcome.empty, source: source.id);
  }

  if (!commitResult) {
    return ApplyResult(outcome: ApplyOutcome.applied, source: source.id);
  }

  final who = committer ?? repository.identityFromConfig();
  if (who == null) {
    throw StateError(
      'no user.name and user.email are configured for this repository',
    );
  }

  final written = repository.commitTree(
    tree: tree,
    message: _messageFor(source, revert: revert),
    // A cherry-pick keeps the original author; a revert is new writing and is
    // attributed to whoever did it.
    author: revert ? who : source.author,
    committer: who,
    parents: [head],
    reflogMessage: revert ? 'revert' : 'cherry-pick',
  );

  SequencerState.clear(repository.gitDirectory);
  return ApplyResult(
    outcome: ApplyOutcome.applied,
    source: source.id,
    commit: written,
  );
}

String _messageFor(Commit source, {required bool revert}) =>
    revert ? revertMessage(source) : source.message;

/// Finishes a cherry-pick or revert whose conflicts have been resolved and
/// staged.
///
/// The message and the author come from the commit that was being applied,
/// which is why the sequencer wrote its name down: by the time a person has
/// resolved the conflict, nothing else in the repository still knows what was
/// being applied.
ObjectId continueApply(Repository repository, {Identity? committer}) {
  final state = SequencerState.read(repository.gitDirectory);
  if (state == null) {
    throw StateError('no cherry-pick or revert is in progress');
  }

  final index = repository.index;
  if (index != null && index.hasConflicts) {
    throw StateError('the index still has conflicts');
  }

  final source = repository.objects.readTyped<Commit>(state.current);
  final revert = state.operation == SequencerOperation.revert;

  final who = committer ?? repository.identityFromConfig();
  if (who == null) {
    throw StateError(
      'no user.name and user.email are configured for this repository',
    );
  }

  final id = repository.commitTree(
    tree: repository.writeTreeFromIndex(),
    message: _messageFor(source, revert: revert),
    author: revert ? who : source.author,
    committer: who,
    parents: [repository.headId!],
    reflogMessage: revert ? 'revert' : 'cherry-pick',
  );

  SequencerState.clear(repository.gitDirectory);
  final message = fs.file(p.join(repository.gitDirectory, 'MERGE_MSG'));
  if (message.existsSync()) message.deleteSync();

  return id;
}
