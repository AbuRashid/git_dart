/// The worker in place, for a browser.
///
/// Flutter Web has no `dart:isolate`, so there is nowhere else to put it: the
/// work happens on the thread that draws. That is a real cost and it is worth
/// being honest about — a slow operation on a large repository will show as a
/// stalled frame, where on the desktop it would not.
///
/// It is nonetheless the right shape for now. The alternative is a Web Worker
/// reached through JavaScript, which means serialising this protocol by hand
/// and giving up the type safety the isolate version gets for nothing. The seam
/// is here, so that swap stays possible without the app noticing.
library;

import 'dart:async';

import 'package:git_dart/git_dart.dart' as git;

import 'cancel_flag.dart';
import 'git_worker.dart';
import 'worker_transport.dart';

WorkerTransport newWorkerTransport() => InPlaceWorkerTransport();

class InPlaceWorkerTransport implements WorkerTransport {
  final GitWorker _worker = GitWorker();

  @override
  Future<void> start() async {}

  @override
  Future<Object?> send(
    GitRequest request, {
    void Function(String)? onProgress,
    int cancelHandle = 0,
  }) async {
    try {
      // Awaited whether or not it is a future, so a synchronous failure
      // arrives the same way an asynchronous one does. There is no
      // serialisation boundary here at all - the same thread is asking and
      // answering - so progress is just the same callback handed straight
      // through.
      final result = _worker.handle(
        request,
        onProgress: onProgress,
        cancel: cancellationFor(cancelHandle),
      );
      return result is Future ? await result : result;
    } on git.CancelledException {
      throw const RequestCancelled();
    } catch (error) {
      // The same contract as the isolate: a failure is a reply.
      throw GitWorkerException(error.toString());
    }
  }

  @override
  void dispose() {}
}
