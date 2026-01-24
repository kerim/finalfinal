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

  getCursorPosition(): { line: number; column: number } {
    if (!editorInstance) {
      console.log('[Milkdown] getCursorPosition: editor not ready, returning line 1 col 0');
      return { line: 1, column: 0 };
    }
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      const { head } = view.state.selection;

      // Walk through document to find line number and column
      let line = 1;
      let lineStart = 0;

      view.state.doc.nodesBetween(0, head, (node, pos) => {
        if (node.isBlock && pos < head) {
          // Each block node after the first increments line count
          if (pos > 0) {
            line++;
            lineStart = pos + 1; // +1 to skip the node boundary
          }
        }
        return true;
      });

      // Column is the offset within the current line
      const column = head - lineStart;
      console.log('[Milkdown] getCursorPosition: line', line, 'col', column, 'head', head);
      return { line, column };
    } catch (e) {
      console.error('[Milkdown] getCursorPosition error:', e);
      return { line: 1, column: 0 };
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

      // Find the position of the target line
      let currentLine = 1;
      let targetPos = 1; // Start after doc boundary

      view.state.doc.nodesBetween(0, view.state.doc.content.size, (node, pos) => {
        if (node.isBlock) {
          if (currentLine === line) {
            // Found target line - position is: node start + 1 (enter block) + column
            const maxCol = Math.max(0, node.content.size);
            targetPos = pos + 1 + Math.min(column, maxCol);
            return false; // Stop iteration
          }
          if (pos > 0) currentLine++;
        }
        return true;
      });

      console.log('[Milkdown] setCursorPosition: line', line, 'col', column, '-> pos', targetPos);

      const safePos = Math.min(Math.max(1, targetPos), view.state.doc.content.size);
      const selection = Selection.near(view.state.doc.resolve(safePos));
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
