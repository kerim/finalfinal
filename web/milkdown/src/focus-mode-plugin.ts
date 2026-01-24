// Focus mode plugin using ProseMirror Decoration system
// NOT DOM manipulation - critical for ProseMirror reconciliation

import { $prose } from '@milkdown/kit/utils';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';

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

        // Find the block containing the cursor
        let currentBlockStart = 0;
        let currentBlockEnd = doc.content.size;

        doc.descendants((node, pos) => {
          if (node.isBlock && node.isTextblock) {
            const nodeEnd = pos + node.nodeSize;
            if (currentPos >= pos && currentPos <= nodeEnd) {
              currentBlockStart = pos;
              currentBlockEnd = nodeEnd;
            }
          }
          return true;
        });

        // Add 'dimmed' decoration to all blocks except current
        doc.descendants((node, pos) => {
          if (node.isBlock && node.isTextblock) {
            const nodeEnd = pos + node.nodeSize;
            const isCurrent = pos === currentBlockStart;

            if (!isCurrent) {
              decorations.push(
                Decoration.node(pos, nodeEnd, { class: 'ff-dimmed' })
              );
            }
          }
          return true;
        });

        return DecorationSet.create(doc, decorations);
      },
    },
  });
});
