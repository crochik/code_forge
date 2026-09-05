/// Layout mapping and the document scans that feed the editor's gutter,
/// folding, indent guides and word completion.
///
/// This replaces the `flutter_rust_bridge` binding to a Rust `zed-sum-tree`.
/// The public surface is deliberately identical to the generated one.
///
/// The sum tree is replaced by a flat list of line blocks with lazily rebuilt
/// prefix sums. Mutations are O(1) amortised and invalidate the sums; the first
/// query after a burst of mutations rebuilds them once, and every query after
/// that is a binary search. That suits the actual access pattern — many
/// `pushLine` calls while a document loads, then one viewport query per frame —
/// better than a tree that rebalances on each insert.
library;

import 'dart:typed_data';

import 'rope.dart';

// ---------------------------------------------------------------- value types

class LineSummary {
  final BigInt lenChars;
  final double height;
  final BigInt lines;

  const LineSummary({
    required this.lenChars,
    required this.height,
    required this.lines,
  });

  static Future<LineSummary> default_() async => LineSummary(
        lenChars: BigInt.zero,
        height: 0,
        lines: BigInt.zero,
      );

  @override
  int get hashCode => lenChars.hashCode ^ height.hashCode ^ lines.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LineSummary &&
          runtimeType == other.runtimeType &&
          lenChars == other.lenChars &&
          height == other.height &&
          lines == other.lines;
}

class LineCount {
  final BigInt field0;

  const LineCount({required this.field0});

  static Future<LineCount> default_() async => LineCount(field0: BigInt.zero);

  @override
  int get hashCode => field0.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LineCount &&
          runtimeType == other.runtimeType &&
          field0 == other.field0;
}

class CharOffset {
  final BigInt field0;

  const CharOffset({required this.field0});

  static Future<CharOffset> default_() async => CharOffset(field0: BigInt.zero);

  @override
  int get hashCode => field0.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CharOffset &&
          runtimeType == other.runtimeType &&
          field0 == other.field0;
}

class PixelHeight {
  final double field0;

  const PixelHeight({required this.field0});

  static Future<PixelHeight> default_() async => const PixelHeight(field0: 0);

  @override
  int get hashCode => field0.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PixelHeight &&
          runtimeType == other.runtimeType &&
          field0 == other.field0;
}

class GuideBlock {
  final int startLine;
  final int endLine;
  final int indentLevel;
  final int leadingSpaces;

  const GuideBlock({
    required this.startLine,
    required this.endLine,
    required this.indentLevel,
    required this.leadingSpaces,
  });

  @override
  int get hashCode =>
      startLine.hashCode ^
      endLine.hashCode ^
      indentLevel.hashCode ^
      leadingSpaces.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GuideBlock &&
          runtimeType == other.runtimeType &&
          startLine == other.startLine &&
          endLine == other.endLine &&
          indentLevel == other.indentLevel &&
          leadingSpaces == other.leadingSpaces;
}

class RustFoldRange {
  final int startLine;
  final int endLine;

  const RustFoldRange({required this.startLine, required this.endLine});

  @override
  int get hashCode => startLine.hashCode ^ endLine.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RustFoldRange &&
          runtimeType == other.runtimeType &&
          startLine == other.startLine &&
          endLine == other.endLine;
}

class ViewportFrame {
  final int firstLine;
  final int lastLine;
  final double firstLineY;
  final List<LineSummary> lines;

  const ViewportFrame({
    required this.firstLine,
    required this.lastLine,
    required this.firstLineY,
    required this.lines,
  });

  @override
  int get hashCode =>
      firstLine.hashCode ^
      lastLine.hashCode ^
      firstLineY.hashCode ^
      lines.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ViewportFrame &&
          runtimeType == other.runtimeType &&
          firstLine == other.firstLine &&
          lastLine == other.lastLine &&
          firstLineY == other.firstLineY &&
          lines == other.lines;
}

class VisibleLineRange {
  final int firstLine;
  final int lastLine;
  final double firstLineY;

  const VisibleLineRange({
    required this.firstLine,
    required this.lastLine,
    required this.firstLineY,
  });

