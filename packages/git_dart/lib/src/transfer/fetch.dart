import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/git_object.dart';
import '../objects/tag.dart';
import '../objects/tree.dart';
import '../remote/remote.dart';
import '../repository.dart';
import '../storage/pack_indexer.dart';
import '../storage/pack_parser.dart';
import '../storage/pack_writer.dart';
import 'connection.dart';
import 'credentials.dart';
import 'negotiator.dart';
import 'pkt_line.dart';
import 'protocol_v2.dart';
import '../platform/host.dart';
import '../platform/http.dart';

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

  /// The branch the remote's HEAD names, when it said — which is what a clone
  /// checks out. Version 0 has no way to ask and this is inferred there, or
  /// null when it cannot be.
  final String? defaultBranch;

  /// Which protocol was actually spoken: 0 or 2.
  final int protocolVersion;

  /// How many rounds of negotiation it took.
  final int negotiationRounds;

  const FetchResult({
    required this.updates,
    required this.objectsReceived,
    this.advertised = const {},
    this.defaultBranch,
    this.protocolVersion = 0,
    this.negotiationRounds = 0,
  });

  List<RefUpdate> get changed =>
      [for (final u in updates) if (!u.isUnchanged) u];
}

/// Below this many objects, a fetch stores what arrived loose rather than as a
/// pack.
///
/// Loose is simpler and is read without an index, which is worth having for a
/// fetch that brought three commits. Above it the balance inverts sharply: a
/// clone of anything real brings hundreds of thousands of objects, and one
/// file each is a directory tree the filesystem struggles to walk and an order
/// of magnitude more bytes on disk than the pack it came from. Git draws the
/// same line, at the same place, for the same reason.
const int unpackLimit = 100;

const _agent = 'git/git_dart-0.1';

/// Fetches from [remote] into [repository].
///
/// Four transports, which are three problems. A remote that is a directory on
/// this machine is read directly — its object store is right there and
/// speaking a protocol to it would be ceremony. Smart HTTP is
/// request-and-response, so the whole conversation is re-sent each round. ssh
/// and the git daemon are a single open connection, and differ from each other
/// only in how it is opened.
///
/// Above all four, the protocol is the same: an advertisement, a negotiation,
/// and a packfile.
Future<FetchResult> fetch(
  Repository repository,
  Remote remote, {
  Credentials? credentials,
  void Function(String message)? onProgress,
  String sshCommand = 'ssh',
  bool allowVersion2 = true,
  int? depth,
  String? filter,
}) async {
  if (remote.isLocal) {
    if (filter != null) {
      // The same reasoning as a depth: a local fetch copies objects rather
      // than asking for them, so there is nobody to apply a filter.
      throw UnsupportedError(
        'a filter cannot be applied to a local fetch, which copies objects '
        'directly rather than negotiating for them',
      );
    }
    if (depth != null) {
      // A local fetch copies objects straight out of the other repository's
      // store rather than asking for them, so there is nobody to ask for a
      // truncated history. Refused rather than silently ignored: a caller who
      // asked for a shallow clone and got a complete one has been told
      // something untrue about how much was downloaded.
      throw UnsupportedError(
        'a depth cannot be applied to a local fetch, which copies objects '
        'directly rather than negotiating for them',
      );
    }
    return _fetchLocal(repository, remote, onProgress);
  }
  if (remote.url.startsWith('http://') || remote.url.startsWith('https://')) {
    return _fetchHttp(
      repository,
      remote,
      credentials,
      onProgress,
      allowVersion2,
      depth,
      filter,
    );
  }

  final connection = await connectTo(
    remote.url,
    'git-upload-pack',
    sshCommand: sshCommand,
  );
  if (connection != null) {
    return _fetchOverConnection(
      repository,
      remote,
      connection,
      onProgress,
      allowVersion2,
      depth,
      filter,
    );
  }

  throw UnsupportedError(
    'no transport for ${remote.url}: this build speaks a local path, '
    'http(s), ssh and git://',
  );
}

