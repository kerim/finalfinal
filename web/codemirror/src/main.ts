/// <reference types="../global" />
import { autocompletion } from '@codemirror/autocomplete';
import { defaultKeymap, history, redo, undo } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import { highlightSelectionMatches, search } from '@codemirror/search';
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
  insertLink,
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
import { customHighlightStyle, headingDecorationPlugin, syntaxHighlighting } from './heading-plugin';
import { installLineHeightFix } from './line-height-fix';
import { slashCompletions } from './slash-completions';
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
    // Search extension - headless mode (no default keybindings, controlled via Swift)
    search({ top: false }),
    highlightSelectionMatches(),
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
    }),
    // Update citation add button on selection changes
    EditorView.updateListener.of((update) => {
      if (update.selectionSet || update.docChanged) {
        updateCitationAddButton(update.view);
      }
    }),
    // Section anchor plugin - hides <!-- @sid:UUID --> comments and handles clipboard
    anchorPlugin(),
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
