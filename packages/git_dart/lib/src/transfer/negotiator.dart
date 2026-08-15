import 'dart:collection';

import '../object_id.dart';
import '../objects/commit.dart';
import '../repository.dart';

/// Decides what to tell a server we already have.
///
/// The client says what it wants and what it has; the server sends the
/// difference. Doing this well is the difference between a fetch that sends
/// the repository and one that sends what is missing
/// (`transfer.negotiation`).
///
/// Naively, "what we have" is every ref tip. That is cheap and often terrible:
/// a repository whose branches have all moved on since the last fetch tells
/// the server about tips it has never seen, the server finds nothing in
/// common, and it sends everything. What is wanted is the *frontier* — commits
/// recent enough to be plausible common ground — offered newest first, in
/// rounds, so the exchange stops as soon as the server recognises one.
///
/// This walks history newest first and hands out batches. When the server says
/// it has a commit, everything that commit can reach is common too and is
/// dropped from the walk: one acknowledgement can retire a great deal of
/// history, which is the whole reason the rounds are worth doing.
class Negotiator {
  final Repository repository;

  /// How many `have` lines go in each round.
  ///
  /// Git sends sixteen in the first round and more later. Small first rounds
  /// keep the common case — a fetch a day after the last one — down to a
  /// single short exchange.
  final int firstBatch;
  final int laterBatch;

  /// The most `have` lines to send before giving up and letting the server
  /// send more than it strictly must. Without a cap, a fetch into a large
  /// repository with no common history walks all of it to prove there is
  /// nothing to find.
  final int limit;

  Negotiator(
    this.repository, {
    this.firstBatch = 16,
    this.laterBatch = 64,
    this.limit = 4096,
  });

  /// Newest first, which is where common ground is most likely to be.
  late final SplayTreeSet<Commit> _frontier = SplayTreeSet<Commit>((a, b) {
    final byDate = b.committer.seconds.compareTo(a.committer.seconds);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  });

  final _seen = <ObjectId>{};
  final _sent = <ObjectId>{};

  /// Commits the server has confirmed, and everything they reach.
  final _common = <ObjectId>{};

  var _started = false;
  var _rounds = 0;

  int get sentCount => _sent.length;
  bool get foundCommon => _common.isNotEmpty;

  void _start() {
    if (_started) return;
    _started = true;

    // Every local ref, plus HEAD: the walk starts wherever this repository
    // has been, and the ordering does the rest.
    final roots = <ObjectId>[];
    for (final ref in repository.refs.list()) {
      final id = repository.refs.resolve(ref.path);
      if (id != null) roots.add(id);
    }
    final head = repository.headId;
    if (head != null) roots.add(head);

    for (final id in roots) {
      _consider(id);
    }
  }

  void _consider(ObjectId id) {
    if (!_seen.add(id)) return;
    if (_common.contains(id)) return;
    final raw = repository.objects.readRaw(id);
    if (raw == null) return;
    final object = repository.objects.read(id);
    if (object is Commit) _frontier.add(object);
  }

  /// The next batch of names to offer, or empty when there is nothing left to
  /// say.
  List<ObjectId> nextRound() {
    _start();

    final wanted = _rounds == 0 ? firstBatch : laterBatch;
    _rounds += 1;

    final batch = <ObjectId>[];
    while (batch.length < wanted && _frontier.isNotEmpty) {
      if (_sent.length >= limit) break;

      final commit = _frontier.first;
      _frontier.remove(commit);

      // Retired between being queued and being reached: the server has
      // already said it has something that reaches this.
      if (_common.contains(commit.id)) continue;

      batch.add(commit.id);
      _sent.add(commit.id);
      for (final parent in commit.parents) {
        _consider(parent);
      }
    }
    return batch;
  }

  bool get isExhausted => _started && _frontier.isEmpty;

  /// Records that the server has [id].
  ///
  /// Everything reachable from it is therefore common too, and none of it is
  /// worth mentioning. This is what makes the rounds converge quickly rather
  /// than plodding through history a batch at a time.
  void markCommon(ObjectId id) {
    if (!_common.add(id)) return;

    final pending = <ObjectId>[id];
    while (pending.isNotEmpty) {
      final at = pending.removeLast();
      final raw = repository.objects.readRaw(at);
      if (raw == null) continue;
      final object = repository.objects.read(at);
      if (object is! Commit) continue;
      for (final parent in object.parents) {
        if (_common.add(parent)) pending.add(parent);
      }
    }

    _frontier.removeWhere((commit) => _common.contains(commit.id));
  }
}

/// What a server said in reply to a round of `have` lines.
class NegotiationReply {
  /// Names the server confirmed having.
  final List<ObjectId> acknowledged;

  /// The server has enough common history to build a pack and is not asking
  /// for more.
  final bool ready;

  /// The server found nothing in common in this round.
  final bool nak;

  const NegotiationReply({
    this.acknowledged = const [],
    this.ready = false,
    this.nak = false,
  });
}

/// Reads `ACK <name> [status]` and `NAK` lines.
///
/// `ACK <name> continue` means "I have this, keep going"; `ready` means the
/// server has enough and will send a pack as soon as it is told to. A plain
/// `ACK <name>` in protocol v0 without multi_ack ends the negotiation.
NegotiationReply parseNegotiation(Iterable<String> lines) {
  final acknowledged = <ObjectId>[];
  var ready = false;
  var nak = false;

  for (final raw in lines) {
    final line = raw.trim();
    if (line == 'NAK') {
      nak = true;
      continue;
    }
    if (!line.startsWith('ACK ')) continue;

    final parts = line.split(' ');
    if (parts.length < 2 || parts[1].length != ObjectId.hexLength) continue;
    acknowledged.add(ObjectId.fromHex(parts[1]));
    if (parts.length > 2 && parts[2] == 'ready') ready = true;
  }

  return NegotiationReply(
    acknowledged: acknowledged,
    ready: ready,
    nak: nak,
  );
}
