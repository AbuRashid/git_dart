import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../generated/tokens.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';

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
          ],
        ),
        // The changes and the history scroll; the commit box does not
        // (`committing.the-commit-box-is-pinned`).
        Expanded(
          child: ListView(
            children: [
              _Facts(summary: summary),
              const Divider(height: 1),
              _StagingLists(state: state, repositoryPath: repositoryPath),
              const Divider(height: 1),
              _Heading(label: 'History', count: history?.length),
              if (history == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                for (final commit in history)
                  _CommitRow(
                    commit: commit,
                    onTap: () => state.selectCommit(repositoryPath, commit.id),
                  ),
            ],
          ),
        ),
        _CommitBox(state: state, repositoryPath: repositoryPath),
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
          Chip(label: Text('${summary.branches.length} branches')),
          Chip(label: Text('${summary.tags.length} tags')),
        ],
      ),
    );
  }
}

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

  const _StagingRow({
    required this.row,
    required this.staged,
    required this.onToggle,
    required this.onOpen,
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
      trailing: IconButton(
        tooltip: staged ? 'Unstage' : 'Stage',
        onPressed: onToggle,
        icon: Icon(staged ? Icons.remove : Icons.add),
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

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
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
    final canCommit = staged.isNotEmpty &&
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
              Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    color: statusColor(FileState.added, context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Committed ${committed.shortId} — ${committed.summary}',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: state.dismissLastCommit,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
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
                        : 'Commit ${staged.length} '
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

  const _CommitRow({required this.commit, required this.onTap});

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
      onTap: onTap,
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

class _FileDetailState extends State<_FileDetail> {
  /// A changed file opens on the file, not on its diff: the file is the thing
  /// that can be acted on (`editing.a-changed-file-opens-on-the-file`).
  bool _showDiff = false;

  final _editor = TextEditingController();
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
            if (diff != null)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('File')),
                  ButtonSegment(value: true, label: Text('Diff')),
                ],
                selected: {_showDiff},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    setState(() => _showDiff = selection.first),
              ),
            const SizedBox(width: 8),
          ],
        ),
        if (content == null)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (diff != null && _showDiff && !dirty)
          Expanded(child: _DiffView(diff: diff))
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
          Expanded(child: _TextView(text: content.text ?? '')),
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
/// A plain text field rather than a code editor: this is for fixing a typo and
/// adding a line, and pretending otherwise would promise highlighting, folding
/// and completion that are not here.
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

class _TextView extends StatelessWidget {
  final String text;
  const _TextView({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = text.split('\n');
    final mono = monospaceStyle(context);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: lines.length,
      itemBuilder: (context, index) => Row(
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
          Expanded(child: Text(lines[index], style: mono)),
        ],
      ),
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

    final rows = <Widget>[];
    for (final hunk in diff.hunks) {
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
              Expanded(
                child: Text(line.text, style: mono.copyWith(color: color)),
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
          onBack: onBack ?? () => state.selectRepository(repositoryPath),
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