/// Fetches objects by name, rather than whatever the refs point at.
///
/// This is what makes a partial clone usable. A filtered fetch leaves the
/// blobs behind as promises, and something eventually has to redeem them — a
/// checkout needs the file contents at one commit, whatever the history was
/// filtered down to. Git calls this a lazy fetch and does it from inside the
/// checkout; this library's reads are synchronous, so the redeeming happens
/// here, before the synchronous part begins.
///
/// The server has to be willing to hand over objects by name. Most are for
/// objects reachable from what it already advertised, which is the only case
/// this needs.
Future<FetchResult> fetchObjects(
  Repository repository,
  Remote remote,
  Iterable<ObjectId> objects, {
  Credentials? credentials,
  void Function(String message)? onProgress,
  String? filter,
}) async {
  final wanted = {
    for (final id in objects)
      if (!repository.objects.contains(id)) id,
  };
  if (wanted.isEmpty) {
    return const FetchResult(updates: [], objectsReceived: 0);
  }
  if (!remote.url.startsWith('http://') && !remote.url.startsWith('https://')) {
    // Only smart HTTP so far. Naming objects a server never advertised is the
    // one exchange the duplex paths do not yet build, and asking for them by
    // ref instead would fetch the wrong thing rather than fail.
    throw UnsupportedError(
      'objects can be fetched by name over http(s); ${remote.url} is not',
    );
  }
  return _fetchHttp(
    repository,
    remote,
    credentials,
    onProgress,
    true,
    null,
    filter,
    wanted,
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
    // Collected rather than written one at a time, so that a large fetch can
    // be stored as a pack. A local remote is usually a clone's source, and a
    // clone is exactly the case where one file per object hurts.
    final arrived = <({ObjectId id, ObjectKind kind, Uint8List content})>[];

    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!seen.add(id)) continue;
      if (repository.objects.contains(id)) continue;

      final raw = source.objects.readRaw(id);
      if (raw == null) continue;

      arrived.add((id: id, kind: raw.kind, content: raw.content));
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

    if (arrived.length <= unpackLimit) {
      for (final object in arrived) {
        repository.objects.write(GitObject.parse(object.kind, object.content));
      }
    } else {
      onProgress?.call('packing ${arrived.length} objects');
      final writer = PackWriter();
      final names = <ObjectId, String>{};
      for (final object in arrived) {
        if (object.kind != ObjectKind.tree) continue;
        for (final entry in Tree.parse(object.content).entries) {
          if (entry.mode.isSubmodule) continue;
          names.putIfAbsent(entry.id, () => entry.name);
        }
      }
      for (final object in arrived) {
        writer.add(
          object.id,
          object.kind,
          object.content,
          name: names[object.id],
        );
      }
      final built = writer.buildWithIndex();
      repository.objects.writePack(
        packBytes: built.bytes,
        objects: built.objects,
        packChecksum: built.checksum,
      );
    }

    return FetchResult(
      updates: _applyRefspecs(repository, remote, advertised),
      objectsReceived: copied,
      advertised: advertised,
      defaultBranch: _inferDefaultBranch(source, advertised),
    );
  } finally {
    source.close();
  }
}

/// Which branch a local remote has checked out.
String? _inferDefaultBranch(
  Repository source,
  Map<String, ObjectId> advertised,
) {
  final branch = source.refs.currentBranch;
  return branch != null && advertised.containsKey(branch) ? branch : null;
}

// ---------------------------------------------------------------------------
// smart HTTP
// ---------------------------------------------------------------------------

Future<FetchResult> _fetchHttp(
  Repository repository,
  Remote remote,
  Credentials? given,
  void Function(String)? onProgress,
  bool allowVersion2,
  int? depth,
  String? filter, [
  Set<ObjectId>? explicitWants,
]) async {
  // A `user@host` URL carries the name but not the secret, and HttpClient
  // ignores both, so they are taken out here and sent as a header instead.
  final split = splitCredentials(remote.url);
  final credentials = given ??
      (split.credentials != null && split.credentials!.password.isNotEmpty
          ? split.credentials
          : null);

  final full = split.url.toString();
  final base = full.endsWith('/') ? full.substring(0, full.length - 1) : full;
  final client = newHttpClient();

  Map<String, String> headersFor(Map<String, String> extra) => {
        GitHttpHeaders.userAgent: _agent,
        if (allowVersion2) gitProtocolHeader: gitProtocolVersion2,
        if (credentials != null)
          GitHttpHeaders.authorization: credentials.authorizationHeader,
        ...extra,
      };

  Future<GitHttpResponse> post(List<int> body) async {
    final url = Uri.parse('$base/git-upload-pack');
    final response = await client.send(
      method: 'POST',
      url: url,
      headers: headersFor({
        GitHttpHeaders.contentType: 'application/x-git-upload-pack-request',
        GitHttpHeaders.accept: 'application/x-git-upload-pack-result',
      }),
      body: body,
    );
    if (response.statusCode == 401) {
      await response.body.drain<void>();
      throw AuthenticationRequired(
        base,
        realm: realmOf(response),
        wereRejected: credentials != null,
      );
    }
    if (response.statusCode != 200) {
      throw GitHttpException(
        'the server answered ${response.statusCode}',
        url: url,
      );
    }
    return response;
  }

  try {
    // ---- the advertisement ----
    onProgress?.call('contacting $base');
    final adUrl = Uri.parse('$base/info/refs?service=git-upload-pack');
    final adResponse = await client.send(
      method: 'GET',
      url: adUrl,
      headers: headersFor(const {}),
    );
    if (adResponse.statusCode == 401) {
      await adResponse.body.drain<void>();
      throw AuthenticationRequired(
        base,
        realm: realmOf(adResponse),
        wereRejected: credentials != null,
      );
    }
    if (adResponse.statusCode != 200) {
      throw GitHttpException(
        'the server answered ${adResponse.statusCode} for the ref '
        'advertisement',
        url: adUrl,
      );
    }
    final advertisement = await _collect(adResponse.body);

    // A version 2 server answers the same request with its capabilities
    // instead of its refs. Which arrived is how the version is settled — the
    // header was a request, not a decision.
    final v2 = allowVersion2
        ? readV2Capabilities(advertisement)
        : const V2Capabilities({});

    // Awaited rather than returned: the client is closed in the `finally`
    // below, and returning the future unawaited would close it out from under
    // the request it describes.
    if (v2.supportsFetch) {
      return await _fetchHttpV2(
        repository,
        remote,
        v2,
        post,
        onProgress,
        depth,
        filter,
        explicitWants,
      );
    }
    return await _fetchHttpV0(
      repository,
      remote,
      advertisement,
      post,
      onProgress,
      depth,
      filter,
      explicitWants,
    );
  } finally {
    client.close();
  }
}