  @override
  int get hashCode =>
      firstLine.hashCode ^ lastLine.hashCode ^ firstLineY.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VisibleLineRange &&
          runtimeType == other.runtimeType &&
          firstLine == other.firstLine &&
          lastLine == other.lastLine &&
          firstLineY == other.firstLineY;
}

// ------------------------------------------------------------------ LayoutMap

class _LineBlock {
  _LineBlock(this.lenChars, this.height, this.isFolded);
  int lenChars;
  double height;
  bool isFolded;

  /// A folded line occupies no vertical space, which is what makes the pixel
  /// dimension differ from a plain sum of heights.
  double get summaryHeight => isFolded ? 0.0 : height;
}

class LayoutMap {
  LayoutMap();

  final List<_LineBlock> _blocks = [];
  Float64List? _heightPrefix;
  Int64List? _charPrefix;

  void _invalidate() {
    _heightPrefix = null;
    _charPrefix = null;
  }

  Float64List get _heights {
    final cached = _heightPrefix;
    if (cached != null) return cached;
    final p = Float64List(_blocks.length + 1);
    for (var i = 0; i < _blocks.length; i++) {
      p[i + 1] = p[i] + _blocks[i].summaryHeight;
    }
    return _heightPrefix = p;
  }

  Int64List get _chars {
    final cached = _charPrefix;
    if (cached != null) return cached;
    final p = Int64List(_blocks.length + 1);
    for (var i = 0; i < _blocks.length; i++) {
      p[i + 1] = p[i] + _blocks[i].lenChars;
    }
    return _charPrefix = p;
  }

