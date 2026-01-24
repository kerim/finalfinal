# Plan: Fix Line-to-Block Mapping in setCursorPosition (v0.1.24)

## Root Cause (Verified)

**The bug is in `setCursorPosition()`, not `getCursorPosition()`.**

### Evidence

```
[CodeMirrorEditor] saveAndNotify: line 25 col 15
[MilkdownEditor] setCursorPosition called with: line 25 col 15
[MilkdownEditor] saveAndNotify: line 49 col 13  ← Wrong!
CURSOR DIAGNOSTICS: {"parentTextPreview":"Edge Cases"}  ← Line 49, not 25!
```

### Analysis

Mapping markdown lines to ProseMirror blocks:

| MD Line | Content | PM Block |
|---------|---------|----------|
| 1 | # Cursor Mapping... | 1 |
| 2 | (empty) | - |
| 3 | Test each pattern... | 2 |
| ... | (empty lines don't create blocks) | ... |
| 25 | Multiple: ![first]... | **13** |
| 47 | This paragraph has... | **24** |
| 49 | ## Edge Cases | **25** |

The fallback in `setCursorPosition()` does:
```typescript
if (blockCount === line)  // BUG: assumes line# = block#
```

When `line=25`, it finds PM block 25 which is "Edge Cases" (line 49), not "Multiple:..." (line 25).

**Empty markdown lines don't create ProseMirror blocks, breaking the 1:1 assumption.**

## Fix

### Task 1: Fix setCursorPosition() fallback

Replace block counting with content-line counting:

```typescript
// Fallback: map markdown line to PM block via content line index
if (!found) {
  // Count non-empty lines up to target line to get content index
  let contentLineIndex = 0;
  for (let i = 0; i < line; i++) {
    if (lines[i].trim() !== '') {
      contentLineIndex++;
    }
  }

  // Find the contentLineIndex-th block in PM
  let blockCount = 0;
  view.state.doc.descendants((node, pos) => {
    if (found) return false;
    if (node.isBlock && node.type.name !== 'doc') {
      blockCount++;
      if (blockCount === contentLineIndex) {
        pmPos = pos + 1 + Math.min(textOffset, node.content.size);
        found = true;
        return false;
      }
    }
    return true;
  });
  console.log('[Milkdown] setCursorPosition: fallback used contentLineIndex', contentLineIndex);
}
```

### Task 2: Same fix for getCursorPosition() fallback

The same bug exists in `getCursorPosition()` fallback (though it triggers less often since text matching usually works for non-image lines).

### Task 3: Version bump

- `web/package.json`: 0.1.23 → 0.1.24
- `project.yml`: 0.1.23 → 0.1.24

### Task 4: Remove diagnostic logging

Clean up the verbose diagnostics added in v0.1.22, keep only essential logging.

## Files to Modify

| File | Change |
|------|--------|
| `web/milkdown/src/main.ts` | Fix both fallbacks, clean up diagnostics |
| `web/package.json` | Bump to 0.1.24 |
| `project.yml` | Bump to 0.1.24 |

## Verification

Using test document:
```markdown
# Cursor Mapping Test Document
(empty)
Test each pattern...
...
Multiple: ![first](url1.png) and ![second](url2.png) images.  ← Line 25
...
This paragraph has **bold**, *italic*... ![images](img.png)...  ← Line 47
```

1. Place cursor on line 25 → toggle → should stay on line 25 (not jump to 49)
2. Place cursor on line 47 → toggle → should stay on line 47 (not jump to 1)
3. Lines without images (11, 17) should continue working
4. Rapid toggling should maintain position