/// Version 0 over HTTP, with the negotiation re-sent whole each round.
///
/// The server keeps nothing between requests, so every round repeats the wants
/// and every `have` said so far. That is wasteful and it is what makes smart
/// HTTP work through any proxy that understands nothing but requests and
/// responses.
Future<FetchResult> _fetchHttpV0(
  Repository repository,
  Remote remote,
  Uint8List advertisement,
  Future<GitHttpResponse> Function(List<int>) post,
  void Function(String)? onProgress,
  int? depth,
  String? filter, [
  Set<ObjectId>? explicitWants,
]) async {
  final parsed = _readAdvertisement(advertisement);
  final advertised = parsed.refs;
  final capabilities = parsed.capabilities;

  final wants = explicitWants?.toList() ??
      _wantsFor(repository, remote, advertised, deepening: depth != null);
  if (wants.isEmpty) {
    return FetchResult(
      updates: _applyRefspecs(repository, remote, advertised),
      objectsReceived: 0,
      advertised: advertised,
      defaultBranch: parsed.symrefHead,
    );
  }

  final sideBand = capabilities.contains('side-band-64k');
  final agreed = <String>[
    if (sideBand) 'side-band-64k',
    if (capabilities.contains('ofs-delta')) 'ofs-delta',
    if (capabilities.contains('multi_ack_detailed')) 'multi_ack_detailed',
    // Version 0 negotiates capabilities on the first want line, so asking for
    // a filter takes both this and the `filter` line below. With only the
    // line, the server ignores it, sends nothing, and the clone ends with an
    // unborn HEAD — which is a long way from "the filter was not agreed".
    if (filter != null) 'filter',
    'agent=$_agent',
  ];
  final canNegotiate = capabilities.contains('multi_ack_detailed') ||
      capabilities.contains('multi_ack');

  if (depth != null && !capabilities.contains('shallow')) {
    throw UnsupportedError(
      'this server does not offer shallow fetches, so a depth cannot be '
      'honoured',
    );
  }
  if (filter != null && !capabilities.contains('filter')) {
    // `uploadpack.allowFilter` is off by default, so a server that has not
    // opted in simply does not mention it. Sending the line anyway gets the
    // whole repository and a caller who believes otherwise.
    throw UnsupportedError(
      'this server does not offer filtered fetches, so a filter cannot be '
      'honoured',
    );
  }

  Uint8List requestFor(List<ObjectId> haves, {required bool done}) {
    final body = BytesBuilder();
    for (var i = 0; i < wants.length; i++) {
      body.add(PktLine.text(
        i == 0
            ? 'want ${wants[i].hex} ${agreed.join(' ')}\n'
            : 'want ${wants[i].hex}\n',
      ).encode());
    }
    if (filter != null) {
      body.add(PktLine.text('filter $filter\n').encode());
    }
    // Where our history already stops, so the server does not assume we hold
    // everything behind our `have` lines.
    for (final id in repository.shallowCommits) {
      body.add(PktLine.text('shallow ${id.hex}\n').encode());
    }
    // After the wants and before the flush that closes them: the server reads
    // the whole want section before it answers, and a deepen line outside it
    // is a protocol error rather than a request it ignores.
    if (depth != null) {
      body.add(PktLine.text('deepen $depth\n').encode());
    }
    body.add(PktLine.flush.encode());
    for (final have in haves) {
      body.add(PktLine.text('have ${have.hex}\n').encode());
    }
    if (done) {
      body.add(PktLine.text('done\n').encode());
    } else {
      body.add(PktLine.flush.encode());
    }
    return body.takeBytes();
  }

  // ---- negotiation ----
  final negotiator = Negotiator(repository);
  final told = <ObjectId>[];
  var rounds = 0;

  if (canNegotiate) {
    for (var round = 0; round < 16; round++) {
      final batch = negotiator.nextRound();
      if (batch.isEmpty) break;
      told.addAll(batch);
      rounds += 1;

      onProgress?.call('negotiating (${told.length} offered)');
      final response = await post(requestFor(told, done: false));
      final reply = parseNegotiation(
        _textPackets(await _collect(response.body)),
      );

      for (final id in reply.acknowledged) {
        negotiator.markCommon(id);
      }
      // The server has enough to build a pack; more offers would only make
      // the request longer.
      if (reply.ready) break;
      if (negotiator.isExhausted) break;
    }
  } else {
    // No multi-ack: one shot, with a frontier rather than every ref tip.
    told.addAll(negotiator.nextRound());
  }

  // ---- the pack ----
  onProgress?.call('asking for ${wants.length} refs');
  final response = await post(requestFor(told, done: true));

  // The boundary arrives ahead of the pack, unbanded, so the bytes have to be
  // read once to find it and once to unpack — which is why this path buffers
  // when a depth was asked for and streams when it was not.
  if (depth != null) {
    final whole = await _collect(response.body);
    _recordShallow(repository, parseShallow(_textPackets(whole)));
    final received = await _receivePack(
      repository,
      Stream.value(whole),
      usedSideBand: sideBand,
      promisor: filter != null,
      onProgress: onProgress,
    );
    return FetchResult(
      updates: _applyRefspecs(repository, remote, advertised),
      objectsReceived: received,
      advertised: advertised,
      defaultBranch: parsed.symrefHead,
      negotiationRounds: rounds,
    );
  }

  final received = await _receivePack(
    repository,
    response.body,
    usedSideBand: sideBand,
    promisor: filter != null,
    onProgress: onProgress,
  );

  return FetchResult(
    updates: _applyRefspecs(repository, remote, advertised),
    objectsReceived: received,
    advertised: advertised,
    defaultBranch: parsed.symrefHead,
    negotiationRounds: rounds,
  );
}

