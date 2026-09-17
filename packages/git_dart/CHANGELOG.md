# Changelog

## Unreleased

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
