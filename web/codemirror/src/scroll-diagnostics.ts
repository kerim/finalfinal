/**
 * Scroll Bug Diagnostics Module
 *
 * Temporary diagnostics to identify the root cause of text disappearing
 * during scrolling in CodeMirror. Each diagnostic tests one factor from
 * the failure analysis.
 *
 * Usage: Open Safari Web Inspector console and run:
 *   window.FinalFinal.__diagScrollBug()
 *
 * Or watch real-time scroll events via the [DIAG-SCROLL] log prefix.
 */

import type { EditorView } from '@codemirror/view';
import { ViewPlugin, type ViewUpdate } from '@codemirror/view';
import { getEditorView } from './editor-state';

// Regex to match headings (standard ATX and after section anchors)
const HEADING_REGEX = /^(#{1,6})\s/;
const ANCHOR_HEADING_REGEX = /^(?:<!--\s*(?:@sid:[0-9a-fA-F-]+|::auto-bibliography::)\s*-->)+(#{1,6})\s/;

interface HeadingInfo {
  lineNumber: number;
  level: number;
  from: number;
  text: string;
}

/**
 * Find ALL headings in the document by scanning every line.
 */
function findAllHeadings(view: EditorView): HeadingInfo[] {
  const doc = view.state.doc;
  const headings: HeadingInfo[] = [];

  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i);
    let match = line.text.match(HEADING_REGEX);
    if (!match) {
      match = line.text.match(ANCHOR_HEADING_REGEX);
    }
    if (match) {
      headings.push({
        lineNumber: i,
        level: match[1].length,
        from: line.from,
        text: line.text.substring(0, 60),
      });
    }
  }

  return headings;
}

/**
 * Check if a document position is within any of the visible ranges.
 */
function isInVisibleRanges(view: EditorView, pos: number): boolean {
  for (const { from, to } of view.visibleRanges) {
    if (pos >= from && pos <= to) return true;
  }
  return false;
}

// ============================================================
// Diagnostic 1: visibleRanges heading coverage (Factor 1)
// ============================================================

function diagF1_headingCoverage(view: EditorView): { offScreenCount: number; details: string[] } {
  const headings = findAllHeadings(view);
  const details: string[] = [];
  let offScreenCount = 0;
  const defaultLH = view.defaultLineHeight;

  console.log(`[DIAG-F1] Total headings: ${headings.length}, defaultLineHeight: ${defaultLH.toFixed(1)}px`);

  for (const h of headings) {
    const inViewport = isInVisibleRanges(view, h.from);
    const block = view.lineBlockAt(h.from);
    const heightStr = block.height.toFixed(1);

    if (inViewport) {
      const msg = `[DIAG-F1] Line ${h.lineNumber} (H${h.level}): VISIBLE, measured height=${heightStr}px`;
      console.log(msg);
      details.push(msg);
    } else {
      offScreenCount++;
      const usesDefault = Math.abs(block.height - defaultLH) < 2;
      const flag = usesDefault ? ' ** BODY METRICS **' : '';
      const msg = `[DIAG-F1] Line ${h.lineNumber} (H${h.level}): OFF-SCREEN, estimated height=${heightStr}px (default=${defaultLH.toFixed(1)}px)${flag}`;
      console.log(msg);
      details.push(msg);
    }
  }

  const visibleCount = headings.length - offScreenCount;
  console.log(`[DIAG-F1] Summary: ${visibleCount} visible, ${offScreenCount} off-screen`);

  return { offScreenCount, details };
}

// ============================================================
// Diagnostic 3: Line height variation from proportional fonts
// ============================================================

function diagF3_fontWrapping(view: EditorView): { wrappedCount: number; details: string[] } {
  const headings = findAllHeadings(view);
  const details: string[] = [];
  let wrappedCount = 0;

  // Expected single-line heights per heading level
  const expectedHeights: Record<number, number> = {
    1: 31 * 1.2, // H1: 37.2px
    2: 26 * 1.2, // H2: 31.2px
    3: 22 * 1.2, // H3: 26.4px
    4: 18 * 1.2, // H4: 21.6px
    5: 16 * 1.2, // H5: 19.2px
    6: 14 * 1.2, // H6: 16.8px
  };

  for (const h of headings) {
    if (!isInVisibleRanges(view, h.from)) continue;

    const block = view.lineBlockAt(h.from);
    const expected = expectedHeights[h.level] || 37.2;
    const isWrapped = block.height > expected * 1.5;

    if (isWrapped) wrappedCount++;

    const msg = `[DIAG-F3] H${h.level} at line ${h.lineNumber}: expected ~${expected.toFixed(0)}px, actual ${block.height.toFixed(1)}px (wrapped: ${isWrapped ? 'YES' : 'no'})`;
    console.log(msg);
    details.push(msg);
  }

  console.log(`[DIAG-F3] Summary: ${wrappedCount} headings wrapping to 2+ lines`);
  return { wrappedCount, details };
}

