/// The git settings the window offers, grouped.
///
/// A curated list rather than everything git accepts: `git config` has
/// hundreds of keys, most of which nobody sets by hand, and a screen listing
/// all of them would be a worse reference than the manual. These are the ones
/// people actually change, with the type each expects so the control can be
/// the right one — a switch for a flag, a list for a fixed set of words, a
/// field for the rest.
///
/// Anything not here is still reachable: the last category shows every key the
/// files already set, whatever it is.
library;

enum SettingKind { text, flag, choice, number, path }

class Setting {
  /// The config key, as `git config` spells it.
  final String key;

  final String label;
  final String description;
  final SettingKind kind;

  /// For [SettingKind.choice], the values git accepts.
  final List<String> choices;

  /// What git does when nothing sets it, said in words rather than pretended
  /// to be a value — a screen that shows a default as though it were set
  /// invites the reader to think it was.
  final String? whenUnset;

  final String placeholder;

  const Setting({
    required this.key,
    required this.label,
    required this.description,
    this.kind = SettingKind.text,
    this.choices = const [],
    this.whenUnset,
    this.placeholder = '',
  });
}

class SettingCategory {
  final String name;
  final String icon;
  final List<Setting> settings;

  const SettingCategory({
    required this.name,
    required this.icon,
    required this.settings,
  });
}

