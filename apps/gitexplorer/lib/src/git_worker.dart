/// The worker isolate: every git_dart call happens here.
///
/// git_dart is synchronous and its calls are file reads and inflates, so they
/// must not run on the UI thread. A worker rather than an isolate per call,
/// because spawning one per call would reopen the repository each time — which
/// means reading every pack index again, and on a large repository that is
/// most of the cost of the work (`concurrency.why-a-worker-and-not-a-call-per-operation`).
///
/// Nothing holding a file handle crosses back. The requests and responses in
/// this file are plain data, and there is no way to ask the worker for a
/// Repository, so there is no way for one to leak (`concurrency.rule`).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:git_dart/git_dart.dart' as git;
import 'package:path/path.dart' as p;

import 'generated/tokens.dart';
import 'models.dart';

// ---------------------------------------------------------------------------
// protocol
// ---------------------------------------------------------------------------

sealed class GitRequest {
  const GitRequest();
}

class OpenRepository extends GitRequest {
  final String path;
  final String name;
  const OpenRepository(this.path, this.name);
}

class LoadDirectory extends GitRequest {
  final String repositoryPath;
  final Revision revision;

  /// '' for the repository root.
  final String path;

  const LoadDirectory(this.repositoryPath, this.revision, this.path);
}

class LoadFile extends GitRequest {
  final String repositoryPath;
  final Revision revision;
  final String path;
  const LoadFile(this.repositoryPath, this.revision, this.path);
}

class LoadFileDiff extends GitRequest {
  final String repositoryPath;
  final Revision revision;
  final String path;
  const LoadFileDiff(this.repositoryPath, this.revision, this.path);
}

class LoadHistory extends GitRequest {
  final String repositoryPath;
  final String? path;
  final int limit;
  const LoadHistory(this.repositoryPath, {this.path, this.limit = 100});
}

class LoadCommit extends GitRequest {
  final String repositoryPath;
  final String commitId;
  const LoadCommit(this.repositoryPath, this.commitId);
}

class LoadCommitDiff extends GitRequest {
  final String repositoryPath;
  final String commitId;
  final String path;
  const LoadCommitDiff(this.repositoryPath, this.commitId, this.path);
}

/// Creates an empty repository in a folder that holds none.
///
/// The one write this application makes, admitted as a named exception: it
/// writes no objects and moves no ref that existed before, so there is nothing
/// it could lose (`initialising.the-exception-to-the-non-goal`).
class InitialiseRepository extends GitRequest {
  final String path;
  final String name;
  const InitialiseRepository(this.path, this.name);
}

/// Saves a file in the working tree.
///
/// [expectedSize] and [expectedModified] are what the file looked like when it
/// was opened. A save is refused when they no longer match, because something
/// else has written to it since and overwriting would discard that silently
/// (`editing.a-stale-write-is-refused`). Both null for a file being created.
class WriteFile extends GitRequest {
  final String repositoryPath;
  final String path;
  final String contents;
  final int? expectedSize;
  final DateTime? expectedModified;

  const WriteFile({
    required this.repositoryPath,
    required this.path,
    required this.contents,
    this.expectedSize,
    this.expectedModified,
  });
}

/// Creates an empty file, or every directory on the way to a new folder.
class CreateEntry extends GitRequest {
  final String repositoryPath;
  final String path;
  final EntryKind kind;

  const CreateEntry({
    required this.repositoryPath,
    required this.path,
    required this.kind,
  });
}

/// Both halves of the status, for the staging panel.
class LoadStaging extends GitRequest {
  final String repositoryPath;
  const LoadStaging(this.repositoryPath);
}

/// Stages or unstages one path.
class SetStaged extends GitRequest {
  final String repositoryPath;
  final String path;
  final bool staged;
  const SetStaged(this.repositoryPath, this.path, {required this.staged});
}

/// Commits what is staged.
class CommitStaged extends GitRequest {
  final String repositoryPath;
  final String message;
  const CommitStaged(this.repositoryPath, this.message);
}

