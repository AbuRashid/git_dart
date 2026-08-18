import 'dart:typed_data';

import 'generated/tokens.dart';

/// What a repository is being looked at.
///
/// The working tree is one choice among several rather than the only one,
/// which is what makes this an explorer of a repository rather than of a
/// folder (`revisions`).
class Revision {
  final RevisionKind kind;

  /// The branch name or commit name; null for the working tree and HEAD.
  final String? value;

  const Revision(this.kind, [this.value]);

  static const workingTree = Revision(RevisionKind.workingTree);
  static const head = Revision(RevisionKind.head);

  /// What git_dart should resolve, or null when the files on disk are wanted.
  String? get revisionString => switch (kind) {
        RevisionKind.workingTree => null,
        RevisionKind.head => 'HEAD',
        RevisionKind.branch => value,
        RevisionKind.commit => value,
      };

  String get label => switch (kind) {
        RevisionKind.workingTree => 'Working tree',
        RevisionKind.head => 'HEAD',
        RevisionKind.branch => value ?? '',
        RevisionKind.commit => (value ?? '').substring(0, 8),
      };

  @override
  bool operator ==(Object other) =>
      other is Revision && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// One row in the tree.
class EntryData {
  final String name;

  /// The path within the repository, forward slashes, '' for the root.
  final String path;

  final EntryKind kind;
  final FileState state;

  /// Null for a directory, and for a file whose size was not asked for.
  final int? size;

  /// The blob or tree name, when the entry came from a tree rather than from
  /// disk.
  final String? objectId;

  const EntryData({
    required this.name,
    required this.path,
    required this.kind,
    this.state = FileState.clean,
    this.size,
    this.objectId,
  });
}

/// A repository as the tree's top level shows it.
class RepositorySummary {
  final String path;
  final String name;

  /// False when the path no longer holds a repository. Kept in the list
  /// rather than dropped (`persistence.a-missing-repository-is-kept`).
  final bool available;

  /// Why, when it is not available. Structured rather than a message, because
  /// the answer decides what the application offers to do about it — and only
  /// one of the reasons has anything to offer.
  final UnavailableReason? reason;

  /// The underlying failure, for a reader who wants the detail.
  final String? error;

  final String? branch;
  final bool detached;
  final String? headId;
  final String? headSummary;
  final DateTime? headWhen;
  final String? headAuthor;

  final int changedCount;
  final int untrackedCount;

  final List<String> branches;
  final List<String> tags;

  const RepositorySummary({
    required this.path,
    required this.name,
    this.available = true,
    this.reason,
    this.error,
    this.branch,
    this.detached = false,
    this.headId,
    this.headSummary,
    this.headWhen,
    this.headAuthor,
    this.changedCount = 0,
    this.untrackedCount = 0,
    this.branches = const [],
    this.tags = const [],
  });

  RepositorySummary unavailable(UnavailableReason reason, [String? detail]) =>
      RepositorySummary(
        path: path,
        name: name,
        available: false,
        reason: reason,
        error: detail,
      );

  bool get isClean => changedCount == 0 && untrackedCount == 0;

  /// Whether the application can offer to create a repository here.
  bool get canInitialise =>
      !available && (reason?.offersInitialising ?? false);
}

/// One setting as it stands: what is in force, and where it came from.
class SettingValue {
  final String key;

  /// Null when nothing sets it, in which case git''s own default applies —
  /// which is said in words rather than shown as though it were set.
  final String? value;

  /// The index of ConfigScope, or null when unset.
  final int? scope;
  final String? scopeLabel;

  const SettingValue({
    required this.key,
    this.value,
    this.scope,
    this.scopeLabel,
  });

  bool get isSet => value != null;
}

/// A remote, and where the current branch stands against it.
class RemoteData {
  final String name;
  final String url;

  /// True when the URL names a directory on this machine, which can be
  /// fetched by reading it rather than over a protocol.
  final bool isLocal;

  /// True when this build can fetch from the URL at all.
  final bool canFetch;

  /// The tracking ref this remote holds for the current branch, if it has one.
  final String? trackingRef;

  /// How the current branch stands against that ref, as of the last fetch.
  /// Null when there is no tracking ref, or when the history was too large to
  /// count.
  final int? ahead;
  final int? behind;

