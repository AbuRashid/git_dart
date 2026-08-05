import 'package:flutter/material.dart';
import 'package:git_dart/git_dart.dart' show ConfigScope;

import '../models.dart';
import '../settings_catalogue.dart';
import '../state.dart';

/// Git's settings, grouped, with the categories down the side.
///
/// Two things this screen insists on, because a settings screen that gets
/// them wrong is worse than none. It never shows a default as though it were
/// set — an unset value says what git will do instead, in words. And it always
/// says which file a value came from, because "I changed that and nothing
/// happened" is almost always a wider scope being overridden by a narrower
/// one, or the other way about.
class SettingsPage extends StatefulWidget {
  final ExplorerState state;

  /// Whose config to edit. Local settings need a repository; without one only
  /// the global file can be reached.
  final String repositoryPath;
  final String repositoryName;

  const SettingsPage({
    super.key,
    required this.state,
    required this.repositoryPath,
    required this.repositoryName,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _category = 0;

  @override
  void initState() {
    super.initState();
    // Everything at once: the screen is small enough that reading it per tab
    // would only add flicker.
    widget.state.loadSettings(
      widget.repositoryPath,
      [
        for (final category in settingCategories)
          for (final setting in category.settings) setting.key,
      ],
    );
  }

  static IconData _iconFor(String name) => switch (name) {
        'person' => Icons.person_outline,
        'commit' => Icons.commit,
        'branch' => Icons.call_split,
        'merge' => Icons.merge,
        'files' => Icons.description_outlined,
        'diff' => Icons.difference_outlined,
        'network' => Icons.cloud_outlined,
        _ => Icons.settings_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(20),
            child: Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Editing git config for ${widget.repositoryName}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ),
        ),
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _category,
              onDestinationSelected: (index) =>
                  setState(() => _category = index),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final category in settingCategories)
                  NavigationRailDestination(
                    icon: Icon(_iconFor(category.icon)),
                    label: Text(category.name),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                children: [
                  Text(
                    settingCategories[_category].name,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  for (final setting in settingCategories[_category].settings)
                    _SettingTile(
                      state: widget.state,
                      repositoryPath: widget.repositoryPath,
                      setting: setting,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final ExplorerState state;
  final String repositoryPath;
  final Setting setting;

  const _SettingTile({
    required this.state,
    required this.repositoryPath,
    required this.setting,
  });

  Future<void> _write(String? value, ConfigScope scope) =>
      state.writeSetting(repositoryPath, setting.key, value, scope.index);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = state.settingFor(setting.key);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(setting.label, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        setting.key,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (current?.isSet ?? false)
                  Chip(
                    label: Text(current!.scopeLabel ?? ''),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(setting.description, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            _control(context, current),
            // An unset value says what git will do, rather than showing a
            // default as though someone had chosen it.
            if (!(current?.isSet ?? false) && setting.whenUnset != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Not set — git uses ${setting.whenUnset}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _control(BuildContext context, SettingValue? current) {
    switch (setting.kind) {
      case SettingKind.flag:
        final on = current?.value?.toLowerCase();
        return Row(
          children: [
            Switch(
              value: on == 'true' || on == 'yes' || on == 'on' || on == '1',
              onChanged: (value) =>
                  _write(value ? 'true' : 'false', ConfigScope.local),
            ),
            const SizedBox(width: 12),
            if (current?.isSet ?? false)
              TextButton(
                onPressed: () => _write(null, ConfigScope.local),
                child: const Text('Clear'),
              ),
            const Spacer(),
            _ScopeButton(onSelected: (scope) => _write(
                  (on == 'true') ? 'false' : 'true',
                  scope,
                )),
          ],
        );

      case SettingKind.choice:
        return Row(
          children: [
            DropdownButton<String>(
              value: setting.choices.contains(current?.value)
                  ? current!.value
                  : null,
              hint: const Text('Not set'),
              items: [
                for (final choice in setting.choices)
                  DropdownMenuItem(value: choice, child: Text(choice)),
              ],
              onChanged: (value) => _write(value, ConfigScope.local),
            ),
            const SizedBox(width: 12),
            if (current?.isSet ?? false)
              TextButton(
                onPressed: () => _write(null, ConfigScope.local),
                child: const Text('Clear'),
              ),
          ],
        );

      case SettingKind.text:
      case SettingKind.path:
      case SettingKind.number:
        return _TextSetting(
          key: ValueKey('${setting.key}:${current?.value}'),
          setting: setting,
          current: current,
          onWrite: _write,
        );
    }
  }
}

class _TextSetting extends StatefulWidget {
  final Setting setting;
  final SettingValue? current;
  final Future<void> Function(String?, ConfigScope) onWrite;

  const _TextSetting({
    super.key,
    required this.setting,
    required this.current,
    required this.onWrite,
  });

  @override
  State<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<_TextSetting> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.current?.value ?? '');
  var _dirty = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            onChanged: (_) => setState(() => _dirty = true),
            keyboardType: widget.setting.kind == SettingKind.number
                ? TextInputType.number
                : TextInputType.text,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: widget.setting.placeholder.isEmpty
                  ? 'Not set'
                  : widget.setting.placeholder,
            ),
            onSubmitted: (value) {
              widget.onWrite(value.trim(), ConfigScope.local);
              setState(() => _dirty = false);
            },
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: _dirty
              ? () {
                  widget.onWrite(_controller.text.trim(), ConfigScope.local);
                  setState(() => _dirty = false);
                }
              : null,
          child: const Text('Save'),
        ),
        const SizedBox(width: 8),
        _ScopeButton(
          onSelected: (scope) {
            widget.onWrite(_controller.text.trim(), scope);
            setState(() => _dirty = false);
          },
        ),
        if (widget.current?.isSet ?? false)
          TextButton(
            onPressed: () {
              widget.onWrite(null, ConfigScope.local);
              _controller.clear();
              setState(() => _dirty = false);
            },
            child: const Text('Clear'),
          ),
      ],
    );
  }
}

/// Writes to a scope other than this repository.
///
/// Local is the default because it is the one that cannot surprise anyone
/// else; global is a deliberate choice, made here rather than assumed.
class _ScopeButton extends StatelessWidget {
  final void Function(ConfigScope) onSelected;

  const _ScopeButton({required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ConfigScope>(
      tooltip: 'Save somewhere else',
      icon: const Icon(Icons.more_vert),
      onSelected: onSelected,
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: ConfigScope.local,
          child: Text('Save for this repository'),
        ),
        PopupMenuItem(
          value: ConfigScope.global,
          child: Text('Save for all my repositories'),
        ),
      ],
    );
  }
}
