/// <reference types="../global" />
import { autocompletion, type CompletionContext, type CompletionResult } from '@codemirror/autocomplete';
import { defaultKeymap, history, redo, undo } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { HighlightStyle, syntaxHighlighting, syntaxTree } from '@codemirror/language';
import { languages } from '@codemirror/language-data';
import {
  findNext,
  findPrevious,
  getSearchQuery,
  highlightSelectionMatches,
  replaceAll,
  replaceNext,
  SearchQuery,
  search,
  setSearchQuery,
} from '@codemirror/search';
import { EditorState, type Extension, RangeSetBuilder } from '@codemirror/state';
import {
  Decoration,
  type DecorationSet,
  EditorView,
  highlightActiveLine,
  keymap,
  ViewPlugin,
  type ViewUpdate,
} from '@codemirror/view';
import { tags } from '@lezer/highlight';
import './styles.css';
import { anchorPlugin, stripAnchors } from './anchor-plugin';

// Annotation types matching Milkdown
type AnnotationType = 'task' | 'comment' | 'reference';

interface ParsedAnnotation {
  type: AnnotationType;
  text: string;
  offset: number;
  completed?: boolean; // Match Milkdown API naming
}

// Find/replace options and result types
interface FindOptions {
  caseSensitive?: boolean;
  wholeWord?: boolean;
  regexp?: boolean;
}

interface FindResult {
  matchCount: number;
  currentIndex: number;
}

interface SearchState {
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
      // Citation API (CAYW picker callbacks)
      citationPickerCallback: (data: any, items: any[]) => void;
      citationPickerCancelled: () => void;
      citationPickerError: (message: string) => void;
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
    __CODEMIRROR_DEBUG__?: {
      editorReady: boolean;
      lastContentLength: number;
      lastStatsUpdate: string;
    };
    __CODEMIRROR_SCRIPT_STARTED__?: number;
  }
}

// Track slash command execution for smart undo
let pendingSlashUndo = false;

// Track pending CAYW citation picker request
let pendingCAYWRange: { start: number; end: number } | null = null;

// Append mode state for adding citations to existing ones
let pendingAppendMode = false;
let pendingAppendRange: { start: number; end: number } | null = null;

// Floating add citation button element
let citationAddButton: HTMLElement | null = null;

// Merge existing citation with new citation(s)
// existing: "[@key1; @key2, p. 42]"
// newCitation: "[@key3; @key4]"
// result: "[@key1; @key2, p. 42; @key3; @key4]"
function mergeCitations(existing: string, newCitation: string): string {
  // Strip outer brackets from both
  const existingInner = existing.replace(/^\[|\]$/g, '');
  const newInner = newCitation.replace(/^\[|\]$/g, '');

  // Combine with semicolon separator
  return `[${existingInner}; ${newInner}]`;
}

// Detect if cursor is inside a citation bracket [@...]
function getCitationAtCursor(view: EditorView): { text: string; from: number; to: number } | null {
  const pos = view.state.selection.main.head;
  const doc = view.state.doc.toString();

  // Search backwards for '[' and forwards for ']'
  let bracketStart = -1;
  let bracketEnd = -1;

  // Find opening bracket before cursor
  for (let i = pos - 1; i >= 0; i--) {
    if (doc[i] === '[') {
      bracketStart = i;
      break;
    }
    if (doc[i] === ']') {
      // Found closing bracket before opening - not inside a bracket
      break;
    }
  }

  if (bracketStart === -1) return null;

  // Find closing bracket after cursor
  for (let i = pos; i < doc.length; i++) {
    if (doc[i] === ']') {
      bracketEnd = i + 1;
      break;
    }
    if (doc[i] === '[') {
      // Found another opening bracket - not a valid citation
      break;
    }
  }

  if (bracketEnd === -1) return null;

  // Extract the text and verify it's a citation (contains @)
  const text = doc.slice(bracketStart, bracketEnd);
  if (!text.includes('@')) return null;

  return { text, from: bracketStart, to: bracketEnd };
}

// Create the floating add citation button
function createCitationAddButton(): HTMLElement {
  if (citationAddButton) return citationAddButton;

  const button = document.createElement('button');
  button.textContent = '+';
  button.className = 'cm-citation-add-button';
  button.style.cssText = `
    position: fixed;
    z-index: 10000;
    width: 24px;
    height: 24px;
    border-radius: 4px;
    border: 1px solid var(--editor-border, #ccc);
    background: var(--editor-bg, white);
    color: var(--editor-text, #333);
    cursor: pointer;
    font-size: 16px;
    font-weight: bold;
    line-height: 1;
    display: none;
    align-items: center;
    justify-content: center;
    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
  `;
  button.title = 'Add citation';

  button.addEventListener('mouseenter', () => {
    button.style.background = 'var(--editor-selection, #e8f0fe)';
  });
  button.addEventListener('mouseleave', () => {
    button.style.background = 'var(--editor-bg, white)';
  });
  button.addEventListener('click', (e) => {
    e.preventDefault();
    e.stopPropagation();
    handleAddCitationClick();
  });

  document.body.appendChild(button);
  citationAddButton = button;
  return button;
}

