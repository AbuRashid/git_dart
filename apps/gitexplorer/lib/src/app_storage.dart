/// Where the app keeps the little it remembers between sessions.
///
/// Only the arrangement — which repositories were added, and the theme. Small,
/// and everything else is derivable from the repositories themselves.
///
/// A file in the application support directory where there is one; a browser
/// has no such directory and `path_provider` throws rather than inventing one,
/// so there it is `localStorage`, which is the right size for a few hundred
/// bytes of preferences.
library;

import 'app_storage_io.dart'
    if (dart.library.js_interop) 'app_storage_web.dart' as impl;

/// What was stored under [key], or null when nothing was.
Future<String?> readAppSetting(String key) => impl.readAppSetting(key);

Future<void> writeAppSetting(String key, String value) =>
    impl.writeAppSetting(key, value);
