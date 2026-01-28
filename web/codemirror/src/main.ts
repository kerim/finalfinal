import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter } from '@codemirror/view';
import { EditorState } from '@codemirror/state';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands';
import { syntaxHighlighting, defaultHighlightStyle } from '@codemirror/language';
import { autocompletion, CompletionContext, CompletionResult } from '@codemirror/autocomplete';
import './styles.css';

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
      scrollCursorToCenter: () => void;
      insertAtCursor: (text: string) => void;
      insertBreak: () => void;
      focus: () => void;
    };
    __CODEMIRROR_DEBUG__?: {
      editorReady: boolean;
      lastContentLength: number;
      lastStatsUpdate: string;
    };
    __CODEMIRROR_SCRIPT_STARTED__?: number;
  }
}

// Slash command completions for section breaks and other commands
function slashCompletions(context: CompletionContext): CompletionResult | null {
  const word = context.matchBefore(/\/\w*/);
  if (!word) return null;
  if (word.from === word.to && !context.explicit) return null;

  return {
    from: word.from,
    options: [
      {
        label: '/break',
        detail: 'Insert section break',
        apply: '<!-- ::break:: -->\n\n'
      },
      {
        label: '/h1',
        detail: 'Heading 1',
        apply: '# '
      },
      {
        label: '/h2',
        detail: 'Heading 2',
        apply: '## '
      },
      {
        label: '/h3',
        detail: 'Heading 3',
        apply: '### '
      }
    ]
  };
}

// Mark script start time for debugging
window.__CODEMIRROR_SCRIPT_STARTED__ = Date.now();

let editorView: EditorView | null = null;

// Debug state for Swift introspection
window.__CODEMIRROR_DEBUG__ = {
  editorReady: false,
  lastContentLength: 0,
  lastStatsUpdate: ''
};

// === Diagnostic logging for cursor position debugging ===
let _debugSeq = 0;
const _debugLog: Array<{ seq: number; ts: string; msg: string }> = [];

function debugLog(msg: string) {
  const seq = ++_debugSeq;
  const ts = performance.now().toFixed(2);
  console.log(`[CM DEBUG ${seq}] T=${ts}ms: ${msg}`);
  _debugLog.push({ seq, ts, msg });
  // Keep only last 50 entries
  if (_debugLog.length > 50) _debugLog.shift();
}

// Expose debug log for Swift to query
(window as any).__CM_DEBUG_LOG__ = _debugLog;

function initEditor() {
  const container = document.getElementById('editor');
  if (!container) {
    console.error('[CodeMirror] #editor container not found');
    return;
  }

  const state = EditorState.create({
    doc: '',
    extensions: [
      lineNumbers(),
      highlightActiveLine(),
      highlightActiveLineGutter(),
      history(),
      markdown({ base: markdownLanguage, codeLanguages: languages }),
      syntaxHighlighting(defaultHighlightStyle),
      autocompletion({ override: [slashCompletions] }),
      keymap.of([
        // Filter out Mod-/ (toggle comment) from default keymap to allow Swift to handle mode toggle
        ...defaultKeymap.filter(k => k.key !== 'Mod-/'),
        ...historyKeymap,
        // Cmd+B: Bold
        { key: 'Mod-b', run: () => { wrapSelection('**'); return true; } },
        // Cmd+I: Italic
        { key: 'Mod-i', run: () => { wrapSelection('*'); return true; } },
        // Cmd+K: Link
        { key: 'Mod-k', run: () => { insertLink(); return true; } },
      ]),
      EditorView.lineWrapping,
      EditorView.theme({
        '&': { height: '100%' },
        '.cm-scroller': { overflow: 'auto' }
      })
    ]
  });

  editorView = new EditorView({
    state,
    parent: container
  });

  window.__CODEMIRROR_DEBUG__!.editorReady = true;
  console.log('[CodeMirror] Editor initialized');
}

function wrapSelection(wrapper: string) {
  if (!editorView) return;
  const { from, to } = editorView.state.selection.main;
  const selected = editorView.state.sliceDoc(from, to);
  const wrapped = wrapper + selected + wrapper;
  editorView.dispatch({
    changes: { from, to, insert: wrapped },
    selection: { anchor: from + wrapper.length, head: to + wrapper.length }
  });
}

function insertLink() {
  if (!editorView) return;
  const { from, to } = editorView.state.selection.main;
  const selected = editorView.state.sliceDoc(from, to);
  const linkText = selected || 'link text';
  const inserted = `[${linkText}](url)`;
  editorView.dispatch({
    changes: { from, to, insert: inserted },
    selection: { anchor: from + 1, head: from + 1 + linkText.length }
  });
}

function countWords(text: string): number {
  return text.split(/\s+/).filter(w => w.length > 0).length;
}

