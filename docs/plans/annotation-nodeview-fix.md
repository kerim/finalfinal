# NodeView Stale Closure Fixes

## Status Summary

| Issue | Status | Notes |
|-------|--------|-------|
| Annotation toggle only works once | ✅ FIXED | Reading current node state at click time |
| Citation stays in edit mode | ✅ FIXED | Document-level mousedown listener bypasses unreliable blur |

---

## Issue 1: Annotation Toggle (FIXED)

### Root Cause
The click handler captured `isCompleted` at NodeView creation time. Subsequent clicks used this stale value instead of the current node state.

### Solution Applied
In `annotation-plugin.ts` lines 206-221, the click handler now reads the current node from `view.state.doc.nodeAt(pos)` at click time:

```typescript
markerSpan.addEventListener('click', (e) => {
  // ...
  const currentNode = view.state.doc.nodeAt(pos);
  if (currentNode && currentNode.type.name === 'annotation') {
    const currentCompleted = currentNode.attrs.isCompleted;
    const tr = view.state.tr.setNodeMarkup(pos, undefined, {
      ...currentNode.attrs,
      isCompleted: !currentCompleted,
    });
    view.dispatch(tr);
  }
});
```

### Verification
Tested by toggling task annotation multiple times - toggle now works correctly in both directions.

---

## Issue 2: Citation Edit Mode (FIXED)

### Root Cause
The `blur` event on contentEditable elements inside ProseMirror NodeViews doesn't fire reliably when clicking elsewhere in the editor. ProseMirror's focus handling intercepts clicks before the contentEditable element receives a proper blur event.

### Solution Applied
Added a document-level `mousedown` listener (capture phase) that detects clicks outside the citation DOM element. This bypasses the unreliable blur event entirely.

In `citation-plugin.ts`, the following changes were made:

1. **Added state variable** after `let isEditMode = false;`:
```typescript
let documentClickHandler: ((e: MouseEvent) => void) | null = null;
```

2. **Updated `enterEditMode()`** to add document listener:
```typescript
const enterEditMode = () => {
  console.log('[CitationNodeView] enterEditMode() called');
  if (isEditMode) return;
  isEditMode = true;
  // ... existing setup code ...

  // Add document listener to catch clicks outside
  // (blur events unreliable in ProseMirror NodeViews)
  const handler = (e: MouseEvent) => {
    if (!dom.contains(e.target as Node)) {
      exitEditMode();
    }
  };
  documentClickHandler = handler;
  // setTimeout(0) to avoid catching the entering click
  setTimeout(() => {
    document.addEventListener('mousedown', handler, true);
  }, 0);
};
```

3. **Updated `exitEditMode()`** to remove listener:
```typescript
const exitEditMode = () => {
  console.log('[CitationNodeView] exitEditMode() called, isEditMode:', isEditMode);
  if (!isEditMode) return;
  isEditMode = false;

  // Remove document listener
  if (documentClickHandler) {
    document.removeEventListener('mousedown', documentClickHandler, true);
    documentClickHandler = null;
  }
  // ... rest of existing code ...
};
```

4. **Updated `destroy()`** to clean up listener:
```typescript
destroy: () => {
  // Clean up document listener if destroyed while editing
  if (documentClickHandler) {
    document.removeEventListener('mousedown', documentClickHandler, true);
    documentClickHandler = null;
  }
},
```

### Key Implementation Details
- **Capture phase (`true`)**: Runs before any `stopPropagation` calls
- **`setTimeout(0)`**: Prevents catching the same click that entered edit mode
- **Blur handler kept**: Defense-in-depth; `if (!isEditMode) return` guard prevents double execution

### Verification
- Click citation → shows `[@citekey]`
- Click elsewhere in editor → returns to `(Author Year)` ✅
- Press Escape → returns to `(Author Year)` ✅
- Press Enter → returns to `(Author Year)` ✅
- Click sidebar → returns to `(Author Year)` ✅

---

## Files Modified

| File | Changes |
|------|---------|
| `web/milkdown/src/annotation-plugin.ts` | Fixed click handler to read current node state |
| `web/milkdown/src/citation-plugin.ts` | Added document-level mousedown listener to exit edit mode reliably |

---

## Build Commands

```bash
cd web && pnpm build
cd .. && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```
