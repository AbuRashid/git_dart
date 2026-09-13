import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../generated/tokens.dart';
import '../models.dart';
import '../state.dart';
import '../workspace.dart';
import '../storage_access.dart';
import '../theme.dart';
import 'clone_dialog.dart';

/// The virtual root and everything opened under it.
///
/// The top level is a list the user assembles, not a directory: repositories
/// live wherever they were cloned, and a tree rooted at a real folder can only
/// show the accident of where they landed (`virtual-root.why`).
class TreePane extends StatelessWidget {
  final ExplorerState state;
  final void Function()? onNavigate;

  const TreePane({super.key, required this.state, this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final rows = state.rows;

    final theme = Theme.of(context);

    return Column(
      children: [
        // The header of the list, with the one action that changes it.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Text(
                'Repositories',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              MenuAnchor(
                menuChildren: [
                  // Only where a repository can be a folder. In a browser
                  // there is nothing to point at: the app's storage is its
                  // own, so a repository gets there by being cloned.
                  if (!repositoriesAreInternal)
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.folder_open),
                      onPressed: () => addRepository(context, state),
                      child: const Text('Add a folder I have'),
                    ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.cloud_download_outlined),
                    onPressed: () => cloneRepository(context, state),
                    child: const Text('Clone from a URL'),
                  ),
                  // The web-native counterpart to picking an empty folder and
                  // initialising it: nowhere to point at, so a name is asked
                  // instead.
                  if (repositoriesAreInternal)
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.add),
                      onPressed: () => createRepository(context, state),
                      child: const Text('Create a new repository'),
                    ),
                  // Only where the browser can actually show the picker -
                  // Chromium, as of when this was written.
                  if (canImportRepository)
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.drive_folder_upload_outlined),
                      onPressed: () => importRepository(context, state),
                      child: const Text('Upload a repository'),
                    ),
                ],
                builder: (context, controller, _) => IconButton.filledTonal(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add a repository',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      controller.isOpen ? controller.close() : controller.open(),
                ),
              ),
            ],
          ),
        ),
        // A clone is the one thing here that takes long enough to need saying
        // so, and it has no row of its own to say it in yet.
        if (state.cloning case final url?)
          _Cloning(url: url, progress: state.cloneProgress)
        else
          const Divider(height: 1),
        Expanded(
          child: rows.isEmpty
              ? _EmptyRoot(state: state)
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) => _Row(
                    state: state,
                    row: rows[index],
                    onNavigate: onNavigate,
                  ),
                ),
        ),
        if (state.error case final message?)
          MaterialBanner(
            content: Text(message),
            leading: const Icon(Icons.error_outline),
            actions: [
              IconButton(
                icon: const Icon(Icons.copy_outlined),
                tooltip: 'Copy',
                onPressed: () => copyToClipboard(message),
              ),
              TextButton(
                onPressed: state.dismissError,
                child: const Text('Dismiss'),
              ),
            ],
          ),
      ],
    );
  }
}

/// Light, dark, or whatever the platform says.
class ThemeButton extends StatelessWidget {
  final ExplorerState state;

  const ThemeButton({super.key, required this.state});

  static IconData iconFor(ThemeChoice choice) => switch (choice) {
        ThemeChoice.system => Icons.brightness_auto_outlined,
        ThemeChoice.light => Icons.light_mode_outlined,
        ThemeChoice.dark => Icons.dark_mode_outlined,
      };

  static String labelFor(ThemeChoice choice) => switch (choice) {
        ThemeChoice.system => 'System',
        ThemeChoice.light => 'Light',
        ThemeChoice.dark => 'Dark',
      };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ThemeChoice>(
      icon: Icon(iconFor(state.theme)),
      tooltip: 'Theme',
      onSelected: state.setTheme,
      itemBuilder: (context) => [
        for (final choice in ThemeChoice.values)
          CheckedPopupMenuItem(
            value: choice,
            checked: choice == state.theme,
            child: Text(labelFor(choice)),
          ),
      ],
    );
  }
}