// Handle click on the add citation button
function handleAddCitationClick(): void {
  if (!editorView) return;

  const citation = getCitationAtCursor(editorView);
  if (!citation) {
    hideCitationAddButton();
    return;
  }

  // Store the range for merging later
  pendingAppendMode = true;
  pendingAppendRange = { start: citation.from, end: citation.to };

  // Call Swift to open CAYW picker
  // Pass -1 to indicate append mode
  if ((window as any).webkit?.messageHandlers?.openCitationPicker) {
    (window as any).webkit.messageHandlers.openCitationPicker.postMessage(-1);
  } else {
    pendingAppendMode = false;
    pendingAppendRange = null;
  }
}

// Show the add button near the citation
function showCitationAddButton(view: EditorView, citation: { text: string; from: number; to: number }): void {
  const button = createCitationAddButton();

  // Get coordinates for the end of the citation
  const coords = view.coordsAtPos(citation.to);
  if (!coords) {
    button.style.display = 'none';
    return;
  }

  button.style.left = `${coords.right + 4}px`;
  button.style.top = `${coords.top}px`;
  button.style.display = 'flex';
}

// Hide the add button
function hideCitationAddButton(): void {
  if (citationAddButton) {
    citationAddButton.style.display = 'none';
  }
}

// Update add button visibility based on cursor position
function updateCitationAddButton(view: EditorView): void {
  const citation = getCitationAtCursor(view);
  if (citation) {
    showCitationAddButton(view, citation);
  } else {
    hideCitationAddButton();
  }
}

// Slash command completions for section breaks and other commands
function slashCompletions(context: CompletionContext): CompletionResult | null {
  const word = context.matchBefore(/\/\w*/);
  if (!word) return null;
  if (word.from === word.to && !context.explicit) return null;

  return {
    from: word.from,
    options: [
      {
        label: '/break',
        detail: 'Insert section break',
        apply: (_view: EditorView, _completion: any, from: number, to: number) => {
          editorView?.dispatch({
            changes: { from, to, insert: '<!-- ::break:: -->\n\n' },
          });
          pendingSlashUndo = true;
        },
      },
      {
        label: '/h1',
        detail: 'Heading 1',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          // Transform entire line to heading
          const line = view.state.doc.lineAt(from);
          const lineText = line.text;

          // Calculate slash position from `from` parameter
          const slashPosInLine = from - line.from;
          // Use actual matched length (to - from) instead of hardcoded command length
          const matchedLength = to - from;

          // Extract text before slash and after the matched command
          const textBeforeSlash = lineText.slice(0, slashPosInLine);
          const textAfterCommand = lineText.slice(slashPosInLine + matchedLength);

          // Remove existing heading markers, concatenate directly (no join with space)
          const cleanBefore = textBeforeSlash.replace(/^#+\s*/, '');
          const combinedText = (cleanBefore + textAfterCommand).trim();

          // Replace entire line with new heading
          view.dispatch({
            changes: { from: line.from, to: line.to, insert: `# ${combinedText}` },
          });
          pendingSlashUndo = true;
        },
      },
      {
        label: '/h2',
        detail: 'Heading 2',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          // Transform entire line to heading
          const line = view.state.doc.lineAt(from);
          const lineText = line.text;

          // Calculate slash position from `from` parameter
          const slashPosInLine = from - line.from;
          // Use actual matched length (to - from) instead of hardcoded command length
          const matchedLength = to - from;

          // Extract text before slash and after the matched command
          const textBeforeSlash = lineText.slice(0, slashPosInLine);
          const textAfterCommand = lineText.slice(slashPosInLine + matchedLength);

          // Remove existing heading markers, concatenate directly (no join with space)
          const cleanBefore = textBeforeSlash.replace(/^#+\s*/, '');
          const combinedText = (cleanBefore + textAfterCommand).trim();

          // Replace entire line with new heading
          view.dispatch({
            changes: { from: line.from, to: line.to, insert: `## ${combinedText}` },
          });
          pendingSlashUndo = true;
        },
      },
      {
        label: '/h3',
        detail: 'Heading 3',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          // Transform entire line to heading
          const line = view.state.doc.lineAt(from);
          const lineText = line.text;

          // Calculate slash position from `from` parameter
          const slashPosInLine = from - line.from;
          // Use actual matched length (to - from) instead of hardcoded command length
          const matchedLength = to - from;

          // Extract text before slash and after the matched command
          const textBeforeSlash = lineText.slice(0, slashPosInLine);
          const textAfterCommand = lineText.slice(slashPosInLine + matchedLength);

          // Remove existing heading markers, concatenate directly (no join with space)
          const cleanBefore = textBeforeSlash.replace(/^#+\s*/, '');
          const combinedText = (cleanBefore + textAfterCommand).trim();

          // Replace entire line with new heading
          view.dispatch({
            changes: { from: line.from, to: line.to, insert: `### ${combinedText}` },
          });
          pendingSlashUndo = true;
        },
      },
      {
        label: '/task',
        detail: 'Insert task annotation',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          view.dispatch({
            changes: { from, to, insert: '<!-- ::task:: [ ]  -->' },
            selection: { anchor: from + 17 }, // Position cursor inside the task
          });
          pendingSlashUndo = true;
        },
      },
      {
        label: '/comment',
        detail: 'Insert comment annotation',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          view.dispatch({
            changes: { from, to, insert: '<!-- ::comment::  -->' },
            selection: { anchor: from + 17 }, // Position cursor inside the comment
          });
          pendingSlashUndo = true;
        },
      },
      {
        label: '/reference',
        detail: 'Insert reference annotation',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          view.dispatch({
            changes: { from, to, insert: '<!-- ::reference::  -->' },
            selection: { anchor: from + 19 }, // Position cursor inside the reference
          });
          pendingSlashUndo = true;
        },
      },
      {
        label: '/cite',
        detail: 'Insert citation from Zotero',
        apply: (_view: EditorView, _completion: any, from: number, to: number) => {
          // Store the range to replace (the /cite text)
          pendingCAYWRange = { start: from, end: to };
          // Call Swift to open CAYW picker
          if ((window as any).webkit?.messageHandlers?.openCitationPicker) {
            (window as any).webkit.messageHandlers.openCitationPicker.postMessage(from);
          } else {
            pendingCAYWRange = null;
          }
        },
      },
    ],
  };
}

