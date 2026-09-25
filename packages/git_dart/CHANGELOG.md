# Changelog

## 0.4.0

- A path that is not valid UTF-8 survives the index. `IndexEntry` keeps the
  name's bytes (`rawPath`), renders them for display (`path`), and says
  whether the rendering is faithful (`pathIsText`); entries sort by bytes, as
  git sorts them. Reading an index and writing it back used to replace each
  bad byte with U+FFFD and encode that, which renamed the file — silently,
  during whatever unrelated operation happened to rewrite the index.
- A repaired name no longer addresses a file. `Tree.entryNamed` and
  `Repository.lookup` compare bytes, so two names that render alike — `78 ff`
  and `78 fe` both show as `x` followed by U+FFFD — are no longer the same
  key, and a name a string cannot spell is reached through
  `Tree.entryWithRawName` or `Repository.lookupRaw` instead of by whichever
  entry happened to come first. `status` lists such tracked paths in
  `unrepresentable`, so a caller can say so rather than offering an action
  that would reach the wrong file.
- A repository can be opened for inspection:
  `Repository.open(path, access: RepositoryAccess.inspection)`. Nothing the
  repository's own configuration names is run — no `filter.<driver>` command,
  no hook, no signing or verifying program — nothing is written, and fetch
  and push are refused. A repository's `.git/config` can name programs, and
  git runs them; anything that opens repositories it did not create needs to
  be able to decline that without enumerating every driver. Filter drivers
  the caller registered itself still run: those are the caller's code, not
  the repository's. Where a configured filter was skipped, `status` lists the
  path in `unnormalised` rather than passing an unnormalised comparison off
  as an ordinary one.
- Long reads can be told to stop. `Cancellation` is asked between units of
  work — one commit, one file — by `log`, `status`, `blame` and
  `fileHistory`, which throw `CancelledException` rather than returning a
  short answer that cannot be told from a complete one. Nothing here becomes
  interruptible: these calls are synchronous and hold their thread, so what
  this buys is work that stops at the next boundary instead of running to the
  end for an answer nobody wants.
- An object's kind and size can be asked for without building it:
  `ObjectStore.statObject`, and `readRawUpTo` / `Repository.readFileUpTo`,
  which refuse an object larger than a given bound and say how large it is.
  Every storage form states the size somewhere small — a loose object in the
  header at the front of its stream, a packed one in its pack header, a delta
  in the delta's own — so a caller that will not show a large file no longer
  has to inflate one to find out. The result is typed: too large, missing and
  empty are three answers rather than one.
- A pack's object cache is bounded by bytes rather than by how many objects
  it holds, and the bound can be set per pack (`PackFile.cacheBytes`,
  64 MiB by default). Two hundred and fifty-six trees and two hundred and
  fifty-six video files are not the same amount of memory.
- `status` pairs staged renames. A move is an addition and a deletion in the
  index, as it is in a tree, and status reported it as two unrelated changes
  while tree diffs had inferred the pairing for releases. `StatusEntry` gains
  `oldPath`, `status` gains `detectRenames`, `renameThreshold` and
  `renameLimit` with the same meanings and defaults as `diffTrees`, and the
  pairing uses the same two passes — exact content first, then similarity.
- Index version 4 is read. Its paths are prefix-compressed against the entry
  before them — a count of bytes to drop, in git's own variable-width
  encoding, then the rest — and entries carry no padding. A repository git
  wrote with `index.version = 4`, or converted with `update-index
  --index-version 4`, previously refused every index-dependent operation,
  status among them. Writing still produces version 2, or 3 where a flag
  needs it, which git reads back unchanged.
- A repository whose `extensions.objectFormat` is not `sha1` is refused when
  it is opened, with `UnsupportedObjectFormatException` naming the format.
  Such a repository used to open and then fail at the first object id read,
  complaining about the length of an id that was perfectly good. Reading
  SHA-256 repositories is still not supported; this makes the refusal say so.

## 0.3.1

- New `abortApply`, which abandons a cherry-pick or revert that stopped on
  conflicts: the index and working tree go back to where it started and the
  sequencer state and `MERGE_MSG` are removed. Rebase already had
  `abortRebase`.
- `continueApply` and `continueRebase` take an optional `message`, which
  replaces the stopped commit's own, as editing it on `--continue` does.
