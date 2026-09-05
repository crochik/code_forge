/// The editing core: text storage, line indexing and bidi segmentation.
///
/// This replaces the `flutter_rust_bridge` binding to a Rust `ropey` rope. The
/// public surface is deliberately identical — same class, same method names,
/// same `BigInt` parameters — so code written against the Rust-backed package
/// compiles and behaves the same.
///
/// ## Two deliberate differences from the Rust
///
/// **Offsets are UTF-16 code units, not Unicode scalar values.** `ropey` indexes
/// by code point. Every consumer of these offsets in this package is a Dart
/// `String` or a Flutter `TextSelection`, both of which are UTF-16 — see
/// `Rope.selection` in `code_forge/rope.dart`, which passes an offset from here
/// straight into `TextSelection.baseOffset`. The Rust build therefore disagreed
/// with its own callers on any text containing astral-plane characters (emoji,
/// CJK extension blocks). Indexing in UTF-16 makes the two agree. For text
/// entirely within the BMP — which is all source code in practice — the two
/// schemes produce identical indices for every operation.
///
/// **Out-of-range indices clamp instead of panicking.** `ropey` panics on an
/// out-of-bounds `insert` or `remove`, which crosses the FFI boundary as a
/// process abort. Here they clamp into range, which is what the surrounding
/// methods already did for every other operation.
library;

import 'dart:typed_data';

import 'bidi.dart';
import 'gap_buffer.dart';
import 'text_direction.dart';

export 'text_direction.dart';

/// A segment of text sharing a single strong direction.
class BiDiSegment {
  final BigInt start;
  final BigInt end;
  final TextDirection direction;

  const BiDiSegment({
    required this.start,
    required this.end,
    required this.direction,
  });

  @override
  int get hashCode => start.hashCode ^ end.hashCode ^ direction.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BiDiSegment &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end &&
          direction == other.direction;
}

/// A caret or selection, as a pair of offsets.
class SelectionState {
  final BigInt baseOffset;
  final BigInt extentOffset;

  const SelectionState({required this.baseOffset, required this.extentOffset});

  @override
  int get hashCode => baseOffset.hashCode ^ extentOffset.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectionState &&
          runtimeType == other.runtimeType &&
          baseOffset == other.baseOffset &&
          extentOffset == other.extentOffset;
}

class RopeBridge {
  RopeBridge._(this._buf, this._base, this._extent);

  /// Creates a rope holding [initialText].
  static RopeBridge create({required String initialText}) =>
      RopeBridge._(GapBuffer(initialText), 0, 0);

  final GapBuffer _buf;
  int _base;
  int _extent;

  /// Materialised document, dropped on every edit.
  ///
  /// The Rust build had to rebuild and re-marshal this string on every
  /// `getText()`; caching it means an unedited document is returned for free.
  String? _text;

  /// Offset of the start of each line, dropped on every edit.
  Int32List? _lineStarts;

