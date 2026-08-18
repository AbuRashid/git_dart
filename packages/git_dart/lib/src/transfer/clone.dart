import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../object_id.dart';
import '../objects/commit.dart';
import '../remote/remote.dart';
import '../repository.dart';
import 'credentials.dart';
import 'fetch.dart';

/// What a clone left on disk.
class CloneResult {
  /// Where the repository is: the working tree, or the git directory when bare.
  final String path;

  /// The branch checked out, as a full ref. Null when the remote had nothing
  /// to check out, or when [bare].
  final String? branch;

  final int objectsReceived;
  final bool bare;

  /// True when the remote advertised no refs at all, so there is a repository
  /// here but no history in it yet.
  final bool remoteWasEmpty;

  const CloneResult({
    required this.path,
    required this.objectsReceived,
    required this.bare,
    this.branch,
    this.remoteWasEmpty = false,
  });

  /// The branch's short name, for saying what was checked out.
  String? get branchName => branch == null
      ? null
      : (branch!.startsWith('refs/heads/')
          ? branch!.substring('refs/heads/'.length)
          : branch);
}

/// Thrown when the destination cannot be cloned into.
///
/// Separate from the transport's failures: nothing has been asked of the
/// network when this is raised, and the answer is to choose somewhere else.
class CloneDestinationException implements Exception {
  final String path;
  final String message;

  const CloneDestinationException(this.path, this.message);

  @override
  String toString() => 'cannot clone into $path: $message';
}

/// Copies the repository at [url] into [path].
///
/// This is init, fetch, and checkout in that order — the three operations this
/// library already had, in the arrangement that is what "clone" has always
/// meant. It is written here rather than left to the caller because the parts
/// that are easy to get wrong are the joins: which branch the remote considers
/// its own, that the local branch has to be created before HEAD can point at
/// it, and that a failure halfway through should not leave half a repository
/// behind (`transfer.cloning`).
///
/// The destination must not exist, or must be an empty directory. A clone that
/// wrote into a directory with files in it could not be told apart afterwards
/// from a repository that had always been there.
Future<CloneResult> clone(
  String url,
  String path, {
  String remoteName = 'origin',
  bool bare = false,
  Credentials? credentials,
  void Function(String message)? onProgress,
  String sshCommand = 'ssh',
}) async {
  final destination = p.absolute(path);
  final directory = fs.directory(destination);

  // Refuse before anything is created, so the checks and the cleanup below
  // cannot disagree about what this clone made.
  final existed = directory.existsSync();
  if (existed && directory.listSync().isNotEmpty) {
    throw CloneDestinationException(destination, 'it is not empty');
  }
  if (fs.file(destination).existsSync()) {
    throw CloneDestinationException(destination, 'it is a file');
  }

  var finished = false;
  Repository? repository;
  try {
    repository = Repository.init(destination, bare: bare);
    repository.remotes.add(remoteName, url);
    final remote = repository.remotes.named(remoteName)!;

    final fetched = await fetch(
      repository,
      remote,
      credentials: credentials,
      onProgress: onProgress,
      sshCommand: sshCommand,
    );

    final result = _adopt(repository, remote, fetched, bare, destination);
    finished = true;
    return result;
  } finally {
    repository?.close();
    // A clone that failed leaves nothing: a half-written repository is worse
    // than none, because it looks like one until it is opened.
    if (!finished) {
      try {
        if (existed) {
          for (final entry in fs.directory(destination).listSync()) {
            entry.deleteSync(recursive: true);
          }
        } else if (fs.directory(destination).existsSync()) {
          fs.directory(destination).deleteSync(recursive: true);
        }
      } on GitFsException {
        // The clone already failed; failing to tidy up is not the report the
        // caller needs, and the original error is on its way out.
      }
    }
  }
}

/// Points the new repository at what arrived: HEAD, a local branch, and the
/// working tree.
CloneResult _adopt(
  Repository repository,
  Remote remote,
  FetchResult fetched,
  bool bare,
  String destination,
) {
  final heads = {
    for (final entry in fetched.advertised.entries)
      if (entry.key.startsWith('refs/heads/')) entry.key: entry.value,
  };

  if (heads.isEmpty) {
    // An empty remote is a normal thing to clone: git leaves HEAD on an unborn
    // branch and says so, and the first commit here will start that branch.
    return CloneResult(
      path: destination,
      objectsReceived: fetched.objectsReceived,
      bare: bare,
      remoteWasEmpty: true,
    );
  }

  final branch = _branchToAdopt(heads.keys, fetched.defaultBranch);
  final tip = _tipFor(repository, remote, branch, heads);

  if (tip == null) {
    // Advertised but not stored: the refspec did not map it, which is a
    // configuration this function did not create and should not paper over.
    return CloneResult(
      path: destination,
      objectsReceived: fetched.objectsReceived,
      bare: bare,
    );
  }

  repository.refs.write(branch, tip, reflogMessage: 'clone: from ${remote.url}');
  repository.refs.writeSymbolic('HEAD', branch);
  repository.setUpstream(
    branch.substring('refs/heads/'.length),
    remote.name,
    branch,
  );

  if (!bare && repository.peel(tip) is Commit) {
    // Forced, because HEAD now names the branch while the index is still
    // empty, so every file about to be written looks like a local deletion to
    // the safety check. There is nothing to protect: the destination was
    // refused unless empty, and everything in it arrived from this clone.
    repository.checkout(branch, force: true);
  }

  return CloneResult(
    path: destination,
    objectsReceived: fetched.objectsReceived,
    bare: bare,
    branch: branch,
  );
}

/// Which branch the clone should be on.
///
/// What the remote's HEAD names, when it said so. Servers that cannot say fall
/// back to the names git itself would look for, and then to whatever single
/// branch exists — which is the common case for a repository with one branch
/// under a name neither list knows.
String _branchToAdopt(Iterable<String> heads, String? defaultBranch) {
  if (defaultBranch != null && heads.contains(defaultBranch)) {
    return defaultBranch;
  }
  for (final candidate in const ['refs/heads/main', 'refs/heads/master']) {
    if (heads.contains(candidate)) return candidate;
  }
  return heads.first;
}

/// The commit the new branch starts at, read from where the fetch stored it.
///
/// The tracking ref rather than the advertisement: the advertisement says what
/// the remote has, and the tracking ref says what arrived here.
ObjectId? _tipFor(
  Repository repository,
  Remote remote,
  String branch,
  Map<String, ObjectId> heads,
) {
  final tracking = remote.trackingRefFor(branch);
  if (tracking != null) {
    final stored = repository.refs.resolve(tracking);
    if (stored != null) return stored;
  }
  final advertised = heads[branch];
  return advertised != null && repository.objects.contains(advertised)
      ? advertised
      : null;
}
