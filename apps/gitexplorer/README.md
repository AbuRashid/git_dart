# Git Explorer

<img src="assets/icon/gitexplorer_mark.png" alt="Git Explorer logo" width="160">

A folder explorer over git repositories, built on
[git_dart](../../packages/git_dart) — the example application for that
library, and a real one: it browses, edits, commits, clones, fetches, pulls and
pushes, on Windows, macOS, Linux, Android, iOS and the web.

Derived from [`apps/gitexplorer/v0`](../../explorer.umsg), which was written
before this code and generates part of it.

## What it does

- **Browse** any repository at the working tree, HEAD, a branch or a commit.
  Files open as the file, its diff or its blame, with syntax colour from
  [syntax_dart](../../packages/syntax_dart); `.umsg` files also open as a
  document page through [unimsg_view](../../packages/unimsg_view).
- **History**: the log, and every commit's changed files with their diffs.
- **Edit** the working tree in place, and add files and folders.
- **Stage and commit**, a file, a folder or everything at once.
- **Ignore** a path, with an offer to stop tracking it when it is tracked.
- **Branches**: rename and delete.
- **Remotes**: add and remove, ahead/behind counts, and fetch, pull and push
  with live progress. A push that would overwrite the remote asks first.
- **Clone** from a URL, with progress in the tree.
- **Submodules**: status, and open one as a repository of its own.
- **Settings**: the git config keys that matter, grouped, each saved for this
  repository or for all of yours.
- **Light, dark or system** theme, and a single-pane layout on narrow screens.

## The virtual root

The top of the tree is a list you assemble, not a directory. Repositories are
added from anywhere and shown together.

A parent folder would have been the wrong unit: repositories are wherever they
were cloned, so a tree rooted at a real directory can only show the accident of
where things landed. Rooting at a list you maintain makes the tree mean
something the filesystem does not record. The cost is that a repository must be
added before it appears — which is the right cost, because it is you saying what
you care about.

Below the root: a repository expands into its directories, directories into
files, and a file opens in the detail pane. Only the working tree carries a
status column, because only it is being compared with anything.

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
git config, so it is the repository your git would have made.

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

Files are not deleted, renamed or moved. Deleting is the one file operation with
nothing to undo it: an untracked file that is deleted is gone and git cannot
help, and an explorer that can silently destroy the only copy of something is a
different and much more dangerous kind of tool.

## Staging and committing

The staging area is shown as the third thing it is: two lists, **Staged** and
**Not staged**, with the same file in both when it has been staged and modified
again since. Every other tool that hides the index ends up explaining it anyway,
in worse words, after someone has been surprised by it.

Stage or unstage a path from either list, from a file's right-click menu in the
tree, a whole directory at once, or everything with Stage all. Staging a path
that is missing from the working tree stages its deletion, which is what
`git add` does. Then write a message and commit: a tree is written from the
index, a commit on top of HEAD, and the current branch moves — or is created, if
this is the first commit.

A commit is refused, with the reason shown, when nothing is staged, when the
message is empty, when the index has conflicts, or when no `user.name` and
`user.email` are configured. A commit attributed to a guess is worse than one
that did not happen.

## Remotes and credentials

Fetch, pull and push work against local folders and HTTP(S) remotes; an ssh
remote is shown, but marked as one this application cannot reach. Pull fetches
and then merges the tracking branch.

When a server asks for credentials the application asks you, and can save them:

- **Desktop** saves through git's own credential helper, and only offers to when
  `credential.helper` is configured — the same place your git would look.
- **Android** keeps them in an encrypted vault whose key lives in the Android
  Keystore behind biometric or device-credential authentication (Android 13 or
  later).
- **The web** never saves them; they last for the session.

## Platforms

```bash
flutter run -d windows
```

Also macOS, Linux, Android, iOS and Chrome.

- **Native.** `git_dart` is synchronous, and all of its work happens in one
  long-lived worker isolate, not one per call: spawning per call would reopen
  the repository each time, which means reading every pack index again. Nothing
  holding a file handle crosses back; the worker's requests and replies are
  plain data.
- **Android** asks for all-files access before a folder is picked, and explains
  why first: without it a folder still opens, but looks empty.
- **The web.** A browser has no folders, so repositories live in memory and are
  saved to the browser's private storage (OPFS), one file per repository, and
  loaded back at startup. They arrive by cloning, by being created, or — in
  browsers that allow it — by uploading a folder. Network requests go through
  `fetch`, so a remote must allow cross-origin requests. The worker runs on the
  page's own thread, so a long clone can pause the interface.

## The hosted demo

`lib/main_demo.dart` is a separate entrypoint for a public, sandboxed demo. On
a visitor's first load it unpacks a git bundle of this repository into their
browser, so the app opens on its own source; everything they do changes only
their copy. It adds a way to download the code and a way to reset.

```bash
tool/build_demo.sh <app-slug>
```

builds it for serving from `/apps/<app-slug>/` and zips the web build with the
bundle, refusing when the zip is over the 25 MB a takhzeen app upload allows.

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

Everything else — the widgets, the worker protocol, the models — is written by
hand against the document. Generating those would be a much larger claim than
this method makes.

The launcher icons, favicon and Windows icon are all produced from
`assets/icon/gitexplorer_mark.png` by `tool/generate_icon.py`.

## Tests

```bash
flutter test --concurrency=1
```

`git` must be on the PATH. `test/explorer_test.dart` covers the saved state, the
generated tokens and the worker — opening, cloning, history, blame, writing,
staging and committing, remotes, fetch, pull, push and submodules — against
repositories built by real git and checked against it. `test/ui_test.dart`
drives the panes against that same real worker.

Two things about testing this application, both learned the hard way and worth
knowing before adding a test: isolate messages are real asynchrony, so the work
must happen inside `tester.runAsync`; and `pumpAndSettle` never settles while a
progress indicator is on screen, so these tests pump frames explicitly.

## Not built yet

Deleting, renaming and moving files; creating a branch, checking one out, and
merging from the interface (a pull merges already); a file's own history, which
the worker can load but nothing yet asks for; and ssh remotes.
