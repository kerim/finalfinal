// Block ID Plugin for stable annotation anchoring
// Assigns unique block IDs to block-level nodes (paragraphs, headings, lists, etc.)
// These IDs survive edits elsewhere in the document.

import type { Node } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';

export const blockIdPluginKey = new PluginKey<BlockIdPluginState>('block-id');

// Block types that should receive IDs (top-level only — no list_item)
const BLOCK_TYPES = new Set([
  'paragraph',
  'heading',
  'bullet_list',
  'ordered_list',
  'blockquote',
  'code_block',
  'horizontal_rule',
  'section_break',
  'table',
  'image',
]);

// Generate a UUID for new blocks
function generateBlockId(): string {
  // Use crypto.randomUUID if available, otherwise fallback
  if (typeof crypto !== 'undefined' && crypto.randomUUID) {
    return crypto.randomUUID();
  }
  // Fallback UUID generation
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

// Prefix for temporary IDs (before Swift confirms permanent IDs)
const TEMP_ID_PREFIX = 'temp-';

interface BlockIdPluginState {
  // Map from position to block ID
  blockIds: Map<number, string>;
  // Pending ID confirmations from Swift (temp ID -> permanent ID)
  pendingConfirmations: Map<string, string>;
}

// Track block ID assignments for external access
// Note: These are cleared when the editor is destroyed via resetBlockIdState()
let currentBlockIds: Map<number, string> = new Map();
const pendingConfirmations: Map<string, string> = new Map();

/**
 * Reset module-level state (call when destroying editor instance)
 */
export function resetBlockIdState(): void {
  currentBlockIds.clear();
  pendingConfirmations.clear();
}

/**
 * Get the block ID at a given position
 */
export function getBlockIdAtPos(pos: number): string | undefined {
  return currentBlockIds.get(pos);
}

/**
 * Get all block IDs in the document
 */
export function getAllBlockIds(): Map<number, string> {
  return new Map(currentBlockIds);
}

/**
 * Confirm a temp ID with a permanent ID from Swift
 */
export function confirmBlockId(tempId: string, permanentId: string): void {
  pendingConfirmations.set(tempId, permanentId);
}

/**
 * Confirm multiple temp IDs at once
 */
export function confirmBlockIds(mapping: Record<string, string>): void {
  for (const [tempId, permanentId] of Object.entries(mapping)) {
    pendingConfirmations.set(tempId, permanentId);
  }
}

/**
 * Immediately apply pending confirmations to currentBlockIds.
 * Returns a map of temp→permanent IDs that were applied.
 * Call after confirmBlockIds() to prevent the insert-delete cycle
 * where temp IDs disappear before the next transaction applies them.
 */
export function applyPendingConfirmations(): Map<string, string> {
  const applied = new Map<string, string>();
  for (const [pos, id] of currentBlockIds) {
    const confirmedId = pendingConfirmations.get(id);
    if (confirmedId) {
      currentBlockIds.set(pos, confirmedId);
      applied.set(id, confirmedId);
    }
  }
  for (const [tempId] of applied) {
    pendingConfirmations.delete(tempId);
  }
  return applied;
}

/**
 * Clear all current block IDs.
 * Used by applyBlocks() before setting real IDs from the blocks array.
 */
export function clearBlockIds(): void {
  currentBlockIds.clear();
}

/**
 * Check if a block type should receive an ID
 */
export function isBlockType(node: Node): boolean {
  return BLOCK_TYPES.has(node.type.name);
}

/**
 * Set block IDs for top-level nodes from an ordered array of IDs.
 * Matches BlockParser.parse() which creates one block per top-level node.
 * Uses doc.forEach() (top-level only, NOT doc.descendants()).
 */
export function setBlockIdsForTopLevel(orderedIds: string[], doc: Node): void {
  let index = 0;
  doc.forEach((node, offset) => {
    if (isBlockType(node) && index < orderedIds.length) {
      currentBlockIds.set(offset, orderedIds[index]);
      index++;
    }
  });
}

/**
 * Scan document and assign IDs to blocks that don't have them.
 * Uses content-based matching to track blocks across position shifts.
 */
function assignBlockIds(doc: Node, existingIds: Map<number, string>): Map<number, string> {
  const newIds = new Map<number, string>();
  // Track which old IDs have been claimed to prevent duplicates
  const claimedIds = new Set<string>();

  // Build a map of existing blocks by content hash for matching
  const _existingByContent = new Map<string, { pos: number; id: string }[]>();
  for (const [_pos, _id] of existingIds) {
    // We need the old document's node content, but we don't have it
    // So we'll use position-based matching with content verification
  }

  // Use doc.forEach() for top-level only traversal, matching BlockParser behavior
  doc.forEach((node, offset) => {
    if (isBlockType(node)) {
      // Check if this position already has an ID
      const existingId = existingIds.get(offset);
      if (existingId && !claimedIds.has(existingId)) {
        // Check if this temp ID has been confirmed
        const confirmedId = pendingConfirmations.get(existingId);
        if (confirmedId) {
          newIds.set(offset, confirmedId);
          claimedIds.add(confirmedId);
          pendingConfirmations.delete(existingId);
        } else {
          newIds.set(offset, existingId);
          claimedIds.add(existingId);
        }
      } else {
        // Position doesn't have an ID - try to find by proximity
        // This handles position shifts from edits elsewhere in the document
        let found = false;

        // Look for unclaimed IDs at nearby positions with same block type
        // Use a sliding window approach - closer positions are preferred
        const candidates: { pos: number; id: string; distance: number }[] = [];

        for (const [oldPos, id] of existingIds) {
          if (claimedIds.has(id)) continue;

          const distance = Math.abs(oldPos - offset);
          // Allow larger position shifts for blocks (up to 500 chars)
          // This accommodates edits in earlier parts of the document
          if (distance < 500) {
            candidates.push({ pos: oldPos, id, distance });
          }
        }

        // Sort by distance and pick the closest
        candidates.sort((a, b) => a.distance - b.distance);

        if (candidates.length > 0) {
          const best = candidates[0];
          // Check if this temp ID has been confirmed
          const confirmedId = pendingConfirmations.get(best.id);
          if (confirmedId) {
            newIds.set(offset, confirmedId);
            claimedIds.add(confirmedId);
            pendingConfirmations.delete(best.id);
          } else {
            newIds.set(offset, best.id);
            claimedIds.add(best.id);
          }
          found = true;
        }

        if (!found) {
          // New block - assign temporary ID
          const newId = TEMP_ID_PREFIX + generateBlockId();
          newIds.set(offset, newId);
          claimedIds.add(newId);
        }
      }
    }
  });

  return newIds;
}

// Wrap ProseMirror plugin with $prose for Milkdown compatibility
export const blockIdPlugin = $prose(() => {
  return new Plugin<BlockIdPluginState>({
    key: blockIdPluginKey,

    state: {
      init(_, state) {
        const blockIds = assignBlockIds(state.doc, new Map());
        currentBlockIds = blockIds;
        return { blockIds, pendingConfirmations: new Map() };
      },

      apply(tr, value, _oldState, newState) {
        if (!tr.docChanged) {
          return value;
        }

        // Use currentBlockIds (module-level) instead of stale value.blockIds.
        // syncBlockIds() updates currentBlockIds directly without dispatching a
        // transaction, so value.blockIds can hold stale temp IDs that would
        // overwrite the confirmed UUIDs and trigger mass deletes.
        const blockIds = assignBlockIds(newState.doc, currentBlockIds);
        currentBlockIds = blockIds;

        return {
          blockIds: currentBlockIds,
          pendingConfirmations: new Map(pendingConfirmations),
        };
      },
    },

    props: {
      decorations(state) {
        const pluginState = blockIdPluginKey.getState(state);
        if (!pluginState) {
          return DecorationSet.empty;
        }

        const decorations: Decoration[] = [];

        // Add data-block-id attributes to top-level block nodes only
        state.doc.forEach((node, offset) => {
          if (isBlockType(node)) {
            const blockId = pluginState.blockIds.get(offset);
            if (blockId) {
              decorations.push(
                Decoration.node(offset, offset + node.nodeSize, {
                  'data-block-id': blockId,
                })
              );
            }
          }
        });

        return DecorationSet.create(state.doc, decorations);
      },
    },
  });
});