  /// Index of the first block whose cumulative end reaches [target].
  ///
  /// Mirrors a `zed-sum-tree` cursor seek: `Bias.left` stops at the first block
  /// whose end is `>= target`, `Bias.right` at the first whose end is
  /// `> target`. The two differ exactly where consecutive blocks contribute
  /// nothing — folded lines, for the height dimension — which is why both
  /// exist. Returns the block count when the target is past the end.
  int _seek(List<num> prefix, num target, {required bool biasLeft}) {
    final n = _blocks.length;
    var lo = 0;
    var hi = n;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final end = prefix[mid + 1];
      final reached = biasLeft ? end >= target : end > target;
      if (reached) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  void pushLine({
    required BigInt lenChars,
    required double height,
    required bool isFolded,
  }) {
    _blocks.add(_LineBlock(lenChars.toInt(), height, isFolded));
    _invalidate();
  }

  /// Index the Rust build actually mutated for a given `lineIdx`.
  ///
  /// **This is off by one, deliberately.** `insertLine`, `removeLine` and
  /// `updateLine` were implemented with a `zed-sum-tree` cursor slice at
  /// `Bias::Left`, which stops at the first block whose cumulative line count
  /// *reaches* the target rather than passes it — so the slice keeps
  /// `lineIdx - 1` blocks and the operation lands one line earlier than the
  /// argument suggests. `insertLine(1)` and `insertLine(0)` both insert at the
  /// front; `removeLine(2)` removes line 1.
  ///
  /// It is reproduced rather than corrected because the widget layer is written
  /// against it: `code_area.dart` drives these from its own line bookkeeping,
  /// and quietly shifting every mutation by one line would move the rendered
  /// layout. Verified against the Rust by differential test — see
  /// `test/layout_map_test.dart`.
  int _biasLeftIndex(int lineIdx) => lineIdx > 0 ? lineIdx - 1 : 0;

  /// Whether `lineIdx` is in range, treated as unsigned as the Rust did.
  bool _inRange(int lineIdx) => lineIdx >= 0 && lineIdx < _blocks.length;

  void insertLine({
    required BigInt lineIdx,
    required BigInt lenChars,
    required double height,
    required bool isFolded,
  }) {
    final at = lineIdx.toInt();
    if (!_inRange(at)) {
      pushLine(lenChars: lenChars, height: height, isFolded: isFolded);
      return;
    }
    _blocks.insert(
      _biasLeftIndex(at),
      _LineBlock(lenChars.toInt(), height, isFolded),
    );
    _invalidate();
  }

  void removeLine({required BigInt lineIdx}) {
    final at = lineIdx.toInt();
    if (!_inRange(at)) return;
    _blocks.removeAt(_biasLeftIndex(at));
    _invalidate();
  }

  void clear() {
    _blocks.clear();
    _invalidate();
  }

  double totalHeight() => _heights[_blocks.length];

  BigInt lenLines() => BigInt.from(_blocks.length);

  void updateLine({
    required BigInt lineIdx,
    required BigInt lenChars,
    required double height,
    required bool isFolded,
  }) {
    final at = lineIdx.toInt();
    if (!_inRange(at)) return;
    final block = _blocks[_biasLeftIndex(at)];
    block.lenChars = lenChars.toInt();
    block.height = height;
    block.isFolded = isFolded;
    _invalidate();
  }

  int visualLineFromCharOffset({required BigInt charOffset}) {
    if (_blocks.isEmpty) return 0;
    return _seek(_chars, charOffset.toInt(), biasLeft: true);
  }

  VisibleLineRange visibleRangeByHeight({
    required double viewTop,
    required double viewBottom,
  }) {
    if (_blocks.isEmpty) {
      return const VisibleLineRange(firstLine: 0, lastLine: 0, firstLineY: 0);
    }
    final heights = _heights;
    final top = viewTop > 0 ? viewTop : 0.0;
    final firstLine = _seek(heights, top, biasLeft: true);
    final firstLineY = heights[firstLine];

    final bottom = viewBottom > viewTop ? viewBottom : viewTop;
    var lastLine = _seek(heights, bottom, biasLeft: false);
    final maxLine = _blocks.length - 1;
    if (lastLine > maxLine) lastLine = maxLine;
    if (lastLine < firstLine) lastLine = firstLine;

    return VisibleLineRange(
      firstLine: firstLine,
      lastLine: lastLine,
      firstLineY: firstLineY,
    );
  }

  ViewportFrame buildViewportFrame({
    required double viewTop,
    required double viewBottom,
    required double fallbackLineHeight,
  }) {
    if (_blocks.isEmpty) {
      return const ViewportFrame(
        firstLine: 0,
        lastLine: 0,
        firstLineY: 0,
        lines: [],
      );
    }

    final visible =
        visibleRangeByHeight(viewTop: viewTop, viewBottom: viewBottom);
    final heights = _heights;
    final bottom = viewBottom > viewTop ? viewBottom : viewTop;
    final fallback = fallbackLineHeight > 1.0 ? fallbackLineHeight : 1.0;

    final lines = <LineSummary>[];
    for (var i = visible.firstLine; i < _blocks.length; i++) {
      if (heights[i] > bottom) break;
      final block = _blocks[i];
      final lineHeight = block.isFolded
          ? 0.0
          : (block.height > 0 ? block.height : fallback);
      lines.add(LineSummary(
        lenChars: BigInt.from(block.lenChars),
        height: lineHeight,
        lines: BigInt.one,
      ));
    }

    final computedLast = lines.isEmpty
        ? visible.firstLine
        : visible.firstLine + lines.length - 1;
    return ViewportFrame(
      firstLine: visible.firstLine,
      lastLine: computedLast > visible.firstLine
          ? computedLast
          : visible.firstLine,
      firstLineY: visible.firstLineY,
      lines: lines,
    );
  }
}

// -------------------------------------------------------------- free functions

int _floorToInt(double v) {
  if (v.isNaN) return 0;
  if (v <= -2147483648.0) return -2147483648;
  if (v >= 2147483647.0) return 2147483647;
  return v.floor();
}

int _ceilToInt(double v) {
  if (v.isNaN) return 0;
  if (v <= -2147483648.0) return -2147483648;
  if (v >= 2147483647.0) return 2147483647;
  return v.ceil();
}

VisibleLineRange visibleLineRangeUnwrapped({
  required int totalLines,
  required double viewTop,
  required double viewBottom,
  required double lineHeight,
}) {
  if (totalLines <= 0) {
    return const VisibleLineRange(firstLine: 0, lastLine: 0, firstLineY: 0);
  }
  final safeLineHeight = lineHeight > 0.0 ? lineHeight : 1.0;
  final maxLine = totalLines - 1;
  final firstLine = _floorToInt(viewTop / safeLineHeight).clamp(0, maxLine);
  final lastLine = _ceilToInt(viewBottom / safeLineHeight).clamp(0, maxLine);
  return VisibleLineRange(
    firstLine: firstLine,
    lastLine: lastLine,
    firstLineY: firstLine * safeLineHeight,
  );
}

ViewportFrame buildViewportFrame({
  required RopeBridge rope,
  required double viewTop,
  required double viewBottom,
  required double lineHeight,
}) {
  final totalLines = rope.lenLines().toInt();
  if (totalLines <= 0) {
    return const ViewportFrame(
      firstLine: 0,
      lastLine: 0,
      firstLineY: 0,
      lines: [],
    );
  }
  final safeLineHeight = lineHeight > 0.0 ? lineHeight : 1.0;
  final maxLine = totalLines - 1;
  final firstLine = _floorToInt(viewTop / safeLineHeight).clamp(0, maxLine);
  final lastLine = _ceilToInt(viewBottom / safeLineHeight).clamp(0, maxLine);

  final lines = <LineSummary>[];
  for (var idx = firstLine; idx <= lastLine; idx++) {
    final lenChars = idx < totalLines ? rope.rawLineLength(idx) : 0;
    lines.add(LineSummary(
      lenChars: BigInt.from(lenChars),
      height: safeLineHeight,
      lines: BigInt.one,
    ));
  }

  return ViewportFrame(
    firstLine: firstLine,
    lastLine: lastLine,
    firstLineY: firstLine * safeLineHeight,
    lines: lines,
  );
}

Future<List<RustFoldRange>> foldsComputeAll({required RopeBridge rope}) async {
  final folds = <RustFoldRange>[];
  final stack = <(int, int)>[];
  var lineIdx = 0;
  final text = rope.getText();

  for (var i = 0; i < text.length; i++) {
    final ch = text.codeUnitAt(i);
    if (ch == 0x0A) lineIdx++;
    if (ch == 0x7B || ch == 0x5B || ch == 0x28) {
      stack.add((ch, lineIdx));
    } else if (ch == 0x7D || ch == 0x5D || ch == 0x29) {
      if (stack.isEmpty) continue;
      final (openCh, startLine) = stack.removeLast();
      final matches = (openCh == 0x7B && ch == 0x7D) ||
          (openCh == 0x5B && ch == 0x5D) ||
          (openCh == 0x28 && ch == 0x29);
      if (matches && startLine < lineIdx) {
        folds.add(RustFoldRange(startLine: startLine, endLine: lineIdx));
      }
    }
  }
  return folds;
}

int foldsFindMatchingBracket({
  required RopeBridge rope,
  required int targetOffset,
}) {
  if (targetOffset < 0) return -1;
  return _findMatchingBracket(rope.getText(), targetOffset) ?? -1;
}

int? _findMatchingBracket(String text, int targetOffset) {
  final len = text.length;
  if (targetOffset >= len) return null;

  final startCh = text.codeUnitAt(targetOffset);
  final int matcher;
  final bool forward;
  switch (startCh) {
    case 0x7B: // {
      matcher = 0x7D;
      forward = true;
    case 0x5B: // [
      matcher = 0x5D;
      forward = true;
    case 0x28: // (
      matcher = 0x29;
      forward = true;
    case 0x7D: // }
      matcher = 0x7B;
      forward = false;
    case 0x5D: // ]
      matcher = 0x5B;
      forward = false;
    case 0x29: // )
      matcher = 0x28;
      forward = false;
    default:
      return null;
  }

  var depth = 1;
  if (forward) {
    for (var i = targetOffset + 1; i < len; i++) {
      final ch = text.codeUnitAt(i);
      if (ch == startCh) {
        depth++;
      } else if (ch == matcher) {
        if (--depth == 0) return i;
      }
    }
  } else {
    var i = targetOffset;
    while (i > 0) {
      i--;
      final ch = text.codeUnitAt(i);
      if (ch == startCh) {
        depth++;
      } else if (ch == matcher) {
        if (--depth == 0) return i;
      }
    }
  }
  return null;
}

Future<List<String>> wordsExtract({required RopeBridge rope}) async {
  final words = <String>{};
  final text = rope.getText();
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isEmpty) return;
    if (words.length < 5000) words.add(buffer.toString());
    buffer.clear();
  }

  for (var i = 0; i < text.length; i++) {
    final cu = text.codeUnitAt(i);
    if (_isWordChar(cu)) {
      buffer.writeCharCode(cu);
    } else {
      flush();
    }
  }
  flush();
  return words.toList();
}

