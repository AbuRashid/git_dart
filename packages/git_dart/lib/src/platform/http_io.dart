import 'dart:io';

import 'http.dart';

GitHttpClient defaultGitHttpClient() => _IoHttpClient();

/// `dart:io`'s client, which streams the response body and is what every
/// platform with a real socket should use.
class _IoHttpClient implements GitHttpClient {
  final HttpClient _client = HttpClient();

  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri url,
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final request = await _client.openUrl(method, url);
    headers.forEach(request.headers.set);
    if (body != null) request.add(body);
    return _IoHttpResponse(await request.close());
  }

  @override
  void close() => _client.close(force: true);
}

class _IoHttpResponse implements GitHttpResponse {
  final HttpClientResponse _response;

  _IoHttpResponse(this._response);

  @override
  int get statusCode => _response.statusCode;

  @override
  String? header(String name) => _response.headers.value(name);

  @override
  Stream<List<int>> get body => _response;
}
