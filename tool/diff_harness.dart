// Mirror of the Rust reference harness, run against the pure-Dart core.
// Output is byte-for-byte comparable with the Rust program's stdout.
import 'package:code_forge/src/core/editor.dart';
import 'package:code_forge/src/core/rope.dart';

/// Rust's `{:?}` for a string.
String dbg(String s) {
  final b = StringBuffer('"');
  for (final unit in s.codeUnits) {
    switch (unit) {
      case 0x5C:
        b.write(r'\\');
      case 0x22:
        b.write(r'\"');
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      default:
        b.writeCharCode(unit);
    }
  }
  return (b..write('"')).toString();
}

/// Rust's `{:?}` for a `Vec<String>`.
String dbgList(List<String> xs) => '[${xs.map(dbg).join(', ')}]';

/// Rust's `{}` for an f64 — integral values print without a fractional part.
String rf(double v) {
  if (v.isFinite && v == v.roundToDouble()) return v.toInt().toString();
  return v.toString();
}

String f4(double v) => v.toStringAsFixed(4);

String dirName(TextDirection d) => switch (d) {
      TextDirection.ltr => 'ltr',
      TextDirection.rtl => 'rtl',
      TextDirection.mixed => 'mixed',
    };

BigInt big(int v) => BigInt.from(v);

String segs(List<BiDiSegment> xs) =>
    xs.map((s) => '${s.start}-${s.end}:${dirName(s.direction)}').join(',');

final docs = <(String, String)>[
  ('empty', ''),
  ('no_eol', 'hello'),
  ('simple', 'a\nb\nc\n'),
  ('crlf', 'line1\r\nline2\r\nline3'),
  ('blanks', 'x\n\n\n  \ny\n'),
  (
    'source',
    'function f(a) {\n  if (a) {\n    return [1, 2,\n      3];\n  }\n\treturn {\n\t\tk: 1\n\t};\n}\n'
  ),
  ('tags', '<div>\n  <span>\n    hi\n  </span>\n</div>\n<br/>\n'),
  ('colon', 'obj:\n  a: 1\n  b: 2\ntop: 3\n'),
  (
    'rtl',
    'shalom שלום world السلام done here now'
  ),
  (
    'rtlonly',
    'שלום שלום שלום שלום שלום שלום שלום'
  ),
  (
    'unicode',
    'café naïve こんにちは 中文\nsecond λine\n'
  ),
];

