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
  'math_display',
]);

/**
 * Block types that cannot be produced from another type via a Milkdown input
 * rule. Cross-type Phase-1 claims involving these types are always invalid
 * (they indicate ID theft from position shifting, not in-place conversion).
 * Currently just 'figure' — the confirmed bug vector. Tables, horizontal rules,
 * and section breaks have narrower latent vectors but also have observed
 * paragraph→X input-rule conversions (`|a|b|`, `---`, etc.), so keeping them
 * out preserves those transitions.
 */
const ATOMIC_BLOCK_TYPES: ReadonlySet<string> = new Set(['figure', 'math_display']);

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

// Zoom mode flag: when true, assignBlockIds skips unmatched nodes in the
// mini-Notes tail — at/after the zoom_notes_marker node — so mini-Notes
// content never gets temp IDs (which would sync it into the DB as real
// blocks). Nodes BEFORE the marker (new user blocks created while zoomed)
// still get temp IDs so live sync keeps working.
let blockIdZoomMode = false;

/**
 * Verbose-diagnostic logging toggle. Flip to true on demand for future investigations.
 * Grep gate before commit: `grep -En 'SYNC_DIAG_DETAIL\s*=\s*true' web/milkdown/src/*.ts` must be empty.
 * Re-exported for api-content.ts instrumentation sites.
 */
export const SYNC_DIAG_DETAIL = false;

export function setBlockIdZoomMode(enabled: boolean): void {
  blockIdZoomMode = enabled;
}

/**
 * Reset module-level state (call when destroying editor instance)
 */
export function resetBlockIdState(): void {
  syncLog('BlockId:resetBlockIdState', `clearing ${currentBlockIds.size} block IDs`);
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
  // [SYNC-DIAG Round 2] One log per call (NOT per loop entry), capped 5 pairs
  if (SYNC_DIAG_DETAIL && applied.size > 0) {
    const pairs = Array.from(applied.entries())
      .slice(0, 5)
      .map(([oldId, newId]) => `(${oldId.slice(0, 10)}→${newId.slice(0, 8)})`);
    syncLog('BlockId:confirm', `applyPendingConfirmations: size=${applied.size} firstFew=[${pairs.join(',')}]`);
  }
  return applied;
}

/**
 * Clear all current block IDs.
 * Used by applyBlocks() before setting real IDs from the blocks array.
 */
export function clearBlockIds(): void {
  syncLog('BlockId:clearBlockIds', `clearing ${currentBlockIds.size} block IDs (from applyBlocks path)`);
  currentBlockIds.clear();
  currentBlockTypes.clear();
}

/**
 * Decide whether Phase 1 should claim an existing ID at a given offset.
 * Returns true only when (a) there IS an existing ID at that offset, (b) it
 * hasn't already been claimed, and (c) the type transition is allowed — same
 * type or both types non-atomic (paragraph/heading/list/blockquote/etc., which
 * can arise from input rules). Atomic types (currently `figure`) require
 * strict type match to prevent position-shift ID theft. Exported for tests.
 */
