// Anchor-map based scroll position save/restore for Milkdown editor.
// Uses sparse anchor points + linear interpolation for sub-line precision.
// Pattern adopted from ReText, remarkable, panwriter, dev.to, Joplin.

import type { Node } from '@milkdown/kit/prose/model';
import type { EditorView } from '@milkdown/kit/prose/view';
import { stripMarkdownSyntax } from './utils';

interface ScrollAnchor {
  mdLine: number; // 0-indexed markdown line number
  pixelY: number; // document-absolute pixel Y position
}

// --- Cache ---
let cachedDoc: Node | null = null;
let cachedScrollY = 0;
let cachedMap: ScrollAnchor[] = [];

// --- Internal helpers ---

/**
 * Scan forward from startIdx until predicate matches, return index.
 * Returns startIdx if nothing matches (never goes backwards).
 */
function scanForward(mdLines: string[], startIdx: number, pred: (line: string) => boolean): number {
  for (let i = startIdx; i < mdLines.length; i++) {
    if (pred(mdLines[i])) return i;
  }
  return startIdx;
}

/**
 * Type-dispatch table for mapping PM nodes to markdown lines.
 * Each PM node type has specific markdown representation — we match
 * by pattern, not by generic textContent matching.
 */
function findNodeInMdLines(node: Node, mdLines: string[], startIdx: number): { mdLine: number; linesConsumed: number } {
  // First: advance startIdx past blank lines between blocks
  let idx = startIdx;
  while (idx < mdLines.length && mdLines[idx].trim() === '') idx++;

  const typeName = node.type.name;

  // --- Zero-height: consume markdown line(s), skip from anchor map ---
  if (typeName === 'zoom_notes_marker') {
    const found = scanForward(mdLines, idx, (line) => line.trim() === '<!-- ::zoom-notes:: -->');
    return { mdLine: found, linesConsumed: 1 };
  }
  if (typeName === 'auto_bibliography') {
    const found = scanForward(mdLines, idx, (line) => line.trim().startsWith('<!-- ::auto-bibliography::'));
    return { mdLine: found, linesConsumed: 1 };
  }

  // --- Leaf nodes with textContent === "" (matched by markdown pattern) ---
  if (typeName === 'section_break') {
    const found = scanForward(mdLines, idx, (line) => line.trim() === '<!-- ::break:: -->');
    return { mdLine: found, linesConsumed: 1 };
  }
  if (typeName === 'horizontal_rule') {
    const found = scanForward(mdLines, idx, (line) => /^(-{3,}|\*{3,}|_{3,})$/.test(line.trim()));
    return { mdLine: found, linesConsumed: 1 };
  }
  if (typeName === 'figure') {
    // figure may have a preceding <!-- caption: text --> line.
    // Match the ![alt](src) line — this is where the figure renders visually.
    const src = node.attrs?.src as string | undefined;
    const found = scanForward(mdLines, idx, (line) => line.startsWith('![') || (!!src && line.includes(src)));
    return { mdLine: found, linesConsumed: found - idx + 1 };
  }

  // --- Code blocks: match fence, skip to closing fence ---
  if (typeName === 'code_block') {
    const fenceIdx = scanForward(mdLines, idx, (line) => line.trimStart().startsWith('```'));
    let endIdx = fenceIdx + 1;
    while (endIdx < mdLines.length && !mdLines[endIdx].trimStart().startsWith('```')) {
      endIdx++;
    }
    if (endIdx < mdLines.length) endIdx++; // include closing fence
    return { mdLine: fenceIdx, linesConsumed: endIdx - fenceIdx };
  }

  // --- Tables: match first | pattern, count until non-table line ---
  if (typeName === 'table') {
    const tableIdx = scanForward(mdLines, idx, (line) => line.includes('|'));
    let endIdx = tableIdx;
    while (endIdx < mdLines.length && mdLines[endIdx].includes('|')) {
      endIdx++;
    }
    return { mdLine: tableIdx, linesConsumed: endIdx - tableIdx };
  }

  // --- Lists: match first list marker, count until end of list ---
  if (typeName === 'bullet_list' || typeName === 'ordered_list') {
    const listPattern = typeName === 'bullet_list' ? /^\s*[-*+]\s/ : /^\s*\d+[.)]\s/;
    const listIdx = scanForward(mdLines, idx, (line) => listPattern.test(line));
    let endIdx = listIdx;
    while (endIdx < mdLines.length) {
      const line = mdLines[endIdx];
      if (line.trim() === '') {
        // Blank line: check if next non-blank line continues the list
        let nextNonBlank = endIdx + 1;
        while (nextNonBlank < mdLines.length && mdLines[nextNonBlank].trim() === '') nextNonBlank++;
        if (nextNonBlank >= mdLines.length) break;
        const nextLine = mdLines[nextNonBlank];
        if (!listPattern.test(nextLine) && !nextLine.startsWith('  ')) break;
      }
      endIdx++;
    }
    return { mdLine: listIdx, linesConsumed: endIdx - listIdx };
  }

  // --- Blockquotes: match > prefix ---
  if (typeName === 'blockquote') {
    const bqIdx = scanForward(mdLines, idx, (line) => line.trimStart().startsWith('>'));
    let endIdx = bqIdx;
    while (endIdx < mdLines.length && mdLines[endIdx].trimStart().startsWith('>')) {
      endIdx++;
    }
    return { mdLine: bqIdx, linesConsumed: endIdx - bqIdx };
  }

  // --- Headings: match # prefix ---
  if (typeName === 'heading') {
    const headIdx = scanForward(mdLines, idx, (line) => /^#{1,6}\s/.test(line));
    return { mdLine: headIdx, linesConsumed: 1 };
  }

  // --- Paragraphs: forward text match from current position ---
  if (typeName === 'paragraph') {
    const pmText = node.textContent.trim();
    if (!pmText) {
      // Check if paragraph has atom children (citations, annotations, footnotes)
      let hasAtomChild = false;
      node.forEach((child) => {
        if (child.isAtom) hasAtomChild = true;
      });
      if (hasAtomChild) {
        const found = scanForward(
          mdLines,
          idx,
          (line) => line.trim().startsWith('<!--') || line.includes('[@') || line.includes('[^')
        );
        return { mdLine: found, linesConsumed: 1 };
      }
      // Truly empty paragraph = blank line
      return { mdLine: idx, linesConsumed: 1 };
    }
    // Forward-search for a line whose stripped content partially matches PM text
    // Normalize pmText for comparison (atom nodes produce double spaces in PM)
    const pmTextNormalized = pmText.replace(/\s+/g, ' ');
    const found = scanForward(mdLines, idx, (line) => {
      const stripped = stripMarkdownSyntax(line).trim();
      if (!stripped) return false;
      const pmPrefix = pmTextNormalized.substring(0, 20);
      const mdPrefix = stripped.substring(0, 20);
      return stripped.includes(pmPrefix) || pmTextNormalized.includes(mdPrefix);
    });
    return { mdLine: found, linesConsumed: 1 };
  }

  // --- Fallback for unknown node types ---
  return { mdLine: idx, linesConsumed: 1 };
}

