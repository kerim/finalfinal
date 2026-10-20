// Editor-first section reorder -- the editor half of the Outline sidebar's drag-to-reorder (t-0b70d1e9).
//
// Today a drag reads the whole document out of the editor, saves all of it, renumbers the rows in the database and pushes the whole
// document back into the editor; the push overwrites whatever the user typed meanwhile. Here the EDITOR moves the section first, in
// one synchronous JavaScript turn, and the database catches up afterwards as a queued write job (Swift side). Nothing is pushed back
// over the user's text. It is the duplicate's and the delete's twin (api-section-duplicate.ts, api-section-delete.ts): the same shared
// turn (`runEditorFirstChange`, editor-first-op.ts, whose header lists the steps and says what protects the editor while the change
// is dispatched) and the same reply discipline -- the batch of pending edits the call consumed comes back on EVERY path, and Swift
// always applies it.
//
// This file supplies the part that is the reorder's own, steps (e) and (f) of the shared turn:
//   (e) work out WHICH run of sections moves and WHERE it lands, from the new order Swift sends (`order`, every section leader in
//       final order, with a `level` on the headings whose level the plan changed);
//   (f) dispatch ONE transaction that cuts the moved top-level nodes out and puts the SAME node objects in at the target, plus the
//       level changes, then give every block its original id back, restore the selection and the scroll position.
// A range move, not a whole-document replace, is the point: the nodes outside the cut and the insertion point keep their spellcheck
// marks (remapped) and their place in the text-undo history (mapped), and the caret and the page do not jump. It is NOT a promise
// about DOM reuse: ProseMirror reuses views only for the unchanged prefix and suffix of the document, and between the cut and the
// insertion point it repurposes views one by one, so a long hop costs about that many view updates.
//
// The Notes and Bibliography region at the end of the document is found from the LIVE document (the managed entries, by the
// managedIds Swift read at the click and by the id-less bibliography marker atoms), never from the planned ids: a bibliography
// rebuild that lands between the plan and the click gives the Bibliography heading a fresh id the plan does not know. Nothing is
// ever moved into or out of that region: a run that goes to the end of the document lands in front of it, and a section's group
// ends where it starts.
//
// Which nodes belong to a section is the DATABASE's rule (Database+BlocksReorder.swift `groupBlocksBySections`): a node is a leader
// if and only if its id is in `order`; every other node belongs to the leader before it, and nodes before the first leader are the
// preamble. That is NOT `findSectionRange`'s rule (api-section-delete.ts), which groups by heading LEVEL and would split a section
// at a heading the sidebar does not list yet (one typed a moment ago). One id-less node needs care: the opening bibliography marker
// (`auto_bibliography`) is its own atom directly in front of the Bibliography heading, so it belongs to THAT heading's group.
//
// Spellcheck: the moved range is rechecked by the plugin's ordinary check, not by a call from here. Every document change makes the
// spellcheck plugin's view hook start a 400 ms debounce (spellcheck-plugin.ts `view().update` -> `debouncedCheck`), and that check
// sends the WHOLE document's text to Swift and replaces the marks with the answer. Until then the moved section has no marks (its
// old marks were dropped with the cut: `reconcileResultsAfterEdit` drops what a transaction touches and remaps the rest).

