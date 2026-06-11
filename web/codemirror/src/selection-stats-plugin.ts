// Selection Stats Plugin for CodeMirror
// Pushes the currently selected markdown source to Swift via the
// `selectionChanged` message handler so the status bar can show a live
// selection word count. Swift counts with MarkdownUtils.wordCount — the same
// markdown-aware rules as the document total.
//
// Debounced (150ms) and deduplicated: an unchanged selection sends nothing,
// a collapsed selection sends '' once so Swift clears the count.

import { type EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';

const DEBOUNCE_MS = 150;
let lastSent: string | null = null;

function postSelection(text: string): void {
  if (text === lastSent) return;
  lastSent = text;
  (
    window as unknown as { webkit?: { messageHandlers?: { selectionChanged?: { postMessage: (m: string) => void } } } }
  ).webkit?.messageHandlers?.selectionChanged?.postMessage(text);
}

export const selectionStatsPlugin = ViewPlugin.fromClass(
  class {
    private view: EditorView;
    private debounceTimer: ReturnType<typeof setTimeout> | null = null;

    constructor(view: EditorView) {
      this.view = view;
    }

    update(update: ViewUpdate) {
      if (!update.selectionSet && !update.docChanged) return;
      if (this.debounceTimer) clearTimeout(this.debounceTimer);
      this.debounceTimer = setTimeout(() => {
        this.debounceTimer = null;
        const { from, to } = this.view.state.selection.main;
        postSelection(from === to ? '' : this.view.state.sliceDoc(from, to));
      }, DEBOUNCE_MS);
    }

    destroy() {
      if (this.debounceTimer) clearTimeout(this.debounceTimer);
      postSelection('');
    }
  }
);
