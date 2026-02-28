# Review: CM Image Caption Plan (idempotent-stirring-hopper)

Review of the plan at `docs/plans/idempotent-stirring-hopper.md` against the actual codebase, focused on the five areas requested.

---

## 1. Line Number Stability During Popup Interaction

**Confidence: HIGH -- This is a real problem that needs a mitigation strategy.**

The plan stores `imageLineNumber` and `captionLineNumber` (1-based CodeMirror line numbers) when the popup opens, then uses `doc.line(lineNumber)` at commit time. The plan includes a safety check:

> Before applying changes, verify `doc.line(lineNumber).text` still matches the expected pattern (`CAPTION_REGEX` or `IMAGE_REGEX`). If not, abort silently.

This safety check is good but there are concrete scenarios where line numbers shift while the popup is open:

### Background dispatches that CAN fire during popup interaction

1. **Spellcheck results callback** (`spellcheck-plugin.ts`, line 54): `setSpellcheckResults()` calls `view.dispatch({})` (empty dispatch to trigger decoration rebuild). This is a no-op for line numbering -- document content does not change. **Safe.**

2. **Push-based content messaging** (`main.ts`, lines 223-236): A 50ms debounced `EditorView.updateListener` fires on every `docChanged` and sends content to Swift. This is read-only (no dispatch). **Safe.**

3. **Swift-side `setContent()` call** (`api.ts`, lines 98-149): If Swift calls `window.FinalFinal.setContent(markdown)` while the popup is open, the entire document is replaced. This dispatches `changes: { from: 0, to: prevLen, insert: markdown }`. **This WILL invalidate all stored line numbers.** The plan addresses this by adding `dismissImageCaptionPopup()` to `setContent()`, which is correct.

4. **Content push from Swift via `updateNSView`** (`CodeMirrorEditor.swift`, lines 150-153): `shouldPushContent()` can return true when the content binding changes externally (e.g., from section sync, hierarchy enforcement, drag-drop reordering). This calls the Swift `setContent()` which calls `window.FinalFinal.setContent()`. **The plan's dismiss call in `setContent()` covers this.**

5. **`resetForProjectSwitch()` in `api.ts`** (line 1024-1047): Creates an entirely new `EditorState`. **The plan adds dismiss here too. Covered.**

### Scenarios the plan does NOT cover

- **User typing elsewhere in the document while popup is open**: If the user clicks elsewhere in the editor (which would blur the popup and trigger commit via the blur handler with 150ms delay), they could type text before the commit fires. However, the blur handler commits, not the typing. The 150ms window is tight enough that this race is unlikely, and the safety check on line content would catch it. **Low risk but worth noting.**

- **Slash commands**: If the user triggers a slash command in another part of the document while the popup is open, it would dispatch changes. The popup uses a single-line `<input>` that captures keyboard focus, so slash commands in the editor body are effectively blocked while the popup is focused. **Safe in practice.**

- **`initialize()` in `api.ts`** (line 336-355): Calls `setContent()` internally, so the dismiss in `setContent()` covers it. **Covered.**

### Verdict

The plan's approach (dismiss on `setContent()` + safety check on commit) is **adequate for the known dispatch paths**. The safety check (`doc.line(lineNumber).text` still matches expected pattern) is the right catch-all. However, one subtle edge case remains: what if the user's own edits (typing in the document while popup has focus) shift line numbers? Since the popup captures focus via `<input>`, direct editor typing is blocked. The `mousedown` `preventDefault()` on the popup prevents blur-on-click within the popup. This is consistent with the annotation popup pattern. **No gaps found.**

---

## 2. Commit Logic for Adding a New Caption

**Confidence: HIGH -- There is a line number shift issue the plan should clarify.**

The plan says for "Adding new, non-empty input":

> Insert `<!-- caption: text -->\n` at `imageLine.from`

Let's trace this carefully. Given a document with:
```
Line 3: ![alt](media/photo.png)
```

The popup opens with `imageLineNumber = 3`, `captionLineNumber = null`.

