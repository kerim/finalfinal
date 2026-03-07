/// <reference types="../global" />
import { defaultKeymap, history, redo, undo } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { syntaxTree } from '@codemirror/language';
import { languages } from '@codemirror/language-data';
import { search } from '@codemirror/search';
import { EditorState } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { anchorPlugin } from './anchor-plugin';
import { annotationDecorationPlugin } from './annotation-decoration-plugin';
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
  getCurrentSectionTitle,
  getCursorPosition,
  getStats,
  initialize,
  insertAnnotation,
  insertAtCursor,
  insertBreak,
  insertFootnote,
  insertImage,
  insertLink,
  renumberFootnotes,
  replaceCurrent,
  resetForProjectSwitch,
  scrollCursorToCenter,
  scrollToAnnotation,
  scrollToFootnoteDefinition,
  scrollToFraction,
  scrollToLine,
  scrollToOffset,
  setAnnotationDisplayModes,
  setContent,
  setCursorPosition,
  setFocusMode,
  setPendingCMDropPos,
  setTheme,
  toggleHighlight,
} from './api';
import {
  insertLinkAtCursor,
  setHeading,
  toggleBlockquote,
  toggleBold,
  toggleBulletList,
  toggleCodeBlock,
  toggleItalic,
  toggleNumberList,
  toggleStrikethrough,
} from './api-formatting';
import { updateCitationAddButton } from './citations';
import {
  getEditorView,
  getPendingSlashUndo,
  setEditorExtensions,
  setEditorView,
  setPendingSlashUndo,
  setZoomFootnoteState,
} from './editor-state';
import { focusModePlugin, isFocusModeEnabled } from './focus-mode-plugin';
import { footnoteDecorationPlugin } from './footnote-decoration-plugin';
import { customHighlightStyle, headingDecorationPlugin, syntaxHighlighting } from './heading-plugin';
import { imagePreviewPlugin, setImageMeta } from './image-preview-plugin';
import { installLineHeightFix } from './line-height-fix';
import { scrollStabilizer } from './scroll-stabilizer';
import { selectionToolbarPlugin } from './selection-toolbar-plugin';
import { slashMenuPlugin } from './slash-completions';
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
    EditorView.exceptionSink.of((e) => {
      console.error('[CM Plugin Error]', e);
      (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
        type: 'plugin-error',
        message: e instanceof Error ? `${e.message}\n${e.stack}` : String(e),
      });
    }),
    history(),
    markdown({ base: markdownLanguage, codeLanguages: languages }),
    syntaxHighlighting(customHighlightStyle),
    headingDecorationPlugin,
    focusModePlugin,
    scrollStabilizer,
    // Search extension - headless mode (no default keybindings, controlled via Swift)
    search({ top: false }),
    slashMenuPlugin,
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
      // Cmd+B: Bold (toggle)
      {
        key: 'Mod-b',
        run: () => toggleBold(),
      },
      // Cmd+I: Italic (toggle)
      {
        key: 'Mod-i',
        run: () => toggleItalic(),
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
    // Reset pendingSlashUndo on any editing key, handle paste/drop for images
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
      paste(event, _view) {
        const items = event.clipboardData?.items;
        if (!items) return false;
        for (const item of items) {
          if (item.type.startsWith('image/')) {
            event.preventDefault();
            const file = item.getAsFile();
            if (!file) return true;
            const reader = new FileReader();
            reader.onload = () => {
              const base64 = (reader.result as string).split(',')[1];
              (window as any).webkit?.messageHandlers?.pasteImage?.postMessage({
                data: base64,
                type: file.type,
                name: file.name || null,
              });
            };
            reader.readAsDataURL(file);
            return true;
          }
        }
        return false;
      },
      drop(event, view) {
        const files = event.dataTransfer?.files;
        if (!files || files.length === 0) return false;
        const imageFile = Array.from(files).find((f) => f.type.startsWith('image/'));
        if (!imageFile) return false;
        event.preventDefault();
        event.stopPropagation();

        // Capture drop position
        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        setPendingCMDropPos(pos ?? view.state.doc.length);

        const reader = new FileReader();
        reader.onload = () => {
          const base64 = (reader.result as string).split(',')[1];
          (window as any).webkit?.messageHandlers?.pasteImage?.postMessage({
            data: base64,
            type: imageFile.type,
            name: imageFile.name || null,
          });
        };
        reader.readAsDataURL(imageFile);
        return true;
      },
    }),
    // Update citation add button on selection changes
    EditorView.updateListener.of((update) => {
      if (update.selectionSet || update.docChanged) {
        updateCitationAddButton(update.view);
      }
    }),
    // Debounced push-based content messaging to Swift (replaces 500ms polling as primary)
    (() => {
      let cmPushTimer: ReturnType<typeof setTimeout> | null = null;
      return EditorView.updateListener.of((update) => {
        if (update.docChanged) {
          if (cmPushTimer) clearTimeout(cmPushTimer);
          cmPushTimer = setTimeout(() => {
            const view = getEditorView();
            if (!view) return;
            const raw = view.state.doc.toString(); // raw includes anchors
            (window as any).webkit?.messageHandlers?.contentChanged?.postMessage(raw);
          }, 50);
        }
      });
    })(),
    // Debounced section change push to Swift (instant highlight on cursor move)
    (() => {
      let cmSectionTimer: ReturnType<typeof setTimeout> | null = null;
      let lastTrackedTitle: string | null = null;
      return EditorView.updateListener.of((update) => {
        if (update.selectionSet || update.docChanged) {
          if (cmSectionTimer) clearTimeout(cmSectionTimer);
          cmSectionTimer = setTimeout(() => {
            const newTitle = window.FinalFinal.getCurrentSectionTitle();
            if (newTitle !== lastTrackedTitle) {
              lastTrackedTitle = newTitle;
              (window as any).webkit?.messageHandlers?.sectionChanged?.postMessage({
                title: newTitle || '',
                blockId: null, // CodeMirror has no block IDs
              });
            }
          }, 150);
        }
      });
    })(),
    // Section anchor plugin - hides <!-- @sid:UUID --> comments and handles clipboard
    anchorPlugin(),
    // Footnote decoration plugin - clickable [^N] refs and [^N]: defs
    footnoteDecorationPlugin(),
    // Annotation decoration plugin - type-colored annotation marks
    annotationDecorationPlugin(),
    // Image preview plugin - inline preview below ![alt](media/...) lines
    ...imagePreviewPlugin(),
    // Selection toolbar - floating format bar on text selection
    selectionToolbarPlugin,
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
  getCurrentSectionTitle,
  getContentClean,
  getContentRaw,
  setFocusMode,
  getStats,
  scrollToOffset,
  setTheme,
  getCursorPosition,
  setCursorPosition,
  scrollCursorToCenter,
  scrollToFraction,
  scrollToLine,
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
  insertFootnote,
  renumberFootnotes,
  scrollToFootnoteDefinition,
  setZoomFootnoteState: (zoomed: boolean, maxLabel: number) => {
    setZoomFootnoteState(zoomed, maxLabel);
  },
  // Formatting API
  toggleBold,
  toggleItalic,
  toggleStrikethrough,
  setHeading,
  toggleBulletList,
  toggleNumberList,
  toggleBlockquote,
  toggleCodeBlock,
  insertLink: insertLinkAtCursor,

  // Image API
  insertImage,
  setImageMeta,

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

  // Combined poll data for batched 3s fallback polling
  getPollData() {
    return JSON.stringify({
      stats: window.FinalFinal.getStats(),
      sectionTitle: window.FinalFinal.getCurrentSectionTitle(),
      sectionBlockId: null,
    });
  },

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
