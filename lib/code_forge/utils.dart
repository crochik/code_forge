import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Represents a foldable code region in the editor.
///
/// A fold range defines a region of code that can be collapsed (folded) to hide
/// its contents. This is typically used for code blocks like functions, classes,
/// or control structures.
///
/// Fold ranges are automatically detected based on code structure (braces,
/// indentation) when folding is enabled in the editor.
///
/// Example:
/// ```dart
/// // A fold range from line 5 to line 10
/// final foldRange = FoldRange(5, 10);
/// foldRange.isFolded = true; // Collapse the region
/// ```
class FoldRange {
  /// The starting line index (zero-based) of the fold range.
  ///
  /// This is the line where the fold indicator appears in the gutter.
  final int startIndex;

  /// The ending line index (zero-based) of the fold range.
  ///
  /// When folded, all lines from `startIndex + 1` to `endIndex` are hidden.
  final int endIndex;

  /// Whether this fold range is currently collapsed.
  ///
  /// When true, the contents of this range are hidden in the editor.
  bool isFolded = false;

  /// Child fold ranges that were originally folded when this range was unfolded.
  ///
  /// Used to restore the fold state of nested ranges when toggling folds.
  List<FoldRange> originallyFoldedChildren = [];

  /// Creates a [FoldRange] with the specified start and end line indices.
  FoldRange(this.startIndex, this.endIndex);

  /// Adds a child fold range that was originally folded.
  ///
  /// Used internally to track nested fold states.
  void addOriginallyFoldedChild(FoldRange child) {
    if (!originallyFoldedChildren.contains(child)) {
      originallyFoldedChildren.add(child);
    }
  }

  /// Clears the list of originally folded children.
  void clearOriginallyFoldedChildren() {
    originallyFoldedChildren.clear();
  }

  /// Checks if a line is contained within this fold range.
  ///
  /// Returns true if [line] is strictly greater than [startIndex] and
  /// less than or equal to [endIndex].
  bool containsLine(int line) {
    return line > startIndex && line <= endIndex;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FoldRange &&
        other.startIndex == startIndex &&
        other.endIndex == endIndex;
  }

  @override
  int get hashCode => startIndex.hashCode ^ endIndex.hashCode;
}

/// Custom scroll physics that reverses horizontal drag direction for RTL mode on mobile.
class RTLAwareScrollPhysics extends ClampingScrollPhysics {
  final bool isRTL;
  final bool isMobile;

  const RTLAwareScrollPhysics({
    super.parent,
    required this.isRTL,
    required this.isMobile,
  });

  @override
  RTLAwareScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return RTLAwareScrollPhysics(
      parent: buildParent(ancestor),
      isRTL: isRTL,
      isMobile: isMobile,
    );
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (isRTL && isMobile && position.axis == Axis.horizontal) {
      return super.applyPhysicsToUserOffset(position, -offset);
    }
    return super.applyPhysicsToUserOffset(position, offset);
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (isRTL && isMobile && position.axis == Axis.horizontal) {
      return super.createBallisticSimulation(position, -velocity);
    }
    return super.createBallisticSimulation(position, velocity);
  }
}

/// Use the [GutterBuilder] to render custom content in the gutter.
/// eg:
/// ```dart
/// CodeForge(
///   gutterBuilder: GutterBuilder(
///     builder: (lineNumber, lineText) => if(lineNumber == 1) "[HEADER]" : null
///   )
/// )
/// ```
///
/// Result:
///
/// ```python
/// [HEADER]|   import os
///    2    |   import sys
///    3    |
///    4    |   def main():
///    5    |        pass
/// ```
/// -------------------------------------------------------------
///
/// To exclude the index from modified content. Set [includeReplacedIndex] to false.
/// <br> eg:
/// ```dart
/// CodeForge(
///   gutterBuilder: GutterBuilder(
///     includeReplacedIndex: false,
///     builder: (lineNumber, lineText) => if(lineNumber == 1) "[HEADER]" : null
///   )
/// )
/// ```
///
/// Result:
/// ```python
/// [HEADER]|   import os
///    1    |   import sys
///    2    |
///    3    |   def main():
///    4    |        pass
/// ```
class GutterBuilder {
  /// Builder that builds the custom gutter content.
  /// Takes the int lineNumber and String lineText parameters and returns the custom
  /// string content for the corresponding line.
  final String? Function(int, String) builder;

  /// To exclude the index from modified content. Set [includeReplacedIndex] to false.
  /// <br> eg:
  /// ```dart
  /// CodeForge(
  ///   gutterBuilder: GutterBuilder(
  ///     includeReplacedIndex: false,
  ///     builder: (lineNumber, lineText) => if(lineNumber == 1) "[HEADER]" : null
  ///   )
  /// )
  /// ```
  ///
  /// Result:
  /// ```python
  /// [HEADER]|   import os
  ///    1    |   import sys  # index `1` is included in the gutter.
  ///    2    |
  ///    3    |   def main():
  ///    4    |        pass
  /// ```
  final bool includeReplacedIndex;