final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isWordChar(int cu) {
  if (cu < 0x80) {
    return (cu >= 0x30 && cu <= 0x39) ||
        (cu >= 0x41 && cu <= 0x5A) ||
        (cu >= 0x61 && cu <= 0x7A) ||
        cu == 0x5F;
  }
  return _letterOrDigit.hasMatch(String.fromCharCode(cu));
}

/// Unicode `White_Space`, matching Rust's `char::is_whitespace`.
bool _isWhitespace(int cu) {
  if (cu == 0x20) return true;
  if (cu >= 0x09 && cu <= 0x0D) return true;
  if (cu < 0x80) return false;
  return cu == 0x85 ||
      cu == 0xA0 ||
      cu == 0x1680 ||
      (cu >= 0x2000 && cu <= 0x200A) ||
      cu == 0x2028 ||
      cu == 0x2029 ||
      cu == 0x202F ||
      cu == 0x205F ||
      cu == 0x3000;
}

/// Column reached by the leading whitespace of [line], expanding tabs.
int _leadingColumns(String line, int lineLen, int tabSize) {
  var cols = 0;
  for (var i = 0; i < lineLen; i++) {
    final c = line.codeUnitAt(i);
    if (c == 0x20) {
      cols++;
    } else if (c == 0x09) {
      if (tabSize > 0) {
        final remainder = cols % tabSize;
        cols += remainder == 0 ? tabSize : tabSize - remainder;
      } else {
        cols += 1;
      }
    } else {
      break;
    }
  }
  return cols;
}

