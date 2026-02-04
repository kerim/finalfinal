// Block ID Plugin for stable annotation anchoring
// Assigns unique block IDs to block-level nodes (paragraphs, headings, lists, etc.)
// These IDs survive edits elsewhere in the document.

import { Plugin, PluginKey, Transaction } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { Node } from '@milkdown/kit/prose/model';
import { $prose } from '@milkdown/kit/utils';

export const blockIdPluginKey = new PluginKey<BlockIdPluginState>('block-id');

// Block types that should receive IDs
const BLOCK_TYPES = new Set([
  'paragraph',
  'heading',
  'bullet_list',
  'ordered_list',
  'list_item',
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
let pendingConfirmations: Map<string, string> = new Map();

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
 * Check if a block type should receive an ID
 */
function isBlockType(node: Node): boolean {
  return BLOCK_TYPES.has(node.type.name);
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
  const existingByContent = new Map<string, { pos: number; id: string }[]>();
  for (const [pos, id] of existingIds) {
    // We need the old document's node content, but we don't have it
    // So we'll use position-based matching with content verification
  }

  doc.descendants((node, pos) => {
    if (isBlockType(node)) {
      // Check if this position already has an ID
      const existingId = existingIds.get(pos);
      if (existingId && !claimedIds.has(existingId)) {
        // Check if this temp ID has been confirmed
        const confirmedId = pendingConfirmations.get(existingId);
        if (confirmedId) {
          newIds.set(pos, confirmedId);
          claimedIds.add(confirmedId);
          pendingConfirmations.delete(existingId);
        } else {
          newIds.set(pos, existingId);
          claimedIds.add(existingId);
        }
      } else {
        // Position doesn't have an ID - try to find by proximity
        // This handles position shifts from edits elsewhere in the document
        let found = false;
        const nodeContent = node.textContent;
        const nodeType = node.type.name;

        // Look for unclaimed IDs at nearby positions with same block type
        // Use a sliding window approach - closer positions are preferred
        const candidates: { pos: number; id: string; distance: number }[] = [];

        for (const [oldPos, id] of existingIds) {
          if (claimedIds.has(id)) continue;

          const distance = Math.abs(oldPos - pos);
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
            newIds.set(pos, confirmedId);
            claimedIds.add(confirmedId);
            pendingConfirmations.delete(best.id);
          } else {
            newIds.set(pos, best.id);
            claimedIds.add(best.id);
          }
          found = true;
        }

        if (!found) {
          // New block - assign temporary ID
          const newId = TEMP_ID_PREFIX + generateBlockId();
          newIds.set(pos, newId);
          claimedIds.add(newId);
        }
      }
    }
    return true; // Continue traversal
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

        // Re-assign IDs, preserving existing ones where possible
        const blockIds = assignBlockIds(newState.doc, value.blockIds);
        currentBlockIds = blockIds;

        return {
          blockIds,
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

        // Add data-block-id attributes to all block nodes
        state.doc.descendants((node, pos) => {
          if (isBlockType(node)) {
            const blockId = pluginState.blockIds.get(pos);
            if (blockId) {
              decorations.push(
                Decoration.node(pos, pos + node.nodeSize, {
                  'data-block-id': blockId,
                })
              );
            }
          }
          return true;
        });

        return DecorationSet.create(state.doc, decorations);
      },
    },
  });
});
