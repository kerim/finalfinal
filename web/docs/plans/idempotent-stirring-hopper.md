# Fix: CM Caption Lookup Skips Blank Lines

## Context

The image caption hide+popup feature was implemented but captions were never found at runtime. Diagnostic logging revealed the root cause:

```
[ImagePreview] buildDecorations called, lines: 24
[ImagePreview] Built 0 replace + 3 widget decorations
```

3 images found, 0 captions found. The code only checks `doc.line(i - 1)` which is always a blank line, not the caption comment. Image blocks are stored in the database with a standard markdown blank line between caption and image:

```
<!-- caption: This is a caption -->
                                        <- blank line
![image](media/image.jpg)
```

## Fix

**File:** `web/codemirror/src/image-preview-plugin.ts` — `buildDecorations()`

### 1. Skip blank lines when looking backward for caption

Replace the current single-line check with a backward scan (capped at 3 lines to avoid matching distant orphaned captions):

```typescript
let checkLineNum = i - 1;
const minLine = Math.max(1, i - 3);
while (checkLineNum >= minLine && doc.line(checkLineNum).text.trim() === '') {
  checkLineNum--;
}
if (checkLineNum >= 1) {
  const captionLine = doc.line(checkLineNum);
  const captionMatch = CAPTION_REGEX.exec(captionLine.text.trim());
  if (captionMatch) {
    caption = captionMatch[1];
    captionLineNumber = checkLineNum;
    // Hide from caption start through blank lines to image line start
    decorations.push({
      from: captionLine.from,
      to: line.from,
      deco: Decoration.replace({}),
    });
  }
}
```

The replace range changes from "caption line + 1 char" to "caption line start through image line start" — covering the caption text and all intervening blank lines.

Handles both cases: popup-inserted captions (no blank line, degrades to `i - 1`) and database-loaded captions (1 blank line, finds caption at `i - 2`).

### 2. Keep diagnostic logging for now

Leave the canary, entry/exit logs, and summary count in place. They will confirm the fix is working (e.g., "Built 2 replace + 3 widget decorations" instead of "0 replace"). Remove only after user verifies the fix works.

## Files Modified

| File | Change |
|------|--------|
| `web/codemirror/src/image-preview-plugin.ts` | Fix backward scan (keep diagnostic logs until verified) |

## Verification

1. `cd web && pnpm build`
2. Xcode: Cmd+Shift+K, Cmd+R
3. Switch to source mode (Cmd+/)
4. Caption comments should be hidden, captions shown below images
5. "Add caption..." appears for captionless images
6. Click caption to edit; cursor skips hidden range
7. Xcode console should show "Built 2 replace + 3 widget decorations" (or similar non-zero replace count)

## Code Review Summary

Three independent reviewers validated the fix:
- **CM6 correctness**: StateField with `provide: f => EditorView.decorations.from(f)` correctly supports cross-line `Decoration.replace()` (only plugins have this restriction, not StateFields)
- **No false positives**: `CAPTION_REGEX` requires `caption:` prefix — `<!-- @sid:... -->` anchors can't match
- **No Swift-side conflicts**: No Swift code depends on caption comment line position or visibility
- **Both insertion paths handled**: popup-created captions (no blank line) and database-loaded captions (blank line) both work
- **atomicRanges**: wider replace range means cursor correctly skips the full hidden region
