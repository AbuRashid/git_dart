import '../hooks/hook_steps.dart';
import '../hooks/hooks.dart';
import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/identity.dart';
import '../repository.dart';
import '../worktree/reset.dart';
import 'merge.dart';
import 'sequencer.dart';

enum RebaseOutcome {
  /// Every commit was replayed and the branch now sits on the new base.
  done,

  /// Nothing to do: the branch is already on top of it.
  alreadyThere,

  /// A commit could not be applied without a person. The working tree holds
  /// the conflict and the rest of the work is recorded.
  conflicted,
}

class RebaseResult {
  final RebaseOutcome outcome;

  /// Where the branch ended up.
  final ObjectId? head;

  /// The commits that were replayed, oldest first, as their new names.
  final List<ObjectId> replayed;

  /// The commit that stopped the rebase, when one did.
  final ObjectId? stoppedAt;

  final List<String> conflicts;

  const RebaseResult({
    required this.outcome,
    this.head,
    this.replayed = const [],
    this.stoppedAt,
    this.conflicts = const [],
  });

  bool get ok => outcome != RebaseOutcome.conflicted;
}

/// Replays the current branch's own commits on top of [onto].
///
/// A rebase does not move commits. It writes new ones with the same changes
/// and a different parent, then moves the branch to the last of them — the old
/// commits stay exactly where they were, reachable from nothing and named only
/// by the reflog. Everything about a rebase follows from that: why the names
/// all change, why it must not be done to history other people have, and why
/// it is recoverable when it goes wrong.
///
/// The commits replayed are those reachable from HEAD and not from [onto],
/// oldest first. A commit whose change is already present in [onto] — applied
/// there by hand, or cherry-picked earlier — produces nothing and is dropped,
/// which is what git does and is why a rebase after a merged pull request
/// usually has less to do than expected.
///
/// A rebase with something to do first runs `pre-rebase` with [onto]'s name,
/// and a failing hook throws [HookFailedException] before anything moves;
/// [noVerify] skips it, as `git rebase --no-verify` does. Moving to the new
/// base then runs `post-checkout`, as git's own checkout of `onto` does.
RebaseResult rebase(
  Repository repository,
  ObjectId onto, {
  Identity? committer,
  bool noVerify = false,
}) {
  final workTree = repository.workTree;
  if (workTree == null) {
    throw StateError('a bare repository has no working tree to rebase in');
  }
  if (SequencerState.read(repository.gitDirectory) != null) {
    throw StateError('an operation is already in progress');
  }

  final head = repository.headId;
  if (head == null) throw StateError('this branch has no commits to rebase');

  final index = repository.index;
  if (index != null && index.hasConflicts) {
    throw StateError('the index has conflicts; finish or abort that first');
  }

  final base = repository.peel(onto).id;

  // The branch already has this commit in its history, so it is already on top
  // of it and there is nothing to replay. Replaying anyway would rewrite every
  // commit on the branch to no purpose — new names for identical changes,
  // which is the one thing a rebase should not do idly.
  if (_contains(repository, head, base)) {
    return RebaseResult(outcome: RebaseOutcome.alreadyThere, head: head);
  }

  // Asked only once there is something to do: git reports a branch already
  // up to date without consulting the hook.
  if (!noVerify) runHook(repository, 'pre-rebase', arguments: [base.hex]);

  final todo = commitsToReplay(repository, head, base);

  if (todo.isEmpty) {
    // Nothing of our own since the base: the branch simply moves forward.
    reset(repository, base, mode: ResetMode.hard);
    _postCheckout(repository, head, base);
    final branch = repository.refs.currentBranch;
    if (branch != null) {
      repository.refs.write(branch, base, reflogMessage: 'rebase: fast-forward');
      repository.refs.writeSymbolic('HEAD', branch);
    }
    return RebaseResult(outcome: RebaseOutcome.done, head: base);
  }

  final branch = repository.refs.currentBranch;

  // The working tree goes to the new base first: every commit is then applied
  // on top of what is already there, which is what makes this a replay rather
  // than a diff of the two ends.
  reset(repository, base, mode: ResetMode.hard);
  _postCheckout(repository, head, base);

  return _replay(
    repository,
    todo: todo,
    originalHead: head,
    branch: branch,
    committer: committer,
    replayed: const [],
  );
}

void _postCheckout(Repository repository, ObjectId from, ObjectId to) =>
    runHook(
      repository,
      'post-checkout',
      arguments: [from.hex, to.hex, '1'],
      veto: false,
    );

/// The commits to replay: those on [head]'s first-parent line that [onto] does
/// not already have, oldest first.
///
/// The order is taken from the graph rather than from the dates. Committer
/// dates are seconds and a scripted or imported history commits several within
/// one of them, so sorting by date puts a child before its parent and the
/// replay applies a change to a tree that does not have what it builds on.
/// Following parents and reversing cannot get this wrong, because the graph
/// *is* the order.
///
/// The first-parent line is what gets replayed, so a merge on the branch is
/// flattened into the mainline rather than recreated. A merge records that two
/// histories met at a point which does not exist after a rebase; recreating it
/// would invent a merge that never happened. Git's default does the same.
List<ObjectId> commitsToReplay(
  Repository repository,
  ObjectId head,
  ObjectId onto,
) {
  final theirs = <ObjectId>{};
  final pending = <ObjectId>[onto];
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (!theirs.add(id)) continue;
    final raw = repository.objects.readRaw(id);
    if (raw == null) continue;
    final object = repository.objects.read(id);
    if (object is Commit) pending.addAll(object.parents);
  }

  final ours = <ObjectId>[];
  final seen = <ObjectId>{};
  ObjectId? at = head;

  while (at != null && !theirs.contains(at) && seen.add(at)) {
    final raw = repository.objects.readRaw(at);
    if (raw == null) break;
    final object = repository.objects.read(at);
    if (object is! Commit) break;
    ours.add(at);
    at = object.parents.isEmpty ? null : object.parents.first;
  }

  // Collected newest first by following parents; the replay wants the other
  // way round, so that each is applied on top of the one before it.
  return ours.reversed.toList();
}

