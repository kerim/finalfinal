// Annotation types matching Milkdown
export type AnnotationType = 'task' | 'comment' | 'reference';

export interface ParsedAnnotation {
  type: AnnotationType;
  text: string;
  offset: number;
  completed?: boolean; // Match Milkdown API naming
}

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

declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string, options?: { scrollToStart?: boolean }) => void;
      getContent: () => string;
      getContentClean: () => string; // Content with anchors stripped
      getContentRaw: () => string; // Content including hidden anchors
      setFocusMode: (enabled: boolean) => void;
      getStats: () => { words: number; characters: number };
      getCurrentSectionTitle: () => string | null;
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
      getAnnotations: () => ParsedAnnotation[];
      scrollToAnnotation: (index: number) => void;
      insertAnnotation: (type: string) => void;
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
      // Citation API (CAYW picker callbacks)
      // data.requestId (and the requestId passed to cancelled/error) is an opaque
      // round-trip token identifying which pending /cite request this resolves — NOT a
      // document position. The original command position can go stale during the async
      // Zotero round-trip, so editor-state.ts tracks it separately (remapped across
      // edits by cayw-remap-plugin.ts); this id is only used to look up that entry.
      citationPickerCallback: (data: any, items: any[]) => void;
      citationPickerCancelled: (requestId: number) => void;
      citationPickerError: (message: string, requestId: number) => void;
      // Insert a brand-new citation at the current cursor (native toolbar "Cite" button)
      insertCitation: () => void;
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
      // Find/replace API
      find: (query: string, options?: FindOptions) => FindResult;
      findNext: () => FindResult | null;
      findPrevious: () => FindResult | null;
      replaceCurrent: (replacement: string) => boolean;
      replaceAll: (replacement: string) => number;
      clearSearch: () => void;
      getSearchState: () => SearchState | null;
      // Image API
      insertImage: (opts: { src: string; alt?: string; caption?: string }) => void;
      setImageMeta: (meta: Array<{ src: string; width?: number | null }>) => void;
      // Table API
      insertTable: (rows: number, cols: number) => void;
      formatTable: () => void;
      // Project switch reset
      resetForProjectSwitch: () => void;
      // Unified-undo API (docs/plans/patient-rewinding-clockwork.md) -- Phase 2 skeleton.
      // See undo-coordinator.ts for the full design; no Swift call site invokes
      // setUndoDescriptor/receiveUndoOutcome/receiveRedoOutcome yet -- Phase 3+ wires them
      // alongside the first real structural operations.
      requestUnifiedUndo: () => void;
      requestUnifiedRedo: () => void;
      setUndoDescriptor: (descriptor: { undoTopOpId?: string; redoTopOpId?: string }) => void;
      receiveUndoOutcome: (opId: string, outcome: 'performed' | 'fallback' | 'failed') => void;
      receiveRedoOutcome: (opId: string, outcome: 'performed' | 'fallback' | 'failed') => void;
      // Structural op lifecycle (Phase 3, plan §4.4) -- called by StructuralUndoController.swift.
      beginStructuralOp: (opId: string) => boolean;
      finalizeStructuralOpPostOpDoc: (opId: string) => boolean;
      // Barrier/eviction JS-side clears (Phase 5, plan §4.1/§4.5/§5 backlog).
      clearStructuralUndoRegistry: () => void;
      // MF-1 (Phase 5 review round): scoped to one evicted opId, not a whole-registry clear.
      clearStructuralUndoState: (opId: string) => void;
      // Combined poll data
      getPollData: () => string;
      // Test snapshot hook
      __testSnapshot: () => any;
    };
  }
}
