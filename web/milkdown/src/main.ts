/// <reference types="../global" />
// Milkdown WYSIWYG Editor for final final
// Uses window.FinalFinal API for Swift ↔ JS communication

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { clipboard } from '@milkdown/kit/plugin/clipboard';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm, remarkGFMPlugin } from '@milkdown/kit/preset/gfm';
import { isHistoryTransaction } from '@milkdown/kit/prose/history';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { $prose, getMarkdown } from '@milkdown/kit/utils';
import { annotationDisplayPlugin } from './annotation-display-plugin';
import { annotationPlugin } from './annotation-plugin';
import {
  addCitationItems,
  citationPickerCallback,
  citationPickerCancelled,
  citationPickerError,
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
  flushPendingBlockChanges,
  getBlockAtCursor,
  getBlockChangesApi,
  getContent,
  hasBlockChanges,
  insertImage,
  replayPendingPreMountContent,
  resetEditorState,
  resetForProjectSwitch,
  scrollToBlock,
  setContent,
  setContentWithBlockIds,
  signalMountPaintComplete,
  signalPaintComplete,
  signalPaintCompleteDirect,
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
  compareTableASTs,
  findApi,
  findNextApi,
  findPreviousApi,
  focus,
  formatTable,
  getCurrentSectionBlockId,
  getCurrentSectionTitle,
  getCursorPosition,
  getEditorMode,
  getSearchStateApi,
  getStats,
  initialize,
  insertAtCursor,
  insertBreak,
  insertTable,
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
import { bibliographyEndMarkerPlugin } from './bibliography-end-marker-plugin';
import { bibliographyPlugin } from './bibliography-plugin';
import { blockIdPlugin, getAllBlockIds } from './block-id-plugin';
import { blockSyncPlugin } from './block-sync-plugin';
import { caywRemapPlugin, insertCitationAtCursor } from './cayw';
import { citationPlugin } from './citation-plugin';
import { restoreCitationLibrary } from './citation-search';
import { dropCursorPlugin } from './drop-cursor-plugin';
import {
  clearContentPushTimer,
  getContentHasBeenSet,
  getEditorInstance,
  getIsSettingContent,
  getPendingBlockContent,
  isEditorMounted,
  setContentPushTimer,
  setCurrentContent,
  setEditorInstance,
  setEditorMounted,
  setPendingBlockContent,
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
import { hoverTooltipPlugin } from './hover-tooltip';
import { imageNodeRewritePlugin } from './image-node-rewrite-plugin';
import { imagePlugin } from './image-plugin';
import { inlineCodeCursorPlugin } from './inline-code-cursor';
import { linkCursorPlugin } from './link-cursor';
import { markdownLinkPlugin } from './markdown-link-input-rule';
import {
  beginStructuralOp,
  cancelPendingInsertions,
  clearFailedStructuralOpEntry,
  clearStructuralUndoRegistry,
  clearStructuralUndoState,
  closeEditingPopupsAndClearBoundaryState,
  finalizeStructuralOpPostOpDoc,
  finishStructuralSwapSettle,
  maybeAdvanceRegistryOnSyncOriginTx,
  maybeNotifyHistoryEdited,
  noteUserTransaction,
  performStructuralSwap,
  receiveRedoOutcome,
  receiveUndoOutcome,
  requestUnifiedRedo,
  requestUnifiedUndo,
  setUndoDescriptor,
} from './undo-coordinator';
import './link-click-handler';
import { insertEquation, insertEquationDialog } from './api-math';
import { linkTooltipPlugin, openLinkEdit } from './link-tooltip';
import { mathPlugin } from './math-plugin';
import { orderedListOrderPlugin } from './ordered-list-order-plugin';
import { noteTransactionForEditSpanTracking } from './recent-edit-span';
import { searchPlugin } from './search-plugin';
import { sectionBreakPlugin } from './section-break-plugin';
import { selectionStatsPlugin } from './selection-stats-plugin';
import { selectionToolbarPlugin } from './selection-toolbar-plugin';
import { configureSlash, slash } from './slash-commands';
import {
  disableSmartQuotes as disableSmartQuotesImpl,
  enableSmartQuotes as enableSmartQuotesImpl,
  isNativeQuoteSubstitution,
  isSmartQuotesEnabled,
  plainEquivalentOf,
  runSmartQuoteInputRules,
  smartQuotesPlugin,
} from './smart-quotes-plugin';
import { isSourceModeEnabled, sourceModePlugin } from './source-mode-plugin';
import {
  disableSpellcheck as disableSpellcheckImpl,
  enableSpellcheck as enableSpellcheckImpl,
  isSpellcheckEnabled,
  setSpellcheckResults as setSpellcheckResultsImpl,
  spellcheckPlugin,
  triggerSpellcheck as triggerSpellcheckImpl,
} from './spellcheck-plugin';
import { tablePastePlugin } from './table-paste-plugin';
import { tableToolsPlugin } from './table-tools-plugin';
import { zoomNotesMarkerPlugin } from './zoom-notes-marker-plugin';
import './styles.css';
import 'katex/dist/katex.min.css';
import 'prosemirror-tables/style/tables.css';
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

  // [SYNC-DIAG Phase 0] One-time log of plugin registration order. If blockSyncPlugin
  // ever runs BEFORE blockIdPlugin, snapshotBlocks() reads a stale currentBlockIds
  // and emits phantom deletes — this log makes the order visible in Xcode console.
  syncLog('Bootstrap:pluginOrder', 'blockIdPlugin → blockSyncPlugin (expected)');

  try {
    const editorInstance = await Editor.make()
      .config((ctx) => {
        ctx.set(defaultValueCtx, '');
        // Round 5 (doc-open-blank-regression, 2026-08-29): rootCtx defaults to
        // document.body (@milkdown/core's editorView plugin: `ctx.inject(rootCtx,
        // document.body)`) unless explicitly set. This app never set it, and instead
        // manually reparented the freshly-created view's dom into #editor once, right
        // after create() (see the old `root.appendChild(...)` this replaces) -- which
        // only fixed the INITIAL placement. Milkdown's own built-in MILKDOWN_VIEW_CLEAR
        // plugin (an internal ProseMirror plugin every Milkdown editor carries) rebuilds
        // a fresh `.milkdown` wrapper under `ctx.get(rootCtx) || document.body` and
        // moves the view's dom into it EVERY TIME ProseMirror recreates plugin views --
        // which `clearEditorHistory()`'s `view.updateState()` (added to clear undo
        // history on project switch) does on every switch. Since rootCtx still pointed
        // at document.body, each such switch silently relocated the live editor dom
        // from #editor to a new, empty-looking wrapper at the top of <body> -- #editor
        // was left empty (blank pane) while the real content, still correct but no
        // longer inside #editor, lost that element's centering/padding CSS (wrong
        // margins) once anything (e.g. a user click causing a reflow) made it visible.
        // Confirmed live via a body-skeleton DOM dump comparing the working vs. failing
        // switch. Setting rootCtx here means every such internal re-mount targets
        // #editor correctly, so the manual one-time reparent below is no longer needed.
        ctx.set(rootCtx, root);
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
      .use(blockSyncPlugin) // Track block changes for Swift sync — MUST run AFTER blockIdPlugin so currentBlockIds is fresh before snapshotBlocks() reads it
      .use(sectionBreakPlugin) // Intercept <!-- ::break:: --> before commonmark filters it
      .use(zoomNotesMarkerPlugin) // Intercept <!-- ::zoom-notes:: --> before commonmark filters it
      .use(bibliographyPlugin) // Intercept <!-- ::auto-bibliography:: --> before commonmark filters it
      .use(bibliographyEndMarkerPlugin) // Intercept <!-- ::auto-bibliography-end:: --> + Enter-key
      // placement fix — MUST be before commonmark so its Enter keymap binding takes
      // precedence over commonmark's own Enter→splitBlock (same technique as
      // citationDeleteKeymap below, for Backspace/Delete)
      .use(annotationPlugin) // Intercept annotation comments before filtering
      // Parse [@citekey] citations before commonmark. This ordering also gives
      // citationDeleteKeymap (citation-plugin.ts) precedence over ProseMirror's/
      // commonmark's default Backspace/Delete handling for one-press citation
      // deletion — if this ordering ever changes, that behavior could silently
      // regress (a test failure in citation-delete.test.ts/CitationDeleteTests.swift,
      // not a compile error).
      .use(citationPlugin)
      .use(caywRemapPlugin) // Remaps pending CAYW /cite request ranges across intervening edits during the async Zotero round-trip
      .use(mathPlugin) // Parse $...$ and $$...$$ math before commonmark
      .use(footnotePlugin) // Parse [^N] footnote references before commonmark
      .use(imagePlugin) // Parse ![alt](media/...) into figure nodes before commonmark
      .use(commonmark)
      .use(gfm)
      .config((ctx) => {
        ctx.update(remarkGFMPlugin.options.key, () => ({ tablePipeAlign: false }));
      })
      .use(orderedListOrderPlugin) // Replaces built-in ordered_list schema to fix start/order rendering — AFTER commonmark so orderedListAttr ctx slice exists
      .use(imageNodeRewritePlugin) // Replaces built-in image schema so a plain (non-figure) inline image gets the media/... rewrite too — AFTER commonmark so it wins over commonmark's own image registration
      .use(autolinkPlugin) // Auto-link bare URLs on space - AFTER commonmark for link schema
      .use(markdownLinkPlugin) // Convert [text](url) to link mark on ) keypress - AFTER commonmark for link schema
      .use(smartQuotesPlugin) // Context-aware curly quote conversion (balanced open/close)
      .use(highlightPlugin) // ==highlight== syntax - AFTER commonmark for serialization
      .use(history)
      .use(tablePastePlugin) // Intercept TSV/HTML table paste before clipboard plugin
      .use(clipboard) // Parse pasted markdown as rich text instead of literal text
      .use(focusModePlugin)
      .use(sourceModePlugin) // Dual-appearance source mode
      .use(annotationDisplayPlugin) // Controls annotation visibility
      .use(headingNodeViewPlugin) // Custom heading rendering for source mode # selection
      .use(backtickWrapPlugin) // Backtick wraps selection as inline code (ProseMirror-level)
      .use(inlineCodeCursorPlugin) // Two-stop cursor at inline-code edges: escape by default, arrow keys step in/out
      .use(linkCursorPlugin) // Self-healing boundary fix: clears a fresh/stray link mark at the cursor so typing after a link stays plain
      // citationNodeView is now included in citationPlugin (same file = correct atom identity)
      .use(searchPlugin) // Search highlighting decorations
      .use(spellcheckPlugin) // Spellcheck/grammar decorations via NSSpellChecker
      .use(linkTooltipPlugin) // Custom link preview/edit tooltips (no Vue dependency)
      .use(hoverTooltipPlugin) // Shared hover tooltip for collapsed annotations + footnote refs
      .use(selectionToolbarPlugin) // Selection toolbar (floating format bar)
      .use(selectionStatsPlugin) // Push selected text to Swift for status-bar selection word count
      .use(tableToolsPlugin) // Floating table toolbar (add/delete row & column, alignment)
      .use(dropCursorPlugin) // Visible caret/line indicator tracking the mouse during drag-and-drop
      .use(slash)
      .create();

    setEditorInstance(editorInstance);

    // rootCtx is now set to `root` above, so Milkdown mounts (and re-mounts, on every
    // internal plugin-view recreation) directly inside #editor -- no manual reparent needed.

    // Restore citation library from localStorage (survives editor toggle)
    restoreCitationLibrary();
  } catch (e) {
    console.error('[Milkdown] Init failed:', e);
    // M9: a failure here (e.g. inside Editor.make().create()) previously left any pre-mount
    // pending content silently un-replayed AND un-cleared -- Swift's mount-readiness poll
    // (notifyWebViewReadyWhenEditorReady) just times out at 3s onto a permanently editor-less
    // page, with no signal that content was lost. Clear the stash and log so this is at least
    // diagnosable instead of silently vanishing.
    const pending = getPendingBlockContent();
    if (pending) {
      setPendingBlockContent(null);
      syncLog(
        'Bootstrap:initFailed',
        `content lost: pending block content (len=${pending.markdown.length}, blocks=${pending.blockIds.length}) discarded after Editor.make().create() failure`
      );
    }
    // Mount-flash fix: a failed Editor.make().create() must not leave Swift's `.mount` cloak
    // (beginCloak, armed before this WebView started loading) permanently hiding the WebView
    // -- there is no `view.dom` to force-repaint here (the editor never mounted), so post
    // directly rather than via signalPaintComplete's double-RAF wrapper (same shape
    // resetForProjectSwitch()'s own failure paths use, api-content.ts). Swift's per-token
    // fallback timer is the real backstop if even this direct post is somehow lost.
    signalPaintCompleteDirect({ reason: 'mount' });
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

  // P3 (4c, undo-mode-switch-focus second timing gap): sticky-OR across the 50ms
  // aggregating debounce window below -- true if ANY transaction folded into the next
  // debounced push was an undo replay, so Swift can skip re-correcting a heading the user
  // just undid instead of racing straight back over it (SectionSyncService's suppression,
  // §4d). Cleared on every path out of the debounce timer callback (early-return or real
  // post) so a stale `true` can never ride into a later, unrelated push.
  let pendingWasUndo = false;

  view.dispatch = (tr) => {
    originalDispatch(tr);

    // Unified-undo §4.2/§4.6 predicates -- deliberately run on EVERY transaction (each one's
    // own cheap first check short-circuits whenever there's nothing in the registry/descriptor
    // to act on -- see undo-coordinator.ts). The two are mutually exclusive by construction
    // (one requires addToHistory !== false, the other requires === false), so call order
    // between them doesn't matter.
    //
    // DEFERRED (Phase 3, do not fix now): maybeNotifyHistoryEdited sits ABOVE the
    // getIsSettingContent() early return below. Harmless today (descriptor.redoTopOpId never
    // exists, so maybeNotifyHistoryEdited always no-ops at its own first check regardless of
    // ordering), but once Phase 3 populates descriptor.redoTopOpId, a programmatic
    // content-set transaction that doesn't carry addToHistory:false would still fire
    // historyEdited here and wrongly invalidate the redo entry -- setContent()/
    // setContentWithBlockIds() should be audited to confirm every such transaction sets that
    // meta, or this check should move below the getIsSettingContent() guard.
    maybeNotifyHistoryEdited(tr);
    // §4.6 advancement rule: absorbs sync-origin transactions (addToHistory:false) that land
    // after a structural op's postOpDoc/preOpDoc was captured -- see undo-coordinator.ts.
    maybeAdvanceRegistryOnSyncOriginTx(tr);
    // Real user-transaction counter for undo-coordinator.ts's permanent `[UnifiedUndo]`
    // fallthrough log (undo-mode-switch-focus investigation legacy).
    noteUserTransaction(tr);
    // P3 WYSIWYG (4a mirror, undo-mode-switch-focus second timing gap): tracks the span
    // the user last actually typed in, so updateHeadingLevels (api-content.ts) can tell
    // whether an incoming derived correction overlaps it.
    noteTransactionForEditSpanTracking(tr);

    if (getIsSettingContent()) return;

    if (tr.docChanged) {
      // P3 (4c): fold this transaction's undo-ness into the sticky flag BEFORE
      // scheduling/re-scheduling the debounce timer below.
      if (isHistoryTransaction(tr)) pendingWasUndo = true;
      clearContentPushTimer();
      setContentPushTimer(
        setTimeout(() => {
          // Re-check guard: setContent() may have run during the 50ms window
          if (getIsSettingContent()) {
            pendingWasUndo = false;
            return;
          }
          // Block push before Swift has called setContent/setContentWithBlockIds —
          // prevents stale initialization content from overwriting real content
          if (!getContentHasBeenSet()) {
            pendingWasUndo = false;
            return;
          }
          const wasUndo = pendingWasUndo;
          pendingWasUndo = false;
          const md = editorInstance.action(getMarkdown());
          setCurrentContent(md);
          const firstHeading = md.match(/^#{1,6}\s+.*/m)?.[0]?.slice(0, 60) || '(none)';
          syncLog('ContentPush', `PUSHED: len=${md.length}, firstH="${firstHeading}"`);
          (window as any).webkit?.messageHandlers?.contentChanged?.postMessage({ content: md, wasUndo });
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

  // M8: the mount flag flips -- and therefore any pre-mount content replay it gates on the
  // Swift side (notifyWebViewReadyWhenEditorReady) -- only AFTER view.dispatch above has been
  // patched, so the replay's own transactions go through the SAME content-push-debounce and
  // section-change tracking hooks as every other transaction, instead of silently bypassing
  // them (previously this ran immediately after root.appendChild, well before the patch just
  // above existed).
  setEditorMounted(true);
  replayPendingPreMountContent();

  // Mount-flash fix (doc-open-blank-regression follow-up): now that rootCtx correctly
  // targets #editor (see the ctx.set(rootCtx, root) comment above), Milkdown's internal
  // container-swap teardown/rebuild during EditorView construction is visible against the
  // real editor pane, not document.body. Swift's `beginCloak(.mount)`
  // (MilkdownCoordinator+MessageHandlers.swift), armed before this WebView started loading
  // (MilkdownEditor.swift's makeNSView fresh-view branch), stays in effect until this signal
  // arrives -- forcing a real repaint first so the un-hide doesn't just reveal ANOTHER stale
  // frame. No token threaded through here (unlike resetForProjectSwitch()): a fresh WKWebView
  // only ever runs initEditor() once per Coordinator instance, so at most one `.mount` cloak
  // can ever be outstanding on a given Coordinator -- reason-based resolution is unambiguous.
  signalPaintComplete(view.dom, { reason: 'mount' });

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

      if (isNativeQuoteSubstitution(replacement)) {
        // WebKit's own quote-curling attempt (see smart-quotes-fix plan). Our own
        // smartQuotesPlugin already owns quote-curling; WebKit's attempt is discarded
        // unconditionally here — whether the toggle is on (its own InputRule already
        // produced the correct result via the ordinary typing path, so WebKit's
        // replacement is redundant/stale) or off (WebKit's attempt must simply be
        // thrown away for "off" to mean anything, since there's no public WKWebView
        // API to disable the native substitution at the source).
        //
        // The exact event sequence this relies on — an ordinary `insertText` landing
        // first via the normal InputRule pipeline, then this async
        // `insertReplacementText` — could not be empirically confirmed (this
        // environment's build/test host had its screen locked, so no real OS-level
        // keystroke synthesis into a running build was possible; see the smart-quotes-fix
        // plan's Step 0a). Handling both possible sequences defensively rather than
        // assuming one:
        const quoteRanges = e.getTargetRanges();
        let startPos: number;
        let endPos: number;
        if (quoteRanges.length > 0) {
          const range = quoteRanges[0];
          startPos = view.posAtDOM(range.startContainer, range.startOffset);
          endPos = view.posAtDOM(range.endContainer, range.endOffset);
        } else {
          ({ from: startPos, to: endPos } = view.state.selection);
        }

        if (startPos !== endPos) {
          // Non-collapsed range: a character already occupies this range, meaning an
          // ordinary insertText already landed here via the normal path (two-event
          // model) — either smartQuotesPlugin already curled it (toggle on) or it's
          // still the plain character (toggle off). Either way this native replacement
          // is redundant/stale — discard it outright, changing nothing.
          return;
        }

        // Collapsed range: nothing was inserted here by an ordinary path first —
        // evidence of a single-event model for this keystroke. A discard-only
        // interceptor would leave the keystroke dead (no character inserted at all), so
        // drive the insertion ourselves: run it through the same InputRule resolution
        // real typing would use (toggle on, so curling can still happen from context),
        // or insert it plainly (toggle off).
        //
        // Processed one character at a time — exactly as real keystrokes would arrive
        // — rather than as a single dispatcher call over the whole plain string. Each
        // smartQuotes InputRule only ever matches a single trailing character, so if
        // `replacement` is multi-character (isNativeQuoteSubstitution permits this),
        // one call with the whole string would always fail the length check inside
        // runSmartQuoteInputRules and silently fall back to inserting it straight —
        // even with the toggle on. Looping re-derives the current cursor position from
        // view.state after each dispatch, so each character sees the real, up-to-date
        // document (including whatever curly quote the previous character produced).
        const plain = plainEquivalentOf(replacement);
        const smartQuotesEnabled = isSmartQuotesEnabled();
        let pos = startPos;
        for (const ch of plain) {
          const inputRuleTr = smartQuotesEnabled ? runSmartQuoteInputRules(view.state, pos, pos, ch) : null;
          view.dispatch(inputRuleTr ?? view.state.tr.insertText(ch, pos, pos));
          pos = view.state.selection.to;
        }
        return;
      }

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

  // NOTE: Cmd+Shift+K citation insertion is handled by the macOS menu command
  // (EditorCommands.swift), which posts .insertCitation — observed by both editors
  // (MilkdownCoordinator+NotificationObservers.swift, CodeMirrorEditor.swift).
  // No JS keydown handler needed here — it would double-fire with the native menu.

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
  // True only once the editor instance exists AND its DOM is parented into #editor -- see
  // editor-state.ts's isEditorMounted doc comment. Polled by
  // MilkdownCoordinator+MessageHandlers.swift's notifyWebViewReadyWhenEditorReady before
  // firing onWebViewReady, closing the race where a page-load-complete callback fired well
  // before this async mount actually finished (t-18576cf7).
  isEditorReady: () => isEditorMounted(),
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
  getCAYWDebugState,
  insertCitation: insertCitationAtCursor,
  // Block-based API (Phase B)
  getBlockChanges: getBlockChangesApi,
  applyBlocks,
  confirmBlockIds: confirmBlockIdsApi,
  syncBlockIds,
  setContentWithBlockIds,
  scrollToBlock,
  getBlockAtCursor,
  hasBlockChanges,
  flushPendingBlockChanges,
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
  // Mount-flash fix (redesign after review round): on-demand release signal for the
  // claimed-preloaded-WebView path -- see signalMountPaintComplete's doc comment
  // (api-content.ts) and pollMountCloakReleaseForClaimedView's (Swift-side caller,
  // MilkdownCoordinator+MessageHandlers.swift).
  signalMountPaintComplete,
  // Spellcheck API
  setSpellcheckResults: setSpellcheckResultsImpl,
  enableSpellcheck: enableSpellcheckImpl,
  disableSpellcheck: disableSpellcheckImpl,
  triggerSpellcheck: triggerSpellcheckImpl,
  isSpellcheckEnabled,
  // Smart quotes API
  enableSmartQuotes: enableSmartQuotesImpl,
  disableSmartQuotes: disableSmartQuotesImpl,
  isSmartQuotesEnabled,
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

  // Table API
  insertTable,
  formatTable,
  compareTableASTs,

  // Math equation API
  insertEquation,
  insertEquationDialog,

  // Find/replace API
  find: findApi,
  findNext: findNextApi,
  findPrevious: findPreviousApi,
  replaceCurrent: replaceCurrentApi,
  replaceAll: replaceAllApi,
  clearSearch: clearSearchApi,
  getSearchState: getSearchStateApi,

  // Unified-undo API (docs/architecture/unified-undo.md). requestUnifiedUndo/Redo are the
  // menu-path entry points (Edit > Undo/Redo), routing through the same document-equality
  // decision as the keyboard interceptor; when the native timeline has nothing on top, both
  // fall through to Milkdown's own text undo/redo. setUndoDescriptor is pushed by
  // StructuralUndoController.pushDescriptor() after every recorded op, undo, and redo -- NOT
  // after a barrier, which instead resets JS-local descriptor state via
  // clearStructuralUndoRegistry() below. receiveUndoOutcome/receiveRedoOutcome are Swift's
  // one-shot reply to a JS-initiated structuralUndoRequested/structuralRedoRequested.
  requestUnifiedUndo,
  requestUnifiedRedo,
  setUndoDescriptor,
  receiveUndoOutcome,
  receiveRedoOutcome,
  // Structural op lifecycle (Phase 3) -- called by StructuralUndoController.swift at the
  // audited op-sequence/undo-sequence boundaries (plan §4.4).
  beginStructuralOp,
  finalizeStructuralOpPostOpDoc,
  performStructuralSwap,
  finishStructuralSwapSettle,
  cancelPendingInsertions,
  // N4 (Phase B remediation plan): force-closes editing popups, clears find/replace state.
  closeEditingPopupsAndClearBoundaryState,
  // N6 (Phase B remediation plan): removes just the ONE mid-sequence op's own
  // not-yet-finalized registry entry after a forward-op failure -- see undo-coordinator.ts's
  // doc comment for why this must NOT clear editor text-undo history the way
  // clearStructuralUndoState (eviction) does.
  clearFailedStructuralOpEntry,
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

  // Test-only hook — read-only, introspects the block-id plugin's current
  // position→id assignments via its existing getAllBlockIds() export. No
  // behavior change. Not for production use; no production code should
  // depend on this. Sorted by offset so callers get document order without
  // relying on Map iteration/insertion order.
  __testGetBlockIds() {
    return Array.from(getAllBlockIds().entries())
      .sort((a, b) => a[0] - b[0])
      .map(([offset, id]) => ({ offset, id }));
  },
};

// Initialize editor
initEditor().catch((e) => {
  console.error('[Milkdown] Init failed:', e);
});
