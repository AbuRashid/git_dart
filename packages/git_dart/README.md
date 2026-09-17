# git_dart

<img src="assets/logo/git_dart_mark.png" alt="git_dart logo" width="160">

Git, implemented in pure Dart: objects and packs, refs, the index and the
working tree, history operations, and the network protocols.

No `git` binary, no FFI, no `libgit2`. It reads and writes real repositories —
ones git made, and ones git can read back — on the Dart VM, in Flutter, and in a
browser.

Derived from [`systems/git/v0`](../../specs/git.umsg).

## What it does

| area | what is here | main entry points |
| ---- | ------------ | ----------------- |
| objects and storage | loose objects, packs with both delta kinds, alternates, commit-graph read and write | `Repository.init` / `open` / `discover`, `writeObject`, `commitTree`, `writeCommitGraph` |
| refs | loose and packed refs with locking, the reflog, revision syntax (`HEAD~2^{tree}`, `:path`, `:/message`, `@{n}`, `@{-n}`), branches, lightweight and annotated tags, upstreams and ahead/behind | `resolve`, `createBranch`, `renameBranch`, `deleteBranch`, `createTag`, `trackingFor`, `countAheadBehind` |
| index and working tree | index v2 and v3, staging, status, checkout, reset (soft, mixed, hard), `.gitignore` with global excludes, `.gitattributes` (eol conversion and clean/smudge filter drivers), sparse checkout, linked worktrees, submodules (read) | `stage`, `unstage`, `commitIndex`, `status`, `checkout`, `reset`, `setSparseCheckout`, `Repository.filters` |
| diff | tree diff with exact and similarity rename detection, Myers line diff with hunks, blame, file history that follows renames | `diff`, `changesIn`, `diffBlobs`, `blame`, `fileHistory` |
| history | three-way merge with a recursive merge base and rename detection (rename/modify, rename/rename, rename/delete and rename/add handled as git's `ort` does; no directory renames), fast-forwards, conflict markers and index stages; rebase; cherry-pick and revert; stash | `merge`, `abortMerge`, `rebase`, `cherryPick`, `revert`, `stashSave`, `stashPop` |
| hooks | client-side hooks run where git runs them: `pre-commit`, `prepare-commit-msg`, `commit-msg`, `post-commit`, `pre-merge-commit`, `post-merge`, `post-checkout`, `pre-rebase`, `pre-push`; `core.hooksPath`; `noVerify`; in-process hooks | `Repository.hooks`, `HookRunner`, `HookFailedException` |
| more | describe, notes (read), mailmap, config reading and writing at system, global and local scope | `describe`, `noteFor`, `Mailmap`, `GitConfig`, `ConfigWriter` |
| packs | pack writing with delta compression, indexing, repack, gc | `PackWriter`, `repack`, `gc` |
| transfer | clone, fetch, push, each over smart HTTP(S), ssh, `git://` and local paths; protocol v0 and v2; shallow and partial clones; HTTP credentials; force and force-with-lease | `clone`, `fetch`, `push`, `Credentials`, `PushLease` |
| portable files | bundles, and tar or zip archives of any tree | `writeBundle`, `unbundle`, `writeArchive` |
| signatures | signing and verifying commits and annotated tags in OpenPGP, X.509 and SSH formats, by running `gpg`, `gpgsm` or `ssh-keygen` as git does; `commit.gpgSign`, `tag.gpgSign`, `gpg.format`, `user.signingKey`, `gpg.minTrustLevel`, `gpg.ssh.allowedSignersFile`; a pluggable tool for in-process signing | `verifyCommit`, `verifyTag`, `commitIndex(sign:)`, `createTag(sign:)`, `SignatureTool`, `ProcessSignatureTool` |

## Using it

```dart
import 'package:git_dart/git_dart.dart';

final repo = Repository.open('.');

print(repo.refs.currentBranch);                   // refs/heads/main
for (final commit in repo.log(limit: 20)) {
  print('${commit.id.hex.substring(0, 8)}  ${commit.summary}');
}

for (final entry in repo.status().entries) {
  print('${entry.code} ${entry.path}');           // ' M lib/main.dart'
}

repo.stage('lib/main.dart');
repo.commitIndex(message: 'Tidy main');           // author from user.name/email

repo.createBranch('side');
repo.checkout('side');                            // refuses if it would lose work

final result = merge(repo, repo.resolve('main')!);
print(result.outcome);                            // MergeOutcome.merged

for (final change in repo.changesIn(repo.headId!)) {
  final diff = repo.diffBlobs(change.oldId, change.newId);
  print('${change.path} +${diff.insertions} -${diff.deletions}');
}

repo.close();
```

[`example/example.dart`](example/example.dart) is a complete tour — init,
commit, status, branches, merge, log, diff, blame, bundles and archives — in a
scratch directory:

```bash
dart run example/example.dart
```

### Synchronous, except the network

Working with a repository is synchronous. Reading an object is a file read and
an inflate, and making every call return a Future would cost more than it saves;
an application with a UI should run this library in an isolate.

What waits on something outside the process is asynchronous: `clone`, `fetch`,
`fetchObjects`, `push` and `mergeTrackingRef` (the merge half of a pull).

```dart
final cloned = await clone('https://example.com/project.git', 'project');
```

## Platforms

On the Dart VM and in Flutter, repositories are folders and everything works.

In a browser there is no filesystem and no general network access, so the
library runs against what the application supplies:

- **A filesystem.** `MemoryGitFs` holds repositories in memory; install it with
  `useGitFileSystem`. `OpfsStore` saves a repository to the browser's private
  storage and loads it back, one file per repository, using the portable
  archive in `memory_archive`. `pickDirectoryInto` copies a folder the user
  picks into memory, where the browser supports it.
- **An HTTP client.** Install one with `useGitHttpClient`. The library refuses
  on its own, because whether a request can be made from a page is a question
  about CORS only the application can answer — a same-origin server, a proxy,
  or a remote that allows it.

zlib is pure Dart there, 64-bit reads avoid integers dart2js cannot hold, and
there is no global git config or excludes file to read. ssh and `git://` need
`dart:io` and are not available in a browser. Nor are hook scripts: a browser
runs no processes, so a repository there behaves as if it had no hooks unless
the application supplies them as Dart callbacks with `HookRunner.inProcess`.

## Limits

- **SHA-256 repositories** are not supported.
- **Index version 4** is refused with a clear error rather than half-read.
- **File modes on checkout.** Where the platform cannot set the executable bit or
  create a symlink, those paths come back in `CheckoutResult.degraded` rather
  than being silently wrong. Staging keeps a file's existing mode.
- **Push** goes over every transport, in protocol v0 only (as git's own client
  does; v2 has no push). There are no atomic pushes, push options or ref
  deletions, and a `git://` push needs a daemon started with
  `--enable=receive-pack`.
- **Filter drivers** run `filter.<driver>.clean` and `.smudge` commands through
  `sh`; the long-running `filter.<driver>.process` protocol (`git lfs
  filter-process`) is not supported, and neither is LFS's network protocol. In
  a browser, commands cannot run: register an in-process `FilterDriver` instead.
- Notes and submodules are read, not written. Rebase is not interactive. There
  are no credential helpers and no dumb HTTP transport.
- **Signatures** are made and checked by external programs, as git does, so
  the default `SignatureTool` needs `dart:io`; a browser app must supply its
  own. `gpg.ssh.defaultKeyCommand` is not run — SSH signing needs
  `user.signingKey` — and SHA-256-era `gpgsig-sha256` signatures are ignored.
  Because the API is synchronous, a payload git would pipe to the program is
  fed from a temporary file through `sh` or `cmd`.

## Verification

Two kinds, kept apart on purpose.

**Vectors.** `test/vectors_test.dart` transcribes the vectors of
`systems/git/v0` by hand, each test naming the vector it came from. The object
names in that document were produced by running git 2.53.0, and this
implementation reproduces them.

**Interoperability.** Nearly every other test builds repositories with real
git and checks this library against it — object names, trees, the index,
status, diffs, merges, packs — and checks that git can read back what this
library writes: objects, indexes, packs, branches, commits and bundles. The
transfer tests run against local HTTP servers, ssh, and `git daemon` where it is
installed.

The strongest single check is that every object read out of a pack must hash to
the name it was found under. A delta applied wrongly cannot survive it.

```bash
dart test
```

`git` must be on the PATH. Two more examples point the library at real
repositories rather than scratch ones, which is where the interesting defects
were:

```bash
dart run example/inspect.dart <repository>
```

```bash
dart run example/compare_status.dart <repository> [more...]
```

`compare_status` found three defects the scratch-repository tests could not: a
`.git` directory holding no repository was being opened, the user's global
excludes file was not being read, and an untracked directory was being listed by
file where git reports it as one entry.

## Provenance

`git.umsg` marks which of its claims were checked against git and which were
written from general knowledge. That split is carried into the code: comments
cite the section they come from, and the parts derived from the document's
`described` sections — packs, deltas, pkt-line framing — are the ones tested
hardest against real git, because the document itself says they are the most
likely to contain an error.

Hand-written, not generated. `method/spec-based-design/v0` would have the
vectors generated into tests rather than transcribed; they are transcribed
here, which is the weaker link that document names, and it is named again here
for the same reason.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
