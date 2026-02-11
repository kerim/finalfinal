# Investigation Report: CSS Layout Breaks on Project Switch

## Executive Summary

The CSS variable hypothesis is **disproven** by diagnostic evidence. A more important finding: **mode switching** (CodeMirror → Milkdown) pushes new content into the same reused WebView via `setContent()` and renders correctly. This narrows the bug to code that runs during project switch but NOT during mode switch.

---

## Finding 1: CSS Variables Are Not the Problem

### Diagnostic Evidence (from test run)

```
[MilkdownEditor] PAINT-COMPLETE CSS state: {
  "columnMaxWidth": "750px",        ← CORRECT (override value)
  "editorMaxWidth": "750px",        ← CORRECT (matches)
  "editorMarginLeft": "22.5px",     ← CORRECT (auto-centering for ~795px viewport)
  "scrollY": 0,                     ← CORRECT (at top)
  "bodyHeight": 7256                ← REASONABLE for 12K content
}
```

All CSS values are correct at the moment the WebView becomes visible. The `--column-max-width` variable is present, the `#editor` max-width matches, and `margin: 0 auto` is producing correct auto margins. This eliminates CSS variable loss, theme ordering, and theme caching as causes.

### Fixes Attempted and Their Status

| Fix | Hypothesis | Status |
|-----|-----------|--------|
| Force theme re-push (`lastThemeCss = ""`) | CSS variables lost during reset | **Disproven** |
| Reorder theme→content | CSS must be set before content | **Irrelevant** — CSS was never lost |
| JS scroll resets in `resetForProjectSwitch` | Previous scroll position persists | **Insufficient** — scrollY=0 confirmed |
| Alpha hide/show pattern | Borrow zoom's compositor fix | See Finding 2 |
| Diagnostic logging | Verify CSS state | **Useful** — proved CSS wrong |

---

## Finding 2: Mode Switching Works — The Bug Is Project-Switch-Specific

When editing in CodeMirror then switching to Milkdown (Cmd+/):
1. Content binding updates with CodeMirror's changes
2. `updateNSView` fires → `shouldPushContent` detects change → `setContent(newContent)`
3. Layout renders correctly with proper margins and centering

This uses the **same WebView**, the **same `setContent()` function**, and the **same CSS**. The only difference is the absence of the project-switch machinery. This eliminates generic WebView reuse and compositor caching as root causes.

---

## Finding 3: Four Things Unique to Project Switch

These are present during project switch but absent during mode switch:

### 3a. ProseMirror Hard State Reset
```javascript
// In resetForProjectSwitch() — main.ts:2277-2284
const newState = PMEditorState.create({
    doc: view.state.doc,
    plugins: view.state.plugins,
});
view.updateState(newState);
```
Creates an entirely new `EditorState`, destroying all plugin state (undo history, decorations, input rules). `view.updateState()` forces ProseMirror to reconcile its DOM with the new state. This could leave ProseMirror's internal measurement caches or view state inconsistent.

Mode switching never calls `updateState()` — content changes go through `tr.replace()`, which is the normal ProseMirror transaction path.

### 3b. Alpha Hide/Show Cycle
Project switch hides the WebView (`alphaValue = 0`) before content change, then shows it after paintComplete (`alphaValue = 1`). Mode switching keeps the WebView **visible** throughout. The project's own LESSONS-LEARNED.md (line 1147) documents that `alphaValue = 0/1` "hides the view but doesn't touch compositor."

### 3c. `scrollToStart = true` Pipeline
When `scrollToStartOnNextPush` is true:
- **Swift side:** `alphaValue = 0`, WebView hidden
- **JS side:** After content dispatch, enters the double-RAF → micro-scroll → paintComplete path
- Mode switching doesn't use scrollToStart — it preserves cursor position

### 3d. Two Content Pushes (Empty Then Real)
`editorState.resetForProjectSwitch()` (Swift) clears content to `""`, triggering:
- **First** `updateNSView` → `setContent("")` with scrollToStart → alpha hide → JS takes empty-content early-return path (no paintComplete)
- **Second** `updateNSView` → `setContent(realContent)` with scrollToStart → full JS pipeline → paintComplete

Mode switching does a single content push.

---

## Finding 4: The Diagnostic Shows Correct DOM But Broken Visual

The PAINT-COMPLETE diagnostic proves the DOM/CSS state is correct at the moment the WebView becomes visible. Yet the visual layout is broken. This gap between correct DOM state and incorrect visual rendering is characteristic of:

- **Compositor-level stale tiles** (documented in LESSONS-LEARNED.md lines 1113-1152)
- **WKWebView layout deferral when view is invisible** (alpha=0)
- **Stale ProseMirror view measurements** after `updateState()`

---

## Resolution