At commit time, the plan says to use `doc.line(imageLineNumber)` to get `imageLine`, then insert at `imageLine.from`. The insertion is:
```
<!-- caption: text -->\n
```

After this dispatch:
- Line 3 is now `<!-- caption: text -->`
- Line 4 is now `![alt](media/photo.png)` (the image shifted down by 1)

Then `buildDecorations()` re-runs. It iterates lines:
- Line 3: No `IMAGE_REGEX` match. `CAPTION_REGEX` matches but it only looks for captions preceding images.
- Line 4: `IMAGE_REGEX` matches. Check preceding line (line 3): `CAPTION_REGEX` matches. Caption is extracted.

**This works correctly.** The newly inserted caption on line 3 is correctly detected as preceding the image on line 4. The `Decoration.replace()` on the caption line will hide it, and the widget on line 4 will show the caption text.

### Edge case: inserting before the very first line

If `imageLineNumber = 1`, then `imageLine.from = 0`. Inserting `<!-- caption: text -->\n` at position 0 pushes the image to line 2. `buildDecorations()` will correctly find the caption on line 1 preceding the image on line 2. **Correct.**

### The `from..to` range

The plan uses `imageLine.from` as both the insertion point. Since this is a pure insertion (no replacement), it dispatches `{ from: imageLine.from, to: imageLine.from, insert: "<!-- caption: text -->\n" }`. **This is correct CodeMirror usage.**

### Verdict

**No issues.** The plan handles this case correctly.

---

## 3. Commit Logic for Deleting a Caption

**Confidence: HIGH -- One subtlety worth noting.**

The plan says for "Editing existing, empty input" (delete caption):

> Delete caption line + its trailing newline

The plan specifies deleting from `captionLine.from` to `captionLine.to + 1`. The `+1` consumes the trailing newline character (`\n`), which prevents leaving a blank line gap.

### Tracing through

Given:
```
Line 2: <!-- caption: old text -->
Line 3: ![alt](media/photo.png)
```

`captionLineNumber = 2`, `imageLineNumber = 3`.

At commit: `captionLine = doc.line(2)`. Delete `{ from: captionLine.from, to: captionLine.to + 1, insert: "" }`.

After dispatch:
- Line 2 is now `![alt](media/photo.png)` (shifted up)
- No caption line exists

`buildDecorations()` re-runs:
- Line 2: `IMAGE_REGEX` matches. Check preceding line (line 1): whatever was there before, it won't be a caption comment. No caption.

**Correct.** The existing `Decoration.replace()` that was hiding the caption line is cleaned up because `buildDecorations()` is called from the `StateField.update()` when `docChanged` is true (see `image-preview-plugin.ts` line 155: `if (tr.docChanged) { return buildDecorations(tr.state); }`). The entire decoration set is rebuilt from scratch. **No stale decorations.**

### Guard: `captionLine.to + 1 <= doc.length`

The plan mentions this guard. If the caption is the last line of the document (no trailing newline), `captionLine.to + 1` would exceed `doc.length`. The guard prevents this. **Correct.**

However, this scenario (caption is the last line) is pathological -- a caption should always precede an image. If it is somehow the last line, the guard prevents an out-of-bounds error, and the caption line text would be deleted but the line itself would remain as an empty line. The plan should ideally handle this edge case explicitly (delete just `captionLine.from` to `captionLine.to`). This is a minor robustness concern.

### Verdict

**No blocking issues.** The decoration StateField rebuilds from scratch on every doc change, so stale decorations are not a concern.

---

## 4. Popup Dismiss on Content Changes

**Confidence: HIGH -- The plan has a gap for zoom/unzoom content pushes.**

The plan adds `dismissImageCaptionPopup()` to:
1. `setContent()` in `api.ts`
2. `resetForProjectSwitch()` in `api.ts`

### Other places where content can change externally

Let me audit all paths that modify the CodeMirror document:

