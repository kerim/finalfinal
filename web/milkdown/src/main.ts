/// <reference types="../global" />
// Milkdown WYSIWYG Editor for final final
// Uses window.FinalFinal API for Swift ↔ JS communication

import { defaultValueCtx, Editor, editorViewCtx } from '@milkdown/kit/core';
import { clipboard } from '@milkdown/kit/plugin/clipboard';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { $prose, getMarkdown } from '@milkdown/kit/utils';
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
  insertImage,
  resetEditorState,
  resetForProjectSwitch,
  scrollToBlock,
  setContent,
  setContentWithBlockIds,
  syncBlockIds,
  updateHeadingLevels,
} from './api-content';
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
import {
  clearSearchApi,
  findApi,
  findNextApi,
  findPreviousApi,
  focus,
  getCurrentSectionBlockId,
  getCurrentSectionTitle,
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
  scrollToFraction,
  scrollToLine,
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
  clearContentPushTimer,
  getContentHasBeenSet,
  getCurrentContent,
  getEditorInstance,
  getIsSettingContent,
  setContentPushTimer,
  setCurrentContent,
  setEditorInstance,
  setZoomFootnoteState,
} from './editor-state';
import { focusModePlugin, isFocusModeEnabled } from './focus-mode-plugin';
import {
  footnotePlugin,
  insertFootnote,
  renumberFootnotes,
  scrollToFootnoteDefinition,
  setFootnoteDefinitions,
} from './footnote-plugin';
import { headingNodeViewPlugin } from './heading-nodeview-plugin';
import { highlightPlugin } from './highlight-plugin';
import { imagePlugin } from './image-plugin';
import './link-click-handler';
import { linkTooltipPlugin, openLinkEdit } from './link-tooltip';
import { searchPlugin } from './search-plugin';
import { sectionBreakPlugin } from './section-break-plugin';
import { selectionToolbarPlugin } from './selection-toolbar-plugin';
import { configureSlash, slash } from './slash-commands';
import { isSourceModeEnabled, sourceModePlugin } from './source-mode-plugin';
import {
  disableSpellcheck as disableSpellcheckImpl,
  enableSpellcheck as enableSpellcheckImpl,
  setSpellcheckResults as setSpellcheckResultsImpl,
  spellcheckPlugin,
  triggerSpellcheck as triggerSpellcheckImpl,
} from './spellcheck-plugin';
import { zoomNotesMarkerPlugin } from './zoom-notes-marker-plugin';
import './styles.css';
// Import types to ensure declare global is included in the bundle
import { syncLog } from './sync-debug';
import './types';

