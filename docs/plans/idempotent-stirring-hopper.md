# Plan: CM Image Caption — Hide Source + Click-to-Edit Popup

## Context

CM (source mode) currently shows the raw `<!-- caption: text -->` comment as visible text above the image markdown, plus a styled caption below the image preview widget. Milkdown (WYSIWYG) hides the implementation detail and shows only a clean image with editable caption below. The user wants CM to match Milkdown's presentation: hide the comment, show only the styled caption, and support click-to-edit via a popup (following the annotation/citation popup pattern).

## Approach

Three changes to the existing `image-preview-plugin.ts` + one new file:

1. **Hide caption comment** — `Decoration.replace()` on the `<!-- caption: -->` line
2. **Click-to-edit popup** — new singleton popup module (same pattern as `annotation-edit-popup.ts`)
3. **"Add caption" affordance** — placeholder text below images without captions, visible on hover
4. **Atomic ranges** — cursor skips over hidden caption lines

## Files Modified

| File | Change |
|------|--------|
| `web/codemirror/src/image-caption-popup.ts` | **New file** — singleton popup (input, Enter/Escape/blur handlers) |
| `web/codemirror/src/image-preview-plugin.ts` | Add `Decoration.replace()`, extend widget with line metadata, add ViewPlugin for click events, add `atomicRanges`, return `Extension[]` |
| `web/codemirror/src/styles.css` | Add `.cm-image-add-caption`, `.cm-image-caption:hover`, `.cm-caption-edit-popup` styles |
| `web/codemirror/src/main.ts` | Spread `...imagePreviewPlugin()` (now returns array) |
| `web/codemirror/src/api.ts` | Call `dismissImageCaptionPopup()` in `setContent()` and `resetForProjectSwitch()` |

## Step 1: Create `image-caption-popup.ts`

Singleton popup module following the `annotation-edit-popup.ts` pattern.

**Module state:**
```typescript
let popup: HTMLElement | null = null;
let popupInput: HTMLInputElement | null = null;
let editingView: EditorView | null = null;
let editingImageLineNumber: number | null = null;
let editingCaptionLineNumber: number | null = null; // null = creating new caption
let blurTimeout: ReturnType<typeof setTimeout> | null = null;
```

**Exported functions:**
- `showImageCaptionPopup(view, rect, currentCaption, imageLineNumber, captionLineNumber)` — creates/shows popup positioned below the clicked caption element
- `dismissImageCaptionPopup()` — hides popup, clears state
- `isImageCaptionPopupOpen()` — for guards

**Popup DOM:** Fixed-position div with single-line `<input>` (captions are short) + hint text ("Enter to save · Escape to cancel"). Uses `var(--editor-bg)` / `var(--editor-text)` for theming.

**Event handlers:**
- Enter → commit
- Escape → cancel (dismiss)
- blur → commit after 150ms delay (matches annotation popup)
- mousedown on popup → `preventDefault()` to avoid blur

**Commit logic:**

| Case | Action |
|------|--------|
| Editing existing, non-empty input | Replace caption line text: `from..to` → `<!-- caption: newText -->` |
| Editing existing, empty input | Delete caption line + its trailing newline |
| Adding new, non-empty input | Insert `<!-- caption: text -->\n` at `imageLine.from` |
| Adding new, empty input | No-op (dismiss) |

**Safety:** Before applying changes, verify `doc.line(lineNumber).text` still matches the expected pattern (`CAPTION_REGEX` or `IMAGE_REGEX`). If not, abort silently — another transaction may have shifted content.

**Commit-before-reshow:** If the popup is already open for a different image when the user clicks another caption, commit the current edit first (following `annotation-edit-popup.ts` pattern).

**Focus restore:** Call `editingView.focus()` on both commit and cancel paths to return cursor to editor.

## Step 2: Modify `image-preview-plugin.ts`

### 2a. Extend `ImagePreviewWidget` constructor

Add `imageLineNumber: number` and `captionLineNumber: number | null` fields. Update `eq()` to compare them.

### 2b. Modify `toDOM()` — always show caption area

