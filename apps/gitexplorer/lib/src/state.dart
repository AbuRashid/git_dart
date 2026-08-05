import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'generated/tokens.dart';
import 'git_worker.dart';
import 'models.dart';
import 'repository_store.dart';

/// What the detail pane is showing.
sealed class Selection {
  const Selection();
}

class NothingSelected extends Selection {
  const NothingSelected();
}

class RepositorySelected extends Selection {
  final String repositoryPath;
  const RepositorySelected(this.repositoryPath);
}

class FileSelected extends Selection {
  final String repositoryPath;
  final Revision revision;
  final String path;
  const FileSelected(this.repositoryPath, this.revision, this.path);
}

class CommitSelected extends Selection {
  final String repositoryPath;
  final String commitId;
  const CommitSelected(this.repositoryPath, this.commitId);
}

/// One line of the flattened tree.
class TreeRow {
  final int depth;
  final String repositoryPath;

  /// Null on a repository row.
  final EntryData? entry;

  final RepositorySummary? repository;

  const TreeRow({
    required this.depth,
    required this.repositoryPath,
    this.entry,
    this.repository,
  });

  bool get isRepository => entry == null;
  String get path => entry?.path ?? '';
}

/// A node's identity: which repository, and which path inside it.
///
/// A record rather than a joined string, because every path on this machine
/// contains a space and a separator that cannot appear in a path does not
/// exist.
typedef NodeKey = (String repository, String path);

/// Everything the window is showing, and the only place that talks to the
/// worker.
class ExplorerState extends ChangeNotifier {
  final GitService _git;
  final RepositoryStore _store;

  ExplorerState({GitService? git, RepositoryStore? store})
      : _git = git ?? GitService(),
        _store = store ?? RepositoryStore();

  final _saved = <SavedRepository>[];
  final _summaries = <String, RepositorySummary>{};
  final _revisions = <String, Revision>{};
  final _expanded = <NodeKey>{};
  final _children = <NodeKey, List<EntryData>>{};
  final _loading = <NodeKey>{};

  Selection _selection = const NothingSelected();
  String? _error;
  ThemeChoice _theme = ThemeChoice.system;

  // Detail-pane contents, each null until asked for.
  FileContent? _fileContent;
  FileDiff? _fileDiff;
  List<CommitData>? _history;
  ({CommitData commit, List<ChangeData> changes})? _commit;
  FileDiff? _commitFileDiff;
  String? _commitFilePath;

  List<SavedRepository> get saved => List.unmodifiable(_saved);

  /// Which palette the window uses. The platform is the default and not the
  /// only option: it knows the time of day, not that this window is being read
  /// in direct sunlight right now
  /// (`presentation.the-platform-is-a-default-not-a-verdict`).
  ThemeChoice get theme => _theme;
  Selection get selection => _selection;
  String? get error => _error;
  FileContent? get fileContent => _fileContent;
  FileDiff? get fileDiff => _fileDiff;
  List<CommitData>? get history => _history;
  ({CommitData commit, List<ChangeData> changes})? get commit => _commit;
  FileDiff? get commitFileDiff => _commitFileDiff;
  String? get commitFilePath => _commitFilePath;

  RepositorySummary? summaryFor(String path) => _summaries[path];
  Revision revisionFor(String path) => _revisions[path] ?? Revision.workingTree;
  bool isExpanded(String repository, String path) =>
      _expanded.contains((repository, path));
  bool isLoading(String repository, String path) =>
      _loading.contains((repository, path));


  Future<void> start() async {
    await _git.start();
    final saved = await _store.load();
    _saved.addAll(saved.repositories);
    _theme = saved.theme;
    notifyListeners();
    for (final repository in _saved) {
      await _refreshSummary(repository);
    }
  }

  @override
  void dispose() {
    _git.dispose();
    super.dispose();
  }

  Future<void> _saveState() => _store.save(
        SavedState(repositories: _saved, theme: _theme),
      );

  // ---- staging and committing ---------------------------------------------

  StagingArea? _staging;
  CommitData? _lastCommit;
  bool _committing = false;

  StagingArea? get staging => _staging;

