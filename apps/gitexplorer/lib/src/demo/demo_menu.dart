/// The demo's own actions, in the window's bar: taking the code home, and
/// starting over.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:git_dart/git_dart.dart' as git;

import '../state.dart';
import '../workspace.dart';
import 'demo_platform.dart';

class DemoMenu extends StatelessWidget {
  final ExplorerState state;

  /// The repository the demo seeded, by the name it was given.
  final String repositoryName;

  /// The bundle published beside the app, which seeded it.
  final String bundleName;

  /// Why the demo repository is not there, when seeding it failed.
  final String? problem;

  const DemoMenu({
    super.key,
    required this.state,
    required this.repositoryName,
    required this.bundleName,
    this.problem,
  });

  /// Below this width the bar has no room for a labelled button.
  static const double _labelBreakpoint = 600;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < _labelBreakpoint;
    final seeded = knownWorkspaceRepositories()
        .any((known) => known.path == workspacePathFor(repositoryName));

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (problem != null)
          IconButton(
            icon: const Icon(Icons.error_outline),
            tooltip: 'The demo repository did not load',
            onPressed: () => _showProblem(context),
          ),
        if (narrow)
          IconButton(
            icon: const Icon(Icons.code),
            tooltip: 'Get the code',
            onPressed: () => _getTheCode(context),
          )
        else
          TextButton.icon(
            icon: const Icon(Icons.code),
            label: const Text('Get the code'),
            onPressed: () => _getTheCode(context),
          ),
        PopupMenuButton<void Function()>(
          tooltip: 'Demo',
          onSelected: (action) => action(),
          itemBuilder: (context) => [
            PopupMenuItem(
              enabled: seeded,
              value: () => _downloadMyCopy(context),
              child: const ListTile(
                leading: Icon(Icons.download_outlined),
                title: Text('Download my copy'),
                subtitle: Text('This browser\'s repository, your commits included'),
              ),
            ),
            PopupMenuItem(
              value: () => _reset(context),
              child: const ListTile(
                leading: Icon(Icons.restart_alt),
                title: Text('Reset the demo'),
                subtitle: Text('Start again from the published repository'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _getTheCode(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) {
          final theme = Theme.of(context);
          return AlertDialog(
            title: const Text('Get the code'),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'The repository you are browsing is the real one — every '
                    'commit, branch and tag. Download it as a git bundle and '
                    'clone it with plain git:',
                  ),
                  const SizedBox(height: 16),
                  _Command('git clone $bundleName $repositoryName'),
                  const SizedBox(height: 16),
                  Text(
                    'Committed something here you want to keep? Download my '
                    'copy, in the demo menu, bundles this browser\'s repository '
                    'instead. Changes that are not committed stay behind.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.download_outlined),
                label: Text('Download $bundleName'),
                onPressed: () =>
                    downloadDemoUrl(demoAssetUrl(bundleName), bundleName),
              ),
            ],
          );
        },
      );

  void _downloadMyCopy(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repository = git.Repository.open(workspacePathFor(repositoryName));
      final Uint8List bytes;
      try {
        bytes = git.writeBundle(repository, includeHead: true);
      } finally {
        repository.close();
      }
      downloadDemoBytes(bytes, '$repositoryName-my-copy.bundle');
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('This copy could not be bundled: $error')),
      );
    }
  }

  Future<void> _reset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset the demo?'),
        content: const Text(
          'Everything in this browser goes: commits, edits, and any repository '
          'you cloned or created. The demo repository is then loaded fresh.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;

    // Removed through the state, so the saved list forgets them along with
    // their stored copies, and then a fresh page: an empty workspace is what
    // makes the next start seed again.
    for (final known in knownWorkspaceRepositories()) {
      await state.removeRepository(known.path);
    }
    reloadDemoPage();
  }

  Future<void> _showProblem(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('The demo repository did not load'),
          content: SelectableText(problem!),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
}

/// A shell command, to read or copy.
class _Command extends StatelessWidget {
  final String command;

  const _Command(this.command);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontFamily: 'monospace'),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copy',
            onPressed: () => Clipboard.setData(ClipboardData(text: command)),
          ),
        ],
      ),
    );
  }
}