// ============================================================
// Diagnostic 4: Available text width
// ============================================================

function diagF4_textWidth(_view: EditorView): { availableWidth: number; details: string[] } {
  const details: string[] = [];

  const scroller = document.querySelector('.cm-scroller') as HTMLElement | null;
  if (!scroller) {
    const msg = '[DIAG-F4] .cm-scroller element not found';
    console.log(msg);
    return { availableWidth: 0, details: [msg] };
  }

  const style = getComputedStyle(scroller);
  const clientWidth = scroller.clientWidth;
  const paddingLeft = parseFloat(style.paddingLeft) || 0;
  const paddingRight = parseFloat(style.paddingRight) || 0;
  const available = clientWidth - paddingLeft - paddingRight;
  const maxWidth =
    style.getPropertyValue('max-width') ||
    getComputedStyle(document.documentElement).getPropertyValue('--column-max-width') ||
    'unset';

  const msg = `[DIAG-F4] Scroller: ${clientWidth}px, Padding: ${paddingLeft}px + ${paddingRight}px, Available: ${available.toFixed(0)}px, MaxWidth: ${maxWidth}`;
  console.log(msg);
  details.push(msg);

  return { availableWidth: available, details };
}

// ============================================================
// Diagnostic 5: CM default height vs CSS computed height
// ============================================================

function diagF5_heightMismatch(view: EditorView): { delta: number; details: string[] } {
  const details: string[] = [];
  const cmDefault = view.defaultLineHeight;

  // Measure actual CSS body line height
  const span = document.createElement('span');
  span.textContent = 'Xg'; // use typical characters
  span.style.cssText = `
    font-family: var(--font-body);
    font-size: var(--font-size-body, 18px);
    line-height: var(--line-height-body, 1.75);
    font-weight: var(--weight-body, 400);
    position: absolute;
    visibility: hidden;
  `;
  document.body.appendChild(span);
  const cssComputed = span.getBoundingClientRect().height;
  document.body.removeChild(span);

  // Read CSS variable values
  const rootStyle = getComputedStyle(document.documentElement);
  const fontSize = rootStyle.getPropertyValue('--font-size-body').trim() || '18px';
  const lineHeight = rootStyle.getPropertyValue('--line-height-body').trim() || '1.75';
  const expected = parseFloat(fontSize) * parseFloat(lineHeight);

  const delta = Math.abs(cmDefault - cssComputed);

  const msg = `[DIAG-F5] CM defaultLineHeight: ${cmDefault.toFixed(1)}px, CSS computed: ${cssComputed.toFixed(1)}px, Expected (${fontSize} * ${lineHeight}): ${expected.toFixed(1)}px, Delta: ${delta.toFixed(1)}px`;
  console.log(msg);
  details.push(msg);

  return { delta, details };
}

// ============================================================
// Diagnostic 6: Enhanced height details (F6)
// ============================================================

// Regexes for counting hidden chars in lines
const ANCHOR_HIDDEN_REGEX = /<!-- @sid:[0-9a-fA-F-]+ -->/g;
const BIB_MARKER_HIDDEN_REGEX = /<!-- ::auto-bibliography:: -->/g;

/**
 * F6a: Create a dummy .cm-line element identical to what CM6 HeightOracle creates
 * and measure it inside the editor DOM (so it inherits editor CSS).
 */