/// Picks a folder and adds it.
///
/// A folder with no repository in it is offered the one action that changes
/// that, rather than being added as a row that can only report a failure
/// (`initialising.why`).
Future<void> addRepository(BuildContext context, ExplorerState state) async {
  if (!await ensureStorageAccess(context)) return;

  final picked = await FilePicker.getDirectoryPath(
    dialogTitle: 'Choose a repository',
  );
  if (picked == null) return;

  final looked = await state.inspect(picked);
  if (looked.available) {
    await state.addRepository(picked);
    return;
  }
  if (!context.mounted) return;

  if (!looked.canInitialise) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Cannot open ${looked.name}'),
        content: Text(
          looked.error == null
              ? looked.reason!.says
              : '${looked.reason!.says}\n\n${looked.error}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    return;
  }

  final create = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Not a repository yet'),
      content: Text(
        '${looked.name} holds no repository.\n\n'
        'Create an empty one here? Nothing is committed and nothing existing '
        'is touched — it is what git init does.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Create repository'),
        ),
      ],
    ),
  );

  if (create ?? false) await state.initialiseRepository(picked);
}

/// Makes sure the app may read and write the folder picked next.
///
/// Asked before the picker rather than after, because the failure it prevents is
/// a silent one: without access the folder still opens and `.git` is still
/// written, and only the files — the whole point — are missing. Explaining that
/// afterwards means explaining an empty list.
Future<bool> ensureStorageAccess(BuildContext context) async {
  if (await hasStorageAccess()) return true;
  if (!context.mounted) return false;

  final ask = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Needs access to your files'),
      content: const Text(
        'A repository is a folder of files other apps made, and Android hides '
        'those from this app until you allow it.\n\n'
        'Without it a folder still opens, but it looks empty.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Allow access'),
        ),
      ],
    ),
  );
  if (!(ask ?? false)) return false;

  if (await requestStorageAccess()) return true;
  if (!context.mounted) return false;

  // Refused, or granted-then-revoked on the way back. Say so once and stop,
  // rather than reopening settings at someone who has just declined.
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Access not granted'),
      content: const Text(
        'Folders can still be opened, but their files will not be listed. '
        'Adding a repository is available again once access is allowed.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
  return false;
}

