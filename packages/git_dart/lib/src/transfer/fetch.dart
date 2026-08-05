import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/git_object.dart';
import '../objects/tag.dart';
import '../objects/tree.dart';
import '../remote/remote.dart';
import '../repository.dart';
import '../storage/pack_parser.dart';
import 'credentials.dart';
import 'pkt_line.dart';

/// One ref moved by a fetch.
class RefUpdate {
  final String ref;

  /// Where it pointed before, or null when it is new here.
  final ObjectId? from;
  final ObjectId to;

  const RefUpdate({required this.ref, required this.to, this.from});

  bool get isNew => from == null;
  bool get isUnchanged => from == to;

  @override
  String toString() =>
      '$ref ${isNew ? 'new' : '${from!.hex.substring(0, 8)}..'}'
      '${to.hex.substring(0, 8)}';
}

class FetchResult {
  final List<RefUpdate> updates;
  final int objectsReceived;

  /// What the remote advertised, before any refspec was applied.
  final Map<String, ObjectId> advertised;

  const FetchResult({
    required this.updates,
    required this.objectsReceived,
    this.advertised = const {},
  });

  List<RefUpdate> get changed =>
      [for (final u in updates) if (!u.isUnchanged) u];
}

/// Fetches from [remote] into [repository].
///
/// Two paths, because they are genuinely different problems. A remote that is
/// a directory on this machine is read directly — its object store is right
/// there, and speaking a protocol to it would be ceremony. Anything else is
/// fetched over smart HTTP.
Future<FetchResult> fetch(
  Repository repository,
  Remote remote, {
  Credentials? credentials,
  void Function(String message)? onProgress,
}) async {
  if (remote.isLocal) {
    return _fetchLocal(repository, remote, onProgress);
  }
  if (remote.url.startsWith('http://') || remote.url.startsWith('https://')) {
    return _fetchHttp(repository, remote, credentials, onProgress);
  }
  throw UnsupportedError(
    'this build can fetch from a local path or over http(s); '
    '${remote.url} is neither',
  );
}

// ---------------------------------------------------------------------------
// a directory on this machine
// ---------------------------------------------------------------------------

Future<FetchResult> _fetchLocal(
  Repository repository,
  Remote remote,
  void Function(String)? onProgress,
) async {
  final source = Repository.discover(remote.localPath);
  if (source == null) {
    throw StateError('${remote.localPath} is not a repository');
  }

  try {
    final advertised = <String, ObjectId>{};
    for (final ref in source.refs.list()) {
      final id = source.refs.resolve(ref.path);
      if (id != null) advertised[ref.path] = id;
    }

    // Copy every object reachable from what is wanted and not already here.
    // Reachability stops at objects this repository already holds, so a fetch
    // costs the size of what is new rather than the size of the history.
    final wanted = <ObjectId>[];
    for (final entry in advertised.entries) {
      if (remote.trackingRefFor(entry.key) == null) continue;
      wanted.add(entry.value);
    }

    var copied = 0;
    final seen = <ObjectId>{};
    final pending = <ObjectId>[...wanted];

    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!seen.add(id)) continue;
      if (repository.objects.contains(id)) continue;

      final raw = source.objects.readRaw(id);
      if (raw == null) continue;

      repository.objects.write(GitObject.parse(raw.kind, raw.content));
      copied += 1;
      if (copied % 500 == 0) onProgress?.call('copied $copied objects');

      final object = GitObject.parse(raw.kind, raw.content);
      switch (object) {
        case Commit commit:
          pending
            ..add(commit.tree)
            ..addAll(commit.parents);
        case Tree tree:
          for (final entry in tree.entries) {
            if (!entry.mode.isSubmodule) pending.add(entry.id);
          }
        case Tag tag:
          pending.add(tag.target);
        case Blob():
          break;
      }
    }

    return FetchResult(
      updates: _applyRefspecs(repository, remote, advertised),
      objectsReceived: copied,
      advertised: advertised,
    );
  } finally {
    source.close();
  }
}

// ---------------------------------------------------------------------------
// smart HTTP
// ---------------------------------------------------------------------------