- `continueApply` refuses when the operation in progress is a rebase, instead
  of finishing one step of it as though it were a cherry-pick.

## 0.3.0

- `RemoteStore.rename` now does what `git remote rename` does: the tracking
  refs (loose and packed) and their reflogs move to the new name, the fetch
  refspecs are rewritten, `pushurl` and other settings are kept, and branches
  whose `remote` or `pushRemote` named the old remote follow it. It previously
  removed the remote and added it back, which dropped all of these. Renaming
  onto an existing remote is refused.
- `Repository.setUpstream` writes into an existing `[branch "<name>"]` section
  instead of appending another one, so setting it twice no longer leaves two
  `branch.<name>.merge` values. It refuses a branch that does not exist.
- New `Repository.unsetUpstream`, as `git branch --unset-upstream`.

## 0.2.0

- `push` works over ssh and `git://` as well as local paths and HTTP(S),
  taking an `sshCommand` as `fetch` does. Over those duplex transports the
  server's progress and hook output reach `onProgress` via side-band.
- `merge` (and cherry-pick, revert, rebase and stash, which share it) now
  detects renames like git's `ort` strategy: an edit follows a file renamed on
  the other side, and rename/rename, rename/delete and rename/add conflicts are
  staged as git stages them. Honours `merge.renames`, `diff.renames` and
  `merge.renameLimit`; directory renames are not detected. A conflict where one
  side deleted the file now leaves the surviving version in the working tree
  without markers, as git does. `pairRenames` exposes rename pairing over a
  precomputed change list.
- Clean/smudge filter drivers (`filter=<driver>` in `.gitattributes`) are applied
  when staging, in status, and wherever blobs are written to the working tree
  (checkout, reset, restore, stash, merge), in git's order relative to eol
  conversion. Drivers come from `filter.<driver>.clean`/`.smudge` config
  commands, or in-process from `Repository.filters` / `FilterDriver.registry`
  (the only option on the web). Stash, restore and merge now also apply eol
  conversion, which they previously skipped.
- Client-side hooks: commits, merges, checkouts, rebases and pushes run
  `pre-commit`, `prepare-commit-msg`, `commit-msg`, `post-commit`,
  `pre-merge-commit`, `post-merge`, `post-checkout`, `pre-rebase` and
  `pre-push` as git does, honouring `core.hooksPath`, with `noVerify` options
  and a replaceable `Repository.hooks` runner (`HookRunner.disk`, `.none`,
  `.inProcess`). A refusing hook throws `HookFailedException` with its output.
- Signed commits and tags: `Repository.verifyCommit` / `verifyTag` check
  OpenPGP, X.509 and SSH signatures with `gpg`, `gpgsm` or `ssh-keygen`,
  reaching the verdicts `git verify-commit` and `%G?` do; `commitIndex`,
  `commitTree` and `createTag` sign on request or per `commit.gpgSign` /
  `tag.gpgSign`, in the `gpg.format` configured. `SignatureTool` lets an app
  supply its own signer; on the web the default throws `UnsupportedError`.
- API docs no longer carry broken references.

## 0.1.1

- Web is now a supported platform on pub.dev. The ssh and `git://` transports
  (`SshConnection`, `DaemonConnection`) and `IoGitFs` were the only parts
  importing `dart:io` unconditionally; they now come from conditional imports,
  with browser stand-ins that throw a clear `UnsupportedError`.
- `splitSshCommand` is available as a top-level function.

## 0.1.0

First release.

- Objects and storage: loose objects, packs with both delta kinds, alternates,
  commit-graph.
- Refs: loose and packed refs, the reflog, revision syntax, branches, tags,
  upstreams and ahead/behind counts.
- Index and working tree: staging, commits, status, checkout, reset,
  `.gitignore`, `.gitattributes`, sparse checkout, linked worktrees, and
  submodules (read).
- Diff: tree diff with exact and similarity rename detection, line diffs,
  blame and file history.
- History: three-way merge, rebase, cherry-pick, revert and stash.
- Packs: writing with delta compression, repack and gc.
- Transfer: clone, fetch and push over HTTP(S), ssh, `git://` and local paths;
  protocol v0 and v2; shallow and partial clones; force-with-lease.
- Bundles, and tar and zip archives.
- Config reading and writing.
- Runs in a browser with an in-memory filesystem, OPFS storage and an
  application-supplied HTTP client.
