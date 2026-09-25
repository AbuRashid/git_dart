/// The flag as an ordinary object, for a browser.
///
/// There is one isolate, so the worker and the caller share a heap already
/// and a registry keyed by a number is enough. What the browser cannot do is
/// act on the flag during a synchronous call: the same thread is doing the
/// work, so it reaches the check only after it has finished. Cancelling still
/// stops requests that have not started, which is the common case when
/// someone clicks through a tree faster than it can answer.
library;

import 'package:git_dart/git_dart.dart' as git;

import 'cancel_flag.dart';

final _flags = <int, git.CancellationSource>{};
var _nextHandle = 1;

CancelFlag newCancelFlag() => _WebCancelFlag();

git.Cancellation? cancellationFor(int handle) => _flags[handle];

class _WebCancelFlag implements CancelFlag {
  @override
  final int handle = _nextHandle++;

  _WebCancelFlag() {
    _flags[handle] = git.CancellationSource();
  }

  @override
  void cancel() => _flags[handle]?.cancel();

  @override
  void dispose() => _flags.remove(handle);
}
