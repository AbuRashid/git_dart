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
import 'dart:typed_data';

import 'package:git_dart/git_dart.dart' as git;
import 'package:path/path.dart' as p;

import 'credential_store.dart';
import 'generated/tokens.dart';
import 'models.dart';
import 'worker_transport.dart';
import 'workspace.dart';

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

class LoadBlame extends GitRequest {
  final String repositoryPath;
  final Revision revision;
  final String path;
  const LoadBlame(this.repositoryPath, this.revision, this.path);
}

class LoadSubmodule extends GitRequest {
  final String repositoryPath;
  final Revision revision;
  final String path;
  const LoadSubmodule(this.repositoryPath, this.revision, this.path);
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

class LoadRemotes extends GitRequest {
  final String repositoryPath;
  const LoadRemotes(this.repositoryPath);
}

class AddRemote extends GitRequest {
  final String repositoryPath;
  final String name;
  final String url;
  const AddRemote(this.repositoryPath, this.name, this.url);
}

class RemoveRemote extends GitRequest {
  final String repositoryPath;
  final String name;
  const RemoveRemote(this.repositoryPath, this.name);
}

/// Copies a remote repository into a new folder.
class CloneRepository extends GitRequest {
  final String url;

  /// Where the working tree goes: a folder that does not exist yet, or an
  /// empty one.
  final String path;

  /// Supplied after the user was asked; null means "use whatever is saved".
  final String? username;
  final String? password;
  final bool remember;

  const CloneRepository(
    this.url,
    this.path, {
    this.username,
    this.password,
    this.remember = false,
  });
}

class FetchRemote extends GitRequest {
  final String repositoryPath;
  final String name;

  /// Supplied after the user was asked; null means "use whatever is saved".
  final String? username;
  final String? password;

  /// Whether a secret that works should be handed to the credential helper.
  final bool remember;

  const FetchRemote(
    this.repositoryPath,
    this.name, {
    this.username,
    this.password,
    this.remember = false,
  });
}

class PullRemote extends GitRequest {
  final String repositoryPath;
  final String name;
  final String? username;
  final String? password;
  final bool remember;

  const PullRemote(
    this.repositoryPath,
    this.name, {
    this.username,
    this.password,
    this.remember = false,
  });
}

class PushRemote extends GitRequest {
  final String repositoryPath;
  final String name;

  /// Overwrites a remote branch that has commits the pushed one does not.
  /// Asked for explicitly, never assumed.
  final bool force;

  final String? username;
  final String? password;
  final bool remember;

  const PushRemote(
    this.repositoryPath,
    this.name, {
    this.force = false,
    this.username,
    this.password,
    this.remember = false,
  });
}

class RenameBranch extends GitRequest {
  final String repositoryPath;
  final String from;
  final String to;
  const RenameBranch(this.repositoryPath, this.from, this.to);
}

class DeleteBranch extends GitRequest {
  final String repositoryPath;
  final String name;
  const DeleteBranch(this.repositoryPath, this.name);
}

/// Everything the settings screen shows: the value in force for each key it
/// knows, and which file it came from.
class LoadSettings extends GitRequest {
  final String repositoryPath;
  final List<String> keys;
  const LoadSettings(this.repositoryPath, this.keys);
}

/// Writes or clears one setting.
class WriteSetting extends GitRequest {
  final String repositoryPath;
  final String key;

  /// Null clears it, so whatever a wider scope says applies again.
  final String? value;

  /// 0 system, 1 global, 2 local — the index of ConfigScope, since the enum
  /// itself lives in the library.
  final int scope;