import { Fragment } from '@milkdown/kit/prose/model';
import { NodeSelection, type Selection, TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { isManagedEntry, type TopLevelEntry } from './api-section-delete';
import { getAllBlockIds, setTopLevelIdsAt } from './block-id-plugin';
import type { BlockChanges } from './block-sync-plugin';
import { runEditorFirstChange } from './editor-first-op';
import { markFootnoteRenumberAbsorbed } from './undo-coordinator';

/** One section leader of the final order. `level` is present only for a leader whose level the plan changed. */
export interface ReorderOrderEntry {
  id: string;
  level?: number | null;
}

/** What `reorderSectionsEditorFirst` returns, on every path. Swift reads it as `JSON.stringify(...)`, like `getBlockChanges`. */
export interface ReorderSectionsResult {
  /** Every pending edit this call consumed, in `getBlockChanges()` shape. Empty when nothing was pending. Swift always applies it. */
  batch: BlockChanges;
  ok: boolean;
  /** Why `ok` is false: 'noEditor', 'beginFailed', 'rootNotFound', 'planMismatch', 'managedMoved', or 'exception: <message>'. */
  reason?: string;
  /** Ids in `order` that the editor holds no top-level node for. They are dropped from the working order, never a reason to refuse;
   * Swift takes them out of the order it sends to its job. */
  skippedIds: string[];
  /** How many top-level nodes changed place (0 when only levels changed). */
  moved: number;
  /** How many headings had their level set. */
  levelChanges: number;
}

// Test seam (web tests only; production never sets it): runs right after the move was dispatched and its ids restored, before
// block-sync is re-baselined. A throw from it exercises the failure path a real error after the dispatch would take.
let afterMoveHook: (() => void) | null = null;
export function setTestAfterReorderHook(hook: (() => void) | null): void {
  afterMoveHook = hook;
}

/** What the reorder's mutator hands back through `runEditorFirstChange` on success. */
interface ReorderFacts {
  skippedIds: string[];
  moved: number;
  levelChanges: number;
}

/** A selection end as (id of the top-level block it sits in, offset from that block's start): it survives the block changing place.
 * `index` is the block's place among the top-level entries before the move. */
interface SavedPoint {
  id: string;
  offset: number;
  index: number;
}

/** Only a text or node selection is carried by id. AllSelection stays AllSelection under ProseMirror's own mapping, and any other
 * kind (a gap cursor, a table cell selection) keeps whatever the mapping makes of it. */
interface SavedSelection {
  kind: 'text' | 'node';
  anchor: SavedPoint;
  head: SavedPoint;
}

/** A block whose top edge must stay at the same screen height: `top` is its rect's top in viewport coordinates. */
interface ViewportAnchor {
  id: string;
  top: number;
}

function sameSequence(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((value, index) => value === b[index]);
}

/** Entry index where the group of the leader at entry index `leaderIndex` starts: the leader itself, or the opening bibliography
 * marker right in front of it (see the header). */
function groupStart(entries: readonly TopLevelEntry[], leaderIndex: number): number {
  return leaderIndex > 0 && entries[leaderIndex - 1].node.type.name === 'auto_bibliography'
    ? leaderIndex - 1
    : leaderIndex;
}

/** The entry that contains document position `pos` as (its block id, the offset from its start); null when it has no block id.
 * A position at the very end of the document belongs to the last entry (offset = its size). */
function locate(entries: readonly TopLevelEntry[], pos: number): SavedPoint | null {
  let lo = 0;
  let hi = entries.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (entries[mid].pos <= pos) lo = mid;
    else hi = mid - 1;
  }
  const entry = entries[lo];
  if (!entry || entry.id === undefined) return null;
  return { id: entry.id, offset: pos - entry.pos, index: lo };
}

/** Where an entry index sits against the run that moves: in front of it, inside it, or behind it. */
function sideOfRun(index: number, runStart: number, runEnd: number): 'before' | 'inside' | 'after' {
  if (index < runStart) return 'before';
  return index < runEnd ? 'inside' : 'after';
}

/**
 * Whether the moved run lies between the selection's two ends, or cuts through one of them, before or after the move. Then the same
 * two points would enclose different blocks than the user selected, and the next keystroke would replace all of them: the selection
 * is collapsed to its head instead. Ends that are both inside the run move with it, and ends on the same side of the run in both
 * documents enclose the same blocks as before.
 */
function runCutsSelection(
  saved: SavedSelection,
  before: { start: number; end: number },
  after: { start: number; end: number },
  newIndexOf: (oldIndex: number) => number
): boolean {
  if (saved.kind !== 'text') return false;
  const old = [saved.anchor, saved.head].map((p) => sideOfRun(p.index, before.start, before.end));
  if (old.every((side) => side === 'inside')) return false;
  if (old.includes('inside')) return true;
  if (old[0] !== old[1]) return true;
  const now = [saved.anchor, saved.head].map((p) => sideOfRun(newIndexOf(p.index), after.start, after.end));
  return now[0] !== now[1];
}

function saveSelection(entries: readonly TopLevelEntry[], selection: Selection): SavedSelection | null {
  if (selection instanceof NodeSelection) {
    const point = locate(entries, selection.from);
    return point ? { kind: 'node', anchor: point, head: point } : null;
  }
  if (selection instanceof TextSelection) {
    const anchor = locate(entries, selection.anchor);
    const head = locate(entries, selection.head);
    return anchor && head ? { kind: 'text', anchor, head } : null;
  }
  return null;
}