// Custom highlight style for syntax elements (bold, italic, links, code)
// Headings are handled by headingDecorationPlugin (line decorations) instead,
// because HighlightStyle only creates spans for explicitly tagged nodes,
// and heading TEXT is not tagged (only the ATXHeading container node is).
const customHighlightStyle = HighlightStyle.define([
  { tag: tags.strong, fontWeight: '700' },
  { tag: tags.emphasis, fontStyle: 'italic' },
  { tag: tags.link, color: 'var(--accent-color, #007aff)' },
  { tag: tags.url, color: 'var(--accent-color, #007aff)', opacity: '0.7' },
  { tag: tags.monospace, background: 'var(--editor-selection, rgba(0, 122, 255, 0.1))' },
]);

// Line decoration plugin for markdown headings
// HighlightStyle.define only creates spans for explicitly tagged nodes,
// but heading TEXT is not tagged (only the ATXHeading container is).
// So we use line decorations instead, which apply CSS classes to entire lines.
//
// This plugin has two passes:
// 1. Syntax tree pass: finds standard ATX headings (# at column 0)
// 2. Regex fallback pass: finds headings after section anchors (<!-- @sid:UUID --># heading)
//    These aren't parsed as headings because Markdown requires # at column 0.
const headingDecorationPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = this.buildDecorations(view);
    }

    update(update: ViewUpdate) {
      if (update.docChanged || update.viewportChanged || syntaxTree(update.startState) !== syntaxTree(update.state)) {
        this.decorations = this.buildDecorations(update.view);
      }
    }

    buildDecorations(view: EditorView): DecorationSet {
      const doc = view.state.doc;
      const decorations: { pos: number; level: number }[] = [];
      const decoratedLines = new Set<number>();

      // First pass: Syntax tree (finds headings at line start)
      for (const { from, to } of view.visibleRanges) {
        syntaxTree(view.state).iterate({
          from,
          to,
          enter: (node) => {
            // Match ATXHeading1 through ATXHeading6
            const match = node.name.match(/^ATXHeading(\d)$/);
            if (match) {
              const line = doc.lineAt(node.from);
              if (!decoratedLines.has(line.number)) {
                decoratedLines.add(line.number);
                decorations.push({ pos: line.from, level: parseInt(match[1], 10) });
              }
            }
          },
        });
      }

      // Second pass: Regex fallback for headings after section anchors
      // Pattern: <!-- @sid:UUID --># heading text
      // The ^ ensures we match at line start; anchors won't have content before them
      const anchorHeadingRegex = /^<!--\s*@sid:[^>]+-->(#{1,6})\s/;

      for (const { from, to } of view.visibleRanges) {
        const startLine = doc.lineAt(from).number;
        const endLine = doc.lineAt(to).number;

        for (let lineNum = startLine; lineNum <= endLine; lineNum++) {
          if (decoratedLines.has(lineNum)) continue; // Already decorated by syntax tree

          const line = doc.line(lineNum);
          const match = line.text.match(anchorHeadingRegex);
          if (match) {
            decoratedLines.add(lineNum);
            decorations.push({ pos: line.from, level: match[1].length });
          }
        }
      }

      // Sort by position (RangeSetBuilder requires sorted order)
      decorations.sort((a, b) => a.pos - b.pos);

      const builder = new RangeSetBuilder<Decoration>();
      for (const { pos, level } of decorations) {
        builder.add(pos, pos, Decoration.line({ class: `cm-heading-${level}-line` }));
      }

      return builder.finish();
    }
  },
  {
    decorations: (v) => v.decorations,
  }
);