/// Version 2 over HTTP: `ls-refs`, then `fetch`.
Future<FetchResult> _fetchHttpV2(
  Repository repository,
  Remote remote,
  V2Capabilities capabilities,
  Future<GitHttpResponse> Function(List<int>) post,
  void Function(String)? onProgress,
  int? depth,
  String? filter, [
  Set<ObjectId>? explicitWants,
]) async {
  onProgress?.call('protocol version 2');

  if (filter != null && !capabilities.supportsFilter) {
    throw UnsupportedError(
      'this server does not offer filtered fetches, so a filter cannot be '
      'honoured',
    );
  }

  // Only the refs this remote's refspecs could possibly use. On a repository
  // with very many refs this is the whole point of version 2.
  final prefixes = _prefixesFor(remote);
  final listed = parseLsRefs(
    await _collect((await post(lsRefsRequest(prefixes: prefixes))).body),
  );
  final advertised = listed.refs;

  final wants = explicitWants?.toList() ??
      _wantsFor(repository, remote, advertised, deepening: depth != null);
  if (wants.isEmpty) {
    return FetchResult(
      updates: _applyRefspecs(repository, remote, advertised),
      objectsReceived: 0,
      advertised: advertised,
      defaultBranch: listed.defaultBranch,
      protocolVersion: 2,
    );
  }

  final negotiator = Negotiator(repository);
  final told = <ObjectId>[];
  var rounds = 0;

  if (capabilities.canNegotiate) {
    for (var round = 0; round < 16; round++) {
      final batch = negotiator.nextRound();
      if (batch.isEmpty) break;
      told.addAll(batch);
      rounds += 1;

      onProgress?.call('negotiating (${told.length} offered)');
      final body = await _collect((await post(fetchRequest(
        wants: wants,
        haves: told,
        done: false,
        depth: depth,
        shallow: repository.shallowCommits,
        filter: filter,
      ))).body);

      final reply = parseNegotiation(_textPackets(body));
      for (final id in reply.acknowledged) {
        negotiator.markCommon(id);
      }
      if (reply.ready) break;
      if (negotiator.isExhausted) break;
    }
  }

  onProgress?.call('asking for ${wants.length} refs');
  final response = await post(fetchRequest(
    wants: wants,
    haves: told,
    done: true,
    depth: depth,
    shallow: repository.shallowCommits,
    filter: filter,
  ));

  // Version 2 names its sections, so the boundary is read from `shallow-info`
  // rather than guessed at from position.
  if (depth != null) {
    final whole = await _collect(response.body);
    _recordShallow(repository, parseShallow(_textPackets(whole)));
    final received = await _receivePack(
      repository,
      Stream.value(whole),
      usedSideBand: true,
      version2: true,
      promisor: filter != null,
      onProgress: onProgress,
    );
    return FetchResult(
      updates: _applyRefspecs(repository, remote, advertised),
      objectsReceived: received,
      advertised: advertised,
      defaultBranch: listed.defaultBranch,
      protocolVersion: 2,
      negotiationRounds: rounds,
    );
  }

  final received = await _receivePack(
    repository,
    response.body,
    usedSideBand: true,
    version2: true,
    promisor: filter != null,
    onProgress: onProgress,
  );

  return FetchResult(
    updates: _applyRefspecs(repository, remote, advertised),
    objectsReceived: received,
    advertised: advertised,
    defaultBranch: listed.defaultBranch,
    protocolVersion: 2,
    negotiationRounds: rounds,
  );
}

// ---------------------------------------------------------------------------
// ssh and the git daemon
// ---------------------------------------------------------------------------

