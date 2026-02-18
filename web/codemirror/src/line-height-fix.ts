/**
 * Line Height Measurement Fix (Phase 1 + Phase 2)
 *
 * Phase 1: Patches measureTextSize() on DocView to correct defaultLineHeight
 * from ~37px (heading-contaminated) to ~31px (true body height).
 *
 * Phase 2: Patches heightForGap() on HeightOracle to provide heading-aware
 * height estimation. Without this, CM6 uses uniform body metrics for all
 * off-screen lines, underestimating heading heights (H1–H3 have larger
 * font-size) and their wrapping (wider chars → more visual lines).
 *
 * PRIVATE API: Accesses view.docView.measureTextSize and
 * view.viewState.heightOracle.heightForGap (internal CM6).
 * All access uses optional chaining + Symbol guards — degrades to no-op
 * if CM6 internals change.
 *
 * @see https://github.com/codemirror/view/blob/main/src/docview.ts (measureTextSize)
 * @see https://github.com/codemirror/view/blob/main/src/heightmap.ts (HeightOracle)
 */

import type { EditorView } from '@codemirror/view';
import { stripAnchors } from './anchor-plugin';

// Symbol guards for idempotent patching
const MEASURE_PATCHED = Symbol('ff.measureTextSizePatched');
const ORACLE_PATCHED = Symbol('ff.heightForGapPatched');

// --- Heading detection ---

/**
 * Detect heading level from a line's text.
 * Handles both "# ..." and "<!-- @sid:UUID --># ..." patterns.
 * Fast-rejects non-headings via charCodeAt(0) check (O(1) for body lines).
 * Returns 0 for non-headings, 1–6 for heading levels.
 */