/// Protocol version 0, which every server still speaks
/// (`transfer.two-protocols`).
Future<FetchResult> _fetchHttp(
  Repository repository,
  Remote remote,
  Credentials? given,
  void Function(String)? onProgress,
) async {
  // A `user@host` URL carries the name but not the secret, and HttpClient
  // ignores both, so they are taken out here and sent as a header instead.
  final split = splitCredentials(remote.url);
  final credentials = given ??
      (split.credentials != null && split.credentials!.password.isNotEmpty
          ? split.credentials
          : null);

  final withoutTrailingSlash = split.url.toString();
  final base = withoutTrailingSlash.endsWith('/')
      ? withoutTrailingSlash.substring(0, withoutTrailingSlash.length - 1)
      : withoutTrailingSlash;
  final client = HttpClient();

  try {
    // ---- the advertisement ----
    onProgress?.call('contacting $base');
    final adRequest = await client.getUrl(
      Uri.parse('$base/info/refs?service=git-upload-pack'),
    );
    adRequest.headers.set('User-Agent', 'git/git_dart-0.1');
    if (credentials != null) {
      adRequest.headers.set(
        HttpHeaders.authorizationHeader,
        credentials.authorizationHeader,
      );
    }
    final adResponse = await adRequest.close();
    if (adResponse.statusCode == 401) {
      await adResponse.drain<void>();
      throw AuthenticationRequired(
        base,
        realm: realmOf(adResponse),
        wereRejected: credentials != null,
      );
    }
    if (adResponse.statusCode != 200) {
      throw HttpException(
        'the server answered ${adResponse.statusCode} for the ref '
        'advertisement',
        uri: adRequest.uri,
      );
    }
    final advertisement = await _collect(adResponse);

    final parsed = _readAdvertisement(advertisement);
    final advertised = parsed.refs;
    final capabilities = parsed.capabilities;

    // ---- what to ask for ----
    final wants = <ObjectId>[];
    for (final entry in advertised.entries) {
      if (remote.trackingRefFor(entry.key) == null) continue;
      if (repository.objects.contains(entry.value)) continue;
      if (!wants.contains(entry.value)) wants.add(entry.value);
    }

    if (wants.isEmpty) {
      return FetchResult(
        updates: _applyRefspecs(repository, remote, advertised),
        objectsReceived: 0,
        advertised: advertised,
      );
    }

    // What we already have, so the server can send the difference rather than
    // the repository (`transfer.negotiation`).
    final haves = <ObjectId>[];
    for (final ref in repository.refs.list()) {
      final id = repository.refs.resolve(ref.path);
      if (id != null && !haves.contains(id)) haves.add(id);
      if (haves.length >= 256) break;
    }

    final agreed = <String>[
      if (capabilities.contains('side-band-64k')) 'side-band-64k',
      if (capabilities.contains('ofs-delta')) 'ofs-delta',
      'agent=git/git_dart-0.1',
    ];

    final body = BytesBuilder();
    for (var i = 0; i < wants.length; i++) {
      final line = i == 0
          ? 'want ${wants[i].hex} ${agreed.join(' ')}\n'
          : 'want ${wants[i].hex}\n';
      body.add(PktLine.text(line).encode());
    }
    body.add(PktLine.flush.encode());
    for (final have in haves) {
      body.add(PktLine.text('have ${have.hex}\n').encode());
    }
    body.add(PktLine.text('done\n').encode());

    // ---- the pack ----
    onProgress?.call('asking for ${wants.length} refs');
    final request =
        await client.postUrl(Uri.parse('$base/git-upload-pack'));
    request.headers
      ..set('Content-Type', 'application/x-git-upload-pack-request')
      ..set('Accept', 'application/x-git-upload-pack-result')
      ..set('User-Agent', 'git/git_dart-0.1');
    if (credentials != null) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        credentials.authorizationHeader,
      );
    }
    request.add(body.takeBytes());

    final response = await request.close();
    if (response.statusCode == 401) {
      await response.drain<void>();
      throw AuthenticationRequired(
        base,
        realm: realmOf(response),
        wereRejected: credentials != null,
      );
    }
    if (response.statusCode != 200) {
      throw HttpException(
        'the server answered ${response.statusCode} for the pack',
        uri: request.uri,
      );
    }

    final pack = _readPackResponse(
      await _collect(response),
      usedSideBand: agreed.contains('side-band-64k'),
      onProgress: onProgress,
    );

    final objects = PackParser(pack).parse();
    objects.forEach((id, object) {
      repository.objects.write(GitObject.parse(object.kind, object.content));
    });

    return FetchResult(
      updates: _applyRefspecs(repository, remote, advertised),
      objectsReceived: objects.length,
      advertised: advertised,
    );
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder();
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// Reads `# service=…`, then the ref lines, then the capabilities that came
/// after the NUL on the first of them (`transfer.advertisement`).
({Map<String, ObjectId> refs, Set<String> capabilities}) _readAdvertisement(
  Uint8List bytes,
) {
  final reader = PktLineReader(bytes);
  final refs = <String, ObjectId>{};
  final capabilities = <String>{};

  var first = true;
  while (true) {
    final packet = reader.next();
    if (packet == null) break;
    if (packet.kind != PktKind.data) continue;

    final text = packet.text;
    if (text.startsWith('#')) continue; // the service banner

    final line = parseAdvertisement(packet);
    if (first) {
      capabilities.addAll(line.capabilities);
      first = false;
    }
    // A peeled tag is advertised as `refs/tags/x^{}`; the tag object itself is
    // the one to track.
    if (line.path.endsWith('^{}')) continue;
    if (line.name == '0' * 40) continue; // an empty repository
    refs[line.path] = ObjectId.fromHex(line.name);
  }

  return (refs: refs, capabilities: capabilities);
}