```typescript
// Always create caption element (for click-to-edit or add-caption)
const captionEl = document.createElement('div');
if (this.caption) {
  captionEl.className = 'cm-image-caption';
  captionEl.textContent = this.caption;
} else {
  captionEl.className = 'cm-image-caption cm-image-add-caption';
  captionEl.textContent = 'Add caption…';
}
// Store metadata as data attributes for the click handler
captionEl.dataset.imageLineNumber = String(this.imageLineNumber);
if (this.captionLineNumber !== null) {
  captionEl.dataset.captionLineNumber = String(this.captionLineNumber);
}
captionEl.dataset.caption = this.caption;
wrapper.appendChild(captionEl);
```

Click handling is NOT in `toDOM()` — it's in the companion ViewPlugin (Step 2d) to avoid per-instance handler leaks.

### 2c. Modify `buildDecorations()` — add `Decoration.replace()` for caption lines

When a caption line is found preceding an image:
- Add `Decoration.replace({})` from `captionLine.from` to `captionLine.to + 1` (consume the trailing newline to eliminate the blank line gap)
- Guard: only consume newline if `captionLine.to + 1 <= doc.length`
- Collect all decorations (replace + widget) in a single array, sort by position, then build

### 2d. Add companion `ViewPlugin` for click events + auto-dismiss on external edits

```typescript
const imageCaptionClickPlugin = ViewPlugin.fromClass(
  class {
    update(update: ViewUpdate) {
      // Auto-dismiss popup when document changes externally
      // (Swift keyboard shortcuts, spellcheck, setContent, etc.)
      if (update.docChanged && isImageCaptionPopupOpen()) {
        // Use a module-level flag to distinguish our own commits
        if (!isCommittingCaption) {
          dismissImageCaptionPopup();
        }
      }
    }
  },
  {
    eventHandlers: {
      click(event: MouseEvent, view: EditorView) {
        const target = event.target as HTMLElement;
        if (!target.classList.contains('cm-image-caption') &&
            !target.classList.contains('cm-image-add-caption')) {
          return false;
        }
        event.preventDefault();
        event.stopPropagation();
        // Extract metadata from data attributes, call showImageCaptionPopup()
        return true;
      },
    },
  }
);
```

The `update()` handler auto-dismisses the popup when any external document change occurs (Swift keyboard shortcuts like Cmd+B, spellcheck dispatches, content push). The `isCommittingCaption` flag prevents the popup's own commit dispatch from triggering dismissal.

### 2e. Add `atomicRanges` for cursor skip

```typescript
const atomicImageRanges = EditorView.atomicRanges.of(
  (view) => view.state.field(imageDecorationField)
);
```

This makes the cursor skip over the hidden `Decoration.replace()` range. Note: `anchor-plugin.ts` uses `view.plugin()` for its `atomicRanges` (from a ViewPlugin), but since our decorations come from a `StateField`, we use `view.state.field()` instead. The returned `DecorationSet` includes both replace and widget decorations; the zero-width widget ranges have no cursor effect, so this is benign.

### 2f. Change export to `Extension[]`

```typescript
export function imagePreviewPlugin(): Extension[] {
  return [imageDecorationField, atomicImageRanges, imageCaptionClickPlugin];
}
```

## Step 3: CSS additions in `styles.css`

```css
/* "Add caption" placeholder — hidden until hover */
.cm-image-add-caption {
  color: var(--editor-muted, var(--editor-text-secondary, #999));
  cursor: pointer;
  opacity: 0;
  transition: opacity 0.15s;
}
.cm-image-preview:hover .cm-image-add-caption {
  opacity: 0.6;
}

/* Existing caption — clickable with hover feedback */
.cm-image-caption {
  cursor: pointer;
}
.cm-image-caption:hover {
  background: var(--editor-selection, rgba(0, 122, 255, 0.1));
  border-radius: 2px;
}

/* Caption edit popup */
.cm-caption-edit-popup {
  position: fixed;
  z-index: 10000;
  background: var(--editor-bg, #fff);
  border: 1px solid rgba(128, 128, 128, 0.3);
  border-radius: 6px;
  padding: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
  min-width: 250px;
  max-width: 400px;
}
.cm-caption-edit-popup input[type="text"] {
  width: 100%;
  padding: 6px 8px;
  border: 1px solid rgba(128, 128, 128, 0.3);
  border-radius: 4px;
  font-size: 13px;
  background: var(--editor-bg, #fff);
  color: var(--editor-text, #333);
  box-sizing: border-box;
  font-family: inherit;
}
.cm-caption-edit-hint {
  margin-top: 4px;
  font-size: 11px;
  color: var(--editor-muted, var(--editor-text-secondary, #999));
  text-align: center;
}
```