class _EmptyRoot extends StatelessWidget {
  final ExplorerState state;
  const _EmptyRoot({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('No repositories yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              repositoriesAreInternal
                  ? 'Repositories are kept in this browser, so they start by '
                      'being cloned.'
                  : 'Repositories are wherever they were cloned, so you '
                      'choose which ones to show here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            if (repositoriesAreInternal) ...[
              FilledButton.icon(
                onPressed: () => cloneRepository(context, state),
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Clone from a URL'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => createRepository(context, state),
                icon: const Icon(Icons.add),
                label: const Text('Create a new repository'),
              ),
              if (canImportRepository) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => importRepository(context, state),
                  icon: const Icon(Icons.drive_folder_upload_outlined),
                  label: const Text('Upload a repository'),
                ),
              ],
            ] else ...[
              FilledButton.icon(
                onPressed: () => addRepository(context, state),
                icon: const Icon(Icons.add),
                label: const Text('Add a repository'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => cloneRepository(context, state),
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Clone from a URL'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The strip that says a clone is happening, in the divider's place.
class _Cloning extends StatelessWidget {
  final String url;

  /// The latest phase reported for it — a step git_dart names locally
  /// ("negotiating", "indexing"), or the server's own text relayed over the
  /// sideband ("Receiving objects: 43% (215/500)"). Null before the first one
  /// arrives.
  final String? progress;

  const _Cloning({required this.url, this.progress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Cloning $url', overflow: TextOverflow.ellipsis, style: label),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            // Determinate whenever the server hands over a percentage, and
            // indeterminate the rest of the time - a phase with no known
            // total, such as indexing, genuinely has no fraction to show.
            child: LinearProgressIndicator(minHeight: 3, value: _percentIn(progress)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            progress ?? 'contacting…',
            overflow: TextOverflow.ellipsis,
            style: label,
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// Pulls a fraction out of a progress line like `Receiving objects: 43%
/// (215/500)`.
double? _percentIn(String? text) {
  if (text == null) return null;
  final match = RegExp(r'(\d{1,3})%').firstMatch(text);
  if (match == null) return null;
  return int.parse(match.group(1)!).clamp(0, 100) / 100;
}

class _Row extends StatelessWidget {
  final ExplorerState state;
  final TreeRow row;
  final void Function()? onNavigate;

  const _Row({required this.state, required this.row, this.onNavigate});

  @override
  Widget build(BuildContext context) {
    return row.isRepository
        ? _RepositoryRow(state: state, row: row, onNavigate: onNavigate)
        : _EntryRow(state: state, row: row, onNavigate: onNavigate);
  }
}

class _RepositoryRow extends StatelessWidget {
  final ExplorerState state;
  final TreeRow row;
  final void Function()? onNavigate;

  const _RepositoryRow({
    required this.state,
    required this.row,
    this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = row.repository!;
    final expanded = state.isExpanded(row.repositoryPath, '');
    final selected = state.selection is RepositorySelected &&
        (state.selection as RepositorySelected).repositoryPath ==
            row.repositoryPath;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _Contextual(
        onMenu: (position) => _repositoryMenu(context, state, summary, position),
        child: ListTile(
        dense: true,
        selected: selected,
        contentPadding: const EdgeInsets.only(left: 8, right: 8),
        leading: summary.available
            ? IconButton(
                icon: Icon(expanded ? Icons.expand_more : Icons.chevron_right),
                onPressed: () => state.toggle(row.repositoryPath, ''),
                tooltip: expanded ? 'Collapse' : 'Expand',
              )
            : Icon(
                // A folder that could become a repository is not a failure, so
                // it does not wear a failure's icon.
                summary.canInitialise
                    ? Icons.folder_outlined
                    : Icons.error_outline,
                color: summary.canInitialise ? null : theme.colorScheme.error,
              ),
        title: Text(
          summary.name,
          overflow: TextOverflow.ellipsis,
          style:
              theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          summary.available
              ? (summary.detached
                  ? 'detached at ${summary.headId?.substring(0, 8) ?? ''}'
                  : summary.branch ?? 'no branch')
              : (summary.canInitialise ? 'not a repository' : 'unavailable'),
          overflow: TextOverflow.ellipsis,
        ),
        trailing: summary.available && !summary.isClean
            ? _ChangeCounts(summary: summary)
            : null,
          onTap: () {
            state.selectRepository(row.repositoryPath);
            onNavigate?.call();
          },
        ),
      ),
    );
  }
}

class _ChangeCounts extends StatelessWidget {
  final RepositorySummary summary;
  const _ChangeCounts({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (summary.changedCount > 0)
          Badge(
            label: Text('${summary.changedCount}'),
            backgroundColor: statusColor(FileState.modified, context),
          ),
        if (summary.untrackedCount > 0) ...[
          const SizedBox(width: 6),
          Badge(
            label: Text('${summary.untrackedCount}'),
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            textColor: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ],
    );
  }
}

class _EntryRow extends StatelessWidget {
  final ExplorerState state;
  final TreeRow row;
  final void Function()? onNavigate;

  const _EntryRow({required this.state, required this.row, this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = row.entry!;
    final expandable = entry.kind.expands;
    final expanded = state.isExpanded(row.repositoryPath, entry.path);
    final selected = switch (state.selection) {
      FileSelected(:final repositoryPath, :final path) =>
        repositoryPath == row.repositoryPath && path == entry.path,
      SubmoduleSelected(:final repositoryPath, :final path) =>
        repositoryPath == row.repositoryPath && path == entry.path,
      _ => false,
    };
    final unsaved = state.hasDraft(row.repositoryPath, entry.path);
    final color = statusColor(entry.state, context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _Contextual(
        onMenu: state.revisionFor(row.repositoryPath).kind.editable
          ? (position) => entry.kind == EntryKind.directory
              ? _directoryMenu(
                  context, state, row.repositoryPath, entry.path, position)
              : _fileMenu(context, state, row.repositoryPath, entry, position)
          : null,
      child: ListTile(
        dense: true,
        selected: selected,
        contentPadding: EdgeInsets.only(left: 8 + 16.0 * row.depth, right: 8),
        // A folder shows a chevron for the same reason a repository does: it
        // is what says "this opens". Files are inset by the chevron's width so
        // their icons line up under the folders'.
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (expandable)
              Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 20)
            else
              const SizedBox(width: 20),
            const SizedBox(width: 4),
            Icon(
              switch (entry.kind) {
                EntryKind.directory =>
                  expanded ? Icons.folder_open : Icons.folder_outlined,
                EntryKind.submodule => Icons.dataset_linked_outlined,
                _ => Icons.insert_drive_file_outlined,
              },
            ),
          ],
        ),
        // An ignored entry is still on disk and still worth showing, but it is
        // not part of the repository's business, so it is dimmed rather than
        // marked.
        enabled: true,
        textColor: entry.state == FileState.ignored
            ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)
            : null,
        iconColor: entry.state == FileState.ignored
            ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
            : null,
        title: Text(entry.name, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (unsaved)
              Tooltip(
                message: 'unsaved changes',
                child: Icon(
                  Icons.circle,
                  size: 8,
                  color: theme.colorScheme.primary,
                ),
              ),
            if (entry.state.shown && color != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Tooltip(
                  message: entry.state.name,
                  child: Text(
                    entry.state.code,
                    style: theme.textTheme.labelLarge?.copyWith(color: color),
                  ),
                ),
              ),
          ],
        ),
        onTap: () {
          if (expandable) {
            state.toggle(row.repositoryPath, entry.path);
          } else if (entry.kind == EntryKind.submodule) {
            state.selectSubmodule(row.repositoryPath, entry.path);
            onNavigate?.call();
          } else {
            state.selectFile(row.repositoryPath, entry.path);
            onNavigate?.call();
          }
        },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// menus
// ---------------------------------------------------------------------------

/// Opens a row's context menu on right-click, and on long-press for touch.
///
/// A right-click is how a context menu is opened on a desktop; long-press
/// alone leaves a mouse with no way to reach it, which is how these menus went
/// missing once already.
class _Contextual extends StatelessWidget {
  final Widget child;
  final Future<void> Function(Offset position)? onMenu;

  const _Contextual({required this.child, this.onMenu});

  @override
  Widget build(BuildContext context) {
    if (onMenu == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (details) => onMenu!(details.globalPosition),
      onLongPressStart: (details) => onMenu!(details.globalPosition),
      child: child,
    );
  }
}

/// Shows a standard menu where the pointer is.
Future<T?> _menuAt<T>(
  BuildContext context,
  Offset position,
  List<PopupMenuEntry<T>> items,
) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      position & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}

PopupMenuItem<T> _item<T>(T value, IconData icon, String label) =>
    PopupMenuItem<T>(
      value: value,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );

Future<void> _repositoryMenu(
  BuildContext context,
  ExplorerState state,
  RepositorySummary summary,
  Offset position,
) async {
  final editable =
      summary.available && state.revisionFor(summary.path).kind.editable;
  final choice = await _menuAt<String>(context, position, [
    if (editable) ...[
      _item('new-file', Icons.note_add_outlined, 'New file…'),
      _item('new-folder', Icons.create_new_folder_outlined, 'New folder…'),
      const PopupMenuDivider(),
    ],
    _item('refresh', Icons.refresh, 'Re-read from disk'),
    _item('rename', Icons.drive_file_rename_outline, 'Rename…'),
    _item('remove', Icons.remove_circle_outline, 'Remove from the tree'),
  ]);
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'new-file':
      await createEntry(context, state, summary.path, '', EntryKind.file);
    case 'new-folder':
      await createEntry(context, state, summary.path, '', EntryKind.directory);
    case 'refresh':
      await state.refresh(summary.path);
    case 'remove':
      await state.removeRepository(summary.path);
    case 'rename':
      final name = await _askForName(context, summary.name);
      if (name != null) await state.renameRepository(summary.path, name);
  }
}

Future<void> _fileMenu(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  EntryData entry,
  Offset position,
) async {
  final choice = await _menuAt<String>(context, position, [
    _item('stage', Icons.add, 'Stage'),
    _item('unstage', Icons.remove, 'Unstage'),
    const PopupMenuDivider(),
    _item('ignore', Icons.visibility_off_outlined, 'Ignore…'),
  ]);
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'stage':
      await state.setStaged(repositoryPath, entry.path, staged: true);
    case 'unstage':
      await state.setStaged(repositoryPath, entry.path, staged: false);
    case 'ignore':
      await ignoreEntry(context, state, repositoryPath, entry);
  }
}

/// Adds [entry] to the repository's `.gitignore`.
///
/// A path git is already tracking goes on being tracked whatever `.gitignore`
/// says, so the dialog says so and offers to drop it from the index as well —
/// the file stays on disk either way.
Future<void> ignoreEntry(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  EntryData entry,
) async {
  final isDirectory = entry.kind == EntryKind.directory;
  final tracked = await state.trackedCount(repositoryPath, entry.path);
  if (!context.mounted) return;

  var untrack = false;

  if (tracked > 0) {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Ignore this?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tracked == 1
                    ? 'Git is already tracking ${entry.path}.'
                    : 'Git is already tracking $tracked files under '
                        '${entry.path}.',
              ),
              const SizedBox(height: 12),
              const Text(
                'An ignore rule does not apply to something already tracked, '
                'so on its own this will change nothing.',
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: untrack,
                onChanged: (value) => setState(() => untrack = value ?? false),
                title: const Text('Also stop tracking it'),
                subtitle: const Text(
                  'Removes it from the index; the file stays on disk. The '
                  'next commit will record the removal.',
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
              child: const Text('Ignore'),
            ),
          ],
        ),
      ),
    );
    if (proceed != true) return;
  }

  final pattern = await state.ignorePath(
    repositoryPath,
    entry.path,
    isDirectory: isDirectory,
    alsoUntrack: untrack,
  );
  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        pattern == null
            ? '${entry.path} was already ignored'
            : 'Added $pattern to .gitignore',
      ),
    ),
  );
}