  /// First index in [starts] holding a position greater than [value].
  static int _upperBound(Int32List starts, int value) {
    var lo = 0;
    var hi = starts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (starts[mid] > value) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// Moves the line index across a splice instead of rebuilding it.
  ///
  /// Rebuilding meant rescanning the whole document for newlines after every
  /// keystroke — 29ms on a 10MB file, which is two dropped frames for one
  /// character. `ropey` never paid that because its tree carries line counts.
  /// Here the cost is proportional to the number of *lines* after the edit,
  /// and the common case (a character with no newline on either side) is an
  /// in-place shift of the tail with no allocation.
  ///
  /// Call after the buffer has been edited; only pre-edit positions are read.
  void _spliceLineStarts(int start, int removedLen, String inserted) {
    final starts = _lineStarts;
    if (starts == null) return; // not built yet — the lazy path will do it

    final delta = inserted.length - removedLen;
    // `starts[0]` is always 0 and `start >= 0`, so index 0 is never dropped.
    final k = _upperBound(starts, start);
    final m = _upperBound(starts, start + removedLen);

    var added = 0;
    for (var j = 0; j < inserted.length; j++) {
      if (inserted.codeUnitAt(j) == 0x0A) added++;
    }

    if (added == 0 && m == k) {
      if (delta != 0) {
        for (var i = k; i < starts.length; i++) {
          starts[i] += delta;
        }
      }
      return;
    }

    final tail = starts.length - m;
    final next = Int32List(k + added + tail);
    next.setRange(0, k, starts);
    var at = k;
    for (var j = 0; j < inserted.length; j++) {
      if (inserted.codeUnitAt(j) == 0x0A) next[at++] = start + j + 1;
    }
    for (var i = 0; i < tail; i++) {
      next[at + i] = starts[m + i] + delta;
    }
    _lineStarts = next;
  }

  int get _length => _buf.length;

  Int32List get _starts {
    final cached = _lineStarts;
    if (cached != null) return cached;
    // One line more than there are newlines: an empty document has one line,
    // and a document ending in a newline has an empty final line. This matches
    // `ropey`'s `len_lines`.
    final n = _length;
    var count = 1;
    for (var i = 0; i < n; i++) {
      if (_buf.codeUnitAt(i) == 0x0A) count++;
    }
    final starts = Int32List(count);
    var at = 1;
    for (var i = 0; i < n; i++) {
      if (_buf.codeUnitAt(i) == 0x0A) starts[at++] = i + 1;
    }
    return _lineStarts = starts;
  }

  int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  /// Line containing [offset] — the largest `i` with `lineStart[i] <= offset`.
  int _lineAt(int offset) {
    final starts = _starts;
    var lo = 0;
    var hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Half-open range of the raw line [index], newline included.
  (int, int) _rawLine(int index) {
    final starts = _starts;
    final start = starts[index];
    final end = index + 1 < starts.length ? starts[index + 1] : _length;
    return (start, end);
  }

  static String _stripEol(String line) {
    if (line.endsWith('\r\n')) return line.substring(0, line.length - 2);
    if (line.endsWith('\n')) return line.substring(0, line.length - 1);
    return line;
  }

  // ---------------------------------------------------------------- selection

  SelectionState selection() => SelectionState(
        baseOffset: BigInt.from(_base),
        extentOffset: BigInt.from(_extent),
      );

  void setSelection({
    required BigInt baseOffset,
    required BigInt extentOffset,
  }) {
    final len = _length;
    _base = _clamp(baseOffset.toInt(), 0, len);
    _extent = _clamp(extentOffset.toInt(), 0, len);
  }

  SelectionState replaceRangeAndUpdateSelection({
    required BigInt start,
    required BigInt end,
    required String replacement,
    required bool preserveOldCursor,
    required BigInt oldBase,
    required BigInt oldExtent,
  }) {
    final len = _length;
    final safeStart = _clamp(start.toInt(), 0, len);
    final safeEnd = _clamp(end.toInt(), safeStart, len);

    if (safeStart < safeEnd) _buf.remove(safeStart, safeEnd);
    if (replacement.isNotEmpty) _buf.insert(safeStart, replacement);
    _text = null;
    _spliceLineStarts(safeStart, safeEnd - safeStart, replacement);

    final replacementLen = replacement.length;
    final newLen = _length;

    int base;
    int extent;
    if (preserveOldCursor) {
      final delta = replacementLen - (safeEnd - safeStart);
      int map(int offset) {
        if (offset <= safeStart) return offset;
        if (offset >= safeEnd) return _clamp(offset + delta, 0, newLen);
        final relative = offset - safeStart;
        final mapped =
            safeStart + (relative < replacementLen ? relative : replacementLen);
        return mapped < newLen ? mapped : newLen;
      }

      base = map(oldBase.toInt());
      extent = map(oldExtent.toInt());
    } else {
      base = safeStart + replacementLen;
      extent = base;
    }

    _base = base < newLen ? base : newLen;
    _extent = extent < newLen ? extent : newLen;
    return SelectionState(
      baseOffset: BigInt.from(base),
      extentOffset: BigInt.from(extent),
    );
  }

  // ------------------------------------------------------------------ content

  BigInt lenChars() => BigInt.from(_length);

  String getText() => _text ??= _buf.text();

  void insert({required BigInt charIdx, required String text}) {
    final at = _clamp(charIdx.toInt(), 0, _length);
    _buf.insert(at, text);
    _text = null;
    _spliceLineStarts(at, 0, text);
  }

  void remove({required BigInt start, required BigInt end}) {
    final len = _length;
    final s = _clamp(start.toInt(), 0, len);
    final e = _clamp(end.toInt(), s, len);
    _buf.remove(s, e);
    _text = null;
    _spliceLineStarts(s, e - s, '');
  }

  String slice({required BigInt start, required BigInt end}) {
    final len = _length;
    final validStart = _clamp(start.toInt(), 0, len);
    final validEnd = _clamp(end.toInt(), validStart, len);
    return _buf.substring(validStart, validEnd);
  }

  String charAt({required BigInt position}) {
    final at = position.toInt();
    if (at < 0 || at >= _length) return '';
    return _buf.substring(at, at + 1);
  }

  RopeBridge copy() => deepClone();

  RopeBridge deepClone() =>
      RopeBridge._(GapBuffer(getText()), _base, _extent);

  // -------------------------------------------------------------------- lines

  BigInt lenLines() => BigInt.from(_starts.length);

  BigInt charToLine({required BigInt charIdx}) =>
      BigInt.from(_lineAt(_clamp(charIdx.toInt(), 0, _length)));

  BigInt lineToChar({required BigInt lineIdx}) {
    final starts = _starts;
    return BigInt.from(starts[_clamp(lineIdx.toInt(), 0, starts.length - 1)]);
  }

  String line({required BigInt lineIdx}) {
    final starts = _starts;
    final index = _clamp(lineIdx.toInt(), 0, starts.length - 1);
    final (start, end) = _rawLine(index);
    return _stripEol(_buf.substring(start, end));
  }

  /// Line [index] with its terminator still attached, clamped into range.
  ///
  /// This is `ropey`'s `line()` before [line] strips the newline. The Rust
  /// reached straight into the rope for this; exposing it keeps the callers in
  /// `editor.dart` from having to reconstruct it.
  String rawLine(int index) {
    final starts = _starts;
    final (start, end) = _rawLine(_clamp(index, 0, starts.length - 1));
    return _buf.substring(start, end);
  }

  /// Length of [rawLine], without materialising it.
  int rawLineLength(int index) {
    final starts = _starts;
    final (start, end) = _rawLine(_clamp(index, 0, starts.length - 1));
    return end - start;
  }

  List<String> cachedLines() =>
      cachedLinesRange(startLine: BigInt.zero, endLine: lenLines());

  List<String> cachedLinesRange({
    required BigInt startLine,
    required BigInt endLine,
  }) {
    final total = _starts.length;
    final start = _clamp(startLine.toInt(), 0, total);
    final end = _clamp(endLine.toInt(), start, total);
    final lines = <String>[];
    for (var i = start; i < end; i++) {
      final (from, to) = _rawLine(i);
      lines.add(_stripEol(_buf.substring(from, to)));
    }
    return lines;
  }

  BigInt findLineStart({required BigInt offset}) =>
      lineToChar(lineIdx: charToLine(charIdx: offset));

  BigInt findLineEnd({required BigInt offset}) {
    final len = _length;
    final validOffset = _clamp(offset.toInt(), 0, len);
    final lineIndex = _lineAt(validOffset);
    final starts = _starts;
    final nextLineStart =
        lineIndex + 1 < starts.length ? starts[lineIndex + 1] : len;

    final (from, to) = _rawLine(lineIndex);
    final lineLen = to - from;
    if (lineLen == 0) return BigInt.from(nextLineStart);

    if (_buf.codeUnitAt(to - 1) == 0x0A) {
      if (lineLen >= 2 && _buf.codeUnitAt(to - 2) == 0x0D) {
        return BigInt.from(nextLineStart >= 2 ? nextLineStart - 2 : 0);
      }
      return BigInt.from(nextLineStart >= 1 ? nextLineStart - 1 : 0);
    }
    return BigInt.from(nextLineStart);
  }

  // --------------------------------------------------------------------- bidi

  /// Calls [visit] with the UTF-16 offset and code point of each character in
  /// `[from, to)`, decoding surrogate pairs so astral characters classify
  /// correctly. Returning `false` stops the walk.
  void _walk(int from, int to, bool Function(int offset, int codePoint) visit) {
    var i = from;
    while (i < to) {
      var cp = _buf.codeUnitAt(i);
      var width = 1;
      if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < to) {
        final low = _buf.codeUnitAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
          width = 2;
        }
      }
      if (!visit(i, cp)) return;
      i += width;
    }
  }

