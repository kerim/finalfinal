import { autocompletion, type CompletionContext, type CompletionResult } from '@codemirror/autocomplete';
import { defaultKeymap, history, redo, undo } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { defaultHighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { languages } from '@codemirror/language-data';
import { EditorState } from '@codemirror/state';
import { EditorView, highlightActiveLine, highlightActiveLineGutter, keymap, lineNumbers } from '@codemirror/view';
import './styles.css';

// Annotation types matching Milkdown
type AnnotationType = 'task' | 'comment' | 'reference';

interface ParsedAnnotation {
  type: AnnotationType;
  text: string;
  offset: number;
  completed?: boolean; // Match Milkdown API naming
}

declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string) => void;
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
      getAnnotations: () => ParsedAnnotation[];
      scrollToAnnotation: (offset: number) => void;
      insertAnnotation: (type: string) => void;
      // Highlight API
      toggleHighlight: () => boolean;
      // Citation API (CAYW picker callbacks)
      citationPickerCallback: (data: any, items: any[]) => void;
      citationPickerCancelled: () => void;
      citationPickerError: (message: string) => void;
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
    console.warn('[CodeMirror] handleAddCitationClick: no citation at cursor');
    hideCitationAddButton();
    return;
  }

  console.log('[CodeMirror] Add citation clicked, existing:', citation.text);

  // Store the range for merging later
  pendingAppendMode = true;
  pendingAppendRange = { start: citation.from, end: citation.to };

  // Call Swift to open CAYW picker
  // Pass -1 to indicate append mode
  if ((window as any).webkit?.messageHandlers?.openCitationPicker) {
    (window as any).webkit.messageHandlers.openCitationPicker.postMessage(-1);
  } else {
    console.warn('[CodeMirror] Swift message handler not available');
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
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          console.log(`[SLASH DEBUG] apply: from=${from}, to=${to}, text="${view.state.sliceDoc(from, to)}"`);
          console.log(
            `[SLASH DEBUG] doc BEFORE dispatch (around from): "${view.state.sliceDoc(Math.max(0, from - 5), from)}|${view.state.sliceDoc(from, to)}|${view.state.sliceDoc(to, to + 20)}"`
          );
          view.dispatch({
            changes: { from, to, insert: '<!-- ::break:: -->\n\n' },
          });
          console.log(
            `[SLASH DEBUG] doc AFTER dispatch (around from): "${view.state.sliceDoc(Math.max(0, from - 5), from + 30)}"`
          );
          pendingSlashUndo = true;
          console.log('[SLASH DEBUG] pendingSlashUndo set to true');
        },
      },
      {
        label: '/h1',
        detail: 'Heading 1',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          console.log(`[SLASH DEBUG] apply /h1: from=${from}, to=${to}, text="${view.state.sliceDoc(from, to)}"`);
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
          console.log('[SLASH DEBUG] pendingSlashUndo set to true');
        },
      },
      {
        label: '/h2',
        detail: 'Heading 2',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          console.log(`[SLASH DEBUG] apply /h2: from=${from}, to=${to}, text="${view.state.sliceDoc(from, to)}"`);
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
          console.log('[SLASH DEBUG] pendingSlashUndo set to true');
        },
      },
      {
        label: '/h3',
        detail: 'Heading 3',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          console.log(`[SLASH DEBUG] apply /h3: from=${from}, to=${to}, text="${view.state.sliceDoc(from, to)}"`);
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
          console.log('[SLASH DEBUG] pendingSlashUndo set to true');
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
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          console.log('[CodeMirror /cite] Opening CAYW picker, from:', from, 'to:', to);
          // Store the range to replace (the /cite text)
          pendingCAYWRange = { start: from, end: to };
          // Call Swift to open CAYW picker
          if ((window as any).webkit?.messageHandlers?.openCitationPicker) {
            (window as any).webkit.messageHandlers.openCitationPicker.postMessage(from);
          } else {
            console.warn('[CodeMirror /cite] Swift message handler not available');
            pendingCAYWRange = null;
          }
        },
      },
    ],
  };
}

// Mark script start time for debugging
window.__CODEMIRROR_SCRIPT_STARTED__ = Date.now();

let editorView: EditorView | null = null;

// Debug state for Swift introspection
window.__CODEMIRROR_DEBUG__ = {
  editorReady: false,
  lastContentLength: 0,
  lastStatsUpdate: '',
};

// === Diagnostic logging for cursor position debugging ===
let _debugSeq = 0;
const _debugLog: Array<{ seq: number; ts: string; msg: string }> = [];

