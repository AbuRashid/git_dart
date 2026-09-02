import 'http.dart';

/// The web has no client of its own worth defaulting to.
///
/// `dart:io`'s exists only in name here, and a browser's own fetch is subject
/// to CORS, which git hosts overwhelmingly do not allow — so the request has
/// to go somewhere the application has arranged. Refusing here says that,
/// rather than failing later inside a request nobody could have made work.
GitHttpClient defaultGitHttpClient() => const _UnconfiguredHttpClient();

class _UnconfiguredHttpClient implements GitHttpClient {
  const _UnconfiguredHttpClient();

  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String> headers = const {},
    List<int>? body,
  }) async =>
      throw GitHttpException(
        'This platform has no HTTP client of its own. Call useGitHttpClient() '
        'with one — a browser reaches a git host through a proxy or a worker, '
        'because the host will not permit the request directly.',
        url: url,
      );

  @override
  void close() {}
}