## Step 4: Update `main.ts`

Change `imagePreviewPlugin()` call to spread:
```typescript
...imagePreviewPlugin(),
```

## Step 5: Update `api.ts`

Add `dismissImageCaptionPopup()` calls in:
- `setContent()` — content pushed from Swift
- `resetForProjectSwitch()` — project switch cleanup

Also strip caption comments from `getStats()` word/character counts (captions are metadata, not body text):
```typescript
// In getStats(), after stripping annotations:
text = text.replace(/<!--\s*caption:\s*.+?\s*-->/g, '');
```

## Step 6: Popup dismiss on editor toggle

The popup must also dismiss when switching between CM and Milkdown (Cmd+/). The `saveAndNotify()` path in `api.ts` calls `getContent()` before the WebView tears down. Add `dismissImageCaptionPopup()` at the top of `saveAndNotify()`.

## Reviewer Findings (3 parallel agents)

| Finding | Severity | Resolution |
|---------|----------|------------|
| `Decoration.replace()` + `widget` in one StateField | Valid | No issue — CM6 supports mixed decoration types |
| `atomicRanges` includes zero-width widget ranges | Benign | Zero-width ranges have no cursor effect |
| `anchor-plugin.ts` uses `view.plugin()` not `view.state.field()` | Inaccuracy | Corrected — we use `view.state.field()` for StateField |
| Swift keyboard shortcuts (Cmd+B) can dispatch while popup open | **Important** | Added `update.docChanged` auto-dismiss in ViewPlugin |
| Commit-before-reshow when clicking different caption | Suggestion | Added to popup spec |
| Focus restore after dismiss | Suggestion | Added `view.focus()` on both paths |
| `getStats()` includes caption text in word counts | Suggestion | Added caption stripping in Step 5 |
| Dismiss on editor toggle (Cmd+/) | Suggestion | Added Step 6 |
| `getContent()` unaffected by decorations | Confirmed | `doc.toString()` returns full text including captions |
| BlockParser Fix C and this plan are independent | Confirmed | Different layers (text vs visual) |

## Implementation Order

1. Create `image-caption-popup.ts` (new file, no dependencies)
2. Modify `image-preview-plugin.ts` (replace decorations, widget metadata, click plugin with auto-dismiss, atomic ranges, export change)
3. Add CSS to `styles.css`
4. Update `main.ts` (spread import)
5. Update `api.ts` (dismiss calls, caption stripping in `getStats()`, dismiss in `saveAndNotify()`)
6. Build: `cd web && pnpm build`

## Verification

1. `cd web && pnpm build` — compiles without errors
2. Build in Xcode
3. **Caption hidden:** The `<!-- caption: text -->` line is not visible in CM. No blank gap where it was.
4. **Caption display:** Styled italic caption appears below image preview, matching Milkdown's look.
5. **Click to edit:** Click caption → popup opens with current text → Enter saves → popup closes → caption updates. Escape cancels.
6. **Add caption:** Hover over captionless image → "Add caption…" appears → click → popup → type text → Enter → caption comment inserted before image line, now displayed below preview.
7. **Delete caption:** Open popup → clear text → Enter → caption comment line removed from document.
8. **Cursor nav:** Arrow up/down past a hidden caption line — cursor skips over it smoothly.
9. **Roundtrip:** Add caption in CM → switch to Milkdown (Cmd+/) → caption appears in Milkdown figure → switch back to CM → no duplication, caption still shown correctly.