/// Adds a rule for [path] to the repository's root `.gitignore`.
///
/// [alsoUntrack] additionally removes it from the index — without which an
/// already-tracked path goes on being tracked and the new rule does nothing,
/// which is the thing people are surprised by.
class IgnorePath extends GitRequest {
  final String repositoryPath;
  final String path;
  final bool isDirectory;
  final bool alsoUntrack;

  const IgnorePath({
    required this.repositoryPath,
    required this.path,
    required this.isDirectory,
    this.alsoUntrack = false,
  });
}

/// How many paths the index holds at or under a path.
class CountTracked extends GitRequest {
  final String repositoryPath;
  final String path;
  const CountTracked(this.repositoryPath, this.path);
}

/// Drops cached state so the next question is answered from disk.
class Refresh extends GitRequest {
  final String repositoryPath;
  const Refresh(this.repositoryPath);
}

class _Envelope {
  final int id;
  final GitRequest request;
  const _Envelope(this.id, this.request);
}

class _Reply {
  final int id;
  final Object? value;
  final String? error;
  const _Reply(this.id, this.value, this.error);
}

// ---------------------------------------------------------------------------
// the worker
// ---------------------------------------------------------------------------

void gitWorkerMain(SendPort toMain) {
  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);

  final worker = _Worker();

  inbox.listen((message) {
    if (message is! _Envelope) return;
    try {
      toMain.send(_Reply(message.id, worker.handle(message.request), null));
    } catch (error) {
      // A failure is a reply, not a crash: one bad repository must not take
      // the worker down and with it every other repository's state.
      toMain.send(_Reply(message.id, null, error.toString()));
    }
  });
}

class _Worker {
  final _repositories = <String, git.Repository>{};
  final _statuses = <String, Map<String, FileState>>{};

  Object? handle(GitRequest request) => switch (request) {
        OpenRepository() => _open(request),
        InitialiseRepository() => _initialise(request),
        WriteFile() => _write(request),
        CreateEntry() => _create(request),
        IgnorePath() => _ignore(request),
        CountTracked() => _countTracked(request),
        LoadStaging() => _staging(request),
        SetStaged() => _setStaged(request),
        CommitStaged() => _writeCommit(request),
        LoadDirectory() => _directory(request),
        LoadFile() => _file(request),
        LoadFileDiff() => _fileDiff(request),
        LoadHistory() => _history(request),
        LoadCommit() => _commit(request),
        LoadCommitDiff() => _commitDiff(request),
        Refresh() => _refresh(request),
      };

  git.Repository _repository(String path) {
    final open = _repositories[path];
    if (open != null) return open;
    final found = git.Repository.discover(path);
    if (found == null) {
      throw StateError('no git repository at $path');
    }
    return _repositories[path] = found;
  }

  Object? _refresh(Refresh request) {
    _statuses.remove(request.repositoryPath);
    _repositories.remove(request.repositoryPath)?.close();
    return null;
  }

  // ---- repository ---------------------------------------------------------

  RepositorySummary _open(OpenRepository request) {
    final blank = RepositorySummary(path: request.path, name: request.name);

    if (!Directory(request.path).existsSync()) {
      return blank.unavailable(UnavailableReason.missing);
    }

    // Discovery walks upwards, so a subdirectory of a repository finds that
    // repository. Nothing nested is ever offered or created
    // (`initialising.a-folder-inside-a-repository-is-never-offered`).
    if (git.Repository.discover(request.path) == null) {
      return blank.unavailable(UnavailableReason.notARepository);
    }

    final git.Repository repo;
    try {
      repo = _repository(request.path);
    } catch (error) {
      return blank.unavailable(UnavailableReason.unreadable, '$error');
    }

    final head = repo.headCommit;
    final status = repo.isBare ? null : repo.status();

    return RepositorySummary(
      path: request.path,
      name: request.name,
      branch: repo.refs.currentBranch?.replaceFirst('refs/heads/', ''),
      detached: repo.refs.isDetached,
      headId: head?.id.hex,
      headSummary: head?.summary,
      headWhen: head?.committer.utc,
      headAuthor: head?.author.name,
      changedCount:
          status == null ? 0 : status.entries.where((e) => !e.isUntracked).length,
      untrackedCount: status?.untracked.length ?? 0,
      branches: repo.refs.branches.map((r) => r.shortName).toList(),
      tags: repo.refs.tags.map((r) => r.shortName).toList(),
    );
  }

