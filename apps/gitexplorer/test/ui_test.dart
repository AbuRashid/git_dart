/// What the panes draw.
///
/// These run against a real worker and a real repository built by git, rather
/// than a stubbed state: the interesting failures in this application are in
/// the seam between the tree and what git actually reports, and a fake on both
/// sides of that seam would test nothing.
///
/// Two things follow from using the real worker, and both were learned the
/// hard way. Isolate messages are real asynchrony, so the work has to happen
/// inside `tester.runAsync`; and `pumpAndSettle` never settles while a
/// progress indicator is on screen, so these tests pump frames explicitly.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitexplorer/main.dart';
import 'package:gitexplorer/src/generated/tokens.dart';
import 'package:gitexplorer/src/models.dart';
import 'package:gitexplorer/src/repository_store.dart';
import 'package:gitexplorer/src/state.dart';
import 'package:gitexplorer/src/theme.dart';
import 'package:gitexplorer/src/ui/tree_pane.dart';
import 'package:path/path.dart' as p;
import 'package:unimsg_view/unimsg_view.dart';

late Directory scratch;
late String repoPath;

String git(List<String> arguments) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: repoPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout as String;
}

void write(String relative, String contents) {
  final file = File(p.join(repoPath, relative.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

int _n = 0;

/// Builds the page at a desktop size, with one repository already added.
Future<ExplorerState> pumpExplorer(
  WidgetTester tester, {
  Size size = const Size(1200, 800),
  bool withRepository = true,
}) async {
  final support = Directory(p.join(scratch.path, 'support${_n++}'))
    ..createSync(recursive: true);

  late final ExplorerState state;
  await tester.runAsync(() async {
    state = ExplorerState(
      store: storeIn(support),
    );
    await state.start();
    if (withRepository) await state.addRepository(repoPath);
  });
  addTearDown(state.dispose);

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: explorerTheme(Brightness.light),
      home: ExplorerPage(state: state),
    ),
  );
  await tester.pump();
  return state;
}

/// Runs real asynchronous work and then draws the result.
Future<void> act(WidgetTester tester, Future<void> Function() work) async {
  await tester.runAsync(work);
  await tester.pump();
}

/// Taps something whose handler talks to the worker.
///
/// A plain [WidgetTester.tap] runs the handler in the test's fake-async zone,
/// where a reply from the isolate never arrives and the handler stalls
/// half-way. Real time has to be allowed to pass.
Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
  // Frames cannot be pumped inside runAsync and worker replies do not arrive
  // outside it, so the two are interleaved: pump to finish the animation and
  // let the handler reach its await, give real time for the reply, then pump
  // again to draw what came back.
  // Several times over, because one action can be several round trips: ignore,
  // then refresh the summary, then reload every open directory.
  await tester.tap(finder);
  for (var i = 0; i < 8; i++) {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
  }
  await tester.pumpAndSettle();
}

/// Taps something whose handler talks to the worker and whose result, while
/// it is awaited, is a spinner rather than the old screen.
///
/// [tapAndWait]'s `pumpAndSettle` never returns here: a `CircularProgress
/// Indicator` schedules a frame for as long as it is on screen, which is
/// exactly the shape `pumpAndSettle` treats as never having settled. This
/// pumps a bounded number of times instead, the same way the plain
/// `tester.pump` calls elsewhere in this file give a real worker reply time
/// to land.
Future<void> tapAndDrain(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump();
  }
}

/// A store that keeps its file in [directory].
///
/// The store itself takes read and write functions rather than a directory,
/// because it has to compile for the web, where there is no directory to be
/// given. Putting the file back is the test's business.
RepositoryStore storeIn(Directory directory) {
  final file = File(p.join(directory.path, RepositoryStore.fileName));
  return RepositoryStore(
    read: (_) async => file.existsSync() ? file.readAsStringSync() : null,
    write: (_, value) async {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(value);
    },
  );
}

