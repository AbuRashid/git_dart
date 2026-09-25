/// The worker in an isolate, where there are isolates.
///
/// One worker rather than an isolate per call: spawning one each time would
/// reopen the repository, which on a large one means reading every pack index
/// again and is most of the cost of the work.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:git_dart/git_dart.dart' as git;

import 'cancel_flag.dart';
import 'git_worker.dart';
import 'worker_transport.dart';

WorkerTransport newWorkerTransport() => IsolateWorkerTransport();

/// The isolate's entry point.
///
/// Top-level because `Isolate.spawn` takes a function it can name, not a
/// closure over anything on this side. Takes the root isolate token alongside
/// the port because a plain background isolate has no platform channel of its
/// own at all — [BackgroundIsolateBinaryMessenger] is what lets one reach the
/// native side, and it has to be handed the main isolate's token to do it,
/// which is why this is captured on that side before the spawn rather than
/// asked for here (`Isolate.spawn` runs before there is a "here" to ask from).
/// Needed for the saved-credentials vault's platform channel; nothing else
/// this worker does touches one.
void gitWorkerMain((SendPort, RootIsolateToken) args) {
  final (toMain, rootIsolateToken) = args;
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);

  final worker = GitWorker();

  inbox.listen((message) async {
    if (message is! WorkerEnvelope) return;
    try {
      // Most handlers are synchronous; a fetch is not, and waits on a network
      // that may never answer. Progress is sent as extra messages on the same
      // port, ahead of the reply - there is nothing else here that ties a
      // message back to the request it belongs to.
      final result = worker.handle(
        message.request,
        onProgress: (text) => toMain.send(WorkerProgress(message.id, text)),
        cancel: cancellationFor(message.cancelHandle),
      );
      final value = result is Future ? await result : result;
      toMain.send(WorkerReply(message.id, value, null));
    } on git.CancelledException {
      // Abandoned, which the other side asked for: an outcome, not a fault.
      toMain.send(WorkerReply(message.id, null, null, cancelled: true));
    } catch (error) {
      // A failure is a reply, not a crash.
      toMain.send(WorkerReply(message.id, null, error.toString()));
    }
  });
}

class IsolateWorkerTransport implements WorkerTransport {
  final _pending = <int, Completer<Object?>>{};

  /// Registered only for a request whose caller asked for progress, and
  /// removed once the reply for that id arrives - a progress message for a
  /// request nobody is listening to is simply dropped.
  final _progress = <int, void Function(String)>{};
  var _nextId = 0;

  late final SendPort _toWorker;
  Isolate? _isolate;
  ReceivePort? _inbox;

  @override
  Future<void> start() async {
    final ready = Completer<SendPort>();
    _inbox = ReceivePort();
    _inbox!.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      if (message is WorkerProgress) {
        _progress[message.id]?.call(message.message);
        return;
      }
      if (message is! WorkerReply) return;
      final completer = _pending.remove(message.id);
      _progress.remove(message.id);
      if (completer == null) return;
      if (message.cancelled) {
        completer.completeError(const RequestCancelled());
        return;
      }
      if (message.error != null) {
        completer.completeError(GitWorkerException(message.error!));
      } else {
        completer.complete(message.value);
      }
    });

    // Null off the main isolate only if the services binding was never
    // initialised, which `main()` always does before this runs.
    final rootIsolateToken = ServicesBinding.rootIsolateToken;
    if (rootIsolateToken == null) {
      throw StateError('no root isolate token; is the Flutter binding started?');
    }
    _isolate = await Isolate.spawn(
      gitWorkerMain,
      (_inbox!.sendPort, rootIsolateToken),
    );
    _toWorker = await ready.future;
  }

  @override
  Future<Object?> send(
    GitRequest request, {
    void Function(String)? onProgress,
    int cancelHandle = 0,
  }) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    if (onProgress != null) _progress[id] = onProgress;
    _toWorker.send(WorkerEnvelope(id, request, cancelHandle: cancelHandle));
    return completer.future;
  }

  @override
  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _inbox?.close();
  }
}
