/// Settings in `localStorage`, for a browser.
///
/// Not OPFS: that is where the repositories live, and reaching it costs an
/// asynchronous round trip per operation. A few hundred bytes of preferences
/// read at startup do not deserve one.
library;

import 'dart:js_interop';

@JS('localStorage')
external _Storage? get _localStorage;

extension type _Storage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
}

/// Namespaced, because `localStorage` is shared by everything on the origin.
String _key(String key) => 'gitexplorer.$key';

Future<String?> readAppSetting(String key) async {
  try {
    return _localStorage?.getItem(_key(key));
  } on Object {
    // Storage can be refused outright — a private window, or a browser set to
    // block it. Forgetting the arrangement is better than failing to start.
    return null;
  }
}

Future<void> writeAppSetting(String key, String value) async {
  try {
    _localStorage?.setItem(_key(key), value);
  } on Object {
    // As above: not remembering is a smaller failure than not running.
  }
}
