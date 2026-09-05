import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:re_highlight/re_highlight.dart';

import '../LSP/lsp.dart';

class SemanticWordSpan {
  final int startChar;
  final int endChar;
  final String word;
  final TextStyle style;

  SemanticWordSpan({
    required this.startChar,
    required this.endChar,
    required this.word,
    required this.style,
  });
}

class HighlightedLine {
  final String text;
  final TextSpan? span;
  final int version;

  HighlightedLine(this.text, this.span, this.version);
}

/// A highlighted run, in a shape that survives the trip back from the
/// background isolate.
///
/// It used to carry the *name* of the theme scope, and the conversion that
/// filled it never assigned one — every span came back scopeless, and so was
/// rebuilt with the base style. The segmentation was right and the colour was
/// gone. Carrying the style itself removes the question: it is what the
/// renderer already resolved, in an isolate that was handed the theme.
class _SpanData {
  final String text;
  final TextStyle? style;
  final List<_SpanData> children;

  _SpanData(this.text, this.style, [this.children = const []]);
}

class SyntaxHighlighter {
  final Mode language;
  final List<Mode> extraLanguages;
  final Map<String, TextStyle> editorTheme;
  final TextStyle? baseTextStyle;
  final String? languageId;
  final Map<int, HighlightedLine> _grammarCache = {}, _mergedCache = {};
  final Map<int, List<SemanticWordSpan>> _lineSemanticSpans = {};
  final Map<String, TextSpan?> _lineSpanCache = {};
  late final String _langId;
  late final Highlight _highlight;
  late final Map<String, TextStyle> _resolvedTheme;
  late final List<Mode> _registeredExtraLanguages;
  late final Map<String, List<String>> _semanticMapping;
  static const int isolateThreshold = 500;
  static const int _cacheKeepMargin = 500;
  static const int _maxLineCacheEntries = 6000;
  static const int _maxSpanCacheEntries = 8000;
  int get documentVersion => _documentVersion;

  /// Bumped whenever anything that decides a line's colours changes: an edit,
  /// a semantic-token answer, an invalidation. Anything holding something built
  /// from a line's colouring — a laid-out paragraph, say — can compare this
  /// against the value it built with and know whether it is still current.
  int get colouringVersion => _version;
  Future<void>? _preHighlightInFlight;
  int _preHighlightInFlightVersion = -1, _version = 0, _documentVersion = 0;
  bool _isEditing = false;

  SyntaxHighlighter({
    required this.language,
    required this.editorTheme,
    this.baseTextStyle,
    this.languageId,
    this.extraLanguages = const [],
  }) {
    _langId = language.hashCode.toString();
    _resolvedTheme = _buildResolvedTheme(editorTheme);
    _highlight = Highlight();
    _highlight.registerLanguage(_langId, language);

    _registeredExtraLanguages = <Mode>[...extraLanguages];

    for (final lang in _registeredExtraLanguages) {
      _registerLanguageWithAliases(_highlight, lang);
    }

    _semanticMapping = getSemanticMapping(languageId ?? '');
  }

  void updateSemanticTokens(
    List<LspSemanticToken> tokens,
    String Function(int) getLineText,
    int lineCount,
  ) {
    // Applying an answer costs every cache in the highlighter and a re-run of
    // the grammar over the viewport — around 9ms on a 12,000-line document,
    // and an isolate spawn when the viewport is more than fifty lines. An
    // answer identical to the one already applied buys none of that, and while
    // someone scrolls a document the server has no analysis for, *every*
    // answer is identical: empty.
    final signature = _signatureOf(tokens);
    if (signature == _appliedSignature) return;
    _appliedSignature = signature;

    final updatedLineSemanticSpans = <int, List<SemanticWordSpan>>{};
    final lineCache = <int, String>{};

    // The part of *this* document the answer describes. Not the same as the
    // lines the answer mentions: an answer can arrive about a document that has
    // since been replaced by a shorter one, and those lines describe nothing
    // here. See the replacement below.
    int? describedFrom;
    int? describedTo;

    for (final token in tokens) {
      if (token.line < 0 || token.line >= lineCount) continue;
      describedFrom = describedFrom == null || token.line < describedFrom
          ? token.line
          : describedFrom;
      describedTo = describedTo == null || token.line > describedTo
          ? token.line
          : describedTo;
      final lineText = lineCache.putIfAbsent(
        token.line,
        () => getLineText(token.line),
      );
      final start = token.start.clamp(0, lineText.length);
      final end = (token.start + token.length).clamp(0, lineText.length);

      if (start < end) {
        final word = lineText.substring(start, end);
        final style = _resolveSemanticStyle(token.tokenTypeName);

        if (style != null && word.isNotEmpty) {
          final lineSpans = updatedLineSemanticSpans.putIfAbsent(
            token.line,
            () => [],
          );
          lineSpans.add(
            SemanticWordSpan(
              startChar: start,
              endChar: end,
              word: word,
              style: style,
            ),
          );
        }
      }
    }

    for (final spans in updatedLineSemanticSpans.values) {
      spans.sort((a, b) => a.startChar.compareTo(b.startChar));
    }

    // Every line the answer covered is replaced, not merged into. A line that
    // came back with no tokens now *has* none — keeping what it had before
    // would leave it painted from an older version of the text.
    //
    // Covered means covered *here*: the range is taken from the tokens that
    // landed inside this document, not from every token in the answer. Taken
    // from the answer, an answer about a document this one has already replaced
    // — every token past the end of a shorter one, every offset past the end of
    // a changed line — cleared the whole range it named and put nothing back.
    // The classification vanished and stayed gone, because the client only asks
    // again when the document changes: an edit brought it back, nothing else
    // did.
    if (describedFrom != null && describedTo != null) {
      _lineSemanticSpans.removeWhere(
        (line, _) => line >= describedFrom! && line <= describedTo!,
      );
    }

    for (final entry in updatedLineSemanticSpans.entries) {
      _lineSemanticSpans[entry.key] = entry.value;
    }

    _isEditing = false;
    _hadClassification = _lineSemanticSpans.isNotEmpty;
    _lineSpanCache.clear();
    _mergedCache.clear();
    _grammarCache.clear();
    _version++;
  }

