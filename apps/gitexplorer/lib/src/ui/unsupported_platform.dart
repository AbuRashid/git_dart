import 'package:flutter/material.dart';

import '../theme.dart';

/// What the web build shows in place of an explorer it cannot run yet.
///
/// git_dart reads a repository through a filesystem, and a browser has none it
/// can reach: `dart:io` compiles for the web but throws on the first call. The
/// app would otherwise start, look ready, and fail at the first repository —
/// which is a worse answer than this one. It goes away once a `GitFs` backend
/// over OPFS exists.
class UnsupportedPlatformApp extends StatelessWidget {
  const UnsupportedPlatformApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Git Explorer',
      debugShowCheckedModeBanner: false,
      theme: explorerTheme(Brightness.light),
      darkTheme: explorerTheme(Brightness.dark),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.folder_off_outlined,
                    size: 48,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Git Explorer needs a filesystem',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'A browser tab has no filesystem this app can read a '
                    'repository from, so the web build cannot open one yet. '
                    'The desktop and Android builds can.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