**Fix applied: Option 3 (Robust) — match the working mode-switch path.** Two changes, applied together:

### Change 1: Replace `updateState()` with a normal transaction (main.ts)

In `resetForProjectSwitch()`, the `PMEditorState.create()` + `view.updateState(newState)` block was replaced with a standard `tr.replace()` transaction that empties the document to a single paragraph. This keeps ProseMirror's internal measurement caches intact. The `Slice` import was already present.

### Change 2: Remove the alpha hide/show pipeline for project switch (Swift)

In `handleProjectOpened()`, removed `pendingScrollToStart = true` and the 2-second safety timeout. Replaced with a simple 100ms delayed `window.scrollTo({top: 0, behavior: 'instant'})` — the same approach mode switch uses.

This cascaded through three files:
- `ContentView.swift` — removed `@State private var pendingScrollToStart` and its bindings to both editors
- `MilkdownEditor.swift` — removed `@Binding var pendingScrollToStart`, the `scrollToStartOnNextPush` coordinator property, and the `updateNSView` block that wired them together. In `setContent()`, `shouldScrollToStart` now only checks `isZoomingContent` (zoom path preserved).
- `CodeMirrorEditor.swift` — same removals as MilkdownEditor

### What was NOT changed

The zoom path (`isZoomingContent`) still uses alpha hide/show + `scrollToStart` + paintComplete. That path was always working correctly. Only the project-switch-specific machinery was removed.

### Result

Project switch now follows essentially the same code path as mode switch: content push through the normal pipeline, WebView stays visible, simple scroll-to-top afterward. The brief flash of old→new content (which mode switch always had) is not noticeable in practice.

---

## Key Lesson

When a code path works (mode switch) and a parallel path doesn't (project switch), the fix is to make the broken path match the working one — not to add more machinery to the broken path. The alpha hide/show + paintComplete + scrollToStart pipeline was added to make project switch "smoother" than mode switch, but it introduced two interacting bugs (stale ProseMirror caches + deferred layout while invisible) that were worse than the brief content flash it was trying to prevent.

---

## Avenues Considered But Not Needed

| Avenue | Description | Status |
|--------|------------|--------|
| Isolate `updateState()` only | Replace with transaction, keep alpha pipeline | Subsumed by Option 3 |
| Force layout reflow after paintComplete | `setNeedsDisplay` / `offsetHeight` | Not needed — eliminating the problem was simpler than working around it |
| Eliminate empty content push | Skip the `content=""` intermediate | Not needed — the empty push is harmless without the alpha pipeline |
| Use `batchInitialize()` for project switch | Match first-load path | Overkill — normal `setContent()` works fine |

---

## Code Path Comparison Reference

### First Load (`batchInitialize()`)
```
handlePreloadedView() → batchInitialize() → JS initialize({content, theme})
  - Single JS call: setTheme() then setContent() synchronously
  - WebView VISIBLE throughout
  - No paintComplete, no alpha hide, no scrollToStart
```

### Mode Switch (normal `updateNSView`)
```
Content binding changes → updateNSView → shouldPushContent → setContent(newContent)
  - Single content push
  - WebView VISIBLE throughout
  - No paintComplete, no alpha hide, no scrollToStart
  - No resetForProjectSwitch
```

### Project Switch (was broken, now fixed)
```
handleProjectOpened() → resetForProjectSwitch() → isResettingContent=false → updateNSView
  - JS resetForProjectSwitch: tr.replace() empties document (normal transaction path)
  - Swift reset: content="" → first push (harmless)
  - updateNSView: setContent(real) → normal pipeline, WebView stays visible
  - 100ms later: window.scrollTo({top: 0})
```

### Project Switch (old broken path, removed)
```
  - JS resetForProjectSwitch: view.updateState(newState) ← destroyed PM caches
  - pendingScrollToStart=true ← triggered alpha hide + scrollToStart pipeline
  - FIRST updateNSView: setContent("") with scrollToStart → alpha=0, JS early return
  - SECOND updateNSView: setContent(real) with scrollToStart → alpha=0, double-RAF, paintComplete
  - handlePaintComplete: alpha=1 ← WKWebView had deferred layout while invisible
```

---

## Files Reference

| File | What Changed |
|------|-------------|
| `web/milkdown/src/main.ts` | `resetForProjectSwitch()`: `updateState()` → `tr.replace()` transaction |
| `final final/Views/ContentView.swift` | `handleProjectOpened()`: removed `pendingScrollToStart`, safety timeout; added simple scroll-to-top |
| `final final/Editors/MilkdownEditor.swift` | Removed `pendingScrollToStart` binding, `scrollToStartOnNextPush`, project-switch alpha hiding |
| `final final/Editors/CodeMirrorEditor.swift` | Same removals as MilkdownEditor |
