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
      getAnnotations: () => ParsedAnnotation[];
      scrollToAnnotation: (offset: number) => void;
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
      insertLink: () => boolean;
      // Citation API (CAYW picker callbacks)
      citationPickerCallback: (data: any, items: any[]) => void;
      citationPickerCancelled: () => void;
      citationPickerError: (message: string) => void;
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
      // Project switch reset
      resetForProjectSwitch: () => void;
    };
  }
}