  GutterBuilder({required this.builder, this.includeReplacedIndex = true});
}

/// Accepts when any of [alternatives] does.
///
/// One action, more than one way to press it. A [SingleActivator] matches an
/// exact set of modifiers, so "Control + Home, or ⌘ + Up on a Mac" cannot be
/// written as one — and writing it as two fields would make every caller
/// check both.
class AnyShortcut implements ShortcutActivator {
  const AnyShortcut(this.alternatives);

  /// The spellings of this shortcut. Order carries no meaning.
  final List<ShortcutActivator> alternatives;

  @override
  Iterable<LogicalKeyboardKey>? get triggers => [
    for (final alternative in alternatives) ...?alternative.triggers,
  ];

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      alternatives.any((alternative) => alternative.accepts(event, state));

  @override
  String debugDescribeKeys() =>
      alternatives.map((a) => a.debugDescribeKeys()).join(' or ');
}

/// A spelling that only applies on macOS.
///
/// ⌘ with an arrow is how macOS says "start of the document" and "start of the
/// line". The same combination elsewhere is the window manager's — Super +
/// Arrow tiles a window — so binding it everywhere would take a key the editor
/// has no business taking.
class MacShortcut implements ShortcutActivator {
  const MacShortcut(this.activator);

  /// What to accept when running on macOS.
  final ShortcutActivator activator;

  @override
  Iterable<LogicalKeyboardKey>? get triggers => activator.triggers;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      defaultTargetPlatform == TargetPlatform.macOS &&
      activator.accepts(event, state);

  @override
  String debugDescribeKeys() => '${activator.debugDescribeKeys()} (macOS)';
}

/// Keyboard shortcuts used by the [CodeForge].
/// Ovrride to use your own custom shortcuts.
/// <br>
/// Defaults to:
/// ```dart
/// CodeForgeKeyboardShotcuts({
///   this.duplicate = const SingleActivator(LogicalKeyboardKey.keyD, control: true),
///   this.shiftLineUp = const SingleActivator(LogicalKeyboardKey.arrowUp, control: true, shift: true),
///   this.shiftLineDown= const SingleActivator(LogicalKeyboardKey.arrowDown, control: true),
///   this.deletWordBackward = const SingleActivator(LogicalKeyboardKey.backspace, control: true),
///   this.deletWordForward = const SingleActivator(LogicalKeyboardKey.delete, control: true),
///   this.moveCursorToNextWord = const SingleActivator(LogicalKeyboardKey.arrowRight, control: true),
///   this.moveCursorToPreviousWord = const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true),
///   this.moveSelectionToNextWord = const SingleActivator(LogicalKeyboardKey.arrowRight, control: true, shift: true),
///   this.moveSelectionToPreviousWord = const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true, shift: true),
///   this.lspCodeActions = const SingleActivator(LogicalKeyboardKey.period, control: true),
///   this.lspSignature = const SingleActivator(LogicalKeyboardKey.space, control: true, shift: true),
///   this.showFindBar = const SingleActivator(LogicalKeyboardKey.keyF, control: true),
///   this.showSearchAndReplaceBar = const SingleActivator(LogicalKeyboardKey.keyH, control: true),
/// });
/// ```
///
/// Note: The LSP inlay hints shortcut `(Ctrl + Alt)` is not modifiable.<br>
/// Also, core operations like cut, copy, paste, select all, undo, redo aren't modifiable.
class CodeForgeKeyboardShortcuts {
  /// Place the cursor at the start of the document.
  /// Defaults to `Ctrl + home`, or `⌘ + arrowUp` on macOS.
  final ShortcutActivator jumpToDocumentStart;

  /// Place the cursor at the end of the document.
  /// Defaults to `Ctrl + end`, or `⌘ + arrowDown` on macOS.
  final ShortcutActivator jumpToDocumentEnd;

  /// Similar to [jumpToDocumentStart], place the cursor at the start of the
  /// document and select the text from the start position to it.
  /// Defaults to `Ctrl + Shift + home`, or `⌘ + Shift + arrowUp` on macOS.
  final ShortcutActivator jumpToDocumentStartAndSelectText;

  /// Similar to [jumpToDocumentEnd], place the cursor at the end of the
  /// document and select the text from the start position to it.
  /// Defaults to `Ctrl + Shift + end`, or `⌘ + Shift + arrowDown` on macOS.
  final ShortcutActivator jumpToDocumentEndAndSelectText;

