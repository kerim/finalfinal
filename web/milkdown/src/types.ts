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
  cmdStart: number;
}

// Interface for edit citation callback data from Swift
export interface EditCitationCallbackData {
  pos: number; // Position of the citation node to update
  rawSyntax: string;
  citekeys: string[];
  locators: string;
  prefix: string;
  suppressAuthor: boolean;
}

declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string, options?: { scrollToStart?: boolean }) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
      getStats: () => { words: number; characters: number };
      scrollToOffset: (offset: number) => void;
      setTheme: (cssVariables: string) => void;
      getCursorPosition: () => { line: number; column: number };
      setCursorPosition: (pos: { line: number; column: number }) => void;
      scrollCursorToCenter: () => void;
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
      scrollToAnnotation: (offset: number) => void;
      insertAnnotation: (type: string) => void;
      setHideCompletedTasks: (enabled: boolean) => void;
      // Highlight API
      toggleHighlight: () => boolean;
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
      citationPickerCancelled: () => void;
      citationPickerError: (message: string) => void;
      // Edit citation callback (for clicking existing citations)
      editCitationCallback: (data: EditCitationCallbackData, items: CSLItem[]) => void;
      // Debug API
      getCAYWDebugState: () => {
        pendingCAYWRange: { start: number; end: number } | null;
        hasEditor: boolean;
        docSize: number | null;
      };
      // Block-based API (Phase B)
      getBlockChanges: () => BlockChanges;
      applyBlocks: (blocks: Block[]) => void;
      confirmBlockIds: (mapping: Record<string, string>) => void;
      syncBlockIds: (orderedIds: string[]) => void;
      setContentWithBlockIds: (markdown: string, blockIds: string[], options?: { scrollToStart?: boolean }) => void;
      scrollToBlock: (blockId: string) => void;
      getBlockAtCursor: () => { blockId: string; offset: number } | null;
      hasBlockChanges: () => boolean;
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
    };
  }
}
