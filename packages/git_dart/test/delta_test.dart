/// The delta encoder.
///
/// A delta is a short program: copy a run from the base, or insert literal
/// bytes. The only property that matters absolutely is that running it
/// reproduces the target exactly — a delta that is merely *close* corrupts an
/// object silently, and the corruption survives into every pack that copies
/// the entry onward. So most of this checks round trips, and the interesting
/// inputs are the ones that push the instruction encoding to its edges.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:git_dart/git_dart.dart';
import 'package:test/test.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Encode then apply, and insist on getting the target back.
void roundTrip(Uint8List base, Uint8List target, {String? because}) {
  final delta = encodeDelta(DeltaIndex(base), target);
  if (delta == null) return; // refused as not worth it, which is allowed
  expect(applyDelta(base, delta), target, reason: because);
}

void main() {
  group('round trips', () {
    test('a small edit in the middle', () {
      final base = bytes('the quick brown fox jumps over the lazy dog\n');
      final target = bytes('the quick brown cat jumps over the lazy dog\n');
      roundTrip(base, target);
    });

    test('an append', () {
      final base = bytes('one\ntwo\nthree\n' * 20);
      final target = bytes('${'one\ntwo\nthree\n' * 20}four\n');
      roundTrip(base, target);
    });

    test('a truncation', () {
      final base = bytes('one\ntwo\nthree\n' * 20);
      final target = bytes('one\ntwo\nthree\n' * 10);
      roundTrip(base, target);
    });

    test('a prepend, which shifts every offset', () {
      final base = bytes('body line\n' * 50);
      final target = bytes('header\n${'body line\n' * 50}');
      roundTrip(base, target);
    });

    test('wholly different content', () {
      roundTrip(bytes('a' * 500), bytes('b' * 500));
    });

    test('an empty base', () {
      roundTrip(Uint8List(0), bytes('anything at all\n' * 30));
    });

    test('an empty target', () {
      roundTrip(bytes('anything at all\n' * 30), Uint8List(0));
    });

    test('identical content', () {
      final same = bytes('unchanged\n' * 40);
      roundTrip(same, same);
    });

    test('content shorter than one block', () {
      roundTrip(bytes('abc'), bytes('abd'));
    });

    test('highly repetitive content', () {
      // Every block hashes the same, so this is where an unbounded candidate
      // list would turn the scan quadratic.
      final base = Uint8List(200000);
      final target = Uint8List(200000)..[199999] = 1;
      roundTrip(base, target);
    });

    test('binary content with NULs and high bytes', () {
      final random = Random(20260815);
      final base = Uint8List.fromList(
        List.generate(60000, (_) => random.nextInt(256)),
      );
      final target = Uint8List.fromList(base)
        ..setRange(1000, 1010, List.filled(10, 0))
        ..[59999] = 0xff;
      roundTrip(base, target);
    });

    test('a run longer than one copy instruction can carry', () {
      // Over 16MB, so the copy has to be split across instructions.
      final base = Uint8List(0x1000000 + 4096);
      for (var i = 0; i < base.length; i++) {
        base[i] = (i * 7) & 0xff;
      }
      final target = Uint8List.fromList(base)..[base.length - 1] = 0;
      roundTrip(base, target, because: 'a copy over 0xffffff must be split');
    });

    test('many small scattered edits', () {
      final random = Random(7);
      final base = Uint8List.fromList(
        List.generate(50000, (i) => (i * 13) & 0xff),
      );
      final target = Uint8List.fromList(base);
      for (var i = 0; i < 200; i++) {
        target[random.nextInt(target.length)] = random.nextInt(256);
      }
      roundTrip(base, target);
    });

    test('a fuzz of random pairs', () {
      final random = Random(4242);
      for (var round = 0; round < 200; round++) {
        final baseLength = random.nextInt(400);
        final base = Uint8List.fromList(
          List.generate(baseLength, (_) => random.nextInt(8)),
        );
        // Derived from the base as often as not, so real matches exist.
        final target = random.nextBool()
            ? Uint8List.fromList([
                ...base.take(random.nextInt(baseLength + 1)),
                ...List.generate(random.nextInt(80), (_) => random.nextInt(8)),
                ...base.skip(random.nextInt(baseLength + 1)),
              ])
            : Uint8List.fromList(
                List.generate(random.nextInt(400), (_) => random.nextInt(8)),
              );
        roundTrip(base, target, because: 'round $round');
      }
    });
  });

  group('the decision to delta at all', () {
    test('a delta that would not be smaller is refused', () {
      // Nothing in common, so every byte is a literal and the instructions
      // are pure overhead.
      final delta = encodeDelta(
        DeltaIndex(bytes('aaaa')),
        bytes('zzzz'),
      );
      expect(delta, isNull);
    });

    test('a limit gives up early', () {
      final base = bytes('shared prefix\n' * 100);
      final target = bytes('${'shared prefix\n' * 100}and more\n');

      final unlimited = encodeDelta(DeltaIndex(base), target);
      expect(unlimited, isNotNull);

      // Asking for something smaller than is achievable gets nothing rather
      // than a worse answer.
      expect(encodeDelta(DeltaIndex(base), target, limit: 4), isNull);
      // And a generous limit changes nothing.
      expect(
        encodeDelta(DeltaIndex(base), target, limit: 10000),
        unlimited,
      );
    });
  });

  group('how well it compresses', () {
    test('a one-line change in a large file is a small delta', () {
      final lines = List.generate(2000, (i) => 'line $i of the file\n').join();
      final base = bytes(lines);
      final target = bytes(lines.replaceFirst(
        'line 1000 of the file',
        'line 1000 of the file, edited',
      ));

      final delta = encodeDelta(DeltaIndex(base), target)!;
      // The whole point: the cost is the size of the change, not of the file.
      expect(delta.length, lessThan(200));
      expect(delta.length * 100, lessThan(target.length));
    });

    test('an append costs about the length of what was appended', () {
      final base = bytes('a settled line\n' * 3000);
      final target = bytes('${'a settled line\n' * 3000}one new line\n');

      final delta = encodeDelta(DeltaIndex(base), target)!;
      expect(delta.length, lessThan(100));
    });

    test('a shifted file still deltas well', () {
      // Everything moves, so a naive positional comparison finds nothing and
      // only real matching helps.
      final body = List.generate(1000, (i) => 'content line $i\n').join();
      final base = bytes(body);
      final target = bytes('a new first line\n$body');

      final delta = encodeDelta(DeltaIndex(base), target)!;
      expect(delta.length, lessThan(200));
    });
  });
}
