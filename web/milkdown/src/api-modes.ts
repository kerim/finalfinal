// Editor mode, cursor, and misc API method implementations for window.FinalFinal

import { type Editor, editorViewCtx, parserCtx, serializerCtx } from '@milkdown/kit/core';
import { Slice } from '@milkdown/kit/prose/model';
import { Selection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { getMarkdown } from '@milkdown/kit/utils';
import { fromMarkdown } from 'mdast-util-from-markdown';
import { gfmTableFromMarkdown } from 'mdast-util-gfm-table';
import { gfmTable } from 'micromark-extension-gfm-table';
import { getContent, getRawSerialisedMarkdown, setContent } from './api-content';
import { getBlockIdAtPos } from './block-id-plugin';
import { mdToTextOffset, textToMdOffset } from './cursor-mapping';
import { getEditorInstance } from './editor-state';
import {
  clearSearch as clearSearchImpl,
  find as findImpl,
  findNext as findNextImpl,
  findPrevious as findPreviousImpl,
  getSearchState as getSearchStateImpl,
  replaceAll as replaceAllImpl,
  replaceCurrent as replaceCurrentImpl,
} from './find-replace';
import { setFocusModeEnabled } from './focus-mode-plugin';
import { restoreScrollPosition, saveScrollPosition } from './scroll-map';
import { sectionBreakNode } from './section-break-plugin';
import { isSourceModeEnabled, setSourceModeEnabled } from './source-mode-plugin';
import type { FindOptions, FindResult, SearchState } from './types';
import { withSettingContent } from './typewriter-plugin';
import { findTableStartLine, isTableLine, isTableSeparator, stripMarkdownSyntax } from './utils';

export function setFocusMode(enabled: boolean): void {
  setFocusModeEnabled(enabled);
  const editorInstance = getEditorInstance();
  if (editorInstance) {
    const view = editorInstance.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr);
  }
}

export function getCurrentSectionTitle(): string | null {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return null;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { head } = view.state.selection;
    let lastHeadingText: string | null = null;

    view.state.doc.nodesBetween(0, head, (node) => {
      if (node.type.name === 'heading') {
        lastHeadingText = node.textContent;
      }
      return true;
    });

    return lastHeadingText;
  } catch {
    return null;
  }
}

export function getCurrentSectionBlockId(): string | null {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return null;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { head } = view.state.selection;
    let lastHeadingPos: number | null = null;

    view.state.doc.nodesBetween(0, head, (node, pos) => {
      if (node.type.name === 'heading') {
        lastHeadingPos = pos;
      }
      return true;
    });

    if (lastHeadingPos !== null) {
      const blockId = getBlockIdAtPos(lastHeadingPos);
      return blockId ?? null;
    }
    return null;
  } catch {
    return null;
  }
}

export function getStats(): { words: number; characters: number } {
  const content = getContent();
  // Strip annotations before counting (<!-- ::type:: content -->)
  const strippedContent = content.replace(/<!--\s*::\w+::\s*[\s\S]*?-->/g, '');
  const words = strippedContent.split(/\s+/).filter((w) => w.length > 0).length;
  return { words, characters: strippedContent.length };
}

export function scrollToOffset(offset: number): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  const view = editorInstance.ctx.get(editorViewCtx);
  const docSize = view.state.doc.content.size;
  const pos = Math.min(offset, Math.max(0, docSize - 1));

  try {
    const selection = Selection.near(view.state.doc.resolve(pos));
    view.dispatch(view.state.tr.setSelection(selection));

    const coords = view.coordsAtPos(pos);
    if (coords) {
      const targetScrollY = coords.top + window.scrollY - 100;
      window.scrollTo({ top: Math.max(0, targetScrollY), behavior: 'smooth' });
    }

    view.focus();
  } catch {
    // Scroll failed, ignore
  }
}