  /// Whether a classification this held has gone, and says so once.
  ///
  /// A client asks the server for tokens when the document changes and not
  /// otherwise, so an answer that is lost after it was applied is lost for
  /// good: the colouring falls back to what the grammar alone can say and
  /// stays there until the next edit. Anything that empties the spans without
  /// an answer to replace them — an edit that moved every line, a document
  /// replaced under an answer in flight — leaves the editor in that state.
  ///
  /// Rather than trust that no such path exists, a renderer can ask this and
  /// request the tokens again. Answering once per loss is what keeps that from
  /// becoming a request per frame: a document with genuinely nothing to
  /// classify answers false, having never had anything to lose.
  bool takeLostClassification() {
    if (!_hadClassification || _lineSemanticSpans.isNotEmpty) return false;
    _hadClassification = false;
    return true;
  }

  bool _hadClassification = false;

  /// Whether any line in `[from, to]` carries a classification.
  ///
  /// Asked of the viewport: a screenful with none of it, in a file that is
  /// almost entirely names, is the shape of the problem.
  bool hasClassificationBetween(int from, int to) {
    for (var line = from; line <= to; line++) {
      final spans = _lineSemanticSpans[line];
      if (spans != null && spans.isNotEmpty) return true;
    }
    return false;
  }

  /// Applies the next answer even if it is the one already applied.
  ///
  /// An answer identical to the one held is skipped, which is what keeps
  /// scrolling a file the server has nothing to say about cheap. But a request
  /// made *because* the colouring went missing asks about a document that has
  /// not changed, so what comes back is byte-identical to the answer that was
  /// lost — and would be skipped, leaving the file exactly as plain as before.
  /// Asking again only repairs anything if the answer is allowed to land.
  void forceNextAnswer() => _appliedSignature = null;

  /// Drops the classification currently applied, keeping only what the grammar
  /// says.
  ///
  /// For when the spans no longer describe the text under them at all — the
  /// editor being pointed at another file. An empty answer does not do this on
  /// purpose: a server with nothing to say about a document should not wipe
  /// what is painted, and while someone scrolls such a document every answer is
  /// an empty one.
  void forgetSemanticTokens() {
    _appliedSignature = null;
    // Deliberate, and the file it described is gone: not a loss to recover.
    _hadClassification = false;
    if (_lineSemanticSpans.isEmpty) return;

    _lineSemanticSpans.clear();
    _lineSpanCache.clear();
    _mergedCache.clear();
    _grammarCache.clear();
    _isEditing = false;
    _version++;
  }

  /// Identifies a token list cheaply enough to compare on every answer.
  static int _signatureOf(List<LspSemanticToken> tokens) {
    var hash = tokens.length;
    for (final token in tokens) {
      hash = Object.hash(
        hash,
        token.line,
        token.start,
        token.length,
        token.typeIndex,
        token.modifierBitmask,
        // The name is what picks the style, and a client can carry one the
        // index alone would not distinguish.
        token.tokenTypeName,
      );
    }
    return hash;
  }

  /// The signature of the answer currently applied. Null until the first one,
  /// so an empty first answer still clears whatever the caches hold.
  int? _appliedSignature;

