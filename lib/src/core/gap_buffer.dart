/// A gap buffer over UTF-16 code units.
///
/// This is the storage the editor sits on. The gap sits at the cursor, so the
/// common case — typing one character after the last one — is a single array
/// store with no copying. Moving the cursor a long way costs a `memmove` of the
/// distance travelled, which is the trade a gap buffer makes against a rope:
/// cursor-local edits get faster, far-away edits get slower.
///
/// See the "Is it necessary?" section of the app README for the measurements
/// behind that choice.
library;

import 'dart:typed_data';

final class GapBuffer {
  GapBuffer(String initial, {int gap = 1 << 12})
      : _buf = Uint16List(initial.length + gap),
        _gapStart = initial.length,
        _gapEnd = initial.length + gap {
    for (var i = 0; i < initial.length; i++) {
      _buf[i] = initial.codeUnitAt(i);
    }
  }

  Uint16List _buf;
  int _gapStart;
  int _gapEnd;

  int get length => _buf.length - (_gapEnd - _gapStart);

  int codeUnitAt(int index) =>
      _buf[index < _gapStart ? index : index + (_gapEnd - _gapStart)];

  void _moveGapTo(int pos) {
    if (pos == _gapStart) return;
    if (pos < _gapStart) {
      final n = _gapStart - pos;
      _buf.setRange(_gapEnd - n, _gapEnd, _buf, pos);
      _gapStart -= n;
      _gapEnd -= n;
    } else {
      final n = pos - _gapStart;
      _buf.setRange(_gapStart, _gapStart + n, _buf, _gapEnd);
      _gapStart += n;
      _gapEnd += n;
    }
  }

  void _grow(int need) {
    // Grow geometrically, and keep a gap proportional to the document so a
    // large file does not reallocate on every few keystrokes.
    final live = length;
    final newGap = (live >> 3).clamp(1 << 12, 1 << 20) + need;
    final next = Uint16List(live + newGap);
    next.setRange(0, _gapStart, _buf);
    final tail = _buf.length - _gapEnd;
    next.setRange(next.length - tail, next.length, _buf, _gapEnd);
    _buf = next;
    _gapEnd = next.length - tail;
  }

  void insert(int pos, String text) {
    if (text.isEmpty) return;
    _moveGapTo(pos);
    if (_gapEnd - _gapStart < text.length) _grow(text.length);
    for (var i = 0; i < text.length; i++) {
      _buf[_gapStart++] = text.codeUnitAt(i);
    }
  }

  void remove(int start, int end) {
    if (end <= start) return;
    _moveGapTo(end);
    _gapStart -= end - start;
  }

  String substring(int start, int end) {
    if (end <= start) return '';
    final gapLen = _gapEnd - _gapStart;
    if (end <= _gapStart) {
      return String.fromCharCodes(_buf, start, end);
    }
    if (start >= _gapStart) {
      return String.fromCharCodes(_buf, start + gapLen, end + gapLen);
    }
    final out = Uint16List(end - start);
    final head = _gapStart - start;
    out.setRange(0, head, _buf, start);
    out.setRange(head, out.length, _buf, _gapEnd);
    return String.fromCharCodes(out);
  }

  String text() => substring(0, length);
}
