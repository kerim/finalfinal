// Focus mode plugin using ProseMirror Decoration system
// NOT DOM manipulation - critical for ProseMirror reconciliation
// Uses state field with cached DecorationSet to avoid O(n) rebuild on every keystroke

import type { Transaction } from '@milkdown/kit/prose/state';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';

export const focusModePluginKey = new PluginKey<FocusModePluginState>('focus-mode');

let focusModeEnabled = false;

export function setFocusModeEnabled(enabled: boolean) {
  focusModeEnabled = enabled;
}

export function isFocusModeEnabled(): boolean {
  return focusModeEnabled;
}

interface FocusModePluginState {
  decorations: DecorationSet;
  cursorTextblockPos: number | null; // Position of the textblock containing the cursor
}

/** Find the position of the nearest textblock containing the given position */
function findCursorTextblockPos(doc: import('@milkdown/kit/prose/model').Node, pos: number): number | null {
  let found: number | null = null;
  doc.descendants((node, nodePos) => {
    if (found !== null) return false; // Already found, stop
    if (node.isBlock && node.isTextblock) {
      const nodeEnd = nodePos + node.nodeSize;
      if (pos >= nodePos && pos < nodeEnd) {
        found = nodePos;
        return false; // Stop traversal
      }
    }
    return true; // Continue into children
  });
  return found;
}

/** Build a full DecorationSet, dimming all textblocks except the one at cursorPos */
function buildDecorations(
  doc: import('@milkdown/kit/prose/model').Node,
  cursorTextblockPos: number | null
): DecorationSet {
  if (cursorTextblockPos === null) return DecorationSet.empty;
  const decorations: Decoration[] = [];
  doc.descendants((node, pos) => {
    if (node.isBlock && node.isTextblock) {
      if (pos !== cursorTextblockPos) {
        decorations.push(Decoration.node(pos, pos + node.nodeSize, { class: 'ff-dimmed' }));
      }
    }
    return true;
  });
  return DecorationSet.create(doc, decorations);
}

// Wrap ProseMirror plugin with $prose for Milkdown compatibility
export const focusModePlugin = $prose(() => {
  return new Plugin<FocusModePluginState>({
    key: focusModePluginKey,

    state: {
      init(_, state): FocusModePluginState {
        if (!focusModeEnabled) {
          return { decorations: DecorationSet.empty, cursorTextblockPos: null };
        }
        const cursorPos = findCursorTextblockPos(state.doc, state.selection.from);
        return {
          decorations: buildDecorations(state.doc, cursorPos),
          cursorTextblockPos: cursorPos,
        };
      },

      apply(tr: Transaction, value: FocusModePluginState, _oldState, newState): FocusModePluginState {
        if (!focusModeEnabled) {
          return { decorations: DecorationSet.empty, cursorTextblockPos: null };
        }

        const newCursorPos = findCursorTextblockPos(newState.doc, newState.selection.from);

        // If cursor hasn't moved to a different textblock and doc structure unchanged,
        // just map existing decorations through the transaction mapping (O(log n))
        if (newCursorPos === value.cursorTextblockPos && !tr.docChanged) {
          return value;
        }

        if (tr.docChanged && newCursorPos === value.cursorTextblockPos) {
          // Doc changed but cursor still in same textblock — map decorations
          return {
            decorations: value.decorations.map(tr.mapping, newState.doc),
            cursorTextblockPos: newCursorPos,
          };
        }

        // Cursor moved to a different textblock or doc structure changed significantly — full rebuild
        return {
          decorations: buildDecorations(newState.doc, newCursorPos),
          cursorTextblockPos: newCursorPos,
        };
      },
    },

    props: {
      decorations(state) {
        return focusModePluginKey.getState(state)?.decorations ?? DecorationSet.empty;
      },
    },
  });
});
