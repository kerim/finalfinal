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
  formatTable,
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
  insertCitationAtCursor,
  insertEquation,
  insertEquationDialog,
  insertFootnote,
  insertImage,
  insertLink,
  insertTable,
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
  toggleInlineCode,
  toggleItalic,
  toggleNumberList,
  toggleStrikethrough,
} from './api-formatting';
import { caywRemapPlugin } from './cayw-remap-plugin';
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
import { selectionStatsPlugin } from './selection-stats-plugin';
import { selectionToolbarPlugin } from './selection-toolbar-plugin';
import { slashMenuPlugin } from './slash-completions';
import {
  disableSmartQuotes,
  enableSmartQuotes,
  handleBeforeInput,
  isSmartQuotesEnabled,
  smartQuotesInputHandler,
} from './smart-quotes-plugin';
import {
  disableSpellcheck,
  enableSpellcheck,
  isSpellcheckEnabled,
  setSpellcheckResults,
  spellcheckPlugin,
  triggerSpellcheck,
} from './spellcheck-plugin';
import { handleTablePaste } from './table-paste';
import {
  beginStructuralOp,
  clearStructuralUndoRegistry,
  clearStructuralUndoState,
  finalizeStructuralOpPostOpDoc,
  handleGlobalUndoRedoKeydown,
  maybeAdvanceRegistryOnSyncOriginTx,
  maybeNotifyHistoryEdited,
  receiveRedoOutcome,
  receiveUndoOutcome,
  requestUnifiedRedo,
  requestUnifiedUndo,
  setUndoDescriptor,
} from './undo-coordinator';
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
    // Remaps pending CAYW (/cite) requests' positions across intervening edits while
    // the async Zotero round-trip is in flight — see cayw-remap-plugin.ts.
    caywRemapPlugin,
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
      beforeinput(event, view) {
        return handleBeforeInput(event, view);
      },
      keydown(event, view) {
        // Reset flag on any editing key (typing, backspace, delete)
        if (event.key.length === 1 || event.key === 'Backspace' || event.key === 'Delete') {
          setPendingSlashUndo(false);
        }

        // Backtick with selected text wraps as inline code
        if (event.key === '`' && !event.metaKey && !event.ctrlKey && !event.altKey) {
          const { from, to } = view.state.selection.main;
          if (from !== to) {
            event.preventDefault();
            toggleInlineCode();
            return true;
          }
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
      paste(event, view) {
        // Table paste — must come before image handling
        if (handleTablePaste(event, view)) {
          event.preventDefault();
          return true;
        }

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
    // Unified-undo §4.2/§4.6 predicates -- deliberately run on EVERY transaction in the
    // update (each one's own cheap first check short-circuits whenever there's nothing in
    // the registry/descriptor to act on -- see undo-coordinator.ts). The two are mutually
    // exclusive by construction (one requires the addToHistory annotation !== false, the
    // other requires === false), so call order between them doesn't matter.
    EditorView.updateListener.of((update) => {
      for (const tr of update.transactions) {
        maybeNotifyHistoryEdited(tr);
        // §4.6 advancement rule: absorbs sync-origin transactions (addToHistory === false)
        // that land after a structural op's postOpDoc/preOpDoc was captured.
        maybeAdvanceRegistryOnSyncOriginTx(tr);
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
    // Push selected text to Swift for status-bar selection word count
    selectionStatsPlugin,
    // Spellcheck/grammar decorations via NSSpellChecker
    ...spellcheckPlugin(),
    // Smart quotes — live curling of straight quotes as the user types
    EditorView.inputHandler.of(smartQuotesInputHandler),
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

  // Unified-undo capture-phase keydown interceptor (docs/plans/patient-rewinding-clockwork.md
  // §4.2/§4.7). No merge point needed here the way Milkdown's slash-commands.ts has one --
  // see undo-coordinator.ts's header for why. With the always-empty Phase 2 registry this
  // always returns false (fallthrough), leaving CodeMirror's own `Mod-z`/`Mod-Shift-z`/
  // `Mod-y` keymap bindings (including their embedded smart-slash-undo logic) completely
  // untouched.
  //
  // DEFERRED (Phase 3, do not fix now): no event-target check -- this fires for a Cmd-Z
  // typed anywhere in the document (a native text field, a dialog, etc.), not just inside
  // this editor. Harmless today (getEditorView() gate aside, routing always falls through to
  // a no-op here since nothing but the editor's own keymap reacts to the untouched event),
  // but worth scoping to editor-owned targets before Phase 3 makes the structural path live.
  document.addEventListener(
    'keydown',
    (e) => {
      const currentView = getEditorView();
      if (!currentView) return;
      handleGlobalUndoRedoKeydown(e, currentView);
    },
    true
  );
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
  // Insert a brand-new citation at the current cursor (native toolbar "Cite" button)
  insertCitation: insertCitationAtCursor,
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
  toggleInlineCode,
  insertLink: insertLinkAtCursor,

  // Image API
  insertImage,
  setImageMeta,

  // Table API
  insertTable,
  formatTable,

  // Math equation API
  insertEquation,
  insertEquationDialog,

  // Spellcheck API
  setSpellcheckResults,
  enableSpellcheck,
  disableSpellcheck,
  triggerSpellcheck,
  isSpellcheckEnabled,

  // Smart quotes API
  enableSmartQuotes,
  disableSmartQuotes,
  isSmartQuotesEnabled,
  find,
  findNext: apiFindNext,
  findPrevious: apiFindPrevious,
  replaceCurrent,
  replaceAll: apiReplaceAll,
  clearSearch,
  getSearchState: apiGetSearchState,
  resetForProjectSwitch,

  // Unified-undo API (docs/plans/patient-rewinding-clockwork.md) -- Phase 2 skeleton.
  // requestUnifiedUndo/Redo are the menu-path entry points (Edit > Undo/Redo); with no
  // structural entries ever recorded in this phase, both always fall through to
  // CodeMirror's own text undo/redo. setUndoDescriptor/receiveUndoOutcome/receiveRedoOutcome
  // are the Swift -> JS bridge targets Phase 3+ wires once real structural operations
  // exist -- no Swift call site invokes any of the three yet.
  requestUnifiedUndo,
  requestUnifiedRedo,
  setUndoDescriptor,
  receiveUndoOutcome,
  receiveRedoOutcome,
  // Structural op lifecycle (Phase 3) -- called by StructuralUndoController.swift. Source
  // mode never checkpoint-swaps (degraded undo path, plan §4.4 undo step 3b), so only
  // registry population is exposed here -- see undo-coordinator.ts's header.
  beginStructuralOp,
  finalizeStructuralOpPostOpDoc,
  // Barrier/eviction JS-side clears (Phase 5, plan §4.1/§4.5/§5 backlog) -- called by
  // UnifiedUndoService.invalidateAll()/record()'s eviction path via ContentView's
  // clearStructuralRegistry/clearEditorHistories closures.
  clearStructuralUndoRegistry,
  clearStructuralUndoState,

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
