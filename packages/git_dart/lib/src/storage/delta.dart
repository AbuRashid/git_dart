/// Builds the delta instruction stream that turns one object into another.
///
/// A packfile may store an object as the difference from another rather than
/// whole. The difference is not a text diff: it is a short program in two
/// instructions — copy a run of bytes from the base, or insert a run of
/// literal bytes — and applying it is running that program. Nothing about it
/// knows or cares what the bytes mean, which is why it works on any object
/// kind and why a delta between two versions of a compiled binary is as valid
/// as one between two versions of a source file.
///
/// The decoders in this library already read this format. This is the other
/// half: without it every pack we write stores whole objects, which is legal,
/// correct, and several times larger than what git would send.
library;

import 'dart:typed_data';

/// The size of the block that is hashed to find matches.
///
/// Sixteen is git's own choice. Smaller finds more matches and costs more to
/// look for; larger misses short runs. It also sets the floor on what can be
/// found at all: a run shorter than this is never the *start* of a match,
/// though it may be picked up by extending one.
const int _blockSize = 16;

/// The shortest copy worth emitting.
///
/// A copy instruction costs between two and eight bytes, so copying three
/// bytes makes the delta longer than inserting them. Below this the literal
/// wins.
const int _minimumCopy = 4;

/// The most a single copy instruction can move: the size field is three bytes.
const int _maximumCopy = 0xffffff;

/// The most a single insert instruction can carry: the length is seven bits.
const int _maximumInsert = 0x7f;

/// An index of [base], so matches in it can be found without scanning.
///
/// Built once and reused for every target compared against the same base,
/// because the sliding window compares one base against many targets and
/// rebuilding this each time is most of the cost of packing.
class DeltaIndex {
  final Uint8List base;

  /// Hash of a block to the offsets in [base] where that block starts.
  ///
  /// Only every sixteenth position is indexed, which is a sixteenth of the
  /// memory and finds the same matches: a match that begins between two
  /// indexed positions is found at the next one and then extended backwards.
  final Map<int, List<int>> _blocks = {};

  /// How many places one hash may name.
  ///
  /// Content that repeats — a file of zeros, a table of identical rows — puts
  /// every block in one bucket, and checking them all turns the scan
  /// quadratic. Past a handful the extra candidates almost never beat the
  /// first, so the bucket stops growing rather than the search stops being
  /// affordable.
  static const int _maximumCandidates = 8;

  DeltaIndex(this.base) {
    for (var at = 0; at + _blockSize <= base.length; at += _blockSize) {
      var hash = 0;
      for (var i = 0; i < _blockSize; i++) {
        hash = _mix(hash, base[at + i]);
      }
      final bucket = _blocks[hash] ??= <int>[];
      if (bucket.length < _maximumCandidates) bucket.add(at);
    }
  }

  /// A polynomial hash: multiply by a prime, add the byte.
  ///
  /// It has to be this shape rather than something stronger like FNV, because
  /// the scan rolls the window forward a byte at a time and only a polynomial
  /// lets the oldest byte be taken out again by subtracting its contribution.
  /// A hash with an xor in it cannot be undone that way, and recomputing the
  /// whole window at every position costs sixteen times as much for the same
  /// answer.
  static int _mix(int hash, int byte) =>
      ((hash * 0x01000193) + byte) & 0xffffffff;

  /// The multiplier's value at the far end of the window, for rolling a byte
  /// out of the hash. Derived once rather than recomputed per position.
  static final int _rollOut = () {
    var power = 1;
    for (var i = 0; i < _blockSize - 1; i++) {
      power = (power * 0x01000193) & 0xffffffff;
    }
    return power;
  }();

  bool get isEmpty => _blocks.isEmpty;
}