export function setTheme(cssVariables: string): void {
  const root = document.documentElement;
  // Clear all existing CSS custom properties to remove stale overrides
  // This ensures that when an override is removed (e.g., font reset to default),
  // the old value doesn't persist on the element's inline style
  const propsToRemove: string[] = [];
  for (let i = 0; i < root.style.length; i++) {
    const prop = root.style[i];
    if (prop.startsWith('--')) {
      propsToRemove.push(prop);
    }
  }
  for (const prop of propsToRemove) {
    root.style.removeProperty(prop);
  }

  // Set new CSS variables
  cssVariables
    .split(';')
    .filter((s) => s.trim())
    .forEach((pair) => {
      const [key, value] = pair.split(':').map((s) => s.trim());
      if (key && value) root.style.setProperty(key, value);
    });
}

/**
 * Map a ProseMirror position to a 1-indexed markdown line number.
 * Uses: text matching → table detection → block-counting fallback.
 */
function pmPosToMdLine(view: import('@milkdown/kit/prose/view').EditorView, pmPos: number, mdLines: string[]): number {
  const $pos = view.state.doc.resolve(pmPos);
  const parentNode = $pos.parent;
  const parentText = parentNode.textContent.trim().replace(/\s+/g, ' ');

  let line = 1;
  let matched = false;

  // Check if position is in a table by looking at ancestor nodes
  let inTable = false;
  for (let d = $pos.depth; d > 0; d--) {
    if ($pos.node(d).type.name === 'table') {
      inTable = true;
      break;
    }
  }

  // SIMPLE TABLE HANDLING: When position is in a table, return the table's START line
  if (inTable) {
    let pmTableOrdinal = 0;
    let foundTablePos = false;
    view.state.doc.descendants((node, pos) => {
      if (foundTablePos) return false;
      if (node.type.name === 'table') {
        pmTableOrdinal++;
        if (pmPos > pos && pmPos < pos + node.nodeSize) {
          foundTablePos = true;
          return false;
        }
      }
      return true;
    });

    // Find the pmTableOrdinal-th table in markdown
    if (pmTableOrdinal > 0) {
      let mdTableCount = 0;
      for (let i = 0; i < mdLines.length; i++) {
        if (isTableLine(mdLines[i]) && !isTableSeparator(mdLines[i])) {
          if (i === 0 || !isTableLine(mdLines[i - 1])) {
            mdTableCount++;
            if (mdTableCount === pmTableOrdinal) {
              line = i + 1;
              matched = true;
              break;
            }
          }
        }
      }
    }
  }

  // Standard text matching (skip if already matched via table)
  for (let i = 0; i < mdLines.length && !matched; i++) {
    const stripped = stripMarkdownSyntax(mdLines[i]);

    if (stripped && stripped === parentText) {
      line = i + 1;
      matched = true;
      break;
    }

    // Partial match (for long lines)
    if (stripped && parentText && parentText.startsWith(stripped) && stripped.length >= 10) {
      line = i + 1;
      matched = true;
      break;
    }

    // Reverse partial match
    if (stripped && parentText && stripped.startsWith(parentText) && parentText.length >= 10) {
      line = i + 1;
      matched = true;
      break;
    }
  }

  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'debug',
    message: `[CURSOR-SYNC] pmPosToMdLine: pmPos=${pmPos} len=${parentText.length} matched=${matched} line=${line} method=${inTable ? 'table' : matched ? 'text' : 'scanning'}`,
  });

  // Fallback: count blocks from document start
  if (!matched) {
    let blockCount = 0;
    view.state.doc.descendants((node, pos) => {
      if (pos >= pmPos) return false;
      if (node.isBlock && node.type.name !== 'doc') {
        blockCount++;
      }
      return true;
    });

    let contentLinesSeen = 0;
    for (let i = 0; i < mdLines.length; i++) {
      if (mdLines[i].trim() !== '') {
        contentLinesSeen++;
        if (contentLinesSeen === blockCount) {
          line = i + 1;
          break;
        }
      }
    }
    if (contentLinesSeen < blockCount) {
      line = mdLines.length;
    }

    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[CURSOR-SYNC] pmPosToMdLine FALLBACK: blockCount=${blockCount} contentLinesSeen=${contentLinesSeen} resultLine=${line}`,
    });
  }

  return line;
}

// The caret's Markdown column, exactly (hand test 2026-11-06, docs/architecture/write-queue-plan/phase5/a9-notes.md, "Cursor fix and
// switch notice"). A citation, a footnote reference, a math or annotation node is ONE ProseMirror position but many Markdown characters;
// the text-offset estimate (cursor-mapping.ts) counted it as one, so a caret at the end of a paragraph with citations came over to the
// Markdown page dozens of columns too early, and the next keys landed in the middle of a word earlier in the paragraph. Instead, the
// caret's textblock alone is serialised with a marker character at the caret, by the editor's own serializer, and the marker's place in
// that text is the column. One block, not the document: cheap at any document size.

const CARET_MARKER = '';
const SYNTAX_PREFIX = /^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/;

function syntaxPrefixLength(line: string): number {
  const match = line.match(SYNTAX_PREFIX);
  return match ? match[0].length : 0;
}

function leadingSpaces(line: string): number {
  return line.length - line.trimStart().length;
}

/** The textblock holding `pos` serialised alone with the caret marker at `pos`; null in a table, a code block, or on any failure. */
function textblockWithMarker(editorInstance: Editor, view: EditorView, pos: number): string | null {
  const $pos = view.state.doc.resolve(pos);
  if (!$pos.parent.isTextblock || $pos.parent.type.spec.code) return null;
  for (let depth = $pos.depth; depth > 0; depth--) {
    if ($pos.node(depth).type.name === 'table') return null;
  }
  try {
    const doc = view.state.tr.insertText(CARET_MARKER, pos).doc;
    const block = doc.resolve(pos).parent;
    const markdown = editorInstance.ctx.get(serializerCtx)(view.state.schema.topNodeType.create(null, block));
    return markdown.includes(CARET_MARKER) ? markdown : null;
  } catch {
    return null;
  }
}

/** Where the marker is in `blockMarkdown`: the line of the block (0 = its first) and the column in that line. */
function markerPlace(blockMarkdown: string): { lineInBlock: number; column: number; blockLines: string[] } {
  const index = blockMarkdown.indexOf(CARET_MARKER);
  const before = blockMarkdown.slice(0, index);
  return {
    lineInBlock: before.split('\n').length - 1,
    column: index - (before.lastIndexOf('\n') + 1),
    blockLines: blockMarkdown.replace(/\n+$/, '').split('\n'),
  };
}

/** The caret at `head` as a Markdown line and column, `line` being the block's first line in `mdLines`. Null when not exact. */
function caretInMarkdownLine(
  editorInstance: Editor,
  view: EditorView,
  head: number,
  line: number,
  mdLines: string[]
): { line: number; column: number } | null {
  const blockMarkdown = textblockWithMarker(editorInstance, view, head);
  if (blockMarkdown === null) return null;
  const place = markerPlace(blockMarkdown);
  const blockLine = place.blockLines[place.lineInBlock] ?? '';
  const fullLine = mdLines[line - 1 + place.lineInBlock] ?? '';
  // The block alone has no list marker or quote prefix (its container is not serialised); the document's line has. The first line's prefix
  // is the syntax prefix, a following line's is its indentation.
  const shift =
    place.lineInBlock === 0
      ? syntaxPrefixLength(fullLine) - syntaxPrefixLength(blockLine.replace(CARET_MARKER, ''))
      : leadingSpaces(fullLine) - leadingSpaces(blockLine.replace(CARET_MARKER, ''));
  return { line: line + place.lineInBlock, column: Math.max(0, place.column + shift) };
}

/**
 * The offset in the textblock starting at `contentStart` whose Markdown column (the block's first line, after its syntax prefix) is the
 * first at or past `contentColumn`. The inverse of `caretInMarkdownLine` for one-line blocks; null when the block serialises to more than
 * one line or cannot be serialised.
 */
function offsetForMarkdownColumn(
  editorInstance: Editor,
  view: EditorView,
  contentStart: number,
  contentColumn: number
): number | null {
  const size = view.state.doc.resolve(contentStart).parent.content.size;
  const columnAt = (offset: number): number | null => {
    const blockMarkdown = textblockWithMarker(editorInstance, view, contentStart + offset);
    if (blockMarkdown === null) return null;
    const place = markerPlace(blockMarkdown);
    if (place.blockLines.length !== 1) return null;
    return place.column - syntaxPrefixLength(place.blockLines[0].replace(CARET_MARKER, ''));
  };
  if (columnAt(size) === null) return null;
  let low = 0;
  let high = size;
  while (low < high) {
    const middle = (low + high) >> 1;
    const column = columnAt(middle);
    if (column === null) return null;
    if (column >= contentColumn) high = middle;
    else low = middle + 1;
  }
  return low;
}

export function getCursorPosition(): {
  line: number;
  column: number;
  scrollFraction: number;
  cursorIsVisible: boolean;
  topLine: number;
} {
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    return { line: 1, column: 0, scrollFraction: 0, cursorIsVisible: true, topLine: 1 };
  }

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { head } = view.state.selection;
    // The switch to Markdown has just read the same document through getContent(); this reuses that
    // serialisation (raw text, same as before) instead of serialising a second time.
    const markdown = getRawSerialisedMarkdown(editorInstance);
    const mdLines = markdown.split('\n');

    let line = pmPosToMdLine(view, head, mdLines);

    // The column: exact from the caret's own block serialised with a marker at the caret (citations, footnote references and every
    // other inline node counted as the Markdown characters they are); the old text-offset estimate only where that cannot be had.
    const exact = caretInMarkdownLine(editorInstance, view, head, line, mdLines);
    let column: number;
    if (exact) {
      line = exact.line;
      column = exact.column;
    } else {
      const $head = view.state.doc.resolve(head);
      const offsetInBlock = head - $head.start($head.depth);
      const lineContent = mdLines[line - 1] || '';
      const syntaxLength = syntaxPrefixLength(lineContent);
      column = syntaxLength + textToMdOffset(lineContent.slice(syntaxLength), offsetInBlock);
    }

    const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
    const scrollFraction = maxScroll > 0 ? Math.min(1, window.scrollY / maxScroll) : 0;

    // Check if cursor is currently visible in the viewport
    const coords = view.coordsAtPos(head);
    const cursorIsVisible = coords != null && coords.top >= 0 && coords.bottom <= window.innerHeight;

    // Determine the markdown line at the viewport top (float with sub-line precision)
    const topLine = saveScrollPosition(view, mdLines);

    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[CURSOR-SYNC] MW.getCursorPosition: line=${line} col=${column} pmHead=${head} visible=${cursorIsVisible} topLine=${topLine.toFixed(2)}`,
    });

    return { line, column, scrollFraction, cursorIsVisible, topLine };
  } catch {
    return { line: 1, column: 0, scrollFraction: 0, cursorIsVisible: true, topLine: 1 };
  }
}

