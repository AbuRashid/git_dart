import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'config/config_writer.dart';
import 'config/git_config.dart';
import 'diff/text_diff.dart';
import 'diff/tree_diff.dart';
import 'fs/git_fs.dart';
import 'graph/commit_graph.dart';
import 'graph/graph_walks.dart';
import 'hooks/hook_steps.dart';
import 'hooks/hooks.dart';
import 'index/git_index.dart';
import 'object_id.dart';
import 'objects/commit.dart';
import 'objects/git_object.dart';
import 'objects/identity.dart';
import 'objects/tag.dart';
import 'objects/tree.dart';
import 'refs/ref_store.dart';
import 'refs/mailmap.dart';
import 'refs/reflog.dart';
import 'remote/remote.dart';
import 'signing/signature.dart';
import 'storage/object_store.dart';
import 'worktree/attributes.dart';
import 'worktree/checkout.dart';
import 'worktree/filters.dart';
import 'worktree/ignore.dart';
import 'worktree/status.dart';

/// A repository: an object store, a ref namespace over it, and — unless bare —
/// an index and a working tree.
class Repository {
  /// The `.git` directory, or the repository itself when bare.
  final String gitDirectory;

  /// The git directory holding everything this repository shares — objects,
  /// refs, config. The same as [gitDirectory] except in a linked worktree.
  ///
  /// `git worktree add` gives a second checkout its own small git directory
  /// under `.git/worktrees/<name>`, holding a HEAD and an index and a
  /// `commondir` file naming where the real repository is. Reading such a
  /// worktree without following that file finds no objects and no refs, and
  /// reports a perfectly good checkout as an empty repository with every
  /// tracked file newly added.
  final String commonDirectory;

  /// The working tree root, or null for a bare repository.
  final String? workTree;

  final ObjectStore objects;
  final RefStore refs;

