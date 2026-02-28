import {
  findNext as cmFindNext,
  findPrevious as cmFindPrevious,
  replaceAll as cmReplaceAll,
  getSearchQuery,
  replaceNext,
  SearchQuery,
  setSearchQuery,
} from '@codemirror/search';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { stripAnchors } from './anchor-plugin';
import { hideCitationAddButton, mergeCitations } from './citations';
import {
  getCitationAddButton,
  getCurrentMatchIndex,
  getCurrentSearchOptions,
  getCurrentSearchQuery,
  getDocumentFootnoteCount,
  getEditorExtensions,
  getEditorView,
  getIsZoomMode,
  getPendingAppendMode,
  getPendingAppendRange,
  getPendingCAYWRange,
  setCurrentMatchIndex,
  setCurrentSearchOptions,
  setCurrentSearchQuery,
  setPendingAppendMode,
  setPendingAppendRange,
  setPendingCAYWRange,
  setPendingSlashUndo,
  setZoomFootnoteState,
} from './editor-state';
import { setFocusModeEffect, setFocusModeEnabled } from './focus-mode-plugin';
import { dismissImageCaptionPopup } from './image-caption-popup';
import { installLineHeightFix, invalidateHeadingMetricsCache } from './line-height-fix';
import type { AnnotationType, FindOptions, FindResult, ParsedAnnotation, SearchState } from './types';

// --- Search helpers ---

export function countMatches(view: EditorView, query: SearchQuery): number {
  let count = 0;
  const cursor = query.getCursor(view.state.doc);
  while (!cursor.next().done) {
    count++;
  }
  return count;
}

export function findCurrentMatchIndex(view: EditorView, query: SearchQuery): number {
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

// --- Editor utilities ---

export function wrapSelection(wrapper: string): void {
  const view = getEditorView();
  if (!view) return;
  const { from, to } = view.state.selection.main;
  const selected = view.state.sliceDoc(from, to);
  const wrapped = wrapper + selected + wrapper;
  view.dispatch({
    changes: { from, to, insert: wrapped },
    selection: { anchor: from + wrapper.length, head: to + wrapper.length },
  });
}

export function insertLink(): void {
  const view = getEditorView();
  if (!view) return;
  const { from, to } = view.state.selection.main;
  const selected = view.state.sliceDoc(from, to);
  const linkText = selected || 'link text';
  const inserted = `[${linkText}](url)`;
  view.dispatch({
    changes: { from, to, insert: inserted },
    selection: { anchor: from + 1, head: from + 1 + linkText.length },
  });
}

export function countWords(text: string): number {
  // Strip annotations before counting (<!-- ::type:: content -->)
  const strippedText = text.replace(/<!--\s*::\w+::\s*[\s\S]*?-->/g, '');
  return strippedText.split(/\s+/).filter((w) => w.length > 0).length;
}

// --- API implementations ---

export function setContent(markdown: string, options?: { scrollToStart?: boolean }): void {
  const view = getEditorView();
  if (!view) return;

  dismissImageCaptionPopup();

  const prevLen = view.state.doc.length;
  view.dispatch({
    changes: { from: 0, to: prevLen, insert: markdown },
  });

  // Force CodeMirror to re-measure line heights after content change.
  // Heading decorations change font-size on heading lines, but only for
  // visibleRanges. Without this, off-viewport heading heights are
  // underestimated, causing blank gaps in the virtual viewport.
  requestAnimationFrame(() => {
    view.requestMeasure();
  });

  // Reset scroll position for zoom transitions
  // Swift handles hiding/showing the WKWebView at compositor level
  if (options?.scrollToStart) {
    // Reset scroll immediately
    view.dom.scrollTop = 0;
    window.scrollTo({ top: 0, left: 0, behavior: 'instant' });

    // Force layout calculation
    void view.dom.offsetHeight;
    void document.body.offsetHeight;

    // Wait for actual paint to complete using double RAF
    // First RAF: queued after current frame
    // Second RAF: queued after the paint of the first frame
    // This ensures the browser has actually rendered the content
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        // CRITICAL: Force compositor refresh with micro-scroll
        // WKWebView's compositor caches the previous content.
        // A scroll triggers compositor refresh, showing the new content.
        window.scrollTo({ top: 1, left: 0, behavior: 'instant' });
        window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
        view.dom.scrollTop = 0;

        // Signal Swift that paint is complete
        if (typeof (window as any).webkit?.messageHandlers?.paintComplete?.postMessage === 'function') {
          (window as any).webkit.messageHandlers.paintComplete.postMessage({
            scrollHeight: document.body.scrollHeight,
            timestamp: Date.now(),
          });
        }
      });
    });
  }
}