  /// True when a tracking ref exists but the count was not attempted.
  final bool tooLargeToCount;

  /// True when this repository holds no copy of anything from this remote —
  /// it has never fetched from it. Different from "the remote has no such
  /// branch", and the two want different advice.
  final bool neverFetched;

  const RemoteData({
    required this.name,
    required this.url,
    this.isLocal = false,
    this.canFetch = true,
    this.trackingRef,
    this.ahead,
    this.behind,
    this.tooLargeToCount = false,
    this.neverFetched = false,
  });

  bool get hasCounts => ahead != null && behind != null;
  bool get isEven => ahead == 0 && behind == 0;
}

/// What a push did.
class PushOutcome {
  final String remote;
  final int objectsSent;

  /// True when the remote wants credentials. The caller asks the user and
  /// tries again rather than treating it as a failure.
  final bool needsCredentials;

  /// True when a secret was sent and refused, rather than never sent — the
  /// difference between "sign in" and "that was wrong".
  final bool wereRejected;

  /// The name to offer in the prompt, from the URL or from what was saved.
  final String? username;

  /// Whether a credential helper is configured, and so whether the secret
  /// can be saved at all.
  final bool canSave;

  /// Refs that moved, as `refs/heads/main abc1234..def5678`.
  final List<String> updated;

  /// Refs the remote would not take, with its reason.
  final List<String> rejected;

  final String? error;

  const PushOutcome({
    required this.remote,
    this.objectsSent = 0,
    this.updated = const [],
    this.rejected = const [],
    this.error,
    this.needsCredentials = false,
    this.wereRejected = false,
    this.username,
    this.canSave = false,
  });

  bool get ok => error == null && rejected.isEmpty && !needsCredentials;

  /// True when the push was refused only because it would not fast-forward,
  /// which is the case worth offering to force.
  bool get canForce =>
      error == null && rejected.any((r) => r.contains('fast-forward'));
}

/// What a fetch did.
/// What a clone did, or why it did not.
///
/// Credentials are asked for the same way a fetch asks: a clone is a fetch
/// with a repository made for it, and a server that wants a token wants one at
/// the same point.
class CloneOutcome {
  /// Where the repository was put. Null when nothing was made.
  final String? path;

  /// The branch checked out, short-named.
  final String? branch;

  final int objectsReceived;

  /// True when the remote had no refs, so the clone is an empty repository.
  final bool remoteWasEmpty;

  final bool needsCredentials;
  final bool wereRejected;
  final String? username;
  final bool canSave;

  final String? error;

  const CloneOutcome({
    this.path,
    this.branch,
    this.objectsReceived = 0,
    this.remoteWasEmpty = false,
    this.needsCredentials = false,
    this.wereRejected = false,
    this.username,
    this.canSave = false,
    this.error,
  });

  bool get succeeded => path != null && error == null && !needsCredentials;
}

class FetchOutcome {
  final String remote;
  final int objectsReceived;

  /// True when the remote wants credentials.
  final bool needsCredentials;
  final bool wereRejected;
  final String? username;
  final bool canSave;

  /// Refs that moved, as `refs/remotes/origin/main abc1234..def5678`.
  final List<String> updated;

  final String? error;

  const FetchOutcome({
    required this.remote,
    this.objectsReceived = 0,
    this.updated = const [],
    this.error,
    this.needsCredentials = false,
    this.wereRejected = false,
    this.username,
    this.canSave = false,
  });

  bool get isEmpty => updated.isEmpty && error == null;
}

/// What a pull did: the fetch, then the merge.
class PullOutcome {
  final String remote;
  final FetchOutcome fetch;

  /// Null when the fetch failed or wanted credentials, so nothing was merged.
  final String? mergeOutcome;
  final List<String> conflicts;
  final String? mergedCommit;
  final String? error;

  const PullOutcome({
    required this.remote,
    required this.fetch,
    this.mergeOutcome,
    this.conflicts = const [],
    this.mergedCommit,
    this.error,
  });

  bool get ok => error == null && conflicts.isEmpty;
}

/// Where a branch stands against the ref it tracks.
class TrackingData {
  final String branch;
  final String? upstream;
  final int ahead;
  final int behind;

