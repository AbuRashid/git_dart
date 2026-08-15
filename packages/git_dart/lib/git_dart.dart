/// A pure Dart implementation of git's object system, storage, refs and index.
///
/// Derived from `systems/git/v0` (git.umsg). The pinned layers of that document
/// — objects, loose storage, refs, the index — are implemented here, along with
/// packfile reading, which the document describes rather than pins and which is
/// required to read any real repository.
///
/// The API is synchronous. Reading an object is a file read and an inflate;
/// callers on a UI thread should run this library in an isolate rather than
/// have every call pay for a Future.
library;

export 'src/config/config_writer.dart';
export 'src/config/git_config.dart';
export 'src/diff/text_diff.dart';
export 'src/diff/tree_diff.dart';
export 'src/index/git_index.dart';
export 'src/merge/cherry_pick.dart';
export 'src/merge/merge.dart';
export 'src/merge/rebase.dart';
export 'src/merge/sequencer.dart';
export 'src/object_id.dart';
export 'src/objects/commit.dart';
export 'src/objects/git_object.dart';
export 'src/objects/identity.dart';
export 'src/objects/tag.dart';
export 'src/objects/tree.dart';
export 'src/refs/ref_store.dart';
export 'src/refs/reflog.dart';
export 'src/remote/remote.dart';
export 'src/repository.dart';
export 'src/storage/loose_object_store.dart';
export 'src/storage/object_store.dart';
export 'src/storage/pack_file.dart';
export 'src/storage/pack_index.dart';
export 'src/storage/pack_index_writer.dart';
export 'src/storage/pack_indexer.dart';
export 'src/storage/pack_parser.dart';
export 'src/storage/repack.dart';
export 'src/storage/pack_writer.dart';
export 'src/transfer/connection.dart';
export 'src/transfer/credentials.dart';
export 'src/transfer/fetch.dart';
export 'src/transfer/negotiator.dart';
export 'src/transfer/pkt_line.dart';
export 'src/transfer/protocol_v2.dart';
export 'src/transfer/push.dart';
export 'src/worktree/attributes.dart';
export 'src/worktree/checkout.dart';
export 'src/worktree/ignore.dart';
export 'src/worktree/reset.dart';
export 'src/worktree/stash.dart';
export 'src/worktree/status.dart';
