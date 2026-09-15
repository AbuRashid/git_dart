/// The demo outside a browser: there is no page to fetch beside or reload.
library;

import 'dart:typed_data';

Never _unsupported() =>
    throw UnsupportedError('the demo only runs in a browser');

Uri documentBase() => _unsupported();

Future<Uint8List> fetchBytes(Uri url) async => _unsupported();

void downloadUrl(Uri url, String fileName) => _unsupported();

void downloadBytes(Uint8List bytes, String fileName) => _unsupported();

void reloadPage() => _unsupported();