| Path | Covered? | Notes |
|------|----------|-------|
| `setContent()` | YES | Plan adds dismiss here |
| `resetForProjectSwitch()` | YES | Plan adds dismiss here (creates new EditorState) |
| `initialize()` | YES | Calls `setContent()` internally |
| User typing | N/A | User cannot type in editor while popup input has focus |
| Spellcheck result dispatch | SAFE | Empty dispatch, no doc change |
| Slash command | SAFE | Requires editor focus, popup has focus |
| Citation picker callback | EDGE | User could have popup open, trigger citation from Zotero. But `citationPickerCallback` modifies the document via `view.dispatch()`. The popup would see line numbers shift. **However**, for the citation picker to be triggered, the user would have had to type `/cite` in the editor, which requires editor focus -- so the popup would already be dismissed via blur. **Safe in practice.** |
| Footnote insertion (Cmd+Shift+N) | EDGE | This is a keyboard shortcut that fires via NotificationCenter. If the popup is open and focused, the keyboard shortcut goes to NSApp, not the popup. The Swift coordinator calls `insertFootnoteAtCursor()` which dispatches a document change. **This could shift lines while the popup is open.** The popup's safety check would catch this (line text would no longer match), but ideally the dismiss should be called. |
| Formatting commands (Cmd+B, etc.) | EDGE | Same pattern as footnote. Keyboard shortcuts go through Swift notifications. **Could dispatch while popup is open.** |
| `renumberFootnotes()` | EDGE | Called from Swift. Dispatches document changes. |

### Missing dismiss calls

The plan should consider adding dismiss calls in these additional locations:

1. **Any `view.dispatch()` that changes the document** -- rather than adding dismiss calls everywhere, a more robust approach would be to add an `EditorView.updateListener` that dismisses the popup on `docChanged`. This is cleaner than adding individual dismiss calls to every path. The annotation popup in Milkdown (`annotation-edit-popup.ts`) does NOT do this, but it operates on ProseMirror node positions which are more stable (ProseMirror tracks node identity, not line numbers).

### Recommendation

The plan should add an `EditorView.updateListener` in the image caption click plugin that dismisses the popup when `update.docChanged` is true and the change did not originate from the popup's own commit dispatch. This could be done with a module-level flag `isCommitting` that is set during commit and cleared after. This is more robust than chasing individual dispatch sites.

### Verdict

**Important gap.** The plan covers the two main external content change paths (`setContent` and `resetForProjectSwitch`) but misses Swift-initiated keyboard shortcuts (formatting, footnotes) that dispatch document changes via `evaluateJavaScript`. The safety check would prevent data corruption, but the popup would remain visible with stale data. Adding a `docChanged` listener for auto-dismiss is recommended.

---

## 5. Singleton Popup Pattern Comparison with Annotation Popup

**Confidence: HIGH -- The plan is well-aligned but misses a few patterns.**

Comparing the plan's proposed `image-caption-popup.ts` with `annotation-edit-popup.ts`:

### Patterns the plan correctly follows

1. **Module-level singleton state** -- both use `let popup: HTMLElement | null = null` pattern. Correct.
2. **Blur-with-delay commit** -- both use 150ms `setTimeout` on blur, with `clearTimeout` on focus. Correct.
3. **`mousedown` `preventDefault()`** on popup to avoid blur. Correct.
4. **`showXxxPopup()` / `dismissXxxPopup()` / `isXxxPopupOpen()` exports**. Correct.
5. **Fixed positioning** with `z-index: 10000`. Matches annotation popup.

### Patterns the plan misses or differs on

1. **Commit-before-reshow**: The annotation popup (line 164) commits the current edit before opening a new one:
   ```typescript
   if (editingNodePos !== null && editingView && editPopupInput) {
     commitAnnotationEdit();
   }
   ```
   The plan mentions `showImageCaptionPopup()` but does not explicitly state whether clicking a different image's caption while the popup is open should commit the current edit first. **The plan should add this pattern.**

2. **Input type**: The annotation popup uses a `<textarea>` (multiline) with Shift+Enter for new lines. The plan uses a single-line `<input>`, which is appropriate for captions (short text). **Correct difference.**