export function setCursorPosition(lineCol: { line: number; column: number }): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    return;
  }

  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'debug',
    message: `[CURSOR-SYNC] MW.setCursorPosition INPUT: line=${lineCol.line} col=${lineCol.column}`,
  });

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    let { line, column } = lineCol;
    const markdown = editorInstance.action(getMarkdown());
    const lines = markdown.split('\n');

    // Handle separator rows - redirect to first data row
    let targetLine = lines[line - 1] || '';

    if (isTableLine(targetLine) && isTableSeparator(targetLine)) {
      const tableStart = findTableStartLine(lines, line);
      if (tableStart) {
        let dataRowLine = line + 1;
        while (dataRowLine <= lines.length && isTableSeparator(lines[dataRowLine - 1])) {
          dataRowLine++;
        }
        if (dataRowLine <= lines.length && isTableLine(lines[dataRowLine - 1])) {
          line = dataRowLine;
          column = 1;
          targetLine = lines[line - 1];
        }
      }
    }

    // Calculate text offset for column positioning
    const syntaxMatch = targetLine.match(/^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/);
    const syntaxLength = syntaxMatch ? syntaxMatch[0].length : 0;
    const afterSyntax = targetLine.slice(syntaxLength);
    const mdColumnInContent = Math.max(0, column - syntaxLength);
    const textOffset = mdToTextOffset(afterSyntax, mdColumnInContent);

    const targetText = stripMarkdownSyntax(targetLine);

    let pmPos = 1;
    let found = false;
    let matchedBlockStart = 0;
    let matchedBlockEnd = 0;

    // SIMPLE TABLE HANDLING: Place cursor at the START of the table
    if (isTableLine(targetLine) && !isTableSeparator(targetLine)) {
      // Find which table this is in markdown (ordinal counting)
      // Count tables up to and including the target line
      let tableOrdinal = 0;
      for (let i = 0; i <= line - 1; i++) {
        if (isTableLine(lines[i]) && !isTableSeparator(lines[i])) {
          if (i === 0 || !isTableLine(lines[i - 1])) {
            tableOrdinal++;
          }
        }
      }

      // Find the tableOrdinal-th table in ProseMirror and place cursor at its start
      let currentTableOrdinal = 0;
      view.state.doc.descendants((node, pos) => {
        if (found) return false;
        if (node.type.name === 'table') {
          currentTableOrdinal++;
          if (currentTableOrdinal === tableOrdinal) {
            // Place cursor at start of table (position just inside first cell)
            pmPos = pos + 3;
            found = true;
            matchedBlockStart = pos;
            matchedBlockEnd = pos + node.nodeSize;
            return false;
          }
        }
        return true;
      });
    }

    // Standard text matching
    if (!found) {
      view.state.doc.descendants((node, pos) => {
        if (found) return false;

        if (node.isBlock && node.textContent.trim().replace(/\s+/g, ' ') === targetText) {
          pmPos = pos + 1 + Math.min(textOffset, node.content.size);
          found = true;
          matchedBlockStart = pos;
          matchedBlockEnd = pos + node.nodeSize;
          return false;
        }
        return true;
      });
    }

    // Fallback: map markdown line to PM block via content line index
    if (!found) {
      let contentLineIndex = 0;
      let inTableBlock = false;
      for (let i = 0; i < line; i++) {
        const currentLine = lines[i];
        if (isTableLine(currentLine)) {
          if (!inTableBlock) {
            contentLineIndex++;
            inTableBlock = true;
          }
        } else {
          inTableBlock = false;
          if (currentLine.trim() !== '') {
            contentLineIndex++;
          }
        }
      }

      let blockCount = 0;
      view.state.doc.descendants((node, pos) => {
        if (found) return false;
        if (node.isBlock && node.type.name !== 'doc') {
          blockCount++;
          if (blockCount === contentLineIndex) {
            pmPos = pos + 1 + Math.min(textOffset, node.content.size);
            found = true;
            matchedBlockStart = pos;
            matchedBlockEnd = pos + node.nodeSize;
            return false;
          }
          if (node.type.name === 'table') {
            return false;
          }
        }
        return true;
      });
    }

    // The exact offset in the matched textblock (see `caretInMarkdownLine`): the text-offset estimate above counts a citation's or a
    // footnote reference's Markdown characters as text, so a column after one went too far into the paragraph.
    if (found && !isTableLine(targetLine)) {
      let node = view.state.doc.nodeAt(matchedBlockStart);
      let contentStart = matchedBlockStart + 1;
      while (node && !node.isTextblock && node.firstChild) {
        node = node.firstChild;
        contentStart += 1;
      }
      if (node?.isTextblock && !node.type.spec.code) {
        const exact = offsetForMarkdownColumn(editorInstance, view, contentStart, mdColumnInContent);
        if (exact !== null) pmPos = contentStart + exact;
      }
    }

    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[CURSOR-SYNC] MW.setCursorPosition MAPPED: pmPos=${pmPos} found=${found}`,
    });

    const selection = Selection.near(view.state.doc.resolve(pmPos));
    if (found && matchedBlockStart > 0 && (selection.head < matchedBlockStart || selection.head >= matchedBlockEnd)) {
      // Selection.near() jumped outside the matched block — clamp it back
      const clamped = Selection.near(view.state.doc.resolve(matchedBlockStart + 1));
      view.dispatch(view.state.tr.setSelection(clamped).scrollIntoView());
    } else {
      view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
    }
    view.focus();
  } catch {
    // Cursor positioning failed, ignore
  }
}

export function scrollCursorToCenter(): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  // Double-RAF ensures browser has completed layout and paint before
  // calculating cursor coordinates (same pattern as paintComplete in zoom).
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      try {
        const view = editorInstance.ctx.get(editorViewCtx);
        const { head } = view.state.selection;
        const coords = view.coordsAtPos(head);
        if (coords) {
          const viewportHeight = window.innerHeight;
          const targetScrollY = coords.top + window.scrollY - viewportHeight / 2;
          window.scrollTo({ top: Math.max(0, targetScrollY), behavior: 'instant' });
        }
      } catch {
        // Scroll failed, ignore
      }
    });
  });
}

export function scrollToFraction(fraction: number): void {
  let attempts = 0;
  const tryScroll = () => {
    const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
    if (maxScroll <= 0 && attempts < 20) {
      attempts++;
      requestAnimationFrame(tryScroll);
      return;
    }
    if (maxScroll > 0) {
      window.scrollTo({ top: Math.max(0, fraction * maxScroll), behavior: 'instant' });
    }
  };
  requestAnimationFrame(() => requestAnimationFrame(tryScroll));
}

export function scrollToLine(line: number): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  let attempts = 0;
  const tryScroll = () => {
    const view = editorInstance.ctx.get(editorViewCtx);
    const markdown = editorInstance.action(getMarkdown());
    const mdLines = markdown.split('\n');
    if (mdLines.length <= 1 && attempts < 20) {
      attempts++;
      requestAnimationFrame(tryScroll);
      return;
    }
    restoreScrollPosition(view, mdLines, line);
  };
  requestAnimationFrame(() => requestAnimationFrame(tryScroll));
}

export function insertAtCursor(text: string): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { from, to } = view.state.selection;
    const tr = view.state.tr.replaceWith(from, to, view.state.schema.text(text));
    view.dispatch(tr);
    view.focus();
  } catch {
    // Insert failed, ignore
  }
}

export function insertBreak(): void {
  // Insert a section break node
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { from } = view.state.selection;
    const nodeType = sectionBreakNode.type(editorInstance.ctx);
    const node = nodeType.create();
    const tr = view.state.tr.insert(from, node);
    view.dispatch(tr);
    view.focus();
  } catch {
    // Insert failed, ignore
  }
}

/// Returns whether the editor's content DOM actually holds focus afterward -- NOT just
/// whether `view.focus()` was called without throwing. `view.focus()` alone always
/// "succeeds" even when the editor instance is torn down or `document.activeElement` never
/// actually moves (a still-loading page, a detached DOM), which made the Swift-side
/// EditorFocusRestoration log line "JS focus() ok" indistinguishable from a silent no-op
/// (review round fix -- Phase C's whole point is making these failures diagnosable from
/// logs, per the mode-switch fix's original "zero .undo lines" gap).
export function focus(): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    view.focus();
    return view.hasFocus();
  } catch {
    return false;
  }
}

export function initialize(options: {
  content: string;
  theme: string;
  cursorPosition: { line: number; column: number } | null;
}): void {
  // Apply theme first (doesn't require editor instance)
  setTheme(options.theme);

  // Skip content push if empty — Swift may be deferring to setContentWithBlockIds()
  // which includes image metadata (width, caption)
  if (options.content.length > 0) {
    setContent(options.content);
  }

  // Restore cursor position if provided
  // Skip when content is empty — cursor would match against stale WebView content.
  // restoreCursorPositionIfNeeded() handles cursor after real content arrives via setContentWithBlockIds().
  if (options.cursorPosition && options.content.length > 0) {
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[CURSOR-SYNC] MW.initialize: cursorPosition=line=${options.cursorPosition.line} col=${options.cursorPosition.column} contentLen=${options.content.length}`,
    });
    setCursorPosition(options.cursorPosition);
    scrollCursorToCenter();
  }

  // Focus the editor
  focus();
}

