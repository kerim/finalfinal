// Block ID Plugin for stable annotation anchoring
// Assigns unique block IDs to block-level nodes (paragraphs, headings, lists, etc.)
// These IDs survive edits elsewhere in the document.

import type { Node } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import type { Mapping } from '@milkdown/kit/prose/transform';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
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
  deletedOldPositions: ReadonlySet<number> = new Set()
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
 * unchanged block count still keeps the old id with no content gate — its
 * start is AT the start of the replaced range (not merely somewhere inside
 * it — `deleted` comes from `pos == start` together with `pos != end`
 * setting the DEL_SIDE case), so it takes the same-offset fallback. The "no
 * content gate" part holds specifically BECAUSE structure is unchanged here
 * — `phase1CanClaim`'s `!structureChanged` branch trusts position outright.
 * Under a transaction where structure DOES change, the same-offset fallback
 * is still gated by `canClaimUnderStructuralChange`/`meaningfulTextOverlap`
 * like every other claim; it is not itself exempt. Skipping the gate when
 * structure is unchanged is deliberate, because it is what keeps a
 * whole-document replace (exactly this shape, at every block at once) from
 * mass-deleting ids.
 * Exported for tests.
 */
export function assignBlockIds(
  doc: Node,
  existingIds: Map<number, string>,
  existingTypes: Map<number, string>,
  oldDoc: Node | undefined,
  mapping?: Mapping
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
  // within it. Still correct in practice today (traced separately: those
  // types don't carry meaningful text content for the oldText==='' check to
  // act on either way), but this is not the "content position" invariant
  // the name suggests for every block type.
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
  const deferred: Array<{ offset: number; nodeType: string; nodeText: string }> = [];

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
      // Only compute text content when it's actually needed (structureChanged gates
      // the content check inside phase1CanClaim — see meaningfulTextOverlap, which is
      // only reached when structureChanged is true) — keeps the dominant hot path
      // (ordinary keystrokes, structureChanged === false) free of these lookups.
      const oldText =
        structureChanged && lookupPos !== undefined ? safeNodeAt(oldDoc, lookupPos)?.textContent : undefined;
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
          recentlySplitEmptyIds,
          lookupPos,
          deletedOldPositions
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
      // hand out an id by coincidental offset; that shape is not what this
      // fix closes.)
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
        const [blockIds, blockTypes] = assignBlockIds(
          newState.doc,
          currentBlockIds,
          currentBlockTypes,
          oldState.doc,
          tr.mapping
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
