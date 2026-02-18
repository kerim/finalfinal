# CodeMirror Patterns

Patterns for CodeMirror 6 editor integration. Consult before writing related code.

---

## ATX Headings Require # at Column 0

**Problem:** Heading styling (font-size, font-weight) worked for some headings but not others. `## sub header` on its own line was styled correctly, but `# header 1` on the same line as a section anchor was not.

**Root Cause:** The Lezer markdown parser strictly follows the CommonMark spec: ATX headings must have `#` at column 0 (start of line). When section anchors precede headings:

```markdown
<!-- @sid:UUID --># header 1
```

The `#` is at column 22 (after the anchor comment), so the parser produces:
- `CommentBlock` (the anchor)
- `Paragraph` (the "# header 1" text, NOT an ATXHeading)

Meanwhile, a heading on its own line:
```markdown
## sub header
```

Has `#` at column 0, so the parser produces:
- `ATXHeading2`

**Evidence from syntax tree inspection:**
```
Document content: "<!-- @sid:... --># header 1\n\n## sub header"
Nodes found: ["Document", "CommentBlock", "Paragraph", "ATXHeading2"]
                                          ^^^^^^^^^^^ NOT ATXHeading1!
```

**Solution:** Add a regex fallback pass in the heading decoration plugin. After the syntax tree pass, scan for lines matching the anchor+heading pattern:

```typescript
buildDecorations(view: EditorView): DecorationSet {
  const decorations: { pos: number; level: number }[] = [];
  const decoratedLines = new Set<number>();

  // First pass: Syntax tree (standard headings at column 0)
  for (const { from, to } of view.visibleRanges) {
    syntaxTree(view.state).iterate({
      enter: (node) => {
        const match = node.name.match(/^ATXHeading(\d)$/);
        if (match) {
          const line = doc.lineAt(node.from);
          decoratedLines.add(line.number);
          decorations.push({ pos: line.from, level: parseInt(match[1]) });
        }
      },
    });
  }

  // Second pass: Regex fallback for headings after anchors
  const anchorHeadingRegex = /^<!--\s*@sid:[^>]+-->(#{1,6})\s/;
  for (let lineNum = startLine; lineNum <= endLine; lineNum++) {
    if (decoratedLines.has(lineNum)) continue;
    const match = line.text.match(anchorHeadingRegex);
    if (match) {
      decorations.push({ pos: line.from, level: match[1].length });
    }
  }

  // Sort and build (RangeSetBuilder requires sorted order)
  decorations.sort((a, b) => a.pos - b.pos);
  // ... build from sorted decorations
}
```

**Alternative solutions considered:**
- Move anchors to end of heading line -- requires content migration
- Put anchors on their own line -- changes document structure
- Custom Lezer grammar -- complex, affects all markdown parsing

**General principle:** When using syntax-aware decorations that depend on line-start patterns, add a fallback for cases where prefixed metadata breaks the pattern. Check what nodes the parser actually produces vs. what you expect.

---

## Keymap Intercepts Events Before DOM Handlers

**Problem:** Custom undo behavior in `EditorView.domEventHandlers({ keydown })` never executed because the handler never fired.

**Root Cause:** CodeMirror's `historyKeymap` binds `Mod-z` and intercepts the event before DOM handlers run:

1. User presses Cmd+Z
2. `historyKeymap` matches `Mod-z` -> calls built-in `undo()` -> returns `true` (handled)
3. Event is consumed; `domEventHandlers.keydown` **never fires**

**Wrong approach (DOM handler):**
```typescript
EditorView.domEventHandlers({
  keydown(event, view) {
    if (event.key === 'z' && event.metaKey) {
      // This never runs! historyKeymap already handled the event
      customUndo(view);
      return true;
    }
    return false;
  }
})
```

**Right approach (custom keymap):**
```typescript
keymap.of([
  ...defaultKeymap.filter(k => k.key !== 'Mod-/'),
  // Custom undo replaces historyKeymap's Mod-z binding
  {
    key: 'Mod-z',
    run: (view) => {
      if (needsCustomBehavior) {
        customUndo(view);
        return true;
      }
      return undo(view);  // Fallback to normal undo
    }
  },
  { key: 'Mod-Shift-z', run: (view) => redo(view) },
  { key: 'Mod-y', run: (view) => redo(view) },
  // ... other bindings
])
```

**Key insight:** Don't include `...historyKeymap` when you need to override undo/redo behavior. Define your own `Mod-z`, `Mod-Shift-z`, and `Mod-y` bindings explicitly.

**General principle:** To intercept keyboard shortcuts in CodeMirror, replace the keymap binding, not the DOM handler. Keymap handlers run first.

---

## Virtual Viewport Gaps from Heading Height Mismatch

