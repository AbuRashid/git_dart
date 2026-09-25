/// How the app reaches the git worker, which differs by platform.
///
/// Every git_dart call is synchronous and does real work — file reads and
/// inflates — so it must not run on the thread drawing the interface. On a
/// platform with isolates it runs in one. A browser has none to spawn:
/// `dart:isolate` does not exist for Flutter Web, so there the same worker runs
/// in place and the asynchrony is a promise rather than a thread.
///
/// The protocol is the same either way, because it was already plain data with
/// nothing holding a file handle crossing back (`concurrency.rule`). Only the
/// carrying differs, which is the whole reason this seam is worth having.
library;

import 'git_worker.dart';

import 'worker_transport_io.dart'
    if (dart.library.js_interop) 'worker_transport_web.dart' as impl;

abstract interface class WorkerTransport {
  /// Gets the worker ready. Nothing may be sent before this completes.
  Future<void> start();

  /// Asks the worker something and waits for its answer.
  ///
  /// A failure arrives as a [GitWorkerException] rather than as a crash: one
  /// bad repository must not take the worker down and every other
  /// repository's state with it.
  ///
  /// [onProgress] is called zero or more times before the answer, for a
  /// request that has something to say while it runs - a clone or a fetch
  /// waiting on a network. Most requests never call it at all, which is why
  /// this is a side channel rather than part of the reply: the reply is the
  /// answer, this is commentary while the answer is still being worked out.
  /// [cancelHandle] names a flag the worker watches while it works, from
  /// `newCancelFlag`. Zero means this request will not be cancelled.
  Future<Object?> send(
    GitRequest request, {
    void Function(String)? onProgress,
    int cancelHandle = 0,
  });

  void dispose();
}

/// The transport for this platform.
WorkerTransport newWorkerTransport() => impl.newWorkerTransport();
