# Plan: Fix getCursorPosition Regression (v0.1.20)

## Problem Summary

v0.1.19 introduced a regression: toggling from CM → MD now sends cursor to line 1 instead of the correct position.

**Evidence from logs:**
```
[MilkdownEditor] setCursorPosition called with: line 47 col 90    ← CM→MD works
[CodeMirrorEditor] cursorPositionToRestore=...line: 1, column: 2  ← MD→CM broken!
```

The problem is in `getCursorPosition` - the fuzzy matching added in v0.1.19 is matching the wrong line.

---

## Root Cause

In v0.1.19, I added this fuzzy matching code at lines 268-275:

```typescript
if (stripped && parentText && stripped.length > 0 && parentText.length > 0) {
  if (stripped.includes(parentText) || parentText.includes(stripped)) {
    line = i + 1;
    matched = true;
    break;
  }
}
```

**The bug:** If `parentText` is "Some text here" and line 1's stripped content is "Some introduction", then `stripped.includes("Some")` would be false, but if parentText contains any common word like "the", and line 1 also contains "the", it matches incorrectly.

Even worse: `parentText.includes(stripped)` - if line 1 is short (like "A" or blank), this would match almost anything.

---

## Files to Modify

| File | Action |
|------|--------|
| `web/milkdown/src/main.ts` | Revert broken fuzzy matching in getCursorPosition |
| `web/package.json` | Bump to 0.1.20 |
| `project.yml` | Bump to 0.1.20 |

---

## Implementation

### Task 1: Fix getCursorPosition line matching

Remove the broken fuzzy matching. Keep only:
1. Exact match (original, working)
2. Partial prefix match for long lines (original, working)
3. Block-count fallback (useful but only as last resort)

**Replace lines 248-296 in main.ts with:**

```typescript
// Find which markdown line contains this paragraph's text
let line = 1;
let matched = false;

for (let i = 0; i < mdLines.length; i++) {
  const stripped = stripMarkdownSyntax(mdLines[i]);

  // Exact match
  if (stripped === parentText) {
    line = i + 1;
    matched = true;
    break;
  }

  // Partial match (for long lines that may get truncated)
  if (stripped && parentText &&
      parentText.startsWith(stripped) &&
      stripped.length >= 10) {
    line = i + 1;
    matched = true;
    break;
  }

  // Reverse partial match (stripped is longer than parentText)
  if (stripped && parentText &&
      stripped.startsWith(parentText) &&
      parentText.length >= 10) {
    line = i + 1;
    matched = true;
    break;
  }
}

// Fallback: count blocks from document start to find line
if (!matched) {
  let blockCount = 0;
  view.state.doc.descendants((node, pos) => {
    if (pos >= head) return false;
    if (node.isBlock && node.type.name !== 'doc') {
      blockCount++;
    }
    return true;
  });
  line = Math.max(1, Math.min(blockCount, mdLines.length));
}
```

Key changes:
- Removed `includes()` checks that were too greedy
- Use `startsWith()` in both directions (prefix matching only)
- Require minimum length of 10 chars to avoid matching short common strings

### Task 2: Bump Version

- `web/package.json`: 0.1.19 → 0.1.20
- `project.yml`: 0.1.19 → 0.1.20

---

## Verification

```bash
cd web && pnpm build
cd .. && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

**Manual tests:**
1. Place cursor on line 47 in CM → toggle to MD → toggle back to CM → cursor should be on line 47
2. Test with document containing images
3. Verify nested formatting still works (tested working in v0.1.18)
