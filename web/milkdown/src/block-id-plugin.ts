// Block ID Plugin for stable annotation anchoring
// Assigns unique block IDs to block-level nodes (paragraphs, headings, lists, etc.)
// These IDs survive edits elsewhere in the document.

import type { Node } from '@milkdown/kit/prose/model';
import { type EditorState, Plugin, PluginKey } from '@milkdown/kit/prose/state';
import type { Mapping } from '@milkdown/kit/prose/transform';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import { getIsSettingContent } from './editor-state';
import { syncLog } from './sync-debug';
import type { ExpectedBlockMeta } from './types';

export const blockIdPluginKey = new PluginKey<BlockIdPluginState>('block-id');

// Block types that should receive IDs (top-level only — no list_item).
// NEVER add 'auto_bibliography' or 'auto_bibliography_end' here — both are excluded from this
// allowlist so they never consume a block-ID index tick in setBlockIdsForTopLevel's walk — but
// they are NOT symmetric on the Swift side. The terminator ('auto_bibliography_end', the
// `<!-- ::auto-bibliography-end:: -->` line) produces ZERO Blocks: BlockParser.parse() matches
// it and `continue`s without ever appending one (see BlockParser.swift's doc comment on
// `bibliographyEndMarker`). The opening marker ('auto_bibliography', the
// `<!-- ::auto-bibliography:: -->` line) DOES persist as a `.bibliography`-typed Block when
// glued to the heading it precedes in Source Mode's raw markdown — BlockParser.swift's
// `detectBlockType` classifies that glued text as `.bibliography` (see the doc comment right
// above its `bibliographyEndMarker` check, which says so explicitly). Both are still excluded
// here regardless, because on the ProseMirror side they are each their own zero-content atom
// node type, distinct from the heading/paragraph nodes BLOCK_TYPES tracks — see alignmentPairs'
// doc comment (BlockParser+Assembly.swift) for the Swift-side mirror of this exclusion.
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
 * 'figure' (the confirmed bug vector) and 'math_display' (same shape,
 * inserted the same atomic way). Tables, horizontal rules, and section
 * breaks have narrower latent vectors but also have observed paragraph→X
 * input-rule conversions (`|a|b|`, `---`, etc.), so keeping them out
 * preserves those transitions.
 */
const ATOMIC_BLOCK_TYPES: ReadonlySet<string> = new Set(['figure', 'math_display']);

// Generate a UUID for new blocks. Exported for the editor-first duplicate (api-section-duplicate.ts), which mints the PERMANENT
// ids of the blocks it copies with this same generator, so a copy never carries a `temp-` id (see `setTopLevelIdsAt`).
export function generateBlockId(): string {
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

// Block ids Swift has flagged as "managed" (auto-generated Bibliography/Notes headings and
// their body content — see Block.swift's isBibliography/isNotes). Driven wholesale by
// setManagedBlockIds() from api-content.ts's setContentWithBlockIds() on every content push,
// mirroring how currentBlockIds itself is wholesale-replaced via clearBlockIds() +
// setBlockIdsForTopLevel() on each push -- never mutated incrementally. Consumed by this
// plugin's own decorations() prop below to stamp `data-managed` onto managed block nodes, which
// styles.css's ⌘-hover hint selector then excludes via `:not([data-managed])` -- the WYSIWYG
// replacement for the earlier `.auto-bib-marker` sibling-combinator exclusion
// (`.auto-bib-marker + h1[data-block-id]:hover` etc.). That old rule WAS reachable here --
// bibliography-plugin.ts's `auto_bibliography` atom node (`toDOM`: `div.auto-bib-marker`) renders
// as the Bibliography heading's immediately-preceding DOM sibling on this exact WYSIWYG path
// (BlockParser+Assembly.swift excludes it from the id-array walk specifically so it reaches
// here) -- it was replaced not because it was unreachable, but because it could only ever cover
// Bibliography (Notes headings have no equivalent marker node to combine against) and depended
// on brittle DOM sibling adjacency. `data-managed`, driven directly by Swift's
// isBibliography/isNotes flags, covers both and needs no positional relationship at all.
let managedBlockIds: Set<string> = new Set();

/**
 * Replace the managed-block-id set wholesale (not merged) -- called once per content push from
 * api-content.ts's setContentWithBlockIds(), with the ids Swift flagged isBibliography/isNotes
 * for THIS push. Every other content-push caller -- plain setContent(), applyBlocks() -- calls
 * this itself with an empty argument (see each function's own setManagedBlockIds([]) call in
 * api-content.ts), correctly clearing it to empty, since neither path carries managed-section
 * metadata of its own.
 */
export function setManagedBlockIds(ids: Iterable<string>): void {
  managedBlockIds = new Set(ids);
}

/** Exported for tests — introspects the current managed-block-id set. */
export function getManagedBlockIds(): Set<string> {
  return new Set(managedBlockIds);
}

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
  managedBlockIds.clear();
}

/**
 * Get the block ID at a given position
 */
export function getBlockIdAtPos(pos: number): string | undefined {
  return currentBlockIds.get(pos);
}

/** Block type on record for a top-level offset — the type gate assignBlockIds itself uses. */
export function getBlockTypeAtPos(pos: number): string | undefined {
  return currentBlockTypes.get(pos);
}

/**
 * Get all block IDs in the document
 */
export function getAllBlockIds(): Map<number, string> {
  return new Map(currentBlockIds);
}

/**
 * Copy of the top-level offset → block type map (the type gate assignBlockIds itself uses).
 * Captured beside `getAllBlockIds()` by `deleteSectionEditorFirst` so a failure after its
 * removal can put both maps back exactly as they were (see `restoreBlockIdMaps`).
 */
export function getAllBlockTypes(): Map<number, string> {
  return new Map(currentBlockTypes);
}

/**
 * Put the offset → id and offset → type maps back to previously captured copies (the two
 * `get…` exports above). Wholesale and IN PLACE, like `replaceTopLevelIds` (same Map objects,
 * see `setBlockIdsForTopLevel`'s comment on why). Only valid while the document is the one the
 * copies were captured from, i.e. right after a checkpoint swap back to that document.
 */
export function restoreBlockIdMaps(ids: ReadonlyMap<number, string>, types: ReadonlyMap<number, string>): void {
  currentBlockIds.clear();
  for (const [offset, id] of ids) currentBlockIds.set(offset, id);
  currentBlockTypes.clear();
  for (const [offset, type] of types) currentBlockTypes.set(offset, type);
}

/** Exported for tests — introspects the recently-split-empty marker set. No production code outside this file should depend on this. */
export function getRecentlySplitEmptyIds(): Set<string> {
  return new Set(recentlySplitEmptyIds);
}

/** True for an id the editor made up itself (a block Swift has not confirmed yet). */
export function isTempBlockId(id: string): boolean {
  return id.startsWith(TEMP_ID_PREFIX);
}

/**
 * One observer of Swift's temp -> permanent id confirmations (the undo coordinator, which keeps a log per saved structural
 * operation: see `UndoRegistryEntry.confirmLog`). Registered from the coordinator rather than imported here, because the
 * coordinator already imports this module. Called with every confirmation, before it is queued below.
 */
