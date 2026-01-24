# Plan: Fix Cursor Mapping Remaining Issues (v0.1.18)

## Problem Summary

Testing v0.1.17 revealed three remaining issues:

1. **Off-by-one error in nested patterns**: Cursor shifts by 1 character in text like `**bold *italic* text**`
2. **Image handling**: Images render as atomic nodes in Milkdown; cursor can't be "inside" them. Need to position cursor after rendered image.
3. **Single asterisk breaks mapping**: Text like `**text with * asterisk**` resets cursor to line 1 because the italic regex's lookahead fails

---

## Root Cause Analysis

### Issue 1: Off-by-one in nested patterns
The non-greedy regex `/^(\*\*)(.+?)\1(?!\*)/` matches the outer formatting, but offset calculation assumes simple content. When nested formatting exists, the content length includes the inner formatting syntax, but `textPos` advancement doesn't account for this.

**Fix**: The issue is that `charsNeeded <= contentLen` check uses raw content length. For nested patterns, the visible text (after stripping inner formatting) is shorter than the markdown content.

### Issue 2: Image handling
Images are atomic nodes in ProseMirror. When `setCursorPosition` tries to find a node with text matching the alt text, it may find the image node but can't position inside it. The cursor should be placed **after** the image.

**Fix**: Detect when the cursor position is within an image's markdown range, and map to position immediately after the rendered image node.

### Issue 3: Single asterisk
The regex `/^(\*)(.+?)\1(?!\*)/` with lookahead `(?!\*)` fails when a single `*` appears inside `**bold**` text because the closing `**` immediately follows, making the lookahead reject the match.

**Fix**: Change the matching strategy - match `**bold**` patterns FIRST (greedy for outer delimiters), and only then look for single `*italic*` within unmatched content.

---

## Files to Modify

| File | Action |
|------|--------|
| `web/milkdown/src/cursor-mapping.ts` | Fix off-by-one, improve single asterisk handling |
| `web/milkdown/src/main.ts` | Fix image cursor positioning in setCursorPosition |
| `web/package.json` | Bump to 0.1.18 |
| `project.yml` | Bump to 0.1.18 |

---

## Implementation

### Task 1: Fix off-by-one with boundary detection

In `cursor-mapping.ts`, the issue is that when calculating positions inside formatted text, we need to return positions using 0-based indexing consistently.

**Current issue** in `textToMdOffset` (~line 24-25):
```typescript
if (charsNeeded <= contentLen) {
  return mdPos + syntaxLen + charsNeeded;
}
```

**Fix**: Use `< contentLen` instead of `<= contentLen` to correctly handle the boundary:
```typescript
if (charsNeeded < contentLen) {
  return mdPos + syntaxLen + charsNeeded;
}
// At boundary - cursor is at end of content, before closing syntax
if (charsNeeded === contentLen) {
  return mdPos + syntaxLen + contentLen;
}
```

Apply same fix to all formatting patterns (bold, italic, code, link, image, strikethrough).

### Task 2: Fix single asterisk matching order

The problem is that `/^(\*)(.+?)\1(?!\*)/` tries to match when remaining starts with `*` from `**`.

**Fix**: Match bold (`**`) BEFORE attempting italic (`*`). The current code already does this, but the lookahead `(?!\*)` is problematic.

Change the italic regex to be more specific - only match single `*` that is NOT part of `**`:
```typescript
// Don't match * if it's part of ** (check preceding character isn't *)
const italicMatch = remaining.match(/^(?<!\*)(\*)([^*]+)\1(?!\*)/);
```

Since JS doesn't support lookbehind in all contexts, alternative:
```typescript
// Only try italic if we're not at **
if (!remaining.startsWith('**')) {
  const italicMatch = remaining.match(/^\*([^*]+)\*/);
  // ... process
}
```

### Task 3: Fix image cursor positioning in main.ts

In `setCursorPosition`, when the cursor is inside an image in markdown:

**Add image detection logic** before the node search loop:
```typescript
// Check if cursor is inside an image syntax
const imageMatch = targetLine.match(/^(.*?)!\[([^\]]*)\]\([^)]+\)(.*)/);
if (imageMatch) {
  const beforeImage = imageMatch[1].length;
  const imageStart = beforeImage;
  const imageEnd = beforeImage + imageMatch[0].length - imageMatch[1].length - imageMatch[3].length;

  // If cursor is within image syntax, position after image
  if (column >= imageStart && column < imageEnd) {
    // Find image node and position after it
    // ... special handling
  }
}
```

**Alternative simpler approach**: In `setCursorPosition`, detect when the matched node is an image and position cursor at end of that node:
```typescript
view.state.doc.descendants((node, pos) => {
  if (found) return false;
  if (node.type.name === 'image') {
    // For images, position cursor after the image
    pmPos = pos + node.nodeSize;
    found = true;
    return false;
  }
  // ... existing text matching
});
```

### Task 4: Bump Version

- `web/package.json`: 0.1.17 → 0.1.18
- `project.yml`: 0.1.17 → 0.1.18

---

## Verification

```bash
cd web && pnpm build
cd .. && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

**Manual tests**:
1. Place cursor in `**bold *italic* text**` at various positions → toggle → cursor preserved exactly
2. Place cursor on/near `![image](url.png)` → toggle → cursor lands after rendered image
3. Place cursor in `**text with * asterisk**` → toggle → cursor preserved (not reset to line 1)
