/// The HTTP a git transport needs, and nothing else.
///
/// Smart HTTP is two requests: a GET for the ref advertisement and a POST
/// carrying the negotiation, whose response is the packfile. That response is
/// the size of what is being cloned, so it has to arrive as a stream rather
/// than a buffer — which is most of why this interface exists rather than a
/// call to some convenience function.
///
/// `dart:io`'s `HttpClient` does all of this and does not exist in a browser:
/// constructing one there throws `Unsupported operation: Platform._version`.
/// So the shape is the same as [GitFs] — a native default that is already
/// right, and an injection point for a platform that has to bring its own.
///
/// On the web that injection is not a formality. A browser cannot open an
/// arbitrary connection to a git host: the request is subject to CORS, which
/// most git servers do not permit, so a real web client goes through a proxy
/// or a service worker of its own choosing. Only the application knows which,
/// which is exactly why this is asked for rather than assumed.
library;

import 'http_io.dart' if (dart.library.js_interop) 'http_web.dart' as impl;

/// A response, whose body is streamed because a packfile does not fit
/// comfortably anywhere else.
abstract class GitHttpResponse {
  int get statusCode;

  /// A response header, or null. Names are matched case-insensitively, as
  /// HTTP requires.
  String? header(String name);

  Stream<List<int>> get body;
}

/// What the transports need from an HTTP client.
abstract class GitHttpClient {
  /// Sends one request and returns as soon as the headers are in, so the
  /// caller can stream the body.
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String> headers = const {},
    List<int>? body,
  });

  /// Releases whatever the client is holding. Called once per exchange.
  void close();
}

/// Header names, spelled once.
class GitHttpHeaders {
  static const authorization = 'authorization';
  static const wwwAuthenticate = 'www-authenticate';
  static const contentType = 'content-type';
  static const accept = 'accept';
  static const userAgent = 'user-agent';
}

/// Thrown when a server answers something a git transport cannot use.
class GitHttpException implements Exception {
  final String message;
  final Uri? url;

  const GitHttpException(this.message, {this.url});

  @override
  String toString() =>
      url == null ? 'GitHttpException: $message' : '$message, uri = $url';
}

GitHttpClient Function() _factory = impl.defaultGitHttpClient;

/// A new client for one exchange.
GitHttpClient newHttpClient() => _factory();

/// Points git_dart at [factory] for every HTTP request it makes from now on.
///
/// Call this once, before fetching. It exists for platforms that have to
/// supply their own transport — a browser reaching a git host through a proxy
/// it controls, most obviously.
void useGitHttpClient(GitHttpClient Function() factory) {
  _factory = factory;
}
