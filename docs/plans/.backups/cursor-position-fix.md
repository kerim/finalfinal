# Phase 1.5.1: Cursor Position Mapping Fix

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix cursor position preservation when switching between WYSIWYG (Milkdown) and Source (CodeMirror) modes.

**Problem:** ProseMirror uses tree-based positions where each node boundary counts as 1, while markdown uses flat character offsets. Position 150 in ProseMirror does not equal position 150 in markdown.

**Architecture:** Use line-based mapping - convert cursor position to (line, column) coordinates which are portable between both formats.

---

## Research Summary

### Why Raw Positions Don't Work

From [ProseMirror documentation](https://prosemirror.net/docs/ref/):
> "In ProseMirror, when indexing by position, we need to account for non-text nodes (paragraphs in our case). This offsets things."

ProseMirror treats documents as trees where non-leaf nodes like paragraphs have "before" and "after" positions that create offsets. A position of 150 in ProseMirror might be at character 120 in the serialized markdown.

### Solution Options Considered

1. **Full Position Mapping** ([vladris.com DevLog](https://vladris.com/blog/2025/09/08/devlog-5-markdown-and-wysiwyg.html))
   - Track position correspondence during serialization
   - Most accurate, but requires modifying Milkdown's serialization
   - Overkill for mode toggle use case

2. **Line-Based Mapping** (CHOSEN)
   - Convert position to (line number, column within line)
   - Both formats have clear line boundaries
   - Good accuracy for paragraph-based content
   - Simple to implement

3. **Percentage-Based**
   - Convert position to percentage through document
   - Simplest but least accurate
   - Would land in wrong paragraph for long documents

4. **Text Anchor**
   - Find unique text around cursor, search in other format
   - Fragile if text changes during switch

### Note: Even Typora Has This Problem

From [Typora issues](https://github.com/typora/typora-issues/issues/3506): Users report the view jumps to top when switching modes.

---

## Task 1: Add Line-Based Position API to Milkdown

**Files:**
- Modify: `web/milkdown/src/main.ts`

**Step 1: Replace getCursorPosition/setCursorPosition with line-based versions**

In `window.FinalFinal`, replace the cursor methods:

```typescript
getCursorPosition(): { line: number; column: number } {
  if (!editorInstance) return { line: 1, column: 0 };
  const view = editorInstance.ctx.get(editorViewCtx);
  const { head } = view.state.selection;

  // Walk through document to find line number and column
  let line = 1;
  let lineStart = 0;

  view.state.doc.nodesBetween(0, head, (node, pos) => {
    if (node.isBlock && pos < head) {
      // Each block node after the first increments line count
      if (pos > 0) {
        line++;
        lineStart = pos + 1; // +1 to skip the node boundary
      }
    }
    return true;
  });

  // Column is the offset within the current line
  const column = head - lineStart;
  console.log('[Milkdown] getCursorPosition: line', line, 'col', column, 'head', head);
  return { line, column };
},

setCursorPosition(lineCol: { line: number; column: number }) {
  if (!editorInstance) return;
  const view = editorInstance.ctx.get(editorViewCtx);
  const { line, column } = lineCol;

  // Find the position of the target line
  let currentLine = 1;
  let targetPos = 1; // Start after doc boundary

  view.state.doc.nodesBetween(0, view.state.doc.content.size, (node, pos) => {
    if (node.isBlock) {
      if (currentLine === line) {
        // Found target line - position is: node start + 1 (enter block) + column
        const maxCol = Math.max(0, node.content.size);
        targetPos = pos + 1 + Math.min(column, maxCol);
        return false; // Stop iteration
      }
      if (pos > 0) currentLine++;
    }
    return true;
  });

  console.log('[Milkdown] setCursorPosition: line', line, 'col', column, '-> pos', targetPos);

  try {
    const safePos = Math.min(Math.max(1, targetPos), view.state.doc.content.size);
    const selection = Selection.near(view.state.doc.resolve(safePos));
    view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
    view.focus();
  } catch (e) {
    console.warn('[Milkdown] setCursorPosition failed:', e);
  }
},
```

**Step 2: Update TypeScript interface**

Update the `Window.FinalFinal` interface:

```typescript
getCursorPosition: () => { line: number; column: number };
setCursorPosition: (pos: { line: number; column: number }) => void;
```

**Step 3: Build and verify**

Run: `cd web/milkdown && pnpm build`
Expected: Build succeeds

---

## Task 2: Add Line-Based Position API to CodeMirror

**Files:**
- Modify: `web/codemirror/src/main.ts`

**Step 1: Replace getCursorPosition/setCursorPosition with line-based versions**

In `window.FinalFinal`, replace the cursor methods:

```typescript
getCursorPosition(): { line: number; column: number } {
  if (!editorView) return { line: 1, column: 0 };
  const pos = editorView.state.selection.main.head;
  const line = editorView.state.doc.lineAt(pos);
  const result = {
    line: line.number,  // CodeMirror lines are 1-indexed
    column: pos - line.from
  };
  console.log('[CodeMirror] getCursorPosition: line', result.line, 'col', result.column);
  return result;
},

setCursorPosition(lineCol: { line: number; column: number }) {
  if (!editorView) return;
  const { line, column } = lineCol;

  // Clamp line to valid range
  const lineCount = editorView.state.doc.lines;
  const safeLine = Math.max(1, Math.min(line, lineCount));

  const lineInfo = editorView.state.doc.line(safeLine);
  const maxCol = lineInfo.length;
  const safeCol = Math.max(0, Math.min(column, maxCol));

  const pos = lineInfo.from + safeCol;

  console.log('[CodeMirror] setCursorPosition: line', safeLine, 'col', safeCol, '-> pos', pos);

  editorView.dispatch({
    selection: { anchor: pos },
    effects: EditorView.scrollIntoView(pos, { y: 'center' })
  });
  editorView.focus();
},
```

**Step 2: Update TypeScript interface to match Milkdown**

```typescript
getCursorPosition: () => { line: number; column: number };
setCursorPosition: (pos: { line: number; column: number }) => void;
```

**Step 3: Build and verify**

Run: `cd web/codemirror && pnpm build`
Expected: Build succeeds

---

## Task 3: Update Swift Editors to Use Line-Based Positions

**Files:**
- Modify: `final final/Editors/MilkdownEditor.swift`
- Modify: `final final/Editors/CodeMirrorEditor.swift`
- Modify: `final final/Views/ContentView.swift`

**Step 1: Create CursorPosition struct**

Add at the top of ContentView.swift (or a shared file):

```swift
struct CursorPosition: Equatable {
    let line: Int
    let column: Int

    static let start = CursorPosition(line: 1, column: 0)
}
```

**Step 2: Update MilkdownEditor.swift**

Change the cursor position binding type from `Int?` to `CursorPosition?`:

```swift
@Binding var cursorPositionToRestore: CursorPosition?
let onCursorPositionSaved: (CursorPosition) -> Void
```

Update `saveCursorPositionBeforeCleanup`:

```swift
func saveCursorPositionBeforeCleanup() {
    guard isEditorReady, let webView, !isCleanedUp else { return }
    webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { [weak self] result, _ in
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
              let line = dict["line"], let column = dict["column"] else { return }
        self?.onCursorPositionSaved(CursorPosition(line: line, column: column))
    }
}
```

Update `restoreCursorPositionIfNeeded`:

```swift
private func restoreCursorPositionIfNeeded() {
    guard let position = cursorPositionToRestoreBinding.wrappedValue else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.setCursorPosition(position)
        self?.cursorPositionToRestoreBinding.wrappedValue = nil
    }
}

func setCursorPosition(_ position: CursorPosition) {
    guard isEditorReady, let webView else { return }
    webView.evaluateJavaScript(
        "window.FinalFinal.setCursorPosition({line: \(position.line), column: \(position.column)})"
    ) { _, _ in }
}
```

**Step 3: Update CodeMirrorEditor.swift similarly**

Apply the same pattern:
- Change binding type to `CursorPosition?`
- Update callback type to `(CursorPosition) -> Void`
- Update JavaScript calls to use JSON object format

**Step 4: Update ContentView.swift**

Change the state variable:

```swift
@State private var cursorPositionToRestore: CursorPosition? = nil
```

Update both editor views to pass the new types.

**Step 5: Build and verify**

Run: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`
Expected: Build succeeds

---

## Task 4: Update Version Numbers and Commit

**Files:**
- Modify: `web/milkdown/package.json`
- Modify: `web/codemirror/package.json`
- Modify: `project.yml`

**Step 1: Bump all versions to 0.1.6**

**Step 2: Full rebuild**

```bash
cd web && pnpm build && cd ..
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

**Step 3: Commit**

```bash
git add -A
git commit -m "fix: use line-based cursor position mapping for mode toggle

The previous implementation used raw positions which don't map correctly
between ProseMirror (tree-based) and markdown (flat text). This change
uses (line, column) coordinates which work correctly in both formats."
```

---

## Task 5: End-to-End Verification

**Manual Testing Checklist:**

1. **Test cursor position preservation**
   - [ ] Place cursor at start of document, toggle modes, cursor stays at start
   - [ ] Place cursor in middle of a paragraph, toggle modes, cursor lands in same paragraph at similar column
   - [ ] Place cursor at end of document, toggle modes, cursor stays at end
   - [ ] Place cursor after a heading, toggle modes, cursor lands after same heading

2. **Test edge cases**
   - [ ] Empty document: cursor stays at position (line 1, column 0)
   - [ ] Single line: cursor column preserved
   - [ ] Document with code blocks: cursor in correct line
   - [ ] Document with lists: cursor in correct list item

3. **Console verification**
   - [ ] Check console for "getCursorPosition: line X col Y" logging
   - [ ] Check console for "setCursorPosition: line X col Y -> pos Z" logging
   - [ ] Verify line numbers match between editors

---

## Verification Summary

After completing all tasks:

- [ ] Cursor position preserved when switching WYSIWYG → Source
- [ ] Cursor position preserved when switching Source → WYSIWYG
- [ ] Cursor lands in correct paragraph/line after toggle
- [ ] Column position reasonably preserved within line
- [ ] Edge cases handled (empty doc, end of doc)
- [ ] Console logging shows matching line numbers
- [ ] No JavaScript errors