/// One open connection, so the negotiation is a conversation rather than a
/// series of restatements.
Future<FetchResult> _fetchOverConnection(
  Repository repository,
  Remote remote,
  PacketConnection connection,
  void Function(String)? onProgress,
  bool allowVersion2,
  int? depth,
  String? filter,
) async {
  try {
    // ---- what the server opened with ----
    final opening = <PktLine>[];
    while (true) {
      final packet = await connection.receive();
      if (packet == null || packet.kind != PktKind.data) break;
      opening.add(packet);
    }
    if (opening.isEmpty) {
      throw StateError(
        'the server said nothing. '
        '${connection is SshConnection && connection.diagnostics.isNotEmpty
            ? connection.diagnostics
            : 'It may not have a repository at that path.'}',
      );
    }

    final rejoined = BytesBuilder();
    for (final packet in opening) {
      rejoined.add(packet.encode());
    }
    rejoined.add(PktLine.flush.encode());
    final advertisement = rejoined.takeBytes();

    final v2 = allowVersion2
        ? readV2Capabilities(advertisement)
        : const V2Capabilities({});

    // Awaited, not returned: the connection is closed in the `finally` below.
    if (v2.supportsFetch) {
      return await _fetchConnectionV2(
        repository,
        remote,
        connection,
        v2,
        onProgress,
        depth,
        filter,
      );
    }
    return await _fetchConnectionV0(
      repository,
      remote,
      connection,
      advertisement,
      onProgress,
      depth,
      filter,
    );
  } finally {
    await connection.close();
  }
}

Future<FetchResult> _fetchConnectionV0(
  Repository repository,
  Remote remote,
  PacketConnection connection,
  Uint8List advertisement,
  void Function(String)? onProgress,
  int? depth,
  String? filter,
) async {
  final parsed = _readAdvertisement(advertisement);
  final advertised = parsed.refs;
  final capabilities = parsed.capabilities;

  final wants =
      _wantsFor(repository, remote, advertised, deepening: depth != null);
  if (wants.isEmpty) {
    // Nothing to ask for: the server is told so rather than left waiting.
    connection.send(PktLine.flush.encode());
    await connection.flush();
    return FetchResult(
      updates: _applyRefspecs(repository, remote, advertised),
      objectsReceived: 0,
      advertised: advertised,
      defaultBranch: parsed.symrefHead,
    );
  }

  if (depth != null && !capabilities.contains('shallow')) {
    throw UnsupportedError(
      'this server does not offer shallow fetches, so a depth cannot be '
      'honoured',
    );
  }
  if (filter != null && !capabilities.contains('filter')) {
    throw UnsupportedError(
      'this server does not offer filtered fetches, so a filter cannot be '
      'honoured',
    );
  }

  final sideBand = capabilities.contains('side-band-64k');
  final agreed = <String>[
    if (sideBand) 'side-band-64k',
    if (capabilities.contains('ofs-delta')) 'ofs-delta',
    if (capabilities.contains('multi_ack_detailed')) 'multi_ack_detailed',
    if (filter != null) 'filter',
    'agent=$_agent',
  ];

  for (var i = 0; i < wants.length; i++) {
    connection.send(PktLine.text(
      i == 0
          ? 'want ${wants[i].hex} ${agreed.join(' ')}\n'
          : 'want ${wants[i].hex}\n',
    ).encode());
  }
  if (filter != null) {
    connection.send(PktLine.text('filter $filter\n').encode());
  }
  for (final id in repository.shallowCommits) {
    connection.send(PktLine.text('shallow ${id.hex}\n').encode());
  }
  if (depth != null) {
    connection.send(PktLine.text('deepen $depth\n').encode());
  }
  connection.send(PktLine.flush.encode());
  await connection.flush();

  // A deepen is answered before the negotiation begins: the server names the
  // commits whose parents it is withholding, then falls silent again. On a
  // duplex connection that reply is a section of its own rather than part of
  // the buffered response smart HTTP returns, which is the whole reason this
  // path needed writing separately.
  if (depth != null) {
    final lines = <String>[];
    while (true) {
      final packet = await connection.receive();
      if (packet == null || packet.kind != PktKind.data) break;
      lines.add(packet.text);
    }
    _recordShallow(repository, parseShallow(lines));
  }

  // ---- negotiation, as a conversation ----
  final negotiator = Negotiator(repository);
  final canNegotiate = capabilities.contains('multi_ack_detailed') ||
      capabilities.contains('multi_ack');
  var rounds = 0;

  if (canNegotiate) {
    for (var round = 0; round < 16; round++) {
      final batch = negotiator.nextRound();
      if (batch.isEmpty) break;
      rounds += 1;

      for (final have in batch) {
        connection.send(PktLine.text('have ${have.hex}\n').encode());
      }
      connection.send(PktLine.flush.encode());
      await connection.flush();
      onProgress?.call('negotiating (round $rounds)');

      final lines = <String>[];
      while (true) {
        final packet = await connection.receive();
        if (packet == null || packet.kind != PktKind.data) break;
        lines.add(packet.text);
      }

      final reply = parseNegotiation(lines);
      for (final id in reply.acknowledged) {
        negotiator.markCommon(id);
      }
      if (reply.ready) break;
      if (negotiator.isExhausted) break;
    }
  } else {
    for (final have in negotiator.nextRound()) {
      connection.send(PktLine.text('have ${have.hex}\n').encode());
    }
  }

  connection.send(PktLine.text('done\n').encode());

  // Without side-band there is no framing around the pack and no flush after
  // it, so the only end is the server hanging up — which is what the rest of
  // the stream means there, and only there.
  final received = sideBand
      ? await _receivePack(
          repository,
          _packPacketsFrom(connection, version2: false, onProgress: onProgress),
          usedSideBand: true,
          framed: false,
          promisor: filter != null,
          onProgress: onProgress,
        )
      : await _receivePack(
          repository,
          connection.remaining,
          usedSideBand: false,
          promisor: filter != null,
          onProgress: onProgress,
        );

  return FetchResult(
    updates: _applyRefspecs(repository, remote, advertised),
    objectsReceived: received,
    advertised: advertised,
    defaultBranch: parsed.symrefHead,
    negotiationRounds: rounds,
  );
}

