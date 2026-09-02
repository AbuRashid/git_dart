/// Submodules: another repository, recorded as one entry in a tree.
///
/// A submodule is stored as a tree entry with mode `160000` holding a commit
/// name — a *gitlink*. That commit is not in this repository and never will
/// be, which is why every walk here steps over mode `160000` rather than
/// following it (`objects.modes-in-a-tree`). The entry says only "at this
/// path there is another repository, and it should be at this commit".
///
/// Everything else about a submodule lives outside the object model:
/// `.gitmodules` says where to clone it from, and whether it has been cloned
/// at all is a question about the working tree. Reading a repository that has
/// submodules therefore means joining three sources, and a caller that reads
/// only the tree sees an unexplained empty directory.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

import '../config/git_config.dart';
import '../fs/git_fs.dart';
import '../object_id.dart';
import '../objects/tree.dart';
import '../repository.dart';

/// Where a submodule's checkout stands against what the tree records.
enum SubmoduleState {
  /// `.gitmodules` describes it but nothing has been cloned.
  notInitialised,

  /// Cloned, and sitting at the commit the tree names.
  current,

  /// Cloned, and sitting at some other commit — the usual state while
  /// someone is working inside it.
  moved,

  /// A gitlink with no entry in `.gitmodules`. Legal, and means nobody can
  /// clone it: the tree knows the commit and nothing knows the URL.
  undescribed,
}

/// One submodule, from all three places that describe it.
class Submodule {
  /// The name `.gitmodules` gives the section, which is conventionally the
  /// path but is not required to be.
  final String name;

  /// Where it sits in the tree, with forward slashes.
  final String path;

  /// Where to clone it from, or null when only the gitlink is known.
  final String? url;

  /// The branch to follow, when one was configured.
  final String? branch;

  /// The commit the tree says it should be at, or null when `.gitmodules`
  /// describes a submodule the tree does not actually hold.
  final ObjectId? recorded;

  /// The commit its checkout is actually at, when it has one.
  final ObjectId? checkedOut;

  final SubmoduleState state;

  const Submodule({
    required this.name,
    required this.path,
    required this.state,
    this.url,
    this.branch,
    this.recorded,
    this.checkedOut,
  });

  bool get isInitialised =>
      state == SubmoduleState.current || state == SubmoduleState.moved;

  /// The one-character status git prints before the name: a space when it is
  /// where it should be, `-` when nothing is cloned, `+` when it has moved.
  String get statusSigil => switch (state) {
        SubmoduleState.current => ' ',
        SubmoduleState.notInitialised => '-',
        SubmoduleState.moved => '+',
        SubmoduleState.undescribed => '-',
      };

  @override
  String toString() =>
      '$statusSigil${recorded?.hex ?? '?' * ObjectId.hexLength} $path';
}

/// The submodules of [repository], as of [at] or HEAD.
///
/// Joins the gitlinks in the tree with what `.gitmodules` says and with what
/// is on disk. A gitlink with no description and a description with no gitlink
/// are both reported rather than dropped: each is a real state a repository
/// can be in, and each explains something a caller would otherwise see as a
/// contradiction.
List<Submodule> submodulesOf(Repository repository, {ObjectId? at}) {
  final described = _describedSubmodules(repository, at: at);
  final gitlinks = _gitlinksIn(repository, at: at);

  final paths = <String>{...described.keys, ...gitlinks.keys}.toList()..sort();

  return [
    for (final path in paths)
      () {
        final description = described[path];
        final recorded = gitlinks[path];
        final checkedOut = _checkedOutCommit(repository, path);

        final state = description == null
            ? SubmoduleState.undescribed
            : checkedOut == null
                ? SubmoduleState.notInitialised
                : checkedOut == recorded
                    ? SubmoduleState.current
                    : SubmoduleState.moved;

        return Submodule(
          name: description?.name ?? path,
          path: path,
          url: description?.url,
          branch: description?.branch,
          recorded: recorded,
          checkedOut: checkedOut,
          state: state,
        );
      }(),
  ];
}

/// Opens a submodule's own repository, or null when it has not been cloned.
///
/// A submodule's git directory is usually not inside its working tree: git
/// keeps it under `.git/modules/<name>` and leaves a `.git` *file* pointing
/// there, so that removing the checkout does not destroy the history. The
/// discovery this library already does for a `.git` file handles both
/// arrangements.
Repository? openSubmodule(Repository repository, Submodule submodule) {
  final workTree = repository.workTree;
  if (workTree == null) return null;

  final directory = p.join(
    workTree,
    submodule.path.replaceAll('/', p.separator),
  );
  if (!_holdsARepository(directory)) return null;

  return Repository.discover(directory);
}

