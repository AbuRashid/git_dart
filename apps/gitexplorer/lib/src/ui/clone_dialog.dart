import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import '../state.dart';
import 'detail_pane.dart' show askForCredentials;
import 'tree_pane.dart' show ensureStorageAccess;

/// The folder a URL suggests, which is what git would have named it.
///
/// Offered rather than imposed: the name is a field the user can change, since
/// a repository's own name is not always what they want the folder called.
String suggestedFolderName(String url) {
  var text = url.trim();
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  // Separators, not a path parse: a URL may be scp-style (host:path) or a
  // Windows path, and the name is whatever follows the last of them.
  final lastSeparator = [
    text.lastIndexOf('/'),
    text.lastIndexOf(':'),
    text.lastIndexOf('\\'),
  ].reduce((a, b) => a > b ? a : b);
  var name = lastSeparator >= 0 ? text.substring(lastSeparator + 1) : text;
  if (name.endsWith('.git')) name = name.substring(0, name.length - 4);
  return name;
}

/// Asks where to clone from and to, then does it.
///
/// Credentials are asked for the way a fetch asks: the clone reports that the
/// server wants them, and is run again with what the user gave
/// (`cloning.credentials`).
Future<void> cloneRepository(BuildContext context, ExplorerState state) async {
  // A clone writes into a folder the user picks, which on Android is behind the
  // same permission as reading one.
  if (!await ensureStorageAccess(context)) return;
  if (!context.mounted) return;

  final asked = await showDialog<({String url, String path})>(
    context: context,
    builder: (context) => const _CloneDialog(),
  );
  if (asked == null) return;

  var outcome = await state.cloneRepository(asked.url, asked.path);
  if (outcome != null && outcome.needsCredentials) {
    if (!context.mounted) return;
    final signIn = await askForCredentials(
      context,
      remote: asked.url,
      username: outcome.username,
      wereRejected: outcome.wereRejected,
      canSave: outcome.canSave,
    );
    if (signIn == null) return;

    outcome = await state.cloneRepository(
      asked.url,
      asked.path,
      username: signIn.username,
      password: signIn.password,
      remember: signIn.remember,
    );
  }

  if (!context.mounted || outcome == null) return;
  if (outcome.succeeded) {
    _report(context, outcome);
  }
}

/// Says what arrived, since a clone that worked otherwise looks like a row
/// appearing on its own.
void _report(BuildContext context, CloneOutcome outcome) {
  final name = p.basename(p.normalize(outcome.path!));
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        outcome.remoteWasEmpty
            ? 'Cloned $name — the remote is empty, so there is nothing in it yet'
            : 'Cloned $name'
                '${outcome.branch == null ? '' : ' on ${outcome.branch}'}',
      ),
    ),
  );
}

class _CloneDialog extends StatefulWidget {
  const _CloneDialog();

  @override
  State<_CloneDialog> createState() => _CloneDialogState();
}

class _CloneDialogState extends State<_CloneDialog> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  String? _parent;

  /// True once the name has been typed in, after which the URL stops
  /// suggesting one — a suggestion that overwrote what was typed would be a
  /// field that fights back.
  var _nameWasEdited = false;

  @override
  void initState() {
    super.initState();
    _url.addListener(_suggestName);
  }

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  void _suggestName() {
    if (_nameWasEdited) return;
    final suggestion = suggestedFolderName(_url.text);
    if (suggestion != _name.text) {
      _name.value = TextEditingValue(
        text: suggestion,
        selection: TextSelection.collapsed(offset: suggestion.length),
      );
      setState(() {});
    }
  }

  String? get _destination => _parent == null || _name.text.trim().isEmpty
      ? null
      : p.join(_parent!, _name.text.trim());

  Future<void> _chooseParent() async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: 'Where to put it',
    );
    if (picked != null) setState(() => _parent = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final destination = _destination;

    return AlertDialog(
      title: const Text('Clone a repository'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Repository URL',
                hintText: 'https://host/owner/name.git',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    onChanged: (_) => setState(() => _nameWasEdited = true),
                    decoration: const InputDecoration(labelText: 'Folder name'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _chooseParent,
                  icon: const Icon(Icons.folder_open),
                  label: Text(_parent == null ? 'Choose folder' : 'Change'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // The whole path, because "where did it go" is the question a
            // clone leaves behind.
            Text(
              destination ?? 'Choose where to put it',
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
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _url.text.trim().isEmpty || destination == null
              ? null
              : () => Navigator.pop(
                    context,
                    (url: _url.text.trim(), path: destination),
                  ),
          child: const Text('Clone'),
        ),
      ],
    );
  }
}
