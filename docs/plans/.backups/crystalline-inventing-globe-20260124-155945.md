# Plan: Fix Cursor Mapping Edge Cases (v0.1.17)

## Problem Summary

The cursor-mapping.ts implementation has regex patterns that fail on common markdown:
1. **Nested formatting**: `**bold *italic* text**` fails because `[^*_]+` excludes asterisks
2. **Missing GFM features**: Strikethrough `~~text~~` and images `![alt](url)` not handled
3. **Code duplication**: Markdown stripping logic duplicated in main.ts

The duplicate paragraph issue is noted but deferred (requires significant redesign).

---

## Files to Modify

| File | Action |
|------|--------|
| `web/milkdown/src/cursor-mapping.ts` | Fix regexes, add strikethrough/image support |
| `web/milkdown/src/main.ts` | Extract shared helper, use fixed patterns |
| `web/package.json` | Bump to 0.1.17 |
| `project.yml` | Bump to 0.1.17 |

---

## Implementation

### Task 1: Fix Bold/Italic Regex in cursor-mapping.ts

**Problem**: `[^*_]+` rejects any content containing `*` or `_`

**Current (line 18)**:
```typescript
const boldMatch = remaining.match(/^(\*\*|__)([^*_]+)\1/);
```

**Fixed**: Use non-greedy `.+?` with lookahead:
```typescript
const boldMatch = remaining.match(/^(\*\*)(.+?)\1(?![*])/);
const boldAltMatch = remaining.match(/^(__)(.+?)\1(?![_])/);
```

Same fix for italic patterns (line 33).

### Task 2: Add Strikethrough Support

Add after link handling (~line 73):
```typescript
// Strikethrough ~~text~~
const strikeMatch = remaining.match(/^~~(.+?)~~/);
if (strikeMatch) {
  const contentLen = strikeMatch[1].length;
  const charsNeeded = textOffset - textPos;
  if (charsNeeded <= contentLen) {
    return mdPos + 2 + charsNeeded; // +2 for opening ~~
  }
  mdPos += 4 + contentLen; // ~~ + content + ~~
  textPos += contentLen;
  continue;
}
```

Add corresponding inverse in `mdToTextOffset`.

### Task 3: Add Image Support

Add after link handling:
```typescript
// Image ![alt](url)
const imageMatch = remaining.match(/^!\[([^\]]*)\]\([^)]+\)/);
if (imageMatch) {
  const altLen = imageMatch[1].length;
  const charsNeeded = textOffset - textPos;
  if (charsNeeded <= altLen) {
    return mdPos + 2 + charsNeeded; // +2 for ![
  }
  mdPos += imageMatch[0].length;
  textPos += altLen;
  continue;
}
```

### Task 4: Extract Shared Helper in main.ts

Create helper function:
```typescript
function stripMarkdownSyntax(line: string): string {
  return line
    .replace(/^#+\s*/, '')              // headings
    .replace(/^\s*[-*+]\s*/, '')        // unordered list items
    .replace(/^\s*\d+\.\s*/, '')        // ordered list items
    .replace(/^\s*>\s*/, '')            // blockquotes
    .replace(/~~(.+?)~~/g, '$1')        // strikethrough
    .replace(/\*\*(.+?)\*\*/g, '$1')    // bold
    .replace(/__(.+?)__/g, '$1')        // bold alt
    .replace(/\*(.+?)\*/g, '$1')        // italic
    .replace(/_([^_]+)_/g, '$1')        // italic alt
    .replace(/`([^`]+)`/g, '$1')        // inline code
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1') // images
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')  // links
    .trim();
}
```

Replace duplicated code in `getCursorPosition` (lines 231-240) and `setCursorPosition` (lines 291-300).

### Task 5: Bump Version

- `web/package.json`: 0.1.16 → 0.1.17
- `project.yml`: 0.1.16 → 0.1.17

---

## Deferred: Duplicate Paragraph Handling

The issue where identical paragraphs cause incorrect cursor placement requires a different approach (possibly using document position context or paragraph indexing). This is deferred as it:
- Requires significant architectural changes
- Is an edge case (identical paragraphs are uncommon in real documents)
- Can be addressed in a follow-up

---

## Verification

```bash
cd web && pnpm build
cd .. && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

**Manual tests**:
1. Place cursor in `**bold *italic* text**` → toggle → cursor preserved
2. Place cursor in `~~strikethrough~~` → toggle → cursor preserved
3. Place cursor after `![image](url.png)` → toggle → cursor preserved
4. Place cursor in `**text with * asterisk**` → toggle → cursor preserved