/// Pulls the packfile out of the response.
///
/// With side-band-64k the pack arrives in pkt-lines whose first byte says
/// which band it is: 1 is the pack, 2 is progress for a human, 3 is an error.
Uint8List _readPackResponse(
  Uint8List bytes, {
  required bool usedSideBand,
  void Function(String)? onProgress,
}) {
  final reader = PktLineReader(bytes);
  final pack = BytesBuilder();

  while (true) {
    final packet = reader.next();
    if (packet == null) break;
    if (packet.kind != PktKind.data) continue;

    if (!usedSideBand) {
      final text = packet.text;
      // Acknowledgements come before the pack and are not part of it.
      if (text.startsWith('NAK') || text.startsWith('ACK')) continue;
      pack.add(packet.payload);
      continue;
    }

    if (packet.payload.isEmpty) continue;
    final band = packet.payload.first;
    final rest = Uint8List.sublistView(packet.payload, 1);

    switch (band) {
      case 1:
        pack.add(rest);
      case 2:
        final message = utf8.decode(rest, allowMalformed: true).trim();
        if (message.isNotEmpty) onProgress?.call(message);
      case 3:
        throw StateError(
          'the server reported: ${utf8.decode(rest, allowMalformed: true)}',
        );
      default:
        // Before the pack, the server sends NAK/ACK unbanded.
        final text = utf8.decode(packet.payload, allowMalformed: true);
        if (!text.startsWith('NAK') && !text.startsWith('ACK')) {
          throw FormatException('unknown side band $band');
        }
    }
  }

  return pack.takeBytes();
}

// ---------------------------------------------------------------------------

/// Moves the tracking refs the remote's refspecs name.
List<RefUpdate> _applyRefspecs(
  Repository repository,
  Remote remote,
  Map<String, ObjectId> advertised,
) {
  final updates = <RefUpdate>[];

  for (final entry in advertised.entries) {
    final local = remote.trackingRefFor(entry.key);
    if (local == null) continue;
    // Only what actually arrived: a ref whose objects are missing would be a
    // ref pointing at nothing, which is worse than not having it.
    if (!repository.objects.contains(entry.value)) continue;

    final before = repository.refs.resolve(local);
    if (before != entry.value) {
      repository.refs.write(local, entry.value);
    }
    updates.add(RefUpdate(ref: local, from: before, to: entry.value));
  }

  updates.sort((a, b) => a.ref.compareTo(b.ref));
  return updates;
}