  /// The commit just written, so the pane can say what was done by name
  /// (`care.reported`).
  CommitData? get lastCommit => _lastCommit;

  bool get isCommitting => _committing;

  Future<void> loadStaging(String repository) async {
    try {
      _staging = await _git.staging(repository);
      _error = null;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  Future<void> setStaged(
    String repository,
    String path, {
    required bool staged,
  }) async {
    try {
      _staging = await _git.setStaged(repository, path, staged: staged);
      _error = null;
      await _afterIndexChange(repository);
    } on GitWorkerException catch (failure) {
      _error = failure.message;
      notifyListeners();
    }
  }

  /// Commits what is staged. Returns the new commit, or null when it was
  /// refused — in which case [error] says why.
  Future<CommitData?> commitStaged(String repository, String message) async {
    _committing = true;
    notifyListeners();
    try {
      final commit = await _git.commitStaged(repository, message);
      _lastCommit = commit;
      _error = null;
      _staging = await _git.staging(repository);
      await _afterIndexChange(repository);
      return commit;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
      return null;
    } finally {
      _committing = false;
      notifyListeners();
    }
  }

  void dismissLastCommit() {
    _lastCommit = null;
    notifyListeners();
  }

  /// Everything the index touches: the counts, the tree's status letters, and
  /// the history when a commit has just been added to it.
  Future<void> _afterIndexChange(String repository) async {
    final saved = _saved.where((r) => r.path == repository).firstOrNull;
    if (saved != null) await _refreshSummary(saved);

    for (final key in _expanded.toList()) {
      if (key.$1 != repository) continue;
      await _loadChildren(repository, key.$2);
    }

    try {
      _history = await _git.history(repository, limit: 200);
    } on GitWorkerException {
      // The history is a nicety here; a failure to refresh it must not undo
      // the commit that just succeeded.
    }
    notifyListeners();
  }

  // ---- branches -----------------------------------------------------------

  /// Renames a branch, keeping the name the row shows in step.
  ///
  /// Returns null when it was refused — [error] then says why, which is
  /// usually a name git will not accept or one already taken.
  Future<bool> renameBranch(String repository, String from, String to) async {
    try {
      _summaries[repository] = await _git.renameBranch(repository, from, to);
      _error = null;
      notifyListeners();
      return true;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteBranch(String repository, String name) async {
    try {
      _summaries[repository] = await _git.deleteBranch(repository, name);
      _error = null;
      notifyListeners();
      return true;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
      notifyListeners();
      return false;
    }
  }

  // ---- settings -----------------------------------------------------------

  final _settings = <String, SettingValue>{};

  SettingValue? settingFor(String key) => _settings[key];

  /// Reads the settings the screen shows, for the repository whose config is
  /// being looked at.
  Future<void> loadSettings(String repository, List<String> keys) async {
    try {
      for (final value in await _git.settings(repository, keys)) {
        _settings[value.key] = value;
      }
      _error = null;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  /// Writes one setting, or clears it when [value] is null.
  Future<void> writeSetting(
    String repository,
    String key,
    String? value,
    int scope,
  ) async {
    try {
      for (final written
          in await _git.writeSetting(repository, key, value, scope)) {
        _settings[written.key] = written;
      }
      _error = null;
      // A setting can change what the repository reports — the identity a
      // commit would carry, which files are ignored — so the view is re-read.
      await _refreshOpenRepository(repository);
    } on GitWorkerException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  Future<void> _refreshOpenRepository(String repository) async {
    final saved = _saved.where((r) => r.path == repository).firstOrNull;
    if (saved != null) await _refreshSummary(saved);
    if (_selection case RepositorySelected(:final repositoryPath)
        when repositoryPath == repository) {
      try {
        _staging = await _git.staging(repository);
      } on GitWorkerException {
        // The staging panel is a nicety here; a failure to refresh it must
        // not undo the setting that was just written.
      }
    }
  }

  // ---- remotes ------------------------------------------------------------

  List<RemoteData>? _remotes;
  FetchOutcome? _lastFetch;
  String? _fetching;

  List<RemoteData>? get remotes => _remotes;
  FetchOutcome? get lastFetch => _lastFetch;

  /// The remote currently being fetched, or null. A fetch waits on a network,
  /// so it is reported as pending rather than hidden.
  String? get fetching => _fetching;

  Future<void> loadRemotes(String repository) async {
    try {
      _remotes = await _git.remotes(repository);
      _error = null;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  Future<void> addRemote(String repository, String name, String url) async {
    try {
      _remotes = await _git.addRemote(repository, name, url);
      _error = null;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  Future<void> removeRemote(String repository, String name) async {
    try {
      _remotes = await _git.removeRemote(repository, name);
      _error = null;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  /// Fetches, and reports what arrived.
  Future<FetchOutcome?> fetchRemote(
    String repository,
    String name, {
    String? username,
    String? password,
    bool remember = false,
  }) async {
    _fetching = name;
    _lastFetch = null;
    notifyListeners();
    try {
      final outcome = await _git.fetchRemote(
        repository,
        name,
        username: username,
        password: password,
        remember: remember,
      );
      _lastFetch = outcome;
      // Needing credentials is a question, not a failure.
      _error = outcome.needsCredentials ? null : outcome.error;
      // Tracking refs moved, so the branch list and the counts are stale.
      await _afterIndexChange(repository);
      return outcome;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
      return null;
    } finally {
      _fetching = null;
      notifyListeners();
    }
  }

  PullOutcome? _lastPull;
  String? _pulling;

  PullOutcome? get lastPull => _lastPull;
  String? get pulling => _pulling;

  /// Fetches and merges. Returns the outcome, or null when the worker failed.
  Future<PullOutcome?> pullRemote(
    String repository,
    String name, {
    String? username,
    String? password,
    bool remember = false,
  }) async {
    _pulling = name;
    _lastPull = null;
    _lastFetch = null;
    notifyListeners();
    try {
      final outcome = await _git.pullRemote(
        repository,
        name,
        username: username,
        password: password,
        remember: remember,
      );
      _lastPull = outcome;
      _error = outcome.fetch.needsCredentials ? null : outcome.error;
      await _afterIndexChange(repository);
      return outcome;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
      return null;
    } finally {
      _pulling = null;
      notifyListeners();
    }
  }

  void dismissLastPull() {
    _lastPull = null;
    notifyListeners();
  }

  void dismissLastFetch() {
    _lastFetch = null;
    notifyListeners();
  }

  PushOutcome? _lastPush;
  String? _pushing;

  PushOutcome? get lastPush => _lastPush;
  String? get pushing => _pushing;

  /// Pushes the current branch. [force] overwrites a remote branch holding
  /// commits this one does not — never assumed, only asked for.
  Future<PushOutcome?> pushRemote(
    String repository,
    String name, {
    bool force = false,
    String? username,
    String? password,
    bool remember = false,
  }) async {
    _pushing = name;
    _lastPush = null;
    notifyListeners();
    try {
      final outcome = await _git.pushRemote(
        repository,
        name,
        force: force,
        username: username,
        password: password,
        remember: remember,
      );
      _lastPush = outcome;
      _error = outcome.needsCredentials ? null : outcome.error;
      await _afterIndexChange(repository);
      return outcome;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
      return null;
    } finally {
      _pushing = null;
      notifyListeners();
    }
  }

  void dismissLastPush() {
    _lastPush = null;
    notifyListeners();
  }

  // ---- ignoring -----------------------------------------------------------

  /// How many paths the index holds at or under [path].
  ///
  /// The caller asks before ignoring, because ignoring a tracked path has no
  /// effect until it also leaves the index, and the user should be told that
  /// rather than left wondering why nothing happened.
  Future<int> trackedCount(String repository, String path) async {
    try {
      return await _git.trackedCount(repository, path);
    } on GitWorkerException {
      return 0;
    }
  }

  /// Adds an ignore rule for [path]. Returns the pattern written, or null when
  /// an identical rule was already there or the write failed.
  Future<String?> ignorePath(
    String repository,
    String path, {
    required bool isDirectory,
    bool alsoUntrack = false,
  }) async {
    try {
      final pattern = await _git.ignore(
        repository: repository,
        path: path,
        isDirectory: isDirectory,
        alsoUntrack: alsoUntrack,
      );
      _error = null;
      await _afterIndexChange(repository);
      return pattern;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
      notifyListeners();
      return null;
    }
  }

  // ---- editing ------------------------------------------------------------

  /// Edits made and not yet saved, kept per file.
  ///
  /// Held here rather than in the editor widget so that moving the selection
  /// elsewhere and coming back does not lose them — losing work to a stray
  /// click is not a trade worth making for simpler code
  /// (`editing.unsaved-edits-survive-navigation`).
  final _drafts = <NodeKey, String>{};

  bool get isEditing => _drafts.isNotEmpty;

  String? draftFor(String repository, String path) =>
      _drafts[(repository, path)];

  bool hasDraft(String repository, String path) =>
      _drafts.containsKey((repository, path));

  /// Records a draft, or clears it when it matches what is on disk.
  void editFile(String repository, String path, String text) {
    final saved = _fileContent;
    if (saved != null && saved.path == path && saved.text == text) {
      _drafts.remove((repository, path));
    } else {
      _drafts[(repository, path)] = text;
    }
    notifyListeners();
  }

  void discardDraft(String repository, String path) {
    _drafts.remove((repository, path));
    notifyListeners();
  }

  /// Writes the draft for [path] to disk.
  ///
  /// Returns true when it was written. A save that would overwrite a change
  /// made since the file was opened is refused, and the reason is reported
  /// (`editing.a-stale-write-is-refused`).
  Future<bool> saveFile(String repository, String path) async {
    final draft = _drafts[(repository, path)];
    if (draft == null) return false;

    final opened = _fileContent;
    try {
      await _git.writeFile(
        repository: repository,
        path: path,
        contents: draft,
        expectedSize: opened?.path == path ? opened?.size : null,
        expectedModified: opened?.path == path ? opened?.modified : null,
      );
      _drafts.remove((repository, path));
      _error = null;
      await _afterWorkingTreeChange(repository);
      return true;
    } on GitWorkerException catch (failure) {
      // The draft is kept: the whole point of refusing was not to lose work.
      _error = failure.message;
      notifyListeners();
      return false;
    }
  }

  /// Creates an empty file or folder at [path], relative to the repository.
  Future<bool> createEntry(
    String repository,
    String path,
    EntryKind kind,
  ) async {
    try {
      await _git.createEntry(repository: repository, path: path, kind: kind);
      _error = null;
      await _afterWorkingTreeChange(repository);
      if (kind == EntryKind.file) await selectFile(repository, path);
      return true;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
      notifyListeners();
      return false;
    }
  }

  /// Re-reads what a write has changed: the status counts, and every open
  /// directory of that repository.
  Future<void> _afterWorkingTreeChange(String repository) async {
    final saved = _saved.where((r) => r.path == repository).firstOrNull;
    if (saved != null) await _refreshSummary(saved);

    for (final key in _expanded.toList()) {
      if (key.$1 != repository) continue;
      await _loadChildren(repository, key.$2);
    }

    if (_selection case FileSelected(:final repositoryPath, :final path)
        when repositoryPath == repository) {
      await selectFile(repository, path);
    } else {
      notifyListeners();
    }
  }

  Future<void> setTheme(ThemeChoice choice) async {
    if (_theme == choice) return;
    _theme = choice;
    notifyListeners();
    await _saveState();
  }

  // ---- the virtual root ---------------------------------------------------

  Future<void> addRepository(String path) async {
    if (_saved.any((r) => r.path == path)) return;
    final repository = SavedRepository.forPath(path);
    _saved.add(repository);
    await _saveState();
    notifyListeners();
    await _refreshSummary(repository);
  }

  /// Looks at a folder without adding it.
  ///
  /// The caller asks first, so that a folder holding no repository is offered
  /// the one action that changes that, rather than becoming a row which can
  /// only report a failure (`initialising.why`).
  Future<RepositorySummary> inspect(String path) async {
    try {
      return await _git.inspect(path);
    } on GitWorkerException catch (failure) {
      return RepositorySummary(
        path: path,
        name: p.basename(p.normalize(path)),
      ).unavailable(UnavailableReason.unreadable, failure.message);
    }
  }

  /// Creates an empty repository at [path] and adds it, or moves an existing
  /// row from unavailable to available.
  Future<void> initialiseRepository(String path) async {
    final name = _saved.where((r) => r.path == path).firstOrNull?.name ??
        p.basename(p.normalize(path));

    try {
      final summary = await _git.initialise(path, name);
      _summaries[path] = summary;
      if (!_saved.any((r) => r.path == path)) {
        _saved.add(SavedRepository(path: path, name: name));
        await _saveState();
      }
      _error = null;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  Future<void> removeRepository(String path) async {
    _saved.removeWhere((r) => r.path == path);
    _summaries.remove(path);
    _expanded.removeWhere((key) => key.$1 == path);
    _children.removeWhere((key, _) => key.$1 == path);
    if (_selectionRepository == path) _selection = const NothingSelected();
    await _saveState();
    notifyListeners();
  }

  Future<void> renameRepository(String path, String name) async {
    final index = _saved.indexWhere((r) => r.path == path);
    if (index < 0 || name.trim().isEmpty) return;
    _saved[index] = SavedRepository(path: path, name: name.trim());
    final summary = _summaries[path];
    if (summary != null) {
      _summaries[path] = RepositorySummary(
        path: summary.path,
        name: name.trim(),
        available: summary.available,
        reason: summary.reason,
        error: summary.error,
        branch: summary.branch,
        detached: summary.detached,
        headId: summary.headId,
        headSummary: summary.headSummary,
        headWhen: summary.headWhen,
        headAuthor: summary.headAuthor,
        changedCount: summary.changedCount,
        untrackedCount: summary.untrackedCount,
        branches: summary.branches,
        tags: summary.tags,
      );
    }
    await _saveState();
    notifyListeners();
  }

  String? get _selectionRepository => switch (_selection) {
        RepositorySelected(:final repositoryPath) => repositoryPath,
        FileSelected(:final repositoryPath) => repositoryPath,
        CommitSelected(:final repositoryPath) => repositoryPath,
        NothingSelected() => null,
      };

  Future<void> _refreshSummary(SavedRepository repository) async {
    try {
      _summaries[repository.path] =
          await _git.open(repository.path, repository.name);
    } on GitWorkerException catch (error) {
      _summaries[repository.path] =
          RepositorySummary(path: repository.path, name: repository.name)
              .unavailable(UnavailableReason.unreadable, error.message);
    }
    notifyListeners();
  }

  /// Re-reads a repository from disk: its summary, and anything already open
  /// under it.
  Future<void> refresh(String repositoryPath) async {
    await _git.refresh(repositoryPath);
    _children.removeWhere((key, _) => key.$1 == repositoryPath);

    final saved = _saved.where((r) => r.path == repositoryPath).firstOrNull;
    if (saved != null) await _refreshSummary(saved);

    for (final key in _expanded.toList()) {
      if (key.$1 != repositoryPath) continue;
      await _loadChildren(repositoryPath, key.$2);
    }
    await _reloadDetail();
  }

  // ---- expanding ----------------------------------------------------------

  Future<void> toggle(String repositoryPath, String path) async {
    final key = (repositoryPath, path);
    if (_expanded.remove(key)) {
      notifyListeners();
      return;
    }
    _expanded.add(key);
    notifyListeners();
    if (!_children.containsKey(key)) {
      await _loadChildren(repositoryPath, path);
    }
  }

  Future<void> _loadChildren(String repositoryPath, String path) async {
    final key = (repositoryPath, path);
    _loading.add(key);
    notifyListeners();
    try {
      _children[key] = await _git.directory(
        repositoryPath,
        revisionFor(repositoryPath),
        path,
      );
      _error = null;
    } on GitWorkerException catch (failure) {
      _children[key] = const [];
      _error = failure.message;
    } finally {
      _loading.remove(key);
      notifyListeners();
    }
  }

  Future<void> setRevision(String repositoryPath, Revision revision) async {
    _revisions[repositoryPath] = revision;
    // Everything already open was showing a different revision's tree.
    _children.removeWhere((key, _) => key.$1 == repositoryPath);
    notifyListeners();

    for (final key in _expanded.toList()) {
      if (key.$1 != repositoryPath) continue;
      await _loadChildren(repositoryPath, key.$2);
    }

    if (_selection case FileSelected(:final path)
        when _selectionRepository == repositoryPath) {
      await selectFile(repositoryPath, path);
    }
  }

  /// The visible rows, flattened for a list view.
  List<TreeRow> get rows {
    final out = <TreeRow>[];
    for (final saved in _saved) {
      final summary = _summaries[saved.path] ??
          RepositorySummary(path: saved.path, name: saved.name);
      out.add(TreeRow(depth: 0, repositoryPath: saved.path, repository: summary));
      if (summary.available && isExpanded(saved.path, '')) {
        _appendChildren(out, saved.path, '', 1);
      }
    }
    return out;
  }

  void _appendChildren(
    List<TreeRow> out,
    String repositoryPath,
    String path,
    int depth,
  ) {
    final entries = _children[(repositoryPath, path)];
    if (entries == null) return;
    for (final entry in entries) {
      out.add(TreeRow(
        depth: depth,
        repositoryPath: repositoryPath,
        entry: entry,
      ));
      if (entry.kind.expands && isExpanded(repositoryPath, entry.path)) {
        _appendChildren(out, repositoryPath, entry.path, depth + 1);
      }
    }
  }

  // ---- selection ----------------------------------------------------------

  Future<void> selectRepository(String repositoryPath) async {
    _selection = RepositorySelected(repositoryPath);
    _fileContent = null;
    _fileDiff = null;
    _commit = null;
    _history = null;
    _staging = null;
    notifyListeners();

    // A repository that could not be opened has no staging area and no
    // history, and asking for them would report a failure the row has already
    // explained more usefully.
    if (_summaries[repositoryPath]?.available != true) {
      notifyListeners();
      return;
    }

    try {
      _staging = await _git.staging(repositoryPath);
      _remotes = await _git.remotes(repositoryPath);
      _history = await _git.history(repositoryPath, limit: 200);
    } on GitWorkerException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  Future<void> selectFile(String repositoryPath, String path) async {
    final revision = revisionFor(repositoryPath);
    _selection = FileSelected(repositoryPath, revision, path);
    _fileContent = null;
    _fileDiff = null;
    notifyListeners();

    try {
      _fileContent = await _git.file(repositoryPath, revision, path);
      // A diff is only meaningful against the working tree, which is the only
      // view being compared with anything at all.
      if (revision.kind == RevisionKind.workingTree) {
        final diff = await _git.fileDiff(repositoryPath, revision, path);
        if (!diff.isEmpty) _fileDiff = diff;
      }
      _error = null;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  Future<void> selectCommit(String repositoryPath, String commitId) async {
    _selection = CommitSelected(repositoryPath, commitId);
    _commit = null;
    _commitFileDiff = null;
    _commitFilePath = null;
    notifyListeners();

    try {
      _commit = await _git.commit(repositoryPath, commitId);
      _error = null;
    } on GitWorkerException catch (failure) {
      _error = failure.message;
    }
    notifyListeners();
  }

  Future<void> selectCommitFile(String path) async {
    if (_selection case CommitSelected(:final repositoryPath, :final commitId)) {
      _commitFilePath = path;
      _commitFileDiff = null;
      notifyListeners();
      try {
        _commitFileDiff =
            await _git.commitDiff(repositoryPath, commitId, path);
      } on GitWorkerException catch (failure) {
        _error = failure.message;
      }
      notifyListeners();
    }
  }

  void clearSelection() {
    _selection = const NothingSelected();
    notifyListeners();
  }

  void dismissError() {
    _error = null;
    notifyListeners();
  }

  Future<void> _reloadDetail() async {
    switch (_selection) {
      case FileSelected(:final repositoryPath, :final path):
        await selectFile(repositoryPath, path);
      case RepositorySelected(:final repositoryPath):
        await selectRepository(repositoryPath);
      case CommitSelected(:final repositoryPath, :final commitId):
        await selectCommit(repositoryPath, commitId);
      case NothingSelected():
        break;
    }
  }
}
