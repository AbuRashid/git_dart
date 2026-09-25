import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syntax_dart/syntax_dart.dart';
import 'package:unimsg_view/unimsg_view.dart';

import '../generated/tokens.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import 'code_view.dart';
import 'settings_page.dart';

/// What is selected, shown in full.
class DetailPane extends StatelessWidget {
  final ExplorerState state;
  final VoidCallback? onBack;

  const DetailPane({super.key, required this.state, this.onBack});

  @override
  Widget build(BuildContext context) {
    return switch (state.selection) {
      NothingSelected() => const _Nothing(),
      RepositorySelected(:final repositoryPath) => _RepositoryDetail(
          state: state,
          repositoryPath: repositoryPath,
          onBack: onBack,
        ),
      FileSelected(:final repositoryPath, :final path) => _FileDetail(
          state: state,
          repositoryPath: repositoryPath,
          path: path,
          onBack: onBack,
        ),
      CommitSelected(:final repositoryPath) => _CommitDetail(
          state: state,
          repositoryPath: repositoryPath,
          onBack: onBack,
        ),
      SubmoduleSelected(:final repositoryPath, :final path) => _SubmoduleDetail(
          state: state,
          repositoryPath: repositoryPath,
          path: path,
          onBack: onBack,
        ),
    };
  }
}

class _Nothing extends StatelessWidget {
  const _Nothing();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        'Select a repository or a file',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// A pane's heading, as a small app bar.
class _Header extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final List<Widget> actions;

  const _Header({
    required this.title,
    this.subtitle,
    this.onBack,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppBar(
      automaticallyImplyLeading: false,
      leading: onBack == null
          ? null
          : IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: onBack,
              tooltip: 'Back',
            ),
      titleSpacing: onBack == null ? 16 : 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, overflow: TextOverflow.ellipsis),
          if (subtitle != null)
            Text(
              subtitle!,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
      actions: actions,
    );
  }
}

// ---------------------------------------------------------------------------
// a repository
// ---------------------------------------------------------------------------

class _RepositoryDetail extends StatelessWidget {
  final ExplorerState state;
  final String repositoryPath;
  final VoidCallback? onBack;

