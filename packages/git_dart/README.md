# git_dart

<img src="assets/logo/dart_git_mark.png" alt="dart_git logo" width="160">

A pure Dart implementation of git's object system, storage, refs and index,
derived from [`systems/git/v0`](../../git.umsg).

No `git` binary, no FFI, no `libgit2`. Reads and writes real repositories.

## What is implemented

The document's `scope.pinned` layers, plus packfile reading — which the
document describes rather than pins, and without which almost no real
repository can be read at all.

| step | build order (`algorithms.build-order`) | state |
| ---- | -------------------------------------- | ----- |
| 1 | hashing and the loose object | done |
| 2 | the four object formats | done |
| 3 | refs and HEAD | done |
| 4 | the index and checkout | done |
| 5 | commit | `commitTree`, `writeTreeFromIndex` |
| 6 | packfile reading | done, both delta kinds |
| 7 | the walk, merge-base, merge | walk and diff; no merge |
| 8 | pkt-line and fetch | pkt-line only |
| 9 | packfile writing | not started |

Also here: tree diff with exact-rename detection, a Myers text diff with
hunks, `status` against HEAD, the index and the working tree, `.gitignore`
including the user's global excludes, a git config reader, revision syntax
(`HEAD~2^{tree}`), abbreviated object names, alternates, `packed-refs`,
worktree and submodule `.git` files, and the merge stages an unresolved
conflict puts in the index.

Not here: merge, the wire protocols, packfile writing, SHA-256 repositories,
and index version 4 — which is refused with a clear error rather than
half-read. Rename detection finds only exact renames; similarity detection,
which is what finds a file that moved *and* changed, is not implemented. A
checkout cannot set the executable bit, because `dart:io` cannot change file
permissions — such paths come back in `CheckoutResult.degraded` rather than
being silently wrong.

## Using it

```dart
import 'package:git_dart/git_dart.dart';

final repo = Repository.open('.');

print(repo.refs.currentBranch);           // refs/heads/main
print(repo.headCommit!.summary);

for (final commit in repo.log(limit: 20)) {
  print('${commit.id.hex.substring(0, 8)}  ${commit.summary}');
}

final tree = repo.treeOf(repo.headId!)!;
for (final entry in tree.entries) {
  print('${entry.mode} ${entry.name}');
}

final bytes = repo.readFile('lib/main.dart', revision: 'HEAD~3');

for (final change in repo.changesIn(repo.headId!)) {
  print(change);                          // M  lib/main.dart
  final diff = repo.diffBlobs(change.oldId, change.newId);
  print('+${diff.insertions} -${diff.deletions}');
  for (final hunk in diff.hunks) print(hunk);
}

final status = repo.status();
print(status.branch);
for (final entry in status.entries) print(entry);   // ' M lib/main.dart'

repo.checkout('side');                     // refuses if it would lose work

repo.close();
```

The API is synchronous. Reading an object is a file read and an inflate, and
making every call return a Future would cost more than it saves; a UI should
run this library in an isolate instead.

## Verification

Two kinds, kept apart on purpose.

**Vectors.** `test/vectors_test.dart` transcribes the vectors of
`systems/git/v0` by hand, each test naming the vector id it came from. The
three object names in that document were produced by running git 2.53.0, and
this implementation reproduces them.

**Interoperability.** `test/interop_test.dart`, `test/pack_test.dart` and
`test/worktree_test.dart` build repositories with real git and check this
library against `rev-parse`, `ls-tree`, `ls-files`, `write-tree`, `rev-list`,
`cat-file`, `diff --name-status`, `diff --numstat` and `status --porcelain` —
and check that git can read back the objects, indexes and branches this
library writes.

The strongest check in the suite is that every object read out of a pack must
hash to the name it was found under. A delta applied wrongly cannot survive it.

```bash
dart test
```

Two examples point the library at real repositories rather than scratch ones,
which is where the interesting defects were:

```bash
dart run example/inspect.dart <repository>
```

```bash
dart run example/compare_status.dart <repository> [more...]
```

On the Flutter SDK's own repository (3 packs, 1980 packed refs) `inspect` walks
2000 commits in about 0.7s and verifies all 17,266 objects of the head tree.
`compare_status` found three defects the scratch-repository tests could not:
a `.git` directory holding no repository was being opened, the user's global
excludes file was not being read, and an untracked directory was being listed
by file where git reports it as one entry.

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
