/// Regression tests for the document scans — folds, bracket matching, indent
/// guides, word extraction and the unwrapped viewport helpers.
///
/// As with the other suites, expectations come from the Rust build rather than
/// from judgement. See `tool/rust_reference/`.
library;

import 'package:code_forge/src/core/editor.dart';
import 'package:code_forge/src/core/rope.dart';
import 'package:flutter_test/flutter_test.dart';

BigInt big(int v) => BigInt.from(v);

RopeBridge rope(String text) => RopeBridge.create(initialText: text);

const _source = 'function f(a) {\n'
    '  if (a) {\n'
    '    return [1, 2,\n'
    '      3];\n'
    '  }\n'
    '\treturn {\n'
    '\t\tk: 1\n'
    '\t};\n'
    '}\n';

void main() {
  group('folds', () {
    test('a multi-line bracket pair becomes a fold', () async {
      final folds = await foldsComputeAll(rope: rope(_source));
      expect(
        folds.map((f) => '${f.startLine}-${f.endLine}').toList(),
        ['2-3', '1-4', '5-7', '0-8'],
        reason: 'innermost pairs close first',
      );
    });

    test('a pair opening and closing on one line is not a fold', () async {
      expect(await foldsComputeAll(rope: rope('f(a);\n')), isEmpty);
    });

    test('unbalanced brackets do not throw', () async {
      expect(await foldsComputeAll(rope: rope('}}}\n{{{\n')), isEmpty);
    });
  });

  group('matching brackets', () {
    test('forwards and backwards', () {
      final r = rope('a(b[c]d)e');
      expect(foldsFindMatchingBracket(rope: r, targetOffset: 1), 7);
      expect(foldsFindMatchingBracket(rope: r, targetOffset: 7), 1);
      expect(foldsFindMatchingBracket(rope: r, targetOffset: 3), 5);
      expect(foldsFindMatchingBracket(rope: r, targetOffset: 5), 3);
    });

    test('-1 when there is nothing to match', () {
      final r = rope('a(b');
      expect(foldsFindMatchingBracket(rope: r, targetOffset: 0), -1,
          reason: 'not a bracket');
      expect(foldsFindMatchingBracket(rope: r, targetOffset: 1), -1,
          reason: 'unclosed');
      expect(foldsFindMatchingBracket(rope: r, targetOffset: 99), -1);
      expect(foldsFindMatchingBracket(rope: r, targetOffset: -1), -1);
    });
  });

  group('indent guides', () {
    List<String> guides(String text, {int tab = 2, int? last}) =>
        guidesComputeViewport(
          rope: rope(text),
          firstVisible: BigInt.zero,
          lastVisible: big(last ?? 999),
          tabSize: big(tab),
        )
            .map((b) =>
                '${b.startLine}-${b.endLine}:${b.indentLevel}:${b.leadingSpaces}')
            .toList();

    test('a brace block produces a guide spanning to its match', () {
      expect(guides(_source), ['0-9:0:0', '1-5:1:2', '5-8:1:2']);
    });

    test('a line ending in a colon opens a guide', () {
      expect(guides('obj:\n  a: 1\n  b: 2\ntop: 3\n'), ['0-3:0:0']);
    });

    test('an HTML opening tag opens a guide, a self-closing one does not', () {
      expect(
        guides('<div>\n  <span>\n    hi\n  </span>\n</div>\n<br/>\n'),
        ['0-5:0:0', '1-4:1:2'],
      );
    });

    test('tabs advance to the next tab stop', () {
      // Line 5 of `_source` is "\treturn {" — one tab of indentation. Its
      // reported column follows the tab size, and the indent level with it.
      expect(guides(_source, tab: 2)[2], '5-8:1:2');
      expect(guides(_source, tab: 4)[2], '5-8:1:4');
      expect(guides(_source, tab: 8)[2], '5-8:1:8');
      // Space-indented lines are unaffected by the tab size.
      expect(guides(_source, tab: 4)[1], '1-5:0:2');
    });

    test('an empty document produces nothing', () {
      expect(guides(''), isEmpty);
    });
  });

  group('word extraction', () {
    test('splits on non-word characters and dedupes', () async {
      final words = await wordsExtract(rope: rope('a_b c1 a_b, d-e'));
      expect(words..sort(), ['a_b', 'c1', 'd', 'e']);
    });

    test('caps at 5000 distinct words', () async {
      final text = List.generate(6000, (i) => 'w$i').join(' ');
      expect((await wordsExtract(rope: rope(text))).length, 5000);
    });

    test('an empty document yields nothing', () async {
      expect(await wordsExtract(rope: rope('')), isEmpty);
    });
  });

  group('unwrapped viewport helpers', () {
    test('clamps to the document and handles a zero line height', () {
      final v = visibleLineRangeUnwrapped(
          totalLines: 10, viewTop: 0, viewBottom: 0, lineHeight: 0);
      expect([v.firstLine, v.lastLine, v.firstLineY], [0, 0, 0.0]);

      final past = visibleLineRangeUnwrapped(
          totalLines: 10, viewTop: 1000, viewBottom: 2000, lineHeight: 18);
      expect([past.firstLine, past.lastLine], [9, 9]);

      final before = visibleLineRangeUnwrapped(
          totalLines: 10, viewTop: -10, viewBottom: 5, lineHeight: 18);
      expect([before.firstLine, before.lastLine], [0, 1]);
    });

    test('no lines means an empty range', () {
      final v = visibleLineRangeUnwrapped(
          totalLines: 0, viewTop: 0, viewBottom: 100, lineHeight: 18);
      expect([v.firstLine, v.lastLine, v.firstLineY], [0, 0, 0.0]);
    });

    test('the rope-driven frame reports raw line lengths, newline included', () {
      final f = buildViewportFrame(
          rope: rope('ab\ncdef\n'), viewTop: 0, viewBottom: 100, lineHeight: 20);
      expect(f.lines.map((l) => l.lenChars.toInt()).toList(), [3, 5, 0]);
    });
  });
}