function getHeadingLevel(text: string): number {
  const first = text.charCodeAt(0);

  // Fast path: standard heading starts with '#' (code 35)
  if (first === 35) {
    let level = 1;
    while (level < 6 && text.charCodeAt(level) === 35) level++;
    // Must be followed by space (or end of string for bare "#")
    if (level <= 6 && (text.length === level || text.charCodeAt(level) === 32)) {
      return level;
    }
    return 0;
  }

  // Slow path: anchor-prefixed heading starts with '<' (code 60)
  if (first === 60) {
    const match = text.match(/^(?:<!--\s*(?:@sid:[0-9a-fA-F-]+|::auto-bibliography::)\s*-->)+(#{1,6})\s/);
    if (match) return match[1].length;
  }

  return 0;
}

/**
 * Get the visible length of a line's text, stripping hidden anchor markers.
 * Reuses stripAnchors() from anchor-plugin.ts.
 */
function getVisibleLength(text: string): number {
  return stripAnchors(text).length;
}

// --- Measurement helpers ---

/**
 * Run a function while suppressing CM6's MutationObserver to prevent
 * unexpected re-measurements during DOM manipulation.
 */
function measureInEditor(view: EditorView, fn: () => void): void {
  const ignoreFn = (view as any).observer?.ignore?.bind((view as any).observer);
  if (ignoreFn) {
    ignoreFn(fn);
  } else {
    fn();
  }
}

/**
 * Measure the correct body line height by creating a dummy .cm-line element
 * inside the editor's contentDOM.
 */
function measureBodyLineHeight(view: EditorView): number {
  let height = 0;
  measureInEditor(view, () => {
    const dummy = document.createElement('div');
    dummy.className = 'cm-line';
    dummy.textContent = 'x';
    dummy.style.cssText = 'position: absolute; width: 99999px; visibility: hidden;';
    view.contentDOM.appendChild(dummy);
    height = dummy.getBoundingClientRect().height;
    view.contentDOM.removeChild(dummy);
  });
  return height;
}

/**
 * Measure the correct body character width by creating a dummy .cm-line element
 * with representative text inside the editor's contentDOM.
 * Fixes charWidth contamination when measureTextSize() samples a heading line.
 */
function measureBodyCharWidth(view: EditorView): number {
  let charWidth = 0;
  measureInEditor(view, () => {
    const dummy = document.createElement('div');
    dummy.className = 'cm-line';
    dummy.textContent = 'abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789';
    dummy.style.cssText = 'position: absolute; width: 99999px; visibility: hidden; white-space: nowrap;';
    view.contentDOM.appendChild(dummy);
    // Measure the TEXT NODE width via Range API (not the div's 99999px CSS width)
    const range = document.createRange();
    range.selectNodeContents(dummy);
    const rect = range.getBoundingClientRect();
    const textLen = dummy.textContent!.length;
    charWidth = textLen > 0 && rect.width > 0 ? rect.width / textLen : 0;
    view.contentDOM.removeChild(dummy);
  });
  return charWidth;
}

/**
 * Measure height and average character width for a specific heading level
 * by creating a dummy element with the heading's CSS class.
 */
function measureHeadingMetrics(view: EditorView, level: number): { height: number; charWidth: number } {
  let height = 0;
  let charWidth = 0;
  measureInEditor(view, () => {
    const dummy = document.createElement('div');
    dummy.className = `cm-line cm-heading-${level}-line`;
    // Use a representative sample for charWidth measurement
    dummy.textContent = 'abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789';
    dummy.style.cssText = 'position: absolute; width: 99999px; visibility: hidden; white-space: nowrap;';
    view.contentDOM.appendChild(dummy);
    height = dummy.getBoundingClientRect().height; // height is correct from div
    // Measure text node width via Range API (not the div's 99999px CSS width)
    const range = document.createRange();
    range.selectNodeContents(dummy);
    const textRect = range.getBoundingClientRect();
    const textLen = dummy.textContent!.length;
    charWidth = textLen > 0 && textRect.width > 0 ? textRect.width / textLen : 0;
    view.contentDOM.removeChild(dummy);
  });
  return { height, charWidth };
}

// --- Cached heading metrics ---

interface HeadingMetrics {
  height: number;
  charWidth: number;
}

let cachedHeadingMetrics: Map<number, HeadingMetrics> | null = null;
let cachedDefaultLineHeight: number = 0;

/**
 * Get or measure heading metrics for H1–H3. Cached and invalidated when
 * defaultLineHeight changes (font/theme switch).
 */
function getOrMeasureHeadingMetrics(view: EditorView): Map<number, HeadingMetrics> {
  const oracle = (view as any).viewState?.heightOracle;
  const currentDefault = oracle?.lineHeight ?? 0;

  // Invalidate cache if defaultLineHeight changed (theme/font switch)
  if (cachedHeadingMetrics && Math.abs(currentDefault - cachedDefaultLineHeight) < 0.1) {
    return cachedHeadingMetrics;
  }

  const metrics = new Map<number, HeadingMetrics>();
  for (let level = 1; level <= 3; level++) {
    metrics.set(level, measureHeadingMetrics(view, level));
  }

  cachedHeadingMetrics = metrics;
  cachedDefaultLineHeight = currentDefault;
  return metrics;
}

/**
 * Invalidate the cached heading metrics. Called when theme changes
 * (heading-only CSS variable changes that don't affect defaultLineHeight).
 */
export function invalidateHeadingMetricsCache(): void {
  cachedHeadingMetrics = null;
  cachedDefaultLineHeight = 0;
}

// --- Patches ---

/**
 * Patch measureTextSize() on the DocView to correct its lineHeight return
 * value using a clean dummy .cm-line element measurement.
 * (Phase 1 fix — corrects defaultLineHeight from ~37px to ~31px)
 */
function installMeasureTextSizePatch(view: EditorView): void {
  const docView = (view as any).docView;
  if (!docView?.measureTextSize) return;
  if ((docView as any)[MEASURE_PATCHED]) return;

  const original = docView.measureTextSize.bind(docView);

  docView.measureTextSize = () => {
    const result = original();
    const correctHeight = measureBodyLineHeight(view);
    if (correctHeight > 0 && Math.abs(result.lineHeight - correctHeight) > 1) {
      result.lineHeight = correctHeight;
    }
    const correctCharWidth = measureBodyCharWidth(view);
    if (correctCharWidth > 0 && Math.abs(result.charWidth - correctCharWidth) > 1) {
      result.charWidth = correctCharWidth;
    }
    return result;
  };
  (docView as any)[MEASURE_PATCHED] = true;
}

/**
 * Patch heightForGap() on the HeightOracle to add heading-aware height
 * deltas on top of the original bulk estimate.
 * (Phase 2 fix — only corrects the underestimate for H1–H3, preserves
 * the original body wrapping formula exactly)
 */
function installHeightForGapPatch(view: EditorView): void {
  const oracle = (view as any).viewState?.heightOracle;
  if (!oracle?.heightForGap) return;
  if ((oracle as any)[ORACLE_PATCHED]) return;

  const originalHFG = oracle.heightForGap;

  oracle.heightForGap = function (this: any, from: number, to: number): number {
    const doc = this.doc;
    if (!doc) return originalHFG.call(this, from, to);

    let startLine: any;
    let endLine: any;
    try {
      startLine = doc.lineAt(from);
      endLine = doc.lineAt(to);
    } catch {
      return originalHFG.call(this, from, to);
    }

    const metrics = getOrMeasureHeadingMetrics(view);

    // Compute heading height deltas: (measured heading height) - (what original would give)
    let headingDelta = 0;

    for (let n = startLine.number; n <= endLine.number; n++) {
      let line: any;
      try {
        line = doc.line(n);
      } catch {
        return originalHFG.call(this, from, to);
      }

      const level = getHeadingLevel(line.text);
      if (level > 0 && level <= 3) {
        const m = metrics.get(level);
        if (m && m.height > 0) {
          // What the original formula allocates for this line
          const originalLineHeight = this.heightForLine(line.length);

          // What we think the heading actually needs
          let headingHeight: number;
          if (!this.lineWrapping) {
            headingHeight = m.height;
          } else {
            const visLen = getVisibleLength(line.text);
            const headingLineLen = Math.max(5, (this.lineLength * this.charWidth) / m.charWidth);
            const wrappedLines =
              1 + Math.max(0, Math.ceil((visLen - headingLineLen) / Math.max(1, headingLineLen - 5)));
            headingHeight = m.height * wrappedLines;
          }

          headingDelta += headingHeight - originalLineHeight;
        }
      }
    }

    // No headings in gap → original unchanged
    if (headingDelta === 0) return originalHFG.call(this, from, to);

    // Add deltas to the original bulk estimate
    return originalHFG.call(this, from, to) + headingDelta;
  };
  (oracle as any)[ORACLE_PATCHED] = true;
}

// --- Public API ---

/**
 * Install both line height patches on the given EditorView.
 * Idempotent via Symbol guards — safe to call multiple times.
 *
 * Call after creating EditorView AND after any setState() call
 * (which destroys and recreates docView + oracle).
 */
export function installLineHeightFix(view: EditorView): void {
  installMeasureTextSizePatch(view);
  installHeightForGapPatch(view);
}
