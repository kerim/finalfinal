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

---

## Post-Scroll Height Drift

**Problem:** After rapid scrolling, blank/white gaps appeared where content should be. Gaps persisted until the user scrolled slowly back through the affected area. Especially visible in documents with 50+ sections and mixed heading levels.

**Root Cause:** CM6's virtual renderer can't complete enough measurement cycles during rapid scrolling. Even with correct height estimation formulas (`line-height-fix.ts`), the height map accumulates drift because estimates are only reconciled with actual DOM measurements when lines render. When scrolling stops abruptly, stale estimates remain in the height map.

**Fix:** A `ViewPlugin` that triggers adaptive `requestMeasure()` cycles after scrolling stops (120ms debounce). Each cycle uses `requestMeasure({ read, write })` to check whether `contentDOM` height changed. If delta > 5px, another round is scheduled via `requestAnimationFrame`. The chain self-terminates when heights stabilize or after 4 rounds.

```typescript
// scroll-stabilizer.ts — core mechanism
this.view.requestMeasure({
  read: (view) => view.contentDOM.getBoundingClientRect().height,
  write: (height, _view) => {
    if (Math.abs(height - this.lastKnownHeight) > HEIGHT_EPSILON) {
      this.lastKnownHeight = height;
      this.rafId = requestAnimationFrame(() => this.stabilize(round + 1));
    }
  },
});
```

Key design choices:
- `requestMeasure()` over `dispatch({})` — lightweight, doesn't trigger full plugin update cycles
- Cancels in-progress chain if user scrolls again — stale measurements aren't useful
- `{ passive: true }` scroll listener — no jank

**General principle:** Correcting CM6's height estimation accuracy (via `measureTextSize` patches) is necessary but not sufficient. The viewport also needs time to reconcile estimates with actual measurements. After any operation that changes the scroll position significantly, trigger `requestMeasure()` and verify heights have stabilized.

**See also:** [cm-scroll-stabilizer.md](../findings/cm-scroll-stabilizer.md) for the full investigation.

---

## Block Decorations Must Come From StateField, Not ViewPlugin

**Problem:** CodeMirror displayed blank/empty when documents contained image markdown `![alt](media/...)`. No content was visible at all — not even the text around the images.

**Root Cause:** The image preview plugin (`image-preview-plugin.ts`) used `ViewPlugin.fromClass(...)` with `Decoration.widget({ block: true })`. CM6 enforces that block-level decorations (widgets with `block: true`) must come from a `StateField`, not a `ViewPlugin`. At runtime, CM6 throws:

```
RangeError: Block decorations may not be specified via plugins
```

This error was initially hard to diagnose because it manifested as a blank editor with no visible JS errors in the Xcode console. Adding detailed JS exception logging to the Swift `evaluateJavaScript` completion handler (extracting `WKJavaScriptExceptionMessage`, `WKJavaScriptExceptionLineNumber`, etc. from `NSError.userInfo`) revealed the `RangeError`.

**Fix:** Replace `ViewPlugin.fromClass(...)` with `StateField.define<DecorationSet>(...)`:

```typescript
// WRONG: ViewPlugin cannot provide block decorations
export function imagePreviewPlugin() {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      constructor(view: EditorView) { this.decorations = buildDecorations(view); }
      update(update: ViewUpdate) { this.decorations = buildDecorations(update.view); }
    },
    { decorations: (v) => v.decorations }
  );
}

// RIGHT: StateField can provide block decorations
export function imagePreviewPlugin() {
  return StateField.define<DecorationSet>({
    create(state) { return buildDecorations(state); },
    update(value, tr) {
      if (tr.docChanged) return buildDecorations(tr.state);
      return value;
    },
    provide: (f) => EditorView.decorations.from(f),
  });
}
```

**Consequential change:** `buildDecorations` takes `EditorState` instead of `EditorView`, so widgets can't hold a `view` reference for `requestMeasure()`. Instead, use DOM traversal in the widget's `toDOM()` callbacks:

```typescript
img.onload = () => {
  const editorRoot = wrapper.closest('.cm-editor');
  if (editorRoot) {
    EditorView.findFromDOM(editorRoot as HTMLElement)?.requestMeasure();
  }
};
```

Using `wrapper.closest('.cm-editor')` is safe even for cached images where `onload` fires synchronously before DOM attachment (returns `null`, no-op).

**Swift-side debugging aid:** When diagnosing blank WebView issues, use `if let error` (not `if let error = error as? NSError`) for the guard, then `let nsError = error as NSError` inside for logging. The conditional `as? NSError` cast can skip error handling branches (e.g., resetting `lastPushedContent`) when the error type doesn't match.

**General principle:** In CM6, `ViewPlugin` can only provide inline/line decorations. Block decorations (`block: true`) must come from `StateField.define(...)` with `provide: (f) => EditorView.decorations.from(f)`. This is documented in CM6 but the runtime error is not always surfaced clearly.

---

## Map ViewPlugin Decorations Instead of Rebuilding

**Problem:** Spell check underlines appeared on wrong words during typing. The `ViewPlugin.update()` rebuilt the entire `DecorationSet` from a module-level results array on every update, using positions that were stale after the edit.