  void applyDocumentEdit(
    int editLine,
    int editStart,
    int oldEnd,
    String insertedText,
    String deletedText,
    String fullText,
  ) {
    _documentVersion++;
    // The spans below are about to be shifted or dropped, so they no longer
    // match the answer they came from. The next answer has to be applied even
    // if the server sends the same tokens back.
    _appliedSignature = null;
    final insertedLineBreaks = '\n'.allMatches(insertedText).length;
    final deletedLineBreaks = '\n'.allMatches(deletedText).length;
    final lineBreakDelta = insertedLineBreaks - deletedLineBreaks;
    final isPureInsertion = oldEnd == editStart;
    final isPureDeletion = insertedText.isEmpty && oldEnd > editStart;
    if (lineBreakDelta != 0 && (isPureInsertion || isPureDeletion)) {
      final shiftedSemanticSpans = <int, List<SemanticWordSpan>>{};
      for (final entry in _lineSemanticSpans.entries) {
        final lineIndex = entry.key;
        if (lineIndex > editLine) {
          shiftedSemanticSpans[lineIndex + lineBreakDelta] = entry.value;
        } else if (lineIndex < editLine) {
          shiftedSemanticSpans[lineIndex] = entry.value;
        }
        // The edited line itself is dropped: it was split or joined, so its
        // spans describe a line that no longer exists. Grammar colouring holds
        // it until the server answers, which is better than painting a word in
        // two colours from offsets that have moved.
      }

      _lineSemanticSpans
        ..clear()
        ..addAll(shiftedSemanticSpans);
      _grammarCache.removeWhere((line, _) => line >= editLine);
      _mergedCache.removeWhere((line, _) => line >= editLine);
      _isEditing = false;
    } else if (lineBreakDelta != 0) {
      // A replacement that changed the line count — a paste over a selection,
      // say. Every line below the edit has moved, and the spans were computed
      // against the old numbering, so there is nothing honest to shift them by.
      _lineSemanticSpans.clear();
      _grammarCache.clear();
      _mergedCache.clear();
      _isEditing = false;
    } else if (insertedText.isNotEmpty || deletedText.isNotEmpty) {
      final lineSemanticSpans = _lineSemanticSpans[editLine];
      if (lineSemanticSpans != null && lineSemanticSpans.isNotEmpty) {
        final updatedLineSemanticSpans = <SemanticWordSpan>[];
        final insertedLength = insertedText.length;
        final deletedLength = deletedText.length;
        final shiftDelta = insertedLength - deletedLength;
        final insertedEnd = editStart + insertedLength;

        for (final span in lineSemanticSpans) {
          if (span.endChar <= editStart) {
            updatedLineSemanticSpans.add(span);
            continue;
          }

          if (span.startChar >= oldEnd) {
            updatedLineSemanticSpans.add(
              SemanticWordSpan(
                startChar: span.startChar + shiftDelta,
                endChar: span.endChar + shiftDelta,
                word: span.word,
                style: span.style,
              ),
            );
            continue;
          }

          if (span.startChar < editStart) {
            final leftEnd = editStart.clamp(span.startChar, span.endChar);
            if (leftEnd > span.startChar) {
              updatedLineSemanticSpans.add(
                SemanticWordSpan(
                  startChar: span.startChar,
                  endChar: leftEnd,
                  word: span.word.substring(0, leftEnd - span.startChar),
                  style: span.style,
                ),
              );
            }
          }

          if (span.endChar > oldEnd) {
            final rightStart = insertedEnd;
            final rightEnd = span.endChar + shiftDelta;
            if (rightEnd > rightStart) {
              final rightWordStart =
                  (span.word.length - (span.endChar - oldEnd)).clamp(
                    0,
                    span.word.length,
                  );
              updatedLineSemanticSpans.add(
                SemanticWordSpan(
                  startChar: rightStart,
                  endChar: rightEnd,
                  word: span.word.substring(rightWordStart),
                  style: span.style,
                ),
              );
            }
          }
        }

        updatedLineSemanticSpans.sort(
          (a, b) => a.startChar == b.startChar
              ? a.endChar.compareTo(b.endChar)
              : a.startChar.compareTo(b.startChar),
        );
        _lineSemanticSpans[editLine] = updatedLineSemanticSpans;
      }

      _isEditing = false;
    } else {
      _isEditing = true;
    }

    _lineSpanCache.clear();
    _version++;
  }

  void invalidateAll() {
    _appliedSignature = null;
    _grammarCache.clear();
    _mergedCache.clear();
    _documentVersion++;
    _version++;
  }

  void invalidateLines(Set<int> lines) {
    for (final line in lines) {
      _grammarCache.remove(line);
      _mergedCache.remove(line);
    }
    _version++;
  }

