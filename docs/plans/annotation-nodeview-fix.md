# NodeView Stale Closure Fixes

## Status Summary

| Issue | Status | Notes |
|-------|--------|-------|
| Annotation toggle only works once | ✅ FIXED | Reading current node state at click time |
| Citation stays in edit mode | 🔍 INVESTIGATING | Blur event not firing reliably |

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

## Issue 2: Citation Edit Mode (INVESTIGATING)

### Observed Behavior
1. Citation inserts correctly, displays as `(Friedman 2015)`
2. Clicking citation enters edit mode, shows `[@friedmanExceptionalStatesChinese2015]`
3. Clicking away from citation **should** exit edit mode and return to formatted display
4. **Actual:** Citation stays showing raw syntax `[@citekey]`

### Current Implementation
- `enterEditMode()`: Sets `contentEditable = 'true'`, shows raw syntax
- `exitEditMode()`: Triggered by `blur` event, sets `contentEditable = 'false'`, calls `updateDisplay()`
- `blur` event listener on DOM element calls `exitEditMode()`

### Hypothesis: Blur Event Not Firing

The `blur` event on contentEditable elements inside ProseMirror NodeViews may not fire reliably when:
1. User clicks elsewhere in the ProseMirror editor
2. ProseMirror handles the click and updates selection
3. Focus management between ProseMirror and contentEditable element is inconsistent

#### Why Blur Might Not Fire
1. **ProseMirror focus handling**: When clicking elsewhere in the editor, ProseMirror may handle focus in a way that doesn't properly blur nested contentEditable elements
2. **stopEvent interference**: The NodeView's `stopEvent` returns `true` for all events in edit mode, which might affect focus management
3. **WKWebView quirks**: Safari/WebKit in WKWebView may have specific behavior around focus/blur in this context

### What Needs Investigation

1. **Verify hypothesis**: Add logging to confirm blur is not firing
   - Add `console.log` at start of blur handler
   - Add `console.log` inside `exitEditMode()`
   - Check if logs appear when clicking away

2. **Test alternative triggers**:
   - Does pressing Escape work? (Currently should call `dom.blur()`)
   - Does pressing Enter work?
   - Does clicking outside the editor entirely (e.g., on sidebar) trigger blur?

3. **Inspect focus state**:
   - Log `document.activeElement` before and after clicking away
   - Verify the contentEditable span was actually focused

---

## Proposed Fix for Issue 2

If blur is confirmed not to fire reliably, implement a more robust exit mechanism:

### Option A: Document-level mousedown listener
```typescript
let documentClickHandler: ((e: MouseEvent) => void) | null = null;

const enterEditMode = () => {
  if (isEditMode) return;
  isEditMode = true;
  // ... existing code ...

  // Add document listener to catch clicks outside
  documentClickHandler = (e: MouseEvent) => {
    if (!dom.contains(e.target as Node)) {
      exitEditMode();
    }
  };
  // Use setTimeout to avoid catching the entering click
  setTimeout(() => {
    document.addEventListener('mousedown', documentClickHandler!, true);
  }, 0);
};

const exitEditMode = () => {
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

### Option B: ProseMirror transaction listener
Listen for ProseMirror transactions that change selection, and exit edit mode if selection moves outside the citation node.

### Option C: Focus polling (last resort)
Use `requestAnimationFrame` or `setInterval` to poll whether the element still has focus.

---

## Files Modified

| File | Changes |
|------|---------|
| `web/milkdown/src/annotation-plugin.ts` | Fixed click handler to read current node state |
| `web/milkdown/src/citation-plugin.ts` | Moved citekeys computation into updateDisplay(), added safety check in exitEditMode() |

---

## Next Steps

1. Add diagnostic logging to citation blur/exitEditMode
2. Test to confirm blur is not firing
3. Implement Option A (document mousedown listener) if hypothesis confirmed
4. Build and test
5. Consider whether annotation-plugin.ts needs similar robustness (currently uses direct click, not contentEditable)

---

## Build Commands

```bash
cd web && pnpm build
cd .. && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```
