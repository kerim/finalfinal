// Milkdown WYSIWYG Editor for final final
// Uses window.FinalFinal API for Swift ↔ JS communication

// === PHASE 1: Verify script execution at the very top ===
(window as any).__MILKDOWN_SCRIPT_STARTED__ = Date.now();
console.log('[Milkdown] SCRIPT TAG EXECUTED - timestamp:', Date.now());

// === PHASE 6: Debug state object for Swift-side querying ===
const debugState = {
  scriptLoaded: true,
  importsComplete: false,
  apiRegistered: false,
  initStarted: false,
  initSteps: [] as string[],
  errors: [] as string[],
  editorCreated: false,
  domReady: false,
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
import './styles.css';

// === PHASE 1: Verify imports completed ===
console.log('[Milkdown] IMPORTS COMPLETED');
debugState.importsComplete = true;
debugState.initSteps.push('Imports completed');

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
  // === PHASE 5: Numbered logging throughout initialization ===
  console.log('[Milkdown] INIT STEP 1: Function entered');
  debugState.initStarted = true;
  debugState.initSteps.push('Step 1: initEditor() entered');

  const root = document.getElementById('editor');
  console.log('[Milkdown] INIT STEP 2: querySelector result:', root);
  debugState.initSteps.push(`Step 2: #editor element = ${root ? 'found' : 'NOT FOUND'}`);

  if (!root) {
    console.error('[Milkdown] INIT STEP 2 FAILED: Editor root element not found');
    debugState.errors.push('Editor root element not found');
    return;
  }

  console.log('[Milkdown] INIT STEP 3: Starting Editor.make()');
  debugState.initSteps.push('Step 3: Starting Editor.make()');

  try {
    editorInstance = await Editor.make()
      .config((ctx) => {
        console.log('[Milkdown] INIT STEP 4: Inside config callback');
        debugState.initSteps.push('Step 4: Inside config callback');
        ctx.set(defaultValueCtx, '');
      })
      .use(commonmark)
      .use(gfm)
      .use(history)
      .use(focusModePlugin)
      .create();

    console.log('[Milkdown] INIT STEP 5: Editor.make().create() completed');
    debugState.initSteps.push('Step 5: Editor created');
    debugState.editorCreated = true;
    console.log('[Milkdown] INIT STEP 6: Editor instance:', editorInstance);
  } catch (e) {
    const errorMsg = e instanceof Error ? e.message : String(e);
    console.error('[Milkdown] INIT STEP FAILED at create:', e);
    debugState.errors.push(`Editor.make().create() failed: ${errorMsg}`);
    throw e;
  }

  console.log('[Milkdown] INIT STEP 7: Appending editor DOM to root');
  debugState.initSteps.push('Step 7: Appending DOM');

  try {
    root.appendChild(editorInstance.ctx.get(editorViewCtx).dom);
    console.log('[Milkdown] INIT STEP 8: DOM appended successfully');
    debugState.initSteps.push('Step 8: DOM appended');
  } catch (e) {
    const errorMsg = e instanceof Error ? e.message : String(e);
    console.error('[Milkdown] INIT STEP 7-8 FAILED:', e);
    debugState.errors.push(`DOM append failed: ${errorMsg}`);
    throw e;
  }

  // Track content changes
  console.log('[Milkdown] INIT STEP 9: Setting up dispatch wrapper');
  debugState.initSteps.push('Step 9: Setting up dispatch');

  const view = editorInstance.ctx.get(editorViewCtx);
  const originalDispatch = view.dispatch.bind(view);
  view.dispatch = (tr) => {
    originalDispatch(tr);
    if (tr.docChanged && !isSettingContent) {
      currentContent = editorInstance!.action(getMarkdown());
    }
  };

  console.log('[Milkdown] INIT STEP 10: Editor fully initialized');
  debugState.initSteps.push('Step 10: Initialization complete');
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
    console.log('[Milkdown] Focus mode:', enabled);
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

  // === PHASE 6: Debug state getter for Swift-side querying ===
  getDebugState() {
    return JSON.stringify((window as any).__MILKDOWN_DEBUG__, null, 2);
  },

  getCursorPosition(): { line: number; column: number; debug?: object } {
    if (!editorInstance) {
      return { line: 1, column: 0, debug: { error: 'editor not ready' } };
    }

    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      const { head } = view.state.selection;
      const markdown = editorInstance.action(getMarkdown());
      const mdLines = markdown.split('\n');

      // Resolve cursor position in document tree
      const $head = view.state.doc.resolve(head);

      // Collect debug info
      const debug: Record<string, unknown> = {
        pmHead: head,
        docSize: view.state.doc.content.size,
        mdLineCount: mdLines.length,
        cursorDepth: $head.depth,
      };

      // Get the immediate parent node (paragraph, heading, etc.)
      // This is the actual text-containing node, NOT a container like bullet_list
      const parentNode = $head.parent;
      const parentText = parentNode.textContent;
      const parentType = parentNode.type.name;

      debug.parentType = parentType;
      debug.parentText = parentText.slice(0, 50);

      // Build ancestry path for debugging
      const ancestry: string[] = [];
      for (let d = $head.depth; d >= 0; d--) {
        ancestry.push($head.node(d).type.name);
      }
      debug.ancestry = ancestry;

      // Find which markdown line contains this paragraph's text
      let line = 1;
      let matchType = 'none';

      for (let i = 0; i < mdLines.length; i++) {
        const rawLine = mdLines[i];

        // Strip markdown syntax for comparison
        const stripped = rawLine
          .replace(/^#+\s*/, '')           // headings
          .replace(/^\s*[-*+]\s*/, '')     // unordered list items
          .replace(/^\s*\d+\.\s*/, '')     // ordered list items
          .replace(/^\s*>\s*/, '')         // blockquotes
          .replace(/\*\*([^*]+)\*\*/g, '$1')  // bold
          .replace(/__([^_]+)__/g, '$1')      // bold alt
          .replace(/\*([^*]+)\*/g, '$1')      // italic
          .replace(/_([^_]+)_/g, '$1')        // italic alt
          .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1') // links
          .replace(/`([^`]+)`/g, '$1')        // inline code
          .trim();

        // Try exact match first
        if (stripped === parentText) {
          line = i + 1;
          matchType = 'exact';
          debug.matchedLine = i + 1;
          debug.matchedLineText = rawLine.slice(0, 40);
          debug.strippedLine = stripped.slice(0, 40);
          break;
        }

        // Then try prefix match (for long lines or partial matches)
        if (stripped && parentText.startsWith(stripped) && stripped.length >= 10) {
          line = i + 1;
          matchType = 'prefix';
          debug.matchedLine = i + 1;
          debug.matchedLineText = rawLine.slice(0, 40);
          debug.strippedLine = stripped.slice(0, 40);
          break;
        }

        // Also check if stripped starts with parentText (for short paragraphs)
        if (parentText && stripped.startsWith(parentText.slice(0, 15)) && parentText.length >= 5) {
          line = i + 1;
          matchType = 'reverse-prefix';
          debug.matchedLine = i + 1;
          debug.matchedLineText = rawLine.slice(0, 40);
          debug.strippedLine = stripped.slice(0, 40);
          break;
        }
      }

      debug.matchType = matchType;

      // Calculate column offset within the paragraph
      const blockStart = $head.start($head.depth);
      const offsetInBlock = head - blockStart;

      // Get the markdown line
      const lineContent = mdLines[line - 1] || '';

      // Account for line-start syntax (list markers, heading #, etc.)
      const syntaxMatch = lineContent.match(/^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/);
      const syntaxLength = syntaxMatch ? syntaxMatch[0].length : 0;

      // Column = syntax prefix + offset in text
      // Note: This simple approach works for lists, paragraphs, headings.
      // Inline markdown like **bold** may have cursor off by 2-4 chars (acceptable tradeoff).
      const column = syntaxLength + Math.min(offsetInBlock, lineContent.length - syntaxLength);

      debug.offsetInBlock = offsetInBlock;
      debug.syntaxLength = syntaxLength;
      debug.calculatedLine = line;
      debug.calculatedColumn = column;

      return { line, column, debug };
    } catch (e) {
      return { line: 1, column: 0, debug: { error: String(e) } };
    }
  },

  setCursorPosition(lineCol: { line: number; column: number }) {
    if (!editorInstance) {
      console.warn('[Milkdown] setCursorPosition: editor not ready');
      return;
    }

    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      const { line, column } = lineCol;

      // Get serialized markdown
      const markdown = editorInstance.action(getMarkdown());
      const lines = markdown.split('\n');

      // Calculate markdown offset from line:column
      let mdOffset = 0;
      for (let i = 0; i < line - 1 && i < lines.length; i++) {
        mdOffset += lines[i].length + 1; // +1 for newline
      }
      const lineContent = lines[line - 1] || '';
      mdOffset += Math.min(column, lineContent.length);

      // Map markdown offset back to PM position
      const docSize = view.state.doc.content.size;
      const mdLength = markdown.length;

      let pmPos = Math.round((mdOffset / Math.max(mdLength, 1)) * docSize);
      pmPos = Math.max(1, Math.min(pmPos, docSize));

      console.log('[Milkdown] setCursorPosition: line', line, 'col', column,
                  '-> mdOffset', mdOffset, '-> pmPos', pmPos);

      const selection = Selection.near(view.state.doc.resolve(pmPos));
      view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
      view.focus();
    } catch (e) {
      console.warn('[Milkdown] setCursorPosition failed:', e);
    }
  },
};

// Register API before calling initEditor
console.log('[Milkdown] window.FinalFinal API registering...');
debugState.apiRegistered = true;
debugState.initSteps.push('API registered');

// Check DOM ready state
console.log('[Milkdown] Document readyState:', document.readyState);
debugState.domReady = document.readyState === 'complete' || document.readyState === 'interactive';
debugState.initSteps.push(`DOM readyState: ${document.readyState}`);

initEditor()
  .then(() => {
    console.log('[Milkdown] initEditor() promise resolved');
    debugState.initSteps.push('initEditor promise resolved');
  })
  .catch((e) => {
    const errorMsg = e instanceof Error ? e.message : String(e);
    console.error('[Milkdown] Init failed:', e);
    debugState.errors.push(`initEditor failed: ${errorMsg}`);
  });

console.log('[Milkdown] window.FinalFinal API registered');
