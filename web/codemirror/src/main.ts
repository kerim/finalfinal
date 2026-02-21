/// <reference types="../global" />
import { autocompletion } from '@codemirror/autocomplete';
import { defaultKeymap, history, redo, undo } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { syntaxTree } from '@codemirror/language';
import { languages } from '@codemirror/language-data';
import { search } from '@codemirror/search';
import { EditorState } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { anchorPlugin } from './anchor-plugin';
import {
  apiFindNext,
  apiFindPrevious,
  apiGetSearchState,
  apiReplaceAll,
  citationPickerCallback,
  citationPickerCancelled,
  citationPickerError,
  clearSearch,
  find,
  focusEditor,
  getAnnotations,
  getContent,
  getContentClean,
  getContentRaw,
  getCursorPosition,
  getStats,
  initialize,
  insertAnnotation,
  insertAtCursor,
  insertBreak,
  insertFootnote,
  insertLink,
  renumberFootnotes,
  scrollToFootnoteDefinition,
  replaceCurrent,
  resetForProjectSwitch,
  scrollCursorToCenter,
  scrollToAnnotation,
  scrollToOffset,
  setAnnotationDisplayModes,
  setContent,
  setCursorPosition,
  setFocusMode,
  setTheme,
  toggleHighlight,
  wrapSelection,
} from './api';
import { updateCitationAddButton } from './citations';
import { getPendingSlashUndo, setEditorExtensions, setEditorView, setPendingSlashUndo } from './editor-state';
import { focusModePlugin, isFocusModeEnabled } from './focus-mode-plugin';
import { footnoteDecorationPlugin } from './footnote-decoration-plugin';
import { customHighlightStyle, headingDecorationPlugin, syntaxHighlighting } from './heading-plugin';
import { installLineHeightFix } from './line-height-fix';
import { scrollStabilizer } from './scroll-stabilizer';
import { slashCompletions } from './slash-completions';
import {
  disableSpellcheck,
  enableSpellcheck,
  setSpellcheckResults,
  spellcheckPlugin,
  triggerSpellcheck,
} from './spellcheck-plugin';
import './styles.css';
// Import types.ts for declare global side-effect
import './types';

