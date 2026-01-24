# Plan: Debug Cursor Position Near Image Nodes (v0.1.22)

## Problem Summary

When cursor is on or near lines containing image syntax, `getCursorPosition()` returns (1, 2) instead of the actual position.

**Evidence from logs:**
```
[MilkdownEditor] setCursorPosition called with: line 47 col 89  ← Correctly receives line 47
[MilkdownEditor] saveAndNotify: posting didSaveCursorPosition with line 1 col 2  ← getCursorPosition() returns wrong!
```

Lines 11, 17 work. Line 47 (near images) fails.

## Hypothesis

**Location:** `web/milkdown/src/main.ts` lines 231-313

The `getCursorPosition()` function:
1. **Line matching (252-279):** Match `parentNode.textContent` against stripped markdown lines
2. **Fallback block counting (282-291):** Count blocks if no match

**Suspected failure:** For image-containing lines, text matching fails and block counting returns wrong value.

## Phase 1: Add Diagnostic Logging (DO THIS FIRST)

Per systematic debugging: **gather evidence before fixing**.

### Task 1: Add comprehensive diagnostics to getCursorPosition()

```typescript
getCursorPosition(): { line: number; column: number } {
  // ... existing setup ...

  const parentNode = $head.parent;
  const parentText = parentNode.textContent;

  // DIAGNOSTIC: Log everything we need to understand the failure
  console.log('[Milkdown] getCursorPosition DEBUG:', JSON.stringify({
    head: head,
    parentType: parentNode.type.name,
    parentTextLength: parentText.length,
    parentTextPreview: parentText.substring(0, 80),
    childCount: parentNode.content.childCount,
    childTypes: Array.from(parentNode.content.content || []).map((n: any) => n.type?.name),
  }));
```

Also log inside the matching loop:

```typescript
for (let i = 0; i < mdLines.length; i++) {
  const stripped = stripMarkdownSyntax(mdLines[i]);

  // Log first few iterations to see what's being compared
  if (i < 5 || i === 46) {  // Log line 47 (index 46)
    console.log(`[Milkdown] Line ${i+1} match check:`, JSON.stringify({
      original: mdLines[i].substring(0, 60),
      stripped: stripped.substring(0, 60),
      parentText: parentText.substring(0, 60),
      exactMatch: stripped === parentText,
    }));
  }
```

And log the fallback:

```typescript
if (!matched) {
  let blockCount = 0;
  let positions: number[] = [];
  view.state.doc.descendants((node, pos) => {
    if (pos >= head) return false;
    if (node.isBlock && node.type.name !== 'doc') {
      blockCount++;
      positions.push(pos);
    }
    return true;
  });
  console.log('[Milkdown] FALLBACK used:', JSON.stringify({
    head: head,
    blockCount: blockCount,
    blockPositions: positions.slice(-5),  // Last 5 positions
    resultLine: Math.max(1, Math.min(blockCount, mdLines.length)),
  }));
  line = Math.max(1, Math.min(blockCount, mdLines.length));
}
```

### Task 2: Build, run, and capture output

```bash
cd web && pnpm build && cd .. && xcodegen generate && \
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Run the app, place cursor on line 47, toggle to CodeMirror, and capture console output.

## Phase 2: Analyze Evidence

After running Phase 1, we'll know:
1. What `parentNode.type.name` is for line 47 (paragraph? image?)
2. What `parentText` contains
3. Whether matching fails at exact match, partial match, or both
4. What `blockCount` the fallback produces

## Phase 3: Fix Based on Evidence

**Only after Phase 1-2 are complete**, implement the fix based on what the logs reveal.

Likely fixes (to be confirmed by logs):
- If `parentNode` is an image node: use block counting from start
- If block counting undercounts: fix the `pos >= head` condition
- If text matching fails due to image alt text: strip images differently

## Files to Modify

| File | Change |
|------|--------|
| `web/milkdown/src/main.ts` | Add diagnostics first, then fix based on evidence |
| `web/package.json` | Bump to 0.1.22 |
| `project.yml` | Bump to 0.1.22 |

## Verification

After fix is implemented based on diagnostic evidence:

1. Place cursor on line with image → toggle to CM → verify correct line
2. Place cursor on line after image → toggle → verify correct line
3. Place cursor on line before image → toggle → verify correct line
4. Verify lines 11, 17 still work correctly
5. Test rapid toggling
