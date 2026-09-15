/// Putting the demo repository into a browser that has none.
library;

import 'dart:typed_data';

import 'package:git_dart/git_dart.dart' as git;

import '../workspace.dart';

/// Unbundles [bundle] as a repository called [name], when the workspace holds
/// no repository at all. Returns whether it did.
///
/// Only into an empty workspace: the demo is a sandbox, and a visitor's own
/// commits live in the copy this made. Seeding on every load would throw them
/// away — resetting is the one thing that does that, and it asks first.
///
/// Called before [ExplorerState.start], so the repository is already in the
/// workspace when the app looks for what is there.
Future<bool> seedDemoRepository({
  required String name,
  required Future<Uint8List> Function() bundle,
}) async {
  if (knownWorkspaceRepositories().isNotEmpty) return false;

  final bytes = await bundle();
  final path = workspacePathFor(name);
  final repository = git.Repository.init(path);
  try {
    final result = git.unbundle(repository, bytes, writeRefs: true);
    final branch = _branchFor(result.refs);
    if (branch != null) {
      repository.refs.writeSymbolic('HEAD', branch);
      // Forced for the same reason a clone forces it: the index is empty, so
      // every file about to be written looks like a local deletion.
      repository.checkout(branch, force: true);
    }
  } catch (_) {
    repository.close();
    // Half a repository looks like a whole one until it is opened.
    await removeFromWorkspace(path);
    rethrow;
  }
  repository.close();

  trackWorkspaceRepository(path);
  await persistWorkspace();
  return true;
}

/// The branch to check out: the one the bundle's HEAD was on, as far as the
/// bundle can say — it records HEAD as a commit, not a name — and otherwise
/// the names git itself would look for.
String? _branchFor(Map<String, git.ObjectId> refs) {
  final branches = [
    for (final ref in refs.keys)
      if (ref.startsWith('refs/heads/')) ref,
  ];
  if (branches.isEmpty) return null;

  final head = refs['HEAD']?.hex;
  final atHead = [
    for (final branch in branches)
      if (head != null && refs[branch]!.hex == head) branch,
  ];
  for (final candidate in [...atHead, 'refs/heads/main', 'refs/heads/master']) {
    if (branches.contains(candidate)) return candidate;
  }
  return branches.first;
}
