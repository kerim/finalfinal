/// <reference types="../global" />
// Milkdown WYSIWYG Editor for final final
// Uses window.FinalFinal API for Swift ↔ JS communication

import { defaultValueCtx, Editor, editorViewCtx } from '@milkdown/kit/core';
import { clipboard } from '@milkdown/kit/plugin/clipboard';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { getMarkdown } from '@milkdown/kit/utils';
import { annotationDisplayPlugin } from './annotation-display-plugin';
import { annotationPlugin } from './annotation-plugin';
import {
  addCitationItems,
  citationPickerCallback,
  citationPickerCancelled,
  citationPickerError,
  editCitationCallback,
  getAllCitekeys,
  getAnnotations,
  getBibliographyCitekeys,
  getCAYWDebugState,
  getCitationCount,
  insertAnnotation,
  requestCitationResolution,
  scrollToAnnotation,
  searchCitationsCallback,
  setAnnotationDisplayModes,
  setCitationLibraryApi,
  setCitationStyle,
  setHideCompletedTasks,
  toggleHighlight,
} from './api-annotations';
import {
  applyBlocks,
  confirmBlockIdsApi,
  getBlockAtCursor,
  getBlockChangesApi,
  getContent,
  hasBlockChanges,
  resetEditorState,
  resetForProjectSwitch,
  scrollToBlock,
  setContent,
  setContentWithBlockIds,
  syncBlockIds,
} from './api-content';
import {
  clearSearchApi,
  findApi,
  findNextApi,
  findPreviousApi,
  focus,
  getCursorPosition,
  getEditorMode,
  getSearchStateApi,
  getStats,
  initialize,
  insertAtCursor,
  insertBreak,
  replaceAllApi,
  replaceCurrentApi,
  scrollCursorToCenter,
  scrollToOffset,
  setCursorPosition,
  setEditorMode,
  setFocusMode,
  setTheme,
} from './api-modes';
import { autolinkPlugin } from './autolink-plugin';
import { bibliographyPlugin } from './bibliography-plugin';
import { blockIdPlugin } from './block-id-plugin';
import { blockSyncPlugin } from './block-sync-plugin';
import { openCAYWPicker } from './cayw';
import { citationPlugin } from './citation-plugin';
import { restoreCitationLibrary } from './citation-search';
import {
  getCurrentContent,
  getEditorInstance,
  getIsSettingContent,
  setCurrentContent,
  setEditorInstance,
} from './editor-state';
import { focusModePlugin, isFocusModeEnabled } from './focus-mode-plugin';
import { headingNodeViewPlugin } from './heading-nodeview-plugin';
import { highlightPlugin } from './highlight-plugin';
import './link-click-handler';
import { linkTooltipPlugin, openLinkEdit } from './link-tooltip';
import { searchPlugin } from './search-plugin';
import { sectionBreakPlugin } from './section-break-plugin';
import { configureSlash, slash } from './slash-commands';
import { sourceModePlugin } from './source-mode-plugin';
import {
  disableSpellcheck as disableSpellcheckImpl,
  enableSpellcheck as enableSpellcheckImpl,
  setSpellcheckResults as setSpellcheckResultsImpl,
  spellcheckPlugin,
} from './spellcheck-plugin';
import './styles.css';
// Import types to ensure declare global is included in the bundle
import './types';