  /// Place the cursor at the start of the current line.
  /// Defaults to `home`, or `⌘ + arrowLeft` on macOS.
  final ShortcutActivator jumpToLineStart;

  /// Place the cursor at the end of the current line.
  /// Defaults to `end`, or `⌘ + arrowRight` on macOS.
  final ShortcutActivator jumpToLineEnd;

  /// Move the cursor a page up, keeping its column.
  /// Defaults to `pageUp` — `Fn + arrowUp` on a Mac keyboard without one.
  final ShortcutActivator pageUp;

  /// Move the cursor a page down, keeping its column.
  /// Defaults to `pageDown` — `Fn + arrowDown` on a Mac keyboard without one.
  final ShortcutActivator pageDown;

  /// Similar to [pageUp], extending the selection to where it lands.
  /// Defaults to `Shift + pageUp`.
  final ShortcutActivator selectPageUp;

  /// Similar to [pageDown], extending the selection to where it lands.
  /// Defaults to `Shift + pageDown`.
  final ShortcutActivator selectPageDown;

  /// Duplicate the selection, if no active selectio, current line gets duplicated.
  /// Defaults to `Ctrl + D`
  final ShortcutActivator duplicate;

  /// Moves the current line upwards.
  /// Defaults to `Ctrl + Shift + arrowUp`
  final ShortcutActivator shiftLineUp;

  /// Moves the current line downwards.
  /// Defaults to `Ctrl + Shift + arrowUp`
  final ShortcutActivator shiftLineDown;

  /// Delete an entire word and moves the cursor backward.
  /// Defaults to `Ctrl + backspace`
  final ShortcutActivator deletWordBackward;

  /// Delete an entore word and moves the cursor forward.
  /// Defaults to `Ctrl + delete`
  final ShortcutActivator deletWordForward;

  /// Cursor jumps to the previous word.
  /// Defaults to `Ctrl + arrowLeft`
  final ShortcutActivator moveCursorToPreviousWord;

  /// Cursor jumps to the next word.
  /// Defaults to `Ctrl + arrowRight`
  final ShortcutActivator moveCursorToNextWord;

  /// Similar to [moveCursorToPreviousWord], but selection also jumps with the cursor.
  /// Defaults to `Ctrl + Shift + arrowLeft`
  final ShortcutActivator moveSelectionToPreviousWord;

  /// Extends the selection forward by one character at a time.
  /// Defaults to `Shift + arrowRight`
  final ShortcutActivator moveSelectionForward;

  /// Extends the selection backward by one character at a time.
  /// Defaults to `Shift + arrowLeft
  final ShortcutActivator moveSelectionBackward;

  /// Extends the text selection to upward lines.
  /// Defaults tp `Shift + arrowUp`.
  final ShortcutActivator moveSelectionUpward;

  /// Extends the text selection to downward lines.
  /// Defaults tp `Shift + arrowDown`.
  final ShortcutActivator moveSelectionDownward;

  /// Similar to [moveCursorToNextWord], but selection also jumps with the cursor.
  /// Defaults to `Ctrl + Shift + arrowRight`
  final ShortcutActivator moveSelectionToNextWord;

  /// Shows the [LSP code actions](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_codeAction) if available.
  /// Defaults to `Ctrl + .`
  final ShortcutActivator lspCodeActions;

  /// Shows [LSP signature help](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_signatureHelp) if available.
  /// Defaults to `Ctrl + Shift + space`
  final ShortcutActivator lspSignatureHelp;

  /// Show the word finder bar if provided.
  /// Defaults to `Ctrl + F`
  final ShortcutActivator showFindBar;

  /// Show the finder bar along with the replace bar.
  /// Defaults to `Ctrl + H`
  final ShortcutActivator showFindAndReplaceBar;

  /// Jumps the cursor to the start of the current line by selecting the line text.
  /// Defaults to `Shift + home`.
  final ShortcutActivator selectToLineStart;

  /// Jumps the cursor to the end of the current line by selecting the line text.
  /// Defaults to `Shift + end`.
  final ShortcutActivator selectToLineEnd;

  /// Creates mutlicursor to the same column and downward rows/lines.
  final ShortcutActivator extendMutliCursorDownward;

  /// Creates mutlicursor to the same column and upward rows/lines.
  final ShortcutActivator extendMutliCursorUpward;

