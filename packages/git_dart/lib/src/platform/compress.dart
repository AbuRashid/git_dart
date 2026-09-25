/// Compression, on whichever platform this is running.
///
/// Every git object is stored zlib-deflated, so this sits under the object
/// store, the pack reader and the pack writer — which is to say under
/// everything. `dart:io` has a fast native zlib and a browser does not have
/// `dart:io` at all: importing it compiles and the first call throws
/// `Unsupported operation: _newZLibDeflateFilter`, which is a long way from
/// where the mistake was made.
///
/// The split is the same one [GitFs] makes, for the same reason: the native
/// path keeps the fast implementation, and the web path gets a pure-Dart one
/// that is slower and works. Neither caller has to know which it got.
library;

import 'dart:typed_data';

import 'compress_io.dart' if (dart.library.js_interop) 'compress_web.dart'
    as impl;

/// Compresses [bytes] into a zlib stream — the two header bytes, the deflated
/// data, then an Adler-32 of the input.
///
/// That framing is not decoration: a git object is stored exactly this way,
/// and a reader that is handed raw deflate instead fails on the first byte.
Uint8List deflate(List<int> bytes) => impl.deflate(bytes);

/// Expands a zlib stream produced by [deflate], or by git.
Uint8List inflate(List<int> bytes) => impl.inflate(bytes);

/// Inflates a zlib stream whose length is not recorded, stopping once
/// [expectedSize] bytes have come out.
///
/// This is how a packed object is read. A pack stores where a compressed
/// stream *begins* and never where it ends, so the only stopping condition is
/// the uncompressed size in the object's own header — which means the reader
/// has to be able to stop mid-buffer rather than being handed an exact slice.
///
/// [bytes] may therefore run past the end of the stream, and anything after it
/// is ignored rather than being an error.
Uint8List inflateExactly(List<int> bytes, int expectedSize) =>
    impl.inflateExactly(bytes, expectedSize);

/// Inflates at most [limit] bytes of a zlib stream, stopping there and
/// ignoring whatever follows.
///
/// Unlike [inflateExactly] this does not know, and does not ask, how long the
/// stream is: a stream that ends sooner returns what there was. It is how an
/// object's header is read without inflating the object — the difference
/// between learning that a blob is two hundred megabytes and allocating two
/// hundred megabytes to find out.
Uint8List inflateAtMost(List<int> bytes, int limit) =>
    impl.inflateAtMost(bytes, limit);