  RepositorySummary _initialise(InitialiseRepository request) {
    final directory = Directory(request.path);
    if (!directory.existsSync()) {
      throw StateError('${request.path} is not there to initialise');
    }
    // Refuse rather than write over something already here. Initialising on
    // top of a repository that exists but failed to open would be destroying
    // it on the strength of not having understood it
    // (`initialising.only-not-a-repository-is-offered`).
    if (git.Repository.discover(request.path) != null) {
      throw StateError('${request.path} is already inside a repository');
    }

    git.Repository.init(request.path, defaultBranch: _defaultBranch(request.path))
        .close();
    return _open(OpenRepository(request.path, request.name));
  }

  /// `init.defaultBranch` from the user's own git config, or `main`.
  ///
  /// Taken from their configuration rather than fixed here, so a repository
  /// this application creates is the one their git would have created
  /// (`initialising.default-branch`).
  String _defaultBranch(String path) {
    final config = git.GitConfig.forRepository(p.join(path, '.git'));
    final configured = config['init.defaultbranch'];
    return configured == null || configured.isEmpty ? 'main' : configured;
  }

  // ---- ignoring -----------------------------------------------------------

  String? _ignore(IgnorePath request) {
    final repo = _repository(request.repositoryPath);
    if (request.alsoUntrack) repo.removeFromIndex(request.path);
    final pattern = repo.addIgnoreRule(
      request.path,
      isDirectory: request.isDirectory,
    );
    _statuses.remove(request.repositoryPath);
    return pattern;
  }

  int _countTracked(CountTracked request) =>
      _repository(request.repositoryPath).trackedUnder(request.path).length;

  // ---- the staging area ---------------------------------------------------

  StagingArea _staging(LoadStaging request) {
    final repo = _repository(request.repositoryPath);
    if (repo.isBare) return const StagingArea(rows: []);

    final identity = repo.identityFromConfig();

    return StagingArea(
      identity: identity == null
          ? null
          : '${identity.name} <${identity.email}>',
      rows: [
        for (final entry in repo.status().entries)
          StatusRow(
            path: entry.path,
            staged: entry.staged == null ? null : _fromChange(entry.staged),
            unstaged:
                entry.unstaged == null ? null : _fromChange(entry.unstaged),
            isUntracked: entry.isUntracked,
            isConflicted: entry.isConflicted,
          ),
      ],
    );
  }

  StagingArea _setStaged(SetStaged request) {
    final repo = _repository(request.repositoryPath);
    if (request.staged) {
      // A path missing from the working tree stages its deletion, which is
      // what `git add` on a deleted file does (`committing.staging-a-deletion`).
      repo.stage(request.path);
    } else {
      repo.unstage(request.path);
    }
    _statuses.remove(request.repositoryPath);
    return _staging(LoadStaging(request.repositoryPath));
  }

  CommitData _writeCommit(CommitStaged request) {
    final repo = _repository(request.repositoryPath);
    final id = repo.commitIndex(message: request.message);
    _statuses.remove(request.repositoryPath);
    return _toData(repo.objects.readTyped<git.Commit>(id));
  }

  // ---- writing the working tree -------------------------------------------

  /// Resolves a repository-relative path to somewhere inside the working tree,
  /// or refuses.
  ///
  /// Every write goes through here. A path that climbs out with `..`, an
  /// absolute path, or anything in a bare repository is refused — a text field
  /// is not a place to be trusted about where a write lands.
  String _resolveForWriting(String repositoryPath, String path) {
    final repo = _repository(repositoryPath);
    final root = repo.workTree;
    if (root == null) {
      throw StateError('a bare repository has no working tree to write to');
    }
    if (path.trim().isEmpty) {
      throw StateError('a name is required');
    }

    final absolute = p.normalize(p.join(root, path.replaceAll('/', p.separator)));
    if (!p.isWithin(root, absolute)) {
      throw StateError('$path is outside the working tree');
    }
    // The repository's own directory is not part of the working tree, and
    // writing into it by hand is how a repository gets broken.
    if (p.isWithin(p.join(root, '.git'), absolute) ||
        p.equals(p.join(root, '.git'), absolute)) {
      throw StateError('$path is inside the git directory');
    }
    return absolute;
  }

