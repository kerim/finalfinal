# Plan: Fix Cursor Position Near Image Nodes (v0.1.22)

## Problem Summary

When cursor is on or near lines containing image syntax (`![alt](url)`), `getCursorPosition()` returns (1, 2) instead of the actual position.

**Evidence from logs:**
```
[MilkdownEditor] setCursorPosition called with: line 47 col 89  ← Correctly receives line 47
[MilkdownEditor] saveAndNotify: posting didSaveCursorPosition with line 1 col 2  ← getCursorPosition() returns wrong value!
```

Lines 11, 17 work correctly. Line 47 (near images) fails.

## Root Cause Analysis

**Location:** `web/milkdown/src/main.ts` lines 231-313

The `getCursorPosition()` function has two phases:
1. **Line matching (lines 252-279):** Match `parentNode.textContent` against stripped markdown lines
2. **Fallback block counting (lines 282-291):** Count blocks if no match

### Why Images Break Line Matching

For image lines like `![alt](url)`:
- `stripMarkdownSyntax()` returns just `"alt"` (the alt text)
- But ProseMirror treats images as **atomic nodes** with no internal text
- `parentNode.textContent` for image nodes is often empty or just alt text
- When cursor is ON an image paragraph, parent node text doesn't match stripped line
- **Matching fails → falls through to fallback**

### Why Block Counting Fallback Fails

```typescript
view.state.doc.descendants((node, pos) => {
  if (pos >= head) return false;  // ← STOPS BEFORE current block
  if (node.isBlock && node.type.name !== 'doc') {
    blockCount++;
  }
  return true;
});
line = Math.max(1, Math.min(blockCount, mdLines.length));
```

**Issue:** The condition `pos >= head` stops traversal BEFORE the block containing the cursor is counted. This consistently undercounts by 1.

But the real problem: **when blockCount is 0** (or very small due to image node position quirks), it returns line 1.

### The Real Bug

Looking at the log pattern:
- Lines 11, 17, etc. work → line matching succeeds
- Line 47 fails → line matching fails, fallback returns 1

**The issue:** When parent node is an image node, `parentNode.textContent` is likely just the alt text or empty. The text "alt" doesn't match the stripped line because:
1. The stripped markdown is `"alt"`
2. But the image might be inline with other text, making matching ambiguous
3. Or the parent block contains multiple nodes (text + image)

## Fix Strategy

Improve line matching to handle image-containing paragraphs:

1. **Check if parent contains image nodes** - if so, use block-based line detection
2. **Fix block counting** to include the current block
3. **Add logging** to confirm which branch is taken

## Files to Modify

| File | Change |
|------|--------|
| `web/milkdown/src/main.ts` | Fix getCursorPosition() for image nodes |
| `web/package.json` | Bump to 0.1.22 |
| `project.yml` | Bump to 0.1.22 |

## Implementation

### Task 1: Add diagnostic logging to identify exact failure point

Before fixing, add console.log to see:
- What is `parentNode.textContent` for line 47?
- What node type is the parent?
- Does parent contain image children?

```typescript
getCursorPosition(): { line: number; column: number } {
  // ... existing setup ...

  const parentNode = $head.parent;
  const parentText = parentNode.textContent;

  // DIAGNOSTIC: Log parent node details
  console.log('[Milkdown] getCursorPosition diagnostic:', {
    parentType: parentNode.type.name,
    parentText: parentText.substring(0, 50),
    hasImageChild: parentNode.content.content.some(n => n.type.name === 'image'),
    childTypes: parentNode.content.content.map(n => n.type.name),
  });
```

### Task 2: Fix block counting to include current block

Change the stopping condition:

```typescript
// Fallback: count blocks up to AND INCLUDING cursor position
if (!matched) {
  let blockCount = 0;
  let foundCursorBlock = false;
  view.state.doc.descendants((node, pos) => {
    if (foundCursorBlock) return false;
    if (node.isBlock && node.type.name !== 'doc') {
      blockCount++;
      // Check if this block contains the cursor
      const nodeEnd = pos + node.nodeSize;
      if (pos <= head && head < nodeEnd) {
        foundCursorBlock = true;
        return false;
      }
    }
    return true;
  });
  line = Math.max(1, Math.min(blockCount, mdLines.length));
  console.log('[Milkdown] getCursorPosition fallback: blockCount', blockCount, '-> line', line);
}
```

### Task 3: Handle image-containing paragraphs in line matching

If parent node contains an image, try to match by position in document rather than text content:

```typescript
// Check if parent contains image nodes (which break text matching)
const hasImage = parentNode.content.content.some(
  (n: any) => n.type.name === 'image'
);

if (hasImage) {
  // For image-containing blocks, use block position counting instead
  let blockIndex = 0;
  view.state.doc.descendants((node, pos) => {
    if (node.isBlock && node.type.name !== 'doc') {
      blockIndex++;
      const nodeEnd = pos + node.nodeSize;
      if (pos <= head && head < nodeEnd) {
        line = blockIndex;
        matched = true;
        return false;
      }
    }
    return !matched;
  });
}
```

### Task 4: Bump version

- `web/package.json`: 0.1.21 → 0.1.22
- `project.yml`: 0.1.21 → 0.1.22

## Verification

```bash
cd web && pnpm build
cd .. && xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

**Manual tests:**
1. Create document with images on various lines
2. Place cursor on line with image → toggle to CM → verify correct line
3. Place cursor on line after image → toggle → verify correct line
4. Place cursor on line before image → toggle → verify correct line
5. Test with inline images: `text ![img](url) more text`

**Check console logs for diagnostic output to confirm fix path.**
