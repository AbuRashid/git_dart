/// A word of memory the worker can read while it is busy.
///
/// Cancelling a request that has not started yet is easy: the worker takes
/// them one at a time, and a message saying "not that one" is waiting when it
/// looks. Cancelling the request it is *running* is the hard half, because
/// every git_dart read is synchronous — the worker is not reading messages
/// while it works, so a message cannot reach it.
///
/// What can reach it is memory both sides can see. On a platform with
/// isolates that is a word allocated outside the Dart heap, whose address
/// crosses as an ordinary integer; the worker reads it between units of work
/// through [git.Cancellation]. In a browser there are no isolates and the
/// worker runs on the thread that drew the frame, so nothing can interrupt a
/// synchronous call there at all — the flag still works, and only takes
/// effect for requests that have not started.
library;

import 'package:git_dart/git_dart.dart' as git;

import 'cancel_flag_io.dart'
    if (dart.library.js_interop) 'cancel_flag_web.dart' as impl;

abstract interface class CancelFlag {
  /// What crosses to the worker: plain data, like everything else in the
  /// protocol. Zero means "nothing to watch".
  int get handle;

  /// Asks whatever is watching this flag to stop. Safe to call more than
  /// once, and after the request has already finished.
  void cancel();

  /// Releases the flag. After this the handle means nothing, so it must
  /// outlive every reader of it.
  void dispose();
}

/// A flag for one request.
CancelFlag newCancelFlag() => impl.newCancelFlag();

/// The reading end of a flag, in whichever isolate is doing the work.
///
/// A handle of zero is a request nobody will cancel, which is most of them,
/// and costs nothing to carry.
git.Cancellation? cancellationFor(int handle) =>
    handle == 0 ? null : impl.cancellationFor(handle);