  EntryData _write(WriteFile request) {
    final absolute = _resolveForWriting(request.repositoryPath, request.path);
    final file = File(absolute);

    if (Directory(absolute).existsSync()) {
      throw StateError('${request.path} is a directory');
    }

    if (request.expectedSize != null && file.existsSync()) {
      final stat = file.statSync();
      final movedOn = stat.size != request.expectedSize ||
          (request.expectedModified != null &&
              stat.modified.millisecondsSinceEpoch !=
                  request.expectedModified!.millisecondsSinceEpoch);
      if (movedOn) {
        throw StateError(
          '${request.path} changed on disk since it was opened; '
          'reload it and try again',
        );
      }
    }

    file.parent.createSync(recursive: true);
    file.writeAsStringSync(request.contents);

    // The file's state has changed, so the cached status is now a lie.
    _statuses.remove(request.repositoryPath);

    final stat = file.statSync();
    return EntryData(
      name: p.basename(absolute),
      path: request.path,
      kind: EntryKind.file,
      state: _status(_repository(request.repositoryPath), request.repositoryPath)[
              request.path] ??
          FileState.clean,
      size: stat.size,
    );
  }

  EntryData _create(CreateEntry request) {
    final absolute = _resolveForWriting(request.repositoryPath, request.path);

    if (File(absolute).existsSync() || Directory(absolute).existsSync()) {
      throw StateError('${request.path} already exists');
    }

    if (request.kind == EntryKind.directory) {
      // Every directory on the way, so `a/b/c` is one action rather than three
      // (`editing.directories-are-created-in-full`).
      Directory(absolute).createSync(recursive: true);
    } else {
      File(absolute)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
    }

    _statuses.remove(request.repositoryPath);

    return EntryData(
      name: p.basename(absolute),
      path: request.path,
      kind: request.kind,
      state: _status(_repository(request.repositoryPath), request.repositoryPath)[
              request.path] ??
          FileState.untracked,
      size: request.kind == EntryKind.file ? 0 : null,
    );
  }

  /// The status of the working tree, as a path-to-state map, computed once and
  /// kept until a refresh.
  Map<String, FileState> _status(git.Repository repo, String key) {
    final cached = _statuses[key];
    if (cached != null) return cached;
    if (repo.isBare) return _statuses[key] = const {};

    final states = <String, FileState>{};
    for (final entry in repo.status().entries) {
      states[entry.path] = _stateOf(entry);
    }
    return _statuses[key] = states;
  }

  /// A row shows the worse of the two comparisons; the detail pane shows both
  /// (`status-is-not-a-file-property`).
  FileState _stateOf(git.StatusEntry entry) {
    if (entry.isConflicted) return FileState.conflicted;
    if (entry.isUntracked) return FileState.untracked;
    return _fromChange(entry.unstaged ?? entry.staged);
  }

  static FileState _fromChange(git.ChangeKind? kind) => switch (kind) {
        null => FileState.clean,
        git.ChangeKind.added => FileState.added,
        git.ChangeKind.deleted => FileState.deleted,
        git.ChangeKind.modified => FileState.modified,
        git.ChangeKind.renamed => FileState.renamed,
        git.ChangeKind.typeChanged => FileState.typechange,
      };

  // ---- the tree -----------------------------------------------------------

  List<EntryData> _directory(LoadDirectory request) {
    final repo = _repository(request.repositoryPath);
    final revision = request.revision.revisionString;

    if (revision == null) {
      return _directoryFromDisk(repo, request.repositoryPath, request.path);
    }
    return _directoryFromTree(repo, revision, request.path);
  }