// --- Exported functions ---

/**
 * Build an array of {mdLine, pixelY} anchor points by walking PM doc
 * top-level nodes and markdown lines in parallel.
 */
export function buildAnchorMap(view: EditorView, mdLines: string[]): ScrollAnchor[] {
  const doc = view.state.doc;

  // Cache check: same doc identity and scroll position within 50px
  if (cachedDoc === doc && Math.abs(cachedScrollY - window.scrollY) < 50 && cachedMap.length > 0) {
    return cachedMap;
  }

  const anchors: ScrollAnchor[] = [];
  let mdIdx = 0;

  // Zero-height node types to skip from anchor map
  const zeroHeightTypes = new Set(['zoom_notes_marker', 'auto_bibliography']);

  doc.forEach((node, offset) => {
    const result = findNodeInMdLines(node, mdLines, mdIdx);

    if (!zeroHeightTypes.has(node.type.name)) {
      // Get pixel position for this node
      let pixelY: number | null = null;
      try {
        // Container nodes: coordsAtPos(offset + 1) — inside the node
        // Atom nodes: coordsAtPos(offset) — at the node
        const pos = node.isAtom ? offset : offset + 1;
        const coords = view.coordsAtPos(pos);
        if (coords) {
          pixelY = coords.top + window.scrollY;
        }
      } catch {
        // coordsAtPos can throw for off-screen nodes
      }

      if (pixelY !== null) {
        // Deduplicate: skip if same pixelY as last anchor (within 1px)
        const last = anchors.length > 0 ? anchors[anchors.length - 1] : null;
        if (!last || Math.abs(last.pixelY - pixelY) > 1) {
          anchors.push({ mdLine: result.mdLine, pixelY });
        }
      }
    }

    // Always advance mdLine counter (including blank lines consumed)
    mdIdx = result.mdLine + result.linesConsumed;
  });

  // Empty document fallback
  if (anchors.length === 0) {
    anchors.push({ mdLine: 0, pixelY: 0 });
  }

  // Update cache
  cachedDoc = doc;
  cachedScrollY = window.scrollY;
  cachedMap = anchors;

  return anchors;
}

