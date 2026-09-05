/// Regression tests for `LayoutMap`, pinned to the behaviour of the Rust
/// `zed-sum-tree` implementation this replaces.
///
/// Every expectation here was captured by running the same operations against
/// the Rust build (`tool/rust_reference/`) and recording what it returned — not
/// by deciding what looked correct. Where the two disagree, the Rust wins,
/// because the widget layer was written against it.
library;

import 'package:code_forge/src/core/editor.dart';
import 'package:flutter_test/flutter_test.dart';

BigInt big(int v) => BigInt.from(v);

/// The block list, read back through a viewport that covers everything.
List<int> dump(LayoutMap lm) => lm
    .buildViewportFrame(viewTop: 0, viewBottom: 1e9, fallbackLineHeight: 17)
    .lines
    .map((l) => l.lenChars.toInt())
    .toList();

LayoutMap fresh(int n) {
  final lm = LayoutMap();
  for (var i = 0; i < n; i++) {
    lm.pushLine(lenChars: big(i), height: 10, isFolded: false);
  }
  return lm;
}

void main() {
  group('the Bias::Left off-by-one', () {
    // These are the exact outputs of the Rust build. `insertLine(0)` and
    // `insertLine(1)` both insert at the front; the operation lands at
    // `max(lineIdx - 1, 0)`. Reproduced deliberately — see `_biasLeftIndex`.
    test('insertLine lands one line earlier than its argument', () {
      const expected = {
        0: [99, 0, 1, 2, 3, 4],
        1: [99, 0, 1, 2, 3, 4],
        2: [0, 99, 1, 2, 3, 4],
        3: [0, 1, 99, 2, 3, 4],
        4: [0, 1, 2, 99, 3, 4],
        5: [0, 1, 2, 3, 4, 99], // out of range: appends
        6: [0, 1, 2, 3, 4, 99],
      };
      expected.forEach((k, want) {
        final lm = fresh(5)
          ..insertLine(
              lineIdx: big(k), lenChars: big(99), height: 10, isFolded: false);
        expect(dump(lm), want, reason: 'insertLine($k)');
      });
    });

    test('removeLine removes one line earlier than its argument', () {
      const expected = {
        0: [1, 2, 3, 4],
        1: [1, 2, 3, 4],
        2: [0, 2, 3, 4],
        3: [0, 1, 3, 4],
        4: [0, 1, 2, 4],
        5: [0, 1, 2, 3, 4], // out of range: no-op
        6: [0, 1, 2, 3, 4],
      };
      expected.forEach((k, want) {
        final lm = fresh(5)..removeLine(lineIdx: big(k));
        expect(dump(lm), want, reason: 'removeLine($k)');
      });
    });

    test('updateLine updates one line earlier than its argument', () {
      const expected = {
        0: [77, 1, 2, 3, 4],
        1: [77, 1, 2, 3, 4],
        2: [0, 77, 2, 3, 4],
        3: [0, 1, 77, 3, 4],
        4: [0, 1, 2, 77, 4],
        5: [0, 1, 2, 3, 4],
        6: [0, 1, 2, 3, 4],
      };
      expected.forEach((k, want) {
        final lm = fresh(5)
          ..updateLine(
              lineIdx: big(k), lenChars: big(77), height: 10, isFolded: false);
        expect(dump(lm), want, reason: 'updateLine($k)');
      });
    });
  });

  group('seek', () {
    test('char offset resolves to a line, inclusive at the boundary', () {
      // Blocks hold 0,1,2,3,4 chars, so the prefix sums are 0,0,1,3,6,10.
      final lm = fresh(5);
      const expected = [0, 1, 2, 2, 3, 3, 3, 4, 4, 4, 4, 5, 5];
      for (var co = 0; co < expected.length; co++) {
        expect(lm.visualLineFromCharOffset(charOffset: big(co)), expected[co],
            reason: 'offset $co');
      }
    });

    test('height range is inclusive at the top edge, exclusive at the bottom',
        () {
      final lm = fresh(5); // five lines of 10px
      void check(double t, int first, int last, double y) {
        final v = lm.visibleRangeByHeight(viewTop: t, viewBottom: t);
        expect([v.firstLine, v.lastLine, v.firstLineY], [first, last, y],
            reason: 'at $t');
      }

      check(0, 0, 0, 0);
      check(5, 0, 0, 0);
      check(10, 0, 1, 0); // the line ending at 10 is still "first"
      check(15, 1, 1, 10);
      check(20, 1, 2, 10);
      check(49, 4, 4, 40);
      check(50, 4, 4, 40); // clamped to the last line
      check(51, 5, 5, 50); // past the end: first is not clamped
    });

    test('folded lines occupy no height, and the two biases diverge there', () {
      final lm = LayoutMap()
        ..pushLine(lenChars: big(0), height: 10, isFolded: false)
        ..pushLine(lenChars: big(1), height: 10, isFolded: true)
        ..pushLine(lenChars: big(2), height: 10, isFolded: true)
        ..pushLine(lenChars: big(3), height: 10, isFolded: false);

      expect(lm.totalHeight(), 20, reason: 'folded lines contribute 0');
      expect(dump(lm), [0, 1, 2, 3], reason: 'but they are still lines');

      // At exactly 10px, the left bias stops before the zero-height run and the
      // right bias runs past it — which is the whole reason both exist.
      final at10 = lm.visibleRangeByHeight(viewTop: 10, viewBottom: 10);
      expect([at10.firstLine, at10.lastLine, at10.firstLineY], [0, 3, 0.0]);

      final at15 = lm.visibleRangeByHeight(viewTop: 15, viewBottom: 15);
      expect([at15.firstLine, at15.lastLine, at15.firstLineY], [3, 3, 10.0]);
    });
  });

  test('an empty map answers without blowing up', () {
    final lm = LayoutMap();
    expect(lm.lenLines(), BigInt.zero);
    expect(lm.totalHeight(), 0);
    expect(lm.visualLineFromCharOffset(charOffset: big(99)), 0);
    final v = lm.visibleRangeByHeight(viewTop: 0, viewBottom: 100);
    expect([v.firstLine, v.lastLine, v.firstLineY], [0, 0, 0.0]);
    final f = lm.buildViewportFrame(
        viewTop: 0, viewBottom: 100, fallbackLineHeight: 17);
    expect(f.lines, isEmpty);
  });

  test('clear empties the map', () {
    final lm = fresh(5)..clear();
    expect(lm.lenLines(), BigInt.zero);
    expect(lm.totalHeight(), 0);
  });

  test('a zero or negative height falls back to the supplied line height', () {
    final lm = LayoutMap()
      ..pushLine(lenChars: big(4), height: 0, isFolded: false)
      ..pushLine(lenChars: big(5), height: 12, isFolded: false);
    final f = lm.buildViewportFrame(
        viewTop: 0, viewBottom: 1000, fallbackLineHeight: 17);
    expect(f.lines.map((l) => l.height).toList(), [17.0, 12.0]);
  });
}