  List<EntryData> _directoryFromDisk(
    git.Repository repo,
    String key,
    String path,
  ) {
    final root = repo.workTree ?? repo.gitDirectory;
    final directory = Directory(
      path.isEmpty ? root : p.join(root, path.replaceAll('/', p.separator)),
    );
    if (!directory.existsSync()) return const [];

    final states = _status(repo, key);
    // Ignored paths are not in the status at all, so they are matched here —
    // otherwise a file just added to .gitignore would look identical to a
    // clean tracked one.
    final rules = git.loadIgnoreRules(root, repo.gitDirectory, config: repo.config);
    final entries = <EntryData>[];

    for (final entry in directory.listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      if (path.isEmpty && name == '.git') continue;
      final childPath = path.isEmpty ? name : '$path/$name';

      if (entry is Directory) {
        final worst = _worstUnder(states, childPath);
        entries.add(EntryData(
          name: name,
          path: childPath,
          kind: EntryKind.directory,
          // A directory carries the worst state of anything under it, so a
          // change is visible without expanding every level to find it.
          state: worst == FileState.clean &&
                  rules.isIgnored(childPath, isDirectory: true)
              ? FileState.ignored
              : worst,
        ));
      } else {
        final state = states[childPath];
        entries.add(EntryData(
          name: name,
          path: childPath,
          kind: EntryKind.file,
          state: state ??
              (rules.isIgnoredWithin(childPath)
                  ? FileState.ignored
                  : FileState.clean),
          size: entry is File ? entry.lengthSync() : null,
        ));
      }
    }

    return _sorted(entries);
  }

  FileState _worstUnder(Map<String, FileState> states, String directory) {
    final prefix = '$directory/';
    var worst = FileState.clean;
    for (final entry in states.entries) {
      // An untracked directory is recorded by git as a single entry ending in
      // a slash, so it matches the directory itself as well as its contents.
      if (entry.key == directory ||
          entry.key == prefix ||
          entry.key.startsWith(prefix)) {
        worst = _worse(worst, entry.value);
      }
    }
    return worst;
  }

  static FileState _worse(FileState a, FileState b) {
    const order = [
      FileState.clean,
      FileState.ignored,
      FileState.untracked,
      FileState.typechange,
      FileState.renamed,
      FileState.added,
      FileState.deleted,
      FileState.modified,
      FileState.conflicted,
    ];
    return order.indexOf(a) >= order.indexOf(b) ? a : b;
  }

  List<EntryData> _directoryFromTree(
    git.Repository repo,
    String revision,
    String path,
  ) {
    final id = repo.resolve(revision);
    if (id == null) throw StateError('$revision names nothing here');
    final root = repo.treeOf(id);
    if (root == null) throw StateError('$revision has no tree');

    git.Tree tree;
    if (path.isEmpty) {
      tree = root;
    } else {
      final entry = repo.lookup(root, path);
      if (entry == null || !entry.mode.isTree) return const [];
      tree = repo.objects.readTyped<git.Tree>(entry.id);
    }

    return _sorted([
      for (final entry in tree.entries)
        EntryData(
          name: entry.name,
          path: path.isEmpty ? entry.name : '$path/${entry.name}',
          kind: entry.mode.isTree
              ? EntryKind.directory
              : entry.mode.isSubmodule
                  ? EntryKind.submodule
                  : EntryKind.file,
          objectId: entry.id.hex,
        ),
    ]);
  }

