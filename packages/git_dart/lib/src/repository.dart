import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'config/git_config.dart';
import 'diff/text_diff.dart';
import 'diff/tree_diff.dart';
import 'index/git_index.dart';
import 'object_id.dart';
import 'objects/commit.dart';
import 'objects/git_object.dart';
import 'objects/identity.dart';
import 'objects/tag.dart';
import 'objects/tree.dart';
import 'refs/ref_store.dart';
import 'storage/object_store.dart';
import 'worktree/checkout.dart';
import 'worktree/ignore.dart';
import 'worktree/status.dart';

/// A repository: an object store, a ref namespace over it, and — unless bare —
/// an index and a working tree.
class Repository {
  /// The `.git` directory, or the repository itself when bare.
  final String gitDirectory;

  /// The working tree root, or null for a bare repository.
  final String? workTree;

  final ObjectStore objects;
  final RefStore refs;

  Repository._({
    required this.gitDirectory,
    required this.workTree,
    required this.objects,
    required this.refs,
  });

  /// Opens the repository containing [path], searching upwards.
  ///
  /// Throws when there is none — a caller that wants to test should use
  /// [discover], which returns null.
  factory Repository.open(String path) {
    final found = Repository.discover(path);
    if (found == null) {
      throw ArgumentError.value(path, 'path', 'not inside a git repository');
    }
    return found;
  }

  /// The repository containing [path], or null.
  static Repository? discover(String path) {
    var directory = Directory(p.absolute(path));
    while (true) {
      final candidate = p.join(directory.path, '.git');
      // A `.git` directory that holds no repository is not one: an abandoned
      // or half-created directory must be walked past, not opened. Found by
      // reporting 1242 untracked files in a directory git said was not a
      // repository at all.
      if (_looksLikeGitDirectory(candidate)) {
        return Repository.at(candidate, workTree: directory.path);
      }
      if (File(candidate).existsSync()) {
        // A `.git` file rather than a directory: a worktree or a submodule
        // points at its real git directory this way.
        final text = File(candidate).readAsStringSync().trim();
        if (text.startsWith('gitdir:')) {
          final target = text.substring(7).trim();
          final resolved =
              p.isAbsolute(target) ? target : p.join(directory.path, target);
          return Repository.at(resolved, workTree: directory.path);
        }
      }
      // A bare repository is its own git directory.
      if (_looksLikeGitDirectory(directory.path)) {
        return Repository.at(directory.path, workTree: null);
      }
      final parent = directory.parent;
      if (parent.path == directory.path) return null;
      directory = parent;
    }
  }

  /// git's own test for a git directory: HEAD, an object store and a ref
  /// namespace. The three things a repository is.
  static bool _looksLikeGitDirectory(String path) =>
      File(p.join(path, 'HEAD')).existsSync() &&
      Directory(p.join(path, 'objects')).existsSync() &&
      Directory(p.join(path, 'refs')).existsSync();

  /// Opens a known git directory without searching.
  factory Repository.at(String gitDirectory, {String? workTree}) {
    return Repository._(
      gitDirectory: gitDirectory,
      workTree: workTree,
      objects: ObjectStore.open(p.join(gitDirectory, 'objects')),
      refs: RefStore(gitDirectory),
    );
  }

  bool get isBare => workTree == null;

  GitConfig? _config;

  /// The repository's config merged over the user's. Read once and kept: it
  /// is consulted on every status, and a file read per call would be the
  /// slowest thing in the loop.
  GitConfig get config => _config ??= GitConfig.forRepository(gitDirectory);

  /// Forgets the cached [config], for a caller that has just changed it.
  void reloadConfig() => _config = null;

  void close() => objects.close();

  // ---- reading ------------------------------------------------------------

  /// The index, re-read on each access because another process may have
  /// staged something since. Null in a bare repository, and before the first
  /// `add` in any repository.
  GitIndex? get index => GitIndex.open(p.join(gitDirectory, 'index'));

  ObjectId? get headId => refs.resolve('HEAD');

  Commit? get headCommit {
    final id = headId;
    return id == null ? null : objects.readTyped<Commit>(id);
  }