const settingCategories = <SettingCategory>[
  SettingCategory(
    name: 'Identity',
    icon: 'person',
    settings: [
      Setting(
        key: 'user.name',
        label: 'Name',
        description: 'Recorded as the author and committer of every commit.',
        placeholder: 'A Person',
      ),
      Setting(
        key: 'user.email',
        label: 'Email',
        description: 'Recorded beside the name. Hosts match commits to '
            'accounts by this.',
        placeholder: 'you@example.com',
      ),
      Setting(
        key: 'user.signingkey',
        label: 'Signing key',
        description: 'The key used when a commit or tag is signed.',
      ),
      Setting(
        key: 'commit.gpgsign',
        label: 'Sign every commit',
        description: 'Signs commits without being asked each time. This '
            'application does not sign; git will, on the command line.',
        kind: SettingKind.flag,
        whenUnset: 'off',
      ),
    ],
  ),
  SettingCategory(
    name: 'Commits',
    icon: 'commit',
    settings: [
      Setting(
        key: 'commit.template',
        label: 'Message template',
        description: 'A file whose contents start every commit message.',
        kind: SettingKind.path,
      ),
      Setting(
        key: 'core.editor',
        label: 'Editor',
        description: 'What git opens for a commit message on the command '
            'line.',
        placeholder: 'code --wait',
      ),
      Setting(
        key: 'commit.verbose',
        label: 'Show the diff while writing a message',
        description: 'Puts the change being committed below the message in '
            'the editor.',
        kind: SettingKind.flag,
        whenUnset: 'off',
      ),
    ],
  ),
  SettingCategory(
    name: 'Branches',
    icon: 'branch',
    settings: [
      Setting(
        key: 'init.defaultBranch',
        label: 'Default branch name',
        description: 'The branch a new repository starts on. Git\'s own '
            'fallback is still master; most hosts now use main.',
        placeholder: 'main',
        whenUnset: 'master',
      ),
      Setting(
        key: 'push.default',
        label: 'What a plain push sends',
        description: 'simple pushes the current branch to the branch of the '
            'same name, and refuses when they differ.',
        kind: SettingKind.choice,
        choices: ['simple', 'current', 'upstream', 'matching', 'nothing'],
        whenUnset: 'simple',
      ),
      Setting(
        key: 'push.autoSetupRemote',
        label: 'Set the upstream on first push',
        description: 'Saves having to say --set-upstream the first time a '
            'branch is pushed.',
        kind: SettingKind.flag,
        whenUnset: 'off',
      ),
      Setting(
        key: 'pull.rebase',
        label: 'Rebase when pulling',
        description: 'Replays local commits on top of what was fetched '
            'instead of making a merge commit.',
        kind: SettingKind.flag,
        whenUnset: 'off — a pull merges',
      ),
      Setting(
        key: 'branch.autoSetupMerge',
        label: 'Track the branch a new one is made from',
        description: 'Decides whether a new branch records an upstream.',
        kind: SettingKind.choice,
        choices: ['true', 'false', 'always', 'inherit'],
        whenUnset: 'true',
      ),
    ],
  ),
  SettingCategory(
    name: 'Merging',
    icon: 'merge',
    settings: [
      Setting(
        key: 'merge.conflictStyle',
        label: 'Conflict markers',
        description: 'zdiff3 also shows what the common ancestor said, which '
            'usually makes the conflict obvious.',
        kind: SettingKind.choice,
        choices: ['merge', 'diff3', 'zdiff3'],
        whenUnset: 'merge',
      ),
      Setting(
        key: 'merge.tool',
        label: 'Merge tool',
        description: 'What `git mergetool` opens.',
      ),
      Setting(
        key: 'rerere.enabled',
        label: 'Remember conflict resolutions',
        description: 'Replays how you resolved a conflict if the same one '
            'appears again.',
        kind: SettingKind.flag,
        whenUnset: 'off',
      ),
    ],
  ),
  SettingCategory(
    name: 'Files',
    icon: 'files',
    settings: [
      Setting(
        key: 'core.autocrlf',
        label: 'Line endings',
        description: 'On Windows, true stores LF and checks out CRLF. input '
            'stores LF and leaves the working tree alone.',
        kind: SettingKind.choice,
        choices: ['true', 'false', 'input'],
        whenUnset: 'false',
      ),
      Setting(
        key: 'core.ignorecase',
        label: 'Treat filenames as case-insensitive',
        description: 'Set by git to match the filesystem. Changing it on a '
            'case-insensitive disk causes trouble rather than fixing it.',
        kind: SettingKind.flag,
      ),
      Setting(
        key: 'core.excludesFile',
        label: 'Global ignore file',
        description: 'Ignore rules applied to every repository you work in.',
        kind: SettingKind.path,
      ),
      Setting(
        key: 'core.fileMode',
        label: 'Track the executable bit',
        description: 'Turn off where the filesystem cannot store it, or every '
            'file looks changed.',
        kind: SettingKind.flag,
      ),
      Setting(
        key: 'core.longpaths',
        label: 'Allow long paths',
        description: 'Windows refuses paths beyond 260 characters unless this '
            'is on.',
        kind: SettingKind.flag,
        whenUnset: 'off',
      ),
    ],
  ),
  SettingCategory(
    name: 'Diff',
    icon: 'diff',
    settings: [
      Setting(
        key: 'diff.algorithm',
        label: 'Diff algorithm',
        description: 'histogram usually produces the most readable diff; '
            'myers is git\'s default and what this application uses.',
        kind: SettingKind.choice,
        choices: ['myers', 'minimal', 'patience', 'histogram'],
        whenUnset: 'myers',
      ),
      Setting(
        key: 'diff.renames',
        label: 'Detect renames',
        description: 'copies also looks for files copied from another.',
        kind: SettingKind.choice,
        choices: ['true', 'false', 'copies'],
        whenUnset: 'true',
      ),
      Setting(
        key: 'diff.tool',
        label: 'Diff tool',
        description: 'What `git difftool` opens.',
      ),
    ],
  ),
  SettingCategory(
    name: 'Network',
    icon: 'network',
    settings: [
      Setting(
        key: 'credential.helper',
        label: 'Credential helper',
        description: 'Where usernames and tokens are kept. This application '
            'saves through whatever is named here.',
        placeholder: 'manager',
      ),
      Setting(
        key: 'http.proxy',
        label: 'HTTP proxy',
        description: 'Used for http and https remotes.',
      ),
      Setting(
        key: 'http.sslVerify',
        label: 'Verify TLS certificates',
        description: 'Turning this off makes every https remote insecure, '
            'not just the one that was refusing.',
        kind: SettingKind.flag,
        whenUnset: 'on',
      ),
      Setting(
        key: 'http.postBuffer',
        label: 'Upload buffer, in bytes',
        description: 'Raised when a large push fails part-way through.',
        kind: SettingKind.number,
        whenUnset: '1048576',
      ),
      Setting(
        key: 'fetch.prune',
        label: 'Prune deleted remote branches on fetch',
        description: 'Removes tracking refs for branches the remote no longer '
            'has.',
        kind: SettingKind.flag,
        whenUnset: 'off',
      ),
    ],
  ),
];