  const WriteSetting(this.repositoryPath, this.key, this.value, this.scope);
}

/// Drops cached state so the next question is answered from disk.
class Refresh extends GitRequest {
  final String repositoryPath;
  const Refresh(this.repositoryPath);
}

/// A request with the number its reply will carry.
///
/// Public because it crosses the transport boundary, and the transport is
/// chosen per platform: an isolate where there is one, and a direct call in a
/// browser, which has no isolates to spawn.
class WorkerEnvelope {
  final int id;
  final GitRequest request;
  const WorkerEnvelope(this.id, this.request);
}

class WorkerReply {
  final int id;
  final Object? value;
  final String? error;
  const WorkerReply(this.id, this.value, this.error);
}

/// Commentary on a request that is still being worked out - a clone or a
/// fetch, waiting on a network. Zero or more of these precede the
/// [WorkerReply] for the same [id].
class WorkerProgress {
  final int id;
  final String message;
  const WorkerProgress(this.id, this.message);
}

// ---------------------------------------------------------------------------
// the worker
// ---------------------------------------------------------------------------

/// Everything git_dart is asked to do, in one place.
///
/// Holds the open repositories, so a second question about the same repository
/// does not pay to reopen it — which on a large one means reading every pack
/// index again (`concurrency.why-a-worker-and-not-a-call-per-operation`).
///
/// Public so that a platform without isolates can run it in place. Nothing
/// here knows how it was reached.
class GitWorker {
  final _repositories = <String, git.Repository>{};
  final _statuses = <String, Map<String, FileState>>{};