let confirmationListener: ((mapping: Record<string, string>) => void) | null = null;
export function setConfirmationListener(listener: ((mapping: Record<string, string>) => void) | null): void {
  confirmationListener = listener;
}

/**
 * Confirm a temp ID with a permanent ID from Swift
 */
export function confirmBlockId(tempId: string, permanentId: string): void {
  confirmationListener?.({ [tempId]: permanentId });
  pendingConfirmations.set(tempId, permanentId);
}

/**
 * Confirm multiple temp IDs at once
 */
export function confirmBlockIds(mapping: Record<string, string>): void {
  confirmationListener?.(mapping);
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
 * — read at `oldPos`, the MAPPED old position (see the `oldPos` paragraph
 * below), not at bare offset equality with the new node — and the new node's
 * text — i.e. the claim must look like an in-place edit/conversion of the
 * SAME content, not an unrelated node that happened to land on the same
 * offset. Atomic same-type claims (figure/math_display) are exempt from the
 * content check — their
 * content (image src/alt, LaTeX) has no meaningful prefix/suffix relationship,
 * and same-type-atomic slot reuse under churn is a narrow, accepted risk.
 *
 * `recentlySplitEmptyIds` (8th param, defaulted to an empty set for callers
 * that don't track it) lets a legitimate split-then-fill bypass the content
 * check even though `meaningfulTextOverlap` alone would refuse it — see
 * `canClaimViaRecentSplitBypass`, the single source of truth for that bypass.
 *
 * `oldPos`/`deletedOldPositions` (9th/10th params, both optional) route
 * through to `canClaimUnderStructuralChange` in place of
 * `canClaimViaRecentSplitBypass` directly — see that function for what they
 * guard against (a citation-only paragraph and a genuinely-empty paragraph
 * being textually indistinguishable when the citation paragraph itself was
 * deleted). Omitting them (callers with no transaction `Mapping` available)
 * preserves the exact pre-existing behavior, since an empty
 * `deletedOldPositions` never triggers the refusal. `oldPos` may be the
 * MAPPED old position `assignBlockIds`'s Phase 1 resolved via `tr.mapping`
 * (its `oldByNewOffset`/`tracked` lookup), not necessarily numerically equal
 * to the block's own new offset — this function only ever compares it
 * against `deletedOldPositions`. That distinction DOES change outcomes here,
 * not only for the caller's `oldText`: `deletedOldPositions` is keyed by OLD
 * positions, and before Phase 1 followed the mapping, callers passed the
 * bare NEW offset into this parameter — an old/new coordinate mismatch that
 * made the `deletedOldPositions.has(oldPos)` check compare against the wrong
 * space for any shifted block. Passing the mapped `oldPos` makes that
 * refusal fire correctly for shifted blocks — a genuine behaviour change,
 * not a no-op passthrough.
 *
 * `replacedOccupant` (11th param, defaulted to `false`) is the t-452ca407
 * raw-fallback `flagged` signal, passed through for the CROSS-TYPE branch
 * only: when the claim is a same-offset raw fallback whose old occupant was
 * wholly replaced (not merely edited), AND both the old and new node are
 * empty, AND the claim crosses type (paragraph <-> heading, etc.), it is
 * refused outright rather than falling through to
 * `canClaimUnderStructuralChange`. An empty-to-empty claim always passes
 * `meaningfulTextOverlap('', '')` (byte-identical, trivially true), so
 * without this refusal a brand-new, unrelated empty node of a DIFFERENT type
 * from the one it replaced would inherit that occupant's id purely from
 * position coincidence — there is no textual evidence of relatedness left to
 * check once both sides are empty, and a changed type is itself evidence
 * AGAINST relatedness (a same-type empty-to-empty claim, e.g. Enter
 * splitting off a new empty paragraph next to another empty one, is exactly
 * the case the split-bypass exists to allow, so this refusal is scoped to
 * the cross-type branch alone — see `canClaimViaRecentSplitBypass`). A
 * non-empty cross-type replace is unaffected: it still goes through
 * `canClaimUnderStructuralChange`'s ordinary text-overlap gate exactly as
 * before, since only the double-empty case reaches this refusal.
 *
 * `newSideLeaf` (12th param, defaulted to `false`) narrows `replacedOccupant`
 * further: the refusal above does NOT fire when the NEW node is a
 * schema-level LEAF type (hr, section_break — types with no content
 * expression at all, whose `textContent` is ALWAYS ''). Discovered via a
 * real regression, not anticipated by this refusal's original design:
 * Milkdown's own `insertHrInputRule` converts an empty paragraph to `hr` via
 * the EXACT SAME same-offset, cross-type, wholly-replaced `replaceWith`
 * shape as the illegitimate replace-variant theft this refusal targets —
 * verified empirically to be indistinguishable at the `tr.mapping` level
 * (identical deletedAcross/deletedAfter/deletedBefore/deleted flags in both
 * cases). A leaf type's emptiness is not evidence of anything — it can
 * never be otherwise — so refusing on it would punish a legitimate
 * conversion exactly as often as it catches a real theft. Paragraph/heading
 * (the shape the original F4 bug and this refusal are actually about)
 * normally DO carry distinguishing text and are only coincidentally
 * both-empty in the illegitimate shape, so the refusal's own reasoning
 * still holds fully for them; `newSideLeaf` simply keeps it from reaching
 * claims where the destination type never had text to begin with.
 *
 * Deliberately checks ONLY the new side, not the old side too: an EARLIER
 * version of this parameter also exempted a leaf OLD occupant, but that
 * reopens a real theft — an hr (or section_break) deleted as part of a
 * LARGER selection (not a lone single-span replace; that shape is already
 * refused by `deletedOldPositions`'s own `deletedAfter && !deletedAcross`
 * check above) reports `deletedAcross`, not the single-span shape that
 * check catches, so the hr's own old position never enters
 * `deletedOldPositions` — with the old side exempted too, an unrelated
 * empty PARAGRAPH or HEADING landing at that hr's old offset would inherit
 * the hr's id outright, exactly the theft this refusal exists to close,
 * just with the hr as the victim instead of the thief. The new-side-only
 * check has no such gap: it only ever exempts a claim whose DESTINATION is
 * leaf, and a leaf destination can never be the "old, wrongly-emptied
 * victim" in that shape (the victim is always whatever the raw fallback's
 * existing id belonged to, i.e. the OLD side). See
 * `block-id-phase1.test.ts`'s "replacedOccupant (F4 replace variant)" suite
 * for both the exemption and this reverse-direction regression pinned
 * side by side.
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
  recentlySplitEmptyIds: ReadonlySet<string> = new Set(),
  oldPos?: number,
  deletedOldPositions: ReadonlySet<number> = new Set(),
  replacedOccupant = false,
  newSideLeaf = false
): boolean {
  if (!existingId) return false;
  if (claimed.has(existingId)) return false;

  if (existingType === newType) {
    if (ATOMIC_BLOCK_TYPES.has(newType)) return true;
    if (!structureChanged) return true;
    return canClaimUnderStructuralChange(
      oldText,
      newText,
      existingId,
      recentlySplitEmptyIds,
      oldPos,
      deletedOldPositions
    );
  }
  if (existingType === undefined) return false;
  if (ATOMIC_BLOCK_TYPES.has(existingType)) return false;
  if (ATOMIC_BLOCK_TYPES.has(newType)) return false;
  if (replacedOccupant && !newSideLeaf && oldText === '' && newText === '') return false;
  if (!structureChanged) return true;
  return canClaimUnderStructuralChange(
    oldText,
    newText,
    existingId,
    recentlySplitEmptyIds,
    oldPos,
    deletedOldPositions
  );
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
 * because `existingId` is a RECENTLY SPLIT node that is still empty.
 * Intended shape: Enter splits off a new empty node and marks it; a later
 * fill of that SAME node reclaims its marked id. This is the single source
 * of truth for the bypass condition; every structural claim site that would
 * otherwise call `meaningfulTextOverlap` alone as its final gate must route
 * through this instead, so the sites cannot drift out of sync with each
 * other. Exported for tests.
 *
 * This predicate does not check WHICH block is doing the claiming — only
 * that the old text is empty and the id is marked. The narrowness comes from
 * the CALLER, not from here: `assignBlockIds`'s Phase 1 mapped-position
 * lookup (00f10ef4) follows each existing id to where the transaction's
 * mapping actually carried it before this bypass is ever consulted, so a
 * block whose start survived the mapping is never compared against another
 * block's marked id at all — this closed the former F3 misattribution (a
 * content-bearing block losing its own id to a stale split marker). What
 * still reaches this bypass by raw offset alone is a block whose own start
 * did NOT survive the mapping (a brand-new block, or one replaced in place);
 * such a block has no earlier id of its own to lose, so a same-empty-slot id
 * reassignment there is harmless.
 *
 * Not independently re-verified by this pass: Phase 2's proximity-matching
 * route to this same bypass, for deferred blocks — see task-inbox t-af5087af.
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
 * Structural-change gate that sits in front of `canClaimViaRecentSplitBypass`
 * for every claim site that has a transaction `Mapping` available. Fixes the
 * citation-atom-blindness gap: `Node.textContent` strips inline atom nodes
 * (citations), so a citation-only paragraph and a genuinely-empty paragraph
 * both report `oldText === ''` — textually indistinguishable to
 * `meaningfulTextOverlap`/`canClaimViaRecentSplitBypass`. When the citation
 * paragraph is deleted and an unrelated blank paragraph slides into
 * proximity, the two were previously equally valid candidates and pure
 * offset-distance decided the (wrong) winner.
 *
 * `deletedOldPositions` (precomputed once per `assignBlockIds` call from the
 * transaction's `Mapping` — see there) names old positions whose content was
 * structurally deleted, not merely edited in place. Only an `oldText === ''`
 * claim at one of those positions is refused — this is the ONLY new
 * refusal this function adds. Deliberately narrow: it does NOT refuse
 * claims at deleted positions in general, because a whole-document
 * replace/paste-over-selection marks EVERY old position deleted while
 * text overlap there can still be entirely genuine (see the
 * `deletedAcross` semantics `Mapping.mapResult` documents) — refusing
 * broadly would strip every block's identity on those transactions.
 * `oldPos` undefined (caller has no position context) or `deletedOldPositions`
 * empty (no `Mapping` supplied) never triggers the refusal, so this is a
 * strict narrowing of `canClaimViaRecentSplitBypass`'s existing behavior,
 * not a replacement policy. Exported for tests.
 *
 * Accepted cost: an empty block whose old position falls strictly inside
 * ANY multi-block replace range loses its identity under this guard,
 * whether or not it was genuinely destroyed — deliberate collateral of
 * keeping the refusal narrow, not a bug.
 *
 * Chose `Mapping`-based deletion detection over the pre-existing
 * `isBlankDueToExemptAtom` predicate (which already distinguishes "blank
 * because of a citation atom" from "genuinely blank" without needing a
 * `Mapping`) because that predicate inspects a single node's current
 * content and has no way to say whether the OLD block at a position was
 * structurally removed by this transaction — only
 * `Mapping.mapResult(...).deletedAcross` records that.
 *
 * Known gap, deliberately not widened: cursor at the start of a
 * citation-only paragraph + Backspace produces `DEL_BEFORE`, not
 * `DEL_ACROSS`, at the paragraph's own content position, so this guard
 * doesn't catch that shape.
 */
export function canClaimUnderStructuralChange(
  oldText: string | undefined,
  newText: string,
  existingId: string,
  recentlySplitEmptyIds: ReadonlySet<string> = new Set(),
  oldPos?: number,
  deletedOldPositions: ReadonlySet<number> = new Set()
): boolean {
  if (oldText === '' && oldPos !== undefined && deletedOldPositions.has(oldPos)) return false;
  return canClaimViaRecentSplitBypass(oldText, newText, existingId, recentlySplitEmptyIds);
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

/** Pure result of `alignTopLevelIds` — see that function's doc comment. */
export interface AlignedTopLevelIds {
  blockIds: Map<number, string>;
  blockTypes: Map<number, string>;
  assigned: Array<{ i: number; id: string; offset: number; type: string }>;
  mismatches: Array<{ index: number; offset: number; reason: string }>;
  /** How many orderedIds slots were actually walked (index-in-lockstep count) — compare
   * against `orderedIds.length` for the parity check the caller logs. */
  walked: number;
}

/**
 * Pure alignment core extracted from `setBlockIdsForTopLevel` (no behavior change) — computes
 * the id/type maps an ordered id array aligns to on `doc`, without touching module state or
 * logging. `setBlockIdsForTopLevel` below is now a thin wrapper: it calls this, commits the
 * result into `currentBlockIds`/`currentBlockTypes`, and does the existing logging. Exported so
 * tests and other pure callers (e.g. a future merge/diff helper) can compute an alignment
 * without any of this module's side effects.
 */
export function alignTopLevelIds(orderedIds: string[], doc: Node, expected?: ExpectedBlockMeta[]): AlignedTopLevelIds {
  let index = 0;
  const blockIds = new Map<number, string>();
  const blockTypes = new Map<number, string>();
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
        blockIds.set(offset, orderedIds[index]);
        blockTypes.set(offset, node.type.name);
        if (SYNC_DIAG_DETAIL) {
          assigned.push({ i: index, id: orderedIds[index], offset, type: node.type.name });
        }
      } else {
        mismatches.push({ index, offset, reason });
        // Deliberately NOT recording into blockIds/blockTypes here — the id is WITHHELD, not
        // aliased onto the wrong node. This slot gets a fresh temp id on the next
        // assignBlockIds pass (safe — see plan notes on the withheld-id trace), instead of
        // silently attaching a real DB row's identity to content it doesn't belong to.
      }
      index++; // increment regardless of ok/mismatch — positional accounting vs. orderedIds
      // must stay in lockstep or every later comparison desyncs.
    }
  });
  return { blockIds, blockTypes, assigned, mismatches, walked: index };
}