/**
 * Save the current scroll position as a floating-point markdown line number.
 * Uses anchor map + linear interpolation for sub-line precision.
 * Returns 1-indexed float (e.g., 6.6 = 60% through line 6).
 */
export function saveScrollPosition(view: EditorView, mdLines: string[]): number {
  const anchors = buildAnchorMap(view, mdLines);
  const scrollY = window.scrollY;

  // Edge cases
  if (anchors.length === 0) return 1;
  if (anchors.length === 1) return anchors[0].mdLine + 1;
  if (scrollY <= anchors[0].pixelY) return anchors[0].mdLine + 1;
  if (scrollY >= anchors[anchors.length - 1].pixelY) return anchors[anchors.length - 1].mdLine + 1;

  // Find bracketing anchors
  let lower = anchors[0];
  let upper = anchors[anchors.length - 1];
  for (let i = 0; i < anchors.length - 1; i++) {
    if (anchors[i].pixelY <= scrollY && anchors[i + 1].pixelY > scrollY) {
      lower = anchors[i];
      upper = anchors[i + 1];
      break;
    }
  }

  // Interpolate
  const range = upper.pixelY - lower.pixelY;
  const fraction = range > 0 ? Math.min((scrollY - lower.pixelY) / range, 0.99) : 0;
  const mdLine = lower.mdLine + fraction * (upper.mdLine - lower.mdLine);

  // Return 1-indexed
  return mdLine + 1;
}

/**
 * Restore scroll position from a floating-point markdown line number.
 * Uses anchor map + linear interpolation to find the pixel position.
 */
export function restoreScrollPosition(view: EditorView, mdLines: string[], floatTopLine: number): void {
  const anchors = buildAnchorMap(view, mdLines);

  // Clamp to valid range (1-indexed input)
  const clampedLine = Math.max(1, Math.min(floatTopLine, mdLines.length));
  // Convert to 0-indexed
  const targetLine = clampedLine - 1;

  // Edge cases
  if (anchors.length === 0) return;
  if (anchors.length === 1) {
    window.scrollTo({ top: Math.max(0, anchors[0].pixelY), behavior: 'instant' });
    return;
  }

  // Find bracketing anchors around targetLine
  if (targetLine <= anchors[0].mdLine) {
    window.scrollTo({ top: Math.max(0, anchors[0].pixelY), behavior: 'instant' });
    return;
  }
  if (targetLine >= anchors[anchors.length - 1].mdLine) {
    window.scrollTo({ top: Math.max(0, anchors[anchors.length - 1].pixelY), behavior: 'instant' });
    return;
  }

  let lower = anchors[0];
  let upper = anchors[anchors.length - 1];
  for (let i = 0; i < anchors.length - 1; i++) {
    if (anchors[i].mdLine <= targetLine && anchors[i + 1].mdLine > targetLine) {
      lower = anchors[i];
      upper = anchors[i + 1];
      break;
    }
  }

  // Interpolate
  const lineRange = upper.mdLine - lower.mdLine;
  const fraction = lineRange > 0 ? Math.min((targetLine - lower.mdLine) / lineRange, 0.99) : 0;
  const pixelY = lower.pixelY + fraction * (upper.pixelY - lower.pixelY);

  window.scrollTo({ top: Math.max(0, pixelY), behavior: 'instant' });
}