function diagF6a_dummyLineHeight(view: EditorView): string[] {
  const details: string[] = [];

  // Find the editor element to append our dummy to (must inherit editor styles)
  const editorEl = view.dom;

  const dummy = document.createElement('div');
  dummy.className = 'cm-line';
  dummy.textContent = 'abc def ghi jkl mno pqr stu';
  dummy.style.position = 'absolute';
  dummy.style.width = '99999px';
  dummy.style.visibility = 'hidden';

  editorEl.appendChild(dummy);

  const dummyHeight = dummy.getBoundingClientRect().height;
  const dummyStyle = getComputedStyle(dummy);
  const dummyFontSize = dummyStyle.fontSize;
  const dummyLineHeight = dummyStyle.lineHeight;
  const dummyFontFamily = dummyStyle.fontFamily;
  const dummyFontWeight = dummyStyle.fontWeight;

  editorEl.removeChild(dummy);

  const cmDefault = view.defaultLineHeight;
  const delta = Math.abs(cmDefault - dummyHeight);

  let msg = `[DIAG-F6a] Dummy .cm-line inside editor DOM:`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6a]   measured height: ${dummyHeight.toFixed(1)}px`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6a]   fontSize: ${dummyFontSize}, lineHeight: ${dummyLineHeight}, fontWeight: ${dummyFontWeight}`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6a]   fontFamily: ${dummyFontFamily}`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6a]   CM defaultLineHeight: ${cmDefault.toFixed(1)}px, delta: ${delta.toFixed(1)}px`;
  console.log(msg);
  details.push(msg);

  if (delta > 1) {
    msg = `[DIAG-F6a]   ** WARNING: dummy height (${dummyHeight.toFixed(1)}px) != CM default (${cmDefault.toFixed(1)}px) — CSS inheritance issue **`;
    console.log(msg);
    details.push(msg);
  }

  // Also measure in document.body for comparison
  const dummyBody = document.createElement('div');
  dummyBody.className = 'cm-line';
  dummyBody.textContent = 'abc def ghi jkl mno pqr stu';
  dummyBody.style.position = 'absolute';
  dummyBody.style.width = '99999px';
  dummyBody.style.visibility = 'hidden';
  document.body.appendChild(dummyBody);
  const bodyHeight = dummyBody.getBoundingClientRect().height;
  const bodyStyle = getComputedStyle(dummyBody);
  document.body.removeChild(dummyBody);

  msg = `[DIAG-F6a]   Comparison: dummy in body=${bodyHeight.toFixed(1)}px (fontSize=${bodyStyle.fontSize}, lineHeight=${bodyStyle.lineHeight})`;
  console.log(msg);
  details.push(msg);

  return details;
}

/**
 * Count hidden characters in a line (from Decoration.replace ranges).
 * Returns the count of chars hidden by anchor and bibliography markers.
 */
function countHiddenChars(lineText: string): { anchorChars: number; bibChars: number } {
  let anchorChars = 0;
  let bibChars = 0;

  ANCHOR_HIDDEN_REGEX.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = ANCHOR_HIDDEN_REGEX.exec(lineText)) !== null) {
    anchorChars += match[0].length;
  }

  BIB_MARKER_HIDDEN_REGEX.lastIndex = 0;
  while ((match = BIB_MARKER_HIDDEN_REGEX.exec(lineText)) !== null) {
    bibChars += match[0].length;
  }

  return { anchorChars, bibChars };
}

/**
 * Classify a line's type for diagnostic purposes.
 */
function classifyLine(lineText: string, inBibSection: boolean): string {
  // Check for heading (with or without anchors)
  const stripped = lineText.replace(ANCHOR_HIDDEN_REGEX, '').replace(BIB_MARKER_HIDDEN_REGEX, '');
  const headingMatch = stripped.match(/^(#{1,6})\s/);
  if (headingMatch) {
    const level = headingMatch[1].length;
    if (inBibSection && level === 1) return `H${level}-bib`;
    return `H${level}`;
  }

  if (stripped.trim() === '') return 'blank';
  if (inBibSection) return 'bib-ref';
  return 'body';
}

interface LineInfo {
  lineNumber: number;
  type: string;
  rawChars: number;
  hiddenChars: number;
  estHeight: number;
  visible: boolean;
  notes: string;
}

/**
 * F6b: Per-line height analysis for ALL lines in the document.
 * Logs a summary table showing type, char counts, estimated heights, and visibility.
 */
function diagF6b_perLineAnalysis(view: EditorView): { lines: LineInfo[]; bibStartLine: number } {
  const doc = view.state.doc;
  const lines: LineInfo[] = [];
  let bibStartLine = -1;

  // First pass: find bibliography section start
  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i);
    if (line.text.includes('<!-- ::auto-bibliography:: -->')) {
      bibStartLine = i;
      break;
    }
  }

  // Second pass: analyze each line
  console.log('[DIAG-F6b] Per-line height analysis:');
  console.log('[DIAG-F6b] Line | Type     | Raw chars | Hidden | Est height | Visible | Notes');
  console.log('[DIAG-F6b] -----|----------|-----------|--------|------------|---------|------');

  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i);
    const inBib = bibStartLine > 0 && i >= bibStartLine;
    const type = classifyLine(line.text, inBib);
    const { anchorChars, bibChars } = countHiddenChars(line.text);
    const hiddenTotal = anchorChars + bibChars;
    const block = view.lineBlockAt(line.from);
    const visible = isInVisibleRanges(view, line.from);

    let notes = '';
    if (anchorChars > 0) notes += `anchor:${anchorChars}`;
    if (bibChars > 0) notes += `${notes ? ' ' : ''}bib-marker:${bibChars}`;

    const info: LineInfo = {
      lineNumber: i,
      type,
      rawChars: line.length,
      hiddenChars: hiddenTotal,
      estHeight: block.height,
      visible,
      notes,
    };
    lines.push(info);

    const msg = `[DIAG-F6b] ${String(i).padStart(4)} | ${type.padEnd(8)} | ${String(line.length).padStart(9)} | ${String(hiddenTotal).padStart(6)} | ${block.height.toFixed(1).padStart(10)}px | ${(visible ? 'yes' : 'no').padStart(7)} | ${notes}`;
    console.log(msg);
  }

  return { lines, bibStartLine };
}