  TextDirection primaryDirection() {
    var rtl = 0;
    var ltr = 0;
    _walk(0, _length, (_, cp) {
      switch (directionForChar(cp)) {
        case TextDirection.rtl:
          rtl++;
        case TextDirection.ltr:
          ltr++;
        case _:
          break;
      }
      return true;
    });
    if (rtl == 0 && ltr == 0) return TextDirection.ltr;
    return rtl > ltr ? TextDirection.rtl : TextDirection.ltr;
  }

  TextDirection textDirection() {
    var hasRtl = false;
    var hasLtr = false;
    var mixed = false;
    _walk(0, _length, (_, cp) {
      switch (directionForChar(cp)) {
        case TextDirection.rtl:
          hasRtl = true;
        case TextDirection.ltr:
          hasLtr = true;
        case _:
          break;
      }
      if (hasRtl && hasLtr) {
        mixed = true;
        return false;
      }
      return true;
    });
    if (mixed) return TextDirection.mixed;
    return hasRtl ? TextDirection.rtl : TextDirection.ltr;
  }

  List<BiDiSegment> getBidiSegmentsInRange({
    required BigInt start,
    required BigInt end,
  }) =>
      _bidiSegments(start.toInt(), end.toInt());

  List<BiDiSegment> getBidiSegmentsForLine({required BigInt lineIndex}) {
    final starts = _starts;
    final index = _clamp(lineIndex.toInt(), 0, starts.length - 1);
    final (from, to) = _rawLine(index);
    return _bidiSegments(from, to);
  }

