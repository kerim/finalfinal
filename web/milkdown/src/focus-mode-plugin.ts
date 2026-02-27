// Focus mode plugin using ProseMirror Decoration system
// NOT DOM manipulation - critical for ProseMirror reconciliation

import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';

export const focusModePluginKey = new PluginKey('focus-mode');

let focusModeEnabled = false;

export function setFocusModeEnabled(enabled: boolean) {
  focusModeEnabled = enabled;
}

export function isFocusModeEnabled(): boolean {
  return focusModeEnabled;
}

// Wrap ProseMirror plugin with $prose for Milkdown compatibility
export const focusModePlugin = $prose(() => {
  return new Plugin({
    key: focusModePluginKey,
    props: {
      decorations(state) {
        if (!focusModeEnabled) {
          return DecorationSet.empty;
        }

        const { selection, doc } = state;
        const currentPos = selection.from;
        const decorations: Decoration[] = [];

        // Single-pass: find cursor block and dim all others
        doc.descendants((node, pos) => {
          if (node.isBlock && node.isTextblock) {
            const nodeEnd = pos + node.nodeSize;
            if (currentPos >= pos && currentPos < nodeEnd) {
              // Cursor's block — skip (don't dim)
            } else {
              decorations.push(Decoration.node(pos, nodeEnd, { class: 'ff-dimmed' }));
            }
          }
          return true;
        });

        return DecorationSet.create(doc, decorations);
      },
    },
  });
});
