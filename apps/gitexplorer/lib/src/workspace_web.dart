/// The browser workspace: repositories in memory, kept in OPFS.
///
/// git_dart reads through a filesystem and a browser has none, so one lives in
/// memory here and every repository is a subtree of it. OPFS is where that
/// memory is written back to, one file per repository — OPFS charges per
/// operation and a repository has thousands of objects, so a directory tree
/// would cost thousands of round trips to save.
///
/// The in-memory paths are not locations. `/repos/<name>` is a name the app
/// gives a repository so that git_dart has something to open; nothing outside
/// this process can see it.
library;

import 'package:git_dart/git_dart.dart' as git;
import 'package:path/path.dart' as p;

import 'web_http_client.dart';
import 'import_outcome.dart';

/// The one filesystem every repository lives inside.
///
/// Shared because [git.useGitFileSystem] is global: git_dart reads through one
/// filesystem at a time, so two repositories are two subtrees rather than two
/// filesystems.
final git.MemoryGitFs _memory = git.MemoryGitFs();

/// Where a repository's own bytes are kept, by its in-memory path.
final Map<String, git.OpfsStore> _stores = {};

const String _rootName = '/repos';

/// The absolute form of [_rootName].
///
/// `Repository.init` and `clone` both call `p.absolute` on the path they are
/// given, and on the web that turns a rooted path into one qualified with the
/// page's own origin — `/repos/x` becomes `http://host/repos/x`. Computing the
/// root the same way here, once, is what keeps a path this file hands out and
/// the path git_dart reports back as `workTree` the same string, which is what
/// lets a repository be found again by the name it was given. Missed once: a
/// clone's own path did not match the one this file expected, and the
/// repository it had just made could not be tracked to save.
final String _root = p.absolute(_rootName);

/// Where in OPFS a repository called [name] is kept.
git.OpfsStore _storeFor(String name) => git.OpfsStore('repositories/$name');

Future<void> prepareWorkspace() async {
  git.useGitFileSystem(_memory);
  // Nothing answers a fetch or a clone without this: git_dart's own web
  // platform file refuses on purpose, since whether a request can even be
  // made is a question about CORS only the application can answer.
  installWebHttpClient();
  _canImport = await git.canPickDirectory;

  // Everything stored, read back at startup. A repository has to be in memory
  // before git_dart can open it, and there is nowhere else to read it from.
  for (final name in await const git.OpfsStore('repositories').list()) {
    final path = workspacePathFor(name);
    final store = _storeFor(name);
    _stores[path] = store;
    await store.load(under: path, into: _memory);
  }
}

/// There are no folders here, so a repository is cloned rather than picked.
const bool repositoriesAreInternal = true;

String workspacePathFor(String name) => p.join(_root, name);

/// Registers a repository that was just created, so it will be written back.
///
/// Called by whatever added it; until a repository is known here, changes to
/// it stay in memory and are lost on reload.
void trackWorkspaceRepository(String path) {
  final prefix = '$_root/';
  final name = path.startsWith(prefix) ? path.substring(prefix.length) : path;
  _stores[path] = _storeFor(name);
}

Future<void> persistWorkspace() async {
  if (!_memory.hasChanges) return;

  // Which repositories the changes fall under. A save rewrites a repository
  // whole, so one that nothing touched is skipped rather than rewritten.
  final touched = <String>{};
  for (final changed in [..._memory.changedPaths, ..._memory.deletedPaths]) {
    for (final path in _stores.keys) {
      final base = _normalise(path);
      if (changed == base || changed.startsWith('$base/')) touched.add(path);
    }
  }

  for (final path in touched) {
    await _stores[path]!.saveAll(_memory, under: path);
  }

  // Anything left is outside every repository — a temporary file, say — and
  // is not worth carrying into the next session.
  _memory.markClean();
}

/// Set once, in [prepareWorkspace].
bool _canImport = false;
bool get canImportRepository => _canImport;

/// Asks for a folder and brings it in, the way [trackWorkspaceRepository]
/// brings in a clone: registered before the persist that follows, since a
/// repository not yet known here is a repository the first save has nothing
/// to save it under.
Future<ImportOutcome?> importPickedRepository() async {
  String? name;
  final path = await git.pickDirectoryInto(_memory, (folderName) {
    name = _availableName(folderName);
    return workspacePathFor(name!);
  });
  if (path == null) return null;

  if (git.Repository.discover(path) == null) {
    // Not a repository at all - rolled back so a bad pick does not linger as
    // a phantom empty folder holding a name nothing can now use.
    _memory.directory(path).deleteSync(recursive: true);
    return ImportOutcome.failure('$name has no .git in it');
  }

  trackWorkspaceRepository(path);
  await persistWorkspace();
  return ImportOutcome.success(path, name);
}

/// [name], or [name]-2, [name]-3 and so on until one is not already taken.
String _availableName(String name) {
  if (!_memory.directory(workspacePathFor(name)).existsSync()) return name;
  var suffix = 2;
  while (_memory.directory(workspacePathFor('$name-$suffix')).existsSync()) {
    suffix += 1;
  }
  return '$name-$suffix';
}

List<({String path, String name})> knownWorkspaceRepositories() => [
      for (final path in _stores.keys)
        (path: path, name: path.substring(_root.length + 1)),
    ];

Future<void> removeFromWorkspace(String path) async {
  final store = _stores.remove(path);
  if (store != null) await store.delete();

  // The subtree goes too, so a repository added again under the same name
  // does not find the old one still in memory.
  final directory = _memory.directory(path);
  if (directory.existsSync()) directory.deleteSync(recursive: true);
  _memory.markClean();
}

String _normalise(String path) => path
    .replaceAll(r'\', '/')
    .split('/')
    .where((segment) => segment.isNotEmpty && segment != '.')
    .join('/');