  const _RepositoryDetail({
    required this.state,
    required this.repositoryPath,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = state.summaryFor(repositoryPath);
    if (summary == null) return const _Nothing();

    if (!summary.available) {
      return Column(
        children: [
          _Header(
            title: summary.name,
            subtitle: summary.path,
            onBack: onBack,
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      summary.canInitialise
                          ? Icons.folder_outlined
                          : Icons.error_outline,
                      size: 40,
                      color: summary.canInitialise
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      summary.reason?.says ?? summary.error ?? 'unavailable',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (summary.error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        summary.error!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (summary.canInitialise)
                      FilledButton.icon(
                        onPressed: () =>
                            state.initialiseRepository(summary.path),
                        icon: const Icon(Icons.add),
                        label: const Text('Create a repository here'),
                      )
                    else
                      Text(
                        'It stays in the tree: a missing drive should not lose '
                        'your arrangement.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    final history = state.history;

    return Column(
      // The facts and the tabs describe the repository named above them, so
      // they start where its name starts rather than floating mid-pane.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: summary.name,
          subtitle: summary.path,
          onBack: onBack,
          actions: [
            _RevisionButton(state: state, summary: summary),
            IconButton(
              tooltip: 'Re-read from disk',
              onPressed: () => state.refresh(repositoryPath),
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'Settings',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => SettingsPage(
                    state: state,
                    repositoryPath: repositoryPath,
                    repositoryName: summary.name,
                  ),
                ),
              ),
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        _Facts(summary: summary),
        if (summary.busy) _InProgressBanner(state: state, summary: summary),
        if (state.lastOperation case final result?)
          _OperationReport(state: state, result: result, into: summary.branch),
        const Divider(height: 1),
        // History leads: it is what a repository is mostly looked at for.
        // Each tab owns its own controls — the commit box belongs to Staged
        // and appears nowhere else.
        Expanded(
          child: DefaultTabController(
            length: 4,
            child: Column(
              // A scrollable tab bar shrinks to its tabs, so without this the
              // column centres it and the tabs drift into the middle of the
              // pane, away from the content they label.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    const Tab(text: 'History'),
                    Tab(
                      text: switch (state.staging?.staged.length ?? 0) {
                        0 => 'Staged',
                        final n => 'Staged ($n)',
                      },
                    ),
                    Tab(text: 'Branches (${summary.branches.length})'),
                    Tab(text: 'Remotes (${state.remotes?.length ?? 0})'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      if (history == null)
                        const Center(child: CircularProgressIndicator())
                      else
                        ListView(
                          children: [
                            for (final commit in history)
                              _CommitRow(
                                commit: commit,
                                onTap: () => state.selectCommit(
                                  repositoryPath,
                                  commit.id,
                                ),
                                actions: _CommitActions(
                                  state: state,
                                  summary: summary,
                                  commit: commit,
                                ),
                              ),
                          ],
                        ),
                      Column(
                        children: [
                          Expanded(
                            child: ListView(
                              children: [
                                _StagingLists(
                                  state: state,
                                  repositoryPath: repositoryPath,
                                ),
                              ],
                            ),
                          ),
                          // Pinned, so a hundred changed files cannot hide the
                          // one control the tab exists for.
                          _CommitBox(
                            state: state,
                            repositoryPath: repositoryPath,
                          ),
                        ],
                      ),
                      ListView(
                        children: [
                          _Branches(
                            state: state,
                            repositoryPath: repositoryPath,
                            summary: summary,
                          ),
                        ],
                      ),
                      ListView(
                        children: [
                          _Remotes(
                            state: state,
                            repositoryPath: repositoryPath,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Facts extends StatelessWidget {
  final RepositorySummary summary;
  const _Facts({required this.summary});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.start,
        children: [
          Chip(
            avatar: const Icon(Icons.commit, size: 18),
            label: Text(
              summary.detached
                  ? 'detached at ${summary.headId?.substring(0, 8) ?? '—'}'
                  : summary.branch ?? 'no branch',
            ),
          ),
          Chip(label: Text('${summary.changedCount} changed')),
          Chip(label: Text('${summary.untrackedCount} untracked')),
          Chip(
              label:
                  Text(_count(summary.branches.length, 'branch', 'branches'))),
          Chip(label: Text(_count(summary.tags.length, 'tag', 'tags'))),
        ],
      ),
    );
  }
}

/// A count with the right noun for it.
String _count(int n, String one, String many) => '$n ${n == 1 ? one : many}';

class _Heading extends StatelessWidget {
  final String label;
  final int? count;
  final Widget? trailing;

  const _Heading({required this.label, this.count, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Text(
            count == null ? label : '$label ($count)',
            style: theme.textTheme.titleSmall,
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// The branches and tags, and what can be done to them.
class _Branches extends StatelessWidget {
  final ExplorerState state;
  final String repositoryPath;
  final RepositorySummary summary;

  const _Branches({
    required this.state,
    required this.repositoryPath,
    required this.summary,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = summary.branch;
    final hasCommits = summary.headId != null;

    Widget hint(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            text,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        );

    // Merging or rebasing a detached HEAD, or while something else is
    // stopped, is not offered: the first has no branch to move and the
    // second has to be finished first.
    final canMerge = current != null && !summary.detached && !summary.busy;

    return Column(
      children: [
        _Heading(
          label: 'Branches',
          count: summary.branches.length,
          trailing: TextButton.icon(
            onPressed: hasCommits
                ? () => _newBranch(context, state, repositoryPath)
                : null,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New branch'),
          ),
        ),
        if (summary.branches.isEmpty)
          hint('No branches yet — the first commit makes one.')
        else
          for (final branch in summary.branches)
            ListTile(
              dense: true,
              leading: Icon(
                branch == current
                    ? Icons.radio_button_checked
                    : Icons.call_split,
                color: branch == current ? theme.colorScheme.primary : null,
              ),
              title: Text(branch),
              subtitle: switch ((
                branch == current,
                summary.upstreams[branch]
              )) {
                (true, null) => const Text('checked out'),
                (true, final upstream?) =>
                  Text('checked out · follows $upstream'),
                (false, final upstream?) => Text('follows $upstream'),
                (false, null) => null,
              },
              onTap: branch == current
                  ? null
                  : () => _checkout(context, state, repositoryPath, branch),
              trailing: PopupMenuButton<String>(
                tooltip: 'Branch actions',
                onSelected: (choice) async {
                  switch (choice) {
                    case 'checkout':
                      await _checkout(context, state, repositoryPath, branch);
                    case 'merge':
                      await _merge(context, state, repositoryPath, branch,
                          into: current!);
                    case 'rebase':
                      await _rebase(context, state, repositoryPath, branch,
                          current: current!);
                    case 'pick':
                      await _pickFrom(context, state, repositoryPath, branch,
                          current: current ?? 'HEAD');
                    case 'branch':
                      await _newBranch(context, state, repositoryPath,
                          startPoint: branch);
                    case 'upstream':
                      await _chooseUpstream(
                          context, state, repositoryPath, summary, branch);
                    case 'rename':
                      await _renameBranch(
                        context,
                        state,
                        repositoryPath,
                        branch,
                      );
                    case 'delete':
                      await _deleteBranch(
                        context,
                        state,
                        repositoryPath,
                        branch,
                      );
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'checkout',
                    enabled: branch != current && !summary.busy,
                    child: const Text('Switch to'),
                  ),
                  PopupMenuItem(
                    value: 'merge',
                    enabled: canMerge && branch != current,
                    child: Text(
                      current == null ? 'Merge' : 'Merge into $current',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'rebase',
                    enabled: canMerge && branch != current,
                    child: Text(
                      current == null
                          ? 'Rebase onto this…'
                          : 'Rebase $current onto this…',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'pick',
                    enabled: hasCommits && !summary.busy && branch != current,
                    child: const Text('Cherry-pick a commit…'),
                  ),
                  const PopupMenuItem(
                    value: 'branch',
                    child: Text('New branch from here…'),
                  ),
                  PopupMenuItem(
                    value: 'upstream',
                    enabled: summary.remoteBranches.isNotEmpty ||
                        summary.upstreams.containsKey(branch),
                    child: const Text('Follow a remote branch…'),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'rename', child: Text('Rename…')),
                  PopupMenuItem(
                    value: 'delete',
                    // The checked-out branch cannot go; git refuses it too.
                    enabled: branch != current,
                    child: const Text('Delete…'),
                  ),
                ],
              ),
            ),
        if (summary.remoteBranches.isNotEmpty) ...[
          _Heading(
            label: 'Remote branches',
            count: summary.remoteBranches.length,
          ),
          for (final remoteBranch in summary.remoteBranches)
            ListTile(
              dense: true,
              leading: const Icon(Icons.cloud_outlined),
              title: Text(remoteBranch),
              trailing: PopupMenuButton<String>(
                tooltip: 'Remote branch actions',
                onSelected: (choice) async {
                  switch (choice) {
                    case 'checkout':
                      await _checkoutRemote(context, state, repositoryPath,
                          summary, remoteBranch);
                    case 'merge':
                      await _merge(context, state, repositoryPath, remoteBranch,
                          into: current!, fromRemote: true);
                    case 'rebase':
                      await _rebase(
                          context, state, repositoryPath, remoteBranch,
                          current: current!, fromRemote: true);
                    case 'pick':
                      await _pickFrom(
                          context, state, repositoryPath, remoteBranch,
                          current: current ?? 'HEAD', fromRemote: true);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'checkout',
                    enabled: !summary.busy,
                    child: const Text('Check out as a local branch…'),
                  ),
                  PopupMenuItem(
                    value: 'merge',
                    enabled: canMerge,
                    child: Text(
                      current == null ? 'Merge' : 'Merge into $current',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'rebase',
                    enabled: canMerge,
                    child: Text(
                      current == null
                          ? 'Rebase onto this…'
                          : 'Rebase $current onto this…',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'pick',
                    enabled: hasCommits && !summary.busy,
                    child: const Text('Cherry-pick a commit…'),
                  ),
                ],
              ),
            ),
        ],
        _Heading(
          label: 'Tags',
          count: summary.tags.length,
          trailing: TextButton.icon(
            onPressed: hasCommits
                ? () => _newTag(context, state, repositoryPath)
                : null,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New tag'),
          ),
        ),
        if (summary.tags.isEmpty)
          hint('No tags.')
        else
          for (final tag in summary.tags)
            ListTile(
              dense: true,
              leading: const Icon(Icons.sell_outlined),
              title: Text(tag),
              trailing: PopupMenuButton<String>(
                tooltip: 'Tag actions',
                onSelected: (choice) async {
                  if (choice == 'delete') {
                    await _deleteTag(context, state, repositoryPath, tag);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'delete', child: Text('Delete…')),
                ],
              ),
            ),
      ],
    );
  }
}

/// What the last merge, cherry-pick, revert, rebase or stash application
/// did, by name (`care.reported`).
class _OperationReport extends StatelessWidget {
  final ExplorerState state;
  final OperationResult result;
  final String? into;

  const _OperationReport({
    required this.state,
    required this.result,
    required this.into,
  });

  String _headline() {
    final target = into ?? 'HEAD';
    final subject = result.subject;
    final conflicts = result.conflicts.length;
    final commits = _count(result.replayed, 'commit', 'commits');

    if (result.error != null) {
      return switch (result.operation) {
        Operation.merge => 'Merging $subject failed',
        Operation.cherryPick => 'Cherry-picking $subject failed',
        Operation.revert => 'Reverting $subject failed',
        Operation.rebase => 'Rebasing onto $subject failed',
        Operation.applyStash ||
        Operation.popStash =>
          'Applying $subject failed',
        Operation.continueOperation => 'Continuing the $subject failed',
      };
    }

    if (result.outcome == 'conflicted') {
      final resolve = conflicts == 0
          ? 'there are conflicts to resolve'
          : '${_count(conflicts, 'file needs', 'files need')} resolving';
      return switch (result.operation) {
        Operation.merge => 'Merging $subject: $resolve',
        Operation.cherryPick => 'Cherry-picking $subject: $resolve',
        Operation.revert => 'Reverting $subject: $resolve',
        Operation.rebase ||
        Operation.continueOperation =>
          'The rebase stopped again: $resolve',
        Operation.applyStash => 'Applying $subject: $resolve',
        // `rewriting.a-conflicted-stash-is-kept`
        Operation.popStash => 'Applying $subject: $resolve. The stash is kept.',
      };
    }

    return switch ((result.operation, result.outcome)) {
      (Operation.merge, 'alreadyUpToDate') =>
        '$target already has everything in $subject',
      (Operation.merge, 'fastForward') => 'Moved $target forward to $subject',
      (Operation.merge, _) => 'Merged $subject into $target',
      (Operation.cherryPick, 'empty') =>
        '$target already has the change $subject made',
      (Operation.cherryPick, _) => 'Cherry-picked $subject onto $target',
      (Operation.revert, 'empty') =>
        'Nothing to revert: $target no longer has the change $subject made',
      (Operation.revert, _) => 'Reverted $subject',
      (Operation.rebase, 'alreadyThere') =>
        '$target is already on top of $subject',
      (Operation.rebase, _) => result.replayed == 0
          ? 'Moved $target forward to $subject'
          : 'Rebased $target onto $subject, replaying $commits',
      (Operation.applyStash, _) => 'Applied $subject; it is still stashed',
      (Operation.popStash, _) => 'Applied and dropped $subject',
      (Operation.continueOperation, 'applied') => 'Finished the $subject',
      (Operation.continueOperation, _) => result.replayed == 0
          ? 'Finished the rebase'
          : 'Finished the rebase, replaying $commits',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        color: result.ok
            ? successBackground(context)
            : theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _headline(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: result.ok ? onSuccessBackground(context) : null,
                      ),
                    ),
                    for (final path in result.conflicts.take(10))
                      Text(path, style: monospaceStyle(context)),
                    if (result.conflicts.length > 10)
                      Text('and ${result.conflicts.length - 10} more'),
                    if (result.error case final message?)
                      Text(message, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                color: result.ok ? onSuccessBackground(context) : null,
                onPressed: state.dismissLastOperation,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The way out of whatever stopped on conflicts, shown for as long as it
/// lasts (`branching.a-merge-in-progress-is-always-visible`,
/// `rewriting.one-thing-in-progress-at-a-time`).
class _InProgressBanner extends StatelessWidget {
  final ExplorerState state;
  final RepositorySummary summary;

  const _InProgressBanner({required this.state, required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = summary.inProgress!;
    final conflicts =
        state.staging?.rows.where((r) => r.isConflicted).length ?? 0;
    final finish = kind == InProgress.merge ? 'commit' : 'continue';
    final commit = summary.inProgressCommit;

    final what = switch (kind) {
      InProgress.merge => 'A merge is in progress.',
      InProgress.cherryPick => 'Cherry-picking $commit.',
      InProgress.revert => 'Reverting $commit.',
      InProgress.rebase => summary.rebaseRemaining == 0
          ? 'Rebasing: stopped at $commit.'
          : 'Rebasing: stopped at $commit, with '
              '${_count(summary.rebaseRemaining, 'commit', 'commits')} to go.',
    };
    final next = conflicts == 0
        ? '${finish[0].toUpperCase()}${finish.substring(1)} to finish it.'
        : 'Resolve '
            '${_count(conflicts, 'conflicted file', 'conflicted files')}, '
            'stage and $finish to finish it.';

    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              kind == InProgress.merge ? Icons.merge : Icons.alt_route,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$what $next',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: () =>
                  _abortOperation(context, state, summary.path, kind),
              child: Text('Abort ${kind.label}'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows what an action did, or why it was refused, in a snackbar.
void _report(
  BuildContext context,
  ExplorerState state, {
  required bool ok,
  required String done,
  required String refused,
}) {
  if (!context.mounted) return;
  final failure = state.error ?? refused;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: copyableSnackBarMessage(
        ok ? done : failure,
        copyText: ok ? null : failure,
      ),
    ),
  );
}

/// Asks a yes-or-no question whose yes does something that cannot be undone.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  List<String> paths = const [],
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            if (paths.isNotEmpty) const SizedBox(height: 12),
            for (final path in paths.take(20))
              Text(path, style: monospaceStyle(context)),
            if (paths.length > 20) Text('and ${paths.length - 20} more'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Switches branch, offering to force it when uncommitted changes are in the
/// way (`branching.a-checkout-that-would-lose-work-is-refused-first`).
Future<void> _checkout(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  String branch,
) async {
  var outcome = await state.checkoutBranch(repositoryPath, branch);
  if (!context.mounted) return;
  if (outcome != null && !outcome.ok) {
    final force = await _confirm(
      context,
      title: 'Switch to $branch anyway?',
      body: 'These files have changes that are not committed, and $branch '
          'has different versions of them. Switching will replace them, '
          'and the changes will be lost.',
      action: 'Discard and switch',
      paths: outcome.blockedBy,
    );
    if (!force || !context.mounted) return;
    outcome = await state.checkoutBranch(repositoryPath, branch, force: true);
  }
  if (!context.mounted) return;
  _report(
    context,
    state,
    ok: outcome != null && outcome.ok,
    done: outcome == null || outcome.degraded.isEmpty
        ? 'Switched to $branch'
        : 'Switched to $branch; '
            '${_count(outcome.degraded.length, 'file', 'files')} could not '
            'take the mode git records',
    refused: 'Could not switch to $branch',
  );
}

/// Asks for a new branch's name, and whether to switch to it.
Future<void> _newBranch(
  BuildContext context,
  ExplorerState state,
  String repositoryPath, {
  String? startPoint,
  String? startLabel,
}) async {
  final controller = TextEditingController();
  var switchTo = true;

  final name = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(
          startPoint == null
              ? 'New branch'
              : 'New branch from ${startLabel ?? startPoint}',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'Slashes group branches, as in feature/thing',
              ),
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: switchTo,
              onChanged: (value) => setState(() => switchTo = value ?? false),
              title: const Text('Switch to it'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    ),
  );

  final branch = name?.trim();
  if (branch == null || branch.isEmpty) return;

  final outcome = await state.createBranch(
    repositoryPath,
    branch,
    startPoint: startPoint,
    checkout: switchTo,
  );
  if (!context.mounted) return;
  if (outcome != null && !outcome.ok) {
    // Created, and not switched to: offer the same choice a switch does.
    await _checkout(context, state, repositoryPath, branch);
    return;
  }
  _report(
    context,
    state,
    ok: outcome != null,
    done: switchTo ? 'Created and switched to $branch' : 'Created $branch',
    refused: 'Could not create $branch',
  );
}

/// Creates a local branch from a remote one, following it, and switches to it
/// (`branching.a-remote-branch-is-checked-out-as-a-local-one`).
Future<void> _checkoutRemote(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  RepositorySummary summary,
  String remoteBranch,
) async {
  final suggested = remoteBranch.substring(remoteBranch.indexOf('/') + 1);

  // A local branch of that name already following it needs no new branch.
  if (summary.upstreams[suggested] == remoteBranch) {
    await _checkout(context, state, repositoryPath, suggested);
    return;
  }

  final controller = TextEditingController(
    text: summary.branches.contains(suggested) ? '' : suggested,
  );
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Check out $remoteBranch'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Local branch name',
          helperText: summary.branches.contains(suggested)
              ? 'There is already a branch called $suggested'
              : 'It will follow $remoteBranch',
        ),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Check out'),
        ),
      ],
    ),
  );

  final branch = name?.trim();
  if (branch == null || branch.isEmpty) return;

  final outcome = await state.createBranch(
    repositoryPath,
    branch,
    startPoint: remoteBranch,
    fromRemote: true,
    checkout: true,
  );
  if (!context.mounted) return;
  if (outcome != null && !outcome.ok) {
    await _checkout(context, state, repositoryPath, branch);
    return;
  }
  _report(
    context,
    state,
    ok: outcome != null,
    done: 'Switched to $branch, following $remoteBranch',
    refused: 'Could not check out $remoteBranch',
  );
}

Future<void> _merge(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  String source, {
  required String into,
  bool fromRemote = false,
}) async {
  final merged = await state.mergeBranch(
    repositoryPath,
    source,
    fromRemote: fromRemote,
  );
  // A merge that ran is reported on its own card; only a refusal needs
  // saying here.
  if (merged == null && context.mounted) {
    _report(
      context,
      state,
      ok: false,
      done: '',
      refused: 'Could not merge $source into $into',
    );
  }
}

Future<void> _abortOperation(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  InProgress kind,
) async {
  final confirmed = await _confirm(
    context,
    title: 'Abort the ${kind.label}?',
    body: switch (kind) {
      InProgress.rebase =>
        'The branch goes back to where it was before the rebase, with its '
            'original commits. Conflicts already resolved, and anything else '
            'changed since, will be lost.',
      _ => 'The files and the staging area go back to how they were before '
          'the ${kind.label}. Conflicts already resolved, and anything else '
          'changed since, will be lost.',
    },
    action: 'Abort ${kind.label}',
  );
  if (!confirmed) return;
  final ok = await state.abortOperation(repositoryPath);
  if (!context.mounted) return;
  _report(
    context,
    state,
    ok: ok,
    done: '${kind.label[0].toUpperCase()}${kind.label.substring(1)} '
        'abandoned',
    refused: 'Could not abort the ${kind.label}',
  );
}

/// Replays the current branch onto [onto], after saying what that does
/// (`rewriting.a-rebase-is-confirmed`).
Future<void> _rebase(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  String onto, {
  required String current,
  bool fromRemote = false,
}) async {
  final confirmed = await _confirm(
    context,
    title: 'Rebase $current onto $onto?',
    body: 'The commits $current has that $onto does not are written again '
        'on top of $onto, with new names. If $current has been pushed, '
        'anyone who has it will see it diverge, and pushing it again will '
        'need force. The old commits stay in the reflog.',
    action: 'Rebase',
  );
  if (!confirmed) return;
  final result =
      await state.rebaseOnto(repositoryPath, onto, fromRemote: fromRemote);
  if (result == null && context.mounted) {
    _report(
      context,
      state,
      ok: false,
      done: '',
      refused: 'Could not rebase $current onto $onto',
    );
  }
}

/// Lists what [branch] has that HEAD does not, and cherry-picks the one
/// chosen (`rewriting.cherry-picking-starts-from-the-branch`).
Future<void> _pickFrom(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  String branch, {
  required String current,
  bool fromRemote = false,
}) async {
  final commits =
      await state.unmerged(repositoryPath, branch, fromRemote: fromRemote);
  if (!context.mounted) return;
  if (commits.isEmpty) {
    _report(
      context,
      state,
      ok: state.error == null,
      done: '$branch has no commits that $current does not',
      refused: 'Could not list the commits on $branch',
    );
    return;
  }

  final chosen = await showDialog<CommitData>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('Cherry-pick from $branch onto $current'),
      children: [
        for (final commit in commits)
          SimpleDialogOption(
            onPressed:
                commit.isMerge ? null : () => Navigator.pop(context, commit),
            child: Row(
              children: [
                Text(commit.shortId, style: monospaceStyle(context)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    commit.isMerge
                        ? '${commit.summary} (a merge; not offered)'
                        : commit.summary,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
  if (chosen == null) return;
  final result = await state.cherryPick(repositoryPath, chosen.id);
  if (result == null && context.mounted) {
    _report(
      context,
      state,
      ok: false,
      done: '',
      refused: 'Could not cherry-pick ${chosen.shortId}',
    );
  }
}

Future<void> _revertCommit(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  CommitData commit,
) async {
  final result = await state.revertCommit(repositoryPath, commit.id);
  if (result == null && context.mounted) {
    _report(
      context,
      state,
      ok: false,
      done: '',
      refused: 'Could not revert ${commit.shortId}',
    );
  }
}

/// Asks for a stash message and whether untracked files go too.
Future<void> _stashChanges(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
) async {
  final message = TextEditingController();
  var includeUntracked = false;

  final stash = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Stash the changes'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: message,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Message (optional)',
                helperText: 'The files go back to how HEAD has them',
              ),
              onSubmitted: (_) => Navigator.pop(context, true),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: includeUntracked,
              onChanged: (value) =>
                  setState(() => includeUntracked = value ?? false),
              title: const Text('Untracked files too'),
              subtitle: const Text('They are removed from disk until the '
                  'stash is applied'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stash'),
          ),
        ],
      ),
    ),
  );
  if (stash != true) return;

  final ok = await state.saveStash(
    repositoryPath,
    message: message.text,
    includeUntracked: includeUntracked,
  );
  if (!context.mounted) return;
  _report(
    context,
    state,
    ok: ok,
    done: 'Stashed the changes',
    refused: 'Could not stash the changes',
  );
}

Future<void> _dropStash(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  StashData stash,
) async {
  final confirmed = await _confirm(
    context,
    title: 'Drop ${stash.name}?',
    body: 'The changes it holds are removed from the list. They can be '
        'found again only by searching for unreachable commits, until git '
        'cleans those up.',
    action: 'Drop',
  );
  if (!confirmed) return;
  final ok = await state.dropStash(repositoryPath, stash.index);
  if (!context.mounted) return;
  _report(
    context,
    state,
    ok: ok,
    done: 'Dropped ${stash.name}',
    refused: 'Could not drop ${stash.name}',
  );
}

Future<void> _useStash(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  StashData stash, {
  required bool pop,
}) async {
  final result = await state.applyStash(repositoryPath, stash.index, pop: pop);
  if (result == null && context.mounted) {
    _report(
      context,
      state,
      ok: false,
      done: '',
      refused: 'Could not apply ${stash.name}',
    );
  }
}

Future<void> _chooseUpstream(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  RepositorySummary summary,
  String branch,
) async {
  final current = summary.upstreams[branch];
  // A sentinel for "follow nothing", since null means the dialog was closed.
  const none = '';

  final chosen = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('What should $branch follow?'),
      children: [
        for (final remoteBranch in summary.remoteBranches)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, remoteBranch),
            child: Row(
              children: [
                Icon(
                  remoteBranch == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                const SizedBox(width: 12),
                Flexible(child: Text(remoteBranch)),
              ],
            ),
          ),
        if (current != null)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, none),
            child: const Row(
              children: [
                Icon(Icons.link_off, size: 18),
                SizedBox(width: 12),
                Text('Nothing'),
              ],
            ),
          ),
      ],
    ),
  );
  if (chosen == null || chosen == current) return;

  final upstream = chosen == none ? null : chosen;
  final ok = await state.setUpstream(repositoryPath, branch, upstream);
  if (!context.mounted) return;
  _report(
    context,
    state,
    ok: ok,
    done: upstream == null
        ? '$branch follows nothing now'
        : '$branch follows $upstream',
    refused: 'Could not change what $branch follows',
  );
}

/// Asks for a tag's name and, optionally, a message — which makes it an
/// annotated tag, carrying who made it.
Future<void> _newTag(
  BuildContext context,
  ExplorerState state,
  String repositoryPath, {
  String? at,
  String? atLabel,
}) async {
  final name = TextEditingController();
  final message = TextEditingController();

  final created = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title:
          Text(at == null ? 'New tag at HEAD' : 'New tag at ${atLabel ?? at}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'v1.0',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: message,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Message (optional)',
              helperText: 'With a message the tag records who made it',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Create'),
        ),
      ],
    ),
  );

  final tag = name.text.trim();
  if (created != true || tag.isEmpty) return;

  final ok = await state.createTag(
    repositoryPath,
    tag,
    at: at,
    message: message.text,
  );
  if (!context.mounted) return;
  _report(
    context,
    state,
    ok: ok,
    done: 'Tagged ${atLabel ?? 'HEAD'} as $tag',
    refused: 'Could not create $tag',
  );
}

Future<void> _deleteTag(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  String tag,
) async {
  final confirmed = await _confirm(
    context,
    title: 'Delete $tag?',
    body: 'The commit it names stays. If the tag was pushed, the remote '
        'keeps its copy until it is deleted there too.',
    action: 'Delete',
  );
  if (!confirmed) return;
  final ok = await state.deleteTag(repositoryPath, tag);
  if (!context.mounted) return;
  _report(
    context,
    state,
    ok: ok,
    done: 'Deleted $tag',
    refused: 'Could not delete $tag',
  );
}

/// Moves the current branch to [commit], in the strength the user picks
/// (`branching.a-reset-says-how-much-it-keeps`).
Future<void> _resetTo(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  RepositorySummary summary,
  CommitData commit,
) async {
  var strength = ResetStrength.mixed;
  final target = summary.detached ? 'HEAD' : summary.branch ?? 'HEAD';

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Reset $target to ${commit.shortId}?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Commits after this one leave $target. They are not deleted, '
                'and the reflog still names them.',
              ),
              const SizedBox(height: 8),
              RadioGroup<ResetStrength>(
                groupValue: strength,
                onChanged: (value) =>
                    setState(() => strength = value ?? strength),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final choice in ResetStrength.values)
                      RadioListTile<ResetStrength>(
                        contentPadding: EdgeInsets.zero,
                        value: choice,
                        title: Text(choice.label),
                        subtitle: Text(switch (choice) {
                          ResetStrength.soft => 'soft',
                          ResetStrength.mixed => 'mixed',
                          ResetStrength.hard =>
                            'hard — uncommitted changes are lost too',
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: strength == ResetStrength.hard
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true) return;

  final ok = await state.resetBranch(repositoryPath, commit.id, strength);
  if (!context.mounted) return;
  _report(
    context,
    state,
    ok: ok,
    done: 'Reset $target to ${commit.shortId}',
    refused: 'Could not reset $target',
  );
}

Future<void> _discard(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  StatusRow row,
) async {
  final confirmed = await _confirm(
    context,
    title: 'Discard changes to ${row.path}?',
    body: row.staged == null
        ? 'The file goes back to how HEAD has it. The changes are not '
            'recorded anywhere, and cannot be recovered.'
        // Said outright: a staged version is easy to forget having made.
        : 'The file goes back to how HEAD has it, and the staged version '
            'goes too. The changes on disk cannot be recovered.',
    action: 'Discard',
  );
  if (!confirmed) return;
  final ok = await state.discardChanges(repositoryPath, row.path);
  if (!context.mounted) return;
  _report(
    context,
    state,
    ok: ok,
    done: 'Discarded the changes to ${row.path}',
    refused: 'Could not discard the changes to ${row.path}',
  );
}

/// Whether a row can be discarded back to HEAD: tracked there, and not a
/// conflict (`branching.discarding-goes-back-to-head`).
bool _canDiscard(StatusRow row) =>
    row.unstaged != null &&
    !row.isUntracked &&
    !row.isConflicted &&
    row.staged != FileState.added;

Future<void> _renameBranch(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  String branch,
) async {
  final controller = TextEditingController(text: branch);

  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Rename $branch'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'New name',
          helperText: 'Slashes group branches, as in feature/thing',
        ),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Rename'),
        ),
      ],
    ),
  );

  final to = name?.trim();
  if (to == null || to.isEmpty || to == branch) return;

  final ok = await state.renameBranch(repositoryPath, branch, to);
  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: copyableSnackBarMessage(
        ok ? 'Renamed $branch to $to' : state.error ?? 'Rename refused',
        copyText: ok ? null : state.error ?? 'Rename refused',
      ),
    ),
  );
}

Future<void> _deleteBranch(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  String branch,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete $branch?'),
      content: const Text(
        'The commits stay in the repository; nothing points at them from '
        'here afterwards. If they are not on another branch, they become '
        'hard to find.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  final ok = await state.deleteBranch(repositoryPath, branch);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: copyableSnackBarMessage(
        ok ? 'Deleted $branch' : state.error ?? 'Delete refused',
        copyText: ok ? null : state.error ?? 'Delete refused',
      ),
    ),
  );
}

/// The remotes, and fetching from them.
class _Remotes extends StatelessWidget {
  final ExplorerState state;
  final String repositoryPath;

  const _Remotes({required this.state, required this.repositoryPath});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remotes = state.remotes;

    return Column(
      children: [
        _Heading(
          label: 'Remotes',
          count: remotes?.length,
          trailing: TextButton.icon(
            onPressed: () => _addRemote(context, state, repositoryPath),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
          ),
        ),
        if (remotes == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (remotes.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'No remotes. Add one to fetch from it.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else
          for (final remote in remotes)
            ListTile(
              dense: true,
              leading: Icon(
                remote.isLocal ? Icons.folder_outlined : Icons.cloud_outlined,
              ),
              title: Row(
                children: [
                  Flexible(child: Text(remote.name)),
                  const SizedBox(width: 8),
                  _Divergence(remote: remote),
                ],
              ),
              subtitle: Text(remote.url, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state.fetching == remote.name)
                    Tooltip(
                      message: state.fetchProgress ?? 'fetching',
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else
                    IconButton(
                      tooltip: remote.canFetch
                          ? 'Fetch'
                          // Said here rather than discovered when the button
                          // does nothing.
                          : 'This build talks http(s), or to a folder',
                      onPressed: remote.canFetch && state.fetching == null
                          ? () => _fetch(context, state, repositoryPath, remote)
                          : null,
                      icon: const Icon(Icons.download_outlined),
                    ),
                  if (state.pulling == remote.name)
                    Tooltip(
                      message: state.pullProgress ?? 'pulling',
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else
                    IconButton(
                      tooltip: remote.canFetch
                          ? 'Pull — fetch, then merge into this branch'
                          : 'This build talks http(s), or to a folder',
                      onPressed: remote.canFetch &&
                              state.pulling == null &&
                              state.fetching == null
                          ? () => _pull(context, state, repositoryPath, remote)
                          : null,
                      icon: const Icon(Icons.sync),
                    ),
                  if (state.pushing == remote.name)
                    Tooltip(
                      message: state.pushProgress ?? 'pushing',
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else
                    IconButton(
                      tooltip: remote.canFetch
                          ? 'Push the current branch'
                          : 'This build talks http(s), or to a folder',
                      onPressed: remote.canFetch && state.pushing == null
                          ? () => _push(context, state, repositoryPath, remote)
                          : null,
                      icon: const Icon(Icons.upload_outlined),
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'Remote actions',
                    onSelected: (choice) async {
                      switch (choice) {
                        case 'rename':
                          await _renameRemote(
                              context, state, repositoryPath, remote.name);
                        case 'remove':
                          final confirmed = await _confirm(
                            context,
                            title: 'Remove ${remote.name}?',
                            body: 'Its copies of the remote branches go too. '
                                'Nothing on the remote itself changes.',
                            action: 'Remove',
                          );
                          if (confirmed) {
                            await state.removeRemote(
                                repositoryPath, remote.name);
                          }
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename…')),
                      PopupMenuItem(value: 'remove', child: Text('Remove…')),
                    ],
                  ),
                ],
              ),
            ),
        if (state.lastPull case final outcome?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              color: outcome.ok
                  ? successBackground(context)
                  : theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            switch (outcome) {
                              _ when outcome.error != null =>
                                'Pull from ${outcome.remote} failed',
                              _ when outcome.conflicts.isNotEmpty =>
                                '${outcome.conflicts.length} '
                                    '${outcome.conflicts.length == 1 ? 'file needs' : 'files need'} '
                                    'resolving',
                              _
                                  when outcome.mergeOutcome ==
                                      'alreadyUpToDate' =>
                                'Nothing new to merge',
                              _ when outcome.mergeOutcome == 'fastForward' =>
                                'Moved forward to ${outcome.remote}',
                              _ => 'Merged ${outcome.remote}',
                            },
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: outcome.ok
                                  ? onSuccessBackground(context)
                                  : null,
                            ),
                          ),
                          for (final path in outcome.conflicts)
                            Text(path, style: monospaceStyle(context)),
                          if (outcome.error case final message?)
                            Text(message, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: state.dismissLastPull,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (state.lastPush case final outcome?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              margin: EdgeInsets.zero,
              color: outcome.ok
                  ? theme.colorScheme.surfaceContainerHighest
                  : theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            outcome.needsCredentials
                                ? '${outcome.remote} needs a sign-in'
                                : outcome.error != null
                                    ? 'Push to ${outcome.remote} failed'
                                    : outcome.rejected.isNotEmpty
                                        ? 'Push to ${outcome.remote} refused'
                                        : outcome.updated.isEmpty
                                            ? '${outcome.remote} already has these '
                                                'commits'
                                            : 'Pushed ${outcome.objectsSent} '
                                                'objects to ${outcome.remote}',
                            style: theme.textTheme.bodyMedium,
                          ),
                          for (final line in outcome.updated)
                            Text(line, style: monospaceStyle(context)),
                          for (final line in outcome.rejected)
                            Text(line, style: monospaceStyle(context)),
                          if (outcome.error case final message?)
                            Text(message, style: theme.textTheme.bodySmall),
                          // Offered only for the case it fixes, and never
                          // done without being asked.
                          if (outcome.canForce)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: OutlinedButton(
                                onPressed: () => _push(
                                  context,
                                  state,
                                  repositoryPath,
                                  RemoteData(
                                    name: outcome.remote,
                                    url: '',
                                  ),
                                  force: true,
                                ),
                                child: const Text('Force push'),
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: state.dismissLastPush,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (state.lastFetch case final outcome?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              margin: EdgeInsets.zero,
              color: outcome.error != null
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            outcome.needsCredentials
                                ? '${outcome.remote} needs a sign-in'
                                : outcome.error != null
                                    ? 'Fetch from ${outcome.remote} failed'
                                    : outcome.updated.isEmpty
                                        // Not "up to date": a fetch that brought
                                        // nothing says nothing about whether this
                                        // branch and the remote's agree.
                                        ? 'No new commits on ${outcome.remote}'
                                        : 'Fetched ${outcome.objectsReceived} '
                                            'objects from ${outcome.remote}',
                            style: theme.textTheme.bodyMedium,
                          ),
                          // What moved, by name (`care.reported`).
                          for (final line in outcome.updated)
                            Text(line, style: monospaceStyle(context)),
                          if (outcome.error case final message?)
                            Text(message, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: state.dismissLastFetch,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// What the user typed when asked to sign in.
typedef SignIn = ({String username, String password, bool remember});

/// Asks for a username and a secret.
///
/// Most hosts want a personal access token in the password field rather than
/// an account password, so the field says so instead of leaving it to be
/// guessed after a rejection.
Future<SignIn?> askForCredentials(
  BuildContext context, {
  required String remote,
  String? username,
  required bool wereRejected,
  required bool canSave,
}) async {
  final name = TextEditingController(text: username ?? '');
  final secret = TextEditingController();
  var remember = canSave;

  return showDialog<SignIn>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(wereRejected ? 'Sign in again' : 'Sign in to $remote'),
        // Scrollable rather than a plain Column: two fields, a two-line
        // checkbox subtitle and the keyboard all competing for a phone's
        // height overflows otherwise - the keyboard is what a password field
        // guarantees will be on screen.
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (wereRejected)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('The saved details were refused.'),
                ),
              TextField(
                controller: name,
                autofocus: (username ?? '').isEmpty,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: secret,
                autofocus: (username ?? '').isNotEmpty,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password or access token',
                ),
                onSubmitted: (_) => Navigator.pop(context, (
                  username: name.text.trim(),
                  password: secret.text,
                  remember: remember,
                )),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: remember,
                onChanged: canSave
                    ? (value) => setState(() => remember = value ?? false)
                    : null,
                title: const Text('Save it'),
                subtitle: Text(
                  canSave
                      // Named plainly: the user should know where their secret
                      // is going, and that it is not this application's own file.
                      ? 'Kept by git\'s credential helper, the same store git '
                          'itself uses'
                      : 'No credential helper is configured, so this can only '
                          'be remembered until the window closes',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, (
              username: name.text.trim(),
              password: secret.text,
              remember: remember,
            )),
            child: const Text('Sign in'),
          ),
        ],
      ),
    ),
  );
}

/// Fetches, asking for credentials when the remote wants them.
Future<void> _fetch(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  RemoteData remote,
) async {
  final outcome = await state.fetchRemote(repositoryPath, remote.name);
  if (outcome == null || !outcome.needsCredentials) return;
  if (!context.mounted) return;

  final signIn = await askForCredentials(
    context,
    remote: remote.name,
    username: outcome.username,
    wereRejected: outcome.wereRejected,
    canSave: outcome.canSave,
  );
  if (signIn == null) return;

  await state.fetchRemote(
    repositoryPath,
    remote.name,
    username: signIn.username,
    password: signIn.password,
    remember: signIn.remember,
  );
}

/// Fetches and merges, asking for credentials when the remote wants them.
Future<void> _pull(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  RemoteData remote,
) async {
  final outcome = await state.pullRemote(repositoryPath, remote.name);
  if (outcome == null || !outcome.fetch.needsCredentials) return;
  if (!context.mounted) return;

  final signIn = await askForCredentials(
    context,
    remote: remote.name,
    username: outcome.fetch.username,
    wereRejected: outcome.fetch.wereRejected,
    canSave: outcome.fetch.canSave,
  );
  if (signIn == null) return;

  await state.pullRemote(
    repositoryPath,
    remote.name,
    username: signIn.username,
    password: signIn.password,
    remember: signIn.remember,
  );
}

/// Pushes, asking first when it would overwrite.
Future<void> _push(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  RemoteData remote, {
  bool force = false,
}) async {
  if (force) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Force push?'),
        content: Text(
          '${remote.name} holds commits this branch does not. Forcing will '
          'overwrite them there, and whoever made them may have no other '
          'copy.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Force push'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }

  final outcome =
      await state.pushRemote(repositoryPath, remote.name, force: force);
  if (outcome == null || !outcome.needsCredentials) return;
  if (!context.mounted) return;

  final signIn = await askForCredentials(
    context,
    remote: remote.name,
    username: outcome.username,
    wereRejected: outcome.wereRejected,
    canSave: outcome.canSave,
  );
  if (signIn == null) return;

  await state.pushRemote(
    repositoryPath,
    remote.name,
    force: force,
    username: signIn.username,
    password: signIn.password,
    remember: signIn.remember,
  );
}

/// How far the current branch stands from this remote's copy of it.
///
/// Always as of the last fetch, which the tooltip says outright: the numbers
/// describe what this repository knows, not what the server holds now, and a
/// counter that quietly implied otherwise would be worse than none.
class _Divergence extends StatelessWidget {
  final RemoteData remote;

  const _Divergence({required this.remote});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (remote.trackingRef == null) {
      // Two different situations, and the advice differs: fetch to find out,
      // or the remote genuinely has no copy of this branch.
      final message = remote.neverFetched
          ? 'Nothing has been fetched from this remote yet, so there is '
              'nothing here to compare against'
          : 'This remote has no copy of the current branch yet';
      return Tooltip(
        message: message,
        child: Text(
          remote.neverFetched ? 'fetch to compare' : 'no copy yet',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    if (remote.tooLargeToCount) {
      return Tooltip(
        message: 'This history is too large to count quickly',
        child: Text('—', style: theme.textTheme.bodySmall),
      );
    }

    if (!remote.hasCounts) return const SizedBox.shrink();

    if (remote.isEven) {
      return Tooltip(
        message: 'Level with ${remote.trackingRef}, as of the last fetch',
        child: Text(
          'up to date',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    return Tooltip(
      message: 'Against ${remote.trackingRef}, as of the last fetch:\n'
          '${remote.ahead} to push, ${remote.behind} to pull',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (remote.ahead! > 0) ...[
            Icon(Icons.arrow_upward, size: 14, color: successMark(context)),
            Text(
              '${remote.ahead}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: successMark(context)),
            ),
          ],
          if (remote.behind! > 0) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.arrow_downward,
              size: 14,
              color: statusColor(FileState.modified, context),
            ),
            Text(
              '${remote.behind}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: statusColor(FileState.modified, context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> _renameRemote(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  String remote,
) async {
  final controller = TextEditingController(text: remote);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Rename $remote'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'New name',
          helperText: 'What it fetched, and what follows it, keep up',
        ),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Rename'),
        ),
      ],
    ),
  );

  final to = name?.trim();
  if (to == null || to.isEmpty || to == remote) return;
  final ok = await state.renameRemote(repositoryPath, remote, to);
  if (!context.mounted) return;
  _report(
    context,
    state,
    ok: ok,
    done: 'Renamed $remote to $to',
    refused: 'Could not rename $remote',
  );
}

Future<void> _addRemote(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
) async {
  final name = TextEditingController(text: 'origin');
  final url = TextEditingController();

  final added = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Add a remote'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: url,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'URL or folder',
              hintText: 'https://example.com/project.git',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Add'),
        ),
      ],
    ),
  );

  if (added != true) return;
  if (name.text.trim().isEmpty || url.text.trim().isEmpty) return;
  await state.addRemote(repositoryPath, name.text.trim(), url.text.trim());
}

/// The staging area's two lists.
///
/// Two lists with the same file in both is the only honest presentation of a
/// file staged one way and modified again since
/// (`committing.why-the-index-is-shown`).
class _StagingLists extends StatelessWidget {
  final ExplorerState state;
  final String repositoryPath;

  const _StagingLists({required this.state, required this.repositoryPath});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final staging = state.staging;

    if (staging == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final staged = staging.staged;
    final notStaged = staging.notStaged;
    final summary = state.summaryFor(repositoryPath);
    final stashes = summary?.stashes ?? const <StashData>[];
    final busy = summary?.busy ?? false;

    Widget hint(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            text,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        );

    return Column(
      children: [
        _Heading(
          label: 'Staged',
          count: staged.length,
          trailing: staged.isEmpty
              ? null
              : TextButton(
                  onPressed: () async {
                    for (final row in staged) {
                      await state.setStaged(
                        repositoryPath,
                        row.path,
                        staged: false,
                      );
                    }
                  },
                  child: const Text('Unstage all'),
                ),
        ),
        if (staged.isEmpty)
          hint(staging.isEmpty
              ? 'The working tree is clean.'
              : 'Nothing staged yet.')
        else
          for (final row in staged)
            _StagingRow(
              row: row,
              staged: true,
              onToggle: () =>
                  state.setStaged(repositoryPath, row.path, staged: false),
              onOpen: () => state.selectFile(repositoryPath, row.path),
            ),
        _Heading(
          label: 'Not staged',
          count: notStaged.length,
          trailing: notStaged.isEmpty
              ? null
              : TextButton(
                  onPressed: () async {
                    for (final row in notStaged) {
                      await state.setStaged(
                        repositoryPath,
                        row.path,
                        staged: true,
                      );
                    }
                  },
                  child: const Text('Stage all'),
                ),
        ),
        if (notStaged.isEmpty)
          hint('Nothing to stage.')
        else
          for (final row in notStaged)
            _StagingRow(
              row: row,
              staged: false,
              onToggle: () =>
                  state.setStaged(repositoryPath, row.path, staged: true),
              onOpen: () => state.selectFile(repositoryPath, row.path),
              onDiscard: _canDiscard(row)
                  ? () => _discard(context, state, repositoryPath, row)
                  : null,
            ),
        _Heading(
          label: 'Stashes',
          count: stashes.length,
          trailing: TextButton.icon(
            onPressed: staging.isEmpty || busy
                ? null
                : () => _stashChanges(context, state, repositoryPath),
            icon: const Icon(Icons.inventory_2_outlined, size: 18),
            label: const Text('Stash changes'),
          ),
        ),
        if (stashes.isEmpty)
          hint('Nothing stashed.')
        else
          for (final stash in stashes)
            ListTile(
              dense: true,
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(stash.message, overflow: TextOverflow.ellipsis),
              subtitle: Text(stash.name),
              trailing: PopupMenuButton<String>(
                tooltip: 'Stash actions',
                onSelected: (choice) async {
                  switch (choice) {
                    case 'apply':
                      await _useStash(context, state, repositoryPath, stash,
                          pop: false);
                    case 'pop':
                      await _useStash(context, state, repositoryPath, stash,
                          pop: true);
                    case 'drop':
                      await _dropStash(context, state, repositoryPath, stash);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'pop',
                    enabled: !busy,
                    child: const Text('Apply and drop'),
                  ),
                  PopupMenuItem(
                    value: 'apply',
                    enabled: !busy,
                    child: const Text('Apply, and keep it'),
                  ),
                  const PopupMenuItem(value: 'drop', child: Text('Drop…')),
                ],
              ),
            ),
      ],
    );
  }
}

class _StagingRow extends StatelessWidget {
  final StatusRow row;
  final bool staged;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  /// Offered only where going back to HEAD is what discarding means.
  final VoidCallback? onDiscard;

  const _StagingRow({
    required this.row,
    required this.staged,
    required this.onToggle,
    required this.onOpen,
    this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = staged
        ? row.staged
        : (row.unstaged ??
            (row.isUntracked ? FileState.untracked : row.staged));
    final color = shown == null ? null : statusColor(shown, context);

    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 20,
        child: Text(
          row.isConflicted ? 'U' : (shown?.code ?? ''),
          textAlign: TextAlign.center,
          style: theme.textTheme.labelLarge?.copyWith(color: color),
        ),
      ),
      title: Text(row.path, overflow: TextOverflow.ellipsis),
      // A move is one change with two names, and the name it left behind is
      // what a reader following the file is looking for.
      subtitle: row.oldPath == null
          ? null
          : Text(
              'moved from ${row.oldPath}',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onDiscard != null)
            IconButton(
              tooltip: 'Discard changes',
              onPressed: onDiscard,
              icon: const Icon(Icons.undo),
            ),
          IconButton(
            tooltip: staged ? 'Unstage' : 'Stage',
            onPressed: onToggle,
            icon: Icon(staged ? Icons.remove : Icons.add),
          ),
        ],
      ),
      onTap: onOpen,
    );
  }
}

/// The message and the commit button, in a fixed footer.
///
/// Not at the end of the scrolling list of changes: a repository with a
/// hundred changed files would hide the one control the panel exists for
/// (`committing.the-commit-box-is-pinned`).
class _CommitBox extends StatefulWidget {
  final ExplorerState state;
  final String repositoryPath;

  const _CommitBox({required this.state, required this.repositoryPath});

  @override
  State<_CommitBox> createState() => _CommitBoxState();
}

class _CommitBoxState extends State<_CommitBox> {
  final _message = TextEditingController();

  /// Which stopped operation, and which commit of it, the prepared message
  /// was last offered for.
  String? _offeredFor;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final stopped = widget.state.summaryFor(widget.repositoryPath)?.inProgress;
    // A cherry-pick, revert or rebase is finished by continuing it, which
    // is what records it as finished (`rewriting.continuing-is-committing`).
    if (stopped != null && stopped != InProgress.merge) {
      final result = await widget.state.continueOperation(
        widget.repositoryPath,
        _message.text,
      );
      if (result != null) _message.clear();
      return;
    }
    final commit = await widget.state.commitStaged(
      widget.repositoryPath,
      _message.text,
    );
    if (commit != null) _message.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.state;
    final staging = state.staging;
    if (staging == null) return const SizedBox.shrink();

    final staged = staging.staged;
    final summary = state.summaryFor(widget.repositoryPath);
    final stopped = summary?.inProgress;
    final prepared = summary?.preparedMessage;
    // The message the stopped operation prepared is offered once for each
    // commit it stops on, as git offers it.
    final offerKey =
        stopped == null ? null : '${stopped.name} ${summary?.inProgressCommit}';
    if (offerKey != null && prepared != null && _offeredFor != offerKey) {
      _offeredFor = offerKey;
      if (_message.text.trim().isEmpty) _message.text = prepared.trimRight();
    } else if (offerKey == null) {
      _offeredFor = null;
    }
    final canCommit = (staged.isNotEmpty || stopped != null) &&
        _message.text.trim().isNotEmpty &&
        staging.identity != null &&
        !staging.hasConflicts &&
        !state.isCommitting;

    return Material(
      elevation: 3,
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.lastCommit case final committed?) ...[
              // On its own card, the same as the fetch and push reports: a
              // bare row of text reads as part of the form above it, and what
              // was just written deserves to be seen.
              Card(
                margin: EdgeInsets.zero,
                // Elevation and the surface tint that comes with it are what
                // turned this green grey; the fill is stated outright instead.
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                color: successBackground(context),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  child: Row(
                    children: [
                      // A white tick in a solid green disc. Drawn in the same
                      // dark green as the text it sits beside, it stopped
                      // reading as a mark and became part of the sentence.
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: successMark(context),
                        child: const Icon(
                          Icons.check,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Committed ${committed.shortId}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: onSuccessBackground(context)),
                            ),
                            Text(
                              committed.summary,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: onSuccessBackground(context),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Dismiss',
                        color: onSuccessBackground(context),
                        onPressed: state.dismissLastCommit,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _message,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Commit message',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    // A commit attributed to a guess is worse than one that
                    // did not happen.
                    staging.identity ??
                        'Set user.name and user.email to commit',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: staging.identity == null
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: canCommit ? _commit : null,
                  child: Text(
                    state.isCommitting
                        ? 'Committing…'
                        : switch (stopped) {
                              InProgress.merge => 'Commit the merge',
                              InProgress.rebase => 'Continue the rebase',
                              InProgress.cherryPick => 'Finish the cherry-pick',
                              InProgress.revert => 'Finish the revert',
                              null => null,
                            } ??
                            'Commit ${staged.length} '
                                '${staged.length == 1 ? 'file' : 'files'}',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RevisionButton extends StatelessWidget {
  final ExplorerState state;
  final RepositorySummary summary;

  const _RevisionButton({required this.state, required this.summary});

  @override
  Widget build(BuildContext context) {
    final revision = state.revisionFor(summary.path);

    return PopupMenuButton<Revision>(
      tooltip: 'Look at another revision',
      onSelected: (choice) => state.setRevision(summary.path, choice),
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: Revision.workingTree,
          child: Text('Working tree'),
        ),
        const PopupMenuItem(value: Revision.head, child: Text('HEAD')),
        if (summary.branches.isNotEmpty) const PopupMenuDivider(),
        for (final branch in summary.branches)
          PopupMenuItem(
            value: Revision(RevisionKind.branch, branch),
            child: Text(branch),
          ),
        if (summary.tags.isNotEmpty) const PopupMenuDivider(),
        for (final tag in summary.tags.take(20))
          PopupMenuItem(
            value: Revision(RevisionKind.branch, tag),
            child: Text(tag),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(revision.label),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

class _CommitRow extends StatelessWidget {
  final CommitData commit;
  final VoidCallback onTap;
  final Widget? actions;

  const _CommitRow({required this.commit, required this.onTap, this.actions});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: Text(
        commit.shortId,
        style:
            monospaceStyle(context).copyWith(color: theme.colorScheme.primary),
      ),
      title: Text(commit.summary, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${commit.authorName} · ${_when(commit.when)}'
        '${commit.isMerge ? ' · merge' : ''}',
        overflow: TextOverflow.ellipsis,
      ),
      trailing: actions,
      onTap: onTap,
    );
  }
}

/// What can be started from a commit in the history.
class _CommitActions extends StatelessWidget {
  final ExplorerState state;
  final RepositorySummary summary;
  final CommitData commit;

  const _CommitActions({
    required this.state,
    required this.summary,
    required this.commit,
  });

  @override
  Widget build(BuildContext context) {
    final target = summary.detached ? 'HEAD' : summary.branch ?? 'HEAD';
    return PopupMenuButton<String>(
      tooltip: 'Commit actions',
      onSelected: (choice) async {
        switch (choice) {
          case 'branch':
            await _newBranch(
              context,
              state,
              summary.path,
              startPoint: commit.id,
              startLabel: commit.shortId,
            );
          case 'tag':
            await _newTag(
              context,
              state,
              summary.path,
              at: commit.id,
              atLabel: commit.shortId,
            );
          case 'reset':
            await _resetTo(context, state, summary.path, summary, commit);
          case 'revert':
            await _revertCommit(context, state, summary.path, commit);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'branch', child: Text('New branch here…')),
        const PopupMenuItem(value: 'tag', child: Text('New tag here…')),
        PopupMenuItem(
          value: 'reset',
          // A merge can be reset away; a stopped cherry-pick, revert or
          // rebase has to be finished or abandoned first.
          enabled:
              commit.id != summary.headId && (!summary.busy || summary.merging),
          child: Text('Reset $target to here…'),
        ),
        PopupMenuItem(
          value: 'revert',
          // `rewriting.a-merge-is-not-reverted-here`
          enabled: !commit.isMerge && !summary.busy,
          child: Text(
            commit.isMerge
                ? 'Revert (not offered for a merge)'
                : 'Revert this commit',
          ),
        ),
      ],
    );
  }
}

String _when(DateTime when) {
  final local = when.toLocal();
  final difference = DateTime.now().difference(local);
  if (difference.inDays > 60) {
    return '${local.year}-${_two(local.month)}-${_two(local.day)}';
  }
  if (difference.inDays >= 1) return '${difference.inDays}d ago';
  if (difference.inHours >= 1) return '${difference.inHours}h ago';
  if (difference.inMinutes >= 1) return '${difference.inMinutes}m ago';
  return 'just now';
}

String _two(int value) => value.toString().padLeft(2, '0');

// ---------------------------------------------------------------------------
// a file
// ---------------------------------------------------------------------------

/// A gitlink: what `.gitmodules` and the tree say about it, joined with
/// whether it has actually been cloned.
class _SubmoduleDetail extends StatelessWidget {
  final ExplorerState state;
  final String repositoryPath;
  final String path;
  final VoidCallback? onBack;

  const _SubmoduleDetail({
    required this.state,
    required this.repositoryPath,
    required this.path,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final submodule = state.submodule;

    if (submodule == null) {
      return Column(
        children: [
          _Header(title: path.split('/').last, subtitle: path, onBack: onBack),
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }

    return Column(
      children: [
        _Header(
            title: submodule.name, subtitle: submodule.path, onBack: onBack),
        Expanded(
          child: submodule.unavailable != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      submodule.unavailable!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Chip(
                      avatar: Icon(
                        switch (submodule.status) {
                          SubmoduleStatus.current => Icons.check_circle_outline,
                          SubmoduleStatus.moved => Icons.sync_problem_outlined,
                          SubmoduleStatus.notInitialised =>
                            Icons.download_outlined,
                          SubmoduleStatus.undescribed => Icons.help_outline,
                        },
                        size: 18,
                      ),
                      label: Text(switch (submodule.status) {
                        SubmoduleStatus.current => 'up to date',
                        SubmoduleStatus.moved => 'checked out elsewhere',
                        SubmoduleStatus.notInitialised => 'not cloned',
                        SubmoduleStatus.undescribed => 'not in .gitmodules',
                      }),
                    ),
                    const SizedBox(height: 20),
                    if (submodule.url != null)
                      _SubmoduleFact(label: 'URL', value: submodule.url!),
                    if (submodule.branch != null)
                      _SubmoduleFact(label: 'Branch', value: submodule.branch!),
                    if (submodule.recordedCommit != null)
                      _SubmoduleFact(
                        label: 'Recorded commit',
                        value: submodule.recordedCommit!.substring(0, 8),
                      ),
                    if (submodule.checkedOutCommit != null)
                      _SubmoduleFact(
                        label: 'Checked-out commit',
                        value: submodule.checkedOutCommit!.substring(0, 8),
                      ),
                    const SizedBox(height: 24),
                    if (submodule.openableAt != null)
                      FilledButton.icon(
                        onPressed: () => state
                            .openSubmoduleRepository(submodule.openableAt!),
                        icon: const Icon(Icons.dataset_linked_outlined),
                        label: const Text('Open as a repository'),
                      )
                    else if (submodule.status == SubmoduleStatus.notInitialised)
                      Text(
                        'Nothing is cloned here yet, so there is nothing to '
                        'browse. ${submodule.url == null ? '' : 'Clone '
                            '${submodule.url} into ${submodule.path} to '
                            'explore it.'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _SubmoduleFact extends StatelessWidget {
  final String label;
  final String value;
  const _SubmoduleFact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          SelectableText(
            value,
            style:
                theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}

class _FileDetail extends StatefulWidget {
  final ExplorerState state;
  final String repositoryPath;
  final String path;
  final VoidCallback? onBack;

  const _FileDetail({
    required this.state,
    required this.repositoryPath,
    required this.path,
    this.onBack,
  });

  @override
  State<_FileDetail> createState() => _FileDetailState();
}

/// The ways one file can be shown.
enum _FileView { document, file, diff, blame }

class _FileDetailState extends State<_FileDetail> {
  /// A changed file opens on the file, not on its diff: the file is the thing
  /// that can be acted on (`editing.a-changed-file-opens-on-the-file`). A
  /// document opens on the document, for the reason given in
  /// `presentation.a-document-opens-as-a-document`.
  _FileView _view = _FileView.file;

  /// Which file the choice above was made for, so that opening another one
  /// starts from its own default rather than from the last file's.
  String? _viewFor;

  /// The open file read as a document, and the text it was read from.
  DocumentSource? _reading;
  String? _readFrom;

  final _editor = HighlightingEditingController();
  final _editorFocus = FocusNode();

  /// What the controller was last filled from, so it is not refilled — and the
  /// caret not thrown to the start — on every rebuild.
  String? _filledFor;

  @override
  void dispose() {
    _editor.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  void _syncEditor(FileContent content) {
    final draft = widget.state.draftFor(widget.repositoryPath, widget.path);
    final wanted = draft ?? content.text ?? '';
    final key = '${widget.repositoryPath} ${widget.path}';
    // One controller serves every file the pane opens, so the grammar is set
    // here rather than at construction.
    _editor.grammar = grammarForPath(widget.path);
    if (_filledFor == key && _editor.text == wanted) return;
    if (_filledFor == key && draft != null && _editor.text == draft) return;
    _filledFor = key;
    _editor.value = TextEditingValue(
      text: wanted,
      selection: TextSelection.collapsed(
        offset: _editor.selection.baseOffset.clamp(0, wanted.length),
      ),
    );
  }

  /// Whether this file is one this application can read as a document.
  ///
  /// The name, not the contents: a file that will not parse is still a `.umsg`
  /// file, and telling its author that it has stopped being one because they
  /// are half-way through typing a brace would be unhelpful and untrue.
  bool get _isDocument => widget.path.toLowerCase().endsWith('.umsg');

  /// Reads the open file as a document, once per change to its text.
  void _syncDocument(String? source) {
    if (source == null) {
      _reading = null;
      _readFrom = null;
      return;
    }
    if (_readFrom == source) return;
    _readFrom = source;
    _reading = DocumentSource.read(source);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.state;
    final content = state.fileContent;
    final diff = state.fileDiff;
    final revision = state.revisionFor(widget.repositoryPath);

    final dirty = state.hasDraft(widget.repositoryPath, widget.path);
    final editable =
        revision.kind.editable && content != null && content.isEditable;

    if (editable) _syncEditor(content);

    // The draft rather than the saved text, so the page shows what the editor
    // holds. Someone who edits, switches to the document and finds their last
    // paragraph missing has been shown a different file than the one they are
    // working on.
    final source =
        state.draftFor(widget.repositoryPath, widget.path) ?? content?.text;
    if (_isDocument) _syncDocument(source);

    final key = '${widget.repositoryPath} ${widget.path}';
    if (content != null && _viewFor != key) {
      _viewFor = key;
      // Coming back from a commit reached by tapping a blame line lands on
      // Blame again rather than on the file it always otherwise opens on -
      // that is where the click that led here was made from.
      final wantsBlame =
          state.consumeWantsBlameView(widget.repositoryPath, widget.path) &&
              !content.isBinary;
      _view = _isDocument && (_reading?.isDocument ?? false)
          ? _FileView.document
          : wantsBlame
              ? _FileView.blame
              : _FileView.file;
      if (_view == _FileView.blame) {
        state.loadBlame(widget.repositoryPath, revision, widget.path);
      }
    }

    final views = [
      if (_isDocument) _FileView.document,
      _FileView.file,
      if (diff != null) _FileView.diff,
      if (content != null && !content.isBinary) _FileView.blame,
    ];
    // A diff of something being edited compares the wrong pair, so it is
    // withheld rather than shown wrong — the rule this pane already followed.
    final showing = _view == _FileView.diff && dirty ? _FileView.file : _view;

    return Column(
      children: [
        _Header(
          title: widget.path.split('/').last,
          subtitle: '${widget.path} · ${revision.label}'
              '${dirty ? ' · unsaved' : ''}',
          onBack: widget.onBack,
          actions: [
            if (dirty) ...[
              TextButton(
                onPressed: () {
                  state.discardDraft(widget.repositoryPath, widget.path);
                  _filledFor = null;
                },
                child: const Text('Revert'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () =>
                    state.saveFile(widget.repositoryPath, widget.path),
                child: const Text('Save'),
              ),
              const SizedBox(width: 8),
            ],
            if (views.length > 1)
              SegmentedButton<_FileView>(
                segments: [
                  for (final view in views)
                    ButtonSegment(
                      value: view,
                      label: Text(switch (view) {
                        _FileView.document => 'Document',
                        _FileView.file => 'File',
                        _FileView.diff => 'Diff',
                        _FileView.blame => 'Blame',
                      }),
                    ),
                ],
                selected: {showing},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  final next = selection.first;
                  setState(() => _view = next);
                  if (next == _FileView.blame) {
                    state.loadBlame(
                        widget.repositoryPath, revision, widget.path);
                  }
                },
              ),
            const SizedBox(width: 8),
          ],
        ),
        if (content == null)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (showing == _FileView.document)
          Expanded(
            child: _DocumentPane(
              reading: _reading,
              title: widget.path.split('/').last,
            ),
          )
        else if (showing == _FileView.diff && diff != null)
          Expanded(child: _DiffView(diff: diff))
        else if (showing == _FileView.blame)
          Expanded(
            child: state.blame == null
                ? const Center(child: CircularProgressIndicator())
                : _BlameView(
                    blame: state.blame!,
                    state: state,
                    repositoryPath: widget.repositoryPath,
                    revision: revision,
                    path: widget.path,
                  ),
          )
        else if (editable)
          Expanded(
            child: _Editor(
              controller: _editor,
              focusNode: _editorFocus,
              onChanged: (text) =>
                  state.editFile(widget.repositoryPath, widget.path, text),
              onSave: () => state.saveFile(widget.repositoryPath, widget.path),
            ),
          )
        else if (content.notLoaded != null)
          Expanded(
            child: Center(
              child: Text(
                content.isBinary
                    ? 'Binary file, ${_size(content.size)}'
                    : content.notLoaded!,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          )
        else
          Expanded(
            child: _TextView(path: widget.path, text: content.text ?? ''),
          ),
      ],
    );
  }
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} kB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// The file, editable.
///
/// A text field rather than a code editor: this is for fixing a typo and
/// adding a line, and there is no folding, no completion and no navigation
/// here. It is coloured, though, because the alternative was pressing edit and
/// watching the colours leave (`editing.the-editor-is-coloured-like-the-viewer`).
class _Editor extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSave;

  const _Editor({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): onSave,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): onSave,
      },
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          style: monospaceStyle(context),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
      ),
    );
  }
}

/// A `.umsg` file, as the document it is
/// (`presentation.a-document-opens-as-a-document`).
class _DocumentPane extends StatelessWidget {
  final DocumentSource? reading;
  final String title;

  const _DocumentPane({required this.reading, required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final document = reading?.document;

    if (document == null) {
      // Being unreadable is an ordinary state for a file someone is typing
      // into, not a failure. It says where, because that is the one thing the
      // author needs in order to fix it, and it does not offer to hide the
      // problem by showing a stale page.
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.report_gmailerrorred_outlined,
                size: 36,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                'Not a document yet',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(
                reading?.says ?? 'nothing to read',
                textAlign: TextAlign.center,
                style: monospaceStyle(context)
                    .copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Text(
                'The File view shows it as it stands.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return UnimsgDocumentView(
      document: document,
      title: title,
      palette: documentPalette(context),
      // The preamble is the one part of the file the tree does not carry.
      source: reading?.text,
    );
  }
}

class _TextView extends StatefulWidget {
  /// What the file is called, which is how its type is known
  /// (`presentation.syntax-colour`).
  final String path;
  final String text;

  const _TextView({required this.path, required this.text});

  @override
  State<_TextView> createState() => _TextViewState();
}

class _TextViewState extends State<_TextView> {
  late List<String> _lines;
  late CodeHighlighter _highlighter;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(_TextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Scanning the file is the expensive half, and it belongs to the file
    // rather than to the frame.
    if (oldWidget.text != widget.text || oldWidget.path != widget.path) {
      _prepare();
    }
  }

  void _prepare() {
    _lines = widget.text.split('\n');
    _highlighter = CodeHighlighter(widget.path, _lines);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = monospaceStyle(context);
    final palette = SyntaxPalette.of(context);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _lines.length,
      itemBuilder: (context, index) {
        final line = _lines[index];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.right,
                style: mono.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text.rich(
                codeSpan(
                  line,
                  _highlighter.tokensFor(index, line),
                  mono,
                  palette,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Who last touched each line, and when.
///
/// A commit is named once per run of lines it introduced, not on every line —
/// the same convention `git blame`'s own porcelain output and every code host
/// use, since a hundred lines from one commit repeating its own name a hundred
/// times would say nothing a single line does not already say.
class _BlameView extends StatelessWidget {
  final BlameData blame;
  final ExplorerState state;
  final String repositoryPath;
  final Revision revision;
  final String path;

  const _BlameView({
    required this.blame,
    required this.state,
    required this.repositoryPath,
    required this.revision,
    required this.path,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (blame.unavailable != null) {
      return Center(
        child: Text(
          blame.unavailable!,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    final mono = monospaceStyle(context);
    final palette = SyntaxPalette.of(context);
    final highlighter = CodeHighlighter(
      blame.path,
      [for (final line in blame.lines) line.text],
    );

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: blame.lines.length,
      itemBuilder: (context, index) {
        final line = blame.lines[index];
        // Named only where the commit above it differs, or at the very top.
        final sameAsAbove =
            index > 0 && blame.lines[index - 1].commitId == line.commitId;

        return InkWell(
          onTap: () => state.selectCommit(
            repositoryPath,
            line.commitId,
            returnTo: FileSelected(repositoryPath, revision, path),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 220,
                  child: sameAsAbove
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            '${line.commitId.substring(0, 8)} '
                            '${line.authorName} · ${_when(line.authorWhen)}',
                            overflow: TextOverflow.ellipsis,
                            style: mono.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${line.number}',
                    textAlign: TextAlign.right,
                    style: mono.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text.rich(
                    codeSpan(
                      line.text,
                      highlighter.tokensFor(index, line.text),
                      mono,
                      palette,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DiffView extends StatelessWidget {
  final FileDiff diff;
  const _DiffView({required this.diff});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = monospaceStyle(context);

    if (diff.isBinary) {
      return Center(
        child: Text('Binary files differ', style: theme.textTheme.bodyMedium),
      );
    }

    final added = statusColor(FileState.added, context)!;
    final removed = statusColor(FileState.deleted, context)!;
    final palette = SyntaxPalette.of(context);
    final highlighter = DiffHighlighter(diff.path);

    final rows = <Widget>[];
    for (final hunk in diff.hunks) {
      highlighter.startHunk();
      rows.add(Container(
        width: double.infinity,
        color: theme.colorScheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(
          hunk.header,
          style: mono.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ));
      for (final line in hunk.lines) {
        final color = switch (line.marker) {
          '+' => added,
          '-' => removed,
          _ => theme.colorScheme.onSurface,
        };
        rows.add(Container(
          color: switch (line.marker) {
            '+' => added.withValues(alpha: 0.10),
            '-' => removed.withValues(alpha: 0.10),
            _ => null,
          },
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 40,
                child: Text(
                  '${line.oldLine ?? ''}',
                  textAlign: TextAlign.right,
                  style: mono.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 40,
                child: Text(
                  '${line.newLine ?? ''}',
                  textAlign: TextAlign.right,
                  style: mono.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(line.marker, style: mono.copyWith(color: color)),
              const SizedBox(width: 4),
              // The text carries its own colours; what makes the line added or
              // removed is the marker and the wash behind it. Colouring both
              // would mean choosing between saying what the line is and saying
              // what happened to it, and the marker says the second on its own.
              Expanded(
                child: Text.rich(
                  codeSpan(
                    line.text,
                    highlighter.tokensFor(line),
                    mono,
                    palette,
                  ),
                ),
              ),
            ],
          ),
        ));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            // A diff with no label invites the reader to assume the wrong pair.
            'Between ${diff.against} · +${diff.insertions} −${diff.deletions}',
            style: theme.textTheme.bodySmall,
          ),
        ),
        Expanded(child: ListView(children: rows)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// a commit
// ---------------------------------------------------------------------------

class _CommitDetail extends StatelessWidget {
  final ExplorerState state;
  final String repositoryPath;
  final VoidCallback? onBack;

  const _CommitDetail({
    required this.state,
    required this.repositoryPath,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loaded = state.commit;

    if (loaded == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final commit = loaded.commit;
    final changes = loaded.changes;
    final selectedPath = state.commitFilePath;
    final diff = state.commitFileDiff;

    return Column(
      children: [
        _Header(
          title: commit.summary,
          subtitle: '${commit.shortId} · ${commit.authorName} · '
              '${_when(commit.when)}',
          onBack: onBack ?? () => state.backFromCommit(repositoryPath),
        ),
        if (commit.message.trim() != commit.summary.trim())
          Padding(
            padding: const EdgeInsets.all(16),
            child:
                Text(commit.message.trim(), style: theme.textTheme.bodyMedium),
          ),
        _Heading(label: 'Changed files', count: changes.length),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: 280,
                child: ListView.builder(
                  itemCount: changes.length,
                  itemBuilder: (context, index) {
                    final change = changes[index];
                    final color = statusColor(change.state, context);
                    return ListTile(
                      dense: true,
                      selected: change.path == selectedPath,
                      leading: SizedBox(
                        width: 20,
                        child: Text(
                          change.state.code,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelLarge
                              ?.copyWith(color: color),
                        ),
                      ),
                      title: Text(change.path, overflow: TextOverflow.ellipsis),
                      onTap: () => state.selectCommitFile(change.path),
                    );
                  },
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: selectedPath == null
                    ? Center(
                        child: Text(
                          'Select a file to see what changed',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : diff == null
                        ? const Center(child: CircularProgressIndicator())
                        : _DiffView(diff: diff),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
