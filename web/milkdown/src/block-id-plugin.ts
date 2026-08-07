// Block ID Plugin for stable annotation anchoring
// Assigns unique block IDs to block-level nodes (paragraphs, headings, lists, etc.)
// These IDs survive edits elsewhere in the document.

import type { Node } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import { syncLog } from './sync-debug';
import type { ExpectedBlockMeta } from './types';

export const blockIdPluginKey = new PluginKey<BlockIdPluginState>('block-id');

// Block types that should receive IDs (top-level only — no list_item)
const BLOCK_TYPES = new Set([
  'paragraph',
  'heading',
  'bullet_list',
  'ordered_list',
  'blockquote',
  'code_block',
  'hr',
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

// Ids of nodes that were just created empty by a document split (Enter making
// a new empty paragraph) in a structural pass, but have not yet been filled
// with content. Lets a later structural pass recognize a legitimate
// split-then-fill and let the fill claim the split node's identity, instead
// of the anti-ID-theft guard in meaningfulTextOverlap treating it as an
// unrelated node landing on the same offset. See canClaimViaRecentSplitBypass.
const recentlySplitEmptyIds: Set<string> = new Set();

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

export function getBlockIdZoomMode(): boolean {
  return blockIdZoomMode;
}

/**
 * Reset module-level state (call when destroying editor instance)
 */
export function resetBlockIdState(): void {
  syncLog('BlockId:resetBlockIdState', `clearing ${currentBlockIds.size} block IDs`);
  currentBlockIds.clear();
  currentBlockTypes.clear();
  pendingConfirmations.clear();
  recentlySplitEmptyIds.clear();
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

/** Exported for tests — introspects the recently-split-empty marker set. No production code outside this file should depend on this. */
export function getRecentlySplitEmptyIds(): Set<string> {
  return new Set(recentlySplitEmptyIds);
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
 * Resolve a candidate id to its Swift-confirmed permanent id, if one is
 * pending, consuming the pendingConfirmations entry in the process. If the
 * candidate id currently carries a recentlySplitEmptyIds marker, the marker
 * is moved to the resolved id so the temp→permanent handoff never strands
 * the marker on a dead id. Returns the resolved id, or the original
 * candidate unchanged if nothing was pending.
 */
function resolveConfirmedId(candidateId: string): string {
  const confirmedId = pendingConfirmations.get(candidateId);
  if (!confirmedId) return candidateId;
  pendingConfirmations.delete(candidateId);
  if (recentlySplitEmptyIds.has(candidateId)) {
    recentlySplitEmptyIds.delete(candidateId);
    recentlySplitEmptyIds.add(confirmedId);
  }
  return confirmedId;
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
    const finalId = resolveConfirmedId(id);
    if (finalId !== id) {
      currentBlockIds.set(pos, finalId);
      applied.set(id, finalId);
    }
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
  recentlySplitEmptyIds.clear();
}

/**
 * Decide whether Phase 1 should claim an existing ID at a given offset.
 * Returns true only when (a) there IS an existing ID at that offset, (b) it
 * hasn't already been claimed, and (c) the type transition is allowed — same
 * type or both types non-atomic (paragraph/heading/list/blockquote/etc., which
 * can arise from input rules). Atomic types (currently `figure`, `math_display`)
 * require strict type match to prevent position-shift ID theft.
 *
 * When `structureChanged` is true (a block was inserted or deleted elsewhere
 * in the doc), position alone is not trustworthy: a same-type or convertible
 * node can slide into a deleted node's old offset and would otherwise
 * unconditionally inherit its ID (the header-delete-merge bug). In that case
 * we additionally require `meaningfulTextOverlap` between the old node's text
 * (at this offset, in the previous doc) and the new node's text — i.e. the
 * claim must look like an in-place edit/conversion of the SAME content, not
 * an unrelated node that happened to land on the same offset. Atomic same-type
 * claims (figure/math_display) are exempt from the content check — their
 * content (image src/alt, LaTeX) has no meaningful prefix/suffix relationship,
 * and same-type-atomic slot reuse under churn is a narrow, accepted risk.
 *
 * `recentlySplitEmptyIds` (8th param, defaulted to an empty set for callers
 * that don't track it) lets a legitimate split-then-fill bypass the content
 * check even though `meaningfulTextOverlap` alone would refuse it — see
 * `canClaimViaRecentSplitBypass`, the single source of truth for that bypass.
 * Exported for tests.
 */
export function phase1CanClaim(
  newType: string,
  existingType: string | undefined,
  existingId: string | undefined,
  claimed: ReadonlySet<string>,
  structureChanged: boolean,
  oldText: string | undefined,
  newText: string,
  recentlySplitEmptyIds: ReadonlySet<string> = new Set()
): boolean {
  if (!existingId) return false;
  if (claimed.has(existingId)) return false;

  if (existingType === newType) {
    if (ATOMIC_BLOCK_TYPES.has(newType)) return true;
    if (!structureChanged) return true;
    return canClaimViaRecentSplitBypass(oldText, newText, existingId, recentlySplitEmptyIds);
  }
  if (existingType === undefined) return false;
  if (ATOMIC_BLOCK_TYPES.has(existingType)) return false;
  if (ATOMIC_BLOCK_TYPES.has(newType)) return false;
  if (!structureChanged) return true;
  return canClaimViaRecentSplitBypass(oldText, newText, existingId, recentlySplitEmptyIds);
}

/**
 * Whether `newText` looks like an in-place edit/conversion of `oldText`
 * rather than unrelated content that happened to land on the same offset.
 * Byte-identical text (including both empty) always counts. Otherwise a
 * prefix/suffix relationship in either direction counts (covers typing,
 * backspacing, and heading-level/list-type conversions that preserve the
 * text run). An undefined `oldText` (no previous node at this offset, or it
 * wasn't computed) never counts. One side empty and the other not does NOT
 * count — every string is trivially a "prefix" of itself only when equal, so
 * this prevents e.g. a freshly-emptied node from coincidentally claiming an
 * unrelated node's old ID, or vice versa. Exported for tests.
 */
export function meaningfulTextOverlap(oldText: string | undefined, newText: string): boolean {
  if (oldText === undefined) return false;
  if (oldText === newText) return true; // covers empty-vs-empty, and byte-identical conversions
  if (oldText === '' || newText === '') return false; // asymmetric empty → no coincidental credit
  return (
    newText.startsWith(oldText) || oldText.startsWith(newText) || newText.endsWith(oldText) || oldText.endsWith(newText)
  );
}

/**
 * Whether an otherwise-refused empty→non-empty claim should be allowed
 * because `existingId` is a RECENTLY SPLIT node that is still empty — an
 * artifact of Enter creating a new empty paragraph, not evidence of
 * unrelated content sliding into its slot. This is the single source of
 * truth for the bypass condition; every structural claim site that would
 * otherwise call `meaningfulTextOverlap` alone as its final gate must route
 * through this instead, so the sites cannot drift out of sync with each
 * other. Exported for tests.
 *
 * Residual, accepted risk (same class as this file's ATOMIC_BLOCK_TYPES
 * risk acceptances): if an unrelated, non-empty node happens to land at
 * exactly the marked node's old offset while the marked node itself
 * survives elsewhere, it could claim the marked id via this bypass. The
 * oldText==='' gate re-verifies against the real old doc, so any
 * misassigned identity provably belongs to a block that was empty — no
 * content loss results, only a same-empty-slot id reassignment.
 */
export function canClaimViaRecentSplitBypass(
  oldText: string | undefined,
  newText: string,
  existingId: string,
  recentlySplitEmptyIds: ReadonlySet<string> = new Set()
): boolean {
  if (meaningfulTextOverlap(oldText, newText)) return true;
  return oldText === '' && recentlySplitEmptyIds.has(existingId);
}

/**
 * Safe wrapper around `Node.nodeAt()`. ProseMirror's `nodeAt` throws a
 * RangeError when `offset` exceeds the doc's content size, rather than
 * returning null — which happens routinely here, since `oldDoc` and the
 * current doc can differ hugely in size (e.g. a whole-document content
 * replacement transaction, as in `setContentWithBlockIds`). An offset beyond
 * the old doc's bounds correctly means "nothing there to compare against", so
 * this returns undefined instead of throwing.
 */
function safeNodeAt(doc: Node | undefined, offset: number): Node | undefined {
  if (!doc) return undefined;
  if (offset < 0 || offset > doc.content.size) return undefined;
  return doc.nodeAt(offset) ?? undefined;
}

/**
 * Check if a block type should receive an ID
 */
export function isBlockType(node: Node): boolean {
  return BLOCK_TYPES.has(node.type.name);
}

/** Maps a Swift `BlockType.rawValue` string to the PM node-type name it produces.
 * Returns undefined for types with no direct top-level PM equivalent (list_item never
 * appears top-level; bibliography-marker blocks are excluded entirely upstream — see
 * BlockParser.alignmentPairs on the Swift side, which never emits an id/meta pair for them). */
export function pmTypeForBlockType(blockType: string): string | undefined {
  if (blockType === 'image') return 'figure';
  if (blockType === 'horizontal_rule') return 'hr';
  if (blockType === 'list_item' || blockType === 'bibliography') return undefined;
  return blockType; // paragraph, heading, bullet_list, ordered_list, blockquote, code_block,
  // section_break, table, math_display — same name both sides
}

/**
 * Atom-type inline nodes whose real payload lives entirely in node attrs and
 * which Swift's own extraction does NOT strip to empty text. Deliberately
 * NOT a general "any atom" rule — two atom types were considered and
 * excluded for verified, opposite reasons:
 * - footnote_ref: not included, doesn't need to be — Swift already strips
 *   ALL adjacent refs to '' via a whole-string regex replace, so both sides
 *   already agree without any exemption.
 * - footnote_def: not included, and must NEVER be — its own blankness is
 *   exactly the signal the historical corruption attached to the wrong node;
 *   Swift's extraction already agrees with PM's textContent for it (both
 *   compare only the post-prefix remainder), so exempting it would silently
 *   defeat this hardening's own motivating case.
 *
 * NOTE for future maintainers: if a new inline atom type is added to the
 * schema (beyond citation/footnote_ref/footnote_def), it needs a deliberate
 * decision here — add it to this set, or confirm (like footnote_ref) that
 * Swift's own text extraction already strips it to blank on both sides. Do
 * not assume new atom types are automatically handled.
 *
 * Trusts blankness parity, not content identity: this exemption fires for
 * ANY node whose blankness is explained by a citation descendant, including
 * one that's positionally misaligned but coincidentally citation-only —
 * that narrower case is below this check's detection threshold.
 */
const CONTENT_CHECK_ATOM_EXEMPTIONS: ReadonlySet<string> = new Set(['citation']);

/**
 * True when `node`'s trimmed textContent is blank AND that blankness is
 * explained by an exempted-atom descendant rather than genuine absence of
 * content. Checks for ANY matching descendant, not "all children are atoms"
 * (the predicate this replaced) — necessary because inline atoms are often
 * separated by whitespace text nodes (e.g. two citations side by side,
 * `[@a] [@b]`, parse to [citation, text(" "), citation]), which an
 * all-children-must-be-atoms check would wrongly refuse to exempt.
 *
 * Uses node.descendants() rather than direct children specifically so an
 * atom NESTED inside a non-flat block type is still found — e.g. a
 * blockquote whose only content is a citation-only paragraph: the citation
 * is two levels down (blockquote > paragraph > citation), not a direct
 * child of the blockquote node itself. The whitespace-separated-siblings
 * case above doesn't need this — those citations ARE direct children of
 * their paragraph, so an any-match check over direct children alone would
 * already handle it. Exported for tests.
 */
export function isBlankDueToExemptAtom(node: Node): boolean {
  if (node.textContent.trim().length > 0) return false;
  let found = false;
  node.descendants((child) => {
    if (found) return false; // skip descending into already-matched subtrees
    if (CONTENT_CHECK_ATOM_EXEMPTIONS.has(child.type.name)) found = true;
    return true;
  });
  return found;
}

/**
 * Set block IDs for top-level nodes from an ordered array of IDs.
 * Matches BlockParser.parse() which creates one block per top-level node.
 * Uses doc.forEach() (top-level only, NOT doc.descendants()).
 *
 * `expected` (optional, 3rd param) is a per-id ground-truth array from the Swift side
 * (BlockParser.alignmentPairs) enabling an alignment sanity check beyond the pre-existing
 * count-parity check below: for each slot, if the expected PM type doesn't match the actual
 * node's type, or the expected non-blank text doesn't match an actually-blank node (net of the
 * atomic/citation exemptions), the id is WITHHELD rather than assigned — see the loop body for
 * why withholding (not aliasing) is the safe choice. Omitting `expected` (2-arg call, or passing
 * undefined explicitly) skips this check entirely and preserves the pre-existing behavior.
 */
export function setBlockIdsForTopLevel(orderedIds: string[], doc: Node, expected?: ExpectedBlockMeta[]): void {
  let index = 0;
  // [SYNC-DIAG Round 2] Collect a sample of (i, id, offset, nodeType) for correlation
  // with Swift's block-array shape. Cap at 5 head + 5 tail entries to bound volume.
  const assigned: Array<{ i: number; id: string; offset: number; type: string }> = [];
  const mismatches: Array<{ index: number; offset: number; reason: string }> = [];
  doc.forEach((node, offset) => {
    if (isBlockType(node) && index < orderedIds.length) {
      const meta = expected?.[index];
      let ok = true;
      let reason = '';
      if (meta) {
        const expectedType = pmTypeForBlockType(meta.blockType);
        if (expectedType !== undefined && expectedType !== node.type.name) {
          ok = false;
          reason = `type: expected=${expectedType} actual=${node.type.name}`;
        } else if (
          meta.nonEmpty &&
          !ATOMIC_BLOCK_TYPES.has(node.type.name) &&
          node.textContent.trim().length === 0 &&
          !isBlankDueToExemptAtom(node)
        ) {
          ok = false;
          reason = 'content: expected non-blank, actual blank';
        }
      }
      if (ok) {
        currentBlockIds.set(offset, orderedIds[index]);
        currentBlockTypes.set(offset, node.type.name);
        if (SYNC_DIAG_DETAIL) {
          assigned.push({ i: index, id: orderedIds[index], offset, type: node.type.name });
        }
      } else {
        mismatches.push({ index, offset, reason });
        // Deliberately NOT calling currentBlockIds.set/currentBlockTypes.set here — the id is
        // WITHHELD, not aliased onto the wrong node. This slot gets a fresh temp id on the next
        // assignBlockIds pass (safe — see plan notes on the withheld-id trace), instead of
        // silently attaching a real DB row's identity to content it doesn't belong to.
      }
      index++; // increment regardless of ok/mismatch — positional accounting vs. orderedIds
      // must stay in lockstep or every later comparison desyncs.
    }
  });
  if (mismatches.length > 0) {
    const wholesale = mismatches.length >= 3 && mismatches.length > orderedIds.length * 0.3;
    const tag = wholesale
      ? 'WIDESPREAD ALIGNMENT MISMATCH (possible wholesale shift — ids reported as OK may be coincidentally correct)'
      : 'ALIGNMENT MISMATCH';
    const examples = mismatches
      .slice(0, 10)
      .map((m) => `(idx=${m.index},offset=${m.offset},${m.reason})`)
      .join(',');
    syncLog('BlockId', `${tag}: ${mismatches.length} of ${orderedIds.length} ids withheld examples=[${examples}]`);
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[setBlockIdsForTopLevel] ${tag}: ${mismatches.length} of ${orderedIds.length} ids withheld`,
    });
  }
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
    syncLog('BlockId:setTopLevel', `totalAssigned=${assigned.length}/${orderedIds.length} entries=[${head}${tail}]`);
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
 * Also mints `recentlySplitEmptyIds` markers for genuinely new (temp-ID)
 * empty nodes, so a later split-then-fill can reclaim its own id instead of
 * being refused as unrelated content — see `canClaimViaRecentSplitBypass`
 * for the bypass mechanism itself.
 * Exported for tests.
 */
export function assignBlockIds(
  doc: Node,
  existingIds: Map<number, string>,
  existingTypes: Map<number, string>,
  oldDoc: Node | undefined
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
  const deferred: Array<{ offset: number; nodeType: string; nodeText: string }> = [];

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
      // Only compute text content when it's actually needed (structureChanged gates
      // the content check inside phase1CanClaim — see meaningfulTextOverlap, which is
      // only reached when structureChanged is true) — keeps the dominant hot path
      // (ordinary keystrokes, structureChanged === false) free of these lookups.
      const oldText = structureChanged ? safeNodeAt(oldDoc, offset)?.textContent : undefined;
      const newText = structureChanged ? node.textContent : '';
      if (
        phase1CanClaim(
          node.type.name,
          existingType,
          existingId,
          claimedIds,
          structureChanged,
          oldText,
          newText,
          recentlySplitEmptyIds
        )
      ) {
        // Exact-position match (same type, or non-atomic type conversion).
        const finalId = resolveConfirmedId(existingId!);
        newIds.set(offset, finalId);
        newTypes.set(offset, node.type.name);
        claimedIds.add(finalId);
      } else {
        // Defer to Phase 2. nodeText is only read by the structureChanged===true
        // content-filter branch below (meaningfulTextOverlap) — skip the lookup
        // on the structureChanged===false hot path, same as oldText/newText above.
        deferred.push({ offset, nodeType: node.type.name, nodeText: structureChanged ? node.textContent : '' });
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
    const pairs: Array<{
      newOffset: number;
      oldPos: number;
      id: string;
      distance: number;
      nodeType: string;
      nodeText: string;
    }> = [];
    for (const d of deferred) {
      for (const [oldPos, id] of existingIds) {
        if (claimedIds.has(id)) continue;
        if (existingTypes.get(oldPos) !== d.nodeType) continue;
        // Same content-relatedness gate as Phase 1: a same-type candidate at
        // proximity is not enough evidence during structural churn — require
        // the old and new text to actually be related (or exempt atomic types,
        // whose content has no meaningful prefix/suffix relationship).
        if (!ATOMIC_BLOCK_TYPES.has(d.nodeType)) {
          const oldText = safeNodeAt(oldDoc, oldPos)?.textContent;
          if (!canClaimViaRecentSplitBypass(oldText, d.nodeText, id, recentlySplitEmptyIds)) continue;
        }
        const distance = Math.abs(oldPos - d.offset);
        if (distance < 500) {
          pairs.push({ newOffset: d.offset, oldPos, id, distance, nodeType: d.nodeType, nodeText: d.nodeText });
        }
      }
    }
    // Sort by distance ascending, tiebreak by oldPos (stable ordering)
    pairs.sort((a, b) => a.distance - b.distance || a.oldPos - b.oldPos);

    // Greedy assign from sorted pairs
    const assignedNew = new Set<number>();
    for (const p of pairs) {
      if (claimedIds.has(p.id) || assignedNew.has(p.newOffset)) continue;
      const finalId = resolveConfirmedId(p.id);
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
      if (d.nodeText === '' && !ATOMIC_BLOCK_TYPES.has(d.nodeType)) {
        recentlySplitEmptyIds.add(newId);
      }
      if (SYNC_DIAG_DETAIL && !skipPerBlockDeferLogs && d.nodeType === 'figure') {
        syncLog(
          'BlockId:assign:phase2',
          `[structureChanged] newOffset=${d.offset} newType=${d.nodeType} chosen=TEMP ${newId.slice(0, 13)}`
        );
      }
    }
  } else {
    // Structure unchanged or no deferred blocks: per-block proximity matching (original behavior).
    //
    // No content-relatedness check here: this branch only does real work when
    // structureChanged is false (when it's true, deferred.length is also 0 here,
    // making the loop below a no-op — see the `if` above). That mirrors Phase 1's
    // policy of gating the content check on structureChanged: when the block
    // count hasn't changed, position-proximity matching alone is trusted, same
    // as before this fix.
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
        // This branch is only reached when structureChanged is false (its
        // containing `if` requires `structureChanged && deferred.length > 0`,
        // so hitting this `else` with work to do implies structureChanged was
        // false) — so it structurally never needs the recent-split bypass and
        // never marks recentlySplitEmptyIds here. It still must route id
        // renames through the shared helper so a marker from an earlier pass
        // isn't stranded if this branch resolves a pending confirmation for
        // a marked id.
        //
        // Accepted edge case: this reasoning assumes a genuine split's
        // block-count increase isn't exactly offset, in the same transaction,
        // by an unrelated deletion elsewhere in the doc (which would make
        // structureChanged false overall and route the new split node through
        // this never-marks branch). No evidence this app's real editing flows
        // produce such a perfectly-offsetting combined transaction, so this is
        // treated as a low-likelihood risk this fix does not handle.
        const finalId = resolveConfirmedId(best.id);
        newIds.set(d.offset, finalId);
        newTypes.set(d.offset, d.nodeType);
        claimedIds.add(finalId);
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

  // Semantic pruning: a marker is valid only while its id both (a) still
  // exists in this pass's live id set, and (b) still labels an empty node.
  // This also correctly consumes the marker exactly when the bypass was the
  // actual reason a claim succeeded: the bypass can only be decisive when
  // oldText==='' and meaningfulTextOverlap returned false, which (given
  // oldText==='') requires newText!=='' (if newText were also empty,
  // oldText===newText would already make meaningfulTextOverlap true) — so
  // whenever the bypass matters, this pass's newText is provably non-empty,
  // and the "ends non-empty" check below always catches and deletes it.
  if (recentlySplitEmptyIds.size > 0) {
    const idToOffset = new Map<string, number>();
    for (const [offset, id] of newIds) idToOffset.set(id, offset);
    for (const markedId of recentlySplitEmptyIds) {
      if (!claimedIds.has(markedId)) {
        recentlySplitEmptyIds.delete(markedId);
        continue;
      }
      const offset = idToOffset.get(markedId);
      const node = offset !== undefined ? safeNodeAt(doc, offset) : undefined;
      if (node && node.textContent !== '') {
        recentlySplitEmptyIds.delete(markedId);
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
        const [blockIds, blockTypes] = assignBlockIds(state.doc, new Map(), new Map(), undefined);
        currentBlockIds = blockIds;
        currentBlockTypes = blockTypes;
        return { blockIds, pendingConfirmations: new Map() };
      },

      apply(tr, value, oldState, newState) {
        if (!tr.docChanged) {
          return value;
        }

        // Use currentBlockIds (module-level) instead of stale value.blockIds.
        // syncBlockIds() updates currentBlockIds directly without dispatching a
        // transaction, so value.blockIds can hold stale temp IDs that would
        // overwrite the confirmed UUIDs and trigger mass deletes.
        const [blockIds, blockTypes] = assignBlockIds(newState.doc, currentBlockIds, currentBlockTypes, oldState.doc);
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