  List<BiDiSegment> _bidiSegments(int start, int rawEnd) {
    final len = _length;
    final end = rawEnd < len ? rawEnd : len;
    if (start >= end) return const [];

    // Short or plainly-ASCII runs skip classification entirely — the same
    // shortcut the Rust took, and the reason source code costs nothing here.
    if (end - start <= 32) {
      return [
        BiDiSegment(
          start: BigInt.from(start),
          end: BigInt.from(end),
          direction: TextDirection.ltr,
        ),
      ];
    }
    var allAscii = true;
    final probe = start + 32 < end ? start + 32 : end;
    for (var i = start; i < probe; i++) {
      if (_buf.codeUnitAt(i) > 127) {
        allAscii = false;
        break;
      }
    }
    if (allAscii) {
      return [
        BiDiSegment(
          start: BigInt.from(start),
          end: BigInt.from(end),
          direction: TextDirection.ltr,
        ),
      ];
    }

    final segments = <BiDiSegment>[];
    TextDirection? current;
    var segmentStart = start;
    _walk(start, end, (offset, cp) {
      final dir = directionForChar(cp);
      if (dir == null) return true;
      if (current == null) {
        current = dir;
        segmentStart = offset;
      } else if (dir != current) {
        segments.add(BiDiSegment(
          start: BigInt.from(segmentStart),
          end: BigInt.from(offset),
          direction: current!,
        ));
        current = dir;
        segmentStart = offset;
      }
      return true;
    });
    if (current != null) {
      segments.add(BiDiSegment(
        start: BigInt.from(segmentStart),
        end: BigInt.from(end),
        direction: current!,
      ));
    }
    return segments;
  }
}