// Backtick with selected text wraps selection as inline code.
// Uses ProseMirror's handleKeyDown (not DOM events) because WKWebView's
// event timing lets ProseMirror's MutationObserver consume DOM changes
// before DOM-level handlers can intercept them.
const backtickWrapPlugin = $prose(() => {
  return new Plugin({
    key: new PluginKey('backtick-wrap'),
    props: {
      handleKeyDown(view, event) {
        if (event.key !== '`' || event.metaKey || event.ctrlKey || event.altKey) return false;
        if (isSourceModeEnabled()) return false;
        if (view.state.selection.empty) return false;

        toggleInlineCode();
        return true; // ProseMirror calls preventDefault(), suppressing all input paths
      },
    },
  });
});

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
      .use(zoomNotesMarkerPlugin) // Intercept <!-- ::zoom-notes:: --> before commonmark filters it
      .use(bibliographyPlugin) // Intercept <!-- ::auto-bibliography:: --> before commonmark filters it
      .use(annotationPlugin) // Intercept annotation comments before filtering
      .use(citationPlugin) // Parse [@citekey] citations before commonmark
      .use(footnotePlugin) // Parse [^N] footnote references before commonmark
      .use(imagePlugin) // Parse ![alt](media/...) into figure nodes before commonmark
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
      .use(backtickWrapPlugin) // Backtick wraps selection as inline code (ProseMirror-level)
      // citationNodeView is now included in citationPlugin (same file = correct atom identity)
      .use(searchPlugin) // Search highlighting decorations
      .use(spellcheckPlugin) // Spellcheck/grammar decorations via NSSpellChecker
      .use(linkTooltipPlugin) // Custom link preview/edit tooltips (no Vue dependency)
      .use(selectionToolbarPlugin) // Selection toolbar (floating format bar)
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

  // Track content changes with debounced push to Swift
  const editorInstance = getEditorInstance()!;
  const view = editorInstance.ctx.get(editorViewCtx);
  const originalDispatch = view.dispatch.bind(view);
  // Section change tracking state (debounced push to Swift)
  let sectionChangeTimer: ReturnType<typeof setTimeout> | null = null;
  let lastTrackedTitle: string | null = null;
  let lastTrackedBlockId: string | null = null;

  view.dispatch = (tr) => {
    originalDispatch(tr);

    if (getIsSettingContent()) return;

    if (tr.docChanged) {
      clearContentPushTimer();
      setContentPushTimer(
        setTimeout(() => {
          // Re-check guard: setContent() may have run during the 50ms window
          if (getIsSettingContent()) {
            return;
          }
          // Block push before Swift has called setContent/setContentWithBlockIds —
          // prevents stale initialization content from overwriting real content
          if (!getContentHasBeenSet()) {
            return;
          }
          const md = editorInstance.action(getMarkdown());
          setCurrentContent(md);
          const firstHeading = md.match(/^#{1,6}\s+.*/m)?.[0]?.slice(0, 60) || '(none)';
          syncLog('ContentPush', `PUSHED: len=${md.length}, firstH="${firstHeading}"`);
          (window as any).webkit?.messageHandlers?.contentChanged?.postMessage(md);
        }, 50)
      );
    }

    // Check for section change on ANY transaction (cursor move or content change)
    if (sectionChangeTimer) clearTimeout(sectionChangeTimer);
    sectionChangeTimer = setTimeout(() => {
      if (getIsSettingContent()) return;
      const newTitle = window.FinalFinal.getCurrentSectionTitle();
      const newBlockId = window.FinalFinal.getCurrentSectionBlockId();
      if (newTitle !== lastTrackedTitle || newBlockId !== lastTrackedBlockId) {
        lastTrackedTitle = newTitle;
        lastTrackedBlockId = newBlockId;
        (window as any).webkit?.messageHandlers?.sectionChanged?.postMessage({
          title: newTitle || '',
          blockId: newBlockId,
        });
      }
    }, 150);
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

  // NOTE: Cmd+Shift+N footnote insertion is handled by the macOS menu command
  // (EditorCommands.swift), which calls evaluateJavaScript("insertFootnote()").
  // The JS postMessage in footnote-plugin.ts then notifies Swift of the label.
  // No JS keydown handler needed — it would double-fire with the native menu.

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
  getCurrentSectionTitle,
  getCurrentSectionBlockId,
  scrollToOffset,
  setTheme,
  getCursorPosition,
  setCursorPosition,
  scrollCursorToCenter,
  scrollToFraction,
  scrollToLine,
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
  // Image API
  insertImage,
  // Surgical heading update API
  updateHeadingLevels,
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
  triggerSpellcheck: triggerSpellcheckImpl,
  // Footnote API
  setFootnoteDefinitions,
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

  // Find/replace API
  find: findApi,
  findNext: findNextApi,
  findPrevious: findPreviousApi,
  replaceCurrent: replaceCurrentApi,
  replaceAll: replaceAllApi,
  clearSearch: clearSearchApi,
  getSearchState: getSearchStateApi,

  // Combined poll data for batched 3s fallback polling
  getPollData() {
    return JSON.stringify({
      stats: window.FinalFinal.getStats(),
      sectionTitle: window.FinalFinal.getCurrentSectionTitle(),
      sectionBlockId: window.FinalFinal.getCurrentSectionBlockId(),
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
      editorReady: getEditorInstance() !== null,
      focusModeEnabled: isFocusModeEnabled(),
    };
  },
};

// Initialize editor
initEditor().catch((e) => {
  console.error('[Milkdown] Init failed:', e);
});