  /// Resolves a revision to an object name.
  ///
  /// Accepts `HEAD`, a full ref path, a branch or tag short name, a full
  /// object name or an unambiguous abbreviation of one, each optionally
  /// followed by the navigation suffixes: `~n` walks first parents, `^n`
  /// takes the nth parent, and `^{kind}` peels to a kind. Returns null when
  /// nothing matches — including when an abbreviation matches more than one
  /// object, since a wrong object is worse than no object.
  ObjectId? resolve(String revision) {
    final suffix = RegExp(r'[\^~]').firstMatch(revision);
    if (suffix == null) return _resolveName(revision);

    var id = _resolveName(revision.substring(0, suffix.start));
    if (id == null) return null;

    var rest = revision.substring(suffix.start);
    final operation = RegExp(r'^(?:\^\{(\w*)\}|\^(\d*)|~(\d*))');
    while (rest.isNotEmpty) {
      final match = operation.firstMatch(rest);
      if (match == null) return null;
      rest = rest.substring(match.end);

      final peelTo = match.group(1);
      if (peelTo != null) {
        id = _peelTo(id!, peelTo);
      } else if (match.group(2) != null) {
        final n = match.group(2)!.isEmpty ? 1 : int.parse(match.group(2)!);
        // `^0` is the commit itself, which is how a tag is peeled without
        // naming a kind.
        if (n == 0) {
          id = _peelTo(id!, 'commit');
        } else {
          final commit = _asCommit(id!);
          if (commit == null || commit.parents.length < n) return null;
          id = commit.parents[n - 1];
        }
      } else {
        final n = match.group(3)!.isEmpty ? 1 : int.parse(match.group(3)!);
        for (var i = 0; i < n; i++) {
          final commit = _asCommit(id!);
          if (commit == null || commit.parents.isEmpty) return null;
          id = commit.parents.first;
        }
      }
      if (id == null) return null;
    }
    return id;
  }

  Commit? _asCommit(ObjectId id) {
    if (!objects.contains(id)) return null;
    final object = peel(id);
    return object is Commit ? object : null;
  }

  /// `^{}` peels a tag until it reaches something that is not one; a named
  /// kind additionally follows a commit to its tree.
  ObjectId? _peelTo(ObjectId id, String kind) {
    if (!objects.contains(id)) return null;
    final object = peel(id);
    if (kind.isEmpty) return object.id;
    if (kind == 'tree' && object is Commit) return object.tree;
    return object.kind.name == kind ? object.id : null;
  }

  ObjectId? _resolveName(String revision) {
    for (final candidate in [
      revision,
      'refs/$revision',
      'refs/heads/$revision',
      'refs/tags/$revision',
      'refs/remotes/$revision',
      'refs/remotes/$revision/HEAD',
    ]) {
      final id = refs.resolve(candidate);
      if (id != null) return id;
    }

    final hex = revision.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{4,40}$').hasMatch(hex)) return null;
    if (hex.length == ObjectId.hexLength) {
      final id = ObjectId.fromHex(hex);
      return objects.contains(id) ? id : null;
    }

    ObjectId? match;
    for (final id in objects.listAll()) {
      if (!id.hex.startsWith(hex)) continue;
      if (match != null && match != id) return null; // ambiguous
      match = id;
    }
    return match;
  }

  /// Follows a tag to the object it ultimately points at. A tag of a tag is
  /// legal, so this loops.
  GitObject peel(ObjectId id) {
    var object = objects.read(id);
    while (object is Tag) {
      object = objects.read(object.target);
    }
    return object;
  }

  /// The tree of whatever [id] names — a commit's tree, a tree itself, or the
  /// tree of the commit a tag points at.
  Tree? treeOf(ObjectId id) {
    final object = peel(id);
    return switch (object) {
      Tree tree => tree,
      Commit commit => objects.readTyped<Tree>(commit.tree),
      _ => null,
    };
  }

  /// Walks [path] from [tree], returning the entry it names, or null.
  /// Path segments are separated by forward slashes, as git stores them.
  TreeEntry? lookup(Tree tree, String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;

    var current = tree;
    for (var i = 0; i < segments.length; i++) {
      final entry = current.entryNamed(segments[i]);
      if (entry == null) return null;
      if (i == segments.length - 1) return entry;
      if (!entry.mode.isTree) return null;
      current = objects.readTyped<Tree>(entry.id);
    }
    return null;
  }

  /// The contents of a blob at [path] in [revision]'s tree.
  Uint8List? readFile(String path, {String revision = 'HEAD'}) {
    final id = resolve(revision);
    if (id == null) return null;
    final tree = treeOf(id);
    if (tree == null) return null;
    final entry = lookup(tree, path);
    if (entry == null || entry.mode.isTree) return null;
    return objects.readTyped<Blob>(entry.id).content;
  }

  // ---- the walk -----------------------------------------------------------

