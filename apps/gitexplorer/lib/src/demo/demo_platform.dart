/// What the demo needs from the page it runs in.
///
/// The demo is only ever built for a browser, but the app's libraries are
/// compiled for every platform, so the browser half sits behind the same kind
/// of conditional import the workspace uses and the other half says plainly
/// that there is nothing to do.
library;

import 'dart:typed_data';

import 'demo_platform_io.dart'
    if (dart.library.js_interop) 'demo_platform_web.dart' as impl;

/// Where a file published beside the app is.
///
/// Resolved against the document's base rather than the address bar: the demo
/// is served from a path like `/apps/<slug>/`, and a page opened without the
/// trailing slash would otherwise look for its files one directory up.
Uri demoAssetUrl(String name) => impl.documentBase().resolve(name);

/// The bytes at [url], or an error naming the status that came back instead.
Future<Uint8List> fetchDemoBytes(Uri url) => impl.fetchBytes(url);

/// Hands the visitor the file at [url] to save, as [fileName].
void downloadDemoUrl(Uri url, String fileName) =>
    impl.downloadUrl(url, fileName);

/// Hands the visitor [bytes] to save, as [fileName].
void downloadDemoBytes(Uint8List bytes, String fileName) =>
    impl.downloadBytes(bytes, fileName);

/// Loads the page again from the start.
void reloadDemoPage() => impl.reloadPage();