function initEditor() {
  const container = document.getElementById('editor');
  if (!container) {
    console.error('[CodeMirror] #editor container not found');
    return;
  }

  // Store extensions at module level so resetForProjectSwitch can recreate EditorState
  const extensions = [
    history(),
    markdown({ base: markdownLanguage, codeLanguages: languages }),
    syntaxHighlighting(customHighlightStyle),
    headingDecorationPlugin,
    focusModePlugin,
    scrollStabilizer,
    // Search extension - headless mode (no default keybindings, controlled via Swift)
    search({ top: false }),
    autocompletion({ override: [slashCompletions] }),
    keymap.of([
      // Filter out Mod-/ (toggle comment) from default keymap to allow Swift to handle mode toggle
      ...defaultKeymap.filter((k) => k.key !== 'Mod-/'),
      // Custom undo: after slash command, also removes the "/" trigger
      {
        key: 'Mod-z',
        run: (view) => {
          if (getPendingSlashUndo()) {
            // Undo the slash command insertion
            undo(view);

            // Delete the "/" that was restored
            const pos = view.state.selection.main.head;
            if (pos > 0) {
              const charBefore = view.state.sliceDoc(pos - 1, pos);
              if (charBefore === '/') {
                view.dispatch({
                  changes: { from: pos - 1, to: pos, insert: '' },
                });
              }
            }
            setPendingSlashUndo(false);
            return true;
          }
          // Normal undo
          return undo(view);
        },
      },
      // Redo bindings (Mac and Windows)
      { key: 'Mod-Shift-z', run: (view) => redo(view) },
      { key: 'Mod-y', run: (view) => redo(view) },
      // Cmd+B: Bold
      {
        key: 'Mod-b',
        run: () => {
          wrapSelection('**');
          return true;
        },
      },
      // Cmd+I: Italic
      {
        key: 'Mod-i',
        run: () => {
          wrapSelection('*');
          return true;
        },
      },
      // Cmd+K: Link
      {
        key: 'Mod-k',
        run: () => {
          insertLink();
          return true;
        },
      },
    ]),
    EditorView.lineWrapping,
    EditorView.theme({
      '&': {
        height: '100%',
        fontSize: 'var(--font-size-body, 18px)',
        fontWeight: 'var(--weight-body, 400)',
        lineHeight: 'var(--line-height-body, 1.75)',
      },
      '.cm-scroller': {
        overflow: 'auto',
        fontFamily: 'var(--font-body)',
        lineHeight: 'var(--line-height-body, 1.75)',
      },
    }),
    // Reset pendingSlashUndo on any editing key
    EditorView.domEventHandlers({
      keydown(event, _view) {
        // Reset flag on any editing key (typing, backspace, delete)
        if (event.key.length === 1 || event.key === 'Backspace' || event.key === 'Delete') {
          setPendingSlashUndo(false);
        }
        return false;
      },
      click(event, view) {
        // Cmd+click to open URLs in system browser
        if (!(event.metaKey || event.ctrlKey)) return false;
        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        if (!pos) return false;

        const tree = syntaxTree(view.state);
        let node = tree.resolveInner(pos);
        while (node) {
          if (node.name === 'URL' || node.name === 'Autolink') {
            const url = view.state.sliceDoc(node.from, node.to).replace(/^<|>$/g, '');
            window.webkit?.messageHandlers?.openURL?.postMessage(url);
            event.preventDefault();
            return true;
          }
          if (node.name === 'Link') {
            const urlChild = node.getChild('URL');
            if (urlChild) {
              const url = view.state.sliceDoc(urlChild.from, urlChild.to);
              window.webkit?.messageHandlers?.openURL?.postMessage(url);
              event.preventDefault();
              return true;
            }
          }
          node = node.parent;
        }
        return false;
      },
    }),
    // Update citation add button on selection changes
    EditorView.updateListener.of((update) => {
      if (update.selectionSet || update.docChanged) {
        updateCitationAddButton(update.view);
      }
    }),
    // Section anchor plugin - hides <!-- @sid:UUID --> comments and handles clipboard
    anchorPlugin(),
    // Footnote decoration plugin - clickable [^N] refs and [^N]: defs
    footnoteDecorationPlugin(),
    // Spellcheck/grammar decorations via NSSpellChecker
    ...spellcheckPlugin(),
  ];

  setEditorExtensions(extensions);

  const state = EditorState.create({
    doc: '',
    extensions,
  });

  const view = new EditorView({
    state,
    parent: container,
  });

  // Fix CM6's defaultLineHeight measurement — must be called after EditorView creation
  // because it patches the internal docView.measureTextSize() method
  installLineHeightFix(view);

  setEditorView(view);
}

// Register window.FinalFinal API — thin delegation to api.ts implementations
window.FinalFinal = {
  setContent,
  getContent,
  getContentClean,
  getContentRaw,
  setFocusMode,
  getStats,
  scrollToOffset,
  setTheme,
  getCursorPosition,
  setCursorPosition,
  scrollCursorToCenter,
  insertAtCursor,
  insertBreak,
  focus: focusEditor,
  initialize,
  setAnnotationDisplayModes,
  getAnnotations,
  scrollToAnnotation,
  insertAnnotation,
  toggleHighlight,
  citationPickerCallback,
  citationPickerCancelled,
  citationPickerError,
  // Footnote API
  setFootnoteDefinitions: (_defs: Record<string, string>) => {
    // CodeMirror shows raw markdown — no popup needed, but API must exist for Swift calls
  },
  insertFootnote: (...args: Parameters<typeof insertFootnote>) => {
    console.log('[DIAG-FN] CM window.FinalFinal.insertFootnote() called via API');
    const result = insertFootnote(...args);
    console.log('[DIAG-FN] CM window.FinalFinal.insertFootnote() returned:', result);
    return result;
  },
  renumberFootnotes,
  scrollToFootnoteDefinition,
  // Spellcheck API
  setSpellcheckResults,
  enableSpellcheck,
  disableSpellcheck,
  triggerSpellcheck,
  find,
  findNext: apiFindNext,
  findPrevious: apiFindPrevious,
  replaceCurrent,
  replaceAll: apiReplaceAll,
  clearSearch,
  getSearchState: apiGetSearchState,
  resetForProjectSwitch,

  // Test snapshot hook — read-only, calls existing API methods, no behavior change
  __testSnapshot() {
    const content = window.FinalFinal.getContent();
    const cursorPosition = window.FinalFinal.getCursorPosition();
    const stats = window.FinalFinal.getStats();
    return {
      content,
      cursorPosition,
      stats,
      editorReady: true,
      focusModeEnabled: isFocusModeEnabled(),
    };
  },
};

// Initialize on DOM ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initEditor);
} else {
  initEditor();
}
