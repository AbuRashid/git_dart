/// The hosted sandbox demo: the app as it ships, opened on its own repository.
///
/// Built only by tool/build_demo.sh, never as the app itself. Everything a
/// visitor does happens to a copy in their own browser — the seeded repository
/// has no remote, and nothing here can write anywhere else — so the app runs
/// unrestricted. What this adds is only what a first visit needs: the
/// repository already there, a way to take the code home, and a way back to
/// where it started.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show BrowserContextMenu;

import 'main.dart' show GitExplorerApp;
import 'src/demo/demo_menu.dart';
import 'src/demo/demo_platform.dart';
import 'src/demo/demo_seed.dart';
import 'src/theme.dart';
import 'src/workspace.dart';

/// The name the seeded repository is given.
const _repositoryName = 'gitexplorer';

/// The bundle tool/build_demo.sh publishes beside the app.
const _bundleName = 'gitexplorer.bundle';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) await BrowserContextMenu.disableContextMenu();
  await prepareWorkspace();

  // A first visit downloads and unpacks the whole repository before the app
  // can show it, which is long enough to look like a page that failed to
  // load. A frame saying otherwise is drawn first.
  runApp(const _Preparing());
  await WidgetsBinding.instance.endOfFrame;

  String? problem;
  try {
    await seedDemoRepository(
      name: _repositoryName,
      bundle: () => fetchDemoBytes(demoAssetUrl(_bundleName)),
    );
  } catch (error) {
    // The app is still worth opening without it — cloning and creating work
    // regardless — so the failure is reported from inside it, not instead.
    problem = '$error';
  }

  runApp(GitExplorerApp(
    actions: (context, state) => [
      DemoMenu(
        state: state,
        repositoryName: _repositoryName,
        bundleName: _bundleName,
        problem: problem,
      ),
    ],
  ));
}

class _Preparing extends StatelessWidget {
  const _Preparing();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Git Explorer',
      debugShowCheckedModeBanner: false,
      theme: explorerTheme(Brightness.light),
      darkTheme: explorerTheme(Brightness.dark),
      home: const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading the demo repository…'),
            ],
          ),
        ),
      ),
    );
  }
}