/// The delta that turns [index]'s base into [target], or null when it would be
/// no smaller than storing [target] whole.
///
/// [limit] stops the search early: the caller is looking for the *best* base
/// among several and has no use for a delta already larger than one it has.
/// Giving up early is most of what makes trying a whole window affordable.
Uint8List? encodeDelta(
  DeltaIndex index,
  Uint8List target, {
  int? limit,
}) {
  final base = index.base;
  final out = BytesBuilder(copy: false);

  // The header: how big each side is. The reader checks the first against the
  // base it found and refuses if they disagree, which is what stops a delta
  // being applied to the wrong object.
  _writeVarint(out, base.length);
  _writeVarint(out, target.length);

  final literal = BytesBuilder(copy: false);
  var at = 0;
  var hash = 0;
  var hashedFrom = -1;

  void flushLiteral() {
    if (literal.isEmpty) return;
    final bytes = literal.takeBytes();
    var written = 0;
    while (written < bytes.length) {
      final run = bytes.length - written < _maximumInsert
          ? bytes.length - written
          : _maximumInsert;
      out.addByte(run);
      out.add(Uint8List.sublistView(bytes, written, written + run));
      written += run;
    }
  }

  while (at < target.length) {
    if (limit != null && out.length + literal.length >= limit) return null;

    if (at + _blockSize > target.length) {
      literal.addByte(target[at]);
      at += 1;
      continue;
    }

    // The window hash, rolled forward one byte where possible rather than
    // recomputed: the scan visits every position, so recomputing sixteen
    // bytes at each of them is sixteen times the work for the same answer.
    if (hashedFrom == at - 1 && hashedFrom >= 0) {
      hash = _rollForward(hash, target[at - 1], target[at + _blockSize - 1]);
    } else {
      hash = 0;
      for (var i = 0; i < _blockSize; i++) {
        hash = DeltaIndex._mix(hash, target[at + i]);
      }
    }
    hashedFrom = at;

    final candidates = index._blocks[hash];
    var bestOffset = -1;
    var bestLength = 0;

    if (candidates != null) {
      for (final candidate in candidates) {
        // The hash agreeing is not the bytes agreeing.
        var length = 0;
        while (length < _maximumCopy &&
            candidate + length < base.length &&
            at + length < target.length &&
            base[candidate + length] == target[at + length]) {
          length += 1;
        }
        if (length > bestLength) {
          bestLength = length;
          bestOffset = candidate;
        }
        // Long enough that a better match would not repay the search.
        if (bestLength >= _maximumCopy) break;
      }
    }

    if (bestLength < _minimumCopy) {
      literal.addByte(target[at]);
      at += 1;
      continue;
    }

    // Reach backwards into what was about to be written as literal: the match
    // may have started before the indexed block that found it.
    var offset = bestOffset;
    var length = bestLength;
    var pending = literal.length;
    while (pending > 0 &&
        offset > 0 &&
        length < _maximumCopy &&
        base[offset - 1] == target[at - 1]) {
      offset -= 1;
      at -= 1;
      length += 1;
      pending -= 1;
    }
    if (pending != literal.length) {
      // Some of the pending literal is now covered by the copy, so it is
      // rewritten rather than trimmed in place.
      final bytes = literal.takeBytes();
      literal.add(Uint8List.sublistView(bytes, 0, pending));
    }

    flushLiteral();
    _writeCopy(out, offset, length);
    at += length;
    hashedFrom = -1;
  }

  flushLiteral();
  final delta = out.takeBytes();

  // A delta that is not smaller than the object is not worth the indirection,
  // the extra inflate, or the chain it adds to.
  if (delta.length >= target.length) return null;
  if (limit != null && delta.length >= limit) return null;
  return delta;
}

int _rollForward(int hash, int leaving, int arriving) {
  // The oldest byte has been multiplied by the prime once per position it has
  // travelled, so removing it means subtracting it scaled by the prime raised
  // to the width of the window. What is left is the same polynomial one place
  // short, which the mix then completes.
  final without =
      (hash - (leaving * DeltaIndex._rollOut)) & 0xffffffff;
  return DeltaIndex._mix(without, arriving);
}