Future<FetchResult> _fetchConnectionV2(
  Repository repository,
  Remote remote,
  PacketConnection connection,
  V2Capabilities capabilities,
  void Function(String)? onProgress,
  int? depth,
  String? filter,
) async {
  onProgress?.call('protocol version 2');

  if (filter != null && !capabilities.supportsFilter) {
    throw UnsupportedError(
      'this server does not offer filtered fetches, so a filter cannot be '
      'honoured',
    );
  }

  connection.send(lsRefsRequest(prefixes: _prefixesFor(remote)));
  await connection.flush();

  final listing = BytesBuilder();
  while (true) {
    final packet = await connection.receive();
    if (packet == null || packet.kind != PktKind.data) break;
    listing.add(packet.encode());
  }
  final listed = parseLsRefs(listing.takeBytes());
  final advertised = listed.refs;

  final wants =
      _wantsFor(repository, remote, advertised, deepening: depth != null);
  if (wants.isEmpty) {
    return FetchResult(
      updates: _applyRefspecs(repository, remote, advertised),
      objectsReceived: 0,
      advertised: advertised,
      defaultBranch: listed.defaultBranch,
      protocolVersion: 2,
    );
  }

  // Version 2 over one connection still repeats the wants each round, because
  // each `fetch` command is self-contained — the command boundary is what
  // replaced the stateful conversation.
  final negotiator = Negotiator(repository);
  final told = <ObjectId>[];
  var rounds = 0;

  if (capabilities.canNegotiate) {
    for (var round = 0; round < 16; round++) {
      final batch = negotiator.nextRound();
      if (batch.isEmpty) break;
      told.addAll(batch);
      rounds += 1;

      connection.send(fetchRequest(
        wants: wants,
        haves: told,
        done: false,
        depth: depth,
        shallow: repository.shallowCommits,
        filter: filter,
      ));
      await connection.flush();

      final lines = <String>[];
      var sawSection = false;
      while (true) {
        final packet = await connection.receive();
        if (packet == null || packet.kind != PktKind.data) break;
        final text = packet.text.trim();
        if (!sawSection && sectionNamed(text) != V2Section.unknown) {
          sawSection = true;
          continue;
        }
        lines.add(text);
      }

      final reply = parseNegotiation(lines);
      for (final id in reply.acknowledged) {
        negotiator.markCommon(id);
      }
      if (reply.ready) break;
      if (negotiator.isExhausted) break;
    }
  }

  onProgress?.call('asking for ${wants.length} refs');
  connection.send(fetchRequest(
    wants: wants,
    haves: told,
    done: true,
    depth: depth,
    shallow: repository.shallowCommits,
    filter: filter,
  ));
  await connection.flush();

  final control = <String>[];
  final received = await _receivePack(
    repository,
    _packPacketsFrom(
      connection,
      version2: true,
      onProgress: onProgress,
      onControlLine: control.add,
    ),
    usedSideBand: true,
    framed: false,
    promisor: filter != null,
    onProgress: onProgress,
  );
  _recordShallow(repository, parseShallow(control));

  return FetchResult(
    updates: _applyRefspecs(repository, remote, advertised),
    objectsReceived: received,
    advertised: advertised,
    defaultBranch: listed.defaultBranch,
    protocolVersion: 2,
    negotiationRounds: rounds,
  );
}

/// The packfile, out of the packets the server is still sending.
///
/// Reading "the rest of the stream" would be simpler and does not work here: a
/// socket or a pipe does not end when the server has finished speaking, only
/// when it hangs up, and it hangs up when *we* do. Waiting for the end of the
/// stream is therefore waiting for something that will not happen until we
/// stop waiting — which looks exactly like a network that has gone away. Over
/// HTTP the response ends by itself, which is why the same code was fine
/// there and hung here.
///
/// The pack is delivered as side-band packets and terminated by a flush, so
/// the flush is the thing to stop on.
Stream<List<int>> _packPacketsFrom(
  PacketConnection connection, {
  required bool version2,
  void Function(String)? onProgress,
  void Function(String)? onControlLine,
}) async* {
  var inPack = !version2;

  while (true) {
    final packet = await connection.receive();
    if (packet == null) return;

    if (packet.kind == PktKind.flush) {
      // The flush that ends the pack, or one of the flushes that ends the
      // acknowledgements before it.
      if (inPack) return;
      continue;
    }
    if (packet.kind != PktKind.data) continue;

    if (version2 && !inPack) {
      // Version 2 names its sections, so the pack begins where it says it
      // does rather than wherever the acknowledgements happen to stop.
      final text = packet.text.trim();
      if (sectionNamed(text) == V2Section.packfile) {
        inPack = true;
      } else {
        onControlLine?.call(text);
      }
      continue;
    }

    if (packet.payload.isEmpty) continue;
    final band = packet.payload.first;
    final rest = Uint8List.sublistView(packet.payload, 1);

    switch (band) {
      case 1:
        yield rest;
      case 2:
        final message = utf8.decode(rest, allowMalformed: true).trim();
        if (message.isNotEmpty) onProgress?.call(message);
      case 3:
        throw StateError(
          'the server reported: ${utf8.decode(rest, allowMalformed: true)}',
        );
      default:
        // Before the pack, version 0 sends NAK and ACK unbanded.
        final text = utf8.decode(packet.payload, allowMalformed: true);
        if (!text.startsWith('NAK') && !text.startsWith('ACK')) {
          throw FormatException('unknown side band $band');
        }
    }
  }
}

