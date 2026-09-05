# code_forge — pure-Dart fork

A fork of [`code_forge`](https://pub.dev/packages/code_forge) 10.8.0 with the
Rust editing core reimplemented in Dart. **No Rust, no `flutter_rust_bridge`, no
cargokit, no native build step contributed by this package on any platform.**

(An app may still build native code for other reasons — in ScriptTex's case
`jni`, pulled in by `path_provider`, compiles a small C library on Linux and
Windows. That is nothing to do with this package.)

It is a drop-in replacement. The package name, the public API and the observable
behaviour are unchanged, so switching is one line:

```yaml
dependencies:
  code_forge:
    path: packages/code_forge   # was: ^10.8.0
```

Nothing else in an app has to change — including `await RustLib.init()`, which
is kept as a no-op shim precisely so it does not have to.

---

## What was actually replaced

Upstream is 28,134 lines of Dart, of which 4,340 were the generated
`flutter_rust_bridge` binding. The LSP client, syntax highlighting, themes and
find/replace are untouched, and so are the widgets bar one four-line bug fix
([below](#fixes-on-top-of-upstream)). Only the binding layer is new:

| Upstream | Here |
| --- | --- |
| `lib/src/rust/frb_generated*.dart` (3,922 lines of marshalling) | deleted |
| `lib/src/rust/api/rope.dart` → Rust `ropey` | `lib/src/core/rope.dart` — gap buffer + line index |
| `lib/src/rust/api/editor.dart` → Rust `zed-sum-tree` | `lib/src/core/editor.dart` — block list + prefix sums |
| Rust `unicode_bidi` | `lib/src/core/bidi.dart` — bidi class ranges |
| `RustLib.init()` | `lib/src/core/rust_lib.dart` — no-op shim |

## How equivalence was checked

Not by reading the Rust and hoping. `tool/diff_harness.dart` and
`tool/rust_reference/main.rs` drive both implementations through the same
operations and the outputs are compared byte for byte:

> **13,939 lines of output, zero differences.**

Eleven documents — empty, no trailing newline, CRLF, blank lines, nested braces,
HTML tags, colon indentation, RTL, mixed-direction, non-ASCII — crossed with
every method, every offset from 0 to the document length, every line index
including out-of-range ones, plus a 300-operation randomised `LayoutMap` script.
See `tool/rust_reference/README.md` to re-run it.

That comparison is what caught the two things below.

### A reproduced bug

`insertLine`, `removeLine` and `updateLine` act on line `max(lineIdx - 1, 0)`,
not `lineIdx`. Upstream implemented them with a `zed-sum-tree` cursor slice at
`Bias::Left`, which keeps `lineIdx - 1` blocks, so every mutation lands one line
early — `insertLine(0)` and `insertLine(1)` both insert at the front.

This is reproduced deliberately. The widget layer drives these from its own line
bookkeeping and was written against the behaviour; silently shifting every
mutation by one line would move the rendered layout. `test/layout_map_test.dart`
pins it with the exact upstream outputs.

### A fixed performance bug

The first implementation here rebuilt the line index after every edit, which
meant rescanning the document for newlines on every keystroke — 29ms on a 10MB
file, two dropped frames for one character. `ropey` never paid that because its
tree carries line counts. `_spliceLineStarts` now moves the index across an edit
instead:

| document | before | after |
| --- | --- | --- |
| 10 KB | 39.8 µs | 2.0 µs |
| 100 KB | 269.2 µs | 1.9 µs |
| 1 MB | 2,740.7 µs | 8.6 µs |
| 10 MB | 29,210.9 µs | 89.4 µs |

(one keystroke followed by a line query — the path typing actually takes)

## Fixes on top of upstream

**Ctrl + ← skipped a word.** `_moveWordLeft` in `lib/code_forge/code_area.dart`
looked for the last word run in the line *before the caret* whose end fell short
of the caret — which is never the run the caret is in, so it landed on the one
before it. From the end of a line the caret jumped past every word to the first:

```dart
// upstream: always one word too far
int newOffset = lineStart;
for (final match in wordMatches) {
  if (match.end >= lineText.length) break;
  newOffset = lineStart + match.start;
}
```

`lineText` already stops at the caret, so its *last* run is the word the caret
is in — or the one before it, when the caret is on whitespace. Either way that
run's start is the answer. Ctrl + Shift + ← is fixed with it; both go through
this method. `test/word_navigation_test.dart` in the app pins the behaviour by
driving the real editor with real key events.

`_moveWordRight` and the Ctrl + Backspace/Delete handlers were correct and are
untouched.

**Semantic tokens were requested before the edits they describe were sent.**
The render object waits 180 ms after an edit before asking the server for
semantic tokens (`_scheduleVisibleSemanticTokens`); the controller sends the
edit itself 200 ms after it happens (`_lspDocumentSyncDebounce`). The request
therefore overtook its own `didChange`, and the server answered about the text
as it stood a keystroke ago. Measured against the real server, with the buffer
reading `const beta: number = 1;`:

```
answer:  (start 6, length 5)   ← `alpha`, one character too long
         (start 11, …)         ← the `:`, one column too far right
```

Those ranges are painted over the current text: a five-character span across
the four-character word `beta`, and everything after it off by one. The result
is a word in two or three colours, which stays wrong until some later edit
happens to re-request the tokens — the client's own guard only checks that the
*client* has not changed since the request went out, not that the server has
caught up.

The fix is ordering, not timing: `CodeForgeController.flushPendingLspSync()` is
new — it sends whatever is waiting on the debounce — and the token request
awaits it first. Both messages travel the same connection, so the server now
always has the edit before the question. `isLspReady` is exposed alongside it,
because until the document has been opened an edit is in the buffer but not on
the wire, and nothing that asks the server can tell.

**The merged colouring of a line was cached under the line's text.**
`SyntaxHighlighter.getLineSpan` stored the grammar-plus-semantic span in
`_lineSpanCache`, which is keyed by the text of the line alone — while the
semantic half of that span belongs to a line *index*. Two lines reading the
same got whichever colouring was computed first, and a line with no semantic
tokens of its own could be served another line's. Merged spans now live only in
the line-keyed `_mergedCache`; `_lineSpanCache` keeps grammar-only spans, for
which the text really is the whole key.

Two smaller ones alongside it, both "do not paint what is known to be wrong":
`updateSemanticTokens` now replaces every line the answer covered instead of
merging into it, so a line whose tokens are gone loses its old colouring; and
`applyDocumentEdit` drops the spans of a line it split or joined, and all of
them when a replacement changes the line count, rather than shifting offsets
that no longer mean anything. Grammar colouring holds until the server answers.

**A semantic-token answer was applied even when it changed nothing.**
`SyntaxHighlighter.updateSemanticTokens` drops every cache it has and makes the
grammar re-run over the viewport — around 9ms on a 12,000-line document, plus a
`compute()` isolate spawn when more than fifty lines need re-highlighting. The
render object asks again whenever the *viewport* moves, so scrolling a large
file paid that every 180ms. Two changes:

- The highlighter compares an answer against the one it already applied and
  returns early when they match. An edit clears that memory, so a genuinely new
  answer is never skipped. This matters most for a document the server has no
  analysis for, where every answer is an identical empty list.
- `_scheduleVisibleSemanticTokens` only treats the viewport as part of the
  question when the server actually supports `semanticTokens/range`. A server
  that answers `full` returns the whole document however the viewport moved, so
  re-asking made it re-analyse the file for an answer the client already had.

Ten identical answers on a synthetic 12,000-line `.d.ts` cost 92ms before and
9ms after — the one that changes something, and nine that no longer do.

**A laid-out paragraph outlived the colouring it was painted from.** The render
object caches `ui.Paragraph`s by line index, and a paragraph has its colours
baked in. Nothing validated one on the way out — every path that changed
colouring had to remember to clear the cache, and the paths that cleared "from
the edited line down" left the lines *above* an edit painted from whatever
colouring was current when they were last drawn.

The visible form of that: a line painted before the server's semantic tokens
arrived keeps its grammar-only colouring, so keywords and strings look right
and the names the tokens would have classified — property names above all —
stay plain. And an edit "fixed" it only for lines below the edit, which is why
editing near the top of a short file looked like a cure and editing in the
middle of a long one did nothing.

`paint` now compares the highlighter's `colouringVersion` against the one the
cache was filled at and empties it when they differ, which makes a stale
paragraph unreachable rather than merely unlikely. Only the paragraphs: line
widths and heights are geometry, unaffected by colour, and dropping those here
would re-measure a wrapped document from the top on every keystroke.

**Lines highlighted on the background isolate came back with no colours at
all.** `_textSpanToSpanData`, which packs a highlighted line for the trip home
from `compute`, declared `String? scope;` and never assigned it. Every span
therefore arrived scopeless, and `_spanDataToTextSpan` rebuilt it with the base
style: the right runs, in the right places, uncoloured — and cached that way,
so a region stayed grey until something invalidated the line.

Upstream this rarely showed, because the prefetch asked for exactly the lines
paint had already highlighted synchronously, leaving it almost nothing to do.
Widening it to a screenful either side (above) made the isolate the main
producer of cache entries, and the defect became whole uncoloured regions while
scrolling.

The span now carries the `TextStyle` the renderer resolved rather than the name
of a scope to look it up by — the isolate is handed the theme, so what it
produced is already right — and a failure to use the isolate at all falls back
to highlighting here rather than leaving the lines plain.

**The grammar ran during paint, and there was nothing warmed ahead of it.**
`getLineSpan` highlights a line on demand, so a viewport of lines nobody has
visited yet is highlighted inside the frame that scrolls into it. Measured with
`re_highlight` over TypeScript declarations:

| line shape | per line |
| --- | --- |
| `readonly status: number;` | ~0.2ms |
| a long generic signature (226 chars) | ~1.7ms |
| a union of forty literals (491 chars) | ~2.2ms |
| one 8,630-character line | ~50ms |

A sixty-line screenful of real declarations is therefore 100ms or more of work
inside one frame. Two changes:

- **Warming ahead.** The prefetch that runs after paint asked for exactly the
  lines just painted, which that paint had already highlighted synchronously;
  it warmed nothing. It now covers a screenful either side — what the *next*
  frame will need — on the background isolate, and repaints when it lands.
- **A ceiling on line length.** Above 2,000 characters a line is painted in the
  base style rather than run through the grammar. One such line is 50ms, and a
  file of generated declarations can hold many.

A third change, a per-frame time budget on highlighting, was tried and taken
back out. It bounded the frame, but the lines it gave up on were painted plain
*and cached that way by the render object*, so scrolled-past regions stayed
uncoloured; and with `lineWrap` the height pass exhausted the budget every
frame, which meant a repaint every frame and nothing ever coloured. Bounding
the frame is not worth a document that does not finish colouring.

**Wrapping made every frame cost as much as the scroll position.** With
`lineWrap` on, a line's y is the sum of the heights of every line above it, and
`_getWrappedLineHeight` measured a line by building its *highlighted* paragraph
— running the grammar — and caching that paragraph. Scrolled to line 6,000, one
frame measured six thousand lines; the height cache was pruned to a margin
around the viewport, so the next frame measured them again. On a 12,000-line
file that was ~900ms per frame: a full core, and an editor that did not
respond. The scroll extent made it worse, sampling sixty-four lines spread
through the document the same expensive way, on every layout.

Heights now come from a plain paragraph — same font, same width, so the same
rows, and none of the grammar's cost — and are never pruned, since one double
per line is cheaper to keep than to measure twice. The extent's sample is taken
once per wrap width and line count rather than per layout. When a line on
screen is painted, its styled paragraph's height replaces the measured one, so
a font whose bold runs wrap differently corrects itself.

Ten scroll frames on a 12,000-line wrapped file: 18.6s before, ~1.1s after.
`test/idle_test.dart` in the app carries a smoke test for it.

**The editor repainted at frame rate, forever, for a blinking caret.** The
caret is drawn on or off — every reader of `caretBlinkController` asks whether
its value is above 0.5, and nothing uses the values in between — but it was
driven by an `AnimationController` on `repeat(reverse: true)`, and
`caretBlinkController.addListener(markNeedsPaint)` turns every tick of that
into a full paint pass. An idle editor therefore repainted 60 or 120 times a
second to produce a boolean that changes twice, and on a large document each of
those passes walks the viewport.

It is a 500ms `Timer.periodic` now, toggling the same controller between 1.0
and 0.0 — two repaints a second instead of sixty — and it does not run at all
while the editor is unfocused, where no caret is drawn. `test/idle_test.dart`
in the app asserts that an idle editor schedules no frames and runs no ticker;
both fail against the version above.

**`tabSize` meant two things at once.** It is the width of a tab stop when
painting, and it was also the number of characters `tabSpace` inserted — so
`useSpaceAsTab: false, tabSize: 4` inserted *four tab characters*. The two only
agreed at the default of 1. Here `tabSize` means columns, always: `tabSpace` is
one tab character or `tabSize` spaces, and `indent`/`unindent` measure the
indent with `tabSpace.length` rather than assuming it. Nothing changes at the
defaults; a configuration that used to insert four tabs now inserts one.

**`FindController` could find but not really replace.** The searching worked —
matches, options, highlights — but the parts a find *and replace* bar is built
out of were missing or wrong, and the app on top of this package needed them:

- The match list was private. Nothing outside the controller could show the
  matches, only step through them one at a time. `matches` exposes them now, as
  a `FindMatch` carrying offsets rather than a `Match` bound to the string it
  was run against — which goes stale the moment the buffer changes. Each one can
  `locate` itself in the document on demand, so a list only pays for the rows it
  paints.
- **`replaceAll` and the highlights disagreed.** The search compiled its pattern
  with `multiLine: true`; replace-all compiled the same source *without* it. A
  regex anchored with `^` or `$` therefore replaced a different set of matches
  than the one lit up on screen. It is built from the match list now, so what
  disappears is exactly what was highlighted.
- **Replace-all lost the caret.** It rewrote the whole document, which leaves
  the caret at the end of the file. The caret is now carried across by the net
  length change of the matches before it.
- `replace()` left the view where it was, so a replace-one-by-one loop scrolled
  away from itself after the first press. It follows the match it moves to.
  `skip()` and `goToMatch(index)` are new, as are `open()` and `close()` — one
  place for "open the finder on the selection" and "close it and give the editor
  its caret back", so every way in behaves the same.
- **Whole word bound to the wrong thing in a pattern of alternatives.** The
  boundaries were concatenated, so `a|b` as a whole word compiled to
  `\ba|b\b` — `a` at a word start *or* `b` at a word end. It is grouped now.
- `hasPatternError` distinguishes a regex that does not compile from one that
  matches nothing. Both used to leave the editor untouched with no way to tell
  them apart.
- `dispose` leaked its two `FocusNode`s.

`test/find_replace_test.dart` in the app pins all of it, driving the real bar
with real key events and taps.

## Two deliberate differences

**Offsets are UTF-16 code units, not Unicode scalar values.** `ropey` indexed by
code point, but every consumer of those offsets is a Dart `String` or a Flutter
`TextSelection`, both UTF-16 — `Rope.selection` in `lib/code_forge/rope.dart`
passes one straight into `TextSelection.baseOffset`. Upstream therefore
disagreed with its own callers on text containing emoji or other astral-plane
characters. Here they agree. For text inside the BMP, which is all source code
in practice, the two schemes give identical indices for every operation.

**Out-of-range `insert` and `remove` clamp instead of panicking.** `ropey`
panics, which crossed the FFI boundary as a process abort. Every neighbouring
method already clamped.

The bidi table (`lib/src/core/bidi.dart`) is a block-level approximation of the
Unicode bidi property rather than a transcription of `DerivedBidiClass.txt`. The
property that matters is exact — whitespace, digits and punctuation stay
neutral, so spaced RTL text is not misread as mixed — but the class of a few
individual marks inside RTL blocks can differ, which can move a segment boundary
by one character in script-mixing text.

## Performance

Pure-Dart core, AOT, microseconds per operation:

| document | type @cursor | `getText` cold | `getText` warm | `charToLine` | `line()` |
| --- | --- | --- | --- | --- | --- |
| 10 KB | 0.34 | 56.6 | 0.009 | 0.050 | 0.248 |
| 100 KB | 0.13 | 227.6 | 0.004 | 0.027 | 0.201 |
| 1 MB | 0.04 | 2,816.8 | 0.002 | 0.036 | 0.209 |
| 10 MB | 0.08 | 27,441.3 | 0.003 | 0.043 | 0.189 |

Typing is comparable to `ropey` measured in isolation (0.12–0.16 µs) and faster
once the FFI crossing that upstream also paid is counted. `getText` is where the
gap is largest: upstream had to materialise the string *and* marshal it across
the boundary on every call — about 5.4 ms for a 1 MB document — where here an
unedited document is returned from cache in 0.002 µs.

`dart run tool/bench.dart` and `tool/bench2.dart` reproduce these.

## Tests

```bash
flutter test        # 47 tests
flutter analyze
```

Every expectation was captured from the Rust build rather than chosen, so the
suite is a regression test against the original, not against my reading of it.

## Licence

MIT, from upstream — see `LICENSE`. Original work by Athul A S
(<https://github.com/heckmon/code_forge>). This fork keeps that licence and
changes only the editing core.