  void invalidateRange(int startLine, int endLine) {
    for (int i = startLine; i <= endLine; i++) {
      _grammarCache.remove(i);
      _mergedCache.remove(i);
    }
    final keysToRemove = _grammarCache.keys.where((k) => k > endLine).toList();
    for (final key in keysToRemove) {
      _grammarCache.remove(key);
      _mergedCache.remove(key);
    }
    _version++;
  }

  TextSpan? getLineSpan(int lineIndex, String lineText) {
    final mergedCache = _mergedCache[lineIndex];
    if (mergedCache != null &&
        mergedCache.version == _version &&
        mergedCache.text == lineText) {
      return mergedCache.span;
    }

    final grammarCache = _grammarCache[lineIndex];
    final cachedGrammarSpan =
        grammarCache != null &&
            grammarCache.version == _version &&
            grammarCache.text == lineText
        ? grammarCache.span
        : null;

    final semanticSpans = _lineSemanticSpans[lineIndex];
    if (_isEditing || semanticSpans == null || semanticSpans.isEmpty) {
      if (_lineSpanCache.containsKey(lineText)) {
        return _lineSpanCache[lineText];
      }
      if (cachedGrammarSpan != null) {
        _lineSpanCache[lineText] = cachedGrammarSpan;
        return cachedGrammarSpan;
      }
    }

    if (cachedGrammarSpan != null) {
      final mergedSpan = _mergeGrammarAndSemantic(
        lineText,
        cachedGrammarSpan,
        semanticSpans,
      );

      // Deliberately not in `_lineSpanCache`: that one is keyed by line text
      // alone, and a merged span belongs to a line, not to a string. Two lines
      // reading the same would otherwise share whichever one was coloured
      // first — and a line with no semantic tokens of its own would be served
      // another line's colouring.
      _mergedCache[lineIndex] = HighlightedLine(lineText, mergedSpan, _version);
      return mergedSpan;
    }

    if (_lineSpanCache.containsKey(lineText) &&
        (semanticSpans == null || semanticSpans.isEmpty || _isEditing)) {
      return _lineSpanCache[lineText];
    }

    final grammarSpan = _highlightLine(lineText);

    if (_isEditing) {
      _lineSpanCache[lineText] = grammarSpan;
      return grammarSpan;
    }

    final mergedSpan = _mergeGrammarAndSemantic(
      lineText,
      grammarSpan,
      semanticSpans,
    );

    // Line-keyed only, for the reason above.
    _mergedCache[lineIndex] = HighlightedLine(lineText, mergedSpan, _version);

    return mergedSpan;
  }

  TextSpan? _mergeGrammarAndSemantic(
    String lineText,
    TextSpan? grammarSpan,
    List<SemanticWordSpan>? semanticSpans,
  ) {
    if (lineText.isEmpty) {
      return grammarSpan;
    }

    if (semanticSpans == null || semanticSpans.isEmpty) {
      return grammarSpan;
    }

    final grammarSegments = <({String text, TextStyle? style})>[];
    _flattenGrammarSpan(grammarSpan, grammarSegments, baseTextStyle);

    final children = <TextSpan>[];
    int currentPos = 0; // UTF‑16 index

    final utf16SemanticRanges = semanticSpans.map((span) {
      final start = _scalarToUtf16Index(
        lineText,
        span.startChar,
      ).clamp(0, lineText.length);
      final end = _scalarToUtf16Index(
        lineText,
        span.endChar,
      ).clamp(0, lineText.length);
      return (start: start, end: end, style: span.style);
    }).toList();

    for (final range in utf16SemanticRanges) {
      if (range.start > currentPos) {
        _addGrammarSegments(
          children,
          grammarSegments,
          currentPos,
          range.start,
          lineText,
        );
      }

      if (range.start < range.end) {
        final actualText = lineText.substring(range.start, range.end);
        final grammarStyle = _getStyleAtPosition(grammarSegments, range.start);
        final preserveGrammar =
            _isStringOrCommentStyle(grammarStyle) ||
            _hasMeaningfulGrammarStyle(grammarStyle);

        if (preserveGrammar) {
          children.add(TextSpan(text: actualText, style: grammarStyle));
        } else {
          children.add(TextSpan(text: actualText, style: range.style));
        }
      }

      currentPos = range.end;
    }

    if (currentPos < lineText.length) {
      _addGrammarSegments(
        children,
        grammarSegments,
        currentPos,
        lineText.length,
        lineText,
      );
    }

    if (children.isEmpty) {
      return grammarSpan;
    }

    if (children.length == 1) {
      return children.first;
    }

    return TextSpan(style: baseTextStyle, children: children);
  }

  int _scalarToUtf16Index(String text, int scalarOffset) {
    if (scalarOffset <= 0) return 0;
    int utf16 = 0;
    int scalar = 0;
    for (final rune in text.runes) {
      if (scalar >= scalarOffset) break;
      utf16 += rune > 0xFFFF ? 2 : 1;
      scalar++;
    }
    return utf16;
  }