export function phase1CanClaim(
  newType: string,
  existingType: string | undefined,
  existingId: string | undefined,
  claimed: ReadonlySet<string>
): boolean {
  if (!existingId) return false;
  if (claimed.has(existingId)) return false;
  if (existingType === newType) return true;
  if (existingType === undefined) return false;
  if (ATOMIC_BLOCK_TYPES.has(existingType)) return false;
  if (ATOMIC_BLOCK_TYPES.has(newType)) return false;
  return true;
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
  // [SYNC-DIAG Round 2] Collect a sample of (i, id, offset, nodeType) for correlation
  // with Swift's block-array shape. Cap at 5 head + 5 tail entries to bound volume.
  const assigned: Array<{ i: number; id: string; offset: number; type: string }> = [];
  doc.forEach((node, offset) => {
    if (isBlockType(node) && index < orderedIds.length) {
      currentBlockIds.set(offset, orderedIds[index]);
      currentBlockTypes.set(offset, node.type.name);
      if (SYNC_DIAG_DETAIL) {
        assigned.push({ i: index, id: orderedIds[index], offset, type: node.type.name });
      }
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
  if (SYNC_DIAG_DETAIL) {
    const fmt = (e: { i: number; id: string; offset: number; type: string }) =>
      `(${e.i},${e.id.slice(0, 8)},pos=${e.offset},${e.type})`;
    const head = assigned.slice(0, 5).map(fmt).join(',');
    const tail = assigned.length > 10 ? `,…,${assigned.slice(-5).map(fmt).join(',')}` : '';
    syncLog('BlockId:setTopLevel', `totalAssigned=${index}/${orderedIds.length} entries=[${head}${tail}]`);
  }
}

/**
 * Offset of the zoom-notes marker node, or Infinity when absent.
 *
 * In zoom mode, temp-ID suppression must apply ONLY to the mini-Notes tail
 * (the `zoom_notes_marker` node and everything after it). A block without an
 * ID is invisible to block-sync, so suppressing temp IDs for ALL unmatched
 * nodes silently froze live sync — word count and DB persistence — for any
 * paragraph created while zoomed, until zoom-out flushed it.
 * Exported for unit testing.
 */
export function zoomNotesBoundary(doc: Node): number {
  let boundary = Infinity;
  doc.forEach((node, offset) => {
    if (node.type.name === 'zoom_notes_marker' && offset < boundary) {
      boundary = offset;
    }
  });
  return boundary;
}

/**
 * Whether temp-ID assignment should be suppressed for an unmatched node.
 * True only in zoom mode for nodes at/after the mini-Notes boundary.
 * Exported for unit testing.
 */
export function suppressTempIdInZoom(zoomMode: boolean, offset: number, notesBoundary: number): boolean {
  return zoomMode && offset >= notesBoundary;
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

  // [SYNC-DIAG Phase 0] Log when the existingIds baseline is empty — strong desync signal.
  // Quiet on the common case (non-zero existingIds) to avoid log volume.
  if (existingIds.size === 0) {
    syncLog(
      'BlockId:assign',
      `WARNING existingIds.size=0 docBlockCount=${blockCount} structureChanged=${structureChanged} stack=${new Error().stack?.split('\n').slice(1, 5).join(' | ')}`
    );
  } else if (Math.abs(blockCount - existingIds.size) > 5) {
    // Also log when the jump is large — another possible desync footprint.
    syncLog(
      'BlockId:assign',
      `existingIds.size=${existingIds.size} docBlockCount=${blockCount} diff=${blockCount - existingIds.size} structureChanged=${structureChanged}`
    );
  }

  // Collect deferred blocks that need proximity matching
  const deferred: Array<{ offset: number; nodeType: string }> = [];

  // Zoom mode: only the mini-Notes tail is exempt from temp IDs (see zoomNotesBoundary)
  const notesBoundary = blockIdZoomMode ? zoomNotesBoundary(doc) : Infinity;

  // Phase 1: exact-position matches. `phase1CanClaim` enforces the type gate
  // that prevents atomic-type (figure) theft from position-shifted paragraphs
  // while still admitting legitimate input-rule conversions (paragraph↔heading,
  // paragraph↔list, paragraph↔table, etc.).
  doc.forEach((node, offset) => {
    if (isBlockType(node)) {
      const existingId = existingIds.get(offset);
      const existingType = existingTypes.get(offset);
      if (phase1CanClaim(node.type.name, existingType, existingId, claimedIds)) {
        // Exact-position match (same type, or non-atomic type conversion).
        const confirmedId = pendingConfirmations.get(existingId!);
        if (confirmedId) {
          newIds.set(offset, confirmedId);
          newTypes.set(offset, node.type.name);
          claimedIds.add(confirmedId);
          pendingConfirmations.delete(existingId!);
        } else {
          newIds.set(offset, existingId!);
          newTypes.set(offset, node.type.name);
          claimedIds.add(existingId!);
        }
      } else {
        // Defer to Phase 2
        deferred.push({ offset, nodeType: node.type.name });
      }
    }
  });

  // End-of-Phase-1 summary (diagnostic only).
  if (SYNC_DIAG_DETAIL) {
    const claimed = blockCount - deferred.length;
    syncLog(
      'BlockId:assign:phase1',
      `phase1 summary: claimed=${claimed} deferred=${deferred.length} structureChanged=${structureChanged}`
    );
  }

  // [SYNC-DIAG Round 2] Hard cap guard — if >50 deferred blocks, emit one summary
  // and skip per-block defer logs (prevents log-volume DoS).
  const skipPerBlockDeferLogs = deferred.length > 50;
  if (SYNC_DIAG_DETAIL && skipPerBlockDeferLogs) {
    syncLog('BlockId:assign:phase2', `deferred.length=${deferred.length} > 50, suppressing per-block defer logs`);
  }

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

      // [SYNC-DIAG Round 2] Log when deferred figure gets matched, OR when chosen
      // old type differs from deferred new type (latter should be impossible
      // because type filter above — but log it as safety invariant).
      if (SYNC_DIAG_DETAIL && !skipPerBlockDeferLogs) {
        const chosenOldType = existingTypes.get(p.oldPos);
        if (p.nodeType === 'figure' || chosenOldType !== p.nodeType) {
          // Candidate pool for this deferred block (before greedy assignment),
          // capped to first 5. Compute lazily only when we log.
          const cands = pairs
            .filter((x) => x.newOffset === p.newOffset)
            .slice(0, 5)
            .map((x) => `(${x.id.slice(0, 8)},oldPos=${x.oldPos},${existingTypes.get(x.oldPos)},d=${x.distance})`);
          syncLog(
            'BlockId:assign:phase2',
            `[structureChanged] newOffset=${p.newOffset} newType=${p.nodeType} candidates=[${cands.join(',')}] chosen=(${p.id.slice(0, 8)},${chosenOldType},d=${p.distance})`
          );
        }
      }
    }

    // Remaining deferred blocks get temp IDs (unless in the zoom-mode mini-Notes tail)
    for (const d of deferred) {
      if (assignedNew.has(d.offset)) continue;
      if (suppressTempIdInZoom(blockIdZoomMode, d.offset, notesBoundary)) continue;
      const newId = TEMP_ID_PREFIX + generateBlockId();
      newIds.set(d.offset, newId);
      newTypes.set(d.offset, d.nodeType);
      claimedIds.add(newId);
      if (SYNC_DIAG_DETAIL && !skipPerBlockDeferLogs && d.nodeType === 'figure') {
        syncLog(
          'BlockId:assign:phase2',
          `[structureChanged] newOffset=${d.offset} newType=${d.nodeType} chosen=TEMP ${newId.slice(0, 13)}`
        );
      }
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

        if (SYNC_DIAG_DETAIL && !skipPerBlockDeferLogs) {
          const chosenOldType = existingTypes.get(best.pos);
          if (d.nodeType === 'figure' || chosenOldType !== d.nodeType) {
            const cands = sameType
              .slice(0, 5)
              .map((c) => `(${c.id.slice(0, 8)},oldPos=${c.pos},${existingTypes.get(c.pos)},d=${c.distance})`);
            syncLog(
              'BlockId:assign:phase2',
              `[perBlock] newOffset=${d.offset} newType=${d.nodeType} candidates=[${cands.join(',')}] chosen=(${best.id.slice(0, 8)},${chosenOldType},d=${best.distance})`
            );
          }
        }
      }

      if (!found) {
        if (suppressTempIdInZoom(blockIdZoomMode, d.offset, notesBoundary)) continue;
        const newId = TEMP_ID_PREFIX + generateBlockId();
        newIds.set(d.offset, newId);
        newTypes.set(d.offset, d.nodeType);
        claimedIds.add(newId);
        if (SYNC_DIAG_DETAIL && !skipPerBlockDeferLogs && d.nodeType === 'figure') {
          syncLog(
            'BlockId:assign:phase2',
            `[perBlock] newOffset=${d.offset} newType=${d.nodeType} chosen=TEMP ${newId.slice(0, 13)}`
          );
        }
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