  const TrackingData({
    required this.branch,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
  });

  bool get hasUpstream => upstream != null;
  bool get isEven => ahead == 0 && behind == 0;
}

/// One path's place in the staging area.
///
/// Both halves, because a file can be staged one way and modified again since,
/// and the only honest presentation of that is the same file in both lists
/// (`committing.why-the-index-is-shown`).
class StatusRow {
  final String path;

  /// HEAD against the index: what a commit would record.
  final FileState? staged;

  /// The index against the working tree: what is not staged.
  final FileState? unstaged;

  final bool isUntracked;
  final bool isConflicted;

  const StatusRow({
    required this.path,
    this.staged,
    this.unstaged,
    this.isUntracked = false,
    this.isConflicted = false,
  });

  bool get canStage => unstaged != null || isUntracked || isConflicted;
  bool get canUnstage => staged != null;
}

/// What the staging area holds right now.
class StagingArea {
  final List<StatusRow> rows;

  /// The identity a commit would be attributed to, or null when none is
  /// configured — in which case committing is refused rather than guessed
  /// (`committing.identity-comes-from-the-config`).
  final String? identity;

  const StagingArea({required this.rows, this.identity});

  List<StatusRow> get staged => [for (final r in rows) if (r.canUnstage) r];
  List<StatusRow> get notStaged => [for (final r in rows) if (r.canStage) r];

  bool get hasStagedChanges => staged.isNotEmpty;
  bool get hasConflicts => rows.any((r) => r.isConflicted);
  bool get isEmpty => rows.isEmpty;
}

class CommitData {
  final String id;
  final String summary;
  final String message;
  final String authorName;
  final String authorEmail;
  final DateTime when;
  final List<String> parents;

  const CommitData({
    required this.id,
    required this.summary,
    required this.message,
    required this.authorName,
    required this.authorEmail,
    required this.when,
    required this.parents,
  });

  String get shortId => id.substring(0, 8);
  bool get isMerge => parents.length > 1;
}

/// One path changed by a commit, or by the working tree.
class ChangeData {
  final String path;
  final String? oldPath;
  final FileState state;
  final String? oldId;
  final String? newId;

  const ChangeData({
    required this.path,
    required this.state,
    this.oldPath,
    this.oldId,
    this.newId,
  });
}

class FileContent {
  final String path;
  final int size;
  final bool isBinary;

  /// When the file on disk was last written, for a working-tree file. Carried
  /// back on a save so a write that would overwrite someone else's is refused
  /// (`editing.a-stale-write-is-refused`).
  final DateTime? modified;

  /// Null when the file was too large to load, or binary.
  final String? text;

  /// Set when the file was not loaded, saying why.
  final String? notLoaded;

  const FileContent({
    required this.path,
    required this.size,
    required this.isBinary,
    this.modified,
    this.text,
    this.notLoaded,
  });

  /// Whether this content can be edited: it must be text that was actually
  /// loaded, and it must have come from the working tree.
  bool get isEditable => text != null && !isBinary && modified != null;
}

/// A rendered diff: the hunks of one file, already turned into lines the UI
/// can draw without knowing anything about diffs.
class DiffLineData {
  /// ' ', '+' or '-'.
  final String marker;
  final String text;
  final int? oldLine;
  final int? newLine;

  const DiffLineData(this.marker, this.text, this.oldLine, this.newLine);
}

class DiffHunkData {
  final String header;
  final List<DiffLineData> lines;
  const DiffHunkData(this.header, this.lines);
}

class FileDiff {
  final String path;
  final List<DiffHunkData> hunks;
  final int insertions;
  final int deletions;
  final bool isBinary;

  /// What was compared, in words, because a diff with no label invites the
  /// reader to assume the wrong pair.
  final String against;

  const FileDiff({
    required this.path,
    required this.hunks,
    required this.insertions,
    required this.deletions,
    required this.against,
    this.isBinary = false,
  });

  bool get isEmpty => hunks.isEmpty && !isBinary;
}

/// Raw bytes of a blob, for the cases the UI wants to handle itself.
class BlobBytes {
  final Uint8List bytes;
  const BlobBytes(this.bytes);
}
