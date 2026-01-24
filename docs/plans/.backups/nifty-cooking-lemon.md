# Cursor Position Fix v6 - MANDATORY VERIFICATION

## Problem

The cursor jumps when toggling between WYSIWYG and Source modes because `getCursorPosition()` in Milkdown uses `nodesBetween()` block counting, which doesn't account for blank lines in markdown.

## Solution

Replace the broken algorithm with markdown serialization approach.

---

## Task 1: Implement the Fix

**File:** `web/milkdown/src/main.ts`

### Step 1.1: Replace getCursorPosition()

Find this broken code (around line 209-241):
```typescript
getCursorPosition(): { line: number; column: number } {
  // ... code using nodesBetween() ...
}
```

Replace with:
```typescript
getCursorPosition(): { line: number; column: number } {
  if (!editorInstance) {
    console.log('[Milkdown] getCursorPosition: editor not ready');
    return { line: 1, column: 0 };
  }

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { head } = view.state.selection;

    // Get serialized markdown (includes all blank lines)
    const markdown = editorInstance.action(getMarkdown());

    // Map PM position to markdown offset proportionally
    const docSize = view.state.doc.content.size;
    const mdLength = markdown.length;

    let mdOffset = Math.round((head / Math.max(docSize, 1)) * mdLength);
    mdOffset = Math.max(0, Math.min(mdOffset, mdLength));

    // Count actual newlines to get true line number
    const textBefore = markdown.slice(0, mdOffset);
    const newlineCount = (textBefore.match(/\n/g) || []).length;
    const line = newlineCount + 1;

    // Column is offset from last newline
    const lastNewlinePos = textBefore.lastIndexOf('\n');
    const column = lastNewlinePos === -1 ? mdOffset : mdOffset - lastNewlinePos - 1;

    console.log('[Milkdown] getCursorPosition: line', line, 'col', column,
                '(head:', head, 'docSize:', docSize, 'mdOffset:', mdOffset, ')');
    return { line, column };
  } catch (e) {
    console.error('[Milkdown] getCursorPosition error:', e);
    return { line: 1, column: 0 };
  }
}
```

### Step 1.2: Replace setCursorPosition()

Find this broken code (around line 243-278):
```typescript
setCursorPosition(lineCol: { line: number; column: number }) {
  // ... code using nodesBetween() ...
}
```

Replace with:
```typescript
setCursorPosition(lineCol: { line: number; column: number }) {
  if (!editorInstance) {
    console.warn('[Milkdown] setCursorPosition: editor not ready');
    return;
  }

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { line, column } = lineCol;

    // Get serialized markdown
    const markdown = editorInstance.action(getMarkdown());
    const lines = markdown.split('\n');

    // Calculate markdown offset from line:column
    let mdOffset = 0;
    for (let i = 0; i < line - 1 && i < lines.length; i++) {
      mdOffset += lines[i].length + 1; // +1 for newline
    }
    const lineContent = lines[line - 1] || '';
    mdOffset += Math.min(column, lineContent.length);

    // Map markdown offset back to PM position
    const docSize = view.state.doc.content.size;
    const mdLength = markdown.length;

    let pmPos = Math.round((mdOffset / Math.max(mdLength, 1)) * docSize);
    pmPos = Math.max(1, Math.min(pmPos, docSize));

    console.log('[Milkdown] setCursorPosition: line', line, 'col', column,
                '-> mdOffset', mdOffset, '-> pmPos', pmPos);

    const selection = Selection.near(view.state.doc.resolve(pmPos));
    view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
    view.focus();
  } catch (e) {
    console.warn('[Milkdown] setCursorPosition failed:', e);
  }
}
```

---

## Task 2: MANDATORY VERIFICATION - Code Check

**STOP. DO NOT PROCEED UNTIL THIS PASSES.**

After editing, read `web/milkdown/src/main.ts` and verify:

### Checklist (ALL must be TRUE):

- [ ] `getCursorPosition()` contains `editorInstance.action(getMarkdown())`
- [ ] `getCursorPosition()` contains `markdown.slice(0, mdOffset)`
- [ ] `getCursorPosition()` contains `textBefore.match(/\n/g)`
- [ ] `getCursorPosition()` does NOT contain `nodesBetween`
- [ ] `setCursorPosition()` contains `markdown.split('\n')`
- [ ] `setCursorPosition()` does NOT contain `nodesBetween`

**If ANY check fails:** Go back to Task 1 and fix it. Do not continue.

---

## Task 3: Build and Runtime Test

### Step 3.1: Build
```bash
cd web && pnpm build
```

### Step 3.2: Verify build output contains new code
```bash
grep -c "getMarkdown" "final final/Resources/editor/milkdown/milkdown.js"
```
Expected: A number > 0 (proves the new code is in the bundle)

### Step 3.3: Build Xcode
```bash
xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

---

## Task 4: Version Bump

Only after Tasks 1-3 pass:
- Bump version to 0.1.10 in `project.yml`, `web/package.json`, `web/milkdown/package.json`, `web/codemirror/package.json`

---

## Task 5: Commit

```bash
git add web/milkdown/src/main.ts project.yml web/package.json web/milkdown/package.json web/codemirror/package.json
git commit -m "fix: implement markdown serialization for cursor position mapping

Replaces broken nodesBetween() block counting with markdown serialization.
This correctly handles blank lines when mapping cursor positions between
WYSIWYG (Milkdown) and Source (CodeMirror) modes.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Verification Summary

The implementation is NOT complete until:
1. ✅ Code contains `getMarkdown()` calls in both cursor functions
2. ✅ Code does NOT contain `nodesBetween` in cursor functions
3. ✅ Build succeeds
4. ✅ grep confirms new code is in bundle
5. ✅ User manually tests cursor position preservation
