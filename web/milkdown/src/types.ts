// Type definitions and interfaces for the Milkdown editor

import type { DeleteSectionResult } from './api-section-delete';
import type { DuplicatedBlock, DuplicateSectionResult } from './api-section-duplicate';
import type { ReorderOrderEntry, ReorderSectionsResult } from './api-section-reorder';
import type { QuickResumeResult, QuickUndoResult } from './api-section-undo';
import type { ReplaceRangePayload, ReplaceRangeResult } from './api-structural-replace';
import type { StructuralSwapPayload, StructuralSwapResult } from './api-structural-swap';
import type {
  SwapTransitionOptions,
  SwapTransitionResult,
  TransitionBeginResult,
  TransitionTakeResult,
} from './api-transition';
import type { BlockChanges } from './block-sync-plugin';
import type { CSLItem } from './citation-plugin';
import type { PrefillBeginResult, PrefillStepResult } from './citation-prefill';
import type { CitationMemoStats } from './citeproc-engine';

// Find/replace options and result types
export interface FindOptions {
  caseSensitive?: boolean;
  wholeWord?: boolean;
  regexp?: boolean;
}

export interface FindResult {
  matchCount: number;
  currentIndex: number;
}

export interface SearchState {
  query: string;
  matchCount: number;
  currentIndex: number;
  options: FindOptions;
}

// Block type for applyBlocks API
export interface Block {
  id: string;
  blockType: string;
  textContent: string;
  markdownFragment: string;
  headingLevel?: number;
  sortOrder: number;
  imageCaption?: string;
  imageWidth?: number;
}

// Image metadata for setContentWithBlockIds (persists width/caption across reloads)
export interface ImageBlockMeta {
  id: string;
  width?: number | null;
  caption?: string | null;
  alt?: string | null;
}

/** Per-id ground-truth metadata for setBlockIdsForTopLevel's optional alignment check.
 * blockType: Swift BlockType.rawValue (e.g. "paragraph", "image").
 * nonEmpty: whether the DB's ground-truth text for this block is non-blank, where
 * blankness is defined identically on both sides as `text.trim() === ''` — keep this
 * definition in lockstep with BlockParser.alignmentPairs on the Swift side. */
export interface ExpectedBlockMeta {
  blockType: string;
  nonEmpty: boolean;
}

// Search match position
export interface SearchMatch {
  from: number;
  to: number;
}

// Interface for CAYW callback data from Swift
export interface CAYWCallbackData {
  rawSyntax: string;
  citekeys: string[];
  locators: string;
  prefix: string;
  suppressAuthor: boolean;
  /** Opaque round-trip token identifying which pending /cite request this
   * callback resolves — NOT a document position. The original command
   * position can go stale during the async Zotero round-trip, so cayw.ts
   * tracks it separately (and remaps it across edits); this id is only used
   * to look up that tracked entry. */
  requestId: number;
}

declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string, options?: { scrollToStart?: boolean; cloakToken?: number }) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
      /** Typewriter scrolling. Swift sends `focusMode && typewriterScrollingEnabled`;
       *  `lineOffset` is whole lines, clamped to [-10, 10] on both sides. */
      setTypewriterConfig: (config: { enabled: boolean; lineOffset: number }) => void;
      getStats: () => { words: number; characters: number };
      getCurrentSectionTitle: () => string | null;
      getCurrentSectionBlockId: () => string | null;
      scrollToOffset: (offset: number) => void;
      setTheme: (cssVariables: string) => void;
      getCursorPosition: () => {
        line: number;
        column: number;
        scrollFraction: number;
        cursorIsVisible: boolean /** Floating-point markdown line at viewport top. 6.6 = 60% through line 6 */;
        topLine: number;
      };
      setCursorPosition: (pos: { line: number; column: number }) => void;
      scrollCursorToCenter: () => void;
      scrollToFraction: (fraction: number) => void;
      scrollToLine: (line: number) => void;
      insertAtCursor: (text: string) => void;
      insertBreak: () => void;
      focus: () => void;
      /** True only once the editor instance exists AND its DOM is parented into #editor.
       * Polled by Swift (MilkdownCoordinator+MessageHandlers.swift) before firing
       * onWebViewReady -- page-load-complete alone fires well before this async mount
       * actually finishes (t-18576cf7). */
      isEditorReady: () => boolean;
      // Batch initialization for faster startup
      initialize: (options: {
        content: string;
        theme: string;
        cursorPosition: { line: number; column: number } | null;
      }) => void;
      // Annotation API
      setAnnotationDisplayModes: (modes: Record<string, string>) => void;
      getAnnotations: () => Array<{ type: string; text: string; offset: number; completed?: boolean }>;
      scrollToAnnotation: (index: number) => void;
      insertAnnotation: (type: string) => void;
      /** Deletes the inline annotation at `index` (same ordering as getAnnotations()/
       * scrollToAnnotation()), verified against `expectedType`/`expectedText` before acting
       * (falls back to a unique type+text re-scan, refusing on a stale index with zero or
       * multiple matches -- see api-annotations.ts's doc comment). Undoable via the editor's
       * own text history. */
      deleteInlineAnnotation: (index: number, expectedType: string, expectedText: string) => boolean;
      setHideCompletedTasks: (enabled: boolean) => void;
      // Highlight API
      toggleHighlight: () => boolean;
      // Formatting API
      toggleBold: () => boolean;
      toggleItalic: () => boolean;
      toggleStrikethrough: () => boolean;
      setHeading: (level: number) => boolean;
      toggleBulletList: () => boolean;
      toggleNumberList: () => boolean;
      toggleBlockquote: () => boolean;
      toggleCodeBlock: () => boolean;
      toggleInlineCode: () => boolean;
      insertLink: () => boolean;
      // Citation API
      setCitationLibrary: (items: CSLItem[]) => void;
      setCitationStyle: (styleXML: string) => void;
      getBibliographyCitekeys: () => string[];
      getCitationCount: () => number;
      getAllCitekeys: () => string[];
      // Lazy resolution API
      requestCitationResolution: (keys: string[]) => void;
      addCitationItems: (items: CSLItem[]) => void;
      /** Ahead-of-time citation fill (citation-prefill.ts). Parses `markdown` with the page's own parser WITHOUT touching the editor
       * (no dispatch, no content-set flag, no key resolution request) and queues the document's distinct citation groups that the
       * citation memo does not hold yet. `status` is `notReady` before the editor exists and `parseFailed` if the parser threw; nothing
       * is queued then. A later call replaces the queue. */
      prefillCitationsBegin: (markdown: string) => PrefillBeginResult;
      /** Formats queued groups into the citation memo for about `budgetMs` (at least one per call) and reports progress. Safe to call
       * repeatedly, with nothing queued, and safe to stop calling at any point. */
      prefillCitationsStep: (budgetMs: number) => PrefillStepResult;
      /** Citation-memo switch for the UI-test comparison runs; production never calls it. Applies to the running engine and to one built later. */
      setCitationMemoEnabled: (on: boolean) => void;
      /** Citation-memo size and hit/miss counts (`misses` = calls that ran the citation processor). Never builds the engine. */
      getCitationMemoStats: () => CitationMemoStats;
      // CAYW picker callbacks
      citationPickerCallback: (data: CAYWCallbackData, items: CSLItem[]) => void;
      citationPickerCancelled: (requestId: number) => void;
      citationPickerError: (message: string, requestId: number) => void;
      // Debug API
      getCAYWDebugState: () => {
        pendingCAYWRequests: Array<{ requestId: number; start: number; end: number }>;
        hasEditor: boolean;
        docSize: number | null;
      };
      // Insert a brand-new citation at the current cursor (native toolbar "Cite" button)
      insertCitation: () => void;
      // Block-based API (Phase B)
      getBlockChanges: () => BlockChanges;
      // Phase 5 job B2: `getBlockChanges` plus the number of the `drain` report this drain posted (report-outbox.ts).
      getBlockChangesReported: () => BlockChanges & { reportThrough?: number; reportSession?: string };
      applyBlocks: (blocks: Block[]) => void;
      confirmBlockIds: (mapping: Record<string, string>) => void;
      syncBlockIds: (orderedIds: string[], zoomMode: boolean, expected?: ExpectedBlockMeta[]) => void;
      setContentWithBlockIds: (
        markdown: string,
        blockIds: string[],
        options?: {
          scrollToStart?: boolean;
          imageMeta?: ImageBlockMeta[];
          cursorBoundary?: number;
          // Node index one PAST the last bibliography block — companion end bound for
          // cursorBoundary so the cursor-clamp below only fires for a position actually INSIDE
          // the bibliography section (start <= pos < end), not merely at-or-after its start.
          // Needed because a regenerated bibliography can now be reinserted back at a
          // mid-document anchor instead of always landing at the document's end, so real
          // trailing user content can legitimately follow it.
          cursorBoundaryEnd?: number;
          detectPausedEdits?: boolean;
          expected?: ExpectedBlockMeta[];
          // Ids Swift flagged isBibliography/isNotes for this push (Block.swift) -- the
          // auto-generated Bibliography/Notes headings and their body content. Drives
          // block-id-plugin's `data-managed` decoration attribute, which styles.css's
          // ⌘-hover heading-zoom hint excludes via `h1[data-block-id]:not([data-managed])`
          // (etc. for h2-h6) -- see api-content.ts's setContentWithBlockIds.
          managedBlockIds?: string[];
          // Whether the pushed content represents a zoomed subset of the document
          // rather than the full document. Sets blockIdZoomMode SYNCHRONOUSLY,
          // in the same call that pushes the content — closing the race window
          // where a caller previously had to wait for a separate, awaited
          // syncBlockIds()/pushBlockIds() round-trip to flip the flag back on
          // after this function unconditionally cleared it. Defaults to false,
          // matching every pre-existing (non-zoom) call site untouched by this.
          zoomMode?: boolean;
          // Zoom-out: land on this block, in the restored document's own coordinate space,
          // instead of re-applying the zoomed view's captured scroll position (a
          // coordinate-space mismatch that lands at the document's actual top). Ignored when
          // scrollToStart is true. See api-content.ts's setContentWithBlockIds.
          scrollToBlockId?: string;
          // Slice 0 measurement only (typing-trace.ts): which rebuild this push is ('notes' | 'bibliography' |
          // 'footnote'). Swift sends it only while tracing is on; it changes nothing about the push.
          traceKind?: string;
        }
      ) => void;
      scrollToBlock: (blockId: string) => void;
      getBlockAtCursor: () => { blockId: string; offset: number } | null;
      hasBlockChanges: () => boolean;
      flushPendingBlockChanges: () => void;
      // Typing-latency trace switch (slice 0 measurement, typing-trace.ts). Swift turns it on at editor load when Diagnostics
      // logging is on. Default off: while off, the editor posts no `typingEcho` / `typingTrace` messages at all.
      setTraceTyping: (on: boolean) => void;
      // Dual-appearance mode API (Phase C)
      setEditorMode: (mode: 'wysiwyg' | 'source') => void;
      getEditorMode: () => 'wysiwyg' | 'source';
      // Cleanup API (for state reset before project switch)
      resetEditorState: () => void;
      resetForProjectSwitch: () => void;
      // Spellcheck API
      setSpellcheckResults: (
        requestId: number,
        results: Array<{
          from: number;
          to: number;
          word: string;
          type: string;
          suggestions: string[];
          message?: string | null;
          ruleId?: string | null;
          isPicky?: boolean;
        }>
      ) => void;
      enableSpellcheck: () => void;
      disableSpellcheck: () => void;
      triggerSpellcheck: () => void;
      /** Read-only: current spellcheck module-flag state (for regression tests
       *  verifying applyPersistedToggleStates re-applied a persisted preference
       *  to a fresh editor instance — see Swift-side ToggleStateRegressionTests). */
      isSpellcheckEnabled: () => boolean;
      // Smart quotes API
      enableSmartQuotes: () => void;
      disableSmartQuotes: () => void;
      /** Read-only: current smart-quotes module-flag state (same purpose as
       *  isSpellcheckEnabled above). */
      isSmartQuotesEnabled: () => boolean;
      // Footnote API
      setFootnoteDefinitions: (defs: Record<string, string>) => void;
      insertFootnote: (atPosition?: number) => string | null;
      renumberFootnotes: (mapping: Record<string, string>) => void;
      scrollToFootnoteDefinition: (label: string) => void;
      /** E1: id-addressed cursor placement — resolves `blockId` via the block-id map before
       *  falling back to `scrollToFootnoteDefinition`'s node/text-search chain. See
       *  footnote-plugin.ts's doc comment for the full fallback order and NOT_FOUND contract. */
      focusFootnoteDefinition: (label: string, blockId?: string) => void;
      setZoomFootnoteState: (zoomed: boolean, maxLabel: number) => void;
      // Image API
      insertImage: (opts: {
        src: string;
        alt: string;
        caption: string;
        width: number | null;
        blockId: string;
        origin?: string;
      }) => void;
      // Surgical heading update API
      updateHeadingLevels: (changes: Array<{ blockId: string; newLevel: number }>) => void;
      // Find/replace API
      find: (query: string, options?: FindOptions) => FindResult;
      findNext: () => FindResult | null;
      findPrevious: () => FindResult | null;
      replaceCurrent: (replacement: string) => boolean;
      replaceAll: (replacement: string) => number;
      clearSearch: () => void;
      getSearchState: () => SearchState | null;
      // Math equation API
      insertEquation: (latex: string, isDisplay: boolean) => void;
      insertEquationDialog: () => void;
      // Unified-undo API (docs/architecture/unified-undo.md). See undo-coordinator.ts for
      // the full routing design. setUndoDescriptor is pushed by
      // StructuralUndoController.pushDescriptor() after every recorded op, undo, and redo --
      // NOT after a barrier, which instead resets JS-local descriptor state via
      // clearStructuralUndoRegistry() below. receiveUndoOutcome/receiveRedoOutcome are Swift's
      // one-shot reply to a JS-initiated structuralUndoRequested/structuralRedoRequested.
      requestUnifiedUndo: () => void;
      requestUnifiedRedo: () => void;
      setUndoDescriptor: (descriptor: { undoTopOpId?: string; redoTopOpId?: string }) => void;
      receiveUndoOutcome: (opId: string, outcome: 'performed' | 'fallback' | 'failed' | 'cancelled') => void;
      receiveRedoOutcome: (opId: string, outcome: 'performed' | 'fallback' | 'failed' | 'cancelled') => void;
      // Slice 2a: number of Cmd-Z / Cmd-Shift-Z presses held behind an in-flight undo right now (0 when none). No side effects.
      heldUndoPressCount: () => number;
      // Phase 4c job 2: ends the hold on the typing done while a press waits (the lifecycle flush calls it once before its forced poll); true when a hold was released.
      releaseHeldTypingPushes: () => boolean;
      // F7: releases the hold AND returns the pending batch in one call, for a press Swift hands to the old whole-document body.
      releaseHeldTypingAndGetBatch: () => { released: boolean; batch: BlockChanges };
      // Phase 5 job A7 (api-transition.ts): the zoom transition. `beginTransition` drains the pending batch and starts holding and
      // recording in ONE turn (Swift reads it as JSON.stringify(...) and writes the batch through the queue before the barrier);
      // `swapTransition` replaces the document with the recorded typing put back on top in ONE turn and returns the typing in blocks
      // the target lacks as `outside` (an ordinary batch), or refuses with the held typing as `batch`; `endTransition` ends a hold
      // whose swap never came.
      beginTransition: () => TransitionBeginResult;
      swapTransition: (token: number, options: SwapTransitionOptions) => SwapTransitionResult;
      endTransition: (token: number | null) => { ended: boolean };
      // Phase 5 job A9 (api-transition.ts): the switch to Markdown drains the typing held since the begin without ending the hold.
      takeTransitionBatch: (token: number) => TransitionTakeResult;
      // Structural op lifecycle (Phase 3, plan §4.4) -- called by StructuralUndoController.swift.
      beginStructuralOp: (opId: string) => boolean;
      finalizeStructuralOpPostOpDoc: (opId: string) => boolean;
      performStructuralSwap: (opId: string, direction: 'undo' | 'redo') => boolean;
      // Phase 4b part 2, slice 2a (api-section-delete.ts): the editor removes the section first, in one synchronous turn, and
      // returns the pending-edit batch it consumed on every path. Swift reads it as JSON.stringify(...) like getBlockChanges.
      // `managedIds` is the database's list of Notes/Bibliography block ids at the click.
      deleteSectionEditorFirst: (opId: string, rootBlockId: string, managedIds: string[]) => DeleteSectionResult;
      // Phase 4b slice 3 (api-section-duplicate.ts): the editor inserts the section's copy first, in one synchronous turn, with a
      // fresh PERMANENT id per copied block, and returns the pending-edit batch it consumed on every path (Swift always applies
      // it). Refuses (`ok: false`, document untouched) for a managed root. `copies` lists every copied block (source id, new id)
      // in document order; `insertedSectionsSnapshot` the copied section leaders for the sidebar.
      duplicateSectionEditorFirst: (opId: string, rootBlockId: string, managedIds: string[]) => DuplicateSectionResult;
      // The quick redo of a quick-undone duplicate: a fresh duplicate of the CURRENT document under the same opId that reuses the
      // first click's `copies` ids; a re-check refusal reads `ok: false, reason: 'docChanged'`.
      redoSectionDuplicateEditorFirst: (
        opId: string,
        rootBlockId: string,
        managedIds: string[],
        copies?: DuplicatedBlock[]
      ) => DuplicateSectionResult;
      // Phase 4b, reorder job (api-section-reorder.ts, t-0b70d1e9): the editor moves the dragged section (or, for the Option drag, a
      // section with its sub-sections) first, in one synchronous turn, as ONE range move that keeps every block's id, the caret and
      // the scroll position, and returns the pending-edit batch it consumed on every path (Swift always applies it). `order` is every
      // section leader in FINAL order with a `level` on the headings whose level the plan changed. A refusal (`ok: false`, e.g.
      // 'planMismatch', 'rootNotFound') leaves the document untouched; `skippedIds` are ids in `order` the editor has no node for.
      reorderSectionsEditorFirst: (
        opId: string,
        rootId: string,
        managedIds: string[],
        order: ReorderOrderEntry[]
      ) => ReorderSectionsResult;
      // Phase 4b slice 2, round 2c (api-structural-replace.ts): the three Version History restores. The editor replaces the document
      // ('whole'), the target heading's flat section ('section') or inserts a fragment after an anchor ('insertAfter') first, in one
      // synchronous turn, giving the new top-level blocks the payload's ids, and returns the pending-edit batch it consumed on every
      // path (Swift always applies it). A refusal (`ok: false`, e.g. 'idAlignment') leaves the document untouched. The quick UNDO
      // is `undoSectionDeleteEditorFirst` below (the generic checkpoint swap).
      replaceRangeEditorFirst: (opId: string, payload: ReplaceRangePayload) => ReplaceRangeResult;
      // The quick redo of a quick-undone replace: a fresh replace of the CURRENT document under the same opId, from the first click's
      // payload (the same ids); a re-check refusal reads `ok: false, reason: 'docChanged'`.
      redoReplaceRangeEditorFirst: (opId: string, payload: ReplaceRangePayload) => ReplaceRangeResult;
      // Phase 4b slice 3, round 3b (api-structural-swap.ts): the SLOW snapshot undo/redo done in the editor first. One synchronous turn:
      // takes the pending-edit batch, re-checks that the live document still equals the saved copy (`ok: false`, `reason: 'docChanged'`
      // otherwise, nothing swapped), checks the payload's ids against the target document (`idAlignment`), swaps the entry's checkpoint
      // ('undo') or redo checkpoint ('redo') in exactly as `performStructuralSwap` does, gives the blocks the payload's ids and settles
      // block-sync. `noCheckpoint`: no entry / no checkpoint for that direction, nothing swapped. The batch comes back on every path
      // (Swift always applies it). The latch must be held for `opId` (the press that routed here set it); Swift replies with
      // `receiveUndoOutcome` / `receiveRedoOutcome` afterwards.
      structuralSwapEditorFirst: (
        opId: string,
        direction: 'undo' | 'redo',
        payload: StructuralSwapPayload
      ) => StructuralSwapResult;
      // Phase 4b part 2, slice 2b (api-section-undo.ts): the quick undo of that delete. One synchronous turn that re-checks the live
      // document against the saved post-op copy (refusing, touching nothing, when it differs), swaps the pre-op checkpoint back
      // in with its block ids, and leaves block-sync PAUSED; Swift calls `resumeSyncAfterQuickUndo` once the reinsert job holds its
      // ticket. The batch it returns is applied on every path. The latch must be held for `opId` (the press that routed here set it).
      undoSectionDeleteEditorFirst: (opId: string) => QuickUndoResult;
      // The quick redo: removes the section again from the CURRENT document under the same opId (a fresh editor-first delete) and
      // returns the same reply as `deleteSectionEditorFirst`; a re-check refusal reads `ok: false, reason: 'docChanged'`.
      redoSectionDeleteEditorFirst: (opId: string, rootBlockId: string, managedIds: string[]) => DeleteSectionResult;
      // Hands block-sync back after a quick undo and queues what was typed while it was paused; no-op when none is pending.
      resumeSyncAfterQuickUndo: () => QuickResumeResult;
      // True when the live document no longer equals the quick-undone entry's restored document (`preOpDoc`, by the shared routing check):
      // Swift then drops the redo branch. False when there is no editor or entry to compare with. Read-only.
      quickUndoLiveDiffersFromRestored: (opId: string) => boolean;
      finishStructuralSwapSettle: () => boolean;
      cancelPendingInsertions: () => void;
      // N4 (Phase B remediation plan): force-closes editing popups, clears find/replace state.
      closeEditingPopupsAndClearBoundaryState: () => void;
      // N6 (Phase B remediation plan): removes just the ONE mid-sequence op's own
      // not-yet-finalized registry entry after a forward-op failure -- does NOT clear
      // editor text-undo history (unlike clearStructuralUndoState/eviction, below).
      clearFailedStructuralOpEntry: (opId: string) => void;
      // Barrier/eviction JS-side clears (Phase 5, plan §4.1/§4.5/§5 backlog).
      clearStructuralUndoRegistry: () => void;
      // MF-1 (Phase 5 review round): scoped to one evicted opId, not a whole-registry clear.
      clearStructuralUndoState: (opId: string) => void;
    };
  }
}