  const CodeForgeKeyboardShortcuts({
    this.duplicate = const SingleActivator(
      LogicalKeyboardKey.keyD,
      control: true,
    ),
    this.shiftLineUp = const SingleActivator(
      LogicalKeyboardKey.arrowUp,
      control: true,
      shift: true,
    ),
    this.shiftLineDown = const SingleActivator(
      LogicalKeyboardKey.arrowDown,
      control: true,
      shift: true,
    ),
    this.deletWordBackward = const SingleActivator(
      LogicalKeyboardKey.backspace,
      control: true,
    ),
    this.deletWordForward = const SingleActivator(
      LogicalKeyboardKey.delete,
      control: true,
    ),
    this.moveCursorToNextWord = const SingleActivator(
      LogicalKeyboardKey.arrowRight,
      control: true,
    ),
    this.moveCursorToPreviousWord = const SingleActivator(
      LogicalKeyboardKey.arrowLeft,
      control: true,
    ),
    this.moveSelectionToNextWord = const SingleActivator(
      LogicalKeyboardKey.arrowRight,
      control: true,
      shift: true,
    ),
    this.moveSelectionToPreviousWord = const SingleActivator(
      LogicalKeyboardKey.arrowLeft,
      control: true,
      shift: true,
    ),
    this.moveSelectionUpward = const SingleActivator(
      LogicalKeyboardKey.arrowUp,
      shift: true,
    ),
    this.moveSelectionDownward = const SingleActivator(
      LogicalKeyboardKey.arrowDown,
      shift: true,
    ),
    this.moveSelectionForward = const SingleActivator(
      LogicalKeyboardKey.arrowRight,
      shift: true,
    ),
    this.moveSelectionBackward = const SingleActivator(
      LogicalKeyboardKey.arrowLeft,
      shift: true,
    ),
    this.lspCodeActions = const SingleActivator(
      LogicalKeyboardKey.period,
      control: true,
    ),
    this.lspSignatureHelp = const SingleActivator(
      LogicalKeyboardKey.space,
      control: true,
      shift: true,
    ),
    this.showFindBar = const SingleActivator(
      LogicalKeyboardKey.keyF,
      control: true,
    ),
    this.showFindAndReplaceBar = const SingleActivator(
      LogicalKeyboardKey.keyH,
      control: true,
    ),
    this.jumpToDocumentStart = const AnyShortcut([
      SingleActivator(LogicalKeyboardKey.home, control: true),
      MacShortcut(SingleActivator(LogicalKeyboardKey.arrowUp, meta: true)),
    ]),
    this.jumpToDocumentEnd = const AnyShortcut([
      SingleActivator(LogicalKeyboardKey.end, control: true),
      MacShortcut(SingleActivator(LogicalKeyboardKey.arrowDown, meta: true)),
    ]),
    this.jumpToDocumentStartAndSelectText = const AnyShortcut([
      SingleActivator(LogicalKeyboardKey.home, control: true, shift: true),
      MacShortcut(
        SingleActivator(LogicalKeyboardKey.arrowUp, meta: true, shift: true),
      ),
    ]),
    this.jumpToDocumentEndAndSelectText = const AnyShortcut([
      SingleActivator(LogicalKeyboardKey.end, control: true, shift: true),
      MacShortcut(
        SingleActivator(LogicalKeyboardKey.arrowDown, meta: true, shift: true),
      ),
    ]),
    this.jumpToLineStart = const AnyShortcut([
      SingleActivator(LogicalKeyboardKey.home),
      MacShortcut(SingleActivator(LogicalKeyboardKey.arrowLeft, meta: true)),
    ]),
    this.jumpToLineEnd = const AnyShortcut([
      SingleActivator(LogicalKeyboardKey.end),
      MacShortcut(SingleActivator(LogicalKeyboardKey.arrowRight, meta: true)),
    ]),
    this.selectToLineStart = const AnyShortcut([
      SingleActivator(LogicalKeyboardKey.home, shift: true),
      MacShortcut(
        SingleActivator(LogicalKeyboardKey.arrowLeft, meta: true, shift: true),
      ),
    ]),
    this.selectToLineEnd = const AnyShortcut([
      SingleActivator(LogicalKeyboardKey.end, shift: true),
      MacShortcut(
        SingleActivator(LogicalKeyboardKey.arrowRight, meta: true, shift: true),
      ),
    ]),
    this.pageUp = const SingleActivator(LogicalKeyboardKey.pageUp),
    this.pageDown = const SingleActivator(LogicalKeyboardKey.pageDown),
    this.selectPageUp = const SingleActivator(
      LogicalKeyboardKey.pageUp,
      shift: true,
    ),
    this.selectPageDown = const SingleActivator(
      LogicalKeyboardKey.pageDown,
      shift: true,
    ),
    this.extendMutliCursorDownward = const SingleActivator(
      LogicalKeyboardKey.arrowDown,
      alt: true,
      shift: true,
    ),
    this.extendMutliCursorUpward = const SingleActivator(
      LogicalKeyboardKey.arrowUp,
      alt: true,
      shift: true,
    ),
  });
}