// === Dual-appearance mode API (Phase C) ===

export function setEditorMode(mode: 'wysiwyg' | 'source'): void {
  const editorInstance = getEditorInstance();
  const wasSourceMode = isSourceModeEnabled();
  const enableSource = mode === 'source';

  // Step 1: If switching FROM source mode, strip prefixes BEFORE re-parse
  // (so the markdown serializes cleanly without double ##)
  if (wasSourceMode && !enableSource && editorInstance) {
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      let tr = view.state.tr;

      const headings: Array<{ pos: number; level: number }> = [];
      view.state.doc.descendants((node, pos) => {
        if (node.type.name === 'heading') {
          headings.push({ pos, level: node.attrs.level as number });
        }
        return true;
      });

      headings.reverse();

      for (const { pos, level } of headings) {
        const prefix = `${'#'.repeat(level)} `;
        const node = view.state.doc.nodeAt(pos);
        if (!node) continue;
        if (node.textContent.startsWith(prefix)) {
          tr = tr.delete(pos + 1, pos + 1 + prefix.length);
        }
      }

      tr = tr.setMeta('addToHistory', false);
      // Application-origin: the typewriter trigger table marks the mode-switch strip as
      // "no trigger" (plan §2.4.1).
      withSettingContent(() => view.dispatch(tr));
    } catch (e) {
      console.error('[Milkdown] Heading prefix strip failed:', e);
    }
  }

  // Step 2: Change mode state
  setSourceModeEnabled(enableSource);

  // Step 3: Force NodeView recreation via re-parse
  if (wasSourceMode !== enableSource && editorInstance) {
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      const parser = editorInstance.ctx.get(parserCtx);
      const currentMarkdown = getContent();
      const doc = parser(currentMarkdown);

      if (doc) {
        const { from } = view.state.selection;
        const docSize = view.state.doc.content.size;
        let tr = view.state.tr.replace(0, docSize, new Slice(doc.content, 0, 0)).setMeta('addToHistory', false);

        const safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));
        try {
          tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
        } catch {
          tr = tr.setSelection(Selection.atStart(tr.doc));
        }

        // Application-origin: the mode-switch re-parse is not typing (plan §2.4.1).
        withSettingContent(() => view.dispatch(tr));
      }
    } catch {
      // Parse failed, ignore
    }
  }

  // Step 4: If switching TO source mode, insert prefixes AFTER re-parse
  // (so they appear in the fresh NodeViews)
  if (!wasSourceMode && enableSource && editorInstance) {
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      let tr = view.state.tr;

      const headings: Array<{ pos: number; level: number }> = [];
      view.state.doc.descendants((node, pos) => {
        if (node.type.name === 'heading') {
          headings.push({ pos, level: node.attrs.level as number });
        }
        return true;
      });

      headings.reverse();

      for (const { pos, level } of headings) {
        const prefix = `${'#'.repeat(level)} `;
        tr = tr.insertText(prefix, pos + 1);
      }

      tr = tr.setMeta('addToHistory', false);
      // Application-origin: the mode-switch insert is not typing (plan §2.4.1).
      withSettingContent(() => view.dispatch(tr));
    } catch (e) {
      console.error('[Milkdown] Heading prefix insert failed:', e);
    }
  }

  // Step 5: Focus
  if (editorInstance) {
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      view.dispatch(view.state.tr);
      view.focus();
    } catch {
      // Dispatch failed, ignore
    }
  }
}