/**
 * Set block IDs for top-level nodes from an ordered array of IDs.
 * Matches BlockParser.parse() which creates one block per top-level node.
 * Uses doc.forEach() (top-level only, NOT doc.descendants()) — via `alignTopLevelIds`, above.
 *
 * `expected` (optional, 3rd param) is a per-id ground-truth array from the Swift side
 * (BlockParser.alignmentPairs) enabling an alignment sanity check beyond the pre-existing
 * count-parity check below: for each slot, if the expected PM type doesn't match the actual
 * node's type, or the expected non-blank text doesn't match an actually-blank node (net of the
 * atomic/citation exemptions), the id is WITHHELD rather than assigned. Omitting `expected`
 * (2-arg call, or passing undefined explicitly) skips this check entirely and preserves the
 * pre-existing behavior.
 */
export function setBlockIdsForTopLevel(orderedIds: string[], doc: Node, expected?: ExpectedBlockMeta[]): void {
  const result = alignTopLevelIds(orderedIds, doc, expected);
  // IN-PLACE, SELECTIVE `.set()` -- two separate invariants, both load-bearing, neither
  // satisfied by a naive clear-then-repopulate:
  //
  // 1. Same Map OBJECTS, never reassigned: `redecorateBlockIds`'s whole safety argument
  //    (api-content.ts) depends on `currentBlockIds`/`currentBlockTypes` staying the SAME Map
  //    objects the block-id plugin's own internal state (`pluginState.blockIds`, read by
  //    `decorations(state)`) captured a reference to at the last real (docChanged) transaction.
  //
  // 2. NO `.clear()` before repopulating: a WITHHELD (mismatched-`expected`) slot must keep
  //    whatever id was already on record for that offset, not lose it. `syncBlockIds()` (the
  //    only caller that reaches this function WITHOUT a preceding `clearBlockIds()`) depends on
  //    this -- a `.clear()` here wipes every withheld slot's pre-existing entry, dropping its
  //    `data-block-id` decoration from the DOM entirely (block count changes) instead of simply
  //    leaving that slot's REAL, un-mismatched id in place. Regression caught by
  //    `BlockIdAlignmentHardeningLiveTests.testMismatchedExpectedMetadata_idWithheldNotAliased_mismatchReported`.
  //    Callers that DO want a full reset (`setContentWithBlockIds`, `applyBlocks`) already call
  //    `clearBlockIds()` themselves immediately before this function -- this function must not
  //    duplicate that decision on their behalf, since `syncBlockIds()` deliberately never makes it.
  for (const [offset, id] of result.blockIds) currentBlockIds.set(offset, id);
  for (const [offset, type] of result.blockTypes) currentBlockTypes.set(offset, type);
  const { assigned, mismatches, walked: index } = result;
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
 * Rewrite ONLY `currentBlockIds`/`currentBlockTypes` from an ordered array of ids that is
 * already known to align 1:1 with `doc`'s top-level `isBlockType` nodes, in order — no
 * type/content alignment check (unlike `setBlockIdsForTopLevel`/`alignTopLevelIds`), because the
 * caller (`mergeManagedBlocks`'s consumer, api-content.ts's `setContentWithBlockIds` under
 * `options.preserveUserBlocks`) already built `idsByIndex` by construction: each user entry
 * keeps its own prior id, each managed entry gets its freshly-pushed id — there is nothing left
 * to validate. Wholesale replace (like `setBlockIdsForTopLevel`), not a merge onto the existing
 * maps: a stale offset from a differently-shaped previous doc must not survive.
 */
export function replaceTopLevelIds(idsByIndex: string[], doc: Node): void {
  const blockIds = new Map<number, string>();
  const blockTypes = new Map<number, string>();
  let index = 0;
  doc.forEach((node, offset) => {
    if (isBlockType(node) && index < idsByIndex.length) {
      blockIds.set(offset, idsByIndex[index]);
      blockTypes.set(offset, node.type.name);
      index++;
    }
  });
  // IN-PLACE, not a reassignment -- see setBlockIdsForTopLevel's matching comment above for why.
  currentBlockIds.clear();
  for (const [offset, id] of blockIds) currentBlockIds.set(offset, id);
  currentBlockTypes.clear();
  for (const [offset, type] of blockTypes) currentBlockTypes.set(offset, type);
  if (index !== idsByIndex.length) {
    syncLog('BlockId:replaceTopLevelIds', `PARITY MISMATCH: assigned ${index} of ${idsByIndex.length} ids`);
  }
}

/**
 * Give the top-level blocks at `positions` the permanent ids in `ids` (parallel arrays: `ids[i]` belongs to the block starting at
 * `positions[i]`), IN PLACE in `currentBlockIds` -- the same Map object the plugin's own state and `getAllBlockIds` read, see
 * `setBlockIdsForTopLevel`'s comment on why it is never reassigned. The block types stay as the plugin recorded them.
 *
 * For an operation that inserts blocks whose permanent ids it already holds: the editor-first duplicate mints a fresh UUID per
 * copied block (`generateBlockId`), dispatches the insertion, and calls this right after the dispatch. The plugin's `apply` has by
 * then given each inserted block a `temp-` id (it has no other way to name a block it did not see before); this replaces it, so
 * block-sync's re-baseline (`resetAndSnapshot`) records the copy under its permanent id and the copy is never reported as an
 * insert, and typing in it later is an UPDATE of that id.
 *
 * Call it on the document the positions were taken from (right after the inserting dispatch, before anything else changes the
 * document). It does NOT repaint: `data-block-id` is a decoration that only recomputes on a transaction, so the caller dispatches
 * a step-less transaction afterwards (api-content.ts `redecorateBlockIds` is the established technique).
 */
export function setTopLevelIdsAt(positions: readonly number[], ids: readonly string[]): void {
  if (positions.length !== ids.length) {
    throw new Error(`setTopLevelIdsAt: ${positions.length} positions but ${ids.length} ids`);
  }
  for (let i = 0; i < positions.length; i++) {
    const previous = currentBlockIds.get(positions[i]);
    // A split-empty marker names the temp id being replaced; the marker is for that dead id only.
    if (previous !== undefined && isTempBlockId(previous)) recentlySplitEmptyIds.delete(previous);
    currentBlockIds.set(positions[i], ids[i]);
  }
}

/**
 * Re-point the block-id plugin's state in `state` at the live offset -> id map (`currentBlockIds`). For a state that was swapped in whole
 * (`view.updateState(savedState)`, the structural checkpoint swap): that state's plugin state still names the Map object it had when
 * it was saved, and every docChanged transaction since replaced `currentBlockIds` with a new Map (`apply`), so the saved Map holds the
 * ids the blocks had back then. `decorations()` paints `data-block-id` from the plugin state, so without this the swapped-in document
 * would paint those old ids until the next document-changing transaction, whatever `setBlockIdsForTopLevel` has put in the live map.
 * The next `apply` re-aliases the state itself (it reads `currentBlockIds`, never `value.blockIds`). Call it after the ids are set and
 * before the step-less dispatch that repaints. It mutates the plugin-state object of `state`, which for a swapped-in checkpoint IS the
 * saved object: that is the point, the saved state becomes the live state.
 */
export function pointPluginStateAtLiveIds(state: EditorState): void {
  const pluginState = blockIdPluginKey.getState(state);
  if (pluginState) pluginState.blockIds = currentBlockIds;
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
 *
 * `mapping` (optional 5th param — the transaction's `tr.mapping`) enables the
 * `canClaimUnderStructuralChange` guard against citation-atom blindness: see
 * that function's doc comment. Omitted (the plugin's `init` call site, which
 * has no prior transaction) or absent, the guard never refuses anything —
 * identical to this function's pre-existing behavior.
 *
 * `mapping` also drives Phase 1 itself, independent of
 * `canClaimUnderStructuralChange`: when both `mapping` and `oldDoc` are
 * present, Phase 1 looks each existing id up at the position `tr.mapping`
 * carried its old start to, not at the bare new offset — see the
 * `oldByNewOffset`/`tracked` comment inside this function for the full
 * mechanism and the note on collisions. Omitting `mapping` (or supplying it
 * without `oldDoc`) falls back to the pre-existing bare-offset behavior
 * entirely — Phase 1 trusts raw offset equality exactly as before.
 *
 * A single block replaced by a different block in one transaction with
 * unchanged block count still takes the same-offset fallback — its start is
 * AT the start of the replaced range (not merely somewhere inside it —
 * `deleted` comes from `pos == start` together with `pos != end` setting the
 * DEL_SIDE case). t-452ca407: that fallback claim is no longer auto-granted
 * just because the block count happens to be unchanged. When the OLD block at
 * that offset was wholly replaced (a leaf node, or `deletedAcross` at its
 * content position — see the `flagged` computation in Phase 1, below), the
 * claim is routed through the same text-relatedness check
 * (`canClaimUnderStructuralChange`/`meaningfulTextOverlap`) every other claim
 * already goes through under structural change, rather than being trusted on
 * position alone — otherwise an unrelated new block silently inherits a
 * deleted block's id (and, symmetrically, Phase 2's per-block proximity
 * branch — reached when Phase 1 refuses a flagged claim — carries the same
 * text check forward instead of handing the id out by proximity alone; see
 * that branch's own comment). A same-offset claim that is NOT flagged (its
 * old block's start genuinely survived the mapping, or the key is stale, or
 * the whole-document-replace shape from the paragraph above) keeps trusting
 * position outright, exactly as before — this is a narrowing of the fallback,
 * not a new check on every claim.
 *
 * `appOrigin` (optional 6th param, default `false`) exempts a transaction
 * from that narrowing entirely, keeping the pre-existing position-only trust
 * for every claim it makes — for a programmatic content push, "the old and
 * new block happen to be textually unrelated" is not evidence of an
 * unrelated block sliding into a deleted one's slot, since the push itself
 * authored both sides. The block-id plugin's `apply` passes
 * `getIsSettingContent()` (editor-state.ts) as this argument; `init` and
 * every other existing caller omit it and get the default `false`. As of
 * this writing that flag is set (via `setIsSettingContent`/
 * `withSettingContent`) around exactly these call sites in
 * `web/milkdown/src/`: `setEditorMode`'s mode-switch re-parse and its
 * heading-prefix strip/insert steps (api-modes.ts), `renumberFootnotes`
 * (footnote-plugin.ts), `updateHeadingLevels`, `applyBlocks`, `setContent`,
 * `setContentWithBlockIds`, and `resetForProjectSwitch` (all api-content.ts —
 * the last of these calls `setIsSettingContent(false)` unconditionally,
 * api-content.ts:846,865, not as a true/false pair around one dispatch, but
 * it still belongs on this list since it's a site that touches the flag) —
 * re-grep
 * `setIsSettingContent(true)` and `withSettingContent(` across this
 * directory before relying on this list; it is not enforced to stay in sync.
 *
 * Under a transaction where structure DOES change, the same-offset fallback
 * was already gated by `canClaimUnderStructuralChange`/`meaningfulTextOverlap`
 * like every other claim; that is unchanged here. Skipping the gate when
 * structure is unchanged AND the claim is unflagged is deliberate, because it
 * is what keeps a whole-document replace (exactly the shape in the paragraph
 * above, at every block at once) from mass-deleting ids.
 * Exported for tests.
 */
export function assignBlockIds(
  doc: Node,
  existingIds: Map<number, string>,
  existingTypes: Map<number, string>,
  oldDoc: Node | undefined,
  mapping?: Mapping,
  appOrigin = false
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

  // Precompute, once per call and only when it can matter (structural
  // changes are the only consumer — see phase1CanClaim/Phase 2 below — so
  // gating on `structureChanged` too keeps the ordinary-keystroke hot path
  // free of this work), which `existingIds` positions were structurally
  // deleted by this transaction (as opposed to merely edited in place) —
  // feeds `canClaimUnderStructuralChange`'s oldText==='' refusal.
  // `oldPos + 1` targets the position just inside the block's open token
  // (its content position for an empty node) for ordinary container block
  // types. Caveat: for leaf block types with `nodeSize === 1` (e.g. `hr`,
  // `section_break` — not in `ATOMIC_BLOCK_TYPES`), there is no "inside" —
  // `oldPos + 1` lands just AFTER the node, at a sibling boundary, not
  // within it, so this precompute alone misses a leaf's own deletion (it
  // never carries text for the oldText==='' check to act on either way).
  // t-452ca407 follow-up: this WAS a real, reproducible gap for `hr`/
  // `section_break` — a same-offset leaf replace with an unchanged block
  // count silently inherited the deleted leaf's id via
  // `meaningfulTextOverlap('', '')`'s empty-vs-empty match. Closed
  // separately, not here: Phase 1's `flagged` computation (below) checks
  // `mapping.mapResult(lookupPos, 1).deletedAfter` directly on the leaf's
  // own position span and records it into `deletedOldPositions` itself,
  // regardless of `structureChanged` — see that check's own comment.
  //
  // Guards against stale coordinate-space keys: `currentBlockIds` itself
  // IS replaced wholesale every transaction (see the two direct
  // `currentBlockIds = blockIds` reassignments in this plugin's
  // `state.init`/`state.apply` below), so staleness can't survive a normal
  // transaction round-trip. The real gap is `setBlockIdsForTopLevel`, which
  // `syncBlockIds` (api-content.ts) can call directly between transactions
  // without a preceding `clearBlockIds()` — it only `.set()`s the offsets
  // present in whatever doc it's given and never prunes offsets left behind
  // by an earlier, larger doc, so a stray offset can survive into the next
  // transaction's `existingIds`. Node existence alone isn't sufficient
  // proof — a different-typed node could coincidentally occupy that offset
  // — so this also requires the resolved node's type to match the type on
  // record for that position.
  // Shared O(n) index for the two stale-key checks below (this one, and
  // Phase 1's mapped-lookup loop right after it): a single `oldDoc.forEach`
  // pass over its top-level children, position -> type name. Both loops used
  // to call `safeNodeAt(oldDoc, oldPos)` (== `Node.nodeAt`, which linearly
  // scans `Fragment.findIndex` — verified against prosemirror-model's
  // source) once per `existingIds` entry; Phase 1's loop runs on EVERY
  // doc-changing transaction, keystrokes included (unlike this
  // `structureChanged`-gated one), so that made the whole call O(n²) per
  // keystroke, not O(n) as intended. One shared map keeps both checks O(1)
  // each, for O(n) total. Built whenever `mapping && oldDoc` — Phase 1's own
  // loop needs it unconditionally on that pair; gating it further on
  // `structureChanged` here too would just rebuild it a second time below.
  const oldTypeByPos = new Map<number, string>();
  if (mapping && oldDoc) {
    oldDoc.forEach((node, offset) => {
      oldTypeByPos.set(offset, node.type.name);
    });
  }

  const deletedOldPositions = new Set<number>();
  if (mapping && structureChanged) {
    for (const oldPos of existingIds.keys()) {
      if (oldTypeByPos.get(oldPos) !== existingTypes.get(oldPos)) continue;
      if (mapping.mapResult(oldPos + 1).deletedAcross) {
        deletedOldPositions.add(oldPos);
      }
    }
  }

  // Phase 1 mapped lookup (F1a fix): for every existing id, follow
  // tr.mapping to the NEW position its OLD start actually landed at, instead
  // of trusting that a block sharing its numeric offset is the same block.
  // Without this, a same-type/same-shape sibling that slides onto another
  // block's old offset (a multi-character insert/delete elsewhere in the
  // doc, or one keystroke before two back-to-back atomic/leaf blocks) takes
  // that other block's id via the old bare `existingIds.get(offset)` lookup
  // — the F1a bug. `oldByNewOffset` maps each surviving old position's
  // mapped NEW position back to that old position; `tracked` is every old
  // position that survived the mapping at all.
  const oldByNewOffset = new Map<number, number>(); // new offset -> old position
  const tracked = new Set<number>(); // old positions
  // old position -> the NEW position `tracked.add`'s own r.pos mapped it to
  // — same values as `oldByNewOffset`'s keys, just indexed the other
  // direction so Phase 1 can ask "where did THIS numeric old position end
  // up?" in O(1). Feeds the wrap containment check below (review finding 1).
  const trackedNewPos = new Map<number, number>();
  if (mapping && oldDoc) {
    const collided = new Set<number>();
    for (const oldPos of existingIds.keys()) {
      if (oldTypeByPos.get(oldPos) !== existingTypes.get(oldPos)) continue; // stale key: stays raw-eligible
      const r = mapping.mapResult(oldPos, 1); // assoc=1: an insert exactly at a block's start pushes that block right
      if (r.deleted) continue; // start was replaced: stays raw-eligible (fallback)
      tracked.add(oldPos);
      trackedNewPos.set(oldPos, r.pos);
      if (oldByNewOffset.has(r.pos)) {
        collided.add(r.pos);
        continue;
      }
      oldByNewOffset.set(r.pos, oldPos);
    }
    // The `tracked` set, stated exactly:
    //
    // What it holds. `tracked` holds OLD positions: every `existingIds` key
    // whose start survived the transaction per the mapping (valid key, not
    // `deleted`).
    //
    // The mixing is intended. Phase 1's fallback below tests a NEW offset
    // against this OLD-position set on purpose. The fallback is the old raw
    // lookup `existingIds.get(offset)`, which already reads the old-position
    // key that is numerically equal to the new offset. `tracked.has(offset)`
    // asks one question: has the block that used to live at that number been
    // accounted for somewhere by the mapping? If yes, the raw lookup would
    // hand its id to whatever landed on its old number, which is exactly the
    // F1a theft. So that raw lookup is refused.
    //
    // Collisions. When two surviving old positions map to the same new
    // position, both stay in `tracked` and both are removed from
    // `oldByNewOffset`. Neither can be claimed in Phase 1, either by mapped
    // position or by raw offset. Their ids stay unclaimed and both blocks
    // defer to Phase 2 (proximity). No real collision could be constructed
    // for a test — mapping is monotonic, and a survivor never shares a
    // mapped position with another survivor — so this is a defensive rule
    // with no test.
    for (const p of collided) oldByNewOffset.delete(p);
  }

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
  const deferred: Array<{ offset: number; nodeType: string; nodeText: string; flagged: boolean }> = [];

  // Zoom mode: only the mini-Notes tail is exempt from temp IDs (see zoomNotesBoundary)
  const notesBoundary = blockIdZoomMode ? zoomNotesBoundary(doc) : Infinity;

  // Phase 1: mapped-position matches. Each existing id is looked up at the
  // position `tr.mapping` actually carried its old start to (`oldByNewOffset`/
  // `tracked`, computed above), not at the bare new offset — see those
  // structures' comment for why a raw-offset match would hand a shifted
  // block's id to whatever else happens to land on its old number (F1a).
  // `phase1CanClaim` then enforces the type gate that prevents atomic-type
  // (figure) theft from position-shifted paragraphs while still admitting
  // legitimate input-rule conversions (paragraph↔heading, paragraph↔list,
  // paragraph↔table, etc.).
  doc.forEach((node, offset) => {
    if (isBlockType(node)) {
      // `oldByNewOffset.get(offset)` is the mapped-position match. Falling
      // back to `offset` itself is only valid when no tracked old position
      // claims this new offset at all — `tracked.has(offset)` true means
      // SOME survivor's old position numerically equals this new offset, but
      // its own mapped destination is elsewhere, so treating `offset` as
      // that survivor's old position here would be exactly the F1a theft.
      //
      // Exception (review finding 1 — wrap): when the tracked old position
      // numerically equal to `offset` mapped to somewhere STRICTLY inside
      // the new node sitting at `offset` (`offset < mappedPos < offset +
      // node.nodeSize`), that old block was WRAPPED, not displaced — Enter
      // toggling a paragraph into a blockquote or list always leaves the
      // wrapper starting at the wrapped block's own old offset, with the
      // wrapped block itself now nested one or more levels deeper inside it.
      // That is still `offset`'s own former occupant, so the raw fallback is
      // safe here specifically. A neighbour merely pushed right by an insert
      // lands exactly at `offset + node.nodeSize` (the sibling boundary, not
      // "inside" it), so the strict bound keeps ordinary F1a theft refused.
      const wrappedMappedPos = tracked.has(offset) ? trackedNewPos.get(offset) : undefined;
      const wasWrapped =
        wrappedMappedPos !== undefined && offset < wrappedMappedPos && wrappedMappedPos < offset + node.nodeSize;
      const lookupPos = oldByNewOffset.get(offset) ?? (tracked.has(offset) && !wasWrapped ? undefined : offset);
      const existingId = lookupPos === undefined ? undefined : existingIds.get(lookupPos);
      const existingType = lookupPos === undefined ? undefined : existingTypes.get(lookupPos);

      // t-452ca407: is this claim the RAW same-offset fallback (no mapped
      // match, no wrap) landing on a block whose old occupant was wholly
      // replaced? If so, position alone is not evidence this is the same
      // block — flag it for a content check in phase1CanClaim below, unless
      // this transaction is app-origin (appOrigin) or the key at this offset
      // is stale (oldTypeByPos disagrees with existingTypes, in which case
      // today's position-only trust is deliberately kept — see this
      // function's doc comment). `isLeaf` covers leaf block types (hr,
      // section_break) where `deletedAcross` at a "content position" isn't
      // meaningful (there is no "inside" — see the `oldPos + 1` caveat above).
      const isRawFallback = oldByNewOffset.get(offset) === undefined && lookupPos === offset && !wasWrapped;
      const flagged =
        isRawFallback &&
        lookupPos !== undefined &&
        mapping !== undefined &&
        oldDoc !== undefined &&
        !appOrigin &&
        oldTypeByPos.get(offset) === existingTypes.get(offset) &&
        !!(safeNodeAt(oldDoc, lookupPos)?.isLeaf || mapping.mapResult(lookupPos + 1, 1).deletedAcross);

      // t-452ca407 (required fix, leaf gap): a LEAF-TYPE block (hr,
      // section_break — types whose SCHEMA allows no content at all, not
      // merely a block that happens to be empty right now) never carries
      // text, so oldText and newText are always '' and
      // `meaningfulTextOverlap('', '')` trivially returns true — the
      // oldText==='' * `deletedOldPositions` refusal in
      // `canClaimUnderStructuralChange` is the ONLY thing that can catch a
      // same-offset leaf replace, but `deletedOldPositions` (precomputed
      // above) is populated only when the overall block count changed, via
      // an `oldPos + 1` probe that can't see a size-1 leaf's own deletion
      // anyway (see that computation's doc comment). Confirmed directly here
      // (the judge's requested check, not the `oldPos + 1` probe) via
      // `mapping.mapResult(lookupPos, 1)` on the leaf's own position span —
      // and recorded into `deletedOldPositions` regardless of
      // `structureChanged`, so both `canClaimUnderStructuralChange` below AND
      // Phase 2's per-block "structure unchanged" branch (which also now
      // reads `deletedOldPositions` — see its own comment) refuse the claim.
      //
      // Three deliberate narrowings, each pinned by a test that would
      // otherwise regress:
      //
      // 1. `oldTypeByPos.get(lookupPos) !== undefined` (not merely
      //    `flagged`'s own, weaker `oldTypeByPos.get(offset) ===
      //    existingTypes.get(offset)` check, which is trivially true when
      //    BOTH sides are undefined) — `lookupPos` for a raw-fallback claim
      //    is just a bare number with no guarantee it was ever a real
      //    top-level block boundary in `oldDoc`. `safeNodeAt` resolves ANY
      //    position, including one that lands inside a sibling's inline
      //    content, and a resolved text node reports `.isLeaf === true` same
      //    as an hr/section_break instance does (the text type and
      //    hr/section_break all have no content expression, so
      //    NodeType.isLeaf is true for them). Requiring a genuine recorded
      //    top-level entry at `lookupPos` rules that out: a text-node
      //    coincidence never has a `oldTypeByPos` entry of its own (that map
      //    is built from `oldDoc`'s top-level `forEach` only), so it can't
      //    pass.
      //
      // 2. `.type.isLeaf` written out explicitly here, rather than reusing
      //    the `?.isLeaf` check `flagged` (above) already computed — in the
      //    installed prosemirror-model, `Node.isLeaf` is defined as `return
      //    this.type.isLeaf` (a direct delegation, `dist/index.js`), so the
      //    two checks are EQUIVALENT schema-level flags (`contentMatch ==
      //    ContentMatch.empty`), not an instance-vs-schema distinction —
      //    spelled out here only for explicitness at this second call site.
      //    An empty paragraph is unaffected either way: paragraph's
      //    `contentMatch` is not empty, so `.isLeaf`/`.type.isLeaf` are both
      //    false for it regardless of whether it currently holds any text,
      //    so it stays eligible for the ordinary
      //    `meaningfulTextOverlap`/split-bypass route below, unaffected by
      //    this leaf-specific addition.
      //
      // 3. `deletedAfter && !deletedAcross` on the SAME `MapResult`, not
      //    `deletedAfter` alone (which is also true for `deletedAcross`,
      //    since that getter is `(delInfo & (DEL_AFTER | DEL_ACROSS)) > 0`).
      //    `pos === start` of a deleted range (this leaf's own tiny [P, P+1)
      //    span, replaced on its own) sets DEL_AFTER; `start < pos < end` of
      //    a LARGER deleted range (e.g. a whole-document replace spanning
      //    every block at once, even one reproducing byte-identical
      //    content) sets DEL_ACROSS instead. Excluding the latter keeps this
      //    addition narrow to "this exact leaf's own span was replaced",
      //    matching the file's existing philosophy (see
      //    `canClaimUnderStructuralChange`'s own doc comment on why its
      //    guard stays narrow rather than refusing every deletedAcross
      //    position) — a whole-document replace mid-range hit is left to
      //    trust position exactly as it already does for every other block
      //    type in that shape (pinned by the existing "(b) replacing the
      //    whole document with the same content keeps every id" test in
      //    block-id-phase1-mapping.test.ts, which includes an hr).
      //
      // Does NOT touch a drag-move (delete a leaf, reinsert the SAME node
      // elsewhere in one transaction): the reinserted node lands at a
      // DIFFERENT offset, which is never `flagged` here — whatever now sits
      // at the vacated offset is either nothing, or a survivor correctly
      // resolved through the mapped lookup (`oldByNewOffset`) rather than
      // this raw fallback — so the leaf's old position is never added here,
      // and Phase 2's proximity match still finds it freely.
      if (flagged && lookupPos !== undefined && mapping !== undefined && oldTypeByPos.get(lookupPos) !== undefined) {
        const oldLeafNode = safeNodeAt(oldDoc, lookupPos);
        if (oldLeafNode?.type.isLeaf) {
          const leafSpanResult = mapping.mapResult(lookupPos, 1);
          if (leafSpanResult.deletedAfter && !leafSpanResult.deletedAcross) {
            deletedOldPositions.add(lookupPos);
          }
        }
      }

      // Only compute text content when it's actually needed (structureChanged OR a
      // flagged raw-fallback claim gates the content check inside phase1CanClaim —
      // see meaningfulTextOverlap) — keeps the dominant hot path (ordinary
      // keystrokes, neither condition true) free of these lookups.
      const contentGate = structureChanged || flagged;
      const oldText = contentGate && lookupPos !== undefined ? safeNodeAt(oldDoc, lookupPos)?.textContent : undefined;
      const newText = contentGate ? node.textContent : '';
      // t-65a6a268 follow-up (discovered via repro-list-paste.test.ts's
      // real "---" -> hr integration test, not anticipated by this fix's
      // original plan): the replacedOccupant refusal below must NOT fire
      // when the NEW node is a schema-level LEAF type (hr, section_break —
      // no content expression at all, so `textContent` is ALWAYS ''
      // regardless of relatedness). Milkdown's own `insertHrInputRule`
      // converts an empty paragraph to `hr` via exactly the same
      // same-offset, cross-type, wholly-replaced `replaceWith` shape as the
      // illegitimate F4 replace-variant theft — verified empirically to be
      // BYTE-IDENTICAL at the `mapping.mapResult`
      // (deletedAcross/deletedAfter/deletedBefore/deleted) level, so no
      // structural signal distinguishes the two. A leaf DESTINATION's
      // "emptiness" carries no evidence of relatedness OR unrelatedness
      // either way (it can never be otherwise), unlike paragraph/heading,
      // which normally DO carry distinguishing text and are only
      // coincidentally both-empty in the shape this refusal targets — so
      // this exemption keeps the refusal scoped to destinations that could
      // actually have told the two apart. Checks ONLY `node.type.isLeaf`
      // (the NEW side), never the OLD occupant's leaf-ness: exempting the
      // old side too reopens a real theft in the OTHER direction — an hr
      // deleted as part of a LARGER selection (`deletedAcross`, not the
      // single-span `deletedAfter`-only shape `deletedOldPositions` already
      // catches above) never gets that old position recorded there, so an
      // unrelated empty paragraph/heading landing on its old offset would
      // inherit the hr's id if the old side were exempted too — see
      // `phase1CanClaim`'s own doc comment and
      // `block-id-phase1.test.ts`/`block-id-phase1-mapping.test.ts` for both
      // directions pinned. Gated on `flagged` (this is only ever consulted
      // when the refusal could otherwise fire) to keep the ordinary hot path
      // free of the extra lookup.
      const newSideLeaf = flagged && node.type.isLeaf;
      if (
        phase1CanClaim(
          node.type.name,
          existingType,
          existingId,
          claimedIds,
          contentGate,
          oldText,
          newText,
          recentlySplitEmptyIds,
          lookupPos,
          deletedOldPositions,
          flagged,
          newSideLeaf
        )
      ) {
        // Exact-position match (same type, or non-atomic type conversion).
        const finalId = resolveConfirmedId(existingId!);
        newIds.set(offset, finalId);
        newTypes.set(offset, node.type.name);
        claimedIds.add(finalId);
      } else {
        // Defer to Phase 2. nodeText carries the block's REAL text whenever
        // oldDoc is available — not only when contentGate is true — because
        // Phase 2's own per-block branch (t-452ca407) needs the real text to
        // refuse an unrelated claim even for a deferred block that wasn't
        // itself flagged here (MF-1: an empty placeholder would let that
        // branch hand out the id anyway).
        deferred.push({
          offset,
          nodeType: node.type.name,
          nodeText: contentGate || oldDoc !== undefined ? node.textContent : '',
          flagged,
        });
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
          if (
            !canClaimUnderStructuralChange(oldText, d.nodeText, id, recentlySplitEmptyIds, oldPos, deletedOldPositions)
          )
            continue;
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
    // t-452ca407: this branch USED TO have no content-relatedness check at
    // all — a deferred block reaching here (structureChanged false, so Phase
    // 1 refused it for some other reason — most often a flagged raw-fallback
    // claim, see Phase 1 above) could inherit an unrelated, unclaimed id by
    // pure proximity. It now requires the same text relatedness Phase 1 and
    // the structural Phase 2 branch already require, via the `sameType`
    // filter below — `d.nodeText` carries the block's real text for this
    // purpose (see the MF-1 note on the Phase 1 defer above), except when
    // `appOrigin` is true (a programmatic content push authored both sides,
    // so position-only trust is kept exactly as before), the candidate is an
    // atomic type (the existing figure/math_display exemption), or the
    // candidate was never flagged AND `oldDoc` is unavailable (the plugin's
    // `init` call, which has no old document to compare against at all —
    // position-only trust, unchanged).
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

      const sameType = candidates.filter(
        (c) =>
          existingTypes.get(c.pos) === d.nodeType &&
          (appOrigin ||
            (!d.flagged && oldDoc === undefined) ||
            ATOMIC_BLOCK_TYPES.has(d.nodeType) ||
            // t-452ca407 (required fix, leaf gap): routed through
            // `canClaimUnderStructuralChange` instead of calling
            // `canClaimViaRecentSplitBypass` directly, so this branch also
            // consults `deletedOldPositions` — otherwise a leaf candidate
            // Phase 1 already flagged-and-refused at its own old offset
            // (see Phase 1's `flagged`/`deletedOldPositions` comment) could
            // be silently re-granted right here via `c.pos === d.offset`,
            // distance 0, since `meaningfulTextOverlap('', '')` alone can't
            // tell a genuinely-deleted leaf from a moved one. Harmless for
            // every OTHER candidate: `deletedOldPositions` is populated only
            // for positions Phase 1 itself flagged this pass (never the
            // whole-doc `structureChanged` sweep, which never runs when this
            // `else` branch is reached at all — see assignBlockIds), so a
            // drag-moved leaf's true old position is never in it and this
            // substitution changes nothing for that case.
            canClaimUnderStructuralChange(
              safeNodeAt(oldDoc, c.pos)?.textContent,
              d.nodeText,
              c.id,
              recentlySplitEmptyIds,
              c.pos,
              deletedOldPositions
            ))
      );
      // Sort by distance ascending, tiebreak by pos (stable ordering) — matches
      // the structural branch's tiebreak above (`a.distance - b.distance ||
      // a.oldPos - b.oldPos`). `pos` here is the old position, the same value
      // as `oldPos` there. Without this tiebreak, a tie is broken by the
      // existingIds Map's insertion order — this branch does not scramble its
      // own output (its own assignments and temp ids are interleaved in
      // document/deferred order); the scramble comes from a *previous*
      // transaction that went through the structural branch: the previous
      // structural pass's Phase 2 (distance order), then its temp ids. That
      // order then gets carried forward as `currentBlockIds` into the next,
      // non-structural transaction — so an ordinary "type a character back"
      // edit after a split can swap two blocks' ids through this branch.
      // (Phase 1 itself no longer has a matching swap vector for blocks
      // WHOSE START SURVIVED THE MAPPING: F1a — a multi-character shift, or
      // one keystroke before two back-to-back atomic/leaf siblings such as
      // figures/rules/section breaks — is fixed by Phase 1's mapped lookup,
      // above, which follows each such existing id to where `tr.mapping`
      // actually carried its old start instead of trusting raw offset
      // equality. A block whose start was itself DELETED by the mapping
      // (`r.deleted`, see the tracked-loop comment above) still takes the
      // raw same-offset fallback — a multi-block replace or paste that
      // deletes two or more block starts while shifting offsets can still
      // route an unrelated block into this branch by coincidental offset.
      // t-452ca407 closes the actual theft this used to describe: `flagged`
      // (Phase 1, above) marks exactly that raw-fallback shape, and the
      // `sameType` filter's content check just above refuses the claim
      // unless the new block's text is actually related to the old one's —
      // pure coincidental-offset proximity, with no textual relationship, no
      // longer hands out the id. What remains open is narrower: a coincidence
      // where the new content genuinely IS textually related to the old (or
      // the key was stale, or the transaction is app-origin) still claims the
      // id, same as any other legitimate in-place edit would.)
      const best = sameType.length > 0 ? sameType.sort((a, b) => a.distance - b.distance || a.pos - b.pos)[0] : null;

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
        //
        // appOrigin (6th arg): getIsSettingContent() reflects whether THIS
        // transaction was dispatched from inside a setIsSettingContent(true)/
        // withSettingContent() window (see assignBlockIds's doc comment for
        // the real call-site list) — a programmatic content push, not typing.
        const [blockIds, blockTypes] = assignBlockIds(
          newState.doc,
          currentBlockIds,
          currentBlockTypes,
          oldState.doc,
          tr.mapping,
          getIsSettingContent()
        );
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

        // Add data-block-id attributes to top-level block nodes only. A block whose id is in
        // managedBlockIds (auto-generated Bibliography/Notes content) also gets `data-managed`
        // -- styles.css's ⌘-hover hint selector excludes managed headings via
        // `h1[data-block-id]:not([data-managed])` etc.
        state.doc.forEach((node, offset) => {
          if (isBlockType(node)) {
            const blockId = pluginState.blockIds.get(offset);
            if (blockId) {
              decorations.push(
                Decoration.node(offset, offset + node.nodeSize, {
                  'data-block-id': blockId,
                  ...(managedBlockIds.has(blockId) ? { 'data-managed': 'true' } : {}),
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
