/// The desktop workspace: the filesystem the machine already has.
library;

Future<void> prepareWorkspace() async {}

/// Repositories are folders the user picked, and they are theirs.
const bool repositoriesAreInternal = false;

String workspacePathFor(String name) =>
    throw UnsupportedError('a repository here is a folder the user chooses');

/// The disk already knows where the repository is.
void trackWorkspaceRepository(String path) {}

/// Writing a file has already reached the disk.
Future<void> persistWorkspace() async {}

const bool canImportRepository = false;

Future<Never> importPickedRepository() async => throw UnsupportedError(
      'importing a picked folder only applies on the web; open the folder '
      'directly here instead',
    );

/// Nothing to offer: a folder is only ever added by being chosen.
List<({String path, String name})> knownWorkspaceRepositories() => const [];

/// Removing a repository from the list must not delete the user's folder.
Future<void> removeFromWorkspace(String path) async {}