Future<void> _directoryMenu(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  String directory,
  Offset position,
) async {
  final choice = await _menuAt<String>(context, position, [
    _item('new-file', Icons.note_add_outlined, 'New file…'),
    _item('new-folder', Icons.create_new_folder_outlined, 'New folder…'),
    const PopupMenuDivider(),
    _item('stage', Icons.add, 'Stage everything here'),
    _item('ignore', Icons.visibility_off_outlined, 'Ignore…'),
  ]);
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'stage':
      await state.setStaged(repositoryPath, directory, staged: true);
    case 'ignore':
      await ignoreEntry(
        context,
        state,
        repositoryPath,
        EntryData(
          name: directory.split('/').last,
          path: directory,
          kind: EntryKind.directory,
        ),
      );
    case 'new-file':
      await createEntry(
          context, state, repositoryPath, directory, EntryKind.file);
    case 'new-folder':
      await createEntry(
          context, state, repositoryPath, directory, EntryKind.directory);
  }
}

/// Asks for a name and creates an empty file or folder under [directory].
///
/// The name may contain slashes: a folder is created in full, so `a/b/c` is
/// one action rather than three.
Future<void> createEntry(
  BuildContext context,
  ExplorerState state,
  String repositoryPath,
  String directory,
  EntryKind kind,
) async {
  final isFolder = kind == EntryKind.directory;
  final controller = TextEditingController();

  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(isFolder ? 'New folder' : 'New file'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Name',
          hintText: isFolder ? 'lib/src' : 'notes.md',
          helperText: isFolder
              ? 'Git does not record an empty folder until it holds a file'
              : 'In ${directory.isEmpty ? 'the repository root' : directory}',
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
          child: const Text('Create'),
        ),
      ],
    ),
  );

  if (name == null || name.trim().isEmpty) return;
  final path = directory.isEmpty ? name.trim() : '$directory/${name.trim()}';
  await state.createEntry(repositoryPath, path, kind);
}

Future<String?> _askForName(BuildContext context, String current) {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Name',
          helperText: 'The name in the tree; nothing on disk changes',
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
}