// ---------------------------------------------------------------------------
// shared
// ---------------------------------------------------------------------------

/// Applies what the server said about the shallow boundary.
///
/// `shallow` adds a commit whose parents were not sent; `unshallow` removes
/// one because they since have been. Both are applied to what the repository
/// already recorded, because a deepening fetch reports only what changed —
/// replacing the file with just this round's `shallow` lines would forget
/// every boundary the earlier fetches established.
void _recordShallow(Repository repository, ShallowUpdate update) {
  if (update.isEmpty) return;
  final boundary = {...repository.shallowCommits}
    ..addAll(update.shallow)
    ..removeAll(update.unshallow);
  repository.writeShallowCommits(boundary);
}

/// The ref prefixes this remote's refspecs could match, for `ls-refs`.
List<String> _prefixesFor(Remote remote) {
  final prefixes = <String>{};
  for (final spec in remote.effectiveFetchSpecs) {
    final source = spec.source;
    prefixes.add(source.endsWith('*')
        ? source.substring(0, source.length - 1)
        : source);
  }
  // Tags are wanted even when no refspec names them, because a fetch brings
  // the tags that point into what it fetched.
  prefixes.add('refs/tags/');
  // And HEAD, which is not under `refs/` and so is matched by no prefix that
  // starts with it. Without asking for it explicitly the server never mentions
  // it, and `symrefs` has nothing to report — so a clone cannot learn which
  // branch to check out, which is the one thing version 2 was meant to make
  // askable.
  prefixes.add('HEAD');
  return prefixes.toList()..sort();
}

/// What to ask the server for: advertised refs this remote tracks and this
/// repository does not already have.
List<ObjectId> _wantsFor(
  Repository repository,
  Remote remote,
  Map<String, ObjectId> advertised, {
  bool deepening = false,
}) {
  final wants = <ObjectId>[];
  for (final entry in advertised.entries) {
    if (remote.trackingRefFor(entry.key) == null) continue;
    // Already here, so ordinarily there is nothing to ask for. A deepening
    // fetch is the exception: it wants the same tip and more of the history
    // behind it, and skipping the want because the tip is present asks for
    // nothing at all — which is how a deepen silently did nothing.
    if (!deepening && repository.objects.contains(entry.value)) continue;
    if (!wants.contains(entry.value)) wants.add(entry.value);
  }
  return wants;
}