/**
 * F6c: Document height analysis — compare total estimated vs expected heights.
 */
function diagF6c_documentHeight(view: EditorView, lines: LineInfo[]): string[] {
  const details: string[] = [];
  const defaultLH = view.defaultLineHeight;

  const scrollHeight = view.scrollDOM.scrollHeight;
  const contentHeight = view.contentDOM.offsetHeight;

  // Sum of all line block heights
  let sumBlockHeights = 0;
  for (const li of lines) {
    sumBlockHeights += li.estHeight;
  }

  // Expected height assuming correct metrics:
  // body lines at 31.5px (18px * 1.75), headings at CSS-defined heights
  const expectedBodyHeight = 18 * 1.75; // 31.5px
  const headingHeights: Record<string, number> = {
    H1: 31 * 1.2,
    'H1-bib': 31 * 1.2,
    H2: 26 * 1.2,
    H3: 22 * 1.2,
    H4: 18 * 1.2,
    H5: 16 * 1.2,
    H6: 14 * 1.2,
  };

  let expectedTotal = 0;
  let bodyLineCount = 0;
  let headingLineCount = 0;
  let blankLineCount = 0;
  let bibRefCount = 0;

  for (const li of lines) {
    if (li.type.startsWith('H')) {
      expectedTotal += headingHeights[li.type] || expectedBodyHeight;
      headingLineCount++;
    } else if (li.type === 'blank') {
      expectedTotal += expectedBodyHeight;
      blankLineCount++;
    } else if (li.type === 'bib-ref') {
      expectedTotal += expectedBodyHeight;
      bibRefCount++;
    } else {
      expectedTotal += expectedBodyHeight;
      bodyLineCount++;
    }
  }

  const accumulatedError = sumBlockHeights - expectedTotal;
  const perLineError = lines.length > 0 ? accumulatedError / lines.length : 0;

  let msg: string;

  msg = `[DIAG-F6c] Document height analysis:`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6c]   scrollDOM.scrollHeight: ${scrollHeight}px`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6c]   contentDOM.offsetHeight: ${contentHeight}px`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6c]   Sum of lineBlockAt heights: ${sumBlockHeights.toFixed(1)}px`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6c]   Expected total (correct CSS): ${expectedTotal.toFixed(1)}px`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6c]   Accumulated error: ${accumulatedError > 0 ? '+' : ''}${accumulatedError.toFixed(1)}px (${perLineError > 0 ? '+' : ''}${perLineError.toFixed(2)}px/line)`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6c]   Line counts: ${bodyLineCount} body, ${headingLineCount} heading, ${blankLineCount} blank, ${bibRefCount} bib-ref (${lines.length} total)`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6c]   CM defaultLineHeight: ${defaultLH.toFixed(1)}px, expected body: ${expectedBodyHeight.toFixed(1)}px, per-line default error: ${(defaultLH - expectedBodyHeight).toFixed(1)}px`;
  console.log(msg);
  details.push(msg);

  // Estimate total error from defaultLineHeight being wrong (only for off-screen body lines)
  let offScreenBodyCount = 0;
  for (const li of lines) {
    if (!li.visible && (li.type === 'body' || li.type === 'blank' || li.type === 'bib-ref')) {
      offScreenBodyCount++;
    }
  }
  const defaultHeightError = offScreenBodyCount * (defaultLH - expectedBodyHeight);
  msg = `[DIAG-F6c]   Off-screen body/blank/bib lines: ${offScreenBodyCount}, estimated defaultLH error contribution: ${defaultHeightError > 0 ? '+' : ''}${defaultHeightError.toFixed(1)}px`;
  console.log(msg);
  details.push(msg);

  return details;
}

/**
 * F6d: Bibliography section detail.
 */
function diagF6d_bibliographyDetail(_view: EditorView, lines: LineInfo[], bibStartLine: number): string[] {
  const details: string[] = [];

  if (bibStartLine < 0) {
    const msg = '[DIAG-F6d] No bibliography section found';
    console.log(msg);
    details.push(msg);
    return details;
  }

  const bibLines = lines.filter((l) => l.lineNumber >= bibStartLine);
  const bibRefLines = bibLines.filter((l) => l.type === 'bib-ref');
  const nonBibLines = lines.filter((l) => l.lineNumber < bibStartLine);

  const avgBibLength =
    bibRefLines.length > 0 ? bibRefLines.reduce((sum, l) => sum + l.rawChars, 0) / bibRefLines.length : 0;
  const nonBibBodyLines = nonBibLines.filter((l) => l.type === 'body');
  const avgNonBibLength =
    nonBibBodyLines.length > 0 ? nonBibBodyLines.reduce((sum, l) => sum + l.rawChars, 0) / nonBibBodyLines.length : 0;

  const bibTotalHeight = bibLines.reduce((sum, l) => sum + l.estHeight, 0);
  const nonBibTotalHeight = nonBibLines.reduce((sum, l) => sum + l.estHeight, 0);

  const avgBibHeight = bibLines.length > 0 ? bibTotalHeight / bibLines.length : 0;
  const avgNonBibHeight = nonBibLines.length > 0 ? nonBibTotalHeight / nonBibLines.length : 0;

  let msg: string;

  msg = `[DIAG-F6d] Bibliography section detail:`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6d]   Line range: ${bibStartLine}–${lines[lines.length - 1]?.lineNumber || '?'} (${bibLines.length} lines)`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6d]   Bibliography entries: ${bibRefLines.length}`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6d]   Avg bib-ref line length: ${avgBibLength.toFixed(0)} chars (vs body avg: ${avgNonBibLength.toFixed(0)} chars)`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6d]   Avg bib line height: ${avgBibHeight.toFixed(1)}px (vs non-bib avg: ${avgNonBibHeight.toFixed(1)}px)`;
  console.log(msg);
  details.push(msg);

  msg = `[DIAG-F6d]   Bib section total height: ${bibTotalHeight.toFixed(1)}px, rest: ${nonBibTotalHeight.toFixed(1)}px`;
  console.log(msg);
  details.push(msg);

  // Check if any bib lines are visible
  const visibleBibLines = bibLines.filter((l) => l.visible).length;
  msg = `[DIAG-F6d]   Bib lines visible: ${visibleBibLines}/${bibLines.length}`;
  console.log(msg);
  details.push(msg);

  return details;
}

/**
 * Master F6 diagnostic — runs all F6 sub-diagnostics.
 */
function diagF6_heightDetails(view: EditorView): void {
  console.log('[DIAG-F6a] --- Dummy .cm-line height measurement ---');
  diagF6a_dummyLineHeight(view);
  console.log('');

  console.log('[DIAG-F6b] --- Per-line height analysis ---');
  const { lines, bibStartLine } = diagF6b_perLineAnalysis(view);
  console.log('');

  console.log('[DIAG-F6c] --- Document height analysis ---');
  diagF6c_documentHeight(view, lines);
  console.log('');

  console.log('[DIAG-F6d] --- Bibliography section detail ---');
  diagF6d_bibliographyDetail(view, lines, bibStartLine);
}

// ============================================================
// Real-Time Scroll Diagnostic (ViewPlugin)
// ============================================================

/**
 * Tracks which headings have been seen in the viewport.
 * Logs height adjustments when new headings enter the viewport.
 */
export const scrollDiagnosticPlugin = ViewPlugin.fromClass(
  class {
    private seenHeadingLines = new Set<number>();

    constructor(view: EditorView) {
      this.recordVisibleHeadings(view);
    }

    update(update: ViewUpdate) {
      if (update.viewportChanged) {
        this.checkNewHeadings(update.view);
      }
    }

    private recordVisibleHeadings(view: EditorView) {
      const headings = findAllHeadings(view);
      for (const h of headings) {
        if (isInVisibleRanges(view, h.from)) {
          this.seenHeadingLines.add(h.lineNumber);
        }
      }
    }

    private checkNewHeadings(view: EditorView) {
      const headings = findAllHeadings(view);
      const newEntries: string[] = [];

      for (const h of headings) {
        if (!isInVisibleRanges(view, h.from)) continue;
        if (this.seenHeadingLines.has(h.lineNumber)) continue;

        // This heading just entered the viewport for the first time
        this.seenHeadingLines.add(h.lineNumber);

        const block = view.lineBlockAt(h.from);
        const defaultLH = view.defaultLineHeight;
        const heightDiff = block.height - defaultLH;

        newEntries.push(
          `  H${h.level} line ${h.lineNumber}: height=${block.height.toFixed(1)}px (default=${defaultLH.toFixed(1)}px, diff=${heightDiff > 0 ? '+' : ''}${heightDiff.toFixed(1)}px)`
        );
      }

      if (newEntries.length > 0) {
        console.log(`[DIAG-SCROLL] Viewport changed: ${newEntries.length} new heading(s) entering:`);
        for (const entry of newEntries) {
          console.log(entry);
        }
      }
    }
  }
);

// ============================================================
// Master Diagnostic Function
// ============================================================

export function runAllDiagnostics(): void {
  const view = getEditorView();
  if (!view) {
    console.error('[SCROLL-DIAG] No editor view available');
    return;
  }

  console.log('[SCROLL-DIAG] ===== Running All Diagnostics =====');
  console.log('');

  // Factor 1
  console.log('[SCROLL-DIAG] --- Factor 1: visibleRanges heading coverage ---');
  const f1 = diagF1_headingCoverage(view);
  console.log('');

  // Factor 2 (read from window.__DIAG_F2__)
  console.log('[SCROLL-DIAG] --- Factor 2: Initialization requestMeasure count ---');
  const f2 = (window as any).__DIAG_F2__;
  if (f2) {
    console.log(`[DIAG-F2] setContent() calls: ${f2.setContentCalls}`);
    console.log(`[DIAG-F2] requestMeasure() calls: ${f2.requestMeasureCalls}`);
    console.log(`[DIAG-F2] Timestamps: ${JSON.stringify(f2.timestamps)}`);
  } else {
    console.log('[DIAG-F2] window.__DIAG_F2__ not initialized (counters not active)');
  }
  console.log('');

  // Factor 3
  console.log('[SCROLL-DIAG] --- Factor 3: Font wrapping ---');
  const f3 = diagF3_fontWrapping(view);
  console.log('');

  // Factor 4
  console.log('[SCROLL-DIAG] --- Factor 4: Text width ---');
  const f4 = diagF4_textWidth(view);
  console.log('');

  // Factor 5
  console.log('[SCROLL-DIAG] --- Factor 5: Height mismatch ---');
  const f5 = diagF5_heightMismatch(view);
  console.log('');

  // Factor 6
  console.log('[SCROLL-DIAG] --- Factor 6: Enhanced height details ---');
  diagF6_heightDetails(view);
  console.log('');

  // Summary
  console.log('[SCROLL-DIAG] ===== Factor Summary =====');
  console.log(`[SCROLL-DIAG] F1 (visibleRanges): ${f1.offScreenCount} off-screen headings with body-metric heights`);
  console.log(`[SCROLL-DIAG] F2 (requestMeasure): ${f2 ? f2.requestMeasureCalls : '?'} calls during init`);
  console.log(`[SCROLL-DIAG] F3 (font wrapping):  ${f3.wrappedCount} headings wrapping to 2+ lines`);
  console.log(`[SCROLL-DIAG] F4 (text width):     ${f4.availableWidth.toFixed(0)}px available`);
  console.log(
    `[SCROLL-DIAG] F5 (height mismatch): CM=${view.defaultLineHeight.toFixed(1)}px vs CSS delta=${f5.delta.toFixed(1)}px`
  );
}
