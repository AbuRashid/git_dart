/// The flag as a word outside the Dart heap, where there are isolates.
///
/// Dart isolates share no mutable memory, which is the property that makes
/// them safe and the one that stops a cancellation from reaching a worker
/// that is busy. Memory allocated through `dart:ffi` is outside that rule:
/// its address is just a number, both isolates can hold it, and a write on
/// one side is visible to a read on the other.
///
/// One `Int32` per in-flight cancellable request, freed when the request
/// finishes.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:git_dart/git_dart.dart' as git;

import 'cancel_flag.dart';

CancelFlag newCancelFlag() => _NativeCancelFlag();

git.Cancellation cancellationFor(int handle) => _NativeCancellation(handle);

class _NativeCancelFlag implements CancelFlag {
  Pointer<Int32>? _word = calloc<Int32>();

  @override
  int get handle => _word?.address ?? 0;

  @override
  void cancel() => _word?.value = 1;

  @override
  void dispose() {
    final word = _word;
    _word = null;
    if (word != null) calloc.free(word);
  }
}

class _NativeCancellation implements git.Cancellation {
  final Pointer<Int32> _word;

  _NativeCancellation(int handle) : _word = Pointer<Int32>.fromAddress(handle);

  @override
  bool get isCancelled => _word.value != 0;
}