  void _flattenGrammarSpan(
    TextSpan? span,
    List<({String text, TextStyle? style})> segments,
    TextStyle? parentStyle,
  ) {
    if (span == null) return;

    final effectiveStyle = span.style ?? parentStyle;

    if (span.text != null && span.text!.isNotEmpty) {
      segments.add((text: span.text!, style: effectiveStyle));
    }

    if (span.children != null) {
      for (final child in span.children!) {
        if (child is TextSpan) {
          _flattenGrammarSpan(child, segments, effectiveStyle);
        }
      }
    }
  }

  void _addGrammarSegments(
    List<TextSpan> children,
    List<({String text, TextStyle? style})> grammarSegments,
    int startPos,
    int endPos,
    String lineText,
  ) {
    int segmentOffset = 0;
    int addedLength = 0;

    for (final segment in grammarSegments) {
      final segmentStart = segmentOffset;
      final segmentEnd = segmentOffset + segment.text.length;

      if (segmentEnd > startPos && segmentStart < endPos) {
        final overlapStart = segmentStart < startPos
            ? startPos - segmentStart
            : 0;
        final overlapEnd = segmentEnd > endPos
            ? segment.text.length - (segmentEnd - endPos)
            : segment.text.length;

        if (overlapEnd > overlapStart) {
          final text = segment.text.substring(overlapStart, overlapEnd);
          children.add(
            TextSpan(text: text, style: segment.style ?? baseTextStyle),
          );
          addedLength += text.length;
        }
      }

      segmentOffset = segmentEnd;

      if (segmentOffset >= endPos) break;
    }

    final expectedLength = endPos - startPos;
    if (addedLength < expectedLength) {
      final subStart = (startPos + addedLength).clamp(0, lineText.length);
      final subEnd = endPos.clamp(0, lineText.length);
      if (subEnd > subStart) {
        final remaining = lineText.substring(subStart, subEnd);
        if (remaining.isNotEmpty) {
          children.add(TextSpan(text: remaining, style: baseTextStyle));
        }
      }
    }
  }

  TextStyle? _getStyleAtPosition(
    List<({String text, TextStyle? style})> grammarSegments,
    int position,
  ) {
    int offset = 0;
    for (final segment in grammarSegments) {
      final segmentEnd = offset + segment.text.length;
      if (position >= offset && position < segmentEnd) {
        return segment.style;
      }
      offset = segmentEnd;
    }
    return baseTextStyle;
  }

  bool _isStringOrCommentStyle(TextStyle? style) {
    if (style == null) return false;

    final stringStyle = editorTheme['string'];
    final commentStyle = editorTheme['comment'];
    final numberStyle = editorTheme['number'];
    final regexpStyle = editorTheme['regexp'];
    final metaStringStyle = editorTheme['meta-string'];
    final styleColor = style.color;

    if (styleColor == null) return false;
    if (stringStyle?.color == styleColor) return true;
    if (commentStyle?.color == styleColor) return true;
    if (numberStyle?.color == styleColor) return true;
    if (regexpStyle?.color == styleColor) return true;
    if (metaStringStyle?.color == styleColor) return true;

    return false;
  }

  bool _hasMeaningfulGrammarStyle(TextStyle? style) {
    if (style == null) return false;

    final rootStyle = baseTextStyle ?? _resolvedTheme['root'];
    final rootColor = rootStyle?.color;

    if (style.color != null && rootColor != null && style.color != rootColor) {
      return true;
    }
    if (style.fontWeight != null && style.fontWeight != rootStyle?.fontWeight) {
      return true;
    }
    if (style.fontStyle != null && style.fontStyle != rootStyle?.fontStyle) {
      return true;
    }

    return false;
  }

  TextStyle? _resolveSemanticStyle(String? tokenTypeName) {
    if (tokenTypeName == null) return null;

    final hljsKeys = _semanticMapping[tokenTypeName];
    if (hljsKeys == null) return null;

    for (final key in hljsKeys) {
      final style = editorTheme[key];
      final styleFromResolved = _resolvedTheme[key];
      if (styleFromResolved != null) return styleFromResolved;
      if (style != null) return style;
    }

    return null;
  }

  /// Above this many characters a line is painted in the base style instead of
  /// being run through the grammar.
  ///
  /// The grammar costs 1-2ms on an ordinary line of TypeScript declarations
  /// and about 50ms on one of 8,600 characters — and this runs during paint,
  /// for every line of a viewport that is not cached yet. A handful of very
  /// long lines is enough to lose a second on the first render of a file.
  /// Editors that stay responsive on generated code all draw a line like this
  /// somewhere; this one is drawn where an ordinary source line is nowhere
  /// near it.
  static const int maxHighlightedLineLength = 2000;

