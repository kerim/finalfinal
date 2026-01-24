# Cursor Position Mapping Diagnostic Plan

**Problem:** Cursor position saved in CodeMirror doesn't map to the same location in Milkdown.

Example: "* Markdown support |" in CodeMirror → "*|Multiple themes" in Milkdown

**Root Cause Hypothesis:** CodeMirror uses raw character offsets in markdown text. ProseMirror uses document node positions. These are fundamentally different coordinate systems.

---

## Diagnostic Goal

Add logging to capture:
1. What position number is saved when leaving each editor
2. What position number is restored when entering each editor
3. What the actual text around that position is in each editor

---

## Task 1: Add Diagnostic Logging to JavaScript

### CodeMirror (`web/codemirror/src/main.ts`)

In `getCursorPosition()`:
```typescript
getCursorPosition(): number {
  if (!editorView) return 0;
  const pos = editorView.state.selection.main.head;
  const doc = editorView.state.doc.toString();
  const before = doc.slice(Math.max(0, pos - 20), pos);
  const after = doc.slice(pos, pos + 20);
  console.log(`[CodeMirror] getCursorPosition: ${pos}, context: "${before}|${after}"`);
  return pos;
}
```

In `setCursorPosition()`:
```typescript
setCursorPosition(pos: number) {
  if (!editorView) return;
  const safePos = Math.min(pos, editorView.state.doc.length);
  const doc = editorView.state.doc.toString();
  const before = doc.slice(Math.max(0, safePos - 20), safePos);
  const after = doc.slice(safePos, safePos + 20);
  console.log(`[CodeMirror] setCursorPosition: ${pos} -> ${safePos}, context: "${before}|${after}"`);
  // ... rest of function
}
```

### Milkdown (`web/milkdown/src/main.ts`)

In `getCursorPosition()`:
```typescript
getCursorPosition(): number {
  if (!editorInstance) return 0;
  const view = editorInstance.ctx.get(editorViewCtx);
  const pos = view.state.selection.head;
  // Get text context around cursor
  const doc = view.state.doc;
  const $pos = doc.resolve(pos);
  const textBefore = doc.textBetween(Math.max(0, pos - 20), pos, ' ');
  const textAfter = doc.textBetween(pos, Math.min(doc.content.size, pos + 20), ' ');
  console.log(`[Milkdown] getCursorPosition: ${pos}, context: "${textBefore}|${textAfter}"`);
  return pos;
}
```

In `setCursorPosition()`:
```typescript
setCursorPosition(pos: number) {
  if (!editorInstance) return;
  const view = editorInstance.ctx.get(editorViewCtx);
  const safePos = Math.min(Math.max(0, pos), view.state.doc.content.size);
  // Log before setting
  const doc = view.state.doc;
  const textBefore = doc.textBetween(Math.max(0, safePos - 20), safePos, ' ');
  const textAfter = doc.textBetween(safePos, Math.min(doc.content.size, safePos + 20), ' ');
  console.log(`[Milkdown] setCursorPosition: ${pos} -> ${safePos}, context: "${textBefore}|${textAfter}"`);
  // ... rest of function
}
```

---

## Task 2: Build and Test

1. `cd web && pnpm build`
2. `xcodebuild -scheme "final final" -destination 'platform=macOS' build`
3. Run app, open Safari Web Inspector (Develop → final final)
4. Type some text, place cursor at known location
5. Press Cmd+/ to toggle mode
6. Check console for position logs

---

## Expected Output

When toggling from CodeMirror to Milkdown with cursor after "* Markdown support":
```
[CodeMirror] getCursorPosition: 157, context: "* Markdown support|"
[Milkdown] setCursorPosition: 157 -> 157, context: "*|Multiple themes"
```

This will confirm the position number is the same but maps to different text.

---

## After Diagnosis

Once we have the logs, we can design a proper solution:

**Option A:** Convert positions via line/column (both systems support this)
**Option B:** Convert via text matching (find same text context)
**Option C:** Use markdown character offset mapping in Milkdown

The diagnostic data will tell us which approach is most feasible.