export function getContent(): string {
  // Returns content with anchors stripped (default for backwards compatibility)
  const view = getEditorView();
  if (!view) return '';
  return stripAnchors(view.state.doc.toString());
}

export function getContentClean(): string {
  // Explicitly returns content with anchors stripped
  const view = getEditorView();
  if (!view) return '';
  return stripAnchors(view.state.doc.toString());
}

export function getContentRaw(): string {
  // Returns content including hidden anchors (for internal use during mode switch)
  const view = getEditorView();
  if (!view) return '';
  return view.state.doc.toString();
}

export function setFocusMode(enabled: boolean): void {
  setFocusModeEnabled(enabled);
  const view = getEditorView();
  if (view) {
    view.dispatch({ effects: setFocusModeEffect.of(enabled) });
  }
}

export function getCurrentSectionTitle(): string | null {
  const view = getEditorView();
  if (!view) return null;

  try {
    const cursor = view.state.selection.main.head;
    const doc = view.state.doc;
    const cursorLine = doc.lineAt(cursor);

    // Scan backwards from cursor line for a heading
    for (let lineNum = cursorLine.number; lineNum >= 1; lineNum--) {
      const line = doc.line(lineNum);
      const cleanText = stripAnchors(line.text);
      const match = cleanText.match(/^#{1,6}\s+(.+)/);
      if (match) {
        return match[1].trim();
      }
    }

    return null;
  } catch {
    return null;
  }
}

export function getStats(): { words: number; characters: number } {
  const view = getEditorView();
  // Use stripped content for accurate word/char counts (exclude hidden anchors and annotations)
  const rawContent = view?.state.doc.toString() || '';
  const content = stripAnchors(rawContent);
  // Strip annotations before counting (<!-- ::type:: content -->)
  let strippedContent = content.replace(/<!--\s*::\w+::\s*[\s\S]*?-->/g, '');
  // Strip caption comments (metadata, not body text)
  strippedContent = strippedContent.replace(/<!--\s*caption:\s*.+?\s*-->/g, '');
  const words = countWords(strippedContent);
  const characters = strippedContent.length;
  return { words, characters };
}

export function scrollToOffset(offset: number): void {
  const view = getEditorView();
  if (!view) return;
  const pos = Math.min(offset, view.state.doc.length);
  view.dispatch({
    effects: EditorView.scrollIntoView(pos, { y: 'start', yMargin: 50 }),
  });
}

export function setTheme(cssVariables: string): void {
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

  // Heading CSS variables may have changed — invalidate cached metrics
  invalidateHeadingMetricsCache();
}

export function getCursorPosition(): { line: number; column: number } {
  const view = getEditorView();
  if (!view) {
    return { line: 1, column: 0 };
  }
  try {
    const pos = view.state.selection.main.head;
    const line = view.state.doc.lineAt(pos);
    return {
      line: line.number, // CodeMirror lines are 1-indexed
      column: pos - line.from,
    };
  } catch (_e) {
    return { line: 1, column: 0 };
  }
}

export function setCursorPosition(lineCol: { line: number; column: number }): void {
  const view = getEditorView();
  if (!view) return;
  try {
    const { line, column } = lineCol;

    // Clamp line to valid range
    const lineCount = view.state.doc.lines;
    const safeLine = Math.max(1, Math.min(line, lineCount));

    const lineInfo = view.state.doc.line(safeLine);
    const maxCol = lineInfo.length;
    const safeCol = Math.max(0, Math.min(column, maxCol));

    const pos = lineInfo.from + safeCol;

    view.dispatch({
      selection: { anchor: pos },
      effects: EditorView.scrollIntoView(pos, { y: 'center' }),
    });
    view.focus();
  } catch (_e) {
    // Cursor positioning failed
  }
}

export function scrollCursorToCenter(): void {
  const view = getEditorView();
  if (!view) return;
  try {
    const pos = view.state.selection.main.head;
    const coords = view.coordsAtPos(pos);
    if (coords) {
      const viewportHeight = window.innerHeight;
      const targetScrollY = coords.top + window.scrollY - viewportHeight / 2;
      window.scrollTo({ top: Math.max(0, targetScrollY), behavior: 'instant' });
    }
  } catch (_e) {
    // Scroll failed
  }
}

export function insertAtCursor(text: string): void {
  const view = getEditorView();
  if (!view) return;
  const { from, to } = view.state.selection.main;
  view.dispatch({
    changes: { from, to, insert: text },
    selection: { anchor: from + text.length },
  });
  view.focus();
}

export function insertBreak(): void {
  // Insert a pseudo-section break marker
  insertAtCursor('\n\n<!-- ::break:: -->\n\n');
}

export function focusEditor(): void {
  const view = getEditorView();
  if (!view) return;
  view.focus();
}

export function initialize(options: {
  content: string;
  theme: string;
  cursorPosition: { line: number; column: number } | null;
}): void {
  // Apply theme first
  setTheme(options.theme);

  // Set content
  setContent(options.content);

  // Restore cursor position if provided
  if (options.cursorPosition) {
    setCursorPosition(options.cursorPosition);
    scrollCursorToCenter();
  }

  // Focus the editor
  focusEditor();
}

// --- Annotation API ---

export function setAnnotationDisplayModes(_modes: Record<string, string>): void {
  // In source mode, annotations are shown as raw markdown text
  // Display modes don't visually change anything
}

export function getAnnotations(): ParsedAnnotation[] {
  const view = getEditorView();
  if (!view) return [];

  const content = view.state.doc.toString();
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
}

export function scrollToAnnotation(offset: number): void {
  const view = getEditorView();
  if (!view) return;
  const pos = Math.min(offset, view.state.doc.length);
  view.dispatch({
    selection: { anchor: pos },
    effects: EditorView.scrollIntoView(pos, { y: 'center', yMargin: 100 }),
  });
  view.focus();
}

export function insertAnnotation(type: string): void {
  const view = getEditorView();
  if (!view) return;

  const validTypes = ['task', 'comment', 'reference'];
  if (!validTypes.includes(type)) {
    return;
  }

  const { from, to } = view.state.selection.main;
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

  view.dispatch({
    changes: { from, to, insert: insertText },
    selection: { anchor: from + cursorOffset },
  });
  view.focus();
}

// --- Footnote API ---

/**
 * Insert a footnote reference at the given position (or current cursor).
 * Assigns sequential label based on cursor position among existing refs,
 * renumbers subsequent refs and defs in one atomic dispatch.
 */
export function insertFootnote(atPosition?: number): string | null {
  const view = getEditorView();
  if (!view) return null;

  const insertPos = atPosition ?? view.state.selection.main.from;

  // Zoom mode: use next document-level label, no renumbering
  if (getIsZoomMode()) {
    const currentMax = getDocumentFootnoteCount();
    const newLabel = currentMax + 1;
    setZoomFootnoteState(true, newLabel);

    view.dispatch({
      changes: { from: insertPos, insert: `[^${newLabel}]` },
      selection: { anchor: insertPos + `[^${newLabel}]`.length },
    });
    view.focus();

    if (typeof (window as any).webkit?.messageHandlers?.footnoteInserted?.postMessage === 'function') {
      (window as any).webkit.messageHandlers.footnoteInserted.postMessage({ label: String(newLabel) });
    }

    return String(newLabel);
  }

  const content = view.state.doc.toString();

  // Collect all existing refs with positions (exclude definitions [^N]:)
  const refRegex = /\[\^(\d+)\](?!:)/g;
  const existingRefs: Array<{ from: number; to: number; label: number }> = [];
  let match;
  while ((match = refRegex.exec(content)) !== null) {
    existingRefs.push({ from: match.index, to: match.index + match[0].length, label: parseInt(match[1], 10) });
  }
  existingRefs.sort((a, b) => a.from - b.from);

  // Count refs before cursor = insertion index
  const insertionIndex = existingRefs.filter((r) => r.from < insertPos).length;
  const newLabel = insertionIndex + 1;

  // Build changes array (all positions relative to original doc)
  const changes: Array<{ from: number; to: number; insert: string }> = [];

  // Rename refs [^N] → [^N+1] where N >= newLabel
  for (const ref of existingRefs) {
    if (ref.label >= newLabel) {
      changes.push({ from: ref.from, to: ref.to, insert: `[^${ref.label + 1}]` });
    }
  }

  // Rename def prefixes [^N]: → [^N+1]: where N >= newLabel
  const defRegex = /\[\^(\d+)\]:/g;
  while ((match = defRegex.exec(content)) !== null) {
    const defLabel = parseInt(match[1], 10);
    if (defLabel >= newLabel) {
      changes.push({ from: match.index, to: match.index + match[0].length, insert: `[^${defLabel + 1}]:` });
    }
  }

  // Insert the new footnote ref at cursor
  changes.push({ from: insertPos, to: insertPos, insert: `[^${newLabel}]` });

  // Sort forward (CodeMirror applies simultaneously)
  changes.sort((a, b) => a.from - b.from);

  view.dispatch({
    changes,
    selection: { anchor: insertPos + `[^${newLabel}]`.length },
  });
  view.focus();

  // Notify Swift immediately via postMessage (works for slash commands AND keyboard shortcuts)
  if (typeof (window as any).webkit?.messageHandlers?.footnoteInserted?.postMessage === 'function') {
    (window as any).webkit.messageHandlers.footnoteInserted.postMessage({ label: String(newLabel) });
  }

  return String(newLabel);
}

/**
 * Insert a footnote reference while simultaneously replacing a range (e.g. slash command text).
 * All operations happen in a single CodeMirror dispatch for atomic undo.
 */
export function insertFootnoteReplacingRange(from: number, to: number): string | null {
  const view = getEditorView();
  if (!view) return null;

  // Zoom mode: use next document-level label, no renumbering
  if (getIsZoomMode()) {
    const currentMax = getDocumentFootnoteCount();
    const newLabel = currentMax + 1;
    setZoomFootnoteState(true, newLabel);

    view.dispatch({
      changes: { from, to, insert: `[^${newLabel}]` },
      selection: { anchor: from + `[^${newLabel}]`.length },
    });
    view.focus();

    if (typeof (window as any).webkit?.messageHandlers?.footnoteInserted?.postMessage === 'function') {
      (window as any).webkit.messageHandlers.footnoteInserted.postMessage({ label: String(newLabel) });
    }

    return String(newLabel);
  }

  const content = view.state.doc.toString();

  // Collect all existing refs with positions (exclude definitions [^N]:)
  const refRegex = /\[\^(\d+)\](?!:)/g;
  const existingRefs: Array<{ from: number; to: number; label: number }> = [];
  let match;
  while ((match = refRegex.exec(content)) !== null) {
    existingRefs.push({ from: match.index, to: match.index + match[0].length, label: parseInt(match[1], 10) });
  }
  existingRefs.sort((a, b) => a.from - b.from);

  // Count refs before the insertion point = insertion index
  const insertionIndex = existingRefs.filter((r) => r.from < from).length;
  const newLabel = insertionIndex + 1;

  // Build changes array (all positions relative to original doc)
  const changes: Array<{ from: number; to: number; insert: string }> = [];

  // Rename refs [^N] → [^N+1] where N >= newLabel
  for (const ref of existingRefs) {
    if (ref.label >= newLabel) {
      changes.push({ from: ref.from, to: ref.to, insert: `[^${ref.label + 1}]` });
    }
  }

  // Rename def prefixes [^N]: → [^N+1]: where N >= newLabel
  const defRegex = /\[\^(\d+)\]:/g;
  while ((match = defRegex.exec(content)) !== null) {
    const defLabel = parseInt(match[1], 10);
    if (defLabel >= newLabel) {
      changes.push({ from: match.index, to: match.index + match[0].length, insert: `[^${defLabel + 1}]:` });
    }
  }

  // Replace the slash command range with the new footnote ref
  changes.push({ from, to, insert: `[^${newLabel}]` });

  // Sort forward (CodeMirror applies simultaneously)
  changes.sort((a, b) => a.from - b.from);

  view.dispatch({
    changes,
    selection: { anchor: from + `[^${newLabel}]`.length },
  });
  view.focus();

  // Notify Swift immediately via postMessage (works for slash commands AND keyboard shortcuts)
  if (typeof (window as any).webkit?.messageHandlers?.footnoteInserted?.postMessage === 'function') {
    (window as any).webkit.messageHandlers.footnoteInserted.postMessage({ label: String(newLabel) });
  }

  return String(newLabel);
}

/**
 * Scroll to and focus the footnote definition [^N]: in the Notes section.
 */
export function scrollToFootnoteDefinition(label: string): void {
  const view = getEditorView();
  if (!view) return;

  const content = view.state.doc.toString();
  const searchText = `[^${label}]:`;
  const idx = content.indexOf(searchText);
  if (idx === -1) return;

  // Position cursor after "[^N]: " prefix for immediate typing
  const cursorPos = Math.min(idx + searchText.length + 1, content.length);

  view.dispatch({
    selection: { anchor: cursorPos },
    effects: EditorView.scrollIntoView(cursorPos, { y: 'center', yMargin: 100 }),
  });
  view.focus();
}

/**
 * Renumber footnote references and definitions using a mapping of old → new labels.
 * Uses targeted CodeMirror changes to preserve cursor position.
 */
export function renumberFootnotes(mapping: Record<string, string>): void {
  const view = getEditorView();
  if (!view) return;

  const content = view.state.doc.toString();
  const changes: Array<{ from: number; to: number; insert: string }> = [];

  // Find all [^N] occurrences (both refs and defs) and apply mapping
  for (const [oldLabel, newLabel] of Object.entries(mapping)) {
    const regex = new RegExp(`\\[\\^${oldLabel}\\]`, 'g');
    let match;
    while ((match = regex.exec(content)) !== null) {
      changes.push({
        from: match.index,
        to: match.index + match[0].length,
        insert: `[^${newLabel}]`,
      });
    }
  }

  if (changes.length > 0) {
    // Sort by position for correct application
    changes.sort((a, b) => a.from - b.from);
    view.dispatch({ changes });
  }
}

// --- Image API ---

/**
 * Insert an image at the current cursor position.
 * Inserts markdown: ![alt](src) with optional <!-- caption: text --> prefix.
 * Ensures blank lines before/after for proper block separation.
 */
export function insertImage(opts: { src: string; alt?: string; caption?: string }): void {
  const view = getEditorView();
  if (!view) return;

  const { from } = view.state.selection.main;
  const doc = view.state.doc;

  // Build the markdown to insert
  let markdown = `![${opts.alt || ''}](${opts.src})`;

  // Add caption comment before image if present
  if (opts.caption) {
    markdown = `<!-- caption: ${opts.caption} -->\n${markdown}`;
  }

  // Check if we need blank lines before
  const line = doc.lineAt(from);
  const lineText = line.text;
  const needBlankBefore = line.number > 1 && lineText.trim() !== '';
  const needBlankAfter = line.number < doc.lines && doc.line(line.number + 1).text.trim() !== '';

  let insert = '';
  if (needBlankBefore) {
    insert += '\n\n';
  }
  insert += markdown;
  if (needBlankAfter) {
    insert += '\n\n';
  } else {
    insert += '\n';
  }

  const insertFrom = needBlankBefore ? from : line.from;

  view.dispatch({
    changes: { from: insertFrom, to: from, insert },
    selection: { anchor: insertFrom + insert.length },
  });
  view.focus();
}

// --- Highlight API ---

export function toggleHighlight(): boolean {
  const view = getEditorView();
  if (!view) return false;

  const { from, to } = view.state.selection.main;

  // Require a selection
  if (from === to) {
    return false;
  }

  const selectedText = view.state.sliceDoc(from, to);

  // Check if already highlighted (wrapped in ==)
  const beforeStart = from >= 2 ? view.state.sliceDoc(from - 2, from) : '';
  const afterEnd = to + 2 <= view.state.doc.length ? view.state.sliceDoc(to, to + 2) : '';

  if (beforeStart === '==' && afterEnd === '==') {
    // Remove highlight - delete the surrounding ==
    view.dispatch({
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
    view.dispatch({
      changes: { from, to, insert: innerText },
      selection: { anchor: from, head: from + innerText.length },
    });
    return true;
  }

  // Add highlight
  const highlighted = `==${selectedText}==`;
  view.dispatch({
    changes: { from, to, insert: highlighted },
    selection: { anchor: from + 2, head: to + 2 },
  });
  view.focus();
  return true;
}

// --- Citation picker callbacks ---

export function citationPickerCallback(data: any, _items: any[]): void {
  const view = getEditorView();
  if (!view) {
    setPendingCAYWRange(null);
    setPendingAppendMode(false);
    setPendingAppendRange(null);
    return;
  }

  // Check for append mode - merging new citations with existing ones
  if (getPendingAppendMode() && getPendingAppendRange()) {
    const { start, end } = getPendingAppendRange()!;
    const existing = view.state.sliceDoc(start, end);
    const rawSyntax = (data.rawSyntax as string) || `[@${(data.citekeys as string[]).join('; @')}]`;
    const merged = mergeCitations(existing, rawSyntax);

    view.dispatch({
      changes: { from: start, to: end, insert: merged },
      selection: { anchor: start + merged.length },
    });
    view.focus();

    setPendingAppendMode(false);
    setPendingAppendRange(null);
    hideCitationAddButton();
    return;
  }

  // Normal insertion mode
  const range = getPendingCAYWRange();
  if (!range) {
    return;
  }

  const { start, end } = range;
  setPendingCAYWRange(null);

  // Build Pandoc citation syntax: [@citekey1; @citekey2]
  const citekeys = data.citekeys as string[];
  const rawSyntax = (data.rawSyntax as string) || `[@${citekeys.join('; @')}]`;

  // Replace /cite with the citation syntax
  view.dispatch({
    changes: { from: start, to: end, insert: rawSyntax },
    selection: { anchor: start + rawSyntax.length },
  });
  view.focus();
}

export function citationPickerCancelled(): void {
  const view = getEditorView();
  if (view) {
    const range = getPendingCAYWRange();
    if (range) {
      const { start, end } = range;
      const docLength = view.state.doc.length;
      if (start >= 0 && end <= docLength && start <= end) {
        const textAtRange = view.state.doc.sliceString(start, end);
        if (textAtRange.startsWith('/')) {
          view.dispatch({ changes: { from: start, to: end } });
        }
      }
    }
    view.focus();
  }
  setPendingCAYWRange(null);
  setPendingAppendMode(false);
  setPendingAppendRange(null);
}

export function citationPickerError(message: string): void {
  console.error('[CodeMirror] citationPickerError:', message);
  const view = getEditorView();
  if (view) {
    const range = getPendingCAYWRange();
    if (range) {
      const { start, end } = range;
      const docLength = view.state.doc.length;
      if (start >= 0 && end <= docLength && start <= end) {
        const textAtRange = view.state.doc.sliceString(start, end);
        if (textAtRange.startsWith('/')) {
          view.dispatch({ changes: { from: start, to: end } });
        }
      }
    }
    view.focus();
  }
  setPendingCAYWRange(null);
  setPendingAppendMode(false);
  setPendingAppendRange(null);
  // Error display handled by native NSAlert on Swift side.
}

// --- Find/replace API ---

export function find(query: string, options?: FindOptions): FindResult {
  const view = getEditorView();
  if (!view) {
    return { matchCount: 0, currentIndex: 0 };
  }

  setCurrentSearchQuery(query);
  setCurrentSearchOptions(options || {});

  if (!query) {
    // Clear search
    clearSearch();
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
  view.dispatch({
    effects: setSearchQuery.of(searchQuery),
  });

  // Count matches
  const matchCount = countMatches(view, searchQuery);

  // Find current match index based on cursor position
  const idx = matchCount > 0 ? findCurrentMatchIndex(view, searchQuery) : 0;
  setCurrentMatchIndex(idx);

  return { matchCount, currentIndex: idx };
}

export function apiFindNext(): FindResult | null {
  const view = getEditorView();
  if (!view || !getCurrentSearchQuery()) {
    return null;
  }

  // Execute findNext command
  cmFindNext(view);

  // Get current query and recalculate
  const searchQuery = getSearchQuery(view.state);
  const matchCount = countMatches(view, searchQuery);
  const idx = matchCount > 0 ? findCurrentMatchIndex(view, searchQuery) : 0;
  setCurrentMatchIndex(idx);

  return { matchCount, currentIndex: idx };
}

export function apiFindPrevious(): FindResult | null {
  const view = getEditorView();
  if (!view || !getCurrentSearchQuery()) {
    return null;
  }

  // Execute findPrevious command
  cmFindPrevious(view);

  // Get current query and recalculate
  const searchQuery = getSearchQuery(view.state);
  const matchCount = countMatches(view, searchQuery);
  const idx = matchCount > 0 ? findCurrentMatchIndex(view, searchQuery) : 0;
  setCurrentMatchIndex(idx);

  return { matchCount, currentIndex: idx };
}

export function replaceCurrent(replacement: string): boolean {
  const view = getEditorView();
  if (!view || !getCurrentSearchQuery()) {
    return false;
  }

  // Update the search query with replacement
  const searchQuery = new SearchQuery({
    search: getCurrentSearchQuery(),
    caseSensitive: getCurrentSearchOptions().caseSensitive ?? false,
    regexp: getCurrentSearchOptions().regexp ?? false,
    wholeWord: getCurrentSearchOptions().wholeWord ?? false,
    replace: replacement,
  });

  view.dispatch({
    effects: setSearchQuery.of(searchQuery),
  });

  // Execute replaceNext command
  return replaceNext(view);
}

export function apiReplaceAll(replacement: string): number {
  const view = getEditorView();
  if (!view || !getCurrentSearchQuery()) {
    return 0;
  }

  // Count matches before replacement
  const searchQuery = new SearchQuery({
    search: getCurrentSearchQuery(),
    caseSensitive: getCurrentSearchOptions().caseSensitive ?? false,
    regexp: getCurrentSearchOptions().regexp ?? false,
    wholeWord: getCurrentSearchOptions().wholeWord ?? false,
    replace: replacement,
  });

  const beforeCount = countMatches(view, searchQuery);

  view.dispatch({
    effects: setSearchQuery.of(searchQuery),
  });

  // Execute replaceAll command
  cmReplaceAll(view);

  // Return the number of replacements made
  return beforeCount;
}

export function clearSearch(): void {
  const view = getEditorView();
  if (!view) return;

  setCurrentSearchQuery('');
  setCurrentSearchOptions({});
  setCurrentMatchIndex(0);

  // Clear search by setting empty query
  const emptyQuery = new SearchQuery({ search: '' });
  view.dispatch({
    effects: setSearchQuery.of(emptyQuery),
  });
}

export function apiGetSearchState(): SearchState | null {
  const view = getEditorView();
  if (!view || !getCurrentSearchQuery()) {
    return null;
  }

  const searchQuery = getSearchQuery(view.state);
  const matchCount = countMatches(view, searchQuery);

  return {
    query: getCurrentSearchQuery(),
    matchCount,
    currentIndex: getCurrentMatchIndex(),
    options: getCurrentSearchOptions(),
  };
}

// --- Project switch ---

export function resetForProjectSwitch(): void {
  const view = getEditorView();
  if (!view) return;

  dismissImageCaptionPopup();

  // Clear transient module-level state
  setPendingSlashUndo(false);
  setZoomFootnoteState(false, 0);
  setPendingCAYWRange(null);
  setPendingAppendMode(false);
  setPendingAppendRange(null);
  setCurrentSearchQuery('');
  setCurrentSearchOptions({});
  setCurrentMatchIndex(0);
  const button = getCitationAddButton();
  if (button) button.style.display = 'none';

  // Create fresh EditorState (clears undo history, selection, search state)
  const newState = EditorState.create({
    doc: view.state.doc, // Keep current content (will be replaced by setContent)
    extensions: getEditorExtensions(),
  });
  view.setState(newState);
  installLineHeightFix(view);
}