  Object? handle(GitRequest request, {void Function(String)? onProgress}) =>
      switch (request) {
        OpenRepository() => _open(request),
        InitialiseRepository() => _initialise(request),
        WriteFile() => _write(request),
        CreateEntry() => _create(request),
        RenameBranch() => _renameBranch(request),
        DeleteBranch() => _deleteBranch(request),
        LoadSettings() => _settings(request),
        WriteSetting() => _writeSetting(request),
        LoadRemotes() => _remotes(request),
        AddRemote() => _addRemote(request),
        RemoveRemote() => _removeRemote(request),
        CloneRepository() => _clone(request, onProgress: onProgress),
        FetchRemote() => _fetch(request, onProgress: onProgress),
        PushRemote() => _push(request, onProgress: onProgress),
        PullRemote() => _pull(request, onProgress: onProgress),
        IgnorePath() => _ignore(request),
        CountTracked() => _countTracked(request),
        LoadStaging() => _staging(request),
        SetStaged() => _setStaged(request),
        CommitStaged() => _writeCommit(request),
        LoadDirectory() => _directory(request),
        LoadFile() => _file(request),
        LoadFileDiff() => _fileDiff(request),
        LoadBlame() => _blame(request),
        LoadSubmodule() => _submodule(request),
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

    if (!git.gitFs.directory(request.path).existsSync()) {
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
    if (git.gitFs.file(request.path).existsSync()) {
      throw StateError('${request.path} is a file, not a folder');
    }
    final directory = git.gitFs.directory(request.path);
    if (!directory.existsSync()) {
      // A folder the desktop picker returned always exists, so this path
      // means one of two different things depending on where it is asked
      // from. In a browser there was never anything to pick - a name typed
      // for a brand new repository is the whole request, and creating the
      // storage is the point. On the desktop the same absence means a folder
      // that has gone missing since it was added - an unmounted drive, most
      // likely - and silently making a new empty one in its place would
      // replace a question the user needs to see ("where did my repository
      // go?") with an answer that is simply wrong.
      if (!repositoriesAreInternal) {
        throw StateError('${request.path} is not there to initialise');
      }
      directory.createSync(recursive: true);
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

  // ---- branches -----------------------------------------------------------

  RepositorySummary _renameBranch(RenameBranch request) {
    final repo = _repository(request.repositoryPath);
    repo.renameBranch(request.from, request.to);
    _statuses.remove(request.repositoryPath);
    return _open(OpenRepository(
      request.repositoryPath,
      p.basename(p.normalize(request.repositoryPath)),
    ));
  }

  RepositorySummary _deleteBranch(DeleteBranch request) {
    final repo = _repository(request.repositoryPath);
    repo.deleteBranch(request.name);
    return _open(OpenRepository(
      request.repositoryPath,
      p.basename(p.normalize(request.repositoryPath)),
    ));
  }

  // ---- settings -----------------------------------------------------------

  List<SettingValue> _settings(LoadSettings request) {
    final repo = _repository(request.repositoryPath);
    final writer = git.ConfigWriter(repo.gitDirectory);

    return [
      for (final key in request.keys)
        () {
          final origin = writer.origin(key);
          return SettingValue(
            key: key,
            value: origin?.value,
            scope: origin?.scope.index,
            scopeLabel: origin?.scope.label,
          );
        }(),
    ];
  }

  List<SettingValue> _writeSetting(WriteSetting request) {
    final repo = _repository(request.repositoryPath);
    final writer = git.ConfigWriter(repo.gitDirectory);
    final scope = git.ConfigScope.values[request.scope];

    if (request.value == null || request.value!.isEmpty) {
      writer.unset(request.key, scope);
    } else {
      writer.set(request.key, request.value!, scope);
    }

    // The repository caches its config, and a setting just changed.
    repo.reloadConfig();
    _statuses.remove(request.repositoryPath);
    return _settings(LoadSettings(request.repositoryPath, [request.key]));
  }

  // ---- remotes ------------------------------------------------------------

  /// Ahead/behind counts, kept by the pair of commits they describe.
  ///
  /// Counting walks both histories, so it is not something to redo on every
  /// rebuild. The key is the two tips: when either moves the answer is
  /// recomputed, and when neither has, it cannot have changed.
  final _divergence = <String, ({int ahead, int behind})?>{};

  List<RemoteData> _remotes(LoadRemotes request) {
    final repo = _repository(request.repositoryPath);
    final branch = repo.refs.currentBranch?.replaceFirst('refs/heads/', '');
    final localTip = branch == null ? null : repo.refs.resolve('refs/heads/$branch');

    return [
      for (final remote in repo.remotes.list())
        () {
          final canFetch = remote.isLocal ||
              remote.url.startsWith('http://') ||
              remote.url.startsWith('https://');

          // The tracking ref for the branch that is checked out, which is
          // what the counts are about.
          final trackingRef = branch == null
              ? null
              : remote.trackingRefFor('refs/heads/$branch');
          final remoteTip =
              trackingRef == null ? null : repo.refs.resolve(trackingRef);

          if (localTip == null || remoteTip == null) {
            // Nothing under refs/remotes/<name> at all means this repository
            // has never fetched from it — which is a different situation from
            // the remote not having this branch, and wants different advice.
            final anyTracking = repo.refs
                .list(prefix: 'refs/remotes/${remote.name}/')
                .isNotEmpty;
            return RemoteData(
              name: remote.name,
              url: remote.url,
              isLocal: remote.isLocal,
              canFetch: canFetch,
              trackingRef: remoteTip == null ? null : trackingRef,
              neverFetched: !anyTracking,
            );
          }

          final key = '${localTip.hex}:${remoteTip.hex}';
          // The pair of tips is the whole key, so entries for tips that have
          // moved on are dead weight rather than wrong. Cleared wholesale
          // when there are enough of them to notice.
          if (_divergence.length > 64) _divergence.clear();
          final counts = _divergence.containsKey(key)
              ? _divergence[key]
              : _divergence[key] = () {
                  final measured = repo.countAheadBehind(localTip, remoteTip);
                  return measured == null
                      ? null
                      : (ahead: measured.ahead, behind: measured.behind);
                }();

          return RemoteData(
            name: remote.name,
            url: remote.url,
            isLocal: remote.isLocal,
            canFetch: canFetch,
            trackingRef: trackingRef,
            ahead: counts?.ahead,
            behind: counts?.behind,
            tooLargeToCount: counts == null,
          );
        }(),
    ];
  }

  List<RemoteData> _addRemote(AddRemote request) {
    _repository(request.repositoryPath)
        .remotes
        .add(request.name, request.url);
    return _remotes(LoadRemotes(request.repositoryPath));
  }

  List<RemoteData> _removeRemote(RemoveRemote request) {
    _repository(request.repositoryPath).remotes.remove(request.name);
    return _remotes(LoadRemotes(request.repositoryPath));
  }

  final _credentials = CredentialStore();

  /// The `user@` part of a URL, when it has one and can be parsed at all.
  static String? _usernameIn(String url) {
    if (!url.startsWith('http://') && !url.startsWith('https://')) return null;
    return git.splitCredentials(url).credentials?.username;
  }

  /// The secret to try: what the user just typed, else what is saved.
  Future<git.Credentials?> _credentialsFor(
    String url,
    String? username,
    String? password,
  ) async {
    // Only http(s) has anywhere to put them. An ssh-style `git@host:path` is
    // not even a URL — parsing one throws — so it is turned away here rather
    // than deeper in.
    if (!url.startsWith('http://') && !url.startsWith('https://')) return null;
    if (username != null && password != null) {
      return git.Credentials(username: username, password: password);
    }
    return _credentials.lookup(url);
  }

  /// Clones, reporting the same way a fetch does.
  ///
  /// A clone is the one network operation with no repository to ask about
  /// first, so the credentials are looked up against the URL itself.
  Future<CloneOutcome> _clone(
    CloneRepository request, {
    void Function(String)? onProgress,
  }) async {
    final credentials = await _credentialsFor(
      request.url,
      request.username,
      request.password,
    );

    try {
      final result = await git.clone(
        request.url,
        request.path,
        credentials: credentials,
        onProgress: onProgress,
      );
      if (credentials != null && request.remember) {
        await _credentials.save(request.url, credentials);
      }
      return CloneOutcome(
        path: result.path,
        branch: result.branchName,
        objectsReceived: result.objectsReceived,
        remoteWasEmpty: result.remoteWasEmpty,
      );
    } on git.AuthenticationRequired catch (needed) {
      if (needed.wereRejected && credentials != null) {
        await _credentials.discard(request.url, credentials);
      }
      return CloneOutcome(
        needsCredentials: true,
        wereRejected: needed.wereRejected,
        username: credentials?.username ?? _usernameIn(request.url),
        canSave: await _credentials.canSave(),
        error: needed.toString(),
      );
    } catch (error) {
      // A URL that is wrong, a host that is down, a folder that is taken: all
      // are answers to give the user rather than crashes.
      return CloneOutcome(error: '$error');
    }
  }

  Future<FetchOutcome> _fetch(
    FetchRemote request, {
    void Function(String)? onProgress,
  }) async {
    final repo = _repository(request.repositoryPath);
    final remote = repo.remotes.named(request.name);
    if (remote == null) {
      return FetchOutcome(
        remote: request.name,
        error: 'there is no remote named ${request.name}',
      );
    }

    final credentials = await _credentialsFor(
      remote.url,
      request.username,
      request.password,
    );

    try {
      final result = await git.fetch(
        repo,
        remote,
        credentials: credentials,
        onProgress: onProgress,
      );
      _statuses.remove(request.repositoryPath);
      if (credentials != null && request.remember) {
        await _credentials.save(remote.url, credentials);
      }
      return FetchOutcome(
        remote: request.name,
        objectsReceived: result.objectsReceived,
        updated: [for (final update in result.changed) update.toString()],
      );
    } on git.AuthenticationRequired catch (needed) {
      // A saved secret that the server refused is dropped, or the next
      // attempt fails the same way with the same token.
      if (needed.wereRejected && credentials != null) {
        await _credentials.discard(remote.url, credentials);
      }
      return FetchOutcome(
        remote: request.name,
        needsCredentials: true,
        wereRejected: needed.wereRejected,
        username: credentials?.username ?? _usernameIn(remote.url),
        canSave: await _credentials.canSave(),
        error: needed.toString(),
      );
    } catch (error) {
      // A remote that is unreachable, or speaks a protocol this build does
      // not, is an outcome rather than a crash.
      return FetchOutcome(remote: request.name, error: '$error');
    }
  }

  /// Fetch, then merge what arrived — which is what a pull has always been.
  Future<PullOutcome> _pull(
    PullRemote request, {
    void Function(String)? onProgress,
  }) async {
    final fetched = await _fetch(
      FetchRemote(
        request.repositoryPath,
        request.name,
        username: request.username,
        password: request.password,
        remember: request.remember,
      ),
      onProgress: onProgress,
    );

    if (fetched.error != null || fetched.needsCredentials) {
      return PullOutcome(remote: request.name, fetch: fetched);
    }

    final repo = _repository(request.repositoryPath);
    final remote = repo.remotes.named(request.name);
    final branch = repo.refs.currentBranch?.replaceFirst('refs/heads/', '');
    if (remote == null || branch == null) {
      return PullOutcome(
        remote: request.name,
        fetch: fetched,
        error: 'there is no branch checked out to merge into',
      );
    }

    final tracking = remote.trackingRefFor('refs/heads/$branch');
    if (tracking == null || repo.refs.resolve(tracking) == null) {
      return PullOutcome(
        remote: request.name,
        fetch: fetched,
        error: '${request.name} has no copy of $branch to merge',
      );
    }

    try {
      final merged = await git.mergeTrackingRef(repo, tracking);
      _statuses.remove(request.repositoryPath);
      return PullOutcome(
        remote: request.name,
        fetch: fetched,
        mergeOutcome: merged.outcome.name,
        conflicts: merged.conflicts,
        mergedCommit: merged.commit?.hex,
      );
    } catch (error) {
      return PullOutcome(
        remote: request.name,
        fetch: fetched,
        error: '$error',
      );
    }
  }

  Future<PushOutcome> _push(
    PushRemote request, {
    void Function(String)? onProgress,
  }) async {
    final repo = _repository(request.repositoryPath);
    final remote = repo.remotes.named(request.name);
    if (remote == null) {
      return PushOutcome(
        remote: request.name,
        error: 'there is no remote named ${request.name}',
      );
    }

    final credentials = await _credentialsFor(
      remote.pushUrl,
      request.username,
      request.password,
    );

    try {
      final result = await git.push(
        repo,
        remote,
        force: request.force,
        credentials: credentials,
        onProgress: onProgress,
      );
      if (credentials != null && request.remember) {
        await _credentials.save(remote.pushUrl, credentials);
      }
      return PushOutcome(
        remote: request.name,
        objectsSent: result.objectsSent,
        updated: [
          for (final status in result.statuses)
            if (status.ok) status.toString(),
        ],
        rejected: [
          for (final status in result.rejected) status.toString(),
        ],
      );
    } on git.AuthenticationRequired catch (needed) {
      if (needed.wereRejected && credentials != null) {
        await _credentials.discard(remote.pushUrl, credentials);
      }
      return PushOutcome(
        remote: request.name,
        needsCredentials: true,
        wereRejected: needed.wereRejected,
        username: credentials?.username ?? _usernameIn(remote.pushUrl),
        canSave: await _credentials.canSave(),
        error: needed.toString(),
      );
    } catch (error) {
      return PushOutcome(remote: request.name, error: '$error');
    }
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
    final file = git.gitFs.file(absolute);

    if (git.gitFs.directory(absolute).existsSync()) {
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

    if (git.gitFs.file(absolute).existsSync() ||
        git.gitFs.directory(absolute).existsSync()) {
      throw StateError('${request.path} already exists');
    }

    if (request.kind == EntryKind.directory) {
      // Every directory on the way, so `a/b/c` is one action rather than three
      // (`editing.directories-are-created-in-full`).
      git.gitFs.directory(absolute).createSync(recursive: true);
    } else {
      git.gitFs.file(absolute)
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
    final directory = git.gitFs.directory(
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

      if (entry is git.GitFsDirectory) {
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
          size: entry is git.GitFsFile ? entry.lengthSync() : null,
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
      final file = git.gitFs.file(
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
      final file =
          git.gitFs.file(p.join(root, request.path.replaceAll('/', p.separator)));
      if (file.existsSync()) after = file.readAsBytesSync();
    }

    final diff = git.diffText(Uint8List.fromList(before), Uint8List.fromList(after));
    return _renderDiff(request.path, diff, 'HEAD and the working tree');
  }

  BlameData _blame(LoadBlame request) {
    final repo = _repository(request.repositoryPath);

    // Blame has no notion of a working tree - there is nothing to walk
    // backwards from until something is committed - so viewing it blames
    // HEAD, the way the file diff above compares the working tree against
    // HEAD rather than against nothing.
    final target = request.revision.revisionString;
    final at = target == null ? repo.headId : repo.resolve(target);
    if (at == null) {
      return BlameData(
        path: request.path,
        at: null,
        lines: const [],
        unavailable: 'there is nothing committed yet',
      );
    }

    // Checked before the walk, not after: blame on a large binary file would
    // still finish, having spent the whole walk on lines nobody can read.
    final bytes = repo.readFile(request.path, revision: at.hex);
    if (bytes != null && git.looksBinary(Uint8List.fromList(bytes))) {
      return BlameData(
        path: request.path,
        at: at.hex,
        lines: const [],
        unavailable: 'this is a binary file',
      );
    }

    final result = git.blame(repo, request.path, start: at);
    if (result == null) {
      return BlameData(
        path: request.path,
        at: at.hex,
        lines: const [],
        unavailable: 'this file is not present at this revision',
      );
    }

    return BlameData(
      path: result.path,
      at: result.at.hex,
      lines: [
        for (final line in result.lines)
          BlameLineData(
            number: line.number,
            text: line.text,
            commitId: line.commit.hex,
            // Already resolved through .mailmap by git_dart itself, so this
            // reads the same as `git blame` does on the same repository.
            authorName: line.author.name,
            authorWhen: line.author.utc,
            summary: line.summary,
            originalNumber: line.originalNumber,
          ),
      ],
    );
  }

  SubmoduleData _submodule(LoadSubmodule request) {
    final repo = _repository(request.repositoryPath);

    // Null stays null: `submodulesOf` already treats "no commit named" as
    // HEAD's tree joined with whatever `.gitmodules` says on disk right now,
    // which is the working-tree view this app wants when no revision is
    // chosen. A named revision that fails to resolve is a different case -
    // there is no tree to read gitlinks from at all - and is reported rather
    // than silently falling back to the working tree.
    final target = request.revision.revisionString;
    git.ObjectId? at;
    if (target != null) {
      at = repo.resolve(target);
      if (at == null) {
        return SubmoduleData(
          path: request.path,
          name: request.path,
          status: SubmoduleStatus.undescribed,
          unavailable: '$target names nothing here',
        );
      }
    }

    final found = git
        .submodulesOf(repo, at: at)
        .where((submodule) => submodule.path == request.path)
        .firstOrNull;
    if (found == null) {
      return SubmoduleData(
        path: request.path,
        name: request.path,
        status: SubmoduleStatus.undescribed,
        unavailable: 'no submodule is recorded at this path',
      );
    }

    // Only offered once something is actually there to open: a submodule
    // nobody has cloned has nothing behind its path but the gitlink.
    String? openableAt;
    final workTree = repo.workTree;
    if (found.checkedOut != null && workTree != null) {
      openableAt = p.join(workTree, found.path.replaceAll('/', p.separator));
    }

    return SubmoduleData(
      path: found.path,
      name: found.name,
      url: found.url,
      branch: found.branch,
      recordedCommit: found.recorded?.hex,
      checkedOutCommit: found.checkedOut?.hex,
      status: switch (found.state) {
        git.SubmoduleState.notInitialised => SubmoduleStatus.notInitialised,
        git.SubmoduleState.current => SubmoduleStatus.current,
        git.SubmoduleState.moved => SubmoduleStatus.moved,
        git.SubmoduleState.undescribed => SubmoduleStatus.undescribed,
      },
      openableAt: openableAt,
    );
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
  final WorkerTransport _transport = newWorkerTransport();

  Future<void> start() => _transport.start();

  Future<T> _ask<T>(
    GitRequest request, {
    void Function(T value)? beforePersist,
    void Function(String)? onProgress,
  }) async {
    final value =
        await _transport.send(request, onProgress: onProgress) as T;
    // A repository that did not exist before this call has to be registered
    // before the persist below, or the very first save after creating one
    // finds nothing to save it under - which is what silently dropped a
    // fresh clone on reload the first time this ran.
    beforePersist?.call(value);
    // Where a repository is a folder, this reaches disk already and there is
    // nothing to do. In a browser it is the only path back to OPFS, so it
    // runs after every call rather than only the ones known to write -
    // forgetting one here would mean silently losing whatever it did.
    await persistWorkspace();
    return value;
  }

  Future<RepositorySummary> open(String path, String name) =>
      _ask(OpenRepository(path, name));

  /// Looks at a folder without adding it, so the caller can ask before doing
  /// anything about what it finds.
  Future<RepositorySummary> inspect(String path) =>
      _ask(OpenRepository(path, p.basename(p.normalize(path))));

  Future<RepositorySummary> initialise(String path, String name) =>
      _ask<RepositorySummary>(
        InitialiseRepository(path, name),
        // As with a clone: a repository that did not exist a moment ago has
        // to be registered before the persist that follows, or the save
        // finds nothing to save it under.
        beforePersist: (_) => trackWorkspaceRepository(path),
      );

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

  Future<BlameData> blame(
    String repository,
    Revision revision,
    String path,
  ) =>
      _ask(LoadBlame(repository, revision, path));

  Future<SubmoduleData> submodule(
    String repository,
    Revision revision,
    String path,
  ) =>
      _ask(LoadSubmodule(repository, revision, path));

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

  Future<RepositorySummary> renameBranch(
    String repository,
    String from,
    String to,
  ) =>
      _ask(RenameBranch(repository, from, to));

  Future<RepositorySummary> deleteBranch(String repository, String name) =>
      _ask(DeleteBranch(repository, name));

  Future<List<SettingValue>> settings(
    String repository,
    List<String> keys,
  ) =>
      _ask(LoadSettings(repository, keys));

  Future<List<SettingValue>> writeSetting(
    String repository,
    String key,
    String? value,
    int scope,
  ) =>
      _ask(WriteSetting(repository, key, value, scope));

  Future<List<RemoteData>> remotes(String repository) =>
      _ask(LoadRemotes(repository));

  Future<List<RemoteData>> addRemote(
    String repository,
    String name,
    String url,
  ) =>
      _ask(AddRemote(repository, name, url));

  Future<List<RemoteData>> removeRemote(String repository, String name) =>
      _ask(RemoveRemote(repository, name));

  Future<CloneOutcome> cloneRepository(
    String url,
    String path, {
    String? username,
    String? password,
    bool remember = false,
    void Function(String)? onProgress,
  }) =>
      _ask<CloneOutcome>(
        CloneRepository(
          url,
          path,
          username: username,
          password: password,
          remember: remember,
        ),
        beforePersist: (outcome) {
          if (outcome.succeeded) trackWorkspaceRepository(outcome.path!);
        },
        onProgress: onProgress,
      );

  Future<FetchOutcome> fetchRemote(
    String repository,
    String name, {
    String? username,
    String? password,
    bool remember = false,
    void Function(String)? onProgress,
  }) =>
      _ask(
        FetchRemote(
          repository,
          name,
          username: username,
          password: password,
          remember: remember,
        ),
        onProgress: onProgress,
      );

  Future<PullOutcome> pullRemote(
    String repository,
    String name, {
    String? username,
    String? password,
    bool remember = false,
    void Function(String)? onProgress,
  }) =>
      _ask(
        PullRemote(
          repository,
          name,
          username: username,
          password: password,
          remember: remember,
        ),
        onProgress: onProgress,
      );

  Future<PushOutcome> pushRemote(
    String repository,
    String name, {
    bool force = false,
    String? username,
    String? password,
    bool remember = false,
    void Function(String)? onProgress,
  }) =>
      _ask(
        PushRemote(
          repository,
          name,
          force: force,
          username: username,
          password: password,
          remember: remember,
        ),
        onProgress: onProgress,
      );

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

  void dispose() => _transport.dispose();
}

class GitWorkerException implements Exception {
  final String message;
  const GitWorkerException(this.message);

  @override
  String toString() => message;
}
