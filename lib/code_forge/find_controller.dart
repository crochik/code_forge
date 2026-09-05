import 'dart:collection';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'styling.dart';

/// One occurrence of the current query, and where it is in the document.
///
/// A plain `Match` is tied to the string it was run against, which goes stale
/// the moment the buffer changes. This carries only the offsets, so a host can
/// hold on to one across a rebuild.
@immutable
class FindMatch {
  const FindMatch({required this.start, required this.end, required this.text});

  /// Character offset of the first character of the match.
  final int start;

  /// Character offset one past the last character of the match.
  final int end;

  /// The matched text itself.
  final String text;

  /// The line the match starts on, and where on it, counted from zero.
  ///
  /// Derived on demand rather than stored: a query like `e` can match tens of
  /// thousands of times, and a list only ever shows the rows on screen.
  ({int line, int column, String lineText}) locate(
    CodeForgeController controller,
  ) {
    final line = controller.getLineAtOffset(start);
    final lineStart = controller.getLineStartOffset(line);
    return (
      line: line,
      column: start - lineStart,
      lineText: controller.getLineText(line),
    );
  }
}

/// Controller for managing text search functionality in [CodeForge].
///
/// This controller handles searching for text, navigating through matches,
/// and highlighting results in the editor.
class FindController extends ChangeNotifier {
  final CodeForgeController _codeController;

  List<FindMatch> _matches = [];
  int _currentMatchIndex = -1;
  bool _isRegex = false;
  bool _caseSensitive = false;
  bool _matchWholeWord = false;
  bool _hasPatternError = false;
  String _lastQuery = '';
  bool _isActive = false;
  bool _isReplaceMode = false;

  String _lastText = '';
  VoidCallback? _controllerListener;

  final TextEditingController findInputController = TextEditingController();
  final TextEditingController replaceInputController = TextEditingController();
  final FocusNode findInputFocusNode = FocusNode();
  final FocusNode replaceInputFocusNode = FocusNode();

  /// Creates a [FindController] associated with the given [CodeForgeController].
  FindController(this._codeController) {
    _lastText = _codeController.text;
    _controllerListener = _onCodeControllerChanged;
    _codeController.addListener(_controllerListener!);
    findInputController.addListener(_onFindInputChanged);
  }

  void _onFindInputChanged() {
    find(findInputController.text);
  }

  @override
  void dispose() {
    if (_controllerListener != null) {
      _codeController.removeListener(_controllerListener!);
    }
    findInputController.removeListener(_onFindInputChanged);
    findInputController.dispose();
    replaceInputController.dispose();
    findInputFocusNode.dispose();
    replaceInputFocusNode.dispose();
    super.dispose();
  }

  void _onCodeControllerChanged() {
    if (!_isActive && _lastQuery.isEmpty) return;
    final currentText = _codeController.text;
    if (currentText != _lastText) {
      _lastText = currentText;
      _reperformSearch();
    }
  }

  /// The editor this finder searches.
  CodeForgeController get codeController => _codeController;

  /// Every occurrence of the current query, in document order.
  ///
  /// A view, not a copy: a list of matches can be very long, and a panel
  /// showing it reads the getter once per row it paints.
  List<FindMatch> get matches => UnmodifiableListView(_matches);

  /// The number of matches found for the current query.
  int get matchCount => _matches.length;

  /// The current match index (0-based) or -1 if no match is selected.
  int get currentMatchIndex => _currentMatchIndex;

  /// The current match, or null when there is none.
  FindMatch? get currentMatch =>
      _currentMatchIndex >= 0 && _currentMatchIndex < _matches.length
      ? _matches[_currentMatchIndex]
      : null;

  /// The query the matches were found with.
  String get query => _lastQuery;

  /// Whether the query is a regular expression the engine could not compile.
  ///
  /// Only ever true in regex mode, and it is the difference between "no
  /// results" and "that pattern does not parse" — which the finder's own
  /// display cannot otherwise tell apart.
  bool get hasPatternError => _hasPatternError;

  /// The case sensitivity of the search.
  bool get caseSensitive => _caseSensitive;

  /// Whether the search uses regular expressions.
  bool get isRegex => _isRegex;

  /// Whether the search matches whole words only.
  bool get matchWholeWord => _matchWholeWord;

  /// Whether the finder is currently active/visible.
  bool get isActive => _isActive;

  /// Whether the replace mode is active.
  bool get isReplaceMode => _isReplaceMode;

  /// Sets the case sensitivity of the search.
  set caseSensitive(bool value) {
    if (_caseSensitive == value) return;
    _caseSensitive = value;
    _reperformSearch();
    notifyListeners();
  }

