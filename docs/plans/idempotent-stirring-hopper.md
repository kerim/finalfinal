# Plan: Fix Remaining Image Issues (Round 2)

## Context

Round 1 implemented Fixes 0-6 from the original plan (observer cleanup, CM image insertion, centering, `--editor-muted` CSS variable, splice-during-visit fix, toMarkdown caption serialization, CM caption display, orientation-aware sizing). User testing confirmed most fixes work, but three issues remain:

1. **Caption contrast still insufficient** — `--editor-muted` maps to `editorTextSecondary`, which is too muted at reduced font sizes
2. **CM caption UI not appropriate** — inline styles in `image-preview-plugin.ts` don't look good; should use CSS classes
3. **Duplication bug persists** — the splice-during-visit fix alone didn't resolve it

## Root Cause Analysis

### Caption Contrast

`--editor-muted` now correctly uses `editorTextSecondary`, but those colors are deliberately muted for UI chrome (heading placeholders, section breaks, etc.). At the reduced font size used for captions (0.85em in CM, 0.9em in Milkdown), the contrast drops below readable levels, especially in Low Contrast Night (`#777b84` on `#111113` ≈ 3.5:1 ratio).

Captions are **user content**, not decorative UI. They should use `--editor-text` (the primary text color), not `--editor-muted`. The smaller font size already provides visual hierarchy.

### CM Caption UI

The `.cm-image-caption` div in `image-preview-plugin.ts:91-99` uses all inline styles. No CSS class exists in `styles.css`. Milkdown uses a proper `.figure-caption` class in `styles.css:212-220` with clean separation.

### Duplication

`toMarkdown` (image-plugin.ts:136-155) emits the caption as a **separate block-level** `html` mdast node before the `paragraph > image`. Remark-stringify inserts a blank line between block-level siblings:

```
<!-- caption: text -->
                        ← blank line inserted by remark-stringify
![alt](media/file.png)
```

Swift's `splitIntoRawBlocks` (BlockParser.swift:144-223) splits on blank lines, creating **two blocks**:
- Block A: `<!-- caption: text -->` → classified as `.paragraph`
- Block B: `![alt](media/file.png)` → classified as `.image`

The caption paragraph block persists in the database. On each content roundtrip (edit → save → reload), the caption exists in **two places**: as Block A (standalone paragraph) and embedded in the figure node's `caption` attribute. This accumulates over roundtrips.

## Fix A: Caption Contrast

**Change:** Both Milkdown and CM captions use `--editor-text` instead of `--editor-muted`.