/** The saved selection on the document as it is now, found by block id; null when a block is gone (keep the mapped selection). */
function restoredSelection(
  view: EditorView,
  saved: SavedSelection,
  posById: ReadonlyMap<string, number>
): Selection | null {
  const anchorStart = posById.get(saved.anchor.id);
  const headStart = posById.get(saved.head.id);
  if (anchorStart === undefined || headStart === undefined) return null;
  try {
    const anchor = anchorStart + saved.anchor.offset;
    const head = headStart + saved.head.offset;
    return saved.kind === 'node'
      ? NodeSelection.create(view.state.doc, anchor)
      : TextSelection.create(view.state.doc, anchor, head);
  } catch {
    return null;
  }
}

function blockDom(view: EditorView, pos: number): HTMLElement | null {
  const dom = view.nodeDOM(pos);
  return dom instanceof HTMLElement ? dom : null;
}

/**
 * The block to hold still on screen: the caret's block when the caret's line is visible, else the block that contains the visible top
 * (the last block whose top edge is at or above it; the first block if every one starts below it). A view where nothing visible
 * moves then does not jump, even when the block at the top is taller than the screen and the run that moves starts right after it.
 * Null when the layout cannot be read (jsdom has none): the page is then left where it is.
 */
function measureViewportAnchor(view: EditorView, entries: readonly TopLevelEntry[]): ViewportAnchor | null {
  try {
    const head = view.state.selection.head;
    const caret = view.coordsAtPos(head);
    if (caret.bottom > caret.top && caret.bottom > 0 && caret.top < window.innerHeight) {
      const point = locate(entries, head);
      const entry = point ? entries.find((e) => e.id === point.id) : undefined;
      const dom = entry ? blockDom(view, entry.pos) : null;
      if (point && dom) return { id: point.id, top: dom.getBoundingClientRect().top };
    }
  } catch {
    // The caret could not be measured: fall through to the first visible block.
  }
  try {
    const blocks = entries.filter((e) => e.id !== undefined);
    // Blocks are stacked top to bottom, so the first one that starts below the visible top is found by bisection; the block before it
    // is the one that CONTAINS the visible top (a block taller than the screen is such a block, not the one that follows it).
    let lo = 0;
    let hi = blocks.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      const dom = blockDom(view, blocks[mid].pos);
      if (dom && dom.getBoundingClientRect().top <= 0) lo = mid + 1;
      else hi = mid;
    }
    const block = blocks[Math.max(lo - 1, 0)];
    const dom = block ? blockDom(view, block.pos) : null;
    return block?.id !== undefined && dom ? { id: block.id, top: dom.getBoundingClientRect().top } : null;
  } catch {
    return null;
  }
}

/** Scrolls the page so the anchor block's top edge is where it was before the move. */
function restoreViewport(view: EditorView, anchor: ViewportAnchor, posById: ReadonlyMap<string, number>): void {
  const pos = posById.get(anchor.id);
  const dom = pos === undefined ? null : blockDom(view, pos);
  if (!dom) return;
  const shift = dom.getBoundingClientRect().top - anchor.top;
  if (Math.abs(shift) < 0.5) return;
  window.scrollTo({ top: window.scrollY + shift, left: window.scrollX, behavior: 'instant' });
}

/**
 * Bridge target for `window.FinalFinal.reorderSectionsEditorFirst`. Synchronous; Swift calls it as
 * `JSON.stringify(window.FinalFinal.reorderSectionsEditorFirst(opId, rootId, managedIds, order))` in the same synchronous stretch in
 * which it reserves its writer ticket for the returned batch, so reservation order equals execution order.
 *
 * `rootId` is the id of the section the user dragged. `managedIds` is the list of block ids Swift's database flags Notes or
 * Bibliography (never empty on a real document). `order` is every section leader in FINAL order (Notes and Bibliography last), with
 * a `level` on the headings whose level the plan changed. The plan must be "one contiguous run of leaders, starting at `rootId`,
 * moved somewhere else": the plain drag moves one section, the Option drag moves a section with its sub-sections. Anything else is
 * refused (`planMismatch`) and Swift falls back to the old whole-document body.
 */
