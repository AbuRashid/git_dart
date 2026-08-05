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