**Reviewer note:** In High Contrast Night, `editorText` (#BD6B15) is actually darker than `editorTextSecondary` (#ffa057) — an intentional design inversion for the amber-on-black theme. However, #BD6B15 on #0a0a0a still gives ~5:1 contrast (WCAG AA compliant), and matching body text color is consistent since ALL text in that theme is amber. The smaller font size provides visual hierarchy.

### File: `web/milkdown/src/styles.css` (line 216)

```css
/* Before */
color: var(--editor-muted, #666);

/* After */
color: var(--editor-text, #1a1a1a);
```

Note: The `.figure-caption:empty::before` placeholder (line 224) should keep `--editor-muted` — it's UI chrome, not content.

### File: `web/codemirror/src/image-preview-plugin.ts` (line 94)

Remove the inline `color` style — it will be handled by the new CSS class (Fix B).

## Fix B: CM Caption & Image Styles — Move to CSS Classes

Move ALL static inline styles from `image-preview-plugin.ts` to CSS classes. Keep only dynamic styles (orientation-aware `maxHeight` in `onload`) as inline JS.

### File: `web/codemirror/src/styles.css`

Add these classes:

```css
/* Image preview container */
.cm-image-preview {
  text-align: center;
}

/* Image within preview */
.cm-image-preview img {
  max-width: 100%;
  max-height: 300px; /* Initial cap, overridden by JS after load */
  display: block;
  margin: 4px auto 8px auto;
  border-radius: 4px;
}

/* Caption below image */
.cm-image-caption {
  margin-top: -4px;
  margin-bottom: 8px;
  font-size: 0.85em;
  color: var(--editor-text, #1a1a1a);
  text-align: center;
  font-style: italic;
}

/* Error state when image fails to load */
.cm-image-preview-error {
  color: var(--editor-muted, var(--editor-text-secondary, #888));
  font-style: italic;
  padding: 4px 0;
}
```

### File: `web/codemirror/src/image-preview-plugin.ts`

**toDOM() changes:**

1. Remove wrapper inline style (line 46) — handled by `.cm-image-preview` CSS
2. Remove img static inline styles (lines 52-56) — handled by `.cm-image-preview img` CSS. Keep only `img.draggable = false` (not CSS-settable).
3. Replace caption inline styles (lines 90-101) with class-only:
```typescript
if (this.caption) {
  const captionEl = document.createElement('div');
  captionEl.className = 'cm-image-caption';
  captionEl.textContent = this.caption;
  wrapper.appendChild(captionEl);
}
```
4. Replace error handler inline styles (lines 76-85) with class:
```typescript
img.onerror = () => {
  wrapper.textContent = `[Image not found: ${this.src}]`;
  wrapper.className = 'cm-image-preview cm-image-preview-error';
  // requestMeasure stays
};
```
5. **Keep** the `onload` dynamic styles (lines 60-68) as inline JS — orientation is only known at runtime.

**Bug fix:** The error handler (line 78) uses `--text-secondary` — a nonexistent CSS variable. The new `.cm-image-preview-error` class uses the correct `--editor-muted` with `--editor-text-secondary` fallback.

## Fix C: Caption Duplication — Keep Caption+Image Together in BlockParser

**Approach:** Modify `splitIntoRawBlocks` to recognize `<!-- caption: ... -->` blocks and keep them attached to the following image line. Also update `detectBlockType` to correctly classify the combined block.

### File: `final final/Services/BlockParser.swift`

#### Change 1: `splitIntoRawBlocks` (~line 198, blank line handling)

After the existing footnote continuation logic and before the block flush, add a caption-image continuation check:

```swift
// Check if current block is a caption comment — keep with following image
let trimmedBlock = currentBlock.trimmingCharacters(in: .whitespacesAndNewlines)
if trimmedBlock.range(of: "^<!--\\s*caption:", options: .regularExpression) != nil
   && trimmedBlock.hasSuffix("-->") {
    // Peek ahead for image line
    var nextIdx = index + 1
    while nextIdx < lines.count
          && lines[nextIdx].trimmingCharacters(in: .whitespaces).isEmpty {
        nextIdx += 1
    }
    if nextIdx < lines.count
       && lines[nextIdx].trimmingCharacters(in: .whitespaces).hasPrefix("![") {
        // Absorb blank line — keep caption and image in same block
        currentBlock += line + "\n"
        continue
    }
}
```

This goes inside the `if line.trimmingCharacters(in: .whitespaces).isEmpty {` block, after the footnote def check and before the `if !currentBlock...isEmpty { blocks.append(...) }` flush.

#### Change 2: `detectBlockType` (~line 271, before `.image` check)

Add detection for combined caption+image blocks:

```swift
// Caption + Image: <!-- caption: text -->\n...\n![alt](url)
if trimmed.hasPrefix("<!--") && trimmed.contains("caption:") {
    if trimmed.range(of: "!\\[", options: .regularExpression) != nil {
        return (.image, nil)
    }
}
```

Place this before the existing `// Image: ![alt](url)` check at line 271.

## Reviewer Findings (3 parallel agents)

| Finding | Severity | Action |
|---------|----------|--------|
| HC Night: `editorText` darker than `editorTextSecondary` (inverted) | Note | Acceptable — #BD6B15 on #0a0a0a is ~5:1 contrast (WCAG AA) |
| `--text-secondary` typo in onerror handler (should be `--editor-text-secondary`) | Bug | Fixed by new `.cm-image-preview-error` CSS class |
| Static inline styles on wrapper/img should move to CSS | Improvement | Added to Fix B |
| Error state inline styles should be CSS class | Improvement | Added to Fix B |
| Do NOT copy Milkdown's editing affordances (min-height, :focus, :empty::before) | Guidance | CM class is read-only display only |
| BlockParser fix is safe, follows footnote continuation precedent | Confirmation | No changes needed |
| JS-side fix (caption inside paragraph) would NOT work | Confirmation | Swift-side fix confirmed correct |

## Files Modified

| File | Fix |
|------|-----|
| `web/milkdown/src/styles.css` | Fix A: `.figure-caption` uses `--editor-text` |
| `web/codemirror/src/image-preview-plugin.ts` | Fix A+B: remove ALL static inline styles, use CSS classes, fix `--text-secondary` typo |
| `web/codemirror/src/styles.css` | Fix B: add `.cm-image-preview`, `.cm-image-preview img`, `.cm-image-caption`, `.cm-image-preview-error` |
| `final final/Services/BlockParser.swift` | Fix C: keep caption+image together in `splitIntoRawBlocks` + `detectBlockType` |

## Implementation Order

1. Fix B — CM CSS classes (foundation for Fix A)
2. Fix A — Caption contrast (Milkdown CSS + CM plugin inline style removal)
3. Fix C — BlockParser caption+image grouping

## Verification

1. `cd web && pnpm build` — compiles without errors
2. Build in Xcode
3. **Fix A:** Captions are readable in all four themes (especially Low Contrast Night and Low Contrast Day). In HC Night, captions match body text color (dark amber).
4. **Fix B:** CM caption text renders as properly styled italic text below image. Error state (`[Image not found: ...]`) uses themed muted color, not hardcoded #888.
5. **Fix C:** In Milkdown, add 2+ images with captions → edit a caption → blur → no duplication. Switch to CM (Cmd+/) → caption visible above image → switch back to Milkdown → still no duplication.
