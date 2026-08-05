import 'dart:convert';
import 'dart:io';

/// A username and a secret for an HTTP remote.
///
/// The secret is whatever the host wants in a password field — for most hosts
/// today that is a personal access token rather than an account password.
class Credentials {
  final String username;
  final String password;

  const Credentials({required this.username, required this.password});

  String get authorizationHeader =>
      'Basic ${base64.encode(utf8.encode('$username:$password'))}';

  @override
  String toString() => 'Credentials($username, …)';
}

/// Thrown when a remote wants credentials that were not supplied, or refused
/// the ones that were.
///
/// Carries what a caller needs to ask for them: which URL, and the realm the
/// server named. A caller that has none to offer should let this reach the
/// user rather than retrying — a server that says 401 twice will say it a
/// third time.
class AuthenticationRequired implements Exception {
  final String url;
  final String? realm;

  /// True when credentials were sent and rejected, rather than never sent.
  final bool wereRejected;

  const AuthenticationRequired(
    this.url, {
    this.realm,
    this.wereRejected = false,
  });

  @override
  String toString() => wereRejected
      ? 'the credentials for $url were refused'
      : '$url needs a username and password';
}

/// A URL with any `user:password@` removed, and what was removed.
///
/// Credentials in a URL are common in a remote's config — `git remote add`
/// keeps whatever was typed — but they must not be sent as part of the request
/// line. `HttpClient` ignores them, so a URL carrying a username would
/// otherwise arrive unauthenticated and the server would answer 401 while the
/// user could see their name right there in the address.
({Uri url, Credentials? credentials}) splitCredentials(String url) {
  final parsed = Uri.parse(url);
  if (parsed.userInfo.isEmpty) return (url: parsed, credentials: null);

  final colon = parsed.userInfo.indexOf(':');
  final username = Uri.decodeComponent(
    colon < 0 ? parsed.userInfo : parsed.userInfo.substring(0, colon),
  );
  final password = colon < 0
      ? null
      : Uri.decodeComponent(parsed.userInfo.substring(colon + 1));

  return (
    url: parsed.replace(userInfo: ''),
    // A username with no password is not usable on its own, but it is worth
    // carrying: it is the name to offer when asking for the password.
    credentials: password == null
        ? Credentials(username: username, password: '')
        : Credentials(username: username, password: password),
  );
}

/// The realm from a `WWW-Authenticate` header, if it named one.
String? realmOf(HttpClientResponse response) {
  final header = response.headers.value(HttpHeaders.wwwAuthenticateHeader);
  if (header == null) return null;
  final match = RegExp('realm="([^"]*)"', caseSensitive: false)
      .firstMatch(header);
  return match?.group(1);
}
