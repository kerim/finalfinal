// Milkdown WYSIWYG Editor for final final
// Uses window.FinalFinal API for Swift ↔ JS communication

// Debug state for Swift-side querying
const debugState = {
  editorReady: false,
  errors: [] as string[],
  // Cursor diagnostics - persists for Swift-side querying before editor switch
  cursorDiagnostics: null as null | {
    head: number;
    parentTextPreview: string;
    matched: boolean;
    matchedLine: number | null;
    fallback: null | { blockCount: number; resultLine: number };
    finalResult: { line: number; column: number };
  },
};
(window as any).__MILKDOWN_DEBUG__ = debugState;

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
    .trim();
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
      getDebugState: () => string;
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
    debugState.errors.push('Editor root element not found');
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
    const errorMsg = e instanceof Error ? e.message : String(e);
    console.error('[Milkdown] Init failed:', e);
    debugState.errors.push(`Init failed: ${errorMsg}`);
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

  debugState.editorReady = true;
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

  getDebugState() {
    return JSON.stringify((window as any).__MILKDOWN_DEBUG__, null, 2);
  },

  getCursorPosition(): { line: number; column: number } {
    if (!editorInstance) {
      console.log('[Milkdown] getCursorPosition: editor not ready');
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

      // Initialize diagnostics for Swift-side querying
      const diag: typeof debugState.cursorDiagnostics = {
        head: head,
        parentTextPreview: parentText.substring(0, 80),
        matched: false,
        matchedLine: null,
        fallback: null,
        finalResult: { line: 1, column: 0 },
      };

      // Find which markdown line contains this paragraph's text
      let line = 1;
      let matched = false;

      for (let i = 0; i < mdLines.length; i++) {
        const stripped = stripMarkdownSyntax(mdLines[i]);

        // Exact match
        if (stripped === parentText) {
          line = i + 1;
          matched = true;
          diag.matched = true;
          diag.matchedLine = line;
          break;
        }

        // Partial match (for long lines that may get truncated)
        if (stripped && parentText &&
            parentText.startsWith(stripped) &&
            stripped.length >= 10) {
          line = i + 1;
          matched = true;
          diag.matched = true;
          diag.matchedLine = line;
          break;
        }

        // Reverse partial match (stripped is longer than parentText)
        if (stripped && parentText &&
            stripped.startsWith(parentText) &&
            parentText.length >= 10) {
          line = i + 1;
          matched = true;
          diag.matched = true;
          diag.matchedLine = line;
          break;
        }
      }

      // Fallback: count blocks from document start to find line
      // Empty markdown lines don't create ProseMirror blocks, so we map block index to content line
      if (!matched) {
        let blockCount = 0;
        view.state.doc.descendants((node, pos) => {
          if (pos >= head) return false;
          if (node.isBlock && node.type.name !== 'doc') {
            blockCount++;
          }
          return true;
        });

        // Map PM block count back to MD line by finding the (blockCount)-th non-empty line
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
        // If we couldn't find enough content lines, use last valid line
        if (contentLinesSeen < blockCount) {
          line = mdLines.length;
        }
        diag.fallback = {
          blockCount: blockCount,
          resultLine: line,
        };
        console.log('[Milkdown] getCursorPosition: fallback mapped blockCount', blockCount, 'to line', line);
      }

      // Calculate column with inline markdown offset mapping
      const blockStart = $head.start($head.depth);
      const offsetInBlock = head - blockStart;
      const lineContent = mdLines[line - 1] || '';

      // Account for line-start syntax
      const syntaxMatch = lineContent.match(/^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/);
      const syntaxLength = syntaxMatch ? syntaxMatch[0].length : 0;
      const afterSyntax = lineContent.slice(syntaxLength);

      // Use mapping function for accurate column
      const column = syntaxLength + textToMdOffset(afterSyntax, offsetInBlock);

      // Store final result and save diagnostics for Swift-side querying
      diag.finalResult = { line, column };
      debugState.cursorDiagnostics = diag;

      console.log('[Milkdown] getCursorPosition: line', line, 'col', column, matched ? '' : '(fallback)');
      return { line, column };
    } catch (e) {
      console.error('[Milkdown] getCursorPosition error:', e);
      return { line: 1, column: 0 };
    }
  },

  setCursorPosition(lineCol: { line: number; column: number; scrollFraction?: number }) {
    if (!editorInstance) {
      console.warn('[Milkdown] setCursorPosition: editor not ready');
      return;
    }

    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      const { line, column } = lineCol;
      const markdown = editorInstance.action(getMarkdown());
      const lines = markdown.split('\n');

      // Get target line and calculate text offset
      const targetLine = lines[line - 1] || '';
      const syntaxMatch = targetLine.match(/^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/);
      const syntaxLength = syntaxMatch ? syntaxMatch[0].length : 0;
      const afterSyntax = targetLine.slice(syntaxLength);
      const mdColumnInContent = Math.max(0, column - syntaxLength);
      const textOffset = mdToTextOffset(afterSyntax, mdColumnInContent);

      // Strip syntax from target line for matching
      const targetText = stripMarkdownSyntax(targetLine);

      // Find matching node in document by text content
      let pmPos = 1;
      let found = false;
      view.state.doc.descendants((node, pos) => {
        if (found) return false;

        if (node.isBlock && node.textContent.trim() === targetText) {
          pmPos = pos + 1 + Math.min(textOffset, node.content.size);
          found = true;
          return false;
        }
        return true;
      });

      // Fallback: map markdown line to PM block via content line index
      // Empty markdown lines don't create ProseMirror blocks, so we count non-empty lines
      if (!found) {
        // Count non-empty lines up to target line to get content index
        let contentLineIndex = 0;
        for (let i = 0; i < line; i++) {
          if (lines[i].trim() !== '') {
            contentLineIndex++;
          }
        }

        // Find the contentLineIndex-th block in PM
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
          }
          return true;
        });
        console.log('[Milkdown] setCursorPosition: fallback used contentLineIndex', contentLineIndex, 'for line', line);
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

      console.log('[Milkdown] setCursorPosition: line', line, 'col', column, '-> pmPos', pmPos);
    } catch (e) {
      console.warn('[Milkdown] setCursorPosition failed:', e);
    }
  },
};

// Initialize editor
initEditor().catch((e) => {
  const errorMsg = e instanceof Error ? e.message : String(e);
  console.error('[Milkdown] Init failed:', e);
  debugState.errors.push(`initEditor failed: ${errorMsg}`);
});
