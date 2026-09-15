/// The demo's page, through `dart:js_interop`.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

JSObject get _document => globalContext['document']! as JSObject;

Uri documentBase() => Uri.parse((_document['baseURI']! as JSString).toDart);

Future<Uint8List> fetchBytes(Uri url) async {
  final response = await globalContext
      .callMethod<JSPromise<JSObject>>('fetch'.toJS, url.toString().toJS)
      .toDart;
  final status = (response['status']! as JSNumber).toDartInt;
  if (status != 200) throw StateError('$url answered $status');

  final buffer = await response
      .callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS)
      .toDart;
  return buffer.toDart.asUint8List();
}

void downloadUrl(Uri url, String fileName) =>
    _clickLink(url.toString(), fileName);

void downloadBytes(Uint8List bytes, String fileName) {
  final blob = (globalContext['Blob']! as JSFunction)
      .callAsConstructor<JSObject>(<JSAny>[bytes.toJS].toJS);
  final urls = globalContext['URL']! as JSObject;
  final href =
      urls.callMethod<JSString>('createObjectURL'.toJS, blob).toDart;
  _clickLink(href, fileName);

  // Not revoked straight away: the click only starts the download, and a
  // browser still reading the blob when its URL goes away saves nothing.
  Future<void>.delayed(const Duration(minutes: 1), () {
    urls.callMethod<JSAny?>('revokeObjectURL'.toJS, href.toJS);
  });
}

void reloadPage() => (globalContext['location']! as JSObject)
    .callMethod<JSAny?>('reload'.toJS);

/// A link with `download` set, clicked: the one way a page can offer a file
/// to save rather than navigate to it.
void _clickLink(String href, String fileName) {
  final link = _document.callMethod<JSObject>('createElement'.toJS, 'a'.toJS)
    ..['href'] = href.toJS
    ..['download'] = fileName.toJS;
  final body = _document['body']! as JSObject;
  body.callMethod<JSAny?>('appendChild'.toJS, link);
  link.callMethod<JSAny?>('click'.toJS);
  body.callMethod<JSAny?>('removeChild'.toJS, link);
}