RebaseResult _replay(
  Repository repository, {
  required List<ObjectId> todo,
  required ObjectId originalHead,
  required String? branch,
  required Identity? committer,
  required List<ObjectId> replayed,
}) {
  final done = [...replayed];
  final remaining = [...todo];

  while (remaining.isNotEmpty) {
    final id = remaining.removeAt(0);
    final source = repository.objects.readTyped<Commit>(id);
    final head = repository.headId!;

    final applied = applyTrees(
      repository,
      baseFiles: filesOf(
        repository,
        source.parents.isEmpty ? null : source.parents.first,
      ),
      ourFiles: filesOf(repository, head),
      theirFiles: filesOf(repository, id),
    );

    if (applied.conflicts.isNotEmpty) {
      SequencerState(
        operation: SequencerOperation.rebase,
        current: id,
        remaining: remaining,
        originalHead: originalHead,
        branch: branch,
      ).writeTo(repository.gitDirectory);

      return RebaseResult(
        outcome: RebaseOutcome.conflicted,
        stoppedAt: id,
        replayed: done,
        conflicts: applied.conflicts,
      );
    }

    final tree = repository.writeTreeFromIndex();
    if (tree == repository.objects.readTyped<Commit>(head).tree) {
      // The change is already in the new base. Dropped rather than recorded
      // as an empty commit claiming to have done something.
      continue;
    }

    final who = committer ?? repository.identityFromConfig();
    if (who == null) {
      throw StateError(
        'no user.name and user.email are configured for this repository',
      );
    }

    done.add(repository.commitTree(
      tree: tree,
      message: source.message,
      author: source.author,
      committer: who,
      parents: [head],
      reflogMessage: 'rebase',
    ));
  }

  SequencerState.clear(repository.gitDirectory);

  // The branch moves to where the replay ended. HEAD was detached through
  // the replay only in the sense that the branch had not caught up yet.
  final head = repository.headId!;
  if (branch != null) {
    repository.refs.write(
      branch,
      head,
      reflogMessage: 'rebase: finished',
    );
    repository.refs.writeSymbolic('HEAD', branch);
  }

  return RebaseResult(
    outcome: RebaseOutcome.done,
    head: head,
    replayed: done,
  );
}

/// Carries on a rebase whose conflicts have been resolved and staged.
///
/// [message] replaces the stopped commit's own message; the commits replayed
/// after it keep theirs.
RebaseResult continueRebase(
  Repository repository, {
  Identity? committer,
  String? message,
}) {
  final state = SequencerState.read(repository.gitDirectory);
  if (state == null || state.operation != SequencerOperation.rebase) {
    throw StateError('no rebase is in progress');
  }

  final index = repository.index;
  if (index != null && index.hasConflicts) {
    throw StateError('the index still has conflicts');
  }

  final source = repository.objects.readTyped<Commit>(state.current);
  final head = repository.headId!;
  final replayed = <ObjectId>[];

  // The commit that conflicted is finished from what is staged now, then the
  // rest of the list carries on as before.
  final tree = repository.writeTreeFromIndex();
  if (tree != repository.objects.readTyped<Commit>(head).tree) {
    final who = committer ?? repository.identityFromConfig();
    if (who == null) {
      throw StateError(
        'no user.name and user.email are configured for this repository',
      );
    }
    replayed.add(repository.commitTree(
      tree: tree,
      message: message == null || message.trim().isEmpty
          ? source.message
          : message.endsWith('\n')
              ? message
              : '$message\n',
      author: source.author,
      committer: who,
      parents: [head],
      reflogMessage: 'rebase',
    ));
  }

  return _replay(
    repository,
    todo: state.remaining,
    originalHead: state.originalHead,
    branch: state.branch,
    committer: committer,
    replayed: replayed,
  );
}

/// Abandons a rebase and puts the branch back where it started.
///
/// Recoverable because nothing was destroyed: the original commits were never
/// moved, only left unreferenced while the replay ran.
void abortRebase(Repository repository) {
  final state = SequencerState.read(repository.gitDirectory);
  if (state == null || state.operation != SequencerOperation.rebase) {
    throw StateError('no rebase is in progress');
  }

  reset(repository, state.originalHead, mode: ResetMode.hard);
  if (state.branch != null) {
    repository.refs.write(
      state.branch!,
      state.originalHead,
      reflogMessage: 'rebase: aborted',
    );
    repository.refs.writeSymbolic('HEAD', state.branch!);
  }
  SequencerState.clear(repository.gitDirectory);
}

bool _contains(Repository repository, ObjectId ours, ObjectId theirs) {
  final seen = <ObjectId>{};
  final pending = <ObjectId>[ours];
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (id == theirs) return true;
    if (!seen.add(id)) continue;
    final raw = repository.objects.readRaw(id);
    if (raw == null) continue;
    final object = repository.objects.read(id);
    if (object is Commit) pending.addAll(object.parents);
  }
  return false;
}