**Root Cause:** `buildDecorations()` was called unconditionally in `update()`, reading from `spellcheckResults` which held positions computed before the current edit.

**Solution:** Map existing decorations on `docChanged`, and only rebuild from scratch when fresh results arrive (tracked by a `resultsVersion` counter):

```typescript
update(update: ViewUpdate) {
  if (update.docChanged) {
    this.decorations = this.decorations.map(update.changes);
    results = mapResultPositions(results, update.changes);
  }
  if (resultsVersion !== this.lastResultsVersion) {
    this.decorations = buildDecorations(update.view);
    this.lastResultsVersion = resultsVersion;
  }
}
```

The version counter pattern is needed because CM6 `ViewPlugin.update()` has no equivalent to ProseMirror's `tr.getMeta()` for signaling "new data arrived." Incrementing `resultsVersion` in every mutation site (setResults, disable, learn, ignore, disableRule) and checking it in `update()` bridges this gap.

**Position mapping uses `ChangeDesc.mapPos()` with asymmetric bias:** `from` maps with +1 (don't extend left), `to` maps with -1 (don't extend right). This prevents underlines from growing to cover newly typed characters.

**General principle:** CM6's `DecorationSet.map(changes)` is the standard way to keep decorations positioned correctly through document edits. Reserve full rebuilds for when the underlying data changes, not when the document changes.

---

## Static Widget Styles Belong in CSS, Not Inline JS

**Problem:** The CM image preview widget (`image-preview-plugin.ts`) applied all visual styles as inline JS on DOM elements in `toDOM()`. This made styles hard to maintain, inconsistent with the Milkdown side (which uses `.figure-caption` in CSS), and introduced a `--text-secondary` typo (should be `--editor-text-secondary`) that was invisible without inspecting the JS source.

**Root Cause:** The initial implementation set `wrapper.style.textAlign`, `img.style.maxWidth`, `img.style.maxHeight`, `img.style.display`, `img.style.margin`, `img.style.borderRadius`, `captionEl.style.color`, etc. directly in JavaScript. Only the `onload` handler needed to be dynamic (orientation-aware height adjustment based on `naturalWidth` vs `naturalHeight`).

**Solution:** Move all static styles to CSS classes in `styles.css`:

```css
.cm-image-preview { text-align: center; }
.cm-image-preview img {
  max-width: 100%;
  max-height: 300px;
  display: block;
  margin: 4px auto 8px auto;
  border-radius: 4px;
}
.cm-image-caption {
  margin-top: -4px;
  margin-bottom: 8px;
  font-size: 0.85em;
  color: var(--editor-text, #1a1a1a);
  text-align: center;
  font-style: italic;
}
.cm-image-preview-error {
  color: var(--editor-muted, var(--editor-text-secondary, #888));
  font-style: italic;
  padding: 4px 0;
}
```

In `toDOM()`, keep only: `wrapper.className = 'cm-image-preview'`, `img.draggable = false` (not CSS-settable), explicit width application (when `this.width` is set), and the `onload` handler that clears `max-height` for images without explicit width and triggers `requestMeasure()`.

**Bonus fix:** The error handler's `--text-secondary` typo was automatically fixed by using the CSS class `.cm-image-preview-error` with the correct `--editor-text-secondary` fallback.

**General principle:** In CM6 widget `toDOM()`, use CSS classes for static visual styles and reserve inline `style` assignments for values that are only known at runtime (image dimensions, computed positions). This keeps styles maintainable, themeable via CSS variables, and consistent with the rest of the editor.

---

## Caption Comment Lookup Must Skip Blank Lines

**Problem:** Image captions were never found at runtime. Diagnostic logging showed "Built 0 replace + 3 widget decorations" — three images found, zero captions matched.

**Root Cause:** The caption lookup checked only `doc.line(i - 1)`, but the database stores images with a standard markdown blank line between the caption comment and the image:

```markdown
<!-- caption: This is a caption -->
                                        ← blank line
![image](media/image.jpg)
```

Line `i - 1` was always the blank line, so `CAPTION_REGEX` never matched.

**Fix:** Scan backward (capped at 3 lines) skipping blank lines:

```typescript
let checkLineNum = i - 1;
const minLine = Math.max(1, i - 3);
while (checkLineNum >= minLine && doc.line(checkLineNum).text.trim() === '') {
  checkLineNum--;
}
```

The `Decoration.replace()` range was also widened from "caption line + 1 char" to "caption line start through image line start", covering both the caption comment and any intervening blank lines.

**Both insertion paths handled:**
- Popup-created captions (no blank line): `checkLineNum` stays at `i - 1`
- Database-loaded captions (blank line): `checkLineNum` becomes `i - 2`

**Diagnostic technique:** Used the `errorHandler` message handler bridge (see `docs/guides/webkit-debug-logging.md`) to log `buildDecorations` entry/exit and decoration counts directly to Xcode console, bypassing the need for Safari Web Inspector.

**General principle:** When looking for metadata comments adjacent to content lines, never assume they're on the immediately preceding line. Different code paths (database load, user insertion, paste) may produce different amounts of whitespace between them. Scan backward with a reasonable cap.
