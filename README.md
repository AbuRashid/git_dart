# gitexplorer

Git, reimplemented in Dart, and a Flutter explorer built on it.

Both are derived from specifications in this directory, written in
[unimsg](unimsg-v0.umsg) and following
[spec-based design](17-spec-based-design.umsg).

| what | where | derived from |
| ---- | ----- | ------------ |
| the git implementation | [packages/git_dart](packages/git_dart) | [git.umsg](git.umsg) |
| the explorer | [apps/gitexplorer](apps/gitexplorer) | [explorer.umsg](explorer.umsg) |
| the unimsg parser | [packages/unimsg](packages/unimsg) | [unimsg-v0.umsg](unimsg-v0.umsg) |

## git_dart

The object model, loose and packed storage, refs, the index, checkout, diff and
status — no `git` binary, no FFI, no `libgit2`. It reproduces the object names
pinned in `git.umsg` and agrees with git on real repositories: on the Flutter
SDK's own checkout it walks 2000 commits in about 0.7s and verifies every one
of the 17,266 objects in the head tree.

## The explorer

The tree's root is virtual: repositories are added from anywhere on disk and
shown together, because repositories are wherever they were cloned and a tree
rooted at a real folder can only show that accident. A repository opens into its
files at any revision, with a status column on the working tree and a diff
beside each change.

## The specifications

`git.umsg` marks which of its claims were checked against a running git and
which were written from general knowledge, and that split is carried into the
code: the sections the document calls least certain — packs, deltas, framing —
are the ones tested hardest against real git.

`explorer.umsg` was written before the application, and generates part of it.
The palette, the layout measurements, the status vocabulary and the persisted
format version live in that document and are emitted into
`lib/src/generated/tokens.dart`; the test suite fails when the two disagree.
Nothing else is generated — the widgets and the models are written by hand
against the document, which is the smaller and safer claim the method makes.

## Running everything

```bash
cd packages/git_dart && dart test
```

```bash
cd apps/gitexplorer && flutter test --concurrency=1
```

```bash
cd apps/gitexplorer && flutter run -d windows
```

Both suites build repositories with real git and check this code against
`git status`, `git ls-tree`, `git rev-list`, `git write-tree`, `git cat-file`
and `git diff`. Agreement with git is the property that matters; a fixture
written by hand only proves its author consistent.

## What is not here yet

In the library: merge, the wire protocols, and packfile writing.

In the application: delete, rename and move, then branch, checkout and merge.
Fetch, pull and push wait on the transfer protocols in the library — a real
limit with a known cure, not a decision about scope.
