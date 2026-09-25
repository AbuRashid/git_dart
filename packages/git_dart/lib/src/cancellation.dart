/// Stopping work that is no longer wanted.
///
/// Every read in this library is synchronous, which is what makes it simple
/// and is also why it cannot be interrupted from outside: a walk of ten
/// thousand commits holds its thread until it is finished. Nothing here
/// changes that. What it adds is a question the walk asks between units of
/// work — one commit, one file, one tree entry — so that work whose answer
/// nobody wants any more stops at the next boundary instead of running to the
/// end.
///
/// That distinction is worth stating plainly, because the alternative is a
/// promise this cannot keep. A caller can stop waiting for an answer at any
/// time; the work stops only where it was willing to look up.
library;

/// Something a long walk asks, between units of work, whether to stop.
///
/// Implementations are read from whichever thread is doing the work, so an
/// implementation that crosses isolates has to arrange for the answer to
/// change while that thread is busy — a message will not do, since the thread
/// is not reading messages. Sharing a word of memory will.
abstract interface class Cancellation {
  /// Whether the work should stop. Asked often, so it should be cheap.
  bool get isCancelled;

  /// Never cancelled, which is what every caller that does not ask for this
  /// gets.
  static const Cancellation none = _NeverCancelled();
}

class _NeverCancelled implements Cancellation {
  const _NeverCancelled();

  @override
  bool get isCancelled => false;
}

/// Thrown by a walk that was asked to stop.
///
/// A distinct type rather than an empty result: "there are no commits" and "I
/// stopped looking for commits" are different answers, and a caller that
/// cannot tell them apart will cache the wrong one.
class CancelledException implements Exception {
  /// What was being done, for a message a person might read.
  final String doing;

  const CancelledException(this.doing);

  @override
  String toString() => '$doing was cancelled';
}

/// Throws [CancelledException] when [cancel] says to stop.
///
/// A function rather than a method on the interface so that the common case —
/// no cancellation at all — is a field read and a branch.
void checkCancelled(Cancellation? cancel, String doing) {
  if (cancel != null && cancel.isCancelled) {
    throw CancelledException(doing);
  }
}

/// A cancellation this process controls directly.
///
/// Useful in one isolate — a timeout, a caller that changed its mind between
/// two calls — and as the thing a transport's own flag is compared against in
/// tests.
class CancellationSource implements Cancellation {
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
