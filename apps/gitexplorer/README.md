# gitexplorer

A folder explorer over git repositories, built on [git_dart](../../packages/git_dart).

Derived from [`apps/gitexplorer/v0`](../../explorer.umsg), which was written
before this code and generates part of it.

## The virtual root

The top of the tree is a list you assemble, not a directory. Repositories are
added from anywhere on disk and shown together.

A parent folder would have been the wrong unit: repositories are wherever they
were cloned, so a tree rooted at a real directory can only show the accident of
where things landed. Rooting at a list you maintain makes the tree mean
something the filesystem does not record. The cost is that a repository must be
added before it appears — which is the right cost, because it is you saying what
you care about.

Below the root: a repository expands into its directories, directories into
files, and a file opens in the detail pane. Each repository is viewed at a
revision — the working tree, HEAD, a branch or a commit — and only the working
tree carries a status column, because only it is being compared with anything.

## Choosing a folder that holds no repository

It offers to create one. Declining adds nothing.

The first version added the folder anyway and marked it with an error icon,
which is the worst of both answers: it says something is wrong, does not say
what would fix it, and leaves a permanent row to remove by hand. A folder
without a repository in it is not a failure — it is the ordinary state of a
folder — so it does not get a failure's icon, and it gets the one action that
changes it.

Only that case is offered. A folder that is not there has nowhere to write, and
a repository that exists but failed to open must never be initialised over —
that would be destroying something on the strength of not understanding it.
Choosing a subdirectory of a repository finds that repository, so nothing
nested is ever created.

The new repository takes its branch name from `init.defaultBranch` in your own
git config — system, global and repository, in git's order — so it is the
repository your git would have made.

## Editing

A file open at the working tree is editable in place: type, then Save (or
Ctrl+S). A changed file opens on the file rather than on its diff, because the
file is the thing you can act on; the diff is one click away. Directories take
a new file or a new folder from their right-click menu, and a new folder is
created in full, so `lib/src/generated` is one action.

Three rules worth knowing:

- **Only the working tree is editable.** HEAD, a branch and a commit are views
  of objects, and an object cannot be edited — only replaced by a different
  object with a different name. An editor over a commit would be offering to
  rewrite history while appearing to fix a typo.
- **Unsaved edits survive navigation.** Move the selection elsewhere and come
  back and the draft is still there, with the file marked unsaved in the tree.
  Losing work to a stray click is not a trade worth making for simpler code.
- **A stale save is refused.** A save carries the size and timestamp the file
  had when it was opened. If something else wrote to the file since — another
  editor, a build, a checkout — the save is refused and your draft is kept,
  rather than silently discarding what the other writer did.

Nothing is deleted, renamed or moved. Deleting is the one operation here with
nothing to undo it: an untracked file that is deleted is gone and git cannot
help, and an explorer that can silently destroy the only copy of something is a
different and much more dangerous kind of tool.

## Staging and committing

The staging area is shown as the third thing it is: two lists, **Staged** and
**Not staged**, with the same file in both when it has been staged and modified
again since. Every other tool that hides the index ends up explaining it anyway,
in worse words, after someone has been surprised by it.

Stage or unstage a path from either list, from a file's right-click menu in the
tree, or a whole directory at once. Staging a path that is missing from the
working tree stages its deletion, which is what `git add` does. Then write a
message and commit: a tree is written from the index, a commit on top of HEAD,
and the current branch moves — or is created, if this is the first commit.

A commit is refused, with the reason shown, when nothing is staged, when the
message is empty, when the index has conflicts, or when no `user.name` and
`user.email` are configured. A commit attributed to a guess is worse than one
that did not happen.

Known gap: the reflog is not written. A repository this application commits to
will have a gap in `git reflog` where those commits are.

## What is built

Browsing at any revision, diff, status, history, editing the working tree,
adding files and folders, creating a repository, staging, and committing.

Next: delete, rename and move; then branch, checkout and merge. Fetch, pull and
push wait on the transfer protocols in `git_dart`, which that library describes
and does not yet implement.

## Generated from the specification

`explorer.umsg` holds the facts that would otherwise be written in several
places — the palette, the layout measurements, the status vocabulary, the entry
kinds, the persisted format version. They are emitted into
`lib/src/generated/tokens.dart`:

```bash
dart run tool/generate_tokens.dart
```

```bash
dart run tool/generate_tokens.dart --check
```

The check mode fails when the generated file does not match the document, and
runs as part of the test suite. Without it the document would be a suggestion,
and the first hand edit to the generated file would leave the two silently
disagreeing.

Everything else — the widgets, the isolate protocol, the models — is written by
hand against the document. Generating those would be a much larger claim than
this method makes.

## Concurrency

`git_dart` is synchronous, and its calls are file reads and inflates. All of
them happen in one long-lived worker isolate, not one per call: spawning per
call would reopen the repository each time, which means reading every pack index
again — on a large repository that is most of the cost of the work.

Nothing holding a file handle crosses back. The worker's requests and replies
are plain data, and there is no way to ask it for a `Repository`, so there is no
way for one to leak into the UI.

## Running it

```bash
flutter run -d windows
```

Also builds for macOS, Linux, Android and iOS. Not the web: the library reads
files and inflates zlib through `dart:io`, which a browser does not have.

## Tests

```bash
flutter test --concurrency=1
```

`test/explorer_test.dart` covers the persisted list, the generated tokens and
the worker, all against a repository built by real git and checked against
`git status`, `git ls-tree`, `git rev-list` and `git diff --numstat`.
`test/ui_test.dart` drives the panes against that same real worker.

Two things about testing this application, both learned the hard way and worth
knowing before adding a test: isolate messages are real asynchrony, so the work
must happen inside `tester.runAsync`; and `pumpAndSettle` never settles while a
progress indicator is on screen, so these tests pump frames explicitly.
