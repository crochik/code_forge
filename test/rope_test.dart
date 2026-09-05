/// Regression tests for the pure-Dart `RopeBridge`, pinned to the behaviour of
/// the Rust `ropey` implementation this replaces.
///
/// Expectations were captured from the Rust build rather than invented — see
/// `tool/rust_reference/`. The whole document half of that comparison (13,462
/// lines of output over eleven documents) matches byte for byte.
library;

import 'package:code_forge/src/core/rope.dart';
import 'package:flutter_test/flutter_test.dart';

BigInt big(int v) => BigInt.from(v);

RopeBridge rope(String text) => RopeBridge.create(initialText: text);

void main() {
  group('line counting follows ropey', () {
    test('an empty document still has one line', () {
      expect(rope('').lenLines(), BigInt.one);
      expect(rope('').lenChars(), BigInt.zero);
    });

    test('a trailing newline opens an empty final line', () {
      expect(rope('a\nb\nc\n').lenLines(), big(4));
      expect(rope('a\nb\nc').lenLines(), big(3));
    });

    test('line() strips the terminator, rawLine() keeps it', () {
      final r = rope('a\nb\n');
      expect(r.line(lineIdx: big(0)), 'a');
      expect(r.rawLine(0), 'a\n');
      expect(r.line(lineIdx: big(2)), '');
    });

    test('CRLF is stripped as a unit', () {
      final r = rope('line1\r\nline2\r\nline3');
      expect(r.line(lineIdx: big(0)), 'line1');
      expect(r.line(lineIdx: big(2)), 'line3');
      // findLineEnd stops before the \r, not between \r and \n
      expect(r.findLineEnd(offset: big(0)), big(5));
    });

    test('out-of-range line indices clamp to the last line', () {
      final r = rope('a\nb');
      expect(r.line(lineIdx: big(99)), 'b');
      expect(r.lineToChar(lineIdx: big(99)), big(2));
    });

    test('charToLine is defined at the very end of the document', () {
      expect(rope('a\n').charToLine(charIdx: big(2)), big(1));
      expect(rope('a').charToLine(charIdx: big(1)), big(0));
      expect(rope('a').charToLine(charIdx: big(999)), big(0));
    });

    test('findLineStart and findLineEnd bracket the line', () {
      final r = rope('abc\ndefgh\n');
      expect(r.findLineStart(offset: big(6)), big(4));
      expect(r.findLineEnd(offset: big(6)), big(9));
    });
  });

  group('editing', () {
    test('insert and remove', () {
      final r = rope('hello');
      r.insert(charIdx: big(5), text: ' world');
      expect(r.getText(), 'hello world');
      r.remove(start: big(0), end: big(6));
      expect(r.getText(), 'world');
    });

    test('out-of-range edits clamp instead of crashing', () {
      // ropey panics here, which crossed the FFI boundary as a process abort.
      final r = rope('abc');
      r.insert(charIdx: big(999), text: 'X');
      expect(r.getText(), 'abcX');
      r.remove(start: big(2), end: big(999));
      expect(r.getText(), 'ab');
      r.remove(start: big(5), end: big(1));
      expect(r.getText(), 'ab');
    });

    test('slice clamps and never inverts', () {
      final r = rope('abcdef');
      expect(r.slice(start: big(1), end: big(4)), 'bcd');
      expect(r.slice(start: big(4), end: big(1)), '');
      expect(r.slice(start: big(0), end: big(999)), 'abcdef');
    });

    test('charAt is empty past the end', () {
      final r = rope('ab');
      expect(r.charAt(position: big(1)), 'b');
      expect(r.charAt(position: big(2)), '');
    });

    test('copy is deep — editing the copy leaves the original alone', () {
      final r = rope('abc');
      final c = r.copy();
      c.insert(charIdx: big(0), text: 'Z');
      expect(r.getText(), 'abc');
      expect(c.getText(), 'Zabc');
    });

    test('getText is cached but invalidated by an edit', () {
      final r = rope('abc');
      expect(identical(r.getText(), r.getText()), isTrue);
      r.insert(charIdx: big(0), text: 'Z');
      expect(r.getText(), 'Zabc');
    });
  });

  group('selection', () {
    test('replaceRange moves the caret past the replacement', () {
      final r = rope('hello world');
      final s = r.replaceRangeAndUpdateSelection(
        start: big(0),
        end: big(5),
        replacement: 'goodbye',
        preserveOldCursor: false,
        oldBase: big(0),
        oldExtent: big(0),
      );
      expect(r.getText(), 'goodbye world');
      expect(s.baseOffset, big(7));
      expect(s.extentOffset, big(7));
    });

    test('preserveOldCursor maps offsets across the edit', () {
      final r = rope('0123456789');
      final s = r.replaceRangeAndUpdateSelection(
        start: big(2),
        end: big(5),
        replacement: 'X',
        preserveOldCursor: true,
        oldBase: big(1), // before the edit: unmoved
        oldExtent: big(8), // after the edit: shifted by the length delta
      );
      expect(r.getText(), '01X56789');
      expect(s.baseOffset, big(1));
      expect(s.extentOffset, big(6));
    });

    test('setSelection clamps into the document', () {
      final r = rope('abc');
      r.setSelection(baseOffset: big(99), extentOffset: big(2));
      expect(r.selection().baseOffset, big(3));
      expect(r.selection().extentOffset, big(2));
    });
  });

  group('bidi', () {
    test('a short or plainly-ASCII run is one LTR segment', () {
      final r = rope('const x = 1;');
      final segs = r.getBidiSegmentsInRange(start: big(0), end: r.lenChars());
      expect(segs.length, 1);
      expect(segs.single.direction, TextDirection.ltr);
    });

    test('direction detection', () {
      expect(rope('hello there everyone').textDirection(), TextDirection.ltr);
      expect(
        rope('שלום שלום שלום שלום שלום שלום שלום').textDirection(),
        TextDirection.rtl,
      );
      expect(
        rope('shalom שלום world السلام done here now').textDirection(),
        TextDirection.mixed,
      );
    });

    test('primaryDirection takes the majority, not the presence', () {
      expect(
        rope('shalom שלום world السلام done here now').primaryDirection(),
        TextDirection.ltr,
      );
    });

    test('digits, spaces and punctuation stay neutral', () {
      // If they were classified as LTR, RTL text with spaces would read as
      // mixed. This is the property the block-level table has to preserve.
      final r = rope('שלום 123 שלום, שלום; שלום שלום שלום שלום');
      expect(r.textDirection(), TextDirection.rtl);
    });
  });

  group('UTF-16 indexing (a documented difference from the Rust)', () {
    // ropey indexed by code point, so an emoji counted as 1. Everything that
    // consumes these offsets — Dart strings, Flutter's TextSelection — counts
    // it as 2, so the Rust disagreed with its own callers. Here they agree.
    test('an astral character counts as two units, matching Dart', () {
      const emoji = '\u{1F600}'; // one code point, two UTF-16 units
      final r = rope('a${emoji}b');
      expect(r.lenChars(), big(4));
      expect(r.getText().length, 4);
      expect(r.slice(start: big(3), end: big(4)), 'b');
    });

    test('BMP text is identical under either scheme', () {
      final r = rope('café naïve こんにちは 中文');
      expect(r.lenChars().toInt(), r.getText().length);
      expect(r.getText().runes.length, r.getText().length);
    });
  });
}
