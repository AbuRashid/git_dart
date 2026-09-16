// GENERATED FILE — DO NOT EDIT.
//
// Written by tool/generate_tokens.dart from specs/explorer.umsg.
// Edit that document and re-run the tool; the build checks
// this file against it.
//
// Vocabulary only. Colours, sizes and type come from Material,
// not from here (`presentation.doc`).

/// What a row in the tree is (`entry-kinds`).
enum EntryKind {
  /// a repository the user added
  repository(expands: true),
  /// a tree, or a directory on disk
  directory(expands: true),
  /// a blob, or a file on disk
  file(expands: false),
  /// a commit belonging to another store
  submodule(expands: false);

  const EntryKind({required this.expands});

  /// Whether the row can be opened to reveal children.
  final bool expands;
}

/// A path's state (`status-vocabulary`).
enum FileState {
  /// matches the index and HEAD
  clean(code: '', shown: false),
  /// differs from the index
  modified(code: 'M', shown: true),
  /// in the index, not in HEAD
  added(code: 'A', shown: true),
  /// gone from the working tree
  deleted(code: 'D', shown: true),
  /// the same content under a new path
  renamed(code: 'R', shown: true),
  /// file, symlink, submodule or directory swapped
  typechange(code: 'T', shown: true),
  /// in neither the index nor HEAD
  untracked(code: '?', shown: true),
  /// more than one stage in the index
  conflicted(code: 'U', shown: true),
  /// matched by an ignore rule
  ignored(code: '!', shown: false);

  const FileState({required this.code, required this.shown});

  /// The letter shown in the status column.
  final String code;

  /// Whether a row in this state is marked at all.
  final bool shown;
}

/// What a repository is being viewed at (`revisions.choices`).
enum RevisionKind {
  /// the files on disk
  workingTree(hasStatus: true, editable: true),
  /// the tree HEAD points at
  head(hasStatus: false, editable: false),
  /// the tree at a branch's tip
  branch(hasStatus: false, editable: false),
  /// the tree at any commit
  commit(hasStatus: false, editable: false);

  const RevisionKind({
    required this.hasStatus,
    required this.editable,
  });

  /// Only the working tree is compared with anything, so only
  /// it has a status column.
  final bool hasStatus;

  /// Only the working tree can be edited: the others are views
  /// of objects, and an object cannot be edited.
  final bool editable;
}

/// Which scheme the window uses
/// (`presentation.theme-choices`).
enum ThemeChoice {
  /// whatever the platform says
  system,
  /// the light scheme, always
  light,
  /// the dark scheme, always
  dark;
}

/// Why a chosen folder could not be opened
/// (`initialising.unavailable-reasons`).
enum UnavailableReason {
  missing(says: 'the folder is not there', offersInitialising: false),
  notARepository(says: 'the folder holds no repository yet', offersInitialising: true),
  unreadable(says: 'the repository could not be read', offersInitialising: false);

  const UnavailableReason({
    required this.says,
    required this.offersInitialising,
  });

  /// What to tell the user.
  final String says;

  /// Whether creating a repository here is offered.
  final bool offersInitialising;
}

/// The version written into the persisted repository list
/// (`persistence.version`).
const int persistedStateVersion = 1;