void _writeVarint(BytesBuilder out, int value) {
  var rest = value;
  while (true) {
    final byte = rest & 0x7f;
    rest >>= 7;
    if (rest == 0) {
      out.addByte(byte);
      return;
    }
    out.addByte(byte | 0x80);
  }
}

/// A copy instruction: the high bit, then a bitmap saying which offset and
/// size bytes follow.
///
/// Only the non-zero bytes are written, so copying from near the start of a
/// small base costs two bytes rather than eight. That per-instruction thrift
/// is why the format is worth its complexity.
void _writeCopy(BytesBuilder out, int offset, int size) {
  var remaining = size;
  var from = offset;

  while (remaining > 0) {
    final run = remaining > _maximumCopy ? _maximumCopy : remaining;

    var command = 0x80;
    final bytes = <int>[];

    if (from & 0xff != 0) {
      command |= 0x01;
      bytes.add(from & 0xff);
    }
    if ((from >> 8) & 0xff != 0) {
      command |= 0x02;
      bytes.add((from >> 8) & 0xff);
    }
    if ((from >> 16) & 0xff != 0) {
      command |= 0x04;
      bytes.add((from >> 16) & 0xff);
    }
    if ((from >> 24) & 0xff != 0) {
      command |= 0x08;
      bytes.add((from >> 24) & 0xff);
    }

    if (run & 0xff != 0) {
      command |= 0x10;
      bytes.add(run & 0xff);
    }
    if ((run >> 8) & 0xff != 0) {
      command |= 0x20;
      bytes.add((run >> 8) & 0xff);
    }
    if ((run >> 16) & 0xff != 0) {
      command |= 0x40;
      bytes.add((run >> 16) & 0xff);
    }

    out.addByte(command);
    for (final byte in bytes) {
      out.addByte(byte);
    }

    from += run;
    remaining -= run;
  }
}

/// Applies a delta, for checking that what was written can be read back.
///
/// The pack readers each have their own copy of this because they apply deltas
/// while doing something else; this one exists so the encoder can be tested
/// against an implementation it does not share code with.
Uint8List applyDelta(Uint8List base, Uint8List delta) {
  var at = 0;

  int varint() {
    var value = 0;
    var shift = 0;
    int byte;
    do {
      byte = delta[at++];
      value |= (byte & 0x7f) << shift;
      shift += 7;
    } while (byte & 0x80 != 0);
    return value;
  }

  final sourceSize = varint();
  final targetSize = varint();
  if (sourceSize != base.length) {
    throw FormatException(
      'delta expects a base of $sourceSize bytes, base is ${base.length}',
    );
  }

  final out = Uint8List(targetSize);
  var written = 0;

  while (at < delta.length) {
    final instruction = delta[at++];
    if (instruction & 0x80 != 0) {
      var offset = 0;
      var size = 0;
      if (instruction & 0x01 != 0) offset |= delta[at++];
      if (instruction & 0x02 != 0) offset |= delta[at++] << 8;
      if (instruction & 0x04 != 0) offset |= delta[at++] << 16;
      if (instruction & 0x08 != 0) offset |= delta[at++] << 24;
      if (instruction & 0x10 != 0) size |= delta[at++];
      if (instruction & 0x20 != 0) size |= delta[at++] << 8;
      if (instruction & 0x40 != 0) size |= delta[at++] << 16;
      if (size == 0) size = 0x10000;

      out.setRange(written, written + size, base, offset);
      written += size;
    } else if (instruction != 0) {
      out.setRange(written, written + instruction, delta, at);
      at += instruction;
      written += instruction;
    } else {
      throw const FormatException('delta instruction 0 is reserved');
    }
  }

  if (written != targetSize) {
    throw FormatException(
      'delta produced $written bytes, its header promised $targetSize',
    );
  }
  return out;
}
