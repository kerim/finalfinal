// Selection Toolbar Plugin for CodeMirror
// Shows a floating format bar when text is selected

import { syntaxTree } from '@codemirror/language';
import type { EditorState } from '@codemirror/state';
import { type EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import { type ActiveFormats, hideToolbar, type SelectionRect, showToolbar } from '../../shared/selection-toolbar';

function getSelectionRect(view: EditorView): SelectionRect | null {
  const { from, to } = view.state.selection.main;
  const start = view.coordsAtPos(from);
  const end = view.coordsAtPos(to);

  if (!start || !end) return null;

  return {
    top: Math.min(start.top, end.top),
    left: Math.min(start.left, end.left),
    right: Math.max(start.right, end.right),
    bottom: Math.max(start.bottom, end.bottom),
    width: Math.abs(end.right - start.left),
  };
}

function getActiveFormats(state: EditorState): ActiveFormats {
  const formats: ActiveFormats = {};
  const { from, to } = state.selection.main;
  const tree = syntaxTree(state);

  // Check inline marks by inspecting syntax tree at cursor
  const cursor = from;

  // Walk the tree at the cursor position
  let node = tree.resolveInner(cursor, -1);
  while (node) {
    switch (node.name) {
      case 'StrongEmphasis':
        formats.bold = true;
        break;
      case 'Emphasis':
        formats.italic = true;
        break;
      case 'Strikethrough':
        formats.strikethrough = true;
        break;
    }
    node = node.parent;
  }

  // Check block-level formatting from the line
  const line = state.doc.lineAt(from);
  const lineText = line.text;

  // Heading detection
  const headingMatch = lineText.match(/^(#{1,6})\s/);
  if (headingMatch) {
    formats.heading = headingMatch[1].length;
  } else {
    formats.heading = 0;
  }

  // List detection
  if (/^\s*- /.test(lineText)) {
    formats.bulletList = true;
  }
  if (/^\s*\d+\.\s/.test(lineText)) {
    formats.numberList = true;
  }

  // Blockquote detection
  if (/^>\s?/.test(lineText)) {
    formats.blockquote = true;
  }

  // Code block detection: check if we're between ``` fences
  let inCodeBlock = false;
  for (let i = 1; i <= state.doc.lines; i++) {
    const l = state.doc.line(i);
    if (/^```/.test(l.text)) {
      inCodeBlock = !inCodeBlock;
    }
    if (l.from <= from && from <= l.to && inCodeBlock) {
      formats.codeBlock = true;
      break;
    }
    if (l.from > from) break;
  }

  // Highlight detection: check if cursor is within ==...==
  const docText = state.sliceDoc(Math.max(0, from - 200), Math.min(state.doc.length, to + 200));
  const offset = Math.max(0, from - 200);
  const localFrom = from - offset;
  // Simple heuristic: check if there's == before and after cursor in nearby text
  const textBefore = docText.slice(0, localFrom);
  const textAfter = docText.slice(localFrom);
  const lastOpenHighlight = textBefore.lastIndexOf('==');
  if (lastOpenHighlight !== -1) {
    const closeHighlight = textAfter.indexOf('==');
    if (closeHighlight !== -1) {
      // Verify it's not a false positive (e.g., multiple == in different contexts)
      const between = textBefore.slice(lastOpenHighlight + 2);
      if (!between.includes('==')) {
        formats.highlight = true;
      }
    }
  }

  return formats;
}

export const selectionToolbarPlugin = ViewPlugin.fromClass(
  class {
    private view: EditorView;
    private debounceTimer: ReturnType<typeof setTimeout> | null = null;
    private selectionHandler: () => void;

    constructor(view: EditorView) {
      this.view = view;
      this.selectionHandler = () => this.checkSelection();
      document.addEventListener('selectionchange', this.selectionHandler);
    }

    private checkSelection() {
      if (this.debounceTimer) clearTimeout(this.debounceTimer);
      this.debounceTimer = setTimeout(() => {
        const { from, to } = this.view.state.selection.main;
        if (from === to) {
          hideToolbar();
          return;
        }
        const rect = getSelectionRect(this.view);
        if (!rect) {
          hideToolbar();
          return;
        }
        const formats = getActiveFormats(this.view.state);
        showToolbar(rect, formats);
      }, 50);
    }

    update(update: ViewUpdate) {
      if (!update.selectionSet && !update.docChanged) return;
      this.checkSelection();
    }

    destroy() {
      document.removeEventListener('selectionchange', this.selectionHandler);
      if (this.debounceTimer) clearTimeout(this.debounceTimer);
      hideToolbar();
    }
  }
);
