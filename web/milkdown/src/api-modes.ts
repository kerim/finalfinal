// Editor mode, cursor, and misc API method implementations for window.FinalFinal

import { editorViewCtx, parserCtx } from '@milkdown/kit/core';
import { Slice } from '@milkdown/kit/prose/model';
import { Selection } from '@milkdown/kit/prose/state';
import { getMarkdown } from '@milkdown/kit/utils';
import { getContent, setContent } from './api-content';
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
import { sectionBreakNode } from './section-break-plugin';
import { isSourceModeEnabled, setSourceModeEnabled } from './source-mode-plugin';
import type { FindOptions, FindResult, SearchState } from './types';
import { findTableStartLine, isTableLine, isTableSeparator, stripMarkdownSyntax } from './utils';

export function setFocusMode(enabled: boolean): void {
  setFocusModeEnabled(enabled);
  const editorInstance = getEditorInstance();
  if (editorInstance) {
    const view = editorInstance.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr);
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

export function getCursorPosition(): { line: number; column: number } {
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    return { line: 1, column: 0 };
  }

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { head } = view.state.selection;
    const markdown = editorInstance.action(getMarkdown());
    const mdLines = markdown.split('\n');
    const $head = view.state.doc.resolve(head);

    // Get parent node text for line matching
    const parentNode = $head.parent;
    const parentText = parentNode.textContent;

    let line = 1;
    let matched = false;

    // Check if cursor is in a table by looking at ancestor nodes
    let inTable = false;
    for (let d = $head.depth; d > 0; d--) {
      if ($head.node(d).type.name === 'table') {
        inTable = true;
        break;
      }
    }

    // SIMPLE TABLE HANDLING: When cursor is in a table, return the table's START line
    if (inTable) {
      let pmTableOrdinal = 0;
      let foundTablePos = false;
      view.state.doc.descendants((node, pos) => {
        if (foundTablePos) return false;
        if (node.type.name === 'table') {
          pmTableOrdinal++;
          if (head > pos && head < pos + node.nodeSize) {
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

      if (stripped === parentText) {
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

    // Fallback: count blocks from document start
    if (!matched) {
      let blockCount = 0;
      view.state.doc.descendants((node, pos) => {
        if (pos >= head) return false;
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
    }

    // Calculate column with inline markdown offset mapping
    const blockStart = $head.start($head.depth);
    const offsetInBlock = head - blockStart;
    const lineContent = mdLines[line - 1] || '';

    const syntaxMatch = lineContent.match(/^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/);
    const syntaxLength = syntaxMatch ? syntaxMatch[0].length : 0;
    const afterSyntax = lineContent.slice(syntaxLength);
    const column = syntaxLength + textToMdOffset(afterSyntax, offsetInBlock);

    return { line, column };
  } catch {
    return { line: 1, column: 0 };
  }
}

export function setCursorPosition(lineCol: { line: number; column: number; scrollFraction?: number }): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    return;
  }

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

        if (node.isBlock && node.textContent.trim() === targetText) {
          pmPos = pos + 1 + Math.min(textOffset, node.content.size);
          found = true;
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
            return false;
          }
          if (node.type.name === 'table') {
            return false;
          }
        }
        return true;
      });
    }

    const selection = Selection.near(view.state.doc.resolve(pmPos));
    view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
    view.focus();

    // Restore scroll position if provided
    if (lineCol.scrollFraction !== undefined) {
      requestAnimationFrame(() => {
        try {
          const cursorCoords = view.coordsAtPos(pmPos);
          const editorRect = view.dom.getBoundingClientRect();
          if (cursorCoords && editorRect.height > 0) {
            const targetTop = editorRect.height * lineCol.scrollFraction!;
            const cursorInView = cursorCoords.top - editorRect.top;
            const scrollAdjust = cursorInView - targetTop;
            view.dom.scrollTop += scrollAdjust;
          }
        } catch {
          // Scroll adjustment failed, ignore
        }
      });
    }
  } catch {
    // Cursor positioning failed, ignore
  }
}

export function scrollCursorToCenter(): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
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

export function focus(): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    view.focus();
  } catch {
    // Focus failed, ignore
  }
}

export function initialize(options: {
  content: string;
  theme: string;
  cursorPosition: { line: number; column: number } | null;
}): void {
  // Apply theme first (doesn't require editor instance)
  setTheme(options.theme);

  // Set content
  setContent(options.content);

  // Restore cursor position if provided
  if (options.cursorPosition) {
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
      view.dispatch(tr);
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

        view.dispatch(tr);
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
      view.dispatch(tr);
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
