/// Finding and starting hook programs, which only a platform with processes
/// can do.
///
/// Split out like `platform/host.dart`: the `dart:io` half would otherwise be
/// reachable from the library's front door and stop it compiling for a
/// browser. The web half finds no hooks at all, so a repository opened there
/// behaves as if it had none.
library;

export 'hook_process_io.dart'
    if (dart.library.js_interop) 'hook_process_web.dart';
