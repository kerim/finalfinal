import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter } from '@codemirror/view';
import { EditorState } from '@codemirror/state';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands';
import { syntaxHighlighting, defaultHighlightStyle } from '@codemirror/language';
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
    };
    __CODEMIRROR_DEBUG__?: {
      editorReady: boolean;
      lastContentLength: number;
      lastStatsUpdate: string;
    };
    __CODEMIRROR_SCRIPT_STARTED__?: number;
  }
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
    if (!editorView) return;
    editorView.dispatch({
      changes: { from: 0, to: editorView.state.doc.length, insert: markdown }
    });
    window.__CODEMIRROR_DEBUG__!.lastContentLength = markdown.length;
    console.log('[CodeMirror] setContent:', markdown.length, 'chars');
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
    if (!editorView) {
      console.log('[CodeMirror] getCursorPosition: editor not ready, returning line 1 col 0');
      return { line: 1, column: 0 };
    }
    try {
      const pos = editorView.state.selection.main.head;
      const line = editorView.state.doc.lineAt(pos);
      const result = {
        line: line.number,  // CodeMirror lines are 1-indexed
        column: pos - line.from
      };
      console.log('[CodeMirror] getCursorPosition: line', result.line, 'col', result.column);
      return result;
    } catch (e) {
      console.error('[CodeMirror] getCursorPosition error:', e);
      return { line: 1, column: 0 };
    }
  },

  setCursorPosition(lineCol: { line: number; column: number }) {
    if (!editorView) {
      console.warn('[CodeMirror] setCursorPosition: editor not ready');
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

      console.log('[CodeMirror] setCursorPosition: line', safeLine, 'col', safeCol, '-> pos', pos);

      editorView.dispatch({
        selection: { anchor: pos },
        effects: EditorView.scrollIntoView(pos, { y: 'center' })
      });
      editorView.focus();
    } catch (e) {
      console.warn('[CodeMirror] setCursorPosition failed:', e);
    }
  }
};

// Initialize on DOM ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initEditor);
} else {
  initEditor();
}

console.log('[CodeMirror] window.FinalFinal API registered');
