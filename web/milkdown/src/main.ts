// Milkdown WYSIWYG Editor for final final
// Uses window.FinalFinal API for Swift ↔ JS communication

import { Editor, defaultValueCtx, editorViewCtx, parserCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { history } from '@milkdown/kit/plugin/history';
import { getMarkdown } from '@milkdown/kit/utils';
import { Slice } from '@milkdown/kit/prose/model';
import { Selection } from '@milkdown/kit/prose/state';

import { focusModePlugin, setFocusModeEnabled } from './focus-mode-plugin';
import { textToMdOffset, mdToTextOffset } from './cursor-mapping';
import './styles.css';

/**
 * Strip markdown syntax from a line to get plain text content
 * Used for matching ProseMirror nodes to markdown lines
 */
function stripMarkdownSyntax(line: string): string {
  return line
    .replace(/^\||\|$/g, '')            // leading/trailing pipes (table)
    .replace(/\|/g, ' ')                // internal pipes (table cells)
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
    .trim()
    .replace(/\s+/g, ' ');              // normalize whitespace
}

/**
 * Check if a markdown line is a table row (starts/ends with |)
 */
function isTableLine(line: string): boolean {
  const trimmed = line.trim();
  // Ensure at least |x| structure (3 chars minimum)
  return trimmed.length >= 3 && trimmed.startsWith('|') && trimmed.endsWith('|');
}

/**
 * Check if a markdown line is a table separator (| --- | --- |)
 */
function isTableSeparator(line: string): boolean {
  const trimmed = line.trim();
  return /^\|[\s:-]+\|$/.test(trimmed) || /^\|(\s*:?-+:?\s*\|)+$/.test(trimmed);
}

/**
 * Find the table structure in markdown: returns startLine for the table containing the given line
 */
function findTableStartLine(lines: string[], targetLine: number): number | null {
  if (!isTableLine(lines[targetLine - 1])) return null;

  // Find table start (scan backwards)
  let startLine = targetLine;
  while (startLine > 1 && isTableLine(lines[startLine - 2])) {
    startLine--;
  }
  return startLine;
}


declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
      getStats: () => { words: number; characters: number };
      scrollToOffset: (offset: number) => void;
      setTheme: (cssVariables: string) => void;
      getCursorPosition: () => { line: number; column: number };
      setCursorPosition: (pos: { line: number; column: number }) => void;
    };
  }
}

let editorInstance: Editor | null = null;
let currentContent = '';
let isSettingContent = false;

async function initEditor() {
  const root = document.getElementById('editor');
  if (!root) {
    console.error('[Milkdown] Editor root element not found');
    return;
  }

  try {
    editorInstance = await Editor.make()
      .config((ctx) => {
        ctx.set(defaultValueCtx, '');
      })
      .use(commonmark)
      .use(gfm)
      .use(history)
      .use(focusModePlugin)
      .create();

    root.appendChild(editorInstance.ctx.get(editorViewCtx).dom);
  } catch (e) {
    console.error('[Milkdown] Init failed:', e);
    throw e;
  }

  // Track content changes
  const view = editorInstance.ctx.get(editorViewCtx);
  const originalDispatch = view.dispatch.bind(view);
  view.dispatch = (tr) => {
    originalDispatch(tr);
    if (tr.docChanged && !isSettingContent) {
      currentContent = editorInstance!.action(getMarkdown());
    }
  };

  console.log('[Milkdown] Editor initialized');
}

window.FinalFinal = {
  setContent(markdown: string) {
    if (!editorInstance) {
      currentContent = markdown;
      return;
    }
    if (currentContent === markdown) return;

    isSettingContent = true;
    try {
      editorInstance.action((ctx) => {
        const view = ctx.get(editorViewCtx);
        const parser = ctx.get(parserCtx);
        const doc = parser(markdown);
        if (!doc) return;

        const { from } = view.state.selection;
        let tr = view.state.tr.replace(0, view.state.doc.content.size, new Slice(doc.content, 0, 0));

        const safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));
        try {
          tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
        } catch {
          tr = tr.setSelection(Selection.atStart(tr.doc));
        }
        view.dispatch(tr);
      });
      currentContent = markdown;
    } finally {
      isSettingContent = false;
    }
  },

  getContent() {
    return editorInstance ? editorInstance.action(getMarkdown()) : currentContent;
  },

  setFocusMode(enabled: boolean) {
    setFocusModeEnabled(enabled);
    if (editorInstance) {
      const view = editorInstance.ctx.get(editorViewCtx);
      view.dispatch(view.state.tr);
    }
  },

  getStats() {
    const content = this.getContent();
    const words = content.split(/\s+/).filter(w => w.length > 0).length;
    return { words, characters: content.length };
  },

  scrollToOffset(offset: number) {
    if (!editorInstance) return;
    const view = editorInstance.ctx.get(editorViewCtx);
    const pos = Math.min(offset, view.state.doc.content.size - 1);
    try {
      const selection = Selection.near(view.state.doc.resolve(pos));
      view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
      view.focus();
    } catch (e) {
      console.warn('[Milkdown] scrollToOffset failed:', e);
    }
  },

  setTheme(cssVariables: string) {
    const root = document.documentElement;
    cssVariables.split(';').filter(s => s.trim()).forEach(pair => {
      const [key, value] = pair.split(':').map(s => s.trim());
      if (key && value) root.style.setProperty(key, value);
    });
  },

  getCursorPosition(): { line: number; column: number } {
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
        if (stripped && parentText &&
            parentText.startsWith(stripped) &&
            stripped.length >= 10) {
          line = i + 1;
          matched = true;
          break;
        }

        // Reverse partial match
        if (stripped && parentText &&
            stripped.startsWith(parentText) &&
            parentText.length >= 10) {
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
    } catch (e) {
      console.error('[Milkdown] getCursorPosition error:', e);
      return { line: 1, column: 0 };
    }
  },

  setCursorPosition(lineCol: { line: number; column: number; scrollFraction?: number }) {
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
          } catch (scrollErr) {
            console.warn('[Milkdown] scroll adjustment failed:', scrollErr);
          }
        });
      }
    } catch (e) {
      console.warn('[Milkdown] setCursorPosition failed:', e);
    }
  },
};

// Initialize editor
initEditor().catch((e) => {
  console.error('[Milkdown] Init failed:', e);
});
