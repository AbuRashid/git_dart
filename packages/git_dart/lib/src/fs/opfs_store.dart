/// Persisting a repository in the browser's private filesystem.
///
/// OPFS — the Origin Private File System — is storage a page gets to itself:
/// no permission prompt, no path anyone else can see, and it survives a reload.
/// It is the only place a browser can keep a repository without asking for
/// anything.
///
/// The repository is *read into* [MemoryGitFs] when it is opened and written
/// back when it changes, rather than being read through OPFS directly. That is
/// not a shortcut. Git's formats are read by seeking around pack files and
/// stat-ing loose paths, so [GitFs] is synchronous all the way up; OPFS only
/// offers synchronous access through `FileSystemSyncAccessHandle`, which exists
/// **only inside a Web Worker**. Loading into memory buys the synchronous
/// reads on the main thread, at the cost of holding the repository in it.
///
/// So this is a store, not a filesystem: two async operations at the edges, and
/// ordinary synchronous git in between. Writing back is incremental — a
/// repository holds thousands of objects that did not change, and
/// [MemoryGitFs.changedPaths] is what keeps the cost of saving proportional to
/// the size of the edit rather than the size of the history.
library;

import 'memory_git_fs.dart';

import 'opfs_unavailable.dart'
    if (dart.library.js_interop) 'opfs_web.dart' as impl;

/// A directory in the browser's private filesystem.
///
/// Nothing here works off the web, where the methods throw rather than
/// pretending: a caller that reaches this on the desktop has a bug, and
/// silently doing nothing would hide it.
class OpfsStore {
  /// Where under OPFS this store keeps things, as a `/`-separated path.
  final String root;

  const OpfsStore(this.root);

  /// Whether this platform has OPFS at all.
  ///
  /// False off the web, and false in a browser too old for it or in a context
  /// that withholds it — a caller should ask rather than assume, because the
  /// answer decides whether the app can hold a repository at all.
  static Future<bool> get isAvailable => impl.isAvailable();

  /// Reads everything under [root] into a fresh in-memory filesystem.
  ///
  /// The result is marked clean: it is what the store already holds, so none
  /// of it needs writing back.
  ///
  /// [under] is the path the repository should appear at, which is what the
  /// rest of git_dart will open it by. It is a name rather than a location —
  /// nothing else can see this filesystem.
  /// [into] reads the repository alongside what is already in that
  /// filesystem, for an application holding several at once.
  Future<MemoryGitFs> load({String under = '/repo', MemoryGitFs? into}) =>
      impl.load(root, under, into);

  /// Writes back what changed and removes what went.
  ///
  /// Marks [memory] clean afterwards, so the next save carries only what
  /// happened since this one.
  Future<void> save(MemoryGitFs memory, {String under = '/repo'}) =>
      impl.save(root, under, memory);

  /// Writes the whole filesystem, whether or not it is marked changed.
  ///
  /// What a first save does, and what to reach for when the store and memory
  /// may have drifted apart.
  Future<void> saveAll(MemoryGitFs memory, {String under = '/repo'}) =>
      impl.saveAll(root, under, memory);

  /// The names directly inside [root] — the repositories being kept.
  Future<List<String>> list() => impl.list(root);

  /// Removes everything under [root].
  Future<void> delete() => impl.delete(root);

  /// Roughly how many bytes OPFS is holding and how many it will allow.
  ///
  /// A browser grants a quota rather than a disk, and a clone that would
  /// exceed it fails partway through — so the size of a repository is worth
  /// knowing before it is fetched rather than after.
  static Future<({int used, int available})?> get usage => impl.usage();
}