/// Whether a repository lives at exactly this directory.
///
/// The check has to be for `.git` *here*, not for a repository anywhere above:
/// discovery searches upwards, so an empty submodule directory would otherwise
/// resolve to the repository containing it — and a submodule nobody has cloned
/// would report itself as checked out at the outer repository's HEAD. Found
/// exactly that way, from a fresh clone claiming its submodule had moved.
bool _holdsARepository(String directory) {
  if (!fs.directory(directory).existsSync()) return false;
  final marker = p.join(directory, '.git');
  // A directory for an ordinary repository, a file for a submodule or a
  // worktree, which points at where the real git directory lives.
  return fs.directory(marker).existsSync() || fs.file(marker).existsSync();
}

/// What `.gitmodules` says, by path.
Map<String, ({String name, String? url, String? branch})>
    _describedSubmodules(Repository repository, {ObjectId? at}) {
  final text = _gitmodulesText(repository, at: at);
  if (text == null) return const {};

  final config = GitConfig.parse(text);
  final byName = <String, ({String? path, String? url, String? branch})>{};

  for (final entry in config.entries.entries) {
    // `submodule.<name>.<key>`, where the name may itself contain dots — so
    // the first and last segments are fixed and everything between is a name.
    final parts = entry.key.split('.');
    if (parts.length < 3 || parts.first != 'submodule') continue;
    final key = parts.last;
    final name = parts.sublist(1, parts.length - 1).join('.');
    final value = entry.value.last;

    final existing =
        byName[name] ?? (path: null, url: null, branch: null);
    byName[name] = (
      path: key == 'path' ? value : existing.path,
      url: key == 'url' ? value : existing.url,
      branch: key == 'branch' ? value : existing.branch,
    );
  }

  return {
    for (final entry in byName.entries)
      if (entry.value.path case final path?)
        path: (name: entry.key, url: entry.value.url, branch: entry.value.branch),
  };
}

/// `.gitmodules` as of a commit, falling back to the working tree.
///
/// The committed copy is the right answer when a commit was named, and the
/// working tree's is the right answer for "what is here now" — a submodule
/// added and not yet committed exists only there.
String? _gitmodulesText(Repository repository, {ObjectId? at}) {
  final from = at ?? repository.headId;
  if (from != null) {
    final tree = repository.treeOf(from);
    if (tree != null) {
      final entry = repository.lookup(tree, '.gitmodules');
      if (entry != null && !entry.mode.isTree) {
        final raw = repository.objects.readRaw(entry.id);
        if (raw != null) {
          // Decoded leniently: `.gitmodules` is committed content and
          // nothing guarantees it is valid UTF-8.
          return utf8.decode(raw.content, allowMalformed: true);
        }
      }
    }
  }

  if (at != null) return null;

  final workTree = repository.workTree;
  if (workTree == null) return null;
  final file = fs.file(p.join(workTree, '.gitmodules'));
  return file.existsSync() ? file.readAsStringSync() : null;
}

/// Every gitlink in the tree, by path.
Map<String, ObjectId> _gitlinksIn(Repository repository, {ObjectId? at}) {
  final from = at ?? repository.headId;
  if (from == null) return const {};
  final tree = repository.treeOf(from);
  if (tree == null) return const {};

  final out = <String, ObjectId>{};

  void walk(Tree tree, String prefix) {
    for (final entry in tree.entries) {
      final path = '$prefix${entry.name}';
      if (entry.mode.isSubmodule) {
        out[path] = entry.id;
        continue;
      }
      if (!entry.mode.isTree) continue;
      final raw = repository.objects.readRaw(entry.id);
      if (raw == null) continue; // promised, or past a shallow boundary
      walk(repository.objects.readTyped<Tree>(entry.id), '$path/');
    }
  }

  walk(tree, '');
  return out;
}

/// The commit a submodule's checkout is actually on.
ObjectId? _checkedOutCommit(Repository repository, String path) {
  final workTree = repository.workTree;
  if (workTree == null) return null;

  final directory = p.join(workTree, path.replaceAll('/', p.separator));
  if (!_holdsARepository(directory)) return null;

  final inner = Repository.discover(directory);
  if (inner == null) return null;
  try {
    return inner.headId;
  } finally {
    inner.close();
  }
}
