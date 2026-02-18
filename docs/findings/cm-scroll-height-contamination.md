# CM6 Scroll Height Contamination

Root cause analysis for massive document height overestimation and "Viewport failed to stabilize" errors in CodeMirror source mode.

**Status:** Fixed (Phase 1 + Phase 1b + Phase 2)
**File:** `web/codemirror/src/line-height-fix.ts`

---

## Symptoms

- Total document height ballooned from ~2,200px (correct) to ~71,000px
- Off-screen body lines estimated at 1,800-5,300px each (should be 31-186px)
- "Viewport failed to stabilize" warnings on every heading entering the viewport
- Visible only in documents with headings and long paragraphs (short documents unaffected)

## Investigation

### How CM6 estimates off-screen line heights

CM6's virtual viewport only renders lines near the scroll position. Off-screen lines get height estimates from two internal functions:

```javascript
// HeightOracle (index.js:5175) - bulk estimate for a range of lines
heightForGap(from, to) {
    let lines = this.doc.lineAt(to).number - this.doc.lineAt(from).number + 1;
    if (this.lineWrapping)
        lines += Math.max(0, Math.ceil(
            ((to - from) - (lines * this.lineLength * 0.5)) / this.lineLength
        ));
    return this.lineHeight * lines;
}

// HeightOracle (index.js:5181) - single line estimate
heightForLine(length) {
    if (!this.lineWrapping) return this.lineHeight;
    let lines = 1 + Math.max(0, Math.ceil(
        (length - this.lineLength) / Math.max(1, this.lineLength - 5)
    ));
    return lines * this.lineHeight;
}
```

These depend on three oracle values:
- `lineHeight` -- default line height in pixels
- `charWidth` -- average character width in pixels
- `lineLength` -- chars per visual line, computed as `max(5, contentWidth / charWidth)`

### How CM6 measures these values

`DocView.measureTextSize()` (docview.ts) finds a short visible line (<=20 chars, ASCII-only) and measures its rendered dimensions. The caller (index.js:6181) uses the returned `charWidth` to compute `lineLength`.

### The contamination

In our document, the only qualifying visible line was line 15 (`# Slides`, 9 chars) -- an H1 heading with decoration-applied CSS (`font-size: 31px` vs body `18px`). This returned:

| Metric | Contaminated | Correct | Effect |
|--------|-------------|---------|--------|
| `lineHeight` | 37px | 31px | +19% height per line |
| `charWidth` | ~16px | ~9px | `lineLength` drops from ~72 to ~40 |

The `charWidth` contamination was far more damaging. With `lineLength = 40`, a 500-char body line was estimated to wrap into 14 visual lines instead of 8, giving it a height of ~434px instead of ~248px.

### Compounding factors

1. **Document structure:** Long paragraphs (300-870 chars) with few headings meant most content was off-screen and subject to the faulty estimates
2. **Hidden anchors:** Section ID anchors (`<!-- @sid:UUID -->`) added ~50-100 hidden chars per line, inflating the raw char count that `heightForLine()` used
3. **Heading heights:** Off-screen headings got body-metric estimates, underestimating their actual height (opposite direction from body lines)

## The Fix (Three Phases)

### Phase 1: Correct lineHeight

Monkey-patch `docView.measureTextSize` to replace the returned `lineHeight` with a measurement from a clean dummy `.cm-line` element inserted into `contentDOM`. Uses `view.observer.ignore()` to suppress CM6's MutationObserver.

**Effect:** `lineHeight` corrected from 37px to 31px.

### Phase 1b: Correct charWidth

Extend the same patch to also correct `charWidth` using a dummy `.cm-line` element with representative alphanumeric text (65 chars, `white-space: nowrap`).

**Effect:** `charWidth` corrected from ~16px to ~9px. `lineLength` corrected from ~40 to ~72. This was the dominant fix -- body line height estimates dropped by ~40-60%.

### Phase 2: Heading-aware heightForGap deltas

Even with corrected body metrics, headings are underestimated because `heightForGap()` treats all lines uniformly. A separate patch on `heightForGap()`:

1. Scans the gap range for H1-H3 lines (fast O(1) rejection via `charCodeAt(0)`)
2. Measures actual heading metrics (height + charWidth) per level, cached and invalidated on theme change
3. Computes per-heading delta: `(measured heading height) - (what original formula gives)`
4. Adds total delta to the original bulk estimate

This preserves the original body wrapping formula exactly, only adding corrections for headings.

## Key Files

| File | Change |
|------|--------|
| `web/codemirror/src/line-height-fix.ts` | All three patches + measurement helpers |
| `web/codemirror/src/api.ts` | Calls `installLineHeightFix()` after `setState()`, `invalidateHeadingMetricsCache()` on theme change |
| `web/codemirror/src/anchor-plugin.ts` | `stripAnchors()` reused for visible-length calculation in heading wrapping estimates |

## Design Decisions

**Why monkey-patch instead of upstream fix?** The contamination is application-specific (decoration-applied font changes on headings). CM6's `measureTextSize()` is working as designed -- it just assumes all lines have the same font metrics, which is true for most editors.

**Why delta-based heading correction?** Replacing `heightForGap()` entirely would mean reimplementing CM6's wrapping estimation logic, which could diverge across versions. The delta approach adds heading corrections on top of the original formula, staying compatible with CM6 updates.

**Why Symbol guards?** `installLineHeightFix()` is called after every `setState()` (which recreates docView and oracle). Symbol guards (`MEASURE_PATCHED`, `ORACLE_PATCHED`) make the patches idempotent.

**Why cache heading metrics?** Measuring heading heights requires DOM insertion. Caching per-level metrics (invalidated when `defaultLineHeight` changes or theme switches) avoids repeated DOM operations during scroll.

## Verification

Diagnostic output after fix:
- `defaultLineHeight`: 31.0px (correct, was 37px)
- No "Viewport failed to stabilize" warnings during full-document scroll
- Heading viewport transitions show measured vs estimated deltas (expected behavior)

## See Also

- [codemirror.md](../lessons/codemirror.md) -- "measureTextSize() Heading Contamination" lesson
- [codemirror.md](../lessons/codemirror.md) -- "Virtual Viewport Gaps" (earlier requestMeasure fix)
