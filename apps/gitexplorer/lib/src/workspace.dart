/// Getting the platform ready to hold repositories.
///
/// On the desktop there is nothing to do: the repositories are folders and the
/// filesystem is the one underneath. In a browser neither is true — there is no
/// folder to point at and no filesystem to read — so a repository lives in
/// memory, backed by OPFS, and every path the app uses is a name inside it.
library;

export 'import_outcome.dart' show ImportOutcome;

import 'import_outcome.dart';
import 'workspace_io.dart'
    if (dart.library.js_interop) 'workspace_web.dart' as impl;

/// Prepares storage. Called once, before anything opens a repository.
Future<void> prepareWorkspace() => impl.prepareWorkspace();

/// Whether repositories live inside the app rather than on a disk the user
/// can point at.
///
/// Decides how a repository is added: by picking a folder where there are
/// folders, and by cloning where there are not.
bool get repositoriesAreInternal => impl.repositoriesAreInternal;

/// The path a repository called [name] should live at.
///
/// A real folder is its own answer; in a browser this is a name in the
/// in-memory filesystem, and the caller has no say in it.
String workspacePathFor(String name) => impl.workspacePathFor(name);

/// Whether this platform can offer to bring in a folder the user already has.
///
/// Decided once, during [prepareWorkspace] - the browser's own capabilities
/// do not change while the tab is open, so there is nothing to gain by asking
/// again each time a menu is drawn, and a plain bool is what a widget's build
/// method can read without needing to be asynchronous itself.
bool get canImportRepository => impl.canImportRepository;

/// Asks the user to pick a folder and copies it into the workspace,
/// registering and saving it exactly like any other repository here.
///
/// Returns null when the user cancelled the picker - nothing to report, since
/// declining is not a failure. A name that collides with one already present
/// is resolved by appending a number, the same way a duplicate download does,
/// rather than overwriting something that might still be wanted.
Future<ImportOutcome?> importPickedRepository() => impl.importPickedRepository();

/// Notes that a repository now exists at [path], so it will be written back.
///
/// A no-op where a repository is a folder: the disk already knows.
void trackWorkspaceRepository(String path) =>
    impl.trackWorkspaceRepository(path);

/// Writes back anything that changed, where that is not automatic.
///
/// A no-op on a real filesystem, where a write has already reached the disk.
Future<void> persistWorkspace() => impl.persistWorkspace();

/// Every repository already known to this workspace, path and name.
///
/// Empty where a repository is a folder: the desktop has no list of its own
/// to offer, since a folder is only ever added by being chosen. In a browser
/// this is what makes a repository that already exists in OPFS - however it
/// got there - show up without a separate "import" step: OPFS is the app's
/// own storage, not a filesystem it is a guest on, so there is nothing to ask
/// permission for.
List<({String path, String name})> knownWorkspaceRepositories() =>
    impl.knownWorkspaceRepositories();

/// Forgets a repository's stored copy.
Future<void> removeFromWorkspace(String path) => impl.removeFromWorkspace(path);
