// Reusable per-owner asynchronous operation serialization. Errors do not poison
// subsequent operations; callers remain responsible for cancellation epochs.
class AsyncOperationQueue {
  Future<void> _tail=Future<void>.value();
  Future<T> run<T>(Future<T> Function() operation) {
    final result=_tail.then((_)=>operation());
    _tail=result.then<void>((_) {},onError:(Object _,StackTrace __) {});
    return result;
  }
}