  /// Directories first, then by name — the order a file explorer uses, which
  /// is not git's tree order and does not have to be: this one is for reading.
  List<EntryData> _sorted(List<EntryData> entries) {
    entries.sort((a, b) {
      final aIsDirectory = a.kind == EntryKind.directory;
      final bIsDirectory = b.kind == EntryKind.directory;
      if (aIsDirectory != bIsDirectory) return aIsDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  // ---- files --------------------------------------------------------------

  static const _maximumPreview = 1024 * 1024;

  FileContent _file(LoadFile request) {
    final repo = _repository(request.repositoryPath);
    final revision = request.revision.revisionString;

    List<int>? bytes;
    DateTime? modified;
    if (revision == null) {
      final root = repo.workTree ?? repo.gitDirectory;
      final file = File(
        p.join(root, request.path.replaceAll('/', p.separator)),
      );
      if (file.existsSync()) modified = file.statSync().modified;
      if (!file.existsSync()) {
        return FileContent(
          path: request.path,
          size: 0,
          isBinary: false,
          notLoaded: 'the file is not on disk',
        );
      }
      if (file.lengthSync() > _maximumPreview) {
        return FileContent(
          path: request.path,
          size: file.lengthSync(),
          isBinary: false,
          notLoaded: 'the file is larger than 1 MB',
        );
      }
      bytes = file.readAsBytesSync();
    } else {
      bytes = repo.readFile(request.path, revision: revision);
      if (bytes == null) {
        return FileContent(
          path: request.path,
          size: 0,
          isBinary: false,
          notLoaded: 'the file is not in $revision',
        );
      }
      if (bytes.length > _maximumPreview) {
        return FileContent(
          path: request.path,
          size: bytes.length,
          isBinary: false,
          notLoaded: 'the file is larger than 1 MB',
        );
      }
    }

    final content = git.Blob(Uint8List.fromList(bytes));
    if (git.looksBinary(content.content)) {
      return FileContent(
        path: request.path,
        size: bytes.length,
        isBinary: true,
        notLoaded: 'binary',
      );
    }

    return FileContent(
      path: request.path,
      size: bytes.length,
      isBinary: false,
      modified: modified,
      text: content.text,
    );
  }

  // ---- diffs --------------------------------------------------------------

  FileDiff _fileDiff(LoadFileDiff request) {
    final repo = _repository(request.repositoryPath);
    final root = repo.workTree;

    // A working-tree file is compared with HEAD, which is the comparison the
    // status column is showing and so the one a reader expects to see.
    final headId = repo.resolve('HEAD');
    final before = headId == null
        ? <int>[]
        : (repo.readFile(request.path, revision: 'HEAD') ?? <int>[]);

    List<int> after = const [];
    if (root != null) {
      final file = File(p.join(root, request.path.replaceAll('/', p.separator)));
      if (file.existsSync()) after = file.readAsBytesSync();
    }

    final diff = git.diffText(Uint8List.fromList(before), Uint8List.fromList(after));
    return _renderDiff(request.path, diff, 'HEAD and the working tree');
  }

  FileDiff _commitDiff(LoadCommitDiff request) {
    final repo = _repository(request.repositoryPath);
    final id = repo.resolve(request.commitId);
    if (id == null) throw StateError('${request.commitId} names nothing here');

    final change = repo
        .changesIn(id)
        .where((c) => c.path == request.path)
        .firstOrNull;
    if (change == null) {
      return FileDiff(
        path: request.path,
        hunks: const [],
        insertions: 0,
        deletions: 0,
        against: 'its first parent',
      );
    }

    final diff = repo.diffBlobs(change.oldId, change.newId);
    return _renderDiff(request.path, diff, 'its first parent');
  }

  FileDiff _renderDiff(String path, git.TextDiff diff, String against) {
    return FileDiff(
      path: path,
      isBinary: diff.isBinary,
      insertions: diff.insertions,
      deletions: diff.deletions,
      against: against,
      hunks: [
        for (final hunk in diff.hunks)
          DiffHunkData(hunk.header, [
            for (final line in hunk.lines)
              DiffLineData(
                switch (line.kind) {
                  git.LineKind.context => ' ',
                  git.LineKind.inserted => '+',
                  git.LineKind.deleted => '-',
                },
                line.text,
                line.oldLine,
                line.newLine,
              ),
          ]),
      ],
    );
  }

  // ---- history ------------------------------------------------------------

  List<CommitData> _history(LoadHistory request) {
    final repo = _repository(request.repositoryPath);
    final commits = <CommitData>[];

    for (final commit in repo.log(limit: request.limit)) {
      commits.add(_toData(commit));
    }
    return commits;
  }

  ({CommitData commit, List<ChangeData> changes}) _commit(LoadCommit request) {
    final repo = _repository(request.repositoryPath);
    final id = repo.resolve(request.commitId);
    if (id == null) throw StateError('${request.commitId} names nothing here');

    final commit = repo.objects.readTyped<git.Commit>(id);
    return (
      commit: _toData(commit),
      changes: [
        for (final change in repo.changesIn(id))
          ChangeData(
            path: change.path,
            oldPath: change.oldPath,
            state: _fromChange(change.kind),
            oldId: change.oldId?.hex,
            newId: change.newId?.hex,
          ),
      ],
    );
  }

  CommitData _toData(git.Commit commit) => CommitData(
        id: commit.id.hex,
        summary: commit.summary,
        message: commit.message,
        authorName: commit.author.name,
        authorEmail: commit.author.email,
        when: commit.author.utc,
        parents: commit.parents.map((p) => p.hex).toList(),
      );
}

// ---------------------------------------------------------------------------
// client
// ---------------------------------------------------------------------------

/// The main-isolate side of the worker.
class GitService {
  late final SendPort _toWorker;
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;

  Isolate? _isolate;
  ReceivePort? _inbox;

  Future<void> start() async {
    final ready = Completer<SendPort>();
    _inbox = ReceivePort();
    _inbox!.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      if (message is! _Reply) return;
      final completer = _pending.remove(message.id);
      if (completer == null) return;
      if (message.error != null) {
        completer.completeError(GitWorkerException(message.error!));
      } else {
        completer.complete(message.value);
      }
    });

    _isolate = await Isolate.spawn(gitWorkerMain, _inbox!.sendPort);
    _toWorker = await ready.future;
  }

  Future<T> _ask<T>(GitRequest request) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _toWorker.send(_Envelope(id, request));
    return completer.future.then((value) => value as T);
  }

