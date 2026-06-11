// Selection Stats Plugin for CodeMirror
// Pushes the currently selected markdown source to Swift via the
// `selectionChanged` message handler so the status bar can show a live
// selection word count. Swift counts with MarkdownUtils.wordCount — the same
// markdown-aware rules as the document total.
//
// Debounced (150ms) and deduplicated: an unchanged selection sends nothing,
// a collapsed selection sends '' once so Swift clears the count.

import { type EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import { postSelection, SELECTION_DEBOUNCE_MS } from '../../shared/selection-stats';

export const selectionStatsPlugin = ViewPlugin.fromClass(
  class {
    private debounceTimer: ReturnType<typeof setTimeout> | null = null;

    constructor(private view: EditorView) {}

    update(update: ViewUpdate) {
      if (!update.selectionSet && !update.docChanged) return;
      if (this.debounceTimer) clearTimeout(this.debounceTimer);
      this.debounceTimer = setTimeout(() => {
        this.debounceTimer = null;
        const { from, to } = this.view.state.selection.main;
        postSelection(from === to ? '' : this.view.state.sliceDoc(from, to));
      }, SELECTION_DEBOUNCE_MS);
    }

    destroy() {
      if (this.debounceTimer) clearTimeout(this.debounceTimer);
      postSelection('');
    }
  }
);