  /// Sets whether the search uses regular expressions.
  set isRegex(bool value) {
    if (_isRegex == value) return;
    _isRegex = value;
    _reperformSearch();
    notifyListeners();
  }

  /// Sets whether the search matches whole words only.
  set matchWholeWord(bool value) {
    if (_matchWholeWord == value) return;
    _matchWholeWord = value;
    _reperformSearch();
    notifyListeners();
  }

  /// Sets whether the finder is currently active/visible.
  set isActive(bool value) {
    if (_isActive == value) return;
    _isActive = value;
    if (_isActive) {
      Future.microtask(() => findInputFocusNode.requestFocus());
      if (_lastQuery.isNotEmpty) {
        _reperformSearch();
      }
    } else {
      _clearMatches();
    }
    notifyListeners();
  }

  /// Sets whether the replace mode is active.
  set isReplaceMode(bool value) {
    if (_isReplaceMode == value) return;
    _isReplaceMode = value;
    notifyListeners();
  }

  /// Opens the finder and puts the caret in its field.
  ///
  /// [seedFromSelection] takes the editor's selection as the query, which is
  /// what makes "find the thing I just highlighted" a single keystroke. A
  /// selection spanning lines is never that, so it is left alone.
  ///
  /// The query is left selected rather than merely focused, so the next thing
  /// typed replaces it instead of landing on the end of it.
  void open({bool replace = false, bool seedFromSelection = true}) {
    if (seedFromSelection) {
      final selection = _codeController.selection;
      if (!selection.isCollapsed) {
        final text = _codeController.text;
        final start = selection.start.clamp(0, text.length);
        final end = selection.end.clamp(start, text.length);
        final selected = text.substring(start, end);
        if (selected.isNotEmpty && !selected.contains('\n')) {
          findInputController.text = selected;
        }
      }
    }

    isActive = true;
    isReplaceMode = replace;
    findInputFocusNode.requestFocus();
    findInputController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: findInputController.text.length,
    );
  }

  /// Closes the finder and puts the caret back where the user was typing.
  void close() {
    isActive = false;
    isReplaceMode = false;
    _codeController.focusNode?.requestFocus();
  }

  void toggleReplaceMode() {
    isReplaceMode = !isReplaceMode;
  }

  void toggleActive() {
    isActive = !isActive;
  }

  void toggleCaseSensitive() {
    caseSensitive = !caseSensitive;
  }

  void toggleRegex() {
    isRegex = !isRegex;
  }

  void toggleMatchWholeWord() {
    matchWholeWord = !matchWholeWord;
  }

  void _reperformSearch() {
    if (_lastQuery.isNotEmpty) {
      find(_lastQuery, scrollToMatch: false);
    }
  }

  /// The query as a regular expression, or null if it does not compile.
  RegExp? _compile(String query) {
    var pattern = _isRegex ? query : RegExp.escape(query);
    if (_matchWholeWord) {
      // Grouped, or the boundaries would bind to the first and last branch of
      // an alternation: `\ba|b\b` asks for `a` at a word start *or* `b` at a
      // word end, which is not what `a|b` as a whole word means. Non-capturing,
      // so the pattern's own group numbers are untouched.
      pattern = r'\b(?:' + pattern + r')\b';
    }
    try {
      return RegExp(pattern, caseSensitive: _caseSensitive, multiLine: true);
    } on FormatException {
      return null;
    }
  }

  /// Performs a text search.
  ///
  /// [query] is the text to search for.
  /// [scrollToMatch] determines if the editor should scroll to the selected match.
  void find(String query, {bool scrollToMatch = true}) {
    _lastQuery = query;

    if (query.isEmpty) {
      _hasPatternError = false;
      _clearMatches();
      return;
    }

    final regExp = _compile(query);
    if (regExp == null) {
      _hasPatternError = true;
      _matches = [];
      _currentMatchIndex = -1;
      _updateHighlights();
      return;
    }
    _hasPatternError = false;

    final text = _codeController.text;
    _matches = [
      for (final match in regExp.allMatches(text))
        FindMatch(
          start: match.start,
          end: match.end,
          text: text.substring(match.start, match.end),
        ),
    ];

    if (_matches.isEmpty) {
      _currentMatchIndex = -1;
      _updateHighlights();
      return;
    }

    // The match the caret is sitting on or before — which, after an edit or a
    // replacement, is the one the user is looking at.
    final cursor = _codeController.selection.start;
    _currentMatchIndex = _matches.indexWhere((match) => match.start >= cursor);
    if (_currentMatchIndex < 0) _currentMatchIndex = 0;

    _updateHighlights();

    if (scrollToMatch) {
      _scrollToCurrentMatch();
    }
  }

  /// Moves to the next match, wrapping past the last one.
  void next() {
    if (_matches.isEmpty) return;
    _currentMatchIndex = (_currentMatchIndex + 1) % _matches.length;
    _scrollToCurrentMatch();
    _updateHighlights();
  }

  /// Moves to the previous match, wrapping past the first one.
  void previous() {
    if (_matches.isEmpty) return;
    _currentMatchIndex =
        (_currentMatchIndex - 1 + _matches.length) % _matches.length;
    _scrollToCurrentMatch();
    _updateHighlights();
  }

  /// Leaves the current match alone and moves to the next one.
  ///
  /// The same thing [next] does; named for the replace-one-by-one loop, where
  /// "skip this one" is the action the user has in mind.
  void skip() => next();

  /// Selects the match at [index] and scrolls it into view.
  void goToMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    _currentMatchIndex = index;
    _scrollToCurrentMatch();
    _updateHighlights();
  }

  /// Clears search results and highlights.
  void clear() {
    _lastQuery = '';
    _hasPatternError = false;
    _clearMatches();
  }

  /// Replaces the currently selected match with the text in
  /// [replaceInputController], and moves to the next one.
  ///
  /// Advancing is what makes a replace-one-by-one loop possible from a single
  /// button: replace, replace, skip, replace. It falls out of the search being
  /// redone against the new text — the caret lands after the replacement, and
  /// the first match at or after the caret is the next one.
  void replace() {
    final match = currentMatch;
    if (match == null) return;

    _codeController.replaceRange(
      match.start,
      match.end,
      replaceInputController.text,
    );
    // The edit re-ran the search through [_onCodeControllerChanged], which
    // leaves the index on the following match but does not move the view.
    _scrollToCurrentMatch();
    notifyListeners();
  }

  /// Replaces every match with the text in [replaceInputController].
  ///
  /// Built from the matches that are highlighted rather than by running the
  /// pattern again, so what disappears is exactly what was on screen. It lands
  /// as one edit: one entry in the undo history, one message to the language
  /// server.
  void replaceAll() {
    if (_matches.isEmpty) return;

    final text = _codeController.text;
    final replacement = replaceInputController.text;

    final rewritten = StringBuffer();
    var copiedTo = 0;
    for (final match in _matches) {
      // Overlapping matches cannot come out of `allMatches`, but a stale list
      // could outlive an edit; skipping keeps the output well-formed either way.
      if (match.start < copiedTo || match.end > text.length) continue;
      rewritten
        ..write(text.substring(copiedTo, match.start))
        ..write(replacement);
      copiedTo = match.end;
    }
    rewritten.write(text.substring(copiedTo));

    // Where the caret was, in the text that is about to exist. Replacing the
    // whole document would otherwise leave it at the end of the file.
    final caret = _codeController.selection.baseOffset.clamp(0, text.length);
    var shift = 0;
    for (final match in _matches) {
      if (match.end > caret) break;
      shift += replacement.length - (match.end - match.start);
    }

    _codeController.replaceRange(0, text.length, rewritten.toString());
    _codeController.selection = TextSelection.collapsed(
      offset: (caret + shift).clamp(0, _codeController.length),
    );
    notifyListeners();
  }

  void _clearMatches() {
    _matches = [];
    _currentMatchIndex = -1;
    _codeController.searchHighlights = [];
    _codeController.searchHighlightsChanged = true;
    _codeController.notifyListeners();
    notifyListeners();
  }

  void _scrollToCurrentMatch() {
    final match = currentMatch;
    if (match == null) return;

    final matchLine = _codeController.getLineAtOffset(match.start);
    _codeController.setSelectionSilently(
      TextSelection.collapsed(offset: match.start),
    );

    try {
      _codeController.scrollToLine(matchLine);
    } on Object {
      // No editor laid out yet, or the line went out from under the match
      // between the search and this. Either way the caret is already right.
    }
  }

  void _updateHighlights() {
    _codeController.searchHighlights = [
      for (var i = 0; i < _matches.length; i++)
        SearchHighlight(
          start: _matches[i].start,
          end: _matches[i].end,
          isCurrentMatch: i == _currentMatchIndex,
        ),
    ];
    _codeController.searchHighlightsChanged = true;
    _codeController.notifyListeners();
    notifyListeners();
  }
}