/// Length of [line] with its line terminator removed.
int _lenWithoutEol(String line) {
  var len = line.length;
  if (len >= 2 &&
      line.codeUnitAt(len - 1) == 0x0A &&
      line.codeUnitAt(len - 2) == 0x0D) {
    return len - 2;
  }
  if (len >= 1 && line.codeUnitAt(len - 1) == 0x0A) return len - 1;
  return len;
}

bool _isBlank(String line, int lineLen) {
  for (var i = 0; i < lineLen; i++) {
    if (!_isWhitespace(line.codeUnitAt(i))) return false;
  }
  return true;
}

String? _extractOpeningTagName(String line) {
  final trimmed = line.trimRight();
  if (!trimmed.endsWith('>') ||
      trimmed.endsWith('/>') ||
      trimmed.endsWith('-->')) {
    return null;
  }
  final start = trimmed.indexOf('<');
  if (start < 0 || start + 1 >= trimmed.length) return null;

  final first = trimmed.codeUnitAt(start + 1);
  final isAlpha = (first >= 0x41 && first <= 0x5A) ||
      (first >= 0x61 && first <= 0x7A);
  if (!isAlpha) return null;

  final name = StringBuffer()..writeCharCode(first);
  for (var i = start + 2; i < trimmed.length; i++) {
    final c = trimmed.codeUnitAt(i);
    final ok = (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        c == 0x3A ||
        c == 0x5F ||
        c == 0x2D;
    if (!ok) break;
    name.writeCharCode(c);
  }
  return name.toString();
}

bool _containsSameTagOpening(String line, String tagName) =>
    line.contains('<$tagName') &&
    !line.contains('</$tagName') &&
    !line.endsWith('/>');

bool _containsSameTagClosing(String line, String tagName) =>
    line.contains('</$tagName');

int? _findMatchingClosingTagLine(
  RopeBridge rope,
  int startLine,
  String tagName,
) {
  var depth = 1;
  final totalLines = rope.lenLines().toInt();
  for (var lineIdx = startLine + 1; lineIdx < totalLines; lineIdx++) {
    final trimmed = rope.rawLine(lineIdx).trim();
    if (trimmed.isEmpty) continue;
    if (_containsSameTagOpening(trimmed, tagName)) depth++;
    if (_containsSameTagClosing(trimmed, tagName)) {
      depth = depth > 0 ? depth - 1 : 0;
      if (depth == 0) return lineIdx;
    }
  }
  return null;
}

List<GuideBlock> guidesComputeViewport({
  required RopeBridge rope,
  required BigInt firstVisible,
  required BigInt lastVisible,
  required BigInt tabSize,
}) {
  const scanBackLimit = 500;
  final totalLines = rope.lenLines().toInt();
  if (totalLines == 0) return const [];

  final tab = tabSize.toInt();
  final maxLine = totalLines - 1;
  final first = firstVisible.toInt().clamp(0, maxLine);
  final last = lastVisible.toInt().clamp(0, maxLine);
  final scanStart = first > scanBackLimit ? first - scanBackLimit : 0;

  final blocks = <GuideBlock>[];

  for (var lineIdx = scanStart; lineIdx <= last; lineIdx++) {
    final raw = rope.rawLine(lineIdx);
    var lineLen = _lenWithoutEol(raw);
    while (lineLen > 0 && _isWhitespace(raw.codeUnitAt(lineLen - 1))) {
      lineLen--;
    }
    if (lineLen == 0) continue;

    final lastChar = raw.codeUnitAt(lineLen - 1);
    final openingTagName = _extractOpeningTagName(raw.substring(0, lineLen));
    final endsWithBracket = lastChar == 0x7B || // {
        lastChar == 0x28 || // (
        lastChar == 0x5B || // [
        lastChar == 0x3A; // :
    if (!endsWithBracket && openingTagName == null) continue;

    final leadingCols = _leadingColumns(raw, lineLen, tab);
    final indentLevel = tab > 0 ? leadingCols ~/ tab : 0;

    var endLine = lineIdx + 1;

    if (lastChar == 0x7B || lastChar == 0x28 || lastChar == 0x5B) {
      final lineStartChar = rope.lineToChar(lineIdx: BigInt.from(lineIdx)).toInt();
      final bracketPos = lineStartChar + lineLen - 1;
      final matchPos = _findMatchingBracket(rope.getText(), bracketPos);
      if (matchPos != null) {
        endLine = rope.charToLine(charIdx: BigInt.from(matchPos)).toInt() + 1;
      }
    } else if (openingTagName != null) {
      final matchLine =
          _findMatchingClosingTagLine(rope, lineIdx, openingTagName);
      if (matchLine != null) endLine = matchLine + 1;
    }

    if (endLine <= lineIdx + 1) {
      // No bracket or tag to close against: extend over the following lines
      // that are indented further than this one.
      var scan = lineIdx + 1;
      var lastValid = lineIdx;
      while (scan < totalLines) {
        final scanRaw = rope.rawLine(scan);
        final scanLen = _lenWithoutEol(scanRaw);
        if (_isBlank(scanRaw, scanLen)) {
          scan++;
          continue;
        }
        if (_leadingColumns(scanRaw, scanLen, tab) <= leadingCols) break;
        lastValid = scan;
        scan++;
      }
      endLine = lastValid + 1;
    }

    if (endLine <= lineIdx + 1) continue;

    // Drop a guide that would span back out to this line's own indent level.
    var wouldPass = false;
    for (var check = lineIdx + 1; check < endLine - 1; check++) {
      final checkRaw = rope.rawLine(check);
      final checkLen = _lenWithoutEol(checkRaw);
      if (_isBlank(checkRaw, checkLen)) continue;
      if (_leadingColumns(checkRaw, checkLen, tab) <= leadingCols) {
        wouldPass = true;
        break;
      }
    }
    if (wouldPass) continue;

    blocks.add(GuideBlock(
      startLine: lineIdx,
      endLine: endLine,
      indentLevel: indentLevel,
      leadingSpaces: leadingCols,
    ));
  }

  return blocks;
}
