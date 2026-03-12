// Block ID Plugin for stable annotation anchoring
// Assigns unique block IDs to block-level nodes (paragraphs, headings, lists, etc.)
// These IDs survive edits elsewhere in the document.

import type { Node } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import { syncLog } from './sync-debug';

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
  'figure',
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
let currentBlockTypes: Map<number, string> = new Map();
const pendingConfirmations: Map<string, string> = new Map();

// Zoom mode flag: when true, assignBlockIds skips unmatched nodes
// (prevents mini-Notes nodes from getting temp IDs)
let blockIdZoomMode = false;

export function setBlockIdZoomMode(enabled: boolean): void {
  blockIdZoomMode = enabled;
}

/**
 * Reset module-level state (call when destroying editor instance)
 */
export function resetBlockIdState(): void {
  currentBlockIds.clear();
  currentBlockTypes.clear();
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
  currentBlockTypes.clear();
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
      currentBlockTypes.set(offset, node.type.name);
      index++;
    }
  });
  if (index !== orderedIds.length) {
    syncLog('BlockId', `PARITY MISMATCH: assigned ${index} of ${orderedIds.length} IDs — LIKELY CAUSE OF CORRUPTION`);
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[setBlockIdsForTopLevel] PARITY MISMATCH: assigned ${index} of ${orderedIds.length} IDs`,
    });
  }
}

/**
 * Scan document and assign IDs to blocks that don't have them.
 * Uses type-aware matching to prevent cross-type ID theft
 * (e.g., a new paragraph stealing a heading's ID by proximity).
 */
function assignBlockIds(
  doc: Node,
  existingIds: Map<number, string>,
  existingTypes: Map<number, string>
): [Map<number, string>, Map<number, string>] {
  const newIds = new Map<number, string>();
  const newTypes = new Map<number, string>();
  const claimedIds = new Set<string>();

  // Count current blocks to detect structural changes (insertion/deletion)
  let blockCount = 0;
  doc.forEach((node) => {
    if (isBlockType(node)) blockCount++;
  });
  const structureChanged = blockCount !== existingIds.size;

  // Collect deferred blocks that need proximity matching
  const deferred: Array<{ offset: number; nodeType: string }> = [];

  // Phase 1: exact-position matches
  doc.forEach((node, offset) => {
    if (isBlockType(node)) {
      const existingId = existingIds.get(offset);
      // When structure changed, only allow exact-position match if type matches
      const typeMatches = !structureChanged || existingTypes.get(offset) === node.type.name;

      if (existingId && !claimedIds.has(existingId) && typeMatches) {
        // Exact-position match (same type, or type conversion with same structure)
        const confirmedId = pendingConfirmations.get(existingId);
        if (confirmedId) {
          newIds.set(offset, confirmedId);
          newTypes.set(offset, node.type.name);
          claimedIds.add(confirmedId);
          pendingConfirmations.delete(existingId);
        } else {
          newIds.set(offset, existingId);
          newTypes.set(offset, node.type.name);
          claimedIds.add(existingId);
        }
      } else {
        // Defer to Phase 2
        deferred.push({ offset, nodeType: node.type.name });
      }
    }
  });

  // Phase 2: proximity matching
  if (structureChanged && deferred.length > 0) {
    // Closest-first global matching: collect ALL candidate pairs, sort by distance,
    // then assign greedily. This prevents a new paragraph at pos 30 from stealing
    // a bibliography entry's ID at pos 44 when the real entry is at pos 46 (distance=2).
    const pairs: Array<{ newOffset: number; oldPos: number; id: string; distance: number; nodeType: string }> = [];
    for (const d of deferred) {
      for (const [oldPos, id] of existingIds) {
        if (claimedIds.has(id)) continue;
        if (existingTypes.get(oldPos) !== d.nodeType) continue;
        const distance = Math.abs(oldPos - d.offset);
        if (distance < 500) {
          pairs.push({ newOffset: d.offset, oldPos, id, distance, nodeType: d.nodeType });
        }
      }
    }
    // Sort by distance ascending, tiebreak by oldPos (stable ordering)
    pairs.sort((a, b) => a.distance - b.distance || a.oldPos - b.oldPos);

    // Greedy assign from sorted pairs
    const assignedNew = new Set<number>();
    for (const p of pairs) {
      if (claimedIds.has(p.id) || assignedNew.has(p.newOffset)) continue;
      const confirmedId = pendingConfirmations.get(p.id);
      const finalId = confirmedId || p.id;
      if (confirmedId) pendingConfirmations.delete(p.id);
      newIds.set(p.newOffset, finalId);
      newTypes.set(p.newOffset, p.nodeType);
      claimedIds.add(finalId);
      assignedNew.add(p.newOffset);
    }

    // Remaining deferred blocks get temp IDs (unless zoom mode)
    for (const d of deferred) {
      if (assignedNew.has(d.offset)) continue;
      if (blockIdZoomMode) continue;
      const newId = TEMP_ID_PREFIX + generateBlockId();
      newIds.set(d.offset, newId);
      newTypes.set(d.offset, d.nodeType);
      claimedIds.add(newId);
    }
  } else {
    // Structure unchanged or no deferred blocks: per-block proximity matching (original behavior)
    for (const d of deferred) {
      let found = false;
      const candidates: { pos: number; id: string; distance: number }[] = [];
      for (const [oldPos, id] of existingIds) {
        if (claimedIds.has(id)) continue;
        const distance = Math.abs(oldPos - d.offset);
        if (distance < 500) {
          candidates.push({ pos: oldPos, id, distance });
        }
      }

      const sameType = candidates.filter((c) => existingTypes.get(c.pos) === d.nodeType);
      const best = sameType.length > 0 ? sameType.sort((a, b) => a.distance - b.distance)[0] : null;

      if (best) {
        const confirmedId = pendingConfirmations.get(best.id);
        if (confirmedId) {
          newIds.set(d.offset, confirmedId);
          newTypes.set(d.offset, d.nodeType);
          claimedIds.add(confirmedId);
          pendingConfirmations.delete(best.id);
        } else {
          newIds.set(d.offset, best.id);
          newTypes.set(d.offset, d.nodeType);
          claimedIds.add(best.id);
        }
        found = true;
      }

      if (!found) {
        if (blockIdZoomMode) continue;
        const newId = TEMP_ID_PREFIX + generateBlockId();
        newIds.set(d.offset, newId);
        newTypes.set(d.offset, d.nodeType);
        claimedIds.add(newId);
      }
    }
  }

  return [newIds, newTypes];
}

// Wrap ProseMirror plugin with $prose for Milkdown compatibility
export const blockIdPlugin = $prose(() => {
  return new Plugin<BlockIdPluginState>({
    key: blockIdPluginKey,

    state: {
      init(_, state) {
        const [blockIds, blockTypes] = assignBlockIds(state.doc, new Map(), new Map());
        currentBlockIds = blockIds;
        currentBlockTypes = blockTypes;
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
        const [blockIds, blockTypes] = assignBlockIds(newState.doc, currentBlockIds, currentBlockTypes);
        currentBlockIds = blockIds;
        currentBlockTypes = blockTypes;

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