  TextSpan? _highlightLine(String lineText) {
    if (lineText.isEmpty) return null;
    if (lineText.length > maxHighlightedLineLength) {
      return TextSpan(text: lineText, style: baseTextStyle);
    }

    try {
      final result = _highlight.highlight(code: lineText, language: _langId);
      final renderer = TextSpanRenderer(baseTextStyle, _resolvedTheme);
      result.render(renderer);
      var span = renderer.span;
      if (_isTsxOrJsx && _looksLikeJsxTagLine(lineText)) {
        span = _applyJsxTagFallback(lineText, span);
      }
      return span;
    } catch (e) {
      return TextSpan(text: lineText, style: baseTextStyle);
    }
  }

  bool get _isTsxOrJsx {
    final id = languageId?.toLowerCase().trim();
    return id == 'tsx' || id == 'jsx';
  }

  bool _looksLikeJsxTagLine(String line) {
    return RegExp(r'(^|[^A-Za-z0-9_])<\/?[A-Za-z]').hasMatch(line);
  }

  TextSpan? _applyJsxTagFallback(String lineText, TextSpan? span) {
    if (span == null || lineText.isEmpty) return span;

    final tagStyle =
        _resolvedTheme['tag'] ??
        _resolvedTheme['name'] ??
        _resolvedTheme['selector-tag'];
    if (tagStyle == null) return span;

    final grammarSegments = <({String text, TextStyle? style})>[];
    _flattenGrammarSpan(span, grammarSegments, baseTextStyle);

    final ranges = <({int start, int end})>[];
    final tagOpen = RegExp(
      r'(^|[^A-Za-z0-9_])<\/?\s*([A-Za-z][A-Za-z0-9:_-]*)',
    );

    for (final match in tagOpen.allMatches(lineText)) {
      final prefix = match.group(1) ?? '';
      final leadingStart = match.start + prefix.length;
      if (leadingStart < 0 || leadingStart >= lineText.length) continue;

      final nameGroup = match.group(2);
      if (nameGroup == null) continue;
      final nameStart = match.end - nameGroup.length;
      final nameEnd = match.end;

      ranges.add((
        start: leadingStart,
        end: (nameStart).clamp(leadingStart, lineText.length),
      ));
      ranges.add((start: nameStart, end: nameEnd));

      final closeIndex = lineText.indexOf('>', match.end);
      if (closeIndex != -1) {
        final beforeClose = closeIndex > 0 ? lineText[closeIndex - 1] : '';
        if (beforeClose == '/') {
          ranges.add((start: closeIndex - 1, end: closeIndex));
        }
        ranges.add((start: closeIndex, end: closeIndex + 1));
      }
    }

    if (ranges.isEmpty) return span;

    ranges.sort((a, b) => a.start.compareTo(b.start));

    final mergedRanges = <({int start, int end})>[];
    for (final range in ranges) {
      final start = range.start.clamp(0, lineText.length);
      final end = range.end.clamp(0, lineText.length);
      if (end <= start) continue;

      if (mergedRanges.isEmpty || start > mergedRanges.last.end) {
        mergedRanges.add((start: start, end: end));
      } else {
        final last = mergedRanges.removeLast();
        mergedRanges.add((
          start: last.start,
          end: end > last.end ? end : last.end,
        ));
      }
    }

    final children = <TextSpan>[];
    int current = 0;

    for (final range in mergedRanges) {
      if (range.start > current) {
        _addGrammarSegments(
          children,
          grammarSegments,
          current,
          range.start,
          lineText,
        );
      }

      final existing = _getStyleAtPosition(grammarSegments, range.start);
      final chosen = _hasMeaningfulGrammarStyle(existing) ? existing : tagStyle;
      final part = lineText.substring(range.start, range.end);
      if (part.isNotEmpty) {
        children.add(TextSpan(text: part, style: chosen));
      }
      current = range.end;
    }

    if (current < lineText.length) {
      _addGrammarSegments(
        children,
        grammarSegments,
        current,
        lineText.length,
        lineText,
      );
    }

    return TextSpan(style: baseTextStyle, children: children);
  }

  ui.Paragraph buildHighlightedParagraph(
    int lineIndex,
    String lineText,
    ui.ParagraphStyle paragraphStyle,
    double fontSize,
    String? fontFamily, {
    double? width,
  }) {
    final span = getLineSpan(lineIndex, lineText);
    final builder = ui.ParagraphBuilder(paragraphStyle);

    if (span == null || lineText.isEmpty) {
      final style = _getUiTextStyle(null, fontSize, fontFamily);
      builder.pushStyle(style);
      builder.addText(lineText.isEmpty ? ' ' : lineText);
      final p = builder.build();
      p.layout(ui.ParagraphConstraints(width: width ?? double.infinity));
      return p;
    }

    _addTextSpanToBuilder(builder, span, fontSize, fontFamily);

    final p = builder.build();
    p.layout(ui.ParagraphConstraints(width: width ?? double.infinity));
    return p;
  }

