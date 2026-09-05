/// Bidirectional character classification.
///
/// The Rust build reached for the `unicode_bidi` crate, but only ever asked it
/// one question: is this character strongly left-to-right, strongly
/// right-to-left, or neither? (`BidiClass::L` → LTR; `R`, `AL` and `AN` → RTL;
/// everything else → neutral.) That is the question answered here.
///
/// This is a **block-level approximation** of the Unicode bidi property, not a
/// transcription of `DerivedBidiClass.txt`. The distinction that matters is
/// upheld exactly: whitespace, digits, punctuation and symbols stay *neutral*,
/// so a run of Arabic separated by spaces is not misread as mixed-direction.
/// Where it can differ from `unicode_bidi` is the exact class of a few
/// individual marks inside RTL blocks, which can move a segment boundary by a
/// character in text that mixes scripts. No caller in this package is sensitive
/// to that: the results feed direction detection and run splitting for layout.
library;

import 'text_direction.dart';

/// Ranges whose characters are strongly right-to-left — Unicode `R`, `AL` and
/// `AN`, which the caller treats identically.
const List<(int, int)> _rtlRanges = [
  (0x0590, 0x05FF), // Hebrew
  (0x0600, 0x06FF), // Arabic (incl. Arabic-Indic digits, class AN)
  (0x0700, 0x074F), // Syriac
  (0x0750, 0x077F), // Arabic Supplement
  (0x0780, 0x07BF), // Thaana
  (0x07C0, 0x07FF), // NKo
  (0x0800, 0x083F), // Samaritan
  (0x0840, 0x085F), // Mandaic
  (0x0860, 0x086F), // Syriac Supplement
  (0x0870, 0x089F), // Arabic Extended-B
  (0x08A0, 0x08FF), // Arabic Extended-A
  (0xFB1D, 0xFB4F), // Hebrew presentation forms
  (0xFB50, 0xFDFF), // Arabic presentation forms-A
  (0xFE70, 0xFEFF), // Arabic presentation forms-B
  (0x10800, 0x10FFF), // Cypriot, Phoenician, Kharoshthi, Old Persian, ...
  (0x1E800, 0x1EFFF), // Mende Kikakui, Adlam, Arabic Mathematical
];

/// Ranges whose letters are strongly left-to-right — Unicode `L`.
///
/// Deliberately lists *letters*, not whole planes: anything not matched here
/// and not matched above is neutral, which is the safe answer.
const List<(int, int)> _ltrRanges = [
  (0x0041, 0x005A), // A-Z
  (0x0061, 0x007A), // a-z
  (0x00AA, 0x00AA), // feminine ordinal
  (0x00B5, 0x00B5), // micro sign
  (0x00BA, 0x00BA), // masculine ordinal
  (0x00C0, 0x02B8), // Latin-1 letters, Latin Extended-A/B, IPA, modifiers
  (0x0370, 0x03FF), // Greek and Coptic
  (0x0400, 0x052F), // Cyrillic
  (0x0531, 0x058F), // Armenian
  (0x0900, 0x0DFF), // Devanagari through Sinhala
  (0x0E00, 0x0EFF), // Thai, Lao
  (0x0F00, 0x0FFF), // Tibetan
  (0x1000, 0x109F), // Myanmar
  (0x10A0, 0x10FF), // Georgian
  (0x1100, 0x11FF), // Hangul Jamo
  (0x1200, 0x137F), // Ethiopic
  (0x13A0, 0x13FF), // Cherokee
  (0x1E00, 0x1EFF), // Latin Extended Additional
  (0x1F00, 0x1FFF), // Greek Extended
  (0x2C00, 0x2C5F), // Glagolitic
  (0x2C60, 0x2C7F), // Latin Extended-C
  (0x2E80, 0x2FFF), // CJK radicals, Kangxi
  (0x3040, 0x30FF), // Hiragana, Katakana
  (0x3100, 0x312F), // Bopomofo
  (0x3400, 0x4DBF), // CJK Extension A
  (0x4E00, 0x9FFF), // CJK Unified Ideographs
  (0xA000, 0xA4CF), // Yi
  (0xAC00, 0xD7AF), // Hangul syllables
  (0xF900, 0xFAFF), // CJK compatibility ideographs
  (0xFF21, 0xFF3A), // fullwidth A-Z
  (0xFF41, 0xFF5A), // fullwidth a-z
  (0xFF66, 0xFFDC), // halfwidth katakana and hangul
  (0x1D400, 0x1D7CB), // mathematical alphanumerics
  (0x20000, 0x2FA1F), // CJK extensions B-F
];

bool _inRanges(int cp, List<(int, int)> ranges) {
  var lo = 0;
  var hi = ranges.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final (start, end) = ranges[mid];
    if (cp < start) {
      hi = mid - 1;
    } else if (cp > end) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

/// The strong direction of [codePoint], or `null` when it is neutral.
TextDirection? directionForChar(int codePoint) {
  // Fast path: ASCII is the overwhelming majority of source code.
  if (codePoint < 0x80) {
    final isLetter = (codePoint >= 0x41 && codePoint <= 0x5A) ||
        (codePoint >= 0x61 && codePoint <= 0x7A);
    return isLetter ? TextDirection.ltr : null;
  }
  if (_inRanges(codePoint, _rtlRanges)) return TextDirection.rtl;
  if (_inRanges(codePoint, _ltrRanges)) return TextDirection.ltr;
  return null;
}