// Register window.FinalFinal API
window.FinalFinal = {
  setContent(markdown: string) {
    debugLog(`setContent START, ${markdown.length} chars`);
    if (!editorView) {
      debugLog('setContent: no editorView');
      return;
    }
    const prevLen = editorView.state.doc.length;
    const prevCursor = editorView.state.selection.main.head;
    editorView.dispatch({
      changes: { from: 0, to: prevLen, insert: markdown }
    });
    const newLen = editorView.state.doc.length;
    const newCursor = editorView.state.selection.main.head;
    window.__CODEMIRROR_DEBUG__!.lastContentLength = markdown.length;
    debugLog(`setContent DONE, prevLen=${prevLen}, newLen=${newLen}, prevCursor=${prevCursor}, newCursor=${newCursor}`);
  },

  getContent(): string {
    if (!editorView) return '';
    return editorView.state.doc.toString();
  },

  setFocusMode(enabled: boolean) {
    // Focus mode is WYSIWYG-only; ignore in source mode
    console.log('[CodeMirror] setFocusMode ignored (source mode)');
  },

  getStats() {
    const content = editorView?.state.doc.toString() || '';
    const words = countWords(content);
    const characters = content.length;
    window.__CODEMIRROR_DEBUG__!.lastStatsUpdate = new Date().toISOString();
    return { words, characters };
  },

  scrollToOffset(offset: number) {
    if (!editorView) return;
    const pos = Math.min(offset, editorView.state.doc.length);
    editorView.dispatch({
      effects: EditorView.scrollIntoView(pos, { y: 'start', yMargin: 50 })
    });
    console.log('[CodeMirror] scrollToOffset:', offset);
  },

  setTheme(cssVariables: string) {
    const root = document.documentElement;
    const pairs = cssVariables.split(';').filter(s => s.trim());
    pairs.forEach(pair => {
      const [key, value] = pair.split(':').map(s => s.trim());
      if (key && value) {
        root.style.setProperty(key, value);
      }
    });
    console.log('[CodeMirror] Theme applied with', pairs.length, 'variables');
  },

  getCursorPosition(): { line: number; column: number } {
    debugLog('getCursorPosition START');
    if (!editorView) {
      debugLog('getCursorPosition: editor not ready, returning line 1 col 0');
      return { line: 1, column: 0 };
    }
    try {
      const pos = editorView.state.selection.main.head;
      const docLen = editorView.state.doc.length;
      const line = editorView.state.doc.lineAt(pos);
      const result = {
        line: line.number,  // CodeMirror lines are 1-indexed
        column: pos - line.from
      };
      debugLog(`getCursorPosition DONE: pos=${pos}, docLen=${docLen}, line=${result.line}, col=${result.column}`);
      return result;
    } catch (e) {
      debugLog(`getCursorPosition error: ${e}`);
      return { line: 1, column: 0 };
    }
  },

  setCursorPosition(lineCol: { line: number; column: number }) {
    debugLog(`setCursorPosition START: line=${lineCol.line}, col=${lineCol.column}`);
    if (!editorView) {
      debugLog('setCursorPosition: editor not ready');
      return;
    }
    try {
      const { line, column } = lineCol;

      // Clamp line to valid range
      const lineCount = editorView.state.doc.lines;
      const safeLine = Math.max(1, Math.min(line, lineCount));

      const lineInfo = editorView.state.doc.line(safeLine);
      const maxCol = lineInfo.length;
      const safeCol = Math.max(0, Math.min(column, maxCol));

      const pos = lineInfo.from + safeCol;

      debugLog(`setCursorPosition: lineCount=${lineCount}, safeLine=${safeLine}, safeCol=${safeCol}, pos=${pos}`);

      const cursorBefore = editorView.state.selection.main.head;
      editorView.dispatch({
        selection: { anchor: pos },
        effects: EditorView.scrollIntoView(pos, { y: 'center' })
      });
      const cursorAfter = editorView.state.selection.main.head;
      debugLog(`setCursorPosition DONE: cursorBefore=${cursorBefore}, cursorAfter=${cursorAfter}`);
      editorView.focus();
    } catch (e) {
      debugLog(`setCursorPosition failed: ${e}`);
    }
  },

  scrollCursorToCenter() {
    if (!editorView) return;
    try {
      const pos = editorView.state.selection.main.head;
      const coords = editorView.coordsAtPos(pos);
      if (coords) {
        const viewportHeight = window.innerHeight;
        const targetScrollY = coords.top + window.scrollY - (viewportHeight / 2);
        window.scrollTo({ top: Math.max(0, targetScrollY), behavior: 'instant' });
        console.log('[CodeMirror] scrollCursorToCenter: scrolled to', targetScrollY);
      }
    } catch (e) {
      console.warn('[CodeMirror] scrollCursorToCenter failed:', e);
    }
  },

  insertAtCursor(text: string) {
    if (!editorView) return;
    const { from, to } = editorView.state.selection.main;
    editorView.dispatch({
      changes: { from, to, insert: text },
      selection: { anchor: from + text.length }
    });
    editorView.focus();
    console.log('[CodeMirror] insertAtCursor: inserted', text.length, 'chars');
  },

  insertBreak() {
    // Insert a pseudo-section break marker
    this.insertAtCursor('\n\n<!-- ::break:: -->\n\n');
  },

  focus() {
    if (!editorView) return;
    editorView.focus();
  }
};

// Initialize on DOM ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initEditor);
} else {
  initEditor();
}

console.log('[CodeMirror] window.FinalFinal API registered');