**Problem:** CodeMirror's virtual renderer showed blank gaps where content should be. Content appeared after scrolling slightly further. Most visible in documents with many headings (H1-H3) scattered across 50+ paragraphs.

**Root Cause (two factors):**

1. **Decoration-only font sizing:** The heading decoration plugin applies `Decoration.line()` CSS classes that change font-size (body=18px vs H1=31px, H2=26px), but only for `view.visibleRanges`. Lines outside the viewport have no heading decorations, so CodeMirror estimates their height using body text metrics. When headings scroll into view and actually render, they're taller than estimated, leaving blank gaps.

2. **1px preload frame:** `EditorPreloader.swift` created WebViews at 1x1 pixels. With `EditorView.lineWrapping` enabled, every word wraps into its own line at 1px width, producing completely wrong initial height estimates that persisted even after the WebView was resized.

**Fix (two changes):**

Web-side — force height recalculation after content changes:
```typescript
// In setContent(), after dispatching the content change:
requestAnimationFrame(() => {
  view.requestMeasure();
});
```
- `requestMeasure()` is lightweight (no-op if heights unchanged)
- Only fires on `setContent()` calls (content load, zoom, project switch) — NOT during typing

Swift-side — use screen-sized frame for preloaded WebViews:
```swift
private var preloadFrameSize: CGSize {
    NSScreen.screens.first?.frame.size ?? CGSize(width: 1200, height: 800)
}
// Then: WKWebView(frame: CGRect(origin: .zero, size: preloadFrameSize), ...)
```
Uses `NSScreen.screens.first` instead of `NSScreen.main` because `.main` requires a key window (which may not exist during `applicationDidFinishLaunching`).

**General principle:** When CSS decorations change line height and are only applied to visible ranges, CodeMirror's virtual viewport will underestimate off-screen line heights. Call `view.requestMeasure()` after content changes to force re-measurement. Also ensure preloaded WebViews have a realistic frame size so initial line-wrapping calculations are meaningful.

---

## measureTextSize() Heading Contamination

**Problem:** Off-screen body line heights were massively overestimated (up to 30x), causing total document height to balloon from ~2,200px to ~71,000px. Scrolling triggered "Viewport failed to stabilize" warnings whenever headings entered the viewport.

**Root Cause:** CM6's internal `measureTextSize()` (docview.ts) finds a short visible line (<=20 chars, ASCII-only) to measure `lineHeight` and `charWidth`. In our document, the only qualifying visible line was an H1 heading (`# Slides`, 9 chars) which had heading-sized CSS applied via decorations. This returned:
- `lineHeight` = 37px (heading) instead of 31px (body)
- `charWidth` = ~16px (heading font) instead of ~9px (body font)

The `charWidth` contamination was especially damaging because CM6 computes `lineLength = contentWidth / charWidth` (index.js:6181). With contaminated charWidth:
- `lineLength = 650 / 16 ≈ 40` (thinks lines wrap at 40 chars)
- Correct: `lineLength = 650 / 9 ≈ 72` (actual wrapping at ~72 chars)

This caused `heightForGap()` to estimate ~1.6x more wrapped lines for every off-screen body line.

**Fix:** Monkey-patch `docView.measureTextSize` to correct both values using dummy `.cm-line` elements inserted into `contentDOM`:

```typescript
// In installMeasureTextSizePatch():
docView.measureTextSize = () => {
  const result = original();

  // Fix lineHeight (Phase 1)
  const correctHeight = measureBodyLineHeight(view);
  if (correctHeight > 0 && Math.abs(result.lineHeight - correctHeight) > 1) {
    result.lineHeight = correctHeight;
  }

  // Fix charWidth (Phase 1b)
  const correctCharWidth = measureBodyCharWidth(view);
  if (correctCharWidth > 0 && Math.abs(result.charWidth - correctCharWidth) > 1) {
    result.charWidth = correctCharWidth;
  }

  return result;
};
```

Both measurement helpers use `view.observer.ignore()` to suppress CM6's MutationObserver during DOM manipulation.

**Companion fix (Phase 2):** Even with corrected body metrics, headings are still underestimated because `heightForGap()` uses uniform body line height for all lines. A separate patch on `heightForGap()` computes per-heading deltas by measuring actual heading metrics (height + charWidth per H1-H3) and adding the difference to the bulk estimate.

**General principle:** When decoration-applied CSS changes font metrics on specific line types, CM6's `measureTextSize()` can sample a decorated line and contaminate global metrics. Both `lineHeight` and `charWidth` must be verified/corrected. The contamination is document-dependent (which lines are visible and short enough to be sampled).

**See also:** [cm-scroll-height-contamination.md](../findings/cm-scroll-height-contamination.md) for the full investigation.