export function getEditorMode(): 'wysiwyg' | 'source' {
  return isSourceModeEnabled() ? 'source' : 'wysiwyg';
}

// === Find/replace API delegates ===

export function findApi(query: string, options?: FindOptions): FindResult {
  return findImpl(query, options);
}

export function findNextApi(): FindResult | null {
  return findNextImpl();
}

export function findPreviousApi(): FindResult | null {
  return findPreviousImpl();
}

export function replaceCurrentApi(replacement: string): boolean {
  return replaceCurrentImpl(replacement);
}

export function replaceAllApi(replacement: string): number {
  return replaceAllImpl(replacement);
}

export function clearSearchApi(): void {
  clearSearchImpl();
}

export function getSearchStateApi(): SearchState | null {
  return getSearchStateImpl();
}

// === Table API ===

export function insertTable(rows: number, cols: number): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { schema } = view.state;
    const tableType = schema.nodes.table;
    const tableHeaderRowType = schema.nodes.table_header_row;
    const tableRowType = schema.nodes.table_row;
    const tableHeaderType = schema.nodes.table_header;
    const tableCellType = schema.nodes.table_cell;
    const paragraphType = schema.nodes.paragraph;

    if (!tableType || !tableHeaderRowType || !tableRowType || !tableHeaderType || !tableCellType || !paragraphType) {
      console.error('[Milkdown] table node types not found in schema');
      return;
    }

    const emptyPara = () => paragraphType.create(null, []);

    // Header row uses table_header_row (schema: "table_header_row table_row+")
    const headerCells = Array.from({ length: cols }, () => tableHeaderType.create(null, [emptyPara()]));
    const headerRow = tableHeaderRowType.create(null, headerCells);

    // Body rows (rows - 1 data rows using table_cell)
    const bodyRowCount = Math.max(1, rows - 1);
    const bodyRows = Array.from({ length: bodyRowCount }, () => {
      const cells = Array.from({ length: cols }, () => tableCellType.create(null, [emptyPara()]));
      return tableRowType.create(null, cells);
    });

    const tableNode = tableType.create(null, [headerRow, ...bodyRows]);

    // If the cursor is inside an empty top-level paragraph (the typical case
    // after `/table` deletes its slash text), replace that paragraph with the
    // table. Otherwise insert after the current top-level block.
    const { from } = view.state.selection;
    const $from = view.state.doc.resolve(from);
    const topLevel = $from.depth >= 1 ? $from.node(1) : null;
    const isEmptyTopParagraph = topLevel !== null && topLevel.type.name === 'paragraph' && topLevel.content.size === 0;

    // Accepted trade-off (t-65a6a268): the isEmptyTopParagraph branch's
    // replaceWith hits phase1CanClaim's replacedOccupant refusal
    // (same-offset, cross-type, both-empty) and the new table gets a fresh
    // temp id rather than inheriting the paragraph's old one -- see
    // block-id-phase1-mapping.test.ts's "accepted fresh-id trade-offs"
    // suite, pin (b).
    const tr = isEmptyTopParagraph
      ? view.state.tr.replaceWith($from.before(1), $from.after(1), tableNode)
      : view.state.tr.insert($from.after(1), tableNode);
    view.dispatch(tr);
    view.focus();
  } catch (e) {
    console.error('[Milkdown] insertTable failed:', e);
  }
}

export function formatTable(): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    // Block-sync serializer already reformats tables on every dispatch.
    // Trigger a no-op transaction to ensure the current table is re-serialized.
    view.dispatch(view.state.tr);
  } catch (e) {
    console.error('[Milkdown] formatTable failed:', e);
  }
}

export function compareTableASTs(md1: string, md2: string): boolean {
  try {
    const parseOpts = {
      extensions: [gfmTable()],
      mdastExtensions: [gfmTableFromMarkdown()],
    };
    const ast1 = fromMarkdown(md1, parseOpts);
    const ast2 = fromMarkdown(md2, parseOpts);
    // Strip position data before comparing — column-width padding changes
    // character offsets but not semantic content.
    return JSON.stringify(ast1, stripPosition) === JSON.stringify(ast2, stripPosition);
  } catch (e) {
    console.error('[Milkdown] compareTableASTs failed:', e);
    return false;
  }
}

function stripPosition(key: string, value: unknown): unknown {
  if (key === 'position') return undefined;
  return value;
}