void main() {
  setUpAll(() {
    scratch = Directory.systemTemp.createTempSync('gitexplorer_ui');
    repoPath = p.join(scratch.path, 'repo');
    Directory(repoPath).createSync(recursive: true);

    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 'A']);
    git(['config', 'user.email', 'a@x']);

    write('README.md', '# demo\n');
    write('lib/main.dart', 'void main() {}\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'first commit']);

    write('README.md', '# demo\nchanged\n');
    write('scratch.txt', 'untracked\n');
  });

  tearDownAll(() => scratch.deleteSync(recursive: true));

  testWidgets('the virtual root shows the repository with its branch',
      (tester) async {
    await pumpExplorer(tester);

    expect(find.text('Repositories'), findsOneWidget);
    expect(find.text('repo'), findsOneWidget);
    expect(find.text('main'), findsOneWidget); // the branch chip
    expect(find.text('Select a repository or a file'), findsOneWidget);
  });

  testWidgets('expanding a repository lists its files with their state',
      (tester) async {
    final state = await pumpExplorer(tester);
    await act(tester, () => state.toggle(repoPath, ''));

    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('lib'), findsOneWidget);
    expect(find.text('scratch.txt'), findsOneWidget);

    // The status letters of `status-vocabulary`, and nothing on a clean file.
    expect(find.text('M'), findsOneWidget);
    expect(find.text('?'), findsOneWidget);
  });

  testWidgets('a folder has a chevron, and it turns when it opens',
      (tester) async {
    final state = await pumpExplorer(tester);
    await act(tester, () => state.toggle(repoPath, ''));

    // The repository is open so its chevron has turned; `lib` is closed and
    // has one of its own, which is the thing that was missing.
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await act(tester, () => state.toggle(repoPath, 'lib'));
    // The repository and the folder are both open now.
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsNWidgets(2));

    // A file is not something that opens, so it has no chevron of its own.
    expect(find.byIcon(Icons.insert_drive_file_outlined), findsWidgets);
  });

  testWidgets('a file is drawn in the colour for its state', (tester) async {
    final state = await pumpExplorer(tester);
    await act(tester, () => state.toggle(repoPath, ''));

    final context = tester.element(find.text('M'));
    expect(tester.widget<Text>(find.text('M')).style?.color,
        statusColor(FileState.modified, context));
    expect(tester.widget<Text>(find.text('?')).style?.color,
        statusColor(FileState.untracked, context));
  });

  testWidgets('selecting a repository shows its history', (tester) async {
    final state = await pumpExplorer(tester);
    await act(tester, () => state.selectRepository(repoPath));

    // History is the tab a repository opens on.
    expect(find.text('History'), findsOneWidget);
    expect(find.text('first commit'), findsOneWidget);
    expect(find.textContaining('changed'), findsWidgets); // a fact chip
    expect(find.text('Working tree'), findsOneWidget); // the revision button
  });

  testWidgets('a changed file shows the diff and says what it is against',
      (tester) async {
    final state = await pumpExplorer(tester);
    await act(tester, () => state.selectFile(repoPath, 'README.md'));

    // It opens on the file, since that is what can be acted on; the diff is
    // one click away (`editing.a-changed-file-opens-on-the-file`).
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.text('Diff'));
    await tester.pump();

    // One line added, none removed — and the pair being compared is named,
    // because a diff with no label invites the reader to assume the wrong one.
    expect(
      find.text('Between HEAD and the working tree · +1 −0'),
      findsOneWidget,
    );
    expect(find.text('changed'), findsOneWidget); // the added line

    // The hunk header git itself prints for this change.
    final header = git(['diff', '-U3', '--', 'README.md'])
        .split('\n')
        .firstWhere((line) => line.startsWith('@@'))
        .trim();
    expect(find.text(header), findsOneWidget);
  });

  testWidgets('a clean file shows its contents rather than a diff',
      (tester) async {
    final state = await pumpExplorer(tester);
    await act(tester, () => state.selectFile(repoPath, 'lib/main.dart'));

    // At the working tree the contents are shown in an editor rather than as
    // static text, and there is no diff to offer for a clean file.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'void main() {}\n',
    );
    expect(find.text('Diff'), findsNothing);
    expect(find.text('Save'), findsNothing); // nothing edited yet
  });

  testWidgets('a historical revision drops the status column', (tester) async {
    final state = await pumpExplorer(tester);
    await act(tester, () => state.setRevision(repoPath, Revision.head));
    await act(tester, () => state.toggle(repoPath, ''));

    // At HEAD nothing is compared with anything, so nothing is marked
    // (`revisions.only-the-working-tree-has-status`).
    expect(find.text('M'), findsNothing);
    expect(find.text('?'), findsNothing);
    // And a file that exists only on disk is not in a tree at all.
    expect(find.text('scratch.txt'), findsNothing);
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('a commit shows the files it changed', (tester) async {
    final state = await pumpExplorer(tester);
    final head = git(['rev-parse', 'HEAD']).trim();
    await act(tester, () => state.selectCommit(repoPath, head));

    expect(find.text('Changed files (2)'), findsOneWidget);
    expect(find.text('lib/main.dart'), findsOneWidget);
    expect(find.text('Select a file to see what changed'), findsOneWidget);
  });

  testWidgets(
      'going back from a commit reached by blame returns to blame, not history',
      (tester) async {
    final state = await pumpExplorer(tester);
    final head = git(['rev-parse', 'HEAD']).trim();
    final shortHead = head.substring(0, 8);

    await act(tester, () => state.selectFile(repoPath, 'lib/main.dart'));
    // Loaded ahead of the tap below, so switching to the tab is a plain
    // `setState` with nothing to await - `loadBlame` is idempotent, so the
    // tab's own call to it when tapped is a no-op over the same answer.
    await act(
      tester,
      () => state.loadBlame(
        repoPath,
        state.revisionFor(repoPath),
        'lib/main.dart',
      ),
    );
    await tester.tap(find.text('Blame'));
    await tester.pump();
    expect(find.textContaining(shortHead), findsOneWidget);

    // The one line there is blamed on the one commit there is; tapping its
    // attribution opens that commit.
    await tapAndDrain(
      tester,
      find
          .ancestor(
            of: find.textContaining(shortHead),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(find.text('Changed files (2)'), findsOneWidget);

    // Back returns to the file's Blame tab, not the repository's history -
    // blame is where this commit was reached from, not History.
    await tapAndDrain(tester, find.byIcon(Icons.arrow_back));
    expect(find.text('Changed files (2)'), findsNothing);
    expect(find.textContaining(shortHead), findsOneWidget);
  });

  testWidgets('a narrow window shows one pane at a time', (tester) async {
    final state = await pumpExplorer(tester, size: const Size(500, 900));
    expect(find.byType(TreePane), findsOneWidget);

    await act(tester, () => state.selectRepository(repoPath));

    // The tree is gone and there is a way back, rather than two columns in
    // 500 pixels. (The title bar stays either way.)
    expect(find.byType(TreePane), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsWidgets);

    await tester.tap(find.byIcon(Icons.arrow_back).first);
    await tester.pump();
    expect(find.byType(TreePane), findsOneWidget);
  });

  testWidgets('an empty root explains itself instead of showing nothing',
      (tester) async {
    await pumpExplorer(tester, withRepository: false);

    expect(find.text('No repositories yet'), findsOneWidget);
    expect(find.text('Add a repository'), findsOneWidget);
  });

  testWidgets('a folder with no repository offers to create one, and does',
      (tester) async {
    final plain = Directory(p.join(scratch.path, 'plain-ui'))
      ..createSync(recursive: true);

    final state = await pumpExplorer(tester, withRepository: false);
    // A row can arrive here without the picker — a repository whose .git was
    // removed since it was added reaches exactly this state.
    await act(tester, () => state.addRepository(plain.path));
    await act(tester, () => state.selectRepository(plain.path));

    // Not an error icon and a dead end: the reason, and the one action that
    // changes it (`initialising.why`).
    expect(find.text('the folder holds no repository yet'), findsOneWidget);
    expect(find.text('Create a repository here'), findsOneWidget);
    expect(find.text('not a repository'), findsOneWidget);
    // Not a failure, so not a failure's icon, in the row or the pane.
    expect(find.byIcon(Icons.error_outline), findsNothing);

    await act(tester, () => state.initialiseRepository(plain.path));

    expect(find.text('Create a repository here'), findsNothing);
    expect(find.textContaining('History'), findsWidgets);
    expect(
      Directory(p.join(plain.path, '.git')).existsSync(),
      isTrue,
    );
  });

  testWidgets('the theme can be chosen, and outlives a restart',
      (tester) async {
    final support = Directory(p.join(scratch.path, 'theme-support'))
      ..createSync(recursive: true);
    final store = storeIn(support);

    late final ExplorerState state;
    await tester.runAsync(() async {
      state = ExplorerState(store: store);
      await state.start();
    });
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: state,
          builder: (context, _) => ExplorerPage(state: state),
        ),
      ),
    );
    await tester.pump();

    // The platform's answer is the default.
    expect(state.theme, ThemeChoice.system);

    await tester.tap(find.byIcon(Icons.brightness_auto_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    // Settled rather than pumped once, so the menu is gone and the only icon
    // left is the button's. Safe here: this screen has no progress indicator
    // for pumpAndSettle to wait on forever.
    await tester.pumpAndSettle();

    expect(state.theme, ThemeChoice.light);
    expect(find.byIcon(Icons.light_mode_outlined), findsOneWidget);
    expect(find.byIcon(Icons.brightness_auto_outlined), findsNothing);

    // A second session reads back what the first chose.
    late final ExplorerState reopened;
    await tester.runAsync(() async {
      reopened = ExplorerState(
        store: storeIn(support),
      );
      await reopened.start();
    });
    addTearDown(reopened.dispose);
    expect(reopened.theme, ThemeChoice.light);
  });

  testWidgets('the status colour follows the brightness', (tester) async {
    final state = await pumpExplorer(tester);
    await act(tester, () => state.toggle(repoPath, ''));

    // Material's own swatches, chosen for the scheme in force rather than
    // from values invented here (`presentation.status-colour`).
    final context = tester.element(find.text('M'));
    expect(Theme.of(context).brightness, Brightness.light);
    expect(tester.widget<Text>(find.text('M')).style?.color,
        statusColor(FileState.modified, context));
  });

  group('branches and settings', () {
    testWidgets('a branch can be renamed from the repository pane',
        (tester) async {
      final state = await pumpExplorer(tester);
      git(['branch', 'to-rename']);
      await act(tester, () => state.refresh(repoPath));
      await act(tester, () => state.selectRepository(repoPath));

      await tapAndWait(tester, find.byWidgetPredicate((w) => w is Tab && (w.text ?? '').startsWith('Branches')));
      expect(find.text('to-rename'), findsOneWidget);
      expect(find.text('checked out'), findsOneWidget);

      await tapAndWait(
        tester,
        find.descendant(
          of: find.widgetWithText(ListTile, 'to-rename'),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tapAndWait(tester, find.text('Rename…'));

      await tester.enterText(find.byType(TextField).last, 'feature/renamed');
      await tapAndWait(tester, find.text('Rename'));

      expect(
        git(['branch', '--format=%(refname:short)']).trim().split('\n'),
        ['feature/renamed', 'main'],
      );
      expect(find.textContaining('Renamed to-rename'), findsOneWidget);

      git(['branch', '-D', 'feature/renamed']);
    });

    testWidgets('a name git would refuse is reported, and nothing changes',
        (tester) async {
      final state = await pumpExplorer(tester);
      final before = git(['branch', '--format=%(refname:short)']).trim();

      // Through act: a worker reply never arrives inside the fake-async zone.
      var renamed = true;
      await act(tester, () async {
        renamed = await state.renameBranch(repoPath, 'main', 'has space');
      });

      expect(renamed, isFalse);
      expect(state.error, isNotNull);
      expect(git(['branch', '--format=%(refname:short)']).trim(), before);
    });

    testWidgets('an error banner offers a copy icon, so it need not be retyped',
        (tester) async {
      final state = await pumpExplorer(tester);

      var renamed = true;
      await act(tester, () async {
        renamed = await state.renameBranch(repoPath, 'main', 'has space');
      });
      expect(renamed, isFalse);
      expect(state.error, isNotNull);

      // Tapping it does not throw - the clipboard channel is stubbed under
      // test, so there is nothing further to assert about where the text
      // landed.
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pump();

      await act(tester, () async => state.dismissError());
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
    });

    testWidgets('settings open, grouped, and write to the repository',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.selectRepository(repoPath));

      await tapAndWait(tester, find.byIcon(Icons.settings_outlined));

      // The side tabs, and the first category's content.
      expect(find.text('Identity'), findsWidgets);
      expect(find.text('Branches'), findsWidgets);
      expect(find.text('user.name'), findsOneWidget);

      // An unset value says what git will do rather than showing a default.
      await tapAndWait(tester, find.text('Network').last);
      expect(find.textContaining('Not set — git uses'), findsWidgets);

      // Writing goes to this repository's config, and git reads it back.
      await act(
        tester,
        () => state.writeSetting(repoPath, 'user.name', 'Set From The App', 2),
      );
      expect(git(['config', '--local', '--get', 'user.name']).trim(),
          'Set From The App');

      git(['config', '--local', 'user.name', 'A']);
    });
  });

  group('remote counts', () {
    testWidgets('follow the branch as it moves', (tester) async {
      // A remote to be ahead of, and a repository already level with it.
      final origin = p.join(scratch.path, 'counts-origin.git');
      Process.runSync('git', ['init', '-q', '--bare', '-b', 'main', origin]);

      final state = await pumpExplorer(tester);
      await act(tester, () => state.addRemote(repoPath, 'counts', origin));
      await act(tester, () => state.pushRemote(repoPath, 'counts'));
      await act(tester, () => state.selectRepository(repoPath));
      await tapAndWait(
        tester,
        find.byWidgetPredicate(
          (w) => w is Tab && (w.text ?? '').startsWith('Remotes'),
        ),
      );

      expect(find.text('up to date'), findsOneWidget);

      // A commit moves the branch, and the tile has to keep up: before this
      // was wired, it kept showing whatever it said when the pane opened.
      write('counted.txt', 'new\n');
      await act(
        tester,
        () => state.setStaged(repoPath, 'counted.txt', staged: true),
      );
      await act(
        tester,
        () async => state.commitStaged(repoPath, 'one ahead'),
      );

      expect(find.text('up to date'), findsNothing);
      expect(
        state.remotes!.firstWhere((r) => r.name == 'counts').ahead,
        1,
      );

      // reset --hard removes the committed file too, so there is nothing
      // left to delete by hand.
      git(['reset', '--quiet', '--hard', 'HEAD~1']);
      await act(tester, () => state.removeRemote(repoPath, 'counts'));
      await act(tester, () => state.refresh(repoPath));
      write('README.md', '# demo\nchanged\n');
      write('scratch.txt', 'untracked\n');
    });
  });

  group('context menus', () {
    // Right-click is how a context menu is opened on a desktop. These went
    // missing once when the menus were moved to long-press alone, so each
    // opener is checked with the secondary button here.

    testWidgets('right-clicking a folder offers new file, folder and stage',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.toggle(repoPath, ''));

      await tester.tap(find.text('lib'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('New file…'), findsOneWidget);
      expect(find.text('New folder…'), findsOneWidget);
      expect(find.text('Stage everything here'), findsOneWidget);

      await tester.tapAt(const Offset(5, 5)); // dismiss
      await tester.pumpAndSettle();
    });

    testWidgets('right-clicking a file offers stage and unstage',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.toggle(repoPath, ''));

      await tester.tap(find.text('README.md'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Stage'), findsOneWidget);
      expect(find.text('Unstage'), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    });

    testWidgets('right-clicking a repository offers its own actions',
        (tester) async {
      await pumpExplorer(tester);

      await tester.tap(find.text('repo'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Re-read from disk'), findsOneWidget);
      expect(find.text('Rename…'), findsOneWidget);
      expect(find.text('Remove from the tree'), findsOneWidget);
      expect(find.text('New file…'), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    });

    testWidgets('a folder menu creates a file where it was opened',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.toggle(repoPath, ''));

      await tester.tap(find.text('lib'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New file…'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'from_the_menu.txt');
      await tester.runAsync(() async {
        await tester.tap(find.text('Create'));
      });
      await tester.pumpAndSettle();

      // Created under the folder the menu was opened on, not at the root.
      expect(
        File(p.join(repoPath, 'lib', 'from_the_menu.txt')).existsSync(),
        isTrue,
      );
      File(p.join(repoPath, 'lib', 'from_the_menu.txt')).deleteSync();
    });
  });

  group('ignoring', () {
    testWidgets('ignoring an untracked file adds an anchored rule and says so',
        (tester) async {
      final state = await pumpExplorer(tester);
      write('noise.log', 'x\n');
      await act(tester, () => state.refresh(repoPath));
      await act(tester, () => state.toggle(repoPath, ''));

      await tester.tap(find.text('noise.log'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.text('Ignore…'));

      // No dialog: nothing is tracked, so there is nothing to warn about.
      expect(
        File(p.join(repoPath, '.gitignore')).readAsStringSync(),
        contains('/noise.log'),
      );
      expect(find.textContaining('Added /noise.log'), findsOneWidget);
      expect(git(['status', '--porcelain']), isNot(contains('noise.log')));

      File(p.join(repoPath, 'noise.log')).deleteSync();
      File(p.join(repoPath, '.gitignore')).deleteSync();
      await act(tester, () => state.refresh(repoPath));
    });

    testWidgets('ignoring a tracked file warns, and can stop tracking it',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.toggle(repoPath, ''));

      await tester.tap(find.text('README.md'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.text('Ignore…'));

      // The thing people are surprised by, said before it happens.
      expect(find.text('Ignore this?'), findsOneWidget);
      expect(
        find.textContaining('does not apply to something already tracked'),
        findsOneWidget,
      );

      await tester.tap(find.text('Also stop tracking it'));
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.text('Ignore'));

      // Out of the index, still on disk, and git now reports the removal.
      expect(git(['status', '--porcelain']), contains('D  README.md'));
      expect(File(p.join(repoPath, 'README.md')).existsSync(), isTrue);

      git(['reset', '--quiet', 'HEAD']);
      File(p.join(repoPath, '.gitignore')).deleteSync();
      write('README.md', '# demo\nchanged\n');
      await act(tester, () => state.refresh(repoPath));
    });

    testWidgets('cancelling the warning ignores nothing', (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.toggle(repoPath, ''));

      await tester.tap(find.text('README.md'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.text('Ignore…'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(File(p.join(repoPath, '.gitignore')).existsSync(), isFalse);
      expect(git(['status', '--porcelain']), contains('README.md'));
    });

    testWidgets('an ignored file is shown dimmed rather than marked',
        (tester) async {
      final state = await pumpExplorer(tester);
      write('.gitignore', '/skipme.txt\n');
      write('skipme.txt', 'x\n');
      await act(tester, () => state.refresh(repoPath));
      await act(tester, () => state.toggle(repoPath, ''));

      // Still listed — it is on disk — but carries no status letter.
      expect(find.text('skipme.txt'), findsOneWidget);
      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('skipme.txt'),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.textColor, isNotNull);

      File(p.join(repoPath, 'skipme.txt')).deleteSync();
      File(p.join(repoPath, '.gitignore')).deleteSync();
      await act(tester, () => state.refresh(repoPath));
    });
  });

  group('editing', () {
    testWidgets('a working-tree file is editable, and saving reaches disk',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.selectFile(repoPath, 'lib/main.dart'));

      final field = find.byType(TextField);
      expect(field, findsOneWidget);

      await tester.enterText(field, 'void main() { print(2); }\n');
      await act(tester, () async {});

      // Unsaved, and said so, before anything is written.
      expect(find.textContaining('unsaved'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(
        File(p.join(repoPath, 'lib', 'main.dart')).readAsStringSync(),
        'void main() {}\n',
      );

      await act(tester, () => state.saveFile(repoPath, 'lib/main.dart'));

      expect(
        File(p.join(repoPath, 'lib', 'main.dart')).readAsStringSync(),
        'void main() { print(2); }\n',
      );
      expect(find.textContaining('unsaved'), findsNothing);

      // Put it back for the tests that follow.
      git(['checkout', '--', 'lib/main.dart']);
    });

    testWidgets('an unsaved edit survives moving away and coming back',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.selectFile(repoPath, 'README.md'));
      await tester.enterText(find.byType(TextField), 'a draft\n');
      await act(tester, () async {});

      // Somewhere else entirely, and back. (The repository pane has a text
      // field of its own — the commit message — so the editor's absence is
      // checked by what the pane shows rather than by counting fields.)
      await act(tester, () => state.selectRepository(repoPath));
      expect(find.textContaining('Staged'), findsWidgets);
      await act(tester, () => state.selectFile(repoPath, 'README.md'));

      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller?.text,
        'a draft\n',
      );
      expect(find.textContaining('unsaved'), findsOneWidget);
      // And nothing was written while it was unsaved.
      expect(
        File(p.join(repoPath, 'README.md')).readAsStringSync(),
        '# demo\nchanged\n',
      );

      await act(tester, () async => state.discardDraft(repoPath, 'README.md'));
    });

    testWidgets('a historical revision is read-only', (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.setRevision(repoPath, Revision.head));
      await act(tester, () => state.selectFile(repoPath, 'lib/main.dart'));

      // An object cannot be edited, only replaced
      // (`revisions.only-the-working-tree-is-editable`).
      expect(find.byType(TextField), findsNothing);
      expect(find.text('void main() {}'), findsOneWidget);
      expect(find.text('Save'), findsNothing);
    });

    testWidgets('a new file is created and selected', (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.toggle(repoPath, ''));
      await act(
        tester,
        () => state.createEntry(repoPath, 'fresh.txt', EntryKind.file),
      );

      expect(File(p.join(repoPath, 'fresh.txt')).existsSync(), isTrue);
      // It appears in the tree as untracked, and opens ready to type into.
      expect(find.text('fresh.txt'), findsWidgets);
      expect(find.byType(TextField), findsOneWidget);

      File(p.join(repoPath, 'fresh.txt')).deleteSync();
    });

    testWidgets('a new folder is created in full', (tester) async {
      final state = await pumpExplorer(tester);
      await act(
        tester,
        () => state.createEntry(repoPath, 'x/y/z', EntryKind.directory),
      );

      expect(Directory(p.join(repoPath, 'x', 'y', 'z')).existsSync(), isTrue);
      Directory(p.join(repoPath, 'x')).deleteSync(recursive: true);
    });

    testWidgets('a refused write keeps the draft and reports why',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.selectFile(repoPath, 'README.md'));
      await tester.enterText(find.byType(TextField), 'my version\n');
      await act(tester, () async {});

      // Someone else writes to the same file first.
      File(p.join(repoPath, 'README.md'))
          .writeAsStringSync('written by someone else\n');

      await act(tester, () => state.saveFile(repoPath, 'README.md'));

      expect(find.textContaining('changed on disk'), findsOneWidget);
      // The draft is still there to rescue, and the other write survived.
      expect(state.hasDraft(repoPath, 'README.md'), isTrue);
      expect(
        File(p.join(repoPath, 'README.md')).readAsStringSync(),
        'written by someone else\n',
      );

      File(p.join(repoPath, 'README.md')).writeAsStringSync('# demo\nchanged\n');
      await act(tester, () async => state.discardDraft(repoPath, 'README.md'));
    });
  });

  group('staging and committing', () {
    testWidgets('both halves of the index are shown, and a file can move '
        'between them', (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.selectRepository(repoPath));

      // The staging area is its own tab now, and the commit box lives only
      // there.
      await tapAndWait(tester, find.widgetWithText(Tab, 'Staged'));

      expect(find.textContaining('Staged ('), findsWidgets);
      expect(find.textContaining('Not staged ('), findsWidgets);
      expect(find.text('Nothing staged yet.'), findsOneWidget);

      await act(
        tester,
        () => state.setStaged(repoPath, 'README.md', staged: true),
      );

      expect(find.text('Nothing staged yet.'), findsNothing);
      expect(state.staging!.staged.map((r) => r.path), ['README.md']);
      expect(git(['status', '--porcelain']), contains('M  README.md'));

      await act(
        tester,
        () => state.setStaged(repoPath, 'README.md', staged: false),
      );
      expect(state.staging!.staged, isEmpty);
    });

    testWidgets('committing writes a commit and says so by name',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.selectRepository(repoPath));
      await tapAndWait(tester, find.widgetWithText(Tab, 'Staged'));
      await act(
        tester,
        () => state.setStaged(repoPath, 'scratch.txt', staged: true),
      );

      // The button says how much it will commit.
      expect(find.text('Commit 1 file'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'add scratch');
      await tester.pump();
      await act(
        tester,
        () async => state.commitStaged(repoPath, 'add scratch'),
      );

      expect(git(['log', '-1', '--format=%s']).trim(), 'add scratch');
      // Reported afterwards, by name (`care.reported`).
      expect(find.textContaining('Committed'), findsOneWidget);
      expect(find.textContaining('add scratch'), findsWidgets);
      // On a card of its own: a bare line of text reads as part of the form
      // above it, and what was just written deserves to be seen.
      expect(
        find.ancestor(
          of: find.textContaining('Committed'),
          matching: find.byType(Card),
        ),
        findsOneWidget,
      );
      // With its tick, as a mark of its own rather than more green text.
      final card = find.ancestor(
        of: find.textContaining('Committed'),
        matching: find.byType(Card),
      );
      expect(
        find.descendant(of: card, matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.byType(CircleAvatar)),
        findsOneWidget,
      );
      // And the history it joined is refreshed.
      expect(state.history!.first.summary, 'add scratch');

      git(['reset', '--quiet', '--hard', 'HEAD~1']);
      write('README.md', '# demo\nchanged\n');
      write('scratch.txt', 'untracked\n');
    });

    testWidgets('the commit button is unavailable until there is something '
        'to commit and something to say', (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.selectRepository(repoPath));
      await tapAndWait(tester, find.widgetWithText(Tab, 'Staged'));

      FilledButton commitButton() => tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Commit 0 files'),
          );
      expect(commitButton().onPressed, isNull); // nothing staged

      await act(
        tester,
        () => state.setStaged(repoPath, 'README.md', staged: true),
      );
      final staged = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Commit 1 file'),
      );
      expect(staged.onPressed, isNull); // no message yet

      await tester.enterText(find.byType(TextField).last, 'a message');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Commit 1 file'),
            )
            .onPressed,
        isNotNull,
      );

      await act(
        tester,
        () => state.setStaged(repoPath, 'README.md', staged: false),
      );
    });

    testWidgets('a refused commit reports why and stages nothing',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.selectRepository(repoPath));
      await tapAndWait(tester, find.widgetWithText(Tab, 'Staged'));

      final before = git(['rev-parse', 'HEAD']).trim();
      await act(
        tester,
        () async => state.commitStaged(repoPath, 'nothing is staged'),
      );

      expect(state.error, isNotNull);
      expect(find.textContaining('nothing is staged'), findsWidgets);
      expect(git(['rev-parse', 'HEAD']).trim(), before);
    });
  });

  testWidgets('a missing folder is not offered a repository', (tester) async {
    final gone = p.join(scratch.path, 'not-here');

    final state = await pumpExplorer(tester, withRepository: false);
    await act(tester, () => state.addRepository(gone));
    await act(tester, () => state.selectRepository(gone));

    expect(find.text('the folder is not there'), findsOneWidget);
    // Nowhere to write, so nothing offered.
    expect(find.text('Create a repository here'), findsNothing);
    expect(find.text('unavailable'), findsOneWidget);
    // The row and the detail pane both mark it as a failure, which this one
    // genuinely is.
    expect(find.byIcon(Icons.error_outline), findsWidgets);
  });

  group('cloning', () {
    testWidgets('the add button offers both ways to get a repository',
        (tester) async {
      await pumpExplorer(tester);

      await tester.tap(find.byTooltip('Add a repository'));
      await tester.pumpAndSettle();

      expect(find.text('Add a folder I have'), findsOneWidget);
      expect(find.text('Clone from a URL'), findsOneWidget);
    });

    testWidgets('the clone dialog asks for a URL and where to put it',
        (tester) async {
      await pumpExplorer(tester);

      await tester.tap(find.byTooltip('Add a repository'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clone from a URL'));
      await tester.pumpAndSettle();

      expect(find.text('Clone a repository'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Repository URL'), findsOneWidget);
      // Nowhere to put it yet, so there is nothing to press.
      final clone = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Clone'),
      );
      expect(clone.onPressed, isNull);
    });

    testWidgets('the URL suggests the folder name, until one is typed',
        (tester) async {
      await pumpExplorer(tester);

      await tester.tap(find.byTooltip('Add a repository'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clone from a URL'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Repository URL'),
        'https://host/owner/thing.git',
      );
      await tester.pumpAndSettle();

      final name = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Folder name'),
      );
      expect(name.controller!.text, 'thing');
    });
  });

  group('documents', () {
    const spec = '%unimsg 0\n'
        '\n'
        '-- The demo, described as something you could build.\n'
        '\n'
        'demo {\n'
        '  -- ==========\n'
        '  -- THE HEADING\n'
        '  -- ==========\n'
        '  presentation { doc "why", status :provisional }\n'
        '  editing { what "x" }\n'
        '}\n';

    testWidgets('a .umsg file opens as a document, with the source across',
        (tester) async {
      final state = await pumpExplorer(tester);
      write('spec.umsg', spec);
      await act(tester, () => state.refresh(repoPath));
      await act(tester, () => state.selectFile(repoPath, 'spec.umsg'));

      // Opened as a document (`presentation.a-document-opens-as-a-document`).
      expect(find.byType(UnimsgDocumentView), findsOneWidget);
      // Once in the contents, once as the heading it leads to.
      expect(find.text('presentation'), findsNWidgets(2));
      // The author's banner, kept as their name for the section.
      expect(find.text('the heading'), findsOneWidget);
      // A symbol is still a symbol, sigil and all.
      expect(find.text(':provisional'), findsOneWidget);
      // The block at the top of the file, which says what the file is.
      expect(
        find.textContaining('described as something you could build'),
        findsOneWidget,
      );
      // Not the editor, until asked for.
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      expect(find.byType(UnimsgDocumentView), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('a document being typed into says where it stopped parsing',
        (tester) async {
      final state = await pumpExplorer(tester);
      write('broken.umsg', spec);
      await act(tester, () => state.refresh(repoPath));
      await act(tester, () => state.selectFile(repoPath, 'broken.umsg'));
      expect(find.byType(UnimsgDocumentView), findsOneWidget);

      // Half-way through an edit is an ordinary state, not a failure.
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '%unimsg 0\ndemo { a\n');
      await act(tester, () async {});
      await tester.tap(find.text('Document'));
      await tester.pumpAndSettle();

      expect(find.text('Not a document yet'), findsOneWidget);
      // Where, not just that: the position is the one thing the author needs.
      expect(find.textContaining('line 2, column 9'), findsOneWidget);
      expect(find.textContaining('expected a value'), findsOneWidget);
      // No stale page: one that silently lags the file is worse than none.
      expect(find.byType(UnimsgDocumentView), findsNothing);

      state.discardDraft(repoPath, 'broken.umsg');
    });

    testWidgets('the page follows the draft rather than the saved file',
        (tester) async {
      final state = await pumpExplorer(tester);
      write('draft.umsg', spec);
      await act(tester, () => state.refresh(repoPath));
      await act(tester, () => state.selectFile(repoPath, 'draft.umsg'));

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        '%unimsg 0\ndemo { added { what "new" } }\n',
      );
      await act(tester, () async {});
      await tester.tap(find.text('Document'));
      await tester.pumpAndSettle();

      expect(find.text('added'), findsOneWidget);
      expect(find.text('presentation'), findsNothing);

      state.discardDraft(repoPath, 'draft.umsg');
    });

    testWidgets('an ordinary file is offered no document view', (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.selectFile(repoPath, 'lib/main.dart'));
      expect(find.text('Document'), findsNothing);
      expect(find.byType(UnimsgDocumentView), findsNothing);
    });
  });

  group('syntax colour', () {
    testWidgets('a file of a known type is drawn in more than one colour',
        (tester) async {
      final state = await pumpExplorer(tester);
      // The read-only view, since a file at the working tree opens in the
      // editor.
      await act(tester, () => state.setRevision(repoPath, Revision.head));
      await act(tester, () => state.selectFile(repoPath, 'lib/main.dart'));

      final span = lineSpan(tester, 'void main() {}');
      // Whatever the colours are, the line still says what it said.
      expect(span.toPlainText(), 'void main() {}');

      final coloured = colouredRuns(span);
      expect(coloured.keys, contains('void'));
      expect(coloured['void'], isNot(coloured['()']),
          reason: 'a keyword and a bracket are not the same thing');
    });

    testWidgets('the editor is coloured, and only for a type it knows',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.selectFile(repoPath, 'lib/main.dart'));

      final dart = editorSpan(tester);
      expect(dart.toPlainText(), 'void main() {}\n');
      expect(colouredRuns(dart).keys, contains('void'));

      // `.txt` has no grammar, and a file drawn wrong would be worse than a
      // file drawn plain.
      await act(tester, () => state.selectFile(repoPath, 'scratch.txt'));
      expect(colouredRuns(editorSpan(tester)), isEmpty);
    });

    testWidgets('a diff is coloured, without losing which side a line is on',
        (tester) async {
      final state = await pumpExplorer(tester);
      await act(tester, () => state.selectFile(repoPath, 'README.md'));
      await tester.tap(find.text('Diff'));
      await tester.pump();

      // A Markdown heading, on a context line, coloured as a heading.
      expect(colouredRuns(lineSpan(tester, '# demo')).keys,
          contains('# demo'));
      // The added line is prose, so it has no colour of its own; that it was
      // added is still said by the marker beside it.
      expect(colouredRuns(lineSpan(tester, 'changed')), isEmpty);
      expect(find.text('+'), findsOneWidget);
    });
  });
}

/// The span behind a line, whether it was drawn as rich text or as plain.
InlineSpan lineSpan(WidgetTester tester, String text) {
  final widget = tester.widget<Text>(find.text(text));
  return widget.textSpan ?? TextSpan(text: widget.data);
}

/// The same, for whatever the editor is currently holding.
InlineSpan editorSpan(WidgetTester tester) {
  final field = find.byType(TextField);
  return tester.widget<TextField>(field).controller!.buildTextSpan(
        context: tester.element(field),
        style: const TextStyle(),
        withComposing: false,
      );
}

/// Every run of [span] that carries a colour of its own, by its text.
///
/// A run with no colour inherits the pane's, which is what ordinary code
/// should do, so its absence here is the assertion worth making.
Map<String, Color> colouredRuns(InlineSpan span) {
  final runs = <String, Color>{};
  span.visitChildren((child) {
    if (child is TextSpan) {
      final colour = child.style?.color;
      final text = child.text;
      if (colour != null && text != null) runs[text] = colour;
    }
    return true;
  });
  return runs;
}
