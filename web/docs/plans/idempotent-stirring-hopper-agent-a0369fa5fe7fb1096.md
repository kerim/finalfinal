# Review: Proposed Fix for CM6 Caption Backward-Scan Bug

## Summary

The proposed fix in `/Users/niyaro/Documents/Code/ff-dev/images/web/docs/plans/idempotent-stirring-hopper.md` addresses a real bug: `buildDecorations()` only checks `doc.line(i - 1)` for a caption comment, but in practice there is always a blank line between the caption comment and the image markdown (standard markdown block separator). The fix replaces the single-line check with a backward scan that skips blank lines.

The fix is correct in principle with one important plan deviation and two minor suggestions detailed below.

---

## What Was Done Well

- The diagnosis is accurate. The `insertImage()` function in `api.ts` (line 692) inserts captions as `<!-- caption: text -->\n![...](media/...)`, and when preceded by existing content, blank lines are added (lines 702-704). The database round-trip through Milkdown also standardizes blank lines between block elements. So `doc.line(i - 1)` reliably lands on a blank line, not the caption.
- The backward-scan loop (`while checkLineNum >= 1 && blank`) is a clean pattern.
- Changing the replace range from `[prevLine.from, prevLine.to + 1]` to `[captionLine.from, line.from]` is the right approach -- it covers the caption line plus all intervening blank lines in a single replace decoration, eliminating the visual gap.
- The CM6 architecture remains correct: replace decorations stay in a StateField (direct provision), which is required for line-break-crossing replacements per CM6 documentation. The agent review in `idempotent-stirring-hopper-agent-a2efa842772a9170b.md` confirmed this.

---

## Answers to the Six Review Questions

### Q1: Is Decoration.replace spanning captionLine.from to line.from valid in CM6?

Yes. This range crosses line boundaries (caption line plus blank lines), which requires the decoration to come from a directly provided source (StateField). The code uses a StateField with `provide: f => EditorView.decorations.from(f)`, which is the correct direct provision mechanism. The CM6 documentation states: "Only decoration sets provided directly are allowed to influence the editor's vertical layout structure." The CM6 changelog for v0.19.36 confirms: "Replacing decorations that cross lines are ignored, when provided by a plugin" -- meaning they are allowed when provided by a StateField.

### Q2: RangeSetBuilder ordering

Correct. The sorting comparator is:

```typescript
decorations.sort((a, b) => a.from - b.from || (a.to - a.from) - (b.to - b.from));
```

The replace decoration has `from = captionLine.from` (earlier in the document) and the widget has `from = line.to` (later). Since `captionLine.from < line.to`, they sort by `from` position with no ambiguity. `RangeSetBuilder` requires decorations in document order, which is satisfied.

### Q3: Does a multi-line Decoration.replace work correctly as an atomic range?

Yes. The `atomicImageRanges` facet returns the entire `DecorationSet` from the StateField. CM6 treats each range as an atomic unit -- the cursor skips from before the caption to the start of the image line. Zero-width widget ranges at `line.to` are no-ops for cursor movement.

### Q4: Edge case -- image on line 1 or 2

Safe. If the image is on line 1, the existing `if (i > 1)` guard prevents any backward scan. If the image is on line 2, `checkLineNum` starts at 1. If line 1 is blank, the while loop decrements to 0, exits (condition `checkLineNum >= 1` fails), and the outer `if` also fails. If line 1 is a caption, the while loop does not execute, and the regex check proceeds normally.

### Q5: Edge case -- many blank lines between caption and image

Safe for the standard case. Each image's backward scan is independent and stops at the first non-blank line, so there is no cross-contamination between images.

One edge case to consider:

```
<!-- caption: Orphaned caption -->



(many blank lines, no image between)

![image](media/photo.jpg)
```

The backward scan would skip all blank lines and "adopt" the orphaned caption. This is unlikely in practice but could be guarded against with a maximum scan distance (see Suggestions below).

### Q6: Performance

Negligible. The backward scan adds at most 1-2 iterations per image in the common case (one blank line). `doc.line()` is O(1) in CM6. For a document with 3-5 images, this adds a handful of trivial string comparisons.

---

## Important Issue (Should Fix)

### Missing saveAndNotify dismiss call (Step 6 from plan)

The original plan specifies Step 6: "Add `dismissImageCaptionPopup()` at the top of `saveAndNotify()`" for when the editor toggles between CM and Milkdown via Cmd+/. Looking at the `api.ts` diff, this was NOT implemented. The dismiss calls were correctly added to `setContent()` (line 102) and `resetForProjectSwitch()` (line 1032), but `saveAndNotify()` was omitted.

When the CM WebView is torn down on editor switch, the popup's DOM is destroyed along with the body, so this does not cause a visible leak. However, calling `dismissImageCaptionPopup()` before the switch would properly clear the module-level state variables (`editingView`, `editingImageLineNumber`, etc.), preventing potential race conditions if any code path references them during teardown.

This is a plan deviation that should be addressed.

---

## Suggestions (Nice to Have)

### 1. Consider a maximum backward scan distance

The while loop scans backward through ALL blank lines without limit. Adding a cap (e.g., 3 lines) would prevent accidentally matching a distant orphaned caption:

```typescript
const MAX_BLANK_SCAN = 3;
let scanned = 0;
while (checkLineNum >= 1 && doc.line(checkLineNum).text.trim() === '' && scanned < MAX_BLANK_SCAN) {
  checkLineNum--;
  scanned++;
}
```

In practice, markdown block elements are separated by exactly one blank line, so a cap of 3 is generous and still prevents pathological cases.

### 2. Export isCommittingCaption as a getter function

In `image-caption-popup.ts` line 28:

```typescript
export let isCommittingCaption = false;
```

This is read in `image-preview-plugin.ts` line 247. Exporting a mutable `let` binding works in ES modules (the import sees the live binding), but a getter function is more conventional and easier to reason about:

```typescript
let _isCommittingCaption = false;
export function getIsCommittingCaption(): boolean { return _isCommittingCaption; }
```

---

## Additional Observation: commitEdit Insert Format

When `commitEdit()` in `image-caption-popup.ts` adds a new caption (line 159), it inserts `<!-- caption: text -->\n` directly before the image line with NO blank line. Images imported from Swift/database have a blank line between caption and image. The proposed fix handles both cases correctly:

- With blank line: while loop skips it, finds caption, replace range covers both lines
- Without blank line: while loop does not fire, caption is found on the immediately preceding line

The visual result is identical. But the underlying document structure is inconsistent across the two insertion paths. This is not a bug, but worth being aware of for round-tripping between CM and Milkdown (Milkdown may normalize spacing on save).

---

## Verdict

The proposed backward-scan fix is correct and safe for all standard cases.

| Category | Count | Details |
|----------|-------|---------|
| Critical (must fix) | 0 | -- |
| Important (should fix) | 1 | Missing `saveAndNotify()` dismiss call (Step 6 from plan) |
| Suggestions | 2 | Max scan distance; `isCommittingCaption` getter |