  /// Commits reachable from [start], newest first by committer date.
  ///
  /// Date order, not topological: it is what a log listing wants, and it is
  /// honest about what it is. A merge whose sides were committed out of order
  /// will interleave, which topological order exists to prevent.
  Iterable<Commit> log({
    ObjectId? start,
    int? limit,
    Set<ObjectId>? excluding,
  }) sync* {
    final from = start ?? headId;
    if (from == null) return;

    final seen = <ObjectId>{...?excluding};
    final queue = SplayTreeSet<Commit>((a, b) {
      final byDate = b.committer.seconds.compareTo(a.committer.seconds);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });

    if (seen.add(from)) {
      final head = peel(from);
      if (head is Commit) queue.add(head);
    }

    var emitted = 0;
    while (queue.isNotEmpty) {
      final commit = queue.first;
      queue.remove(commit);

      yield commit;
      if (limit != null && ++emitted >= limit) return;

      for (final parent in commit.parents) {
        if (!seen.add(parent)) continue;
        final object = objects.readRaw(parent);
        // A shallow clone's boundary points at commits it does not have.
        if (object == null) continue;
        queue.add(objects.readTyped<Commit>(parent));
      }
    }
  }

  /// Every object reachable from [roots]. What is not here is garbage
  /// (`algorithms.reachability`).
  Set<ObjectId> reachable(Iterable<ObjectId> roots) {
    final seen = <ObjectId>{};
    final pending = <ObjectId>[...roots];

    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!seen.add(id)) continue;
      final raw = objects.readRaw(id);
      if (raw == null) continue;
      final object = GitObject.parse(raw.kind, raw.content);
      switch (object) {
        case Commit commit:
          pending.add(commit.tree);
          pending.addAll(commit.parents);
        case Tree tree:
          for (final entry in tree.entries) {
            // A submodule's commit is not stored here, so following it would
            // report every submodule as a corrupt repository.
            if (!entry.mode.isSubmodule) pending.add(entry.id);
          }
        case Tag tag:
          pending.add(tag.target);
        case Blob():
          break;
      }
    }
    return seen;
  }

  // ---- diff, status, checkout ---------------------------------------------

  /// The changes between two commits, tags or trees. Either may be null,
  /// which is how the first commit is diffed: against nothing.
  List<DiffEntry> diff(
    ObjectId? before,
    ObjectId? after, {
    bool detectRenames = true,
  }) =>
      diffTrees(
        objects,
        before == null ? null : treeOf(before),
        after == null ? null : treeOf(after),
        detectRenames: detectRenames,
      );

  /// What [commit] changed, against its first parent. A merge is diffed
  /// against its first parent too, which is what a log listing shows and is
  /// not the whole story of a merge.
  List<DiffEntry> changesIn(ObjectId commit) {
    final object = peel(commit);
    if (object is! Commit) return const [];
    return diff(
      object.parents.isEmpty ? null : object.parents.first,
      object.id,
    );
  }

  /// The line-by-line difference between two blobs. Either may be null, for a
  /// file that was added or deleted.
  TextDiff diffBlobs(ObjectId? before, ObjectId? after, {int context = 3}) =>
      diffText(
        before == null ? Uint8List(0) : objects.readTyped<Blob>(before).content,
        after == null ? Uint8List(0) : objects.readTyped<Blob>(after).content,
        context: context,
      );

  /// HEAD, the index and the working tree compared.
  ///
  /// Pass `trustStatCache: false` to hash every tracked file rather than
  /// believe the index's stat fields — slower, and the only way to catch a
  /// file edited within the same second and to the same length.
  RepositoryStatus status({
    bool includeUntracked = true,
    bool trustStatCache = true,
    bool collapseUntrackedDirectories = true,
  }) =>
      statusOf(
        this,
        includeUntracked: includeUntracked,
        trustStatCache: trustStatCache,
        collapseUntrackedDirectories: collapseUntrackedDirectories,
      );

  /// Checks out [revision]: the working tree and the index are made to match
  /// it, and HEAD moves.
  ///
  /// HEAD becomes symbolic when [revision] names a branch and direct
  /// otherwise, which is the whole of what "detached HEAD" means
  /// (`refs.head`).
  CheckoutResult checkout(
    String revision, {
    bool force = false,
    bool detach = false,
  }) {
    final id = resolve(revision);
    if (id == null) {
      throw ArgumentError.value(revision, 'revision', 'names no object here');
    }
    final tree = treeOf(id);
    if (tree == null) {
      throw ArgumentError.value(revision, 'revision', 'has no tree');
    }

    final result = checkoutTree(this, tree, force: force);

    final branch = _branchNamed(revision);
    if (branch != null && !detach) {
      refs.writeSymbolic('HEAD', branch);
    } else {
      refs.write('HEAD', peel(id) is Commit ? (peel(id) as Commit).id : id);
    }
    return result;
  }

  String? _branchNamed(String revision) {
    for (final candidate in [revision, 'refs/heads/$revision']) {
      if (candidate.startsWith('refs/heads/') && refs.read(candidate) != null) {
        return candidate;
      }
    }
    return null;
  }

  /// Creates a branch at [at], or at HEAD.
  void createBranch(String name, {ObjectId? at}) {
    final path = name.startsWith('refs/') ? name : 'refs/heads/$name';
    if (refs.read(path) != null) {
      throw ArgumentError.value(name, 'name', 'branch already exists');
    }
    final id = at ?? headId;
    if (id == null) {
      throw StateError('there is no commit for the branch to point at');
    }
    refs.write(path, id);
  }

  // ---- writing ------------------------------------------------------------

  ObjectId writeObject(GitObject object) => objects.write(object);

  // ---- the staging area ---------------------------------------------------

  /// Stages [path] as it is in the working tree.
  ///
  /// Writes the file's content as a blob and updates the index entry. A path
  /// that is missing from the working tree has its deletion staged, which is
  /// what `git add` on a deleted file does — nothing separate is needed.
  ///
  /// A directory stages everything under it that is not ignored.
  void stage(String path) {
    final workTree = this.workTree;
    if (workTree == null) {
      throw StateError('a bare repository has no working tree to stage from');
    }

    final index = this.index ?? GitIndex.empty();
    final entries = [...index.entries];
    final absolute = p.join(workTree, path.replaceAll('/', p.separator));

    if (Directory(absolute).existsSync()) {
      for (final child in _pathsUnder(workTree, path)) {
        _stageOne(workTree, entries, child);
      }
    } else {
      _stageOne(workTree, entries, path);
    }

    GitIndex(entries: entries).writeTo(p.join(gitDirectory, 'index'));
  }

  /// Every non-ignored, non-directory path under [directory], tracked or not.
  Iterable<String> _pathsUnder(String workTree, String directory) sync* {
    final rules = loadIgnoreRules(workTree, gitDirectory, config: config);
    final root = Directory(p.join(workTree, directory.replaceAll('/', p.separator)));
    if (!root.existsSync()) return;

    for (final entry in root.listSync(recursive: true, followLinks: false)) {
      if (entry is Directory) continue;
      final relative =
          p.relative(entry.path, from: workTree).replaceAll(r'\', '/');
      if (relative.startsWith('.git/')) continue;
      if (rules.isIgnoredWithin(relative)) continue;
      yield relative;
    }
  }

  void _stageOne(String workTree, List<IndexEntry> entries, String path) {
    final absolute = p.join(workTree, path.replaceAll('/', p.separator));
    final existing = entries.indexWhere(
      (e) => e.path == path && e.stage == MergeStage.ordinary,
    );

    final link = Link(absolute);
    final file = File(absolute);

    if (!file.existsSync() && !link.existsSync()) {
      // Staging a deletion: the entry goes, and so does any conflict stage,
      // since resolving by deleting is still resolving.
      entries.removeWhere((e) => e.path == path);
      return;
    }

    final isSymlink = link.existsSync() && !file.existsSync();
    final content = isSymlink
        ? Uint8List.fromList(utf8.encode(link.targetSync()))
        : file.readAsBytesSync();
    final id = objects.write(Blob(content));

    // The mode git already recorded wins, so staging on Windows — where the
    // executable bit cannot be read — does not quietly clear it.
    final previous = existing >= 0 ? entries[existing] : null;
    final mode = isSymlink
        ? FileMode.symlink
        : (previous != null && previous.fileMode == FileMode.executableFile
            ? FileMode.executableFile
            : FileMode.regularFile);

    final stat = file.existsSync() ? file.statSync() : null;
    final seconds =
        stat == null ? 0 : stat.modified.millisecondsSinceEpoch ~/ 1000;

    final entry = IndexEntry(
      path: path,
      id: id,
      mode: mode.numeric,
      ctimeSeconds: seconds,
      mtimeSeconds: seconds,
      size: content.length,
    );

    // Any conflict stages for this path are resolved by staging it.
    entries.removeWhere((e) => e.path == path);
    entries.add(entry);
  }

  /// Puts HEAD's version of [path] back in the index, or removes the entry
  /// when HEAD has no such path. The working tree is not touched.
  void unstage(String path) {
    final index = this.index ?? GitIndex.empty();
    final entries = [...index.entries];

    final headTree = headId == null ? null : treeOf(headId!);
    final inHead = headTree == null ? null : lookup(headTree, path);

    entries.removeWhere((e) => e.path == path);
    if (inHead != null && !inHead.mode.isTree) {
      entries.add(IndexEntry(
        path: path,
        id: inHead.id,
        mode: inHead.mode.numeric,
        // Zeroed, so the next status reads the file rather than believing a
        // cache that describes a different version.
      ));
    }

    GitIndex(entries: entries).writeTo(p.join(gitDirectory, 'index'));
  }

  /// Every path the index holds at or under [path].
  ///
  /// A path is "tracked" exactly when the index holds it, which is also what
  /// decides whether adding it to a `.gitignore` will have any effect: git
  /// ignores only what it is not already tracking.
  List<String> trackedUnder(String path) {
    final index = this.index;
    if (index == null) return const [];
    final prefix = path.isEmpty ? '' : '$path/';
    return [
      for (final entry in index.entries)
        if (entry.path == path || (prefix.isNotEmpty && entry.path.startsWith(prefix)))
          entry.path,
    ];
  }

  /// Removes [path] from the index without touching the working tree — what
  /// `git rm --cached` does.
  ///
  /// The file stays on disk and becomes untracked, which is what makes a new
  /// ignore rule apply to it.
  void removeFromIndex(String path) {
    final index = this.index;
    if (index == null) return;

    final prefix = '$path/';
    final entries = [
      for (final entry in index.entries)
        if (entry.path != path && !entry.path.startsWith(prefix)) entry,
    ];
    GitIndex(entries: entries).writeTo(p.join(gitDirectory, 'index'));
  }

  /// Adds a pattern for [path] to the working tree's root `.gitignore`, and
  /// returns the line written — or null when an identical line was already
  /// there.
  ///
  /// The pattern is anchored with a leading slash, so ignoring `notes.txt`
  /// ignores that file and not every file of that name at any depth. A
  /// directory gets a trailing slash, which is how git spells "the directory
  /// and everything in it".
  String? addIgnoreRule(String path, {required bool isDirectory}) {
    final workTree = this.workTree;
    if (workTree == null) {
      throw StateError('a bare repository has no working tree to ignore in');
    }

    final pattern = '/${path.replaceAll(r'\', '/')}${isDirectory ? '/' : ''}';
    final file = File(p.join(workTree, '.gitignore'));

    final existing = file.existsSync() ? file.readAsStringSync() : '';
    final lines = const LineSplitter().convert(existing);
    // An identical rule is left alone rather than repeated: two copies of a
    // line behave exactly as one, and only the file gets worse.
    if (lines.any((line) => line.trim() == pattern)) return null;

    // Written whole rather than appended: `FileMode` here is a tree entry's
    // mode, not dart:io's, and the collision is not worth an import prefix.
    final separator = existing.isEmpty || existing.endsWith('\n') ? '' : '\n';
    file.writeAsStringSync('$existing$separator$pattern\n');
    return pattern;
  }

  /// The identity to record on a commit, from `user.name` and `user.email`.
  ///
  /// Null when either is unset. A commit attributed to a guess is worse than
  /// one that did not happen, so callers refuse rather than invent.
  Identity? identityFromConfig({DateTime? at}) {
    final name = config['user.name'];
    final email = config['user.email'];
    if (name == null || name.isEmpty || email == null || email.isEmpty) {
      return null;
    }
    final when = at ?? DateTime.now();
    return Identity(
      name: name,
      email: email,
      seconds: when.millisecondsSinceEpoch ~/ 1000,
      timezone: formatTimezoneOffset(when.timeZoneOffset),
    );
  }

  /// Commits what is staged.
  ///
  /// Writes a tree from the index, a commit with HEAD as its parent, and moves
  /// the current branch — or creates it, when HEAD is unborn. Returns the new
  /// commit's name.
  ObjectId commitIndex({
    required String message,
    Identity? author,
    Identity? committer,
    bool allowEmpty = false,
  }) {
    final index = this.index;
    if (index == null || index.entries.isEmpty) {
      if (!allowEmpty) throw StateError('nothing is staged');
    }
    if (index != null && index.hasConflicts) {
      throw StateError('cannot commit while the index has conflicts');
    }
    if (message.trim().isEmpty) {
      throw StateError('a commit message is required');
    }

    final who = author ?? identityFromConfig();
    if (who == null) {
      throw StateError(
        'no user.name and user.email are configured for this repository',
      );
    }

    final tree = writeTreeFromIndex();
    final parent = headId;

    if (!allowEmpty && parent != null) {
      final parentCommit = objects.readTyped<Commit>(parent);
      if (parentCommit.tree == tree) {
        throw StateError('nothing is staged');
      }
    }

    return commitTree(
      tree: tree,
      message: message,
      author: who,
      committer: committer ?? who,
      parents: [if (parent != null) parent],
    );
  }

  ObjectId writeBlobFromFile(String path) =>
      objects.write(Blob(File(path).readAsBytesSync()));

  /// Writes a commit and moves the current branch to it — which is all that
  /// "committing" is: new objects, and one ref moved (`refs.doc`).
  ///
  /// [tree] must already be written. Returns the new commit's name.
  ObjectId commitTree({
    required ObjectId tree,
    required String message,
    required Identity author,
    Identity? committer,
    List<ObjectId>? parents,
    bool updateHead = true,
  }) {
    final currentHead = headId;
    final commit = Commit.build(
      tree: tree,
      parents: parents ?? [if (currentHead != null) currentHead],
      author: author,
      committer: committer ?? author,
      message: message.endsWith('\n') ? message : '$message\n',
    );
    final id = objects.write(commit);

    if (updateHead) {
      final branch = refs.currentBranch;
      // On a detached HEAD there is no branch to move, so HEAD itself moves.
      refs.write(branch ?? 'HEAD', id);
    }
    return id;
  }

  /// Builds tree objects from the index's ordinary-stage entries and writes
  /// them, returning the root tree's name. This is `write-tree`.
  ///
  /// Throws when the index has conflicts: there is no single tree to write
  /// while a path has more than one stage.
  ObjectId writeTreeFromIndex() {
    final index = this.index;
    if (index == null) {
      throw StateError('this repository has no index');
    }
    if (index.hasConflicts) {
      throw StateError('cannot write a tree while the index has conflicts');
    }

    final entries = index.entries
        .where((entry) => entry.stage == MergeStage.ordinary)
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    return _writeTreeLevel('', entries);
  }

  ObjectId _writeTreeLevel(String prefix, List<IndexEntry> entries) {
    final here = <TreeEntry>[];
    var i = 0;

    while (i < entries.length) {
      final entry = entries[i];
      final rest = entry.path.substring(prefix.length);
      final slash = rest.indexOf('/');

      if (slash < 0) {
        here.add(TreeEntry.named(
          mode: entry.fileMode,
          name: rest,
          id: entry.id,
        ));
        i += 1;
        continue;
      }

      // A run of entries sharing the next path segment becomes one subtree.
      final name = rest.substring(0, slash);
      final subPrefix = '$prefix$name/';
      final group = <IndexEntry>[];
      while (i < entries.length && entries[i].path.startsWith(subPrefix)) {
        group.add(entries[i]);
        i += 1;
      }
      here.add(TreeEntry.named(
        mode: FileMode.directory,
        name: name,
        id: _writeTreeLevel(subPrefix, group),
      ));
    }

    return objects.write(Tree.build(here));
  }

  /// Creates an empty repository at [path] and returns it.
  static Repository init(String path, {bool bare = false, String defaultBranch = 'main'}) {
    final root = p.absolute(path);
    final gitDirectory = bare ? root : p.join(root, '.git');

    for (final directory in [
      gitDirectory,
      p.join(gitDirectory, 'objects'),
      p.join(gitDirectory, 'objects', 'info'),
      p.join(gitDirectory, 'objects', 'pack'),
      p.join(gitDirectory, 'refs'),
      p.join(gitDirectory, 'refs', 'heads'),
      p.join(gitDirectory, 'refs', 'tags'),
    ]) {
      Directory(directory).createSync(recursive: true);
    }

    File(p.join(gitDirectory, 'HEAD'))
        .writeAsStringSync('ref: refs/heads/$defaultBranch\n');
    File(p.join(gitDirectory, 'config')).writeAsStringSync(
      '[core]\n'
      '\trepositoryformatversion = 0\n'
      '\tfilemode = false\n'
      '\tbare = $bare\n',
    );

    return Repository.at(gitDirectory, workTree: bare ? null : root);
  }
}