async function initEditor() {
  const root = document.getElementById('editor');
  if (!root) {
    console.error('[Milkdown] Editor root element not found');
    return;
  }

  try {
    const editorInstance = await Editor.make()
      .config((ctx) => {
        ctx.set(defaultValueCtx, '');
      })
      .config(configureSlash)
      // Plugin order matters:
      // 1. commonmark/gfm must be first (base schema)
      // 2. Custom plugins extend the schema after base is established
      // 3. sectionBreak/annotation must be before commonmark to intercept HTML comments
      //    before they get filtered out
      // 4. highlightPlugin MUST be after commonmark to survive parse-serialize cycle
      //    (fixes ==text== not persisting when switching to CodeMirror)
      // 5. citationPlugin MUST be before commonmark to parse [@citekey] syntax
      .use(blockIdPlugin) // Assign stable IDs to block-level nodes
      .use(blockSyncPlugin) // Track block changes for Swift sync
      .use(sectionBreakPlugin) // Intercept <!-- ::break:: --> before commonmark filters it
      .use(bibliographyPlugin) // Intercept <!-- ::auto-bibliography:: --> before commonmark filters it
      .use(annotationPlugin) // Intercept annotation comments before filtering
      .use(citationPlugin) // Parse [@citekey] citations before commonmark
      .use(commonmark)
      .use(gfm)
      .use(autolinkPlugin) // Auto-link bare URLs on space - AFTER commonmark for link schema
      .use(highlightPlugin) // ==highlight== syntax - AFTER commonmark for serialization
      .use(history)
      .use(clipboard) // Parse pasted markdown as rich text instead of literal text
      .use(focusModePlugin)
      .use(sourceModePlugin) // Dual-appearance source mode
      .use(annotationDisplayPlugin) // Controls annotation visibility
      .use(headingNodeViewPlugin) // Custom heading rendering for source mode # selection
      // citationNodeView is now included in citationPlugin (same file = correct atom identity)
      .use(searchPlugin) // Search highlighting decorations
      .use(spellcheckPlugin) // Spellcheck/grammar decorations via NSSpellChecker
      .use(linkTooltipPlugin) // Custom link preview/edit tooltips (no Vue dependency)
      .use(slash)
      .create();

    setEditorInstance(editorInstance);

    root.appendChild(editorInstance.ctx.get(editorViewCtx).dom);

    // Restore citation library from localStorage (survives editor toggle)
    restoreCitationLibrary();

    // RACE CONDITION FIX: If content was set before editor was ready, load it now
    // This handles the case where Swift calls initialize() before initEditor() completes
    const currentContent = getCurrentContent();
    if (currentContent?.trim()) {
      window.FinalFinal.setContent(currentContent);
    }
  } catch (e) {
    console.error('[Milkdown] Init failed:', e);
    throw e;
  }

  // Track content changes
  const editorInstance = getEditorInstance()!;
  const view = editorInstance.ctx.get(editorViewCtx);
  const originalDispatch = view.dispatch.bind(view);
  view.dispatch = (tr) => {
    originalDispatch(tr);

    if (tr.docChanged && !getIsSettingContent()) {
      setCurrentContent(editorInstance.action(getMarkdown()));
    }
  };

  // Handle auto-correct: intercept replacement text input to prevent heading corruption
  // macOS auto-correct uses DOM manipulation that can confuse ProseMirror's node structure,
  // causing headings to lose their content. By handling it manually through ProseMirror's
  // transaction system, we preserve the document structure.
  view.dom.addEventListener('beforeinput', (e: InputEvent) => {
    if (e.inputType === 'insertReplacementText') {
      e.preventDefault();

      // Get the replacement text from the event
      const replacement = e.dataTransfer?.getData('text/plain') || e.data || '';
      if (!replacement) return;

      // Get the range being replaced from getTargetRanges()
      const ranges = e.getTargetRanges();
      if (ranges.length === 0) {
        // Fallback: use current selection
        const { from, to } = view.state.selection;
        const tr = view.state.tr.replaceWith(from, to, view.state.schema.text(replacement));
        view.dispatch(tr);
        return;
      }

      // Convert DOM range to ProseMirror positions
      const range = ranges[0];
      const startPos = view.posAtDOM(range.startContainer, range.startOffset);
      const endPos = view.posAtDOM(range.endContainer, range.endOffset);

      // Perform the replacement through ProseMirror
      const tr = view.state.tr.replaceWith(startPos, endPos, view.state.schema.text(replacement));
      view.dispatch(tr);
    }
  });

  // Add keyboard shortcut: Cmd+Shift+K opens citation picker
  document.addEventListener(
    'keydown',
    (e) => {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === 'k') {
        e.preventDefault();
        e.stopPropagation();

        const currentEditor = getEditorInstance();
        if (!currentEditor) return;

        const currentView = currentEditor.ctx.get(editorViewCtx);
        const { from } = currentView.state.selection;

        // Open CAYW picker - no /cite text to replace, so start and end are the same
        openCAYWPicker(from, from);
      }
    },
    true
  );

  // Add keyboard shortcut: Cmd+K opens link creation/editing
  document.addEventListener(
    'keydown',
    (e) => {
      if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key === 'k') {
        e.preventDefault();
        e.stopPropagation();

        const currentEditor = getEditorInstance();
        if (!currentEditor) return;

        const currentView = currentEditor.ctx.get(editorViewCtx);
        openLinkEdit(currentView);
      }
    },
    true
  );
}

// === window.FinalFinal API — thin delegation layer ===

window.FinalFinal = {
  setContent,
  getContent,
  setFocusMode,
  getStats,
  scrollToOffset,
  setTheme,
  getCursorPosition,
  setCursorPosition,
  scrollCursorToCenter,
  insertAtCursor,
  insertBreak,
  focus,
  initialize,
  // Annotation API
  setAnnotationDisplayModes,
  getAnnotations,
  scrollToAnnotation,
  insertAnnotation,
  setHideCompletedTasks,
  toggleHighlight,
  // Citation API
  setCitationLibrary: setCitationLibraryApi,
  setCitationStyle,
  getBibliographyCitekeys,
  getCitationCount,
  getAllCitekeys,
  requestCitationResolution,
  addCitationItems,
  searchCitationsCallback,
  citationPickerCallback,
  citationPickerCancelled,
  citationPickerError,
  editCitationCallback,
  getCAYWDebugState,
  // Block-based API (Phase B)
  getBlockChanges: getBlockChangesApi,
  applyBlocks,
  confirmBlockIds: confirmBlockIdsApi,
  syncBlockIds,
  setContentWithBlockIds,
  scrollToBlock,
  getBlockAtCursor,
  hasBlockChanges,
  // Dual-appearance mode API (Phase C)
  setEditorMode,
  getEditorMode,
  // Cleanup API
  resetEditorState,
  resetForProjectSwitch,
  // Spellcheck API
  setSpellcheckResults: setSpellcheckResultsImpl,
  enableSpellcheck: enableSpellcheckImpl,
  disableSpellcheck: disableSpellcheckImpl,
  // Find/replace API
  find: findApi,
  findNext: findNextApi,
  findPrevious: findPreviousApi,
  replaceCurrent: replaceCurrentApi,
  replaceAll: replaceAllApi,
  clearSearch: clearSearchApi,
  getSearchState: getSearchStateApi,

  // Test snapshot hook — read-only, calls existing API methods, no behavior change
  __testSnapshot() {
    const content = window.FinalFinal.getContent();
    const cursorPosition = window.FinalFinal.getCursorPosition();
    const stats = window.FinalFinal.getStats();
    return {
      content,
      cursorPosition,
      stats,
      editorReady: getEditorInstance() !== null,
      focusModeEnabled: isFocusModeEnabled(),
    };
  },
};

// Initialize editor
initEditor().catch((e) => {
  console.error('[Milkdown] Init failed:', e);
});