/// Streams the packfile to disk, indexes it, and stores it.
///
/// [framed] says whether [response] is still a pkt-line stream that has to be
/// unwrapped, as an HTTP response body is, or the pack bytes themselves, as
/// [_packPacketsFrom] has already produced.
Future<int> _receivePack(
  Repository repository,
  Stream<List<int>> response, {
  required bool usedSideBand,
  bool version2 = false,
  bool framed = true,
  bool promisor = false,
  void Function(String)? onProgress,
}) async {
  // Written to disk as it arrives rather than assembled in memory. The
  // response is the size of what is being cloned, and holding it whole — then
  // the pack it contains, then every object inflated out of that — is three
  // copies of a repository at once.
  final temporary = fs.file(p.join(
    repository.gitDirectory,
    'objects',
    'pack',
    'incoming-$processId.pack',
  ))
    ..parent.createSync(recursive: true);

  final received = framed
      ? await _streamPackTo(
          temporary,
          response,
          usedSideBand: usedSideBand,
          version2: version2,
          onProgress: onProgress,
        )
      : await _writeStreamTo(temporary, response);

  try {
    if (received == 0) return 0;

    onProgress?.call('indexing');
    final indexed = PackIndexer(temporary.path).run();

    // A filtered fetch is always kept as a pack, however few objects it
    // brought. The marker that says its absences were promised sits *beside a
    // pack*; there is nowhere to record it for a loose object, so unpacking a
    // small filtered fetch would silently turn a partial repository into a
    // corrupt-looking one.
    if (indexed.count <= unpackLimit && !promisor) {
      // A handful of objects are cheaper to read loose than through an index,
      // and a pack of three objects is mostly header.
      final objects = PackParser(temporary.readAsBytesSync()).parse();
      objects.forEach((id, object) {
        repository.objects.write(GitObject.parse(object.kind, object.content));
      });
    } else {
      repository.objects.writePackFile(
        packPath: temporary.path,
        objects: indexed.objects,
        packChecksum: indexed.checksum,
        promisor: promisor,
      );
    }
    return indexed.count;
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

/// Writes a stream of pack bytes straight to a file.
Future<int> _writeStreamTo(GitFsFile file, Stream<List<int>> bytes) async {
  final sink = file.openWrite();
  var written = 0;
  try {
    await for (final chunk in bytes) {
      sink.add(chunk);
      written += chunk.length;
    }
  } finally {
    await sink.close();
  }
  return written;
}

/// Collects a whole response into memory.
///
/// Used for advertisements and negotiation replies, which are lists of names
/// read all at once. The pack is not read this way — see [_streamPackTo].
Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder();
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// The text of every data packet in [bytes].
List<String> _textPackets(Uint8List bytes) {
  final reader = PktLineReader(bytes);
  final lines = <String>[];
  while (true) {
    final packet = reader.next();
    if (packet == null) break;
    if (packet.kind == PktKind.data) lines.add(packet.text);
  }
  return lines;
}

/// Writes the packfile out of a side-banded response into [file] as the bytes
/// arrive, and returns how many pack bytes were written.
///
/// With side-band-64k the pack comes in pkt-lines whose first byte says which
/// band it is: 1 is the pack, 2 is progress for a person, 3 is an error.
Future<int> _streamPackTo(
  GitFsFile file,
  Stream<List<int>> response, {
  required bool usedSideBand,
  bool version2 = false,
  void Function(String)? onProgress,
}) async {
  final reader = PktLineStreamReader();
  final sink = file.openWrite();
  var written = 0;
  var inPack = !version2;

  try {
    await for (final chunk in response) {
      for (final packet in reader.add(chunk)) {
        if (packet.kind != PktKind.data) continue;

        if (version2 && !inPack) {
          // Version 2 names its sections, so the pack begins where it says it
          // does rather than wherever the acknowledgements stop.
          final text = packet.text.trim();
          if (sectionNamed(text) == V2Section.packfile) {
            inPack = true;
          }
          continue;
        }

        if (!usedSideBand) {
          final text = packet.text;
          // Acknowledgements come before the pack and are not part of it.
          if (text.startsWith('NAK') || text.startsWith('ACK')) continue;
          sink.add(packet.payload);
          written += packet.payload.length;
          continue;
        }

        if (packet.payload.isEmpty) continue;
        final band = packet.payload.first;
        final rest = Uint8List.sublistView(packet.payload, 1);

        switch (band) {
          case 1:
            sink.add(rest);
            written += rest.length;
          case 2:
            final message = utf8.decode(rest, allowMalformed: true).trim();
            if (message.isNotEmpty) onProgress?.call(message);
          case 3:
            throw StateError(
              'the server reported: ${utf8.decode(rest, allowMalformed: true)}',
            );
          default:
            // Not every packet before the pack is banded. Version 0 sends the
            // acknowledgements and the shallow boundary as plain lines, so
            // their first byte is a letter rather than a band number — 's' for
            // `shallow` reads as band 115, which is how this was found.
            final text = utf8.decode(packet.payload, allowMalformed: true);
            const unbanded = ['NAK', 'ACK', 'shallow ', 'unshallow '];
            if (!unbanded.any(text.startsWith)) {
              throw FormatException('unknown side band $band');
            }
        }
      }
    }
  } finally {
    await sink.close();
  }

  return written;
}

/// Reads `# service=…`, then the ref lines, then the capabilities that came
/// after the NUL on the first of them (`transfer.advertisement`).
({
  Map<String, ObjectId> refs,
  Set<String> capabilities,
  String? symrefHead,
}) _readAdvertisement(Uint8List bytes) {
  final reader = PktLineReader(bytes);
  final refs = <String, ObjectId>{};
  final capabilities = <String>{};
  String? symrefHead;

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
      // `symref=HEAD:refs/heads/main` is how version 0 says which branch is
      // the default — a capability rather than a question a client can ask,
      // which is one of the things version 2 exists to fix.
      for (final capability in line.capabilities) {
        if (!capability.startsWith('symref=HEAD:')) continue;
        symrefHead = capability.substring('symref=HEAD:'.length);
      }
      first = false;
    }
    // A peeled tag is advertised as `refs/tags/x^{}`; the tag object itself is
    // the one to track.
    if (line.path.endsWith('^{}')) continue;
    if (line.name == '0' * 40) continue; // an empty repository
    refs[line.path] = ObjectId.fromHex(line.name);
  }

  return (refs: refs, capabilities: capabilities, symrefHead: symrefHead);
}

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
      repository.refs.write(
        local,
        entry.value,
        reflogMessage: 'fetch ${remote.name}: '
            '${before == null ? 'storing head' : 'fast-forward'}',
      );
    }
    updates.add(RefUpdate(ref: local, from: before, to: entry.value));
  }

  updates.sort((a, b) => a.ref.compareTo(b.ref));
  return updates;
}