  void _addTextSpanToBuilder(
    ui.ParagraphBuilder builder,
    TextSpan span,
    double fontSize,
    String? fontFamily,
  ) {
    final style = _textStyleToUiStyle(span.style, fontSize, fontFamily);
    builder.pushStyle(style);

    if (span.text != null) {
      builder.addText(span.text!);
    }

    if (span.children != null) {
      for (final child in span.children!) {
        if (child is TextSpan) {
          _addTextSpanToBuilder(builder, child, fontSize, fontFamily);
        }
      }
    }

    builder.pop();
  }

  ui.TextStyle _textStyleToUiStyle(
    TextStyle? style,
    double fontSize,
    String? fontFamily,
  ) {
    final baseStyle = style ?? baseTextStyle ?? editorTheme['root'];

    return ui.TextStyle(
      color: baseStyle?.color ?? editorTheme['root']?.color ?? Colors.black,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontWeight: baseStyle?.fontWeight,
      fontStyle: baseStyle?.fontStyle,
    );
  }

  ui.TextStyle _getUiTextStyle(
    String? className,
    double fontSize,
    String? fontFamily,
  ) {
    final themeStyle = className != null ? editorTheme[className] : null;
    final baseStyle = themeStyle ?? baseTextStyle ?? editorTheme['root'];

    return ui.TextStyle(
      color: baseStyle?.color ?? editorTheme['root']?.color ?? Colors.black,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontWeight: baseStyle?.fontWeight,
      fontStyle: baseStyle?.fontStyle,
    );
  }

  /// Warms the grammar cache for a range of lines, off the paint path.
  ///
  /// Answers whether it actually highlighted anything, so a caller that
  /// repaints when the cache grows does not repaint when it did not — which
  /// would be a repaint every frame, forever.
  Future<bool> preHighlightLines(
    int startLine,
    int endLine,
    String Function(int) getLineText,
  ) async {
    if (_preHighlightInFlight != null &&
        _preHighlightInFlightVersion == _version) {
      await _preHighlightInFlight;
      // Someone else's pass; it repaints for what it warmed.
      return false;
    }

    final requestVersion = _version;
    _preHighlightInFlightVersion = requestVersion;
    final future = _preHighlightLinesInternal(
      startLine,
      endLine,
      getLineText,
      requestVersion,
    );
    _preHighlightInFlight = future;

    try {
      return await future;
    } finally {
      if (identical(_preHighlightInFlight, future)) {
        _preHighlightInFlight = null;
        _preHighlightInFlightVersion = -1;
      }
    }
  }

  Future<bool> _preHighlightLinesInternal(
    int startLine,
    int endLine,
    String Function(int) getLineText,
    int requestVersion,
  ) async {
    _pruneCachesForViewport(startLine, endLine);

    final linesToProcess = <int, String>{};

    for (int i = startLine; i <= endLine; i++) {
      final lineText = getLineText(i);
      final cached = _grammarCache[i];
      if (cached == null ||
          cached.text != lineText ||
          cached.version != _version) {
        linesToProcess[i] = lineText;
      }
    }

    if (linesToProcess.isEmpty) return false;

    if (linesToProcess.length < 50) {
      if (requestVersion != _version) return false;
      for (final entry in linesToProcess.entries) {
        if (requestVersion != _version) return false;
        final span = _highlightLine(entry.value);
        _grammarCache[entry.key] = HighlightedLine(entry.value, span, _version);
      }
      return true;
    }

    final Map<int, _SpanData?> results;
    try {
      results = await compute(
        _highlightLinesInBackground,
        _BackgroundHighlightData(
          langId: _langId,
          lines: linesToProcess,
          languageMode: language,
          extraLanguages: _registeredExtraLanguages,
          theme: _resolvedTheme,
          baseStyle: baseTextStyle,
        ),
      );
    } catch (_) {
      // Whatever went wrong with the isolate, uncoloured text is not the
      // answer: do the work here instead.
      if (requestVersion != _version) return false;
      for (final entry in linesToProcess.entries) {
        if (requestVersion != _version) return false;
        _grammarCache[entry.key] = HighlightedLine(
          entry.value,
          _highlightLine(entry.value),
          _version,
        );
      }
      return true;
    }

    if (requestVersion != _version) return false;

    for (final entry in results.entries) {
      final spanData = entry.value;
      final textSpan = spanData != null ? _spanDataToTextSpan(spanData) : null;
      _grammarCache[entry.key] = HighlightedLine(
        linesToProcess[entry.key]!,
        textSpan,
        requestVersion,
      );
    }

    _pruneCachesForViewport(startLine, endLine);
    return true;
  }