Future<void> main() async {
  final out = StringBuffer();
  void p(String s) => out.writeln(s);

  for (final (name, text) in docs) {
    final r = RopeBridge.create(initialText: text);
    p('## doc $name');
    p('lenChars ${r.lenChars()}');
    p('lenLines ${r.lenLines()}');
    p('getText ${dbg(r.getText())}');
    p('primaryDirection ${dirName(r.primaryDirection())}');
    p('textDirection ${dirName(r.textDirection())}');

    final n = r.lenChars().toInt();
    for (var i = 0; i <= n; i++) {
      p('charToLine $i ${r.charToLine(charIdx: big(i))}');
      p('findLineStart $i ${r.findLineStart(offset: big(i))}');
      p('findLineEnd $i ${r.findLineEnd(offset: big(i))}');
      p('charAt $i ${dbg(r.charAt(position: big(i)))}');
    }
    final nl = r.lenLines().toInt();
    for (var l = 0; l < nl + 1; l++) {
      p('line $l ${dbg(r.line(lineIdx: big(l)))}');
      p('lineToChar $l ${r.lineToChar(lineIdx: big(l))}');
      p('bidiLine $l ${segs(r.getBidiSegmentsForLine(lineIndex: big(l)))}');
    }
    for (var a = 0; a <= n; a++) {
      for (var b = 0; b <= n; b++) {
        if ((a + b) % 3 == 0) {
          p('slice $a $b ${dbg(r.slice(start: big(a), end: big(b)))}');
        }
      }
    }
    p('cachedLines ${dbgList(r.cachedLines())}');
    for (var a = 0; a <= nl; a++) {
      for (var b = 0; b <= nl; b++) {
        p('cachedLinesRange $a $b '
            '${dbgList(r.cachedLinesRange(startLine: big(a), endLine: big(b)))}');
      }
    }
    for (var a = 0; a <= n; a++) {
      for (var b = 0; b <= n; b++) {
        if ((a * 7 + b) % 5 == 0) {
          p('bidiRange $a $b '
              '${segs(r.getBidiSegmentsInRange(start: big(a), end: big(b)))}');
        }
      }
    }

    final cap = n < 12 ? n : 12;
    for (var start = 0; start <= cap; start++) {
      for (var end = start; end <= cap; end++) {
        for (final (pres, repl) in [
          (true, ''),
          (false, ''),
          (true, 'XY'),
          (false, 'XY'),
          (true, '\n'),
        ]) {
          final c = r.copy();
          final s = c.replaceRangeAndUpdateSelection(
            start: big(start),
            end: big(end),
            replacement: repl,
            preserveOldCursor: pres,
            oldBase: big(n < 2 ? n : 2),
            oldExtent: big(n < 5 ? n : 5),
          );
          p('replace $start $end ${dbg(repl)} $pres -> '
              '${s.baseOffset} ${s.extentOffset} ${dbg(c.getText())}');
        }
      }
    }

    final folds = await foldsComputeAll(rope: r);
    p('folds ${folds.map((f) => '${f.startLine}-${f.endLine}').join(',')}');
    for (var i = 0; i < n; i++) {
      final m = foldsFindMatchingBracket(rope: r, targetOffset: i);
      if (m != -1) p('bracket $i $m');
    }
    final words = await wordsExtract(rope: r)..sort();
    p('words ${dbgList(words)}');
    for (final tab in [0, 2, 4, 8]) {
      for (var last = 0; last <= nl; last++) {
        final g = guidesComputeViewport(
          rope: r,
          firstVisible: BigInt.zero,
          lastVisible: big(last),
          tabSize: big(tab),
        );
        p('guides $tab $last ${g.map((b) => '${b.startLine}-${b.endLine}:'
            '${b.indentLevel}:${b.leadingSpaces}').join(',')}');
      }
    }
    for (final (vt, vb, lh) in [
      (0.0, 100.0, 20.0),
      (35.0, 90.0, 20.0),
      (0.0, 0.0, 0.0),
      (-10.0, 5.0, 18.0),
      (1000.0, 2000.0, 18.0),
    ]) {
      final v = visibleLineRangeUnwrapped(
          totalLines: nl, viewTop: vt, viewBottom: vb, lineHeight: lh);
      p('vlru ${rf(vt)} ${rf(vb)} ${rf(lh)} -> '
          '${v.firstLine} ${v.lastLine} ${f4(v.firstLineY)}');
      final f = buildViewportFrame(
          rope: r, viewTop: vt, viewBottom: vb, lineHeight: lh);
      p('bvf ${rf(vt)} ${rf(vb)} ${rf(lh)} -> '
          '${f.firstLine} ${f.lastLine} ${f4(f.firstLineY)} '
          '[${f.lines.map((l) => '${l.lenChars}:${f4(l.height)}').join(',')}]');
    }
  }

  // LayoutMap: the same deterministic op script as the Rust harness.
  p('## layoutmap');
  final lm = LayoutMap();
  var seed = 12345;
  int next(int m) {
    seed = seed * 6364136223846793005 + 1442695040888963407;
    return (seed >>> 33) % (m < 1 ? 1 : m);
  }

  for (var step = 0; step < 300; step++) {
    final op = next(10);
    final idx = next(40);
    final len = next(80);
    final h = next(30) + 0.5;
    final folded = next(4) == 0;
    if (op <= 4) {
      lm.pushLine(lenChars: big(len), height: h, isFolded: folded);
    } else if (op <= 6) {
      lm.insertLine(
          lineIdx: big(idx), lenChars: big(len), height: h, isFolded: folded);
    } else if (op == 7) {
      lm.removeLine(lineIdx: big(idx));
    } else if (op == 8) {
      lm.updateLine(
          lineIdx: big(idx), lenChars: big(len), height: h, isFolded: folded);
    }
    if (step % 10 == 0) {
      p('lm $step lines ${lm.lenLines()} height ${f4(lm.totalHeight())}');
      for (final co in [0, 1, 17, 100, 999, 100000]) {
        p('lm $step vlfco $co ${lm.visualLineFromCharOffset(charOffset: big(co))}');
      }
      for (final (vt, vb) in [
        (0.0, 50.0),
        (10.0, 10.0),
        (100.0, 300.0),
        (-5.0, 3.0),
        (99999.0, 100000.0),
      ]) {
        final v = lm.visibleRangeByHeight(viewTop: vt, viewBottom: vb);
        p('lm $step vrbh ${rf(vt)} ${rf(vb)} -> '
            '${v.firstLine} ${v.lastLine} ${f4(v.firstLineY)}');
        final f = lm.buildViewportFrame(
            viewTop: vt, viewBottom: vb, fallbackLineHeight: 17.0);
        p('lm $step lbvf ${rf(vt)} ${rf(vb)} -> '
            '${f.firstLine} ${f.lastLine} ${f4(f.firstLineY)} '
            '[${f.lines.map((l) => '${l.lenChars}:${f4(l.height)}').join(',')}]');
      }
    }
  }
  lm.clear();
  p('lm cleared lines ${lm.lenLines()} height ${f4(lm.totalHeight())}');

  // ignore: avoid_print
  print(out.toString().trimRight());
}