  Repository._({
    required this.gitDirectory,
    required this.commonDirectory,
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
    var directory = fs.directory(p.absolute(path));
    while (true) {
      final candidate = p.join(directory.path, '.git');
      // A `.git` directory that holds no repository is not one: an abandoned
      // or half-created directory must be walked past, not opened. Found by
      // reporting 1242 untracked files in a directory git said was not a
      // repository at all.
      if (_looksLikeGitDirectory(candidate)) {
        return Repository.at(candidate, workTree: directory.path);
      }
      if (fs.file(candidate).existsSync()) {
        // A `.git` file rather than a directory: a worktree or a submodule
        // points at its real git directory this way.
        final text = fs.file(candidate).readAsStringSync().trim();
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

  /// Where a git directory's shared half is.
  ///
  /// A `commondir` file means this is a linked worktree and names the real
  /// repository, usually relatively. Its absence means the ordinary case,
  /// where a repository's own directory is both halves.
  static String _commonDirectoryOf(String gitDirectory) {
    final file = fs.file(p.join(gitDirectory, 'commondir'));
    if (!file.existsSync()) return gitDirectory;
    final target = file.readAsStringSync().trim();
    if (target.isEmpty) return gitDirectory;
    return p.normalize(
      p.isAbsolute(target) ? target : p.join(gitDirectory, target),
    );
  }

  /// git's own test for a git directory: HEAD, an object store and a ref
  /// namespace. The three things a repository is.
  static bool _looksLikeGitDirectory(String path) =>
      fs.file(p.join(path, 'HEAD')).existsSync() &&
      fs.directory(p.join(path, 'objects')).existsSync() &&
      fs.directory(p.join(path, 'refs')).existsSync();

  /// Opens a known git directory without searching.
  factory Repository.at(String gitDirectory, {String? workTree}) {
    final commonDirectory = _commonDirectoryOf(gitDirectory);
    final refs = RefStore(gitDirectory, commonDirectory: commonDirectory);
    final repository = Repository._(
      gitDirectory: gitDirectory,
      commonDirectory: commonDirectory,
      workTree: workTree,
      objects: ObjectStore.open(p.join(commonDirectory, 'objects')),
      refs: refs,
    );
    // The store asks at the moment of a move, so the timestamp is the move's
    // own and a config edited mid-session is picked up.
    refs.identityFor = repository.identityFromConfig;
    return repository;
  }

  bool get isBare => workTree == null;

  /// Who runs this repository's hooks.
  ///
  /// [HookRunner.disk] unless changed: the hooks git would run, found where
  /// git would find them — and, in a browser, none. Set [HookRunner.none] to
  /// run no hooks at all, or [HookRunner.inProcess] to run Dart callbacks in
  /// their place. Commits, merges, checkouts, rebases and pushes all ask this
  /// runner, at the points git runs the same hooks.
  HookRunner hooks = HookRunner.disk;

  /// What makes and checks signatures for this repository.
  ///
  /// By default the programs git itself runs — `gpg`, `gpgsm`, `ssh-keygen` —
  /// which needs `dart:io`. In a browser the default refuses; an app that
  /// wants signatures there, or a test that wants no processes, sets its own.
  SignatureTool signatureTool = SignatureTool.platformDefault;

  GitConfig? _config;

  /// The repository's config merged over the user's. Read once and kept: it
  /// is consulted on every status, and a file read per call would be the
  /// slowest thing in the loop.
  GitConfig get config => _config ??= GitConfig.forRepository(
        commonDirectory,
        worktreeDirectory: gitDirectory,
      );

  Mailmap? _mailmap;

  /// The `.mailmap` in force here, which says which identities are one person.
  ///
  /// Read once and kept: it is consulted per commit, and per line by [blame],
  /// so re-reading the file each time would make the common case pay for a
  /// feature most repositories do not use.
  Mailmap get mailmap => _mailmap ??= Mailmap.forRepository(this);

  /// Forgets the cached [config], for a caller that has just changed it.
  void reloadConfig() {
    _config = null;
    _attributes = null;
  }

  CommitGraph? _commitGraph;
  var _lookedForCommitGraph = false;

  /// The commit-graph cache, or null when the repository has none.
  ///
  /// Optional by design: every question it speeds up is answered the same way
  /// without it. Read once and kept, because it is consulted per commit during
  /// a walk and re-reading the header each time would cost more than it saves.
  CommitGraph? get commitGraph {
    if (_lookedForCommitGraph) return _commitGraph;
    _lookedForCommitGraph = true;
    return _commitGraph = CommitGraph.open(commonDirectory);
  }

  // ---- worktrees ----------------------------------------------------------

  /// Whether this is a linked worktree rather than the repository itself.
  bool get isLinkedWorktree => commonDirectory != gitDirectory;

  /// The other checkouts of this repository, not counting the main one.
  ///
  /// `git worktree add` makes a second working tree sharing one object store,
  /// so two branches can be checked out at once without a second clone. Each
  /// gets a directory under `worktrees/`, and the `gitdir` file in it names
  /// the checkout - which is the only link back, since the checkout knows
  /// about the repository and not the reverse.
  ///
  /// Listed from whichever worktree is asked, because they share the record.
  List<LinkedWorktree> get linkedWorktrees {
    final root = fs.directory(p.join(commonDirectory, 'worktrees'));
    if (!root.existsSync()) return const [];

    final out = <LinkedWorktree>[];
    for (final entry in root.listSync()) {
      if (entry is! GitFsDirectory) continue;
      final name = p.basename(entry.path);

      // `gitdir` holds the path of the checkout's own `.git` file, so the
      // checkout is its parent.
      final pointer = fs.file(p.join(entry.path, 'gitdir'));
      if (!pointer.existsSync()) continue;
      final target = pointer.readAsStringSync().trim();
      if (target.isEmpty) continue;
      final path = p.dirname(p.normalize(target));

      // A worktree whose directory has been deleted is still recorded until
      // someone prunes it, and saying so is more use than hiding it.
      final present = fs.directory(path).existsSync();

      final headFile = fs.file(p.join(entry.path, 'HEAD'));
      String? branch;
      ObjectId? head;
      if (headFile.existsSync()) {
        final text = headFile.readAsStringSync().trim();
        if (text.startsWith('ref:')) {
          branch = text.substring(4).trim();
          head = refs.resolve(branch);
        } else if (text.length >= ObjectId.hexLength) {
          try {
            head = ObjectId.fromHex(text.substring(0, ObjectId.hexLength));
          } on FormatException {
            // A HEAD nothing can be made of leaves the worktree listed with
            // no commit, which is the honest answer.
          }
        }
      }

      out.add(LinkedWorktree(
        name: name,
        path: path,
        branch: branch,
        head: head,
        exists: present,
        locked: fs.file(p.join(entry.path, 'locked')).existsSync(),
      ));
    }

    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// Opens one of [linkedWorktrees].
  Repository? openWorktree(LinkedWorktree worktree) =>
      worktree.exists ? Repository.discover(worktree.path) : null;

  // ---- shallow ------------------------------------------------------------

  /// The commits whose parents this repository deliberately does not have.
  ///
  /// A shallow clone stops at a chosen depth: the commits at the boundary
  /// still name their parents, and those parents were never sent. Without a
  /// record of which commits those are, the result is indistinguishable from a
  /// corrupt repository — every tool that walks history would report a missing
  /// object rather than an edge of a deliberate one. `.git/shallow` is that
  /// record, and it is the whole of what makes a partial history legitimate
  /// rather than broken.
  Set<ObjectId> get shallowCommits {
    final file = fs.file(p.join(commonDirectory, 'shallow'));
    if (!file.existsSync()) return const {};
    final out = <ObjectId>{};
    for (final line in file.readAsLinesSync()) {
      final text = line.trim();
      if (text.length != ObjectId.hexLength) continue;
      try {
        out.add(ObjectId.fromHex(text));
      } on FormatException {
        // A line that is not a name is not a reason to refuse the repository.
      }
    }
    return out;
  }

  bool get isShallow => shallowCommits.isNotEmpty;

  /// Records the boundary, or removes the file when there is none left.
  ///
  /// Sorted, because git writes it sorted and a file that differs only in
  /// order is a diff nobody wants to read.
  void writeShallowCommits(Set<ObjectId> commits) {
    final file = fs.file(p.join(commonDirectory, 'shallow'));
    if (commits.isEmpty) {
      // Deepening to the full history removes the boundary rather than
      // leaving an empty file behind, which git treats as still shallow.
      if (file.existsSync()) file.deleteSync();
      return;
    }
    final sorted = commits.map((id) => id.hex).toList()..sort();
    file.writeAsStringSync(sorted.join('\n') + '\n');
  }

  /// The parents of [commit] that this repository actually has.
  ///
  /// At a shallow boundary a commit still names parents that were never sent.
  /// Every walk wants this rather than [Commit.parents], because the honest
  /// answer to "what can I reach from here" stops at the edge of what is
  /// present.
  List<ObjectId> presentParentsOf(Commit commit) {
    if (commit.parents.isEmpty) return const [];
    return [
      for (final parent in commit.parents)
        if (objects.contains(parent)) parent,
    ];
  }

  /// Forgets the cached commit-graph, for a caller that has just written one.
  void reloadCommitGraph() {
    _lookedForCommitGraph = false;
    _commitGraph = null;
  }

  Attributes? _attributes;

  /// The `.gitattributes` rules in force, with `core.autocrlf` and `core.eol`.
  ///
  /// Cached for the same reason the config is: they are consulted once per
  /// file on every status, checkout and add.
  Attributes get attributes => _attributes ??= workTree == null
      ? Attributes()
      : loadAttributes(workTree!, commonDirectory, config: config);

  /// In-process filter drivers for this repository, by the name
  /// `filter=<name>` gives them.
  ///
  /// These win over [FilterDriver.registry] and over any
  /// `filter.<name>.clean` / `filter.<name>.smudge` command in the config. On
  /// the web they are the only drivers that can run.
  final Map<String, FilterDriver> filters = {};

  late final ContentFilters _contentFilters = ContentFilters(
    config: config,
    workTree: workTree,
    registered: filters,
  );

  /// [raw], read from the working tree at [path], in the form git stores:
  /// the filter driver's clean step, then line-ending conversion.
  ///
  /// git's `convert_to_git`, in its order — the driver sees the file exactly
  /// as it is on disk, and endings are normalised in what it produced.
  Uint8List convertToGit(String path, Uint8List raw) {
    final attributes = this.attributes;
    final cleaned = _contentFilters.clean(
      path,
      ContentFilters.driverName(attributes.forPath(path)),
      raw,
    );
    return toStorage(cleaned, attributes.conversionFor(path, cleaned));
  }

  /// [stored], a blob for [path], in the form written to the working tree:
  /// line-ending conversion, then the filter driver's smudge step.
  ///
  /// git's `convert_to_working_tree`: the reverse of [convertToGit], so the
  /// driver again sees working-tree line endings.
  Uint8List convertToWorkTree(String path, Uint8List stored) {
    final attributes = this.attributes;
    final converted =
        toWorkingTree(stored, attributes.conversionFor(path, stored));
    return _contentFilters.smudge(
      path,
      ContentFilters.driverName(attributes.forPath(path)),
      converted,
    );
  }

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
  ///
  /// `<ref>@{n}` reads the reflog instead of the commit graph: it is where the
  /// ref was n moves ago, which is a different question from where it is n
  /// parents back and is the only way to name a commit nothing points at.
  /// `@{-n}` reads the same log for a different fact — the branch checked out
  /// n checkouts ago, which is what people mean by "the branch I was just on".
  ///
  /// A colon names something *inside* a revision rather than the revision
  /// itself: `HEAD:lib/x.dart` is a blob, `HEAD:lib` is a tree, `:lib/x.dart`
  /// is what the index holds and `:2:lib/x.dart` one side of a conflict.
  /// `:/text` searches commit messages instead of names, for the common case
  /// of remembering what a commit said and not what it was called.
  ObjectId? resolve(String revision) {
    if (revision.isEmpty) return null;

    if (revision.startsWith(':/')) {
      return _resolveByMessage(revision.substring(2));
    }

    // Split at the *first* colon: everything after it is a path, and a path is
    // allowed to contain the characters that would otherwise be navigation.
    final colon = revision.indexOf(':');
    if (colon >= 0) {
      return _resolveInside(
        revision.substring(0, colon),
        revision.substring(colon + 1),
      );
    }

    final previous = RegExp(r'^@\{-(\d+)\}$').firstMatch(revision);
    if (previous != null) {
      return _resolvePreviousCheckout(int.parse(previous.group(1)!));
    }

    final reflog = RegExp(r'^(.*)@\{(\d+)\}$').firstMatch(revision);
    if (reflog != null) {
      final name = reflog.group(1)!;
      final n = int.parse(reflog.group(2)!);
      return _resolveReflog(name.isEmpty ? 'HEAD' : name, n);
    }

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

  /// `<rev>:<path>` — the object at a path, rather than the revision itself.
  ///
  /// An empty revision means the index, which is a different place from any
  /// tree: it is what would be committed, including a path that is staged and
  /// not yet committed anywhere.
  ObjectId? _resolveInside(String revision, String path) {
    if (revision.isEmpty) return _resolveInIndex(path);

    final id = resolve(revision);
    if (id == null) return null;

    // The empty path is the tree itself, which is how `HEAD:` names a tree
    // without naming anything in it.
    final tree = treeOf(id);
    if (tree == null) return null;
    if (path.isEmpty) return tree.id;

    final entry = lookup(tree, path);
    return entry?.id;
  }

  /// `:<path>`, and `:<stage>:<path>` for one side of a conflict.
  ObjectId? _resolveInIndex(String path) {
    var wanted = MergeStage.ordinary;
    var name = path;

    final staged = RegExp(r'^([0-3]):(.*)$').firstMatch(path);
    if (staged != null) {
      wanted = MergeStage.byValue(int.parse(staged.group(1)!));
      name = staged.group(2)!;
    }

    final index = this.index;
    if (index == null) return null;
    for (final entry in index.entries) {
      if (entry.path == name && entry.stage == wanted) return entry.id;
    }
    return null;
  }

  /// `:/text` — the newest commit reachable from HEAD whose message contains
  /// the text.
  ///
  /// Matched as plain text, not as a pattern: git takes a regular expression
  /// here, and quietly reading `a.b` as a pattern would return a commit the
  /// caller did not name. A caller that wants a pattern has [log] to filter.
  ObjectId? _resolveByMessage(String text) {
    if (text.isEmpty) return null;
    for (final commit in log()) {
      if (commit.message.contains(text)) return commit.id;
    }
    return null;
  }

  /// `@{-n}` — where the branch checked out n checkouts ago now points.
  ///
  /// Read out of HEAD's reflog, which records each move as "checkout: moving
  /// from <old> to <new>". Note this resolves the branch *now*, not where it
  /// stood then: `@{-1}` means "that branch", and the branch may have moved.
  ObjectId? _resolvePreviousCheckout(int n) {
    if (n < 1) return null;

    final log = refs.reflogFor('HEAD');
    final moving = RegExp(r'^checkout: moving from (.+) to (.+)$');

    var remaining = n;
    for (var i = log.entries.length - 1; i >= 0; i--) {
      final match = moving.firstMatch(log.entries[i].message);
      if (match == null) continue;
      remaining -= 1;
      if (remaining > 0) continue;
      // The name it moved *from* is the branch being asked about.
      return _resolveName(match.group(1)!);
    }
    return null;
  }

  /// `<ref>@{n}`, trying the ref by every name a ref can be spelled by.
  ObjectId? _resolveReflog(String name, int n) {
    for (final candidate in [
      name,
      'refs/heads/$name',
      'refs/remotes/$name',
    ]) {
      final log = refs.reflogFor(candidate);
      if (log.isEmpty) continue;
      return log.entryAt(n);
    }
    return null;
  }

  /// The recorded history of a ref: where it has been, in what order and why.
  ///
  /// A commit that a branch has moved off is reachable from nothing and is
  /// invisible to [log] and to [reachable]. This is the only place it is still
  /// named (`refs.reflog`).
  Reflog reflogFor(String refPath) => refs.reflogFor(refPath);

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
    int renameThreshold = 50,
  }) =>
      diffTrees(
        objects,
        before == null ? null : treeOf(before),
        after == null ? null : treeOf(after),
        detectRenames: detectRenames,
        renameThreshold: renameThreshold,
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
  ///
  /// The `post-checkout` hook runs afterwards with the old and new HEAD and a
  /// flag of 1, as it does for `git checkout <branch>`; its exit status
  /// changes nothing, since the checkout has already happened. [runHooks] is
  /// false only for operations that move HEAD as a step of their own — a
  /// fast-forward merge runs `post-merge`, not `post-checkout`.
  CheckoutResult checkout(
    String revision, {
    bool force = false,
    bool detach = false,
    bool runHooks = true,
  }) {
    final id = resolve(revision);
    if (id == null) {
      throw ArgumentError.value(revision, 'revision', 'names no object here');
    }
    final tree = treeOf(id);
    if (tree == null) {
      throw ArgumentError.value(revision, 'revision', 'has no tree');
    }

    final from = _describeHeadPosition();
    final previousHead = headId;
    final result = checkoutTree(this, tree, force: force);

    final branch = _branchNamed(revision);
    if (branch != null && !detach) {
      refs.writeSymbolic(
        'HEAD',
        branch,
        reflogMessage: 'checkout: moving from $from to '
            '${branch.substring('refs/heads/'.length)}',
      );
    } else {
      refs.write(
        'HEAD',
        peel(id) is Commit ? (peel(id) as Commit).id : id,
        reflogMessage: 'checkout: moving from $from to $revision',
      );
    }
    if (runHooks) {
      runHook(
        this,
        'post-checkout',
        arguments: [
          (previousHead ?? ObjectId.zero).hex,
          (headId ?? ObjectId.zero).hex,
          '1',
        ],
        veto: false,
      );
    }
    return result;
  }

  /// What HEAD is on, for a reflog line: the branch's short name, or the
  /// commit when detached. Git writes exactly this and it is what makes
  /// `checkout -` possible.
  String _describeHeadPosition() {
    final branch = refs.currentBranch;
    if (branch != null && branch.startsWith('refs/heads/')) {
      return branch.substring('refs/heads/'.length);
    }
    return headId?.hex ?? 'an unborn branch';
  }

  String? _branchNamed(String revision) {
    for (final candidate in [revision, 'refs/heads/$revision']) {
      if (candidate.startsWith('refs/heads/') && refs.read(candidate) != null) {
        return candidate;
      }
    }
    return null;
  }

  /// Whether [name] is one git would accept for a branch.
  ///
  /// A subset of `git check-ref-format`, covering what a person typing into a
  /// box can get wrong. Refusing here is better than writing a ref file git
  /// will later decline to read.
  static String? branchNameProblem(String name) {
    if (name.isEmpty) return 'a name is required';
    if (name.startsWith('-')) return 'it cannot start with a dash';
    if (name.startsWith('/') || name.endsWith('/')) {
      return 'it cannot start or end with a slash';
    }
    if (name.endsWith('.') || name.endsWith('.lock')) {
      return 'it cannot end with a dot or with .lock';
    }
    if (name.contains('..')) return 'it cannot contain two dots';
    if (name.contains('//')) return 'it cannot contain two slashes';
    if (name == '@') return '@ on its own is not a name';
    if (name.contains('@{')) return 'it cannot contain @{';
    for (final rune in name.runes) {
      if (rune <= 0x20 || rune == 0x7f) {
        return 'it cannot contain spaces or control characters';
      }
      if ('~^:?*[\\'.codeUnits.contains(rune)) {
        return 'it cannot contain ~ ^ : ? * [ or a backslash';
      }
    }
    return null;
  }

  /// Renames a branch, moving HEAD and its tracking configuration with it.
  ///
  /// The three things that make this more than writing one ref: the branch may
  /// live in `packed-refs`, HEAD may be pointing at it, and `branch.<name>.*`
  /// records what it tracks. Missing any of them leaves a repository that
  /// looks renamed and behaves oddly afterwards.
  void renameBranch(String from, String to, {bool force = false}) {
    final problem = branchNameProblem(to);
    if (problem != null) throw ArgumentError.value(to, 'to', problem);

    final id = refs.resolve('refs/heads/$from');
    if (id == null) throw StateError('no branch named $from');
    if (from == to) return;

    if (refs.read('refs/heads/$to') != null && !force) {
      throw StateError('a branch named $to already exists');
    }

    final wasCurrent = refs.currentBranch == 'refs/heads/$from';

    // The old ref goes first. Renaming `feature` to `feature/one` needs a
    // directory where the old ref's file is, and a file and a directory
    // cannot share a name — which is why git deletes before it creates. If
    // the write then fails, the old ref goes back.
    // The log follows the branch: it is the same branch under a new name, and
    // carrying it over is the difference between a rename and a delete
    // followed by a create. It is restored before the write below, so that
    // write's own entry appends to the history rather than starting a new one.
    final log = fs.file(Reflog.pathOf(commonDirectory, 'refs/heads/$from'));
    final carried = log.existsSync() ? log.readAsStringSync() : null;

    refs.delete('refs/heads/$from');
    if (carried != null) {
      fs.file(Reflog.pathOf(commonDirectory, 'refs/heads/$to'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(carried);
    }

    try {
      refs.write(
        'refs/heads/$to',
        id,
        reflogMessage: 'branch: renamed $from to $to',
      );
    } catch (_) {
      refs.write('refs/heads/$from', id);
      rethrow;
    }

    // HEAD names the branch by path, so it would otherwise point at a ref
    // that no longer exists — which reads as an unborn branch.
    if (wasCurrent) {
      refs.writeSymbolic(
        'HEAD',
        'refs/heads/$to',
        reflogMessage: 'branch: renamed $from to $to',
      );
    }

    _renameBranchConfig(from, to);
  }

  /// Moves a `[branch "from"]` section to `[branch "to"]`, keeping its lines.
  void _renameBranchConfig(String from, String to) {
    final file = fs.file(p.join(commonDirectory, 'config'));
    if (!file.existsSync()) return;

    final wanted = '[branch "$from"]';
    final lines = file.readAsLinesSync();
    if (!lines.any((line) => line.trim() == wanted)) return;

    final out = <String>[];
    for (final line in lines) {
      out.add(line.trim() == wanted ? '[branch "$to"]' : line);
    }
    file.writeAsStringSync('${out.join('\n')}\n');
    reloadConfig();
  }

  /// Deletes a branch. The commits it pointed at are left alone; what makes
  /// them unreachable is nothing pointing at them any more.
  void deleteBranch(String name) {
    if (refs.currentBranch == 'refs/heads/$name') {
      throw StateError('cannot delete the branch that is checked out');
    }
    if (refs.resolve('refs/heads/$name') == null) {
      throw StateError('no branch named $name');
    }
    refs.delete('refs/heads/$name');
    _removeBranchConfig(name);
  }

  /// Drops a `[branch "name"]` section, as deleting a branch should.
  void _removeBranchConfig(String name) {
    final file = fs.file(p.join(commonDirectory, 'config'));
    if (!file.existsSync()) return;

    final kept = <String>[];
    var inSection = false;
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) inSection = trimmed == '[branch "$name"]';
      if (!inSection) kept.add(line);
    }
    file.writeAsStringSync('${kept.join('\n')}\n');
    reloadConfig();
  }

  /// Creates a branch at [at], or at HEAD.
  void createBranch(String name, {ObjectId? at}) {
    final problem = branchNameProblem(name);
    if (problem != null) throw ArgumentError.value(name, 'name', problem);
    final path = name.startsWith('refs/') ? name : 'refs/heads/$name';
    if (refs.read(path) != null) {
      throw ArgumentError.value(name, 'name', 'branch already exists');
    }
    final id = at ?? headId;
    if (id == null) {
      throw StateError('there is no commit for the branch to point at');
    }
    refs.write(path, id, reflogMessage: 'branch: created from HEAD');
  }

  // ---- writing ------------------------------------------------------------

  ObjectId writeObject(GitObject object) => objects.write(object);

  // ---- remotes ------------------------------------------------------------

  RemoteStore get remotes => RemoteStore(commonDirectory);

  /// What [ours] has that [theirs] does not, and the other way about.
  ///
  /// This is what `git rev-list --left-right --count` reports, and it is
  /// computed the plain way: everything each side reaches, then the
  /// difference. Null when either side has more than [limit] commits, so a
  /// caller can say "not counted" rather than freeze.
  ///
  /// Two cleverer versions were written first and both disagreed with git.
  /// Walking newest-first and stopping when the frontier looks shared leans on
  /// commit dates: histories whose commits share a timestamp — anything
  /// scripted, imported or rebased in a hurry — order arbitrarily and the walk
  /// stops too early. Collecting both full ancestries and subtracting is exact
  /// and costs the size of the history.
  ///
  /// What settles it is a generation number, which orders commits by *shape*
  /// rather than by clock: both frontiers are walked together, deepest first,
  /// and the walk ends as soon as everything left is common to both. That is
  /// exact whatever the dates say. With no commit-graph the same walk runs
  /// without the pruning — the answer is identical and the cost is the old
  /// one, which is why [limit] still exists.
  ///
  /// Null when either side has more than [limit] commits to look at, so a
  /// caller can say "not counted" rather than freeze.
  AheadBehind? countAheadBehind(
    ObjectId ours,
    ObjectId theirs, {
    int limit = 250000,
  }) {
    if (ours == theirs) return const AheadBehind(0, 0);

    // Without a graph the walk is unbounded, so the old ceiling still applies.
    if (commitGraph == null) {
      final counted = _countAheadBehindBounded(ours, theirs, limit);
      if (counted != null) return counted;
      return null;
    }

    final counted = countDivergence(this, ours, theirs);
    return AheadBehind(counted.ahead, counted.behind);
  }

  AheadBehind? _countAheadBehindBounded(
    ObjectId ours,
    ObjectId theirs,
    int limit,
  ) {
    Set<ObjectId>? reachable(ObjectId from) {
      final seen = <ObjectId>{};
      final pending = <ObjectId>[from];
      while (pending.isNotEmpty) {
        final id = pending.removeLast();
        if (!seen.add(id)) continue;
        if (seen.length > limit) return null;
        final raw = objects.readRaw(id);
        if (raw == null) continue; // a shallow boundary
        final object = GitObject.parse(raw.kind, raw.content);
        if (object is Commit) pending.addAll(object.parents);
      }
      return seen;
    }

    final fromOurs = reachable(ours);
    if (fromOurs == null) return null;
    final fromTheirs = reachable(theirs);
    if (fromTheirs == null) return null;

    var ahead = 0;
    for (final id in fromOurs) {
      if (!fromTheirs.contains(id)) ahead += 1;
    }
    var behind = 0;
    for (final id in fromTheirs) {
      if (!fromOurs.contains(id)) behind += 1;
    }
    return AheadBehind(ahead, behind);
  }

  /// Whether [ancestor] is reachable from [descendant] — `merge-base
  /// --is-ancestor`.
  ///
  /// The question behind "is this branch merged", "can this push
  /// fast-forward", and "is this tag on this branch". With a commit-graph the
  /// generation numbers usually settle it without reading a commit at all.
  bool isAncestorOf(ObjectId ancestor, ObjectId descendant) =>
      isAncestor(this, ancestor, descendant);

  /// Commits reachable from [start], parents always after their children.
  ///
  /// What `git log --topo-order` gives, and what [log] deliberately does not:
  /// date order is what a listing usually wants and it can show a commit
  /// before something it was built on.
  Iterable<Commit> logTopological({ObjectId? start, int? limit}) sync* {
    final from = start ?? headId;
    if (from == null) return;
    final head = peel(from);
    if (head is! Commit) return;

    for (final id in topologicalOrder(this, head.id, limit: limit)) {
      final raw = objects.readRaw(id);
      if (raw == null) continue;
      yield objects.readTyped<Commit>(id);
    }
  }

  /// Writes a commit-graph covering everything reachable from the refs.
  ///
  /// Purely a cache: nothing depends on it existing, and a stale one is
  /// replaced rather than repaired. Worth writing after a fetch or a repack,
  /// which is when the shape of the history has changed most.
  int writeCommitGraph() {
    final commits = <CommitGraphInput>[];
    final seen = <ObjectId>{};

    final roots = <ObjectId>[];
    for (final ref in refs.list()) {
      final id = refs.resolve(ref.path);
      if (id != null) roots.add(id);
    }
    final head = headId;
    if (head != null) roots.add(head);

    final pending = <ObjectId>[...roots];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!seen.add(id)) continue;
      final raw = objects.readRaw(id);
      if (raw == null) continue;
      final object = GitObject.parse(raw.kind, raw.content);
      // A ref may name a tag or a tree; only commits belong in the graph.
      if (object is Tag) {
        pending.add(object.target);
        continue;
      }
      if (object is! Commit) continue;

      commits.add(CommitGraphInput(
        id: id,
        tree: object.tree,
        parents: object.parents,
        commitTime: object.committer.seconds,
      ));
      pending.addAll(object.parents);
    }

    if (commits.isEmpty) return 0;

    final bytes = CommitGraphWriter.build(commits);
    final directory = fs.directory(p.join(commonDirectory, 'objects', 'info'))
      ..createSync(recursive: true);
    final path = p.join(directory.path, 'commit-graph');

    // The same lock-and-rename as everything else that must not be seen half
    // written — and a half-written cache is worse than none, because a reader
    // has no way to tell.
    final temporary = fs.file('$path.lock')
      ..writeAsBytesSync(bytes, flush: true);
    temporary.renameSync(path);

    reloadCommitGraph();
    return commits.length;
  }

  /// Where a branch stands against the ref it tracks.
  BranchTracking trackingFor(String branch) {
    final localTip = refs.resolve('refs/heads/$branch');
    final upstream = upstreamOf(config, branch);

    if (upstream == null) {
      return BranchTracking(branch: branch, localTip: localTip);
    }

    // `branch.x.merge` names the ref on the remote; the local copy of it is
    // wherever that remote's refspec puts it.
    final remote = remotes.named(upstream.remote);
    final trackingRef = remote?.trackingRefFor(upstream.ref) ??
        'refs/remotes/${upstream.remote}/$branch';
    final upstreamTip = refs.resolve(trackingRef);

    return BranchTracking(
      branch: branch,
      localTip: localTip,
      upstreamRef: trackingRef,
      upstreamTip: upstreamTip,
      divergence: localTip != null && upstreamTip != null
          ? countAheadBehind(localTip, upstreamTip)
          : null,
    );
  }

  /// Records that [branch] follows [ref] on [remote], as `--set-upstream` does.
  ///
  /// Written into an existing `[branch "<branch>"]` section when there is one.
  /// Appending a second section instead gives `branch.<branch>.merge` two
  /// values, which git reads as a request to merge both.
  void setUpstream(String branch, String remote, String ref) {
    if (refs.read('refs/heads/$branch') == null) {
      throw StateError('no branch named $branch');
    }
    final writer = ConfigWriter(commonDirectory);
    writer.set('branch.$branch.remote', remote, ConfigScope.local);
    writer.set('branch.$branch.merge', ref, ConfigScope.local);
    reloadConfig();
  }

  /// Forgets what [branch] follows, as `--unset-upstream` does.
  void unsetUpstream(String branch) {
    final writer = ConfigWriter(commonDirectory);
    writer.unset('branch.$branch.remote', ConfigScope.local);
    writer.unset('branch.$branch.merge', ConfigScope.local);
    reloadConfig();
  }

  // ---- tags ---------------------------------------------------------------

  /// Creates a tag at [at], or at HEAD.
  ///
  /// With a [message] this writes a tag *object* — an annotated tag, which is
  /// a real object with a tagger and a message, and which the ref then points
  /// at. Without one it writes only the ref, which is what a lightweight tag
  /// is: a name for a commit and nothing else. The difference is visible
  /// forever afterwards, because only one of the two can carry who made it.
  ///
  /// Returns what the ref was pointed at — the tag object for an annotated
  /// tag, the target itself for a lightweight one.
  ObjectId createTag(
    String name, {
    ObjectId? at,
    String? message,
    Identity? tagger,
    bool force = false,
    bool? sign,
    String? signingKey,
  }) {
    if (sign == true && message == null) {
      throw ArgumentError.value(
        sign,
        'sign',
        'only an annotated tag can be signed; give it a message',
      );
    }
    final problem = branchNameProblem(name);
    if (problem != null) throw ArgumentError.value(name, 'name', problem);

    final path = name.startsWith('refs/') ? name : 'refs/tags/$name';
    if (!force && refs.read(path) != null) {
      throw StateError('a tag named $name already exists');
    }

    final target = at ?? headId;
    if (target == null) {
      throw StateError('there is no commit for the tag to point at');
    }
    if (!objects.contains(target)) {
      throw ArgumentError.value(target, 'at', 'names no object here');
    }

    if (message == null) {
      refs.write(path, target, reflogMessage: 'tag: created');
      return target;
    }

    final who = tagger ?? identityFromConfig();
    if (who == null) {
      throw StateError(
        'no user.name and user.email are configured for this repository',
      );
    }

    var object = Tag(
      target: target,
      targetKind: objects.read(target).kind,
      name: name.startsWith('refs/tags/')
          ? name.substring('refs/tags/'.length)
          : name,
      tagger: who,
      rawMessage: Uint8List.fromList(
        utf8.encode(message.endsWith('\n') ? message : '$message\n'),
      ),
    );
    // A tag's signature is not a header but the end of its message: the tag
    // is signed as written, and the signature appended after it. Only
    // annotated tags: with no message there is no object to sign, and a
    // lightweight tag stays lightweight whatever `tag.gpgSign` says.
    if (sign ?? config.boolean('tag.gpgSign') ?? false) {
      final signature = signPayload(
        object.content,
        signingKey: signingKey,
        signer: who,
      );
      object = Tag(
        target: object.target,
        targetKind: object.targetKind,
        name: object.name,
        tagger: who,
        rawMessage: Uint8List.fromList([
          ...object.rawMessage,
          ...utf8.encode(signature),
        ]),
      );
    }
    final id = objects.write(object);
    refs.write(path, id, reflogMessage: 'tag: created');
    return id;
  }

  // ---- signatures ----------------------------------------------------------

  /// Signs [payload] in the `gpg.format` this repository is configured for,
  /// returning the armoured signature with a final newline.
  ///
  /// The key is [signingKey], else `user.signingKey`, else — for OpenPGP and
  /// X.509 only — [signer]'s `Name <email>`, which gpg resolves to a secret
  /// key by user id. SSH has no such lookup: a key has to be named.
  String signPayload(
    Uint8List payload, {
    String? signingKey,
    Identity? signer,
  }) {
    final format = SignatureFormat.configured(config);
    var key = signingKey ?? config['user.signingKey'];
    if (key == null && format != SignatureFormat.ssh) {
      final who = signer ?? identityFromConfig();
      if (who != null) key = '${who.name} <${who.email}>';
    }
    if (key == null || key.isEmpty) {
      throw StateError(
        format == SignatureFormat.ssh
            ? 'user.signingKey needs to be set for ssh signing'
            : 'no signing key: set user.signingKey, or user.name and '
                'user.email',
      );
    }
    return signatureTool.sign(
      payload,
      SigningRequest(format: format, key: key, config: config),
    );
  }

  /// Checks the signature on commit [id] — `git verify-commit`.
  ///
  /// An unsigned commit is not an error: its result is
  /// [SignatureStatus.none], which is what `%G?` says of it.
  SignatureCheck verifyCommit(ObjectId id) {
    final commit = objects.readTyped<Commit>(id);
    final split = splitSignedCommit(commit.content);
    return _verify(split.payload, split.signature, commit.committer.seconds);
  }

  /// Checks the signature on tag object [id] — `git verify-tag`.
  ///
  /// [id] names the tag object, not what it points at: a lightweight tag has
  /// no object to carry a signature, and is refused.
  SignatureCheck verifyTag(ObjectId id) {
    final object = objects.read(id);
    if (object is! Tag) {
      throw ArgumentError.value(id, 'id', 'is not a tag object');
    }
    final split = splitSignedTag(object.content);
    return _verify(split.payload, split.signature, object.tagger?.seconds);
  }

  SignatureCheck _verify(Uint8List payload, String? signature, int? when) {
    if (signature == null) {
      return SignatureCheck(
        result: SignatureStatus.none,
        output: 'no signature found\n',
        payload: payload,
      );
    }
    final format = SignatureFormat.of(signature);
    if (format == null) {
      // Git dies here; a result says the same without taking the caller down.
      return SignatureCheck(
        result: SignatureStatus.none,
        output: 'bad/incompatible signature\n',
        payload: payload,
        signature: signature,
      );
    }

    // Read before running anything, so a typo is reported as a typo rather
    // than as whatever the program said.
    final minimumSetting = config['gpg.minTrustLevel'];
    var minimum = TrustLevel.undefined;
    if (minimumSetting != null) {
      minimum = TrustLevel.byName(minimumSetting) ??
          (throw StateError(
            "invalid value for 'gpg.minTrustLevel': '$minimumSetting'",
          ));
    }

    final check = signatureTool.verify(
      payload,
      signature,
      VerificationRequest(
        format: format,
        config: config,
        payloadTimestamp: when,
      ),
    );
    return check.copyWith(
      minimumTrust: minimum,
      payload: payload,
      signature: signature,
      format: format,
    );
  }

  /// Removes a tag. The object it pointed at is left alone; what makes it
  /// unreachable is nothing pointing at it any more.
  void deleteTag(String name) {
    final path = name.startsWith('refs/') ? name : 'refs/tags/$name';
    if (refs.read(path) == null) throw StateError('no tag named $name');
    refs.delete(path);
  }

  /// Every tag, with the commit it ultimately names.
  ///
  /// An annotated tag's ref points at a tag object rather than at a commit, so
  /// a caller that wants "where does this tag put me" has to peel it. Doing it
  /// here means no caller forgets.
  List<({String name, ObjectId ref, ObjectId target, Tag? annotation})>
      listTags() {
    final out = <({
      String name,
      ObjectId ref,
      ObjectId target,
      Tag? annotation
    })>[];

    for (final ref in refs.tags) {
      final id = refs.resolve(ref.path);
      if (id == null) continue;
      final object = objects.contains(id) ? objects.read(id) : null;
      out.add((
        name: ref.shortName,
        ref: id,
        target: object is Tag ? peel(id).id : id,
        annotation: object is Tag ? object : null,
      ));
    }
    return out;
  }

  // ---- a merge in progress ------------------------------------------------

  /// The commit being merged in, from `MERGE_HEAD`, or null when no merge is
  /// under way.
  ///
  /// A conflicted merge leaves this file behind precisely so that the commit
  /// which resolves it can record the second parent. Without reading it back,
  /// resolving a conflict produces an ordinary commit and the merge is lost:
  /// the branch stays unmerged and the same conflict returns next time.
  ObjectId? get mergeHead {
    final file = fs.file(p.join(gitDirectory, 'MERGE_HEAD'));
    if (!file.existsSync()) return null;
    final text = file.readAsStringSync().trim();
    if (text.isEmpty) return null;
    return ObjectId.fromHex(text.split(RegExp(r'\s')).first);
  }

  /// The message a conflicted merge prepared, from `MERGE_MSG`.
  String? get mergeMessage {
    final file = fs.file(p.join(gitDirectory, 'MERGE_MSG'));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  bool get isMerging => mergeHead != null;

  /// Forgets a merge in progress without touching the index or working tree.
  void clearMergeState() {
    for (final name in const ['MERGE_HEAD', 'MERGE_MSG', 'MERGE_MODE']) {
      final file = fs.file(p.join(gitDirectory, name));
      if (file.existsSync()) file.deleteSync();
    }
  }

  /// Abandons a merge: the index and working tree go back to HEAD and the
  /// merge state is dropped.
  ///
  /// Conflict markers written into the working tree are overwritten, which is
  /// the point — they are not content anyone wants to keep.
  CheckoutResult abortMerge() {
    if (!isMerging) throw StateError('no merge is in progress');
    final head = headId;
    if (head == null) throw StateError('there is no HEAD to go back to');
    final tree = treeOf(head);
    if (tree == null) throw StateError('HEAD has no tree');

    final result = checkoutTree(this, tree, force: true);
    clearMergeState();
    return result;
  }

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

    if (fs.directory(absolute).existsSync()) {
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
    final rules = loadIgnoreRules(workTree, commonDirectory, config: config);
    final root = fs.directory(
      p.join(workTree, directory.replaceAll('/', p.separator)),
    );
    if (!root.existsSync()) return;

    for (final entry in root.listSync(recursive: true, followLinks: false)) {
      if (entry is GitFsDirectory) continue;
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

    final link = fs.link(absolute);
    final file = fs.file(absolute);

    if (!file.existsSync() && !link.existsSync()) {
      // Staging a deletion: the entry goes, and so does any conflict stage,
      // since resolving by deleting is still resolving.
      entries.removeWhere((e) => e.path == path);
      return;
    }

    final isSymlink = link.existsSync() && !file.existsSync();
    final raw = isSymlink
        ? Uint8List.fromList(utf8.encode(link.targetSync()))
        : file.readAsBytesSync();

    // What is stored is the converted form, not what is on disk. A symlink's
    // target is a path and is never converted.
    final content = isSymlink ? raw : convertToGit(path, raw);
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
      // The size of the file *on disk*, not of the blob that was stored. The
      // stat fields are a cache of the working tree, so they have to describe
      // the working tree: recording the converted length makes every check
      // find a mismatch, re-read the file, and — in git's case — report a
      // CRLF file as modified for ever. Confirmed against `git ls-files
      // --debug`, which records the working-tree size for exactly this reason.
      size: raw.length,
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
    final file = fs.file(p.join(workTree, '.gitignore'));

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
  ///
  /// When a merge is in progress the commit being merged in becomes the second
  /// parent and the merge state is cleared, which is what makes resolving a
  /// conflict finish the merge rather than write an unrelated commit on top of
  /// it. The order matters: HEAD first, since the first parent is the branch
  /// merged into (`objects.commit-format`).
  ///
  /// [message] may be empty when a merge prepared one in `MERGE_MSG`.
  ///
  /// The commit hooks run as they do for `git commit -m`: `pre-commit` first,
  /// before the index is read, so a hook that stages something has it
  /// committed; then `prepare-commit-msg` and `commit-msg` on the message in
  /// `COMMIT_EDITMSG`, either of which may rewrite it; and `post-commit` once
  /// the branch has moved. A failing `pre-commit`, `prepare-commit-msg` or
  /// `commit-msg` throws [HookFailedException] with nothing written.
  /// [noVerify] skips `pre-commit` and `commit-msg`, and only those, as
  /// `--no-verify` does.
  ObjectId commitIndex({
    String message = '',
    Identity? author,
    Identity? committer,
    bool allowEmpty = false,
    bool noVerify = false,
    bool? sign,
    String? signingKey,
  }) {
    if (!noVerify) runHook(this, 'pre-commit', commitEnvironment: true);

    final index = this.index;
    if (index == null || index.entries.isEmpty) {
      if (!allowEmpty) throw StateError('nothing is staged');
    }
    if (index != null && index.hasConflicts) {
      throw StateError('cannot commit while the index has conflicts');
    }

    final merging = mergeHead;
    final fromMerge = message.trim().isEmpty && mergeMessage != null;
    var text = message.trim().isEmpty ? (mergeMessage ?? '') : message;
    if (text.trim().isEmpty) {
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

    // A merge that resolved to exactly our own tree still has to be committed:
    // the point of the commit is the second parent, not the tree.
    if (!allowEmpty && merging == null && parent != null) {
      final parentCommit = objects.readTyped<Commit>(parent);
      if (parentCommit.tree == tree) {
        throw StateError('nothing is staged');
      }
    }

    text = messageThroughHooks(
      this,
      message: text,
      file: p.join(gitDirectory, 'COMMIT_EDITMSG'),
      source: fromMerge ? 'merge' : 'message',
      noVerify: noVerify,
    );
    if (text.trim().isEmpty) {
      throw StateError('a hook left the commit message empty');
    }

    final id = commitTree(
      tree: tree,
      message: text,
      author: who,
      committer: committer ?? who,
      parents: [
        if (parent != null) parent,
        if (merging != null) merging,
      ],
      reflogMessage: merging != null ? 'commit (merge)' : 'commit',
      sign: sign,
      signingKey: signingKey,
    );

    if (merging != null) clearMergeState();
    runHook(this, 'post-commit', commitEnvironment: true, veto: false);
    return id;
  }

  ObjectId writeBlobFromFile(String path) =>
      objects.write(Blob(fs.file(path).readAsBytesSync()));

  /// Writes a commit and moves the current branch to it — which is all that
  /// "committing" is: new objects, and one ref moved (`refs.doc`).
  ///
  /// [tree] must already be written. Returns the new commit's name.
  ///
  /// [sign] asks for a signature; left null, `commit.gpgSign` decides, as it
  /// does for every git command that makes a commit on the user's behalf —
  /// merge, cherry-pick and rebase included. The signature is made over the
  /// finished commit and goes in a `gpgsig` header after all the others,
  /// which is where git puts it and so where git looks for it. [signingKey]
  /// overrides `user.signingKey`.
  ObjectId commitTree({
    required ObjectId tree,
    required String message,
    required Identity author,
    Identity? committer,
    List<ObjectId>? parents,
    bool updateHead = true,
    String reflogMessage = 'commit',
    bool? sign,
    String? signingKey,
  }) {
    final currentHead = headId;
    final who = committer ?? author;
    var commit = Commit.build(
      tree: tree,
      parents: parents ?? [if (currentHead != null) currentHead],
      author: author,
      committer: who,
      message: message.endsWith('\n') ? message : '$message\n',
    );
    if (sign ?? config.boolean('commit.gpgSign') ?? false) {
      final signature = signPayload(
        commit.content,
        signingKey: signingKey,
        signer: who,
      );
      commit = Commit(
        tree: commit.tree,
        parents: commit.parents,
        author: commit.author,
        committer: commit.committer,
        rawMessage: commit.rawMessage,
        extraHeaders: [...commit.extraHeaders, commitSignatureLine(signature)],
      );
    }
    final id = objects.write(commit);

    if (updateHead) {
      final branch = refs.currentBranch;
      // On a detached HEAD there is no branch to move, so HEAD itself moves.
      refs.write(
        branch ?? 'HEAD',
        id,
        reflogMessage: '$reflogMessage: ${_summaryOf(message)}',
      );
    }
    return id;
  }

  /// A commit message's first line, which is what a reflog entry carries.
  static String _summaryOf(String message) {
    final firstLine = const LineSplitter()
        .convert(message)
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
    return firstLine.length > 120 ? firstLine.substring(0, 120) : firstLine;
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
      fs.directory(directory).createSync(recursive: true);
    }

    fs.file(p.join(gitDirectory, 'HEAD'))
        .writeAsStringSync('ref: refs/heads/$defaultBranch\n');
    fs.file(p.join(gitDirectory, 'config')).writeAsStringSync(
      '[core]\n'
      '\trepositoryformatversion = 0\n'
      '\tfilemode = false\n'
      '\tbare = $bare\n',
    );

    return Repository.at(gitDirectory, workTree: bare ? null : root);
  }
}

/// A second checkout of one repository, made by `git worktree add`.
class LinkedWorktree {
  /// The name under `worktrees/`, which git derives from the directory but
  /// which is not required to still match it.
  final String name;

  /// The checkout's directory.
  final String path;

  /// The branch it has checked out, as a full ref path, or null when its HEAD
  /// is detached.
  final String? branch;

  /// The commit it is on.
  final ObjectId? head;

  /// Whether the directory is still there. A worktree whose directory was
  /// deleted stays recorded until it is pruned.
  final bool exists;

  /// Whether it is marked locked, which asks other tools not to prune it -
  /// the flag for a worktree on a drive that is not always mounted.
  final bool locked;

  const LinkedWorktree({
    required this.name,
    required this.path,
    required this.exists,
    required this.locked,
    this.branch,
    this.head,
  });

  bool get isDetached => branch == null;

  String get shortBranch =>
      branch == null ? 'detached' : branch!.split('/').last;

  @override
  String toString() => '$name -> $path (${isDetached ? 'detached' : branch})';
}