function debugLog(msg: string) {
  const seq = ++_debugSeq;
  const ts = performance.now().toFixed(2);
  console.log(`[CM DEBUG ${seq}] T=${ts}ms: ${msg}`);
  _debugLog.push({ seq, ts, msg });
  // Keep only last 50 entries
  if (_debugLog.length > 50) _debugLog.shift();
}

// Expose debug log for Swift to query
(window as any).__CM_DEBUG_LOG__ = _debugLog;

function initEditor() {
  const container = document.getElementById('editor');
  if (!container) {
    console.error('[CodeMirror] #editor container not found');
    return;
  }

  const state = EditorState.create({
    doc: '',
    extensions: [
      lineNumbers(),
      highlightActiveLine(),
      highlightActiveLineGutter(),
      history(),
      markdown({ base: markdownLanguage, codeLanguages: languages }),
      syntaxHighlighting(defaultHighlightStyle),
      autocompletion({ override: [slashCompletions] }),
      keymap.of([
        // Filter out Mod-/ (toggle comment) from default keymap to allow Swift to handle mode toggle
        ...defaultKeymap.filter((k) => k.key !== 'Mod-/'),
        // Custom undo: after slash command, also removes the "/" trigger
        {
          key: 'Mod-z',
          run: (view) => {
            console.log(`[SLASH DEBUG] Mod-z keymap, pendingSlashUndo=${pendingSlashUndo}`);
            if (pendingSlashUndo) {
              // Undo the slash command insertion
              undo(view);

              // Delete the "/" that was restored
              const pos = view.state.selection.main.head;
              if (pos > 0) {
                const charBefore = view.state.sliceDoc(pos - 1, pos);
                console.log(`[SLASH DEBUG] charBefore="${charBefore}"`);
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
    ],
  });

  editorView = new EditorView({
    state,
    parent: container,
  });

  window.__CODEMIRROR_DEBUG__!.editorReady = true;
  console.log('[CodeMirror] Editor initialized');
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
  return text.split(/\s+/).filter((w) => w.length > 0).length;
}

// Register window.FinalFinal API
window.FinalFinal = {
  setContent(markdown: string) {
    debugLog(`setContent START, ${markdown.length} chars`);
    if (!editorView) {
      debugLog('setContent: no editorView');
      return;
    }
    const prevLen = editorView.state.doc.length;
    const prevCursor = editorView.state.selection.main.head;
    editorView.dispatch({
      changes: { from: 0, to: prevLen, insert: markdown },
    });
    const newLen = editorView.state.doc.length;
    const newCursor = editorView.state.selection.main.head;
    window.__CODEMIRROR_DEBUG__!.lastContentLength = markdown.length;
    debugLog(`setContent DONE, prevLen=${prevLen}, newLen=${newLen}, prevCursor=${prevCursor}, newCursor=${newCursor}`);
  },

  getContent(): string {
    if (!editorView) return '';
    return editorView.state.doc.toString();
  },

  setFocusMode(_enabled: boolean) {
    // Focus mode is WYSIWYG-only; ignore in source mode
    console.log('[CodeMirror] setFocusMode ignored (source mode)');
  },

  getStats() {
    const content = editorView?.state.doc.toString() || '';
    const words = countWords(content);
    const characters = content.length;
    window.__CODEMIRROR_DEBUG__!.lastStatsUpdate = new Date().toISOString();
    return { words, characters };
  },

  scrollToOffset(offset: number) {
    if (!editorView) return;
    const pos = Math.min(offset, editorView.state.doc.length);
    editorView.dispatch({
      effects: EditorView.scrollIntoView(pos, { y: 'start', yMargin: 50 }),
    });
    console.log('[CodeMirror] scrollToOffset:', offset);
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
    propsToRemove.forEach((prop) => root.style.removeProperty(prop));

    // Set new CSS variables
    const pairs = cssVariables.split(';').filter((s) => s.trim());
    pairs.forEach((pair) => {
      const [key, value] = pair.split(':').map((s) => s.trim());
      if (key && value) {
        root.style.setProperty(key, value);
      }
    });
    console.log('[CodeMirror] Theme applied with', pairs.length, 'variables');
  },

  getCursorPosition(): { line: number; column: number } {
    debugLog('getCursorPosition START');
    if (!editorView) {
      debugLog('getCursorPosition: editor not ready, returning line 1 col 0');
      return { line: 1, column: 0 };
    }
    try {
      const pos = editorView.state.selection.main.head;
      const docLen = editorView.state.doc.length;
      const line = editorView.state.doc.lineAt(pos);
      const result = {
        line: line.number, // CodeMirror lines are 1-indexed
        column: pos - line.from,
      };
      debugLog(`getCursorPosition DONE: pos=${pos}, docLen=${docLen}, line=${result.line}, col=${result.column}`);
      return result;
    } catch (e) {
      debugLog(`getCursorPosition error: ${e}`);
      return { line: 1, column: 0 };
    }
  },

  setCursorPosition(lineCol: { line: number; column: number }) {
    debugLog(`setCursorPosition START: line=${lineCol.line}, col=${lineCol.column}`);
    if (!editorView) {
      debugLog('setCursorPosition: editor not ready');
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

      debugLog(`setCursorPosition: lineCount=${lineCount}, safeLine=${safeLine}, safeCol=${safeCol}, pos=${pos}`);

      const cursorBefore = editorView.state.selection.main.head;
      editorView.dispatch({
        selection: { anchor: pos },
        effects: EditorView.scrollIntoView(pos, { y: 'center' }),
      });
      const cursorAfter = editorView.state.selection.main.head;
      debugLog(`setCursorPosition DONE: cursorBefore=${cursorBefore}, cursorAfter=${cursorAfter}`);
      editorView.focus();
    } catch (e) {
      debugLog(`setCursorPosition failed: ${e}`);
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
        console.log('[CodeMirror] scrollCursorToCenter: scrolled to', targetScrollY);
      }
    } catch (e) {
      console.warn('[CodeMirror] scrollCursorToCenter failed:', e);
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
    console.log('[CodeMirror] insertAtCursor: inserted', text.length, 'chars');
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
  setAnnotationDisplayModes(modes: Record<string, string>) {
    // In source mode, annotations are shown as raw markdown text
    // Display modes don't visually change anything, but we log for consistency
    console.log('[CodeMirror] setAnnotationDisplayModes (no-op in source mode):', modes);
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
    console.log('[CodeMirror] scrollToAnnotation:', offset);
  },

  insertAnnotation(type: string) {
    if (!editorView) return;

    const validTypes = ['task', 'comment', 'reference'];
    if (!validTypes.includes(type)) {
      console.warn('[CodeMirror] insertAnnotation: invalid type', type);
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
    console.log('[CodeMirror] insertAnnotation:', type);
  },

  toggleHighlight(): boolean {
    if (!editorView) return false;

    const { from, to } = editorView.state.selection.main;

    // Require a selection
    if (from === to) {
      console.log('[CodeMirror] toggleHighlight: no selection');
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
      console.log('[CodeMirror] toggleHighlight: removed');
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
      console.log('[CodeMirror] toggleHighlight: removed (included delimiters)');
      return true;
    }

    // Add highlight
    const highlighted = `==${selectedText}==`;
    editorView.dispatch({
      changes: { from, to, insert: highlighted },
      selection: { anchor: from + 2, head: to + 2 },
    });
    editorView.focus();
    console.log('[CodeMirror] toggleHighlight: added');
    return true;
  },

  // Citation API (CAYW picker callbacks)
  citationPickerCallback(data: any, _items: any[]) {
    console.log('[CodeMirror] citationPickerCallback:', data);
    console.log('[CodeMirror] pendingAppendMode:', pendingAppendMode, 'pendingAppendRange:', pendingAppendRange);

    if (!editorView) {
      console.warn('[CodeMirror] citationPickerCallback: no editor');
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

      console.log('[CodeMirror] Append mode - existing:', existing, 'new:', rawSyntax, 'merged:', merged);

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
      console.warn('[CodeMirror] citationPickerCallback: no pending range');
      return;
    }

    const { start, end } = pendingCAYWRange;
    pendingCAYWRange = null;

    // Build Pandoc citation syntax: [@citekey1; @citekey2]
    const citekeys = data.citekeys as string[];
    const rawSyntax = (data.rawSyntax as string) || `[@${citekeys.join('; @')}]`;

    console.log('[CodeMirror] Inserting citation:', rawSyntax);

    // Replace /cite with the citation syntax
    editorView.dispatch({
      changes: { from: start, to: end, insert: rawSyntax },
      selection: { anchor: start + rawSyntax.length },
    });
    editorView.focus();
  },

  citationPickerCancelled() {
    console.log('[CodeMirror] citationPickerCancelled');
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
};

// Initialize on DOM ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initEditor);
} else {
  initEditor();
}

console.log('[CodeMirror] window.FinalFinal API registered');
