// Selection Stats Plugin for Milkdown
// Pushes the currently selected text to Swift via the `selectionChanged`
// message handler so the status bar can show a live selection word count.
// Swift counts the text with MarkdownUtils.wordCount — the same rules as the
// document total — so the two numbers always agree.
//
// Debounced (150ms) and deduplicated: an unchanged selection sends nothing,
// a collapsed selection sends '' once so Swift clears the count.

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import { postSelection, SELECTION_DEBOUNCE_MS } from '../../shared/selection-stats';

const selectionStatsKey = new PluginKey('selection-stats');

let debounceTimer: ReturnType<typeof setTimeout> | null = null;

/**
 * Text stand-in for atom leaf nodes inside a selection. Citations become
 * `@citekey` tokens so MarkdownUtils counts them exactly like the document
 * total does (2 words per citation); other atoms contribute nothing.
 */
function leafText(leaf: Node): string {
  if (leaf.type.name === 'citation') {
    const citekeys = (leaf.attrs as { citekeys?: string }).citekeys ?? '';
    return citekeys
      .split(',')
      .filter((k) => k.trim())
      .map((k) => `@${k.trim()}`)
      .join(' ');
  }
  return '';
}

/** Extract the selected text. Exported for testing. */
export function selectedText(view: EditorView): string {
  const { selection } = view.state;
  if (selection.empty) return '';
  return view.state.doc.textBetween(selection.from, selection.to, '\n', leafText);
}

export const selectionStatsPlugin: MilkdownPlugin = $prose(() => {
  return new Plugin({
    key: selectionStatsKey,
    view() {
      return {
        update(view: EditorView) {
          if (debounceTimer) clearTimeout(debounceTimer);
          debounceTimer = setTimeout(() => {
            debounceTimer = null;
            // Re-read the selection at fire time — it may have moved during the debounce
            postSelection(selectedText(view));
          }, SELECTION_DEBOUNCE_MS);
        },
        destroy() {
          if (debounceTimer) {
            clearTimeout(debounceTimer);
            debounceTimer = null;
          }
          postSelection('');
        },
      };
    },
  });
});
