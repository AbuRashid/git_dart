import 'package:flutter/material.dart';

import 'src/generated/tokens.dart';
import 'src/state.dart';
import 'src/theme.dart';
import 'src/ui/detail_pane.dart';
import 'src/ui/tree_pane.dart';

void main() {
  runApp(const GitExplorerApp());
}

class GitExplorerApp extends StatefulWidget {
  const GitExplorerApp({super.key});

  @override
  State<GitExplorerApp> createState() => _GitExplorerAppState();
}

class _GitExplorerAppState extends State<GitExplorerApp> {
  final _state = ExplorerState();
  late final Future<void> _started = _state.start();

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _state,
      builder: (context, _) => MaterialApp(
        title: 'Git Explorer',
        debugShowCheckedModeBanner: false,
        theme: explorerTheme(Brightness.light),
        darkTheme: explorerTheme(Brightness.dark),
        themeMode: switch (_state.theme) {
          ThemeChoice.system => ThemeMode.system,
          ThemeChoice.light => ThemeMode.light,
          ThemeChoice.dark => ThemeMode.dark,
        },
        home: FutureBuilder<void>(
          future: _started,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Scaffold(body: Center(child: Text('${snapshot.error}')));
            }
            return ExplorerPage(state: _state);
          },
        ),
      ),
    );
  }
}

/// The window: the tree beside the detail, or one at a time when there is not
/// room for both.
class ExplorerPage extends StatelessWidget {
  final ExplorerState state;

  /// Below this width the panes stack instead of sitting side by side.
  static const double breakpoint = 720;

  /// The tree pane's width when both are shown.
  static const double sidebarWidth = 320;

  const ExplorerPage({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= breakpoint;
          final showingDetail = state.selection is! NothingSelected;

          return Scaffold(
            appBar: AppBar(
              title: const Text('Git Explorer'),
              leading: !wide && showingDetail
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Back',
                      onPressed: state.clearSelection,
                    )
                  : null,
              // Adding a repository belongs beside the list it adds to, not
              // in the window's bar, so it lives in the tree pane's header.
              actions: [ThemeButton(state: state)],
            ),
            body: wide
                ? Row(
                    children: [
                      SizedBox(
                        width: sidebarWidth,
                        child: TreePane(state: state),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: DetailPane(state: state)),
                    ],
                  )
                : (showingDetail
                    ? DetailPane(state: state)
                    : TreePane(state: state)),
          );
        },
      ),
    );
  }
}