export function reorderSectionsEditorFirst(
  opId: string,
  rootId: string,
  managedIds: string[],
  order: ReorderOrderEntry[]
): ReorderSectionsResult {
  const result = runEditorFirstChange<ReorderFacts>(opId, 'reorder', undefined, (view, savedIds, ctx) => {
    const entries: TopLevelEntry[] = [];
    view.state.doc.forEach((node, pos) => {
      entries.push({ node, pos, id: savedIds.get(pos) });
    });
    const idsWithNode = new Set<string>();
    for (const entry of entries) if (entry.id !== undefined) idsWithNode.add(entry.id);

    // The working order: what the editor can actually place. An id with no node is skipped, not fatal; the dragged root must exist.
    if (!idsWithNode.has(rootId)) return { ok: false, reason: 'rootNotFound' };
    const skippedIds = order.filter((e) => !idsWithNode.has(e.id)).map((e) => e.id);
    const working = order.filter((e) => idsWithNode.has(e.id));
    const newOrder = working.map((e) => e.id);
    const isLeader = new Set(newOrder);

    // Leaders in document order and the entry range of each leader's group.
    const leaderAt: number[] = [];
    entries.forEach((entry, index) => {
      if (entry.id !== undefined && isLeader.has(entry.id)) leaderAt.push(index);
    });
    const oldOrder = leaderAt.map((index) => entries[index].id as string);
    // Where the editor's own Notes / Bibliography region starts, from the live document: the first managed entry (a block id Swift
    // flagged, or a bibliography marker atom). A group never reaches into it, whether or not the plan names its headings.
    const managed = new Set(managedIds);
    const tailStart = entries.findIndex((entry) => isManagedEntry(entry, managed));
    const tailAt = tailStart < 0 ? entries.length : tailStart;
    const startOfGroup = (k: number) => groupStart(entries, leaderAt[k]);
    const endOfGroup = (k: number) => {
      const next = k + 1 < leaderAt.length ? startOfGroup(k + 1) : entries.length;
      return startOfGroup(k) < tailAt ? Math.min(next, tailAt) : next;
    };

    // The moved run M: the longest run that starts at the root and is contiguous in BOTH orders. A plan whose order is the document's
    // own order moves nothing (a drop that only changed levels): then there is no run, and no managed-region check to make.
    const oldAt = oldOrder.indexOf(rootId);
    const newAt = newOrder.indexOf(rootId);
    if (oldAt < 0 || newAt < 0) return { ok: false, reason: 'planMismatch' };
    const needsMove = !sameSequence(oldOrder, newOrder);
    let runLength = 0;
    if (needsMove) {
      runLength = 1;
      while (
        oldAt + runLength < oldOrder.length &&
        newAt + runLength < newOrder.length &&
        oldOrder[oldAt + runLength] === newOrder[newAt + runLength]
      ) {
        runLength++;
      }
      const oldRest = [...oldOrder.slice(0, oldAt), ...oldOrder.slice(oldAt + runLength)];
      const newRest = [...newOrder.slice(0, newAt), ...newOrder.slice(newAt + runLength)];
      if (!sameSequence(oldRest, newRest)) return { ok: false, reason: 'planMismatch' };
      // Swift's clamp keeps Notes and Bibliography last, so a run that holds one is a plan the editor must not carry out.
      if (oldOrder.slice(oldAt, oldAt + runLength).some((id) => managed.has(id))) {
        return { ok: false, reason: 'managedMoved' };
      }
    }

    // Where the run's nodes go: the start of the group of the leader that follows it in the new order. With none (the run goes to the
    // end), or when that leader is Notes or Bibliography, the start of the editor's own Notes / Bibliography region; in an article
    // with neither, that is the end of the document.
    let sourceStart = 0;
    let sourceEnd = 0;
    let target = 0;
    if (needsMove) {
      sourceStart = startOfGroup(oldAt);
      sourceEnd = endOfGroup(oldAt + runLength - 1);
      const followerId = newOrder[newAt + runLength];
      target = Math.min(followerId === undefined ? entries.length : startOfGroup(oldOrder.indexOf(followerId)), tailAt);
    }

    // The document as it will be: every top-level node in its final place, with its final position.
    const movedEntries = entries.slice(sourceStart, sourceEnd);
    const rest = [...entries.slice(0, sourceStart), ...entries.slice(sourceEnd)];
    const insertAt = target >= sourceEnd ? target - (sourceEnd - sourceStart) : target;
    const finalEntries = needsMove ? [...rest.slice(0, insertAt), ...movedEntries, ...rest.slice(insertAt)] : entries;
    const finalPos: number[] = [];
    let at = 0;
    for (const entry of finalEntries) {
      finalPos.push(at);
      at += entry.node.nodeSize;
    }

    const levels = new Map<string, number>();
    for (const entry of working) if (typeof entry.level === 'number') levels.set(entry.id, entry.level);
    ctx.lap('range');

    // The caret and the screen position, taken before anything changes.
    const savedSelection = saveSelection(entries, view.state.selection);
    if (savedSelection && needsMove) {
      const runLengthNodes = sourceEnd - sourceStart;
      const newIndexOf = (i: number) => {
        if (i >= sourceStart && i < sourceEnd) return insertAt + (i - sourceStart);
        const restIndex = i < sourceStart ? i : i - runLengthNodes;
        return restIndex >= insertAt ? restIndex + runLengthNodes : restIndex;
      };
      const before = { start: sourceStart, end: sourceEnd };
      const after = { start: insertAt, end: insertAt + runLengthNodes };
      // The run lies between the two ends, or cuts through one: keep only the head (see `runCutsSelection`).
      if (runCutsSelection(savedSelection, before, after, newIndexOf)) savedSelection.anchor = savedSelection.head;
    }
    // Typing marks pending at an empty selection (a bold toggle pressed before the first letter) die with any document change.
    const storedMarks = view.state.storedMarks;
    const anchor = measureViewportAnchor(view, entries);
    ctx.lap('collect');

    // `markDispatching` first: from here on a throw puts the checkpoint back (the skeleton's `finally`).
    ctx.markDispatching();
    // ONE transaction: cut the run's groups out, put the same node objects in at the target, set the new levels. Only headings change
    // level; a section break listed with a `level` is left alone, and a heading the plan gives no level keeps the one it has. The
    // `structuralReorder` tag is read by the typewriter plugin (no glide); the rest of what protects the editor is the skeleton's
    // `setSyncPaused` + `resetAndSnapshot` + the `midOp` guard.
    let tr = view.state.tr;
    if (needsMove) {
      const insertPos = finalPos[insertAt];
      tr = tr.delete(
        entries[sourceStart].pos,
        sourceEnd < entries.length ? entries[sourceEnd].pos : view.state.doc.content.size
      );
      tr = tr.insert(insertPos, Fragment.fromArray(movedEntries.map((e) => e.node)));
    }
    let levelChanges = 0;
    finalEntries.forEach((entry, index) => {
      const level = entry.id === undefined ? undefined : levels.get(entry.id);
      if (level !== undefined && entry.node.type.name === 'heading' && entry.node.attrs.level !== level) {
        tr = tr.setNodeMarkup(finalPos[index], undefined, { ...entry.node.attrs, level });
        levelChanges++;
      }
    });
    view.dispatch(tr.setMeta('structuralReorder', true).setMeta('addToHistory', false));
    ctx.lap('dispatch');

    // Every block gets its own id back, not only the moved ones: the block-id plugin settles ids by position and text, and a move
    // is exactly the shape that can mislead it. Sizes do not change under a level change, so `finalPos` still holds.
    const idPositions: number[] = [];
    const ids: string[] = [];
    finalEntries.forEach((entry, index) => {
      if (entry.id !== undefined) {
        idPositions.push(finalPos[index]);
        ids.push(entry.id);
      }
    });
    setTopLevelIdsAt(idPositions, ids);

    // `data-block-id` is a decoration that only recomputes on a transaction (api-content.ts `redecorateBlockIds`), so a step-less
    // dispatch repaints the ids; it also puts the caret and selection back by block id (the cut moved them to the cut's edge when
    // they were inside the run), without scrolling anything into view.
    const posById = new Map<string, number>();
    for (const [pos, id] of getAllBlockIds()) posById.set(id, pos);
    let settle = view.state.tr.setMeta('addToHistory', false);
    const selection = savedSelection ? restoredSelection(view, savedSelection, posById) : null;
    if (selection) settle = settle.setSelection(selection);
    // After `setSelection`, which clears them. A document with no cursor ignores them.
    if (storedMarks) settle = settle.setStoredMarks(storedMarks);
    view.dispatch(settle);
    if (anchor) restoreViewport(view, anchor, posById);
    afterMoveHook?.();

    return {
      ok: true,
      value: { skippedIds, moved: needsMove ? sourceEnd - sourceStart : 0, levelChanges },
      traceDetail: `moved=${needsMove ? sourceEnd - sourceStart : 0} run=${runLength} leaders=${newOrder.length} levels=${levelChanges} skipped=${skippedIds.length}`,
    };
  });

  if (!result.ok) {
    return { batch: result.batch, ok: false, reason: result.reason, skippedIds: [], moved: 0, levelChanges: 0 };
  }
  // The footnote renumber that follows a move is taken in by this entry's saved copy instead of becoming a text-undo step of its own.
  markFootnoteRenumberAbsorbed(opId);
  return { batch: result.batch, ok: true, ...result.value };
}
