# git-dart

<img src="packages/git_dart/assets/logo/git_dart_mark.png" alt="git_dart logo" width="160">

Git, reimplemented in pure Dart — and a Flutter application built on it.

[git_dart](packages/git_dart) reads and writes real repositories with no `git`
binary, no FFI and no `libgit2`: objects and packs, refs, the index and working
tree, merge, rebase, cherry-pick and stash, and clone, fetch and push over HTTP,
ssh and `git://`. It runs on the Dart VM, in Flutter, and in a browser.

[Git Explorer](apps/gitexplorer) is its example application: a repository
explorer that browses, edits, stages, commits, clones, fetches, pulls and pushes,
on desktop, mobile and the web.

## What is here

| what | where | derived from |
| ---- | ----- | ------------ |
| the git implementation | [packages/git_dart](packages/git_dart) | [git.umsg](git.umsg) |
| the explorer application | [apps/gitexplorer](apps/gitexplorer) | [explorer.umsg](explorer.umsg) |
| a line-by-line syntax tokeniser, used for code and diffs | [packages/syntax_dart](packages/syntax_dart) | |
| the unimsg parser, formatter, CBOR codec and command-line tool | [packages/unimsg](packages/unimsg) | [unimsg-v0.umsg](unimsg-v0.umsg) |
| renders any unimsg document as a Flutter page | [packages/unimsg_view](packages/unimsg_view) | |
| Notepad++ highlighting for `.umsg` files | [editors/notepad++](editors/notepad++) | |

The specifications are written in [unimsg](unimsg-v0.umsg) and follow
[spec-based design](17-spec-based-design.umsg).

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
cd packages/syntax_dart && dart test
```

```bash
cd packages/unimsg && dart run test/conformance.dart
```

```bash
cd packages/unimsg_view && flutter test
```

```bash
cd apps/gitexplorer && flutter test --concurrency=1
```

```bash
cd apps/gitexplorer && flutter run -d windows
```

The git_dart and Git Explorer suites build repositories with real git and check
this code against it, so `git` must be on the PATH. Agreement with git is the
property that matters; a fixture written by hand only proves its author
consistent.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
