// Type definitions and interfaces for the Milkdown editor

import type { BlockChanges } from './block-sync-plugin';
import type { CSLItem } from './citation-plugin';

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
      setContent: (markdown: string, options?: { scrollToStart?: boolean }) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
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
      // Legacy search callback (kept for backwards compatibility)
      searchCitationsCallback: (items: CSLItem[]) => void;
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
          // Whether the pushed content represents a zoomed subset of the document
          // rather than the full document. Sets blockIdZoomMode SYNCHRONOUSLY,
          // in the same call that pushes the content — closing the race window
          // where a caller previously had to wait for a separate, awaited
          // syncBlockIds()/pushBlockIds() round-trip to flip the flag back on
          // after this function unconditionally cleared it. Defaults to false,
          // matching every pre-existing (non-zoom) call site untouched by this.
          zoomMode?: boolean;
        }
      ) => void;
      scrollToBlock: (blockId: string) => void;
      getBlockAtCursor: () => { blockId: string; offset: number } | null;
      hasBlockChanges: () => boolean;
      flushPendingBlockChanges: () => void;
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
      // Unified-undo API (docs/plans/patient-rewinding-clockwork.md) -- Phase 2 skeleton.
      // See undo-coordinator.ts for the full design; no Swift call site invokes
      // setUndoDescriptor/receiveUndoOutcome/receiveRedoOutcome yet -- Phase 3+ wires them
      // alongside the first real structural operations.
      requestUnifiedUndo: () => void;
      requestUnifiedRedo: () => void;
      setUndoDescriptor: (descriptor: { undoTopOpId?: string; redoTopOpId?: string }) => void;
      receiveUndoOutcome: (opId: string, outcome: 'performed' | 'fallback') => void;
      receiveRedoOutcome: (opId: string, outcome: 'performed' | 'fallback') => void;
    };
  }
}