  void _pruneCachesForViewport(int startLine, int endLine) {
    final minKeep = (startLine - _cacheKeepMargin).clamp(0, 1 << 30);
    final maxKeep = endLine + _cacheKeepMargin;

    if (_grammarCache.length > _maxLineCacheEntries) {
      _grammarCache.removeWhere((line, _) => line < minKeep || line > maxKeep);
    }

    if (_mergedCache.length > _maxLineCacheEntries) {
      _mergedCache.removeWhere((line, _) => line < minKeep || line > maxKeep);
    }

    // `_lineSemanticSpans` is deliberately not pruned. The two maps above are
    // caches — drop an entry and the next paint rebuilds it from the grammar —
    // but this one *is* the server's answer, and nothing can rebuild it: the
    // client only asks again when the document changes, and a server answering
    // for the whole document answers once. Pruning it took the colouring off
    // every line more than [_cacheKeepMargin] away and never put it back, so
    // scrolling a large file through a screenful and back left what had been
    // classified plain. It is not the copy that costs, either: the whole token
    // list is held above this, for exactly as long.
    if (_lineSpanCache.length > _maxSpanCacheEntries) {
      _lineSpanCache.clear();
    }
  }

  TextSpan? _spanDataToTextSpan(_SpanData? data) {
    if (data == null) return null;

    if (data.children.isEmpty) {
      return TextSpan(text: data.text, style: data.style ?? baseTextStyle);
    }

    return TextSpan(
      text: data.text.isEmpty ? null : data.text,
      style: data.style,
      children: data.children.map((c) => _spanDataToTextSpan(c)!).toList(),
    );
  }

  Map<String, TextStyle> _buildResolvedTheme(Map<String, TextStyle> theme) {
    final resolved = Map<String, TextStyle>.from(theme);

    if (!resolved.containsKey('tag')) {
      final fallbackTagStyle = resolved['selector-tag'] ?? resolved['name'];
      if (fallbackTagStyle != null) {
        resolved['tag'] = fallbackTagStyle;
      }
    }

    return resolved;
  }

  void dispose() {
    _grammarCache.clear();
    _mergedCache.clear();
    _lineSemanticSpans.clear();
    _lineSpanCache.clear();
  }
}

class _BackgroundHighlightData {
  final String langId;
  final Map<int, String> lines;
  final Mode languageMode;
  final List<Mode> extraLanguages;
  final Map<String, TextStyle> theme;
  final TextStyle? baseStyle;

  _BackgroundHighlightData({
    required this.langId,
    required this.lines,
    required this.languageMode,
    required this.extraLanguages,
    required this.theme,
    this.baseStyle,
  });
}

Map<int, _SpanData?> _highlightLinesInBackground(
  _BackgroundHighlightData data,
) {
  final highlight = Highlight();
  highlight.registerLanguage(data.langId, data.languageMode);
  for (final lang in data.extraLanguages) {
    _registerLanguageWithAliases(highlight, lang);
  }

  final results = <int, _SpanData?>{};

  for (final entry in data.lines.entries) {
    final lineIndex = entry.key;
    final lineText = entry.value;

    if (lineText.isEmpty) {
      results[lineIndex] = null;
      continue;
    }

    try {
      final result = highlight.highlight(code: lineText, language: data.langId);
      final renderer = TextSpanRenderer(data.baseStyle, data.theme);
      result.render(renderer);
      final span = renderer.span;
      results[lineIndex] = span != null ? _textSpanToSpanData(span) : null;
    } catch (e) {
      results[lineIndex] = _SpanData(lineText, data.baseStyle);
    }
  }

  return results;
}

void _registerLanguageWithAliases(Highlight highlight, Mode language) {
  if (language.name == null) return;

  final normalizedName = language.name!.toLowerCase().trim();
  highlight.registerLanguage(normalizedName, language);

  for (final token in normalizedName.split(RegExp(r'[^a-z0-9_+#-]+'))) {
    if (token.isNotEmpty) {
      highlight.registerLanguage(token, language);
    }
  }

  for (final alias in language.aliases ?? const <String>[]) {
    final normalizedAlias = alias.toLowerCase();
    highlight.registerLanguage(normalizedAlias, language);
  }
}

_SpanData _textSpanToSpanData(TextSpan span) {
  final children = <_SpanData>[];

  if (span.children != null) {
    for (final child in span.children!) {
      if (child is TextSpan) {
        children.add(_textSpanToSpanData(child));
      }
    }
  }

  return _SpanData(span.text ?? '', span.style, children);
}
