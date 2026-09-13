/// The web's HTTP client: `fetch`, wired to what git_dart asks for.
///
/// Not the default `dart:io` client — a browser has none, and git_dart's own
/// web platform file refuses on purpose rather than pretending, because
/// whether a request can even be made here is a question about CORS that only
/// the application can answer (a proxy, a same-origin server, a remote that
/// happens to allow it). This is that answer: a direct `fetch`, which works
/// exactly when the server the request is aimed at permits it.
///
/// The response body is streamed rather than buffered, because a packfile is
/// the size of what is being cloned and buffering it would mean holding two
/// copies at once — one in the browser's fetch buffer, one in the `Uint8List`
/// git_dart builds from the stream.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:git_dart/git_dart.dart' as git;

@JS('fetch')
external JSPromise<_Response> _fetch(String url, [JSObject init]);

extension type _Response._(JSObject _) implements JSObject {
  external int get status;
  external _Headers get headers;
  external _ReadableStream? get body;
}

extension type _Headers._(JSObject _) implements JSObject {
  external String? get(String name);
}

extension type _ReadableStream._(JSObject _) implements JSObject {
  external _StreamReader getReader();
}

extension type _StreamReader._(JSObject _) implements JSObject {
  external JSPromise<_ReadResult> read();
}

extension type _ReadResult._(JSObject _) implements JSObject {
  external bool get done;
  external JSUint8Array? get value;
}

/// Registers the fetch client for every request git_dart makes from here on.
///
/// Call once, before the first clone or fetch. `useGitHttpClient` takes a
/// factory rather than an instance because [GitHttpClient.close] is called
/// once per exchange — a fresh one per request keeps that meaningful instead
/// of closing something still in use by another request in flight.
void installWebHttpClient() {
  git.useGitHttpClient(() => const FetchHttpClient());
}

class FetchHttpClient implements git.GitHttpClient {
  const FetchHttpClient();

  @override
  Future<git.GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final init = JSObject()..setProperty('method'.toJS, method.toJS);
    if (headers.isNotEmpty) {
      final jsHeaders = JSObject();
      headers.forEach((key, value) => jsHeaders.setProperty(key.toJS, value.toJS));
      init.setProperty('headers'.toJS, jsHeaders);
    }
    if (body != null) {
      init.setProperty(
        'body'.toJS,
        Uint8List.fromList(body).toJS,
      );
    }

    final _Response response;
    try {
      response = await _fetch(url.toString(), init).toDart;
    } on Object catch (error) {
      // Almost always CORS: the browser refuses to hand the response to the
      // page at all, and this is the only signal it gives — no status code,
      // no body, just a failed promise. Named here so the failure reads as
      // what it almost certainly is rather than as an unexplained network
      // error.
      throw git.GitHttpException(
        'the request was blocked, most likely by the server\'s CORS policy '
        '($error)',
        url: url,
      );
    }

    return _FetchResponse(response);
  }

  @override
  void close() {}
}

class _FetchResponse implements git.GitHttpResponse {
  _FetchResponse(this._response);

  final _Response _response;

  @override
  int get statusCode => _response.status;

  @override
  String? header(String name) => _response.headers.get(name);

  @override
  Stream<List<int>> get body {
    final stream = _response.body;
    if (stream == null) return const Stream.empty();

    final controller = StreamController<List<int>>();
    final reader = stream.getReader();

    Future<void> pump() async {
      try {
        while (true) {
          final result = await reader.read().toDart;
          if (result.done) break;
          final chunk = result.value;
          if (chunk != null) controller.add(chunk.toDart);
        }
        await controller.close();
      } on Object catch (error) {
        controller.addError(error);
        await controller.close();
      }
    }

    pump();
    return controller.stream;
  }
}