// Mark script start time for debugging
window.__CODEMIRROR_SCRIPT_STARTED__ = Date.now();

let editorView: EditorView | null = null;

// Module-level extensions array for EditorState creation (used by initEditor and resetForProjectSwitch)
let editorExtensions: Extension[] = [];

// Debug state for Swift introspection
window.__CODEMIRROR_DEBUG__ = {
  editorReady: false,
  lastContentLength: 0,
  lastStatsUpdate: '',
};

// Search state for tracking current match index
let currentSearchQuery = '';
let currentSearchOptions: FindOptions = {};
let currentMatchIndex = 0;

// Helper to count matches in document
function countMatches(view: EditorView, query: SearchQuery): number {
  let count = 0;
  const cursor = query.getCursor(view.state.doc);
  while (!cursor.next().done) {
    count++;
  }
  return count;
}

// Helper to find current match index based on cursor position
function findCurrentMatchIndex(view: EditorView, query: SearchQuery): number {
  const cursor = query.getCursor(view.state.doc);
  const cursorPos = view.state.selection.main.from;
  let index = 0;
  while (!cursor.next().done) {
    index++;
    if (cursor.value.from >= cursorPos) {
      return index;
    }
  }
  return index > 0 ? index : 1;
}

function initEditor() {
  const container = document.getElementById('editor');
  if (!container) {
    console.error('[CodeMirror] #editor container not found');
    return;
  }

  // Store extensions at module level so resetForProjectSwitch can recreate EditorState
  editorExtensions = [
    highlightActiveLine(),
    history(),
    markdown({ base: markdownLanguage, codeLanguages: languages }),
    syntaxHighlighting(customHighlightStyle),
    headingDecorationPlugin,
    // Search extension - headless mode (no default keybindings, controlled via Swift)
    search({ top: false }),
    highlightSelectionMatches(),
    autocompletion({ override: [slashCompletions] }),
    keymap.of([
      // Filter out Mod-/ (toggle comment) from default keymap to allow Swift to handle mode toggle
      ...defaultKeymap.filter((k) => k.key !== 'Mod-/'),
      // Custom undo: after slash command, also removes the "/" trigger
      {
        key: 'Mod-z',
        run: (view) => {
          if (pendingSlashUndo) {
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
            pendingSlashUndo = false;
            return true;
          }
          // Normal undo
          return undo(view);
        },
      },
      // Redo bindings (Mac and Windows)
      { key: 'Mod-Shift-z', run: (view) => redo(view) },
      { key: 'Mod-y', run: (view) => redo(view) },
      // Cmd+B: Bold
      {
        key: 'Mod-b',
        run: () => {
          wrapSelection('**');
          return true;
        },
      },
      // Cmd+I: Italic
      {
        key: 'Mod-i',
        run: () => {
          wrapSelection('*');
          return true;
        },
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
      '&': { height: '100%' },
      '.cm-scroller': { overflow: 'auto' },
    }),
    // Reset pendingSlashUndo on any editing key
    EditorView.domEventHandlers({
      keydown(event, _view) {
        // Reset flag on any editing key (typing, backspace, delete)
        if (event.key.length === 1 || event.key === 'Backspace' || event.key === 'Delete') {
          pendingSlashUndo = false;
        }
        return false;
      },
    }),
    // Update citation add button on selection changes
    EditorView.updateListener.of((update) => {
      if (update.selectionSet || update.docChanged) {
        updateCitationAddButton(update.view);
      }
    }),
    // Section anchor plugin - hides <!-- @sid:UUID --> comments and handles clipboard
    anchorPlugin(),
  ];

  const state = EditorState.create({
    doc: '',
    extensions: editorExtensions,
  });

  editorView = new EditorView({
    state,
    parent: container,
  });

  window.__CODEMIRROR_DEBUG__!.editorReady = true;
}

function wrapSelection(wrapper: string) {
  if (!editorView) return;
  const { from, to } = editorView.state.selection.main;
  const selected = editorView.state.sliceDoc(from, to);
  const wrapped = wrapper + selected + wrapper;
  editorView.dispatch({
    changes: { from, to, insert: wrapped },
    selection: { anchor: from + wrapper.length, head: to + wrapper.length },
  });
}

function insertLink() {
  if (!editorView) return;
  const { from, to } = editorView.state.selection.main;
  const selected = editorView.state.sliceDoc(from, to);
  const linkText = selected || 'link text';
  const inserted = `[${linkText}](url)`;
  editorView.dispatch({
    changes: { from, to, insert: inserted },
    selection: { anchor: from + 1, head: from + 1 + linkText.length },
  });
}

function countWords(text: string): number {
  // Strip annotations before counting (<!-- ::type:: content -->)
  const strippedText = text.replace(/<!--\s*::\w+::\s*[\s\S]*?-->/g, '');
  return strippedText.split(/\s+/).filter((w) => w.length > 0).length;
}

// Register window.FinalFinal API
window.FinalFinal = {
  setContent(markdown: string, options?: { scrollToStart?: boolean }) {
    if (!editorView) {
      return;
    }

    const prevLen = editorView.state.doc.length;
    editorView.dispatch({
      changes: { from: 0, to: prevLen, insert: markdown },
    });
    window.__CODEMIRROR_DEBUG__!.lastContentLength = markdown.length;

    // Reset scroll position for zoom transitions
    // Swift handles hiding/showing the WKWebView at compositor level
    if (options?.scrollToStart) {
      editorView.dispatch({
        selection: { anchor: 0 },
        effects: EditorView.scrollIntoView(0, { y: 'start' }),
      });
      // Force CodeMirror to recalculate viewport
      editorView.requestMeasure();

      // Force aggressive reflow for long content
      void editorView.dom.offsetHeight;
      void document.body.offsetHeight;
    }
  },

  getContent(): string {
    // Returns content with anchors stripped (default for backwards compatibility)
    if (!editorView) return '';
    return stripAnchors(editorView.state.doc.toString());
  },

  getContentClean(): string {
    // Explicitly returns content with anchors stripped
    if (!editorView) return '';
    return stripAnchors(editorView.state.doc.toString());
  },

  getContentRaw(): string {
    // Returns content including hidden anchors (for internal use during mode switch)
    if (!editorView) return '';
    return editorView.state.doc.toString();
  },

  setFocusMode(_enabled: boolean) {
    // Focus mode is WYSIWYG-only; ignore in source mode
  },

  getStats() {
    // Use stripped content for accurate word/char counts (exclude hidden anchors and annotations)
    const rawContent = editorView?.state.doc.toString() || '';
    const content = stripAnchors(rawContent);
    // Strip annotations before counting (<!-- ::type:: content -->)
    const strippedContent = content.replace(/<!--\s*::\w+::\s*[\s\S]*?-->/g, '');
    const words = countWords(strippedContent);
    const characters = strippedContent.length;
    window.__CODEMIRROR_DEBUG__!.lastStatsUpdate = new Date().toISOString();
    return { words, characters };
  },

  scrollToOffset(offset: number) {
    if (!editorView) return;
    const pos = Math.min(offset, editorView.state.doc.length);
    editorView.dispatch({
      effects: EditorView.scrollIntoView(pos, { y: 'start', yMargin: 50 }),
    });
  },

  setTheme(cssVariables: string) {
    const root = document.documentElement;
    // Clear all existing CSS custom properties to remove stale overrides
    // This ensures that when an override is removed (e.g., font reset to default),
    // the old value doesn't persist on the element's inline style
    const propsToRemove: string[] = [];
    for (let i = 0; i < root.style.length; i++) {
      const prop = root.style[i];
      if (prop.startsWith('--')) {
        propsToRemove.push(prop);
      }
    }
    for (const prop of propsToRemove) {
      root.style.removeProperty(prop);
    }

    // Set new CSS variables
    const pairs = cssVariables.split(';').filter((s) => s.trim());
    pairs.forEach((pair) => {
      const [key, value] = pair.split(':').map((s) => s.trim());
      if (key && value) {
        root.style.setProperty(key, value);
      }
    });
  },

  getCursorPosition(): { line: number; column: number } {
    if (!editorView) {
      return { line: 1, column: 0 };
    }
    try {
      const pos = editorView.state.selection.main.head;
      const line = editorView.state.doc.lineAt(pos);
      return {
        line: line.number, // CodeMirror lines are 1-indexed
        column: pos - line.from,
      };
    } catch (_e) {
      return { line: 1, column: 0 };
    }
  },

  setCursorPosition(lineCol: { line: number; column: number }) {
    if (!editorView) {
      return;
    }
    try {
      const { line, column } = lineCol;

      // Clamp line to valid range
      const lineCount = editorView.state.doc.lines;
      const safeLine = Math.max(1, Math.min(line, lineCount));

      const lineInfo = editorView.state.doc.line(safeLine);
      const maxCol = lineInfo.length;
      const safeCol = Math.max(0, Math.min(column, maxCol));

      const pos = lineInfo.from + safeCol;

      editorView.dispatch({
        selection: { anchor: pos },
        effects: EditorView.scrollIntoView(pos, { y: 'center' }),
      });
      editorView.focus();
    } catch (_e) {
      // Cursor positioning failed
    }
  },

  scrollCursorToCenter() {
    if (!editorView) return;
    try {
      const pos = editorView.state.selection.main.head;
      const coords = editorView.coordsAtPos(pos);
      if (coords) {
        const viewportHeight = window.innerHeight;
        const targetScrollY = coords.top + window.scrollY - viewportHeight / 2;
        window.scrollTo({ top: Math.max(0, targetScrollY), behavior: 'instant' });
      }
    } catch (_e) {
      // Scroll failed
    }
  },

  insertAtCursor(text: string) {
    if (!editorView) return;
    const { from, to } = editorView.state.selection.main;
    editorView.dispatch({
      changes: { from, to, insert: text },
      selection: { anchor: from + text.length },
    });
    editorView.focus();
  },

  insertBreak() {
    // Insert a pseudo-section break marker
    this.insertAtCursor('\n\n<!-- ::break:: -->\n\n');
  },

  focus() {
    if (!editorView) return;
    editorView.focus();
  },

  // === Batch initialization for faster startup ===

  initialize(options: { content: string; theme: string; cursorPosition: { line: number; column: number } | null }) {
    // Apply theme first
    this.setTheme(options.theme);

    // Set content
    this.setContent(options.content);

    // Restore cursor position if provided
    if (options.cursorPosition) {
      this.setCursorPosition(options.cursorPosition);
      this.scrollCursorToCenter();
    }

    // Focus the editor
    this.focus();
  },

  // Annotation API methods
  setAnnotationDisplayModes(_modes: Record<string, string>) {
    // In source mode, annotations are shown as raw markdown text
    // Display modes don't visually change anything
  },

  getAnnotations(): ParsedAnnotation[] {
    if (!editorView) return [];

    const content = editorView.state.doc.toString();
    const annotations: ParsedAnnotation[] = [];

    // Parse annotation HTML comments: <!-- ::type:: content -->
    const annotationRegex = /<!--\s*::(\w+)::\s*(.+?)\s*-->/gs;
    const taskCheckboxRegex = /^\s*\[([ xX])\]\s*(.*)$/s;
    const validTypes = ['task', 'comment', 'reference'];

    let match;
    while ((match = annotationRegex.exec(content)) !== null) {
      const [, typeStr, rawContent] = match;

      if (!validTypes.includes(typeStr)) continue;

      const type = typeStr as AnnotationType;
      let text = rawContent;
      let isCompleted = false;

      // Parse task checkbox
      if (type === 'task') {
        const checkboxMatch = rawContent.match(taskCheckboxRegex);
        if (checkboxMatch) {
          isCompleted = checkboxMatch[1].toLowerCase() === 'x';
          text = checkboxMatch[2];
        }
      }

      annotations.push({
        type,
        text: text.trim(),
        offset: match.index,
        completed: type === 'task' ? isCompleted : undefined,
      });
    }

    return annotations;
  },

  scrollToAnnotation(offset: number) {
    if (!editorView) return;
    const pos = Math.min(offset, editorView.state.doc.length);
    editorView.dispatch({
      selection: { anchor: pos },
      effects: EditorView.scrollIntoView(pos, { y: 'center', yMargin: 100 }),
    });
    editorView.focus();
  },

  insertAnnotation(type: string) {
    if (!editorView) return;

    const validTypes = ['task', 'comment', 'reference'];
    if (!validTypes.includes(type)) {
      return;
    }

    const { from, to } = editorView.state.selection.main;
    let insertText: string;
    let cursorOffset: number;

    if (type === 'task') {
      insertText = '<!-- ::task:: [ ]  -->';
      cursorOffset = 17;
    } else if (type === 'comment') {
      insertText = '<!-- ::comment::  -->';
      cursorOffset = 17;
    } else {
      insertText = '<!-- ::reference::  -->';
      cursorOffset = 19;
    }

    editorView.dispatch({
      changes: { from, to, insert: insertText },
      selection: { anchor: from + cursorOffset },
    });
    editorView.focus();
  },

  toggleHighlight(): boolean {
    if (!editorView) return false;

    const { from, to } = editorView.state.selection.main;

    // Require a selection
    if (from === to) {
      return false;
    }

    const selectedText = editorView.state.sliceDoc(from, to);

    // Check if already highlighted (wrapped in ==)
    const beforeStart = from >= 2 ? editorView.state.sliceDoc(from - 2, from) : '';
    const afterEnd = to + 2 <= editorView.state.doc.length ? editorView.state.sliceDoc(to, to + 2) : '';

    if (beforeStart === '==' && afterEnd === '==') {
      // Remove highlight - delete the surrounding ==
      editorView.dispatch({
        changes: [
          { from: from - 2, to: from, insert: '' },
          { from: to, to: to + 2, insert: '' },
        ],
        selection: { anchor: from - 2, head: to - 2 },
      });
      return true;
    }

    // Check if selection itself includes the == delimiters
    if (selectedText.startsWith('==') && selectedText.endsWith('==') && selectedText.length > 4) {
      // Remove highlight by replacing with content minus delimiters
      const innerText = selectedText.slice(2, -2);
      editorView.dispatch({
        changes: { from, to, insert: innerText },
        selection: { anchor: from, head: from + innerText.length },
      });
      return true;
    }

    // Add highlight
    const highlighted = `==${selectedText}==`;
    editorView.dispatch({
      changes: { from, to, insert: highlighted },
      selection: { anchor: from + 2, head: to + 2 },
    });
    editorView.focus();
    return true;
  },

  // Citation API (CAYW picker callbacks)
  citationPickerCallback(data: any, _items: any[]) {
    if (!editorView) {
      pendingCAYWRange = null;
      pendingAppendMode = false;
      pendingAppendRange = null;
      return;
    }

    // Check for append mode - merging new citations with existing ones
    if (pendingAppendMode && pendingAppendRange) {
      const { start, end } = pendingAppendRange;
      const existing = editorView.state.sliceDoc(start, end);
      const rawSyntax = (data.rawSyntax as string) || `[@${(data.citekeys as string[]).join('; @')}]`;
      const merged = mergeCitations(existing, rawSyntax);

      editorView.dispatch({
        changes: { from: start, to: end, insert: merged },
        selection: { anchor: start + merged.length },
      });
      editorView.focus();

      pendingAppendMode = false;
      pendingAppendRange = null;
      hideCitationAddButton();
      return;
    }

    // Normal insertion mode
    if (!pendingCAYWRange) {
      return;
    }

    const { start, end } = pendingCAYWRange;
    pendingCAYWRange = null;

    // Build Pandoc citation syntax: [@citekey1; @citekey2]
    const citekeys = data.citekeys as string[];
    const rawSyntax = (data.rawSyntax as string) || `[@${citekeys.join('; @')}]`;

    // Replace /cite with the citation syntax
    editorView.dispatch({
      changes: { from: start, to: end, insert: rawSyntax },
      selection: { anchor: start + rawSyntax.length },
    });
    editorView.focus();
  },

  citationPickerCancelled() {
    pendingCAYWRange = null;
    pendingAppendMode = false;
    pendingAppendRange = null;
    if (editorView) {
      editorView.focus();
    }
  },

  citationPickerError(message: string) {
    console.error('[CodeMirror] citationPickerError:', message);
    pendingCAYWRange = null;
    pendingAppendMode = false;
    pendingAppendRange = null;
    alert(message);
    if (editorView) {
      editorView.focus();
    }
  },

  // Find/replace API
  find(query: string, options?: FindOptions): FindResult {
    if (!editorView) {
      return { matchCount: 0, currentIndex: 0 };
    }

    currentSearchQuery = query;
    currentSearchOptions = options || {};

    if (!query) {
      // Clear search
      this.clearSearch();
      return { matchCount: 0, currentIndex: 0 };
    }

    // Create search query with options
    const searchQuery = new SearchQuery({
      search: query,
      caseSensitive: options?.caseSensitive ?? false,
      regexp: options?.regexp ?? false,
      wholeWord: options?.wholeWord ?? false,
    });

    // Set the search query in the editor state
    editorView.dispatch({
      effects: setSearchQuery.of(searchQuery),
    });

    // Count matches
    const matchCount = countMatches(editorView, searchQuery);

    // Find current match index based on cursor position
    currentMatchIndex = matchCount > 0 ? findCurrentMatchIndex(editorView, searchQuery) : 0;

    return { matchCount, currentIndex: currentMatchIndex };
  },

  findNext(): FindResult | null {
    if (!editorView || !currentSearchQuery) {
      return null;
    }

    // Execute findNext command
    findNext(editorView);

    // Get current query and recalculate
    const searchQuery = getSearchQuery(editorView.state);
    const matchCount = countMatches(editorView, searchQuery);
    currentMatchIndex = matchCount > 0 ? findCurrentMatchIndex(editorView, searchQuery) : 0;

    return { matchCount, currentIndex: currentMatchIndex };
  },

  findPrevious(): FindResult | null {
    if (!editorView || !currentSearchQuery) {
      return null;
    }

    // Execute findPrevious command
    findPrevious(editorView);

    // Get current query and recalculate
    const searchQuery = getSearchQuery(editorView.state);
    const matchCount = countMatches(editorView, searchQuery);
    currentMatchIndex = matchCount > 0 ? findCurrentMatchIndex(editorView, searchQuery) : 0;

    return { matchCount, currentIndex: currentMatchIndex };
  },

  replaceCurrent(replacement: string): boolean {
    if (!editorView || !currentSearchQuery) {
      return false;
    }

    // Update the search query with replacement
    const searchQuery = new SearchQuery({
      search: currentSearchQuery,
      caseSensitive: currentSearchOptions.caseSensitive ?? false,
      regexp: currentSearchOptions.regexp ?? false,
      wholeWord: currentSearchOptions.wholeWord ?? false,
      replace: replacement,
    });

    editorView.dispatch({
      effects: setSearchQuery.of(searchQuery),
    });

    // Execute replaceNext command
    return replaceNext(editorView);
  },

  replaceAll(replacement: string): number {
    if (!editorView || !currentSearchQuery) {
      return 0;
    }

    // Count matches before replacement
    const searchQuery = new SearchQuery({
      search: currentSearchQuery,
      caseSensitive: currentSearchOptions.caseSensitive ?? false,
      regexp: currentSearchOptions.regexp ?? false,
      wholeWord: currentSearchOptions.wholeWord ?? false,
      replace: replacement,
    });

    const beforeCount = countMatches(editorView, searchQuery);

    editorView.dispatch({
      effects: setSearchQuery.of(searchQuery),
    });

    // Execute replaceAll command
    replaceAll(editorView);

    // Return the number of replacements made
    return beforeCount;
  },

  clearSearch(): void {
    if (!editorView) {
      return;
    }

    currentSearchQuery = '';
    currentSearchOptions = {};
    currentMatchIndex = 0;

    // Clear search by setting empty query
    const emptyQuery = new SearchQuery({ search: '' });
    editorView.dispatch({
      effects: setSearchQuery.of(emptyQuery),
    });
  },

  getSearchState(): SearchState | null {
    if (!editorView || !currentSearchQuery) {
      return null;
    }

    const searchQuery = getSearchQuery(editorView.state);
    const matchCount = countMatches(editorView, searchQuery);

    return {
      query: currentSearchQuery,
      matchCount,
      currentIndex: currentMatchIndex,
      options: currentSearchOptions,
    };
  },

  resetForProjectSwitch() {
    if (!editorView) return;

    // Clear transient module-level state
    pendingSlashUndo = false;
    pendingCAYWRange = null;
    pendingAppendMode = false;
    pendingAppendRange = null;
    currentSearchQuery = '';
    currentSearchOptions = {};
    currentMatchIndex = 0;
    if (citationAddButton) citationAddButton.style.display = 'none';

    // Create fresh EditorState (clears undo history, selection, search state)
    const newState = EditorState.create({
      doc: editorView.state.doc, // Keep current content (will be replaced by setContent)
      extensions: editorExtensions,
    });
    editorView.setState(newState);
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
      editorReady: window.__CODEMIRROR_DEBUG__?.editorReady ?? false,
      focusModeEnabled: false, // CodeMirror has no focus mode
    };
  },
};

// Initialize on DOM ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initEditor);
} else {
  initEditor();
}