3. **Click-outside dismiss**: Neither the annotation popup nor the plan explicitly handles click-outside-dismiss. Both rely on the `blur` event of the input/textarea, which fires when focus moves away. This means clicking anywhere outside the popup (including the editor body) triggers a blur -> commit. This is the correct behavior. **No gap.**

4. **Z-index conflicts**: The plan uses `z-index: 10000`, matching the annotation popup. The spellcheck menu (`spellcheck-menu.ts`) and spellcheck popover (`spellcheck-popover.ts`) also likely use high z-index values. The slash menu uses CSS classes. Since only one popup should be open at a time (clicking a caption closes any slash menu because the cursor moves), z-index conflicts are unlikely. **No issue.**

5. **Viewport boundary handling**: The annotation popup positions itself at `coords.bottom + 4`:
   ```typescript
   popup.style.top = `${coords.bottom + 4}px`;
   ```
   The plan does not mention checking if the popup fits within the viewport. If the image is near the bottom of the viewport, the popup could be clipped. Neither popup handles this, so it is a pre-existing limitation, not a regression. **Consistent with existing pattern.**

6. **Focus management on dismiss**: The annotation popup restores focus to the editor view after cancel (`view?.focus()`). The plan should explicitly mention restoring editor focus after both commit and cancel, to ensure the cursor returns to the editor. The annotation popup does this on both paths. **The plan should add this.**

7. **Theming variables**: The plan uses `var(--editor-bg)` and `var(--editor-text)`, while the annotation popup uses `var(--bg-primary)` and `var(--text-primary)`. These are Milkdown vs CodeMirror CSS variable namespaces. The plan correctly uses the CodeMirror namespace. **Correct.**

### Verdict

The plan is well-aligned with the annotation popup pattern. Two minor gaps:
- Should explicitly commit current edit before reshowing for a different image.
- Should explicitly restore editor focus after both commit and cancel.

---

## Summary of Findings

| Issue | Severity | Confidence | Status |
|-------|----------|------------|--------|
| Line number stability: safety check is adequate | -- | HIGH | Plan handles this well |
| New caption insertion correctness | -- | HIGH | Correct |
| Caption deletion correctness | -- | HIGH | Correct, decorations rebuild from scratch |
| Missing dismiss for Swift keyboard shortcuts | Important | HIGH | Plan should add `docChanged` listener or address these paths |
| Commit-before-reshow pattern missing | Suggestion | HIGH | Should commit current edit before showing for a different image |
| Focus restore after dismiss missing | Suggestion | HIGH | Should restore editor focus on both commit and cancel |
| Viewport boundary clipping for popup | Suggestion | MEDIUM | Pre-existing limitation in annotation popup too, not a regression |
| Caption-is-last-line edge case in delete | Suggestion | MEDIUM | Minor robustness improvement |

### Key Files Referenced

- `/Users/niyaro/Documents/Code/ff-dev/images/docs/plans/idempotent-stirring-hopper.md` -- the plan under review
- `/Users/niyaro/Documents/Code/ff-dev/images/web/codemirror/src/api.ts` -- `setContent()`, `resetForProjectSwitch()`
- `/Users/niyaro/Documents/Code/ff-dev/images/web/codemirror/src/image-preview-plugin.ts` -- current StateField, `buildDecorations()`
- `/Users/niyaro/Documents/Code/ff-dev/images/web/codemirror/src/spellcheck-plugin.ts` -- background dispatches
- `/Users/niyaro/Documents/Code/ff-dev/images/web/codemirror/src/main.ts` -- extension registration, content push listener
- `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/annotation-edit-popup.ts` -- reference popup pattern
- `/Users/niyaro/Documents/Code/ff-dev/images/final final/Editors/CodeMirrorCoordinator+Handlers.swift` -- Swift-side dispatches
- `/Users/niyaro/Documents/Code/ff-dev/images/web/codemirror/src/anchor-plugin.ts` -- `atomicRanges` reference pattern
