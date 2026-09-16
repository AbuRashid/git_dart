# Changelog

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