  Future<RepositorySummary> open(String path, String name) =>
      _ask(OpenRepository(path, name));

  /// Looks at a folder without adding it, so the caller can ask before doing
  /// anything about what it finds.
  Future<RepositorySummary> inspect(String path) =>
      _ask(OpenRepository(path, p.basename(p.normalize(path))));

  Future<RepositorySummary> initialise(String path, String name) =>
      _ask(InitialiseRepository(path, name));

  Future<List<EntryData>> directory(
    String repository,
    Revision revision,
    String path,
  ) =>
      _ask(LoadDirectory(repository, revision, path));

  Future<FileContent> file(
    String repository,
    Revision revision,
    String path,
  ) =>
      _ask(LoadFile(repository, revision, path));

  Future<FileDiff> fileDiff(
    String repository,
    Revision revision,
    String path,
  ) =>
      _ask(LoadFileDiff(repository, revision, path));

  Future<List<CommitData>> history(String repository, {int limit = 100}) =>
      _ask(LoadHistory(repository, limit: limit));

  Future<({CommitData commit, List<ChangeData> changes})> commit(
    String repository,
    String commitId,
  ) =>
      _ask(LoadCommit(repository, commitId));

  Future<FileDiff> commitDiff(
    String repository,
    String commitId,
    String path,
  ) =>
      _ask(LoadCommitDiff(repository, commitId, path));

  Future<EntryData> writeFile({
    required String repository,
    required String path,
    required String contents,
    int? expectedSize,
    DateTime? expectedModified,
  }) =>
      _ask(WriteFile(
        repositoryPath: repository,
        path: path,
        contents: contents,
        expectedSize: expectedSize,
        expectedModified: expectedModified,
      ));

  Future<EntryData> createEntry({
    required String repository,
    required String path,
    required EntryKind kind,
  }) =>
      _ask(CreateEntry(repositoryPath: repository, path: path, kind: kind));

  /// Adds an ignore rule, returning the pattern written or null when an
  /// identical one was already there.
  Future<String?> ignore({
    required String repository,
    required String path,
    required bool isDirectory,
    bool alsoUntrack = false,
  }) =>
      _ask(IgnorePath(
        repositoryPath: repository,
        path: path,
        isDirectory: isDirectory,
        alsoUntrack: alsoUntrack,
      ));

  Future<int> trackedCount(String repository, String path) =>
      _ask(CountTracked(repository, path));

  Future<StagingArea> staging(String repository) =>
      _ask(LoadStaging(repository));

  Future<StagingArea> setStaged(
    String repository,
    String path, {
    required bool staged,
  }) =>
      _ask(SetStaged(repository, path, staged: staged));

  Future<CommitData> commitStaged(String repository, String message) =>
      _ask(CommitStaged(repository, message));

  Future<void> refresh(String repository) => _ask(Refresh(repository));

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _inbox?.close();
  }
}

class GitWorkerException implements Exception {
  final String message;
  const GitWorkerException(this.message);

  @override
  String toString() => message;
}
