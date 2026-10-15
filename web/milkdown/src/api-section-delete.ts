// Editor-first section delete -- the editor half of Phase 4b part 2, slice 2a (t-94369a83).
//
// Today a section delete reads the whole document out of the editor, saves all of it, deletes the rows in the database and
// pushes the whole document back into the editor; the push overwrites whatever the user typed meanwhile. Here the EDITOR removes
// the section first, in one synchronous JavaScript turn, and the database catches up afterwards as a queued write job (Swift side,
// StructuralUndoController). Nothing is pushed back over the user's text.
//
// `deleteSectionEditorFirst` is that one turn. Swift reserves its writer ticket for the batch this call returns and submits the
// call in the same synchronous stretch (plan D1 step 3), so reservation order equals execution order. The call returns the batch
// of pending edits it consumed on EVERY path -- success, refusal and failure alike -- and Swift always applies a returned batch,
// because the consumed edits are gone from the editor's queue.
//
// What it does, in order (plan D1 step 3 (a)-(j), addendum A6/A12):
//   (a) flush the 100 ms detection debounce, so an edit typed a moment ago is a pending change now;
//   (b) consume everything pending (`getBlockChanges`) as the batch Swift applies BEFORE the delete job;
//   (c) pause block-sync, so the removal below is not read back as a wave of deletes;
//   (d) begin a structural op (pre-op checkpoint into the undo registry) and keep copies of the block-id maps beside it;
//   (e) find the range (see `findSectionRange`);
//   (f) dispatch ONE removal transaction, tagged `structuralRemoval`, not added to the text history;
//   (g) re-baseline block-sync on the document after the removal;
//   (h) resume block-sync;
//   (i) finalize the op (`finalizeStructuralOpPostOpDoc`: saves `postOpDoc` AND clears the registry entry's `midOp` marker; the
//       post-op document is never assigned directly, because a left-over `midOp` makes the registry skip every entry);
//   (j) return the batch and the facts Swift needs.
// If anything throws after (f), the `finally` puts the section back BEFORE block-sync resumes: it swaps the checkpoint in,
// restores the block-id maps, re-baselines, and only then unpauses; the reply is `ok: false` with the batch, so Swift's failure
// alert is true (the section is on screen and block-sync queued no deletes).

import { editorViewCtx } from '@milkdown/kit/core';
import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import type { EditorState } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { getAllBlockIds, getAllBlockTypes, restoreBlockIdMaps } from './block-id-plugin';
import {
  type BlockChanges,
  flushPendingBlockChanges,
  getBlockChanges,
  rebindCurrentStateFromView,
  resetAndSnapshot,
  setSyncPaused,
} from './block-sync-plugin';
import { getEditorInstance } from './editor-state';
import { noteRemovalForPaint } from './typing-trace';
import {
  beginStructuralOp,
  clearFailedStructuralOpEntry,
  finalizeStructuralOpPostOpDoc,
  getRegistry,
} from './undo-coordinator';

/** One section leader the removal took out, for Swift's sidebar bookkeeping. */
export interface RemovedSectionSnapshot {
  id: string;
  kind: 'heading' | 'section_break';
  /** Effective level: a heading's own level, 1 for a section break (the database's `headingLevel ?? 1`). */
  level: number;
  /** A heading's text; empty for a section break. */
  title: string;
}

/** What `deleteSectionEditorFirst` returns, on every path. Swift reads it as `JSON.stringify(...)`, like `getBlockChanges`. */
export interface DeleteSectionResult {
  /** Every pending edit this call consumed, in `getBlockChanges()` shape. Empty when nothing was pending. */
  batch: BlockChanges;
  ok: boolean;
  /** Why `ok` is false: 'noEditor', 'beginFailed', 'rootNotFound', 'managedRoot', 'rootNotLeader', or 'exception: <message>'. */
  reason?: string;
  /** Block ids of every top-level node the removal took out (leaders and body), in document order. */
  removedIds: string[];
  /** The subset of `removedIds` that are section leaders (headings and section breaks). */
  removedLeaderIds: string[];
  /** Id of the nearest block before the removed range that has one, or null when the range began the document. */
  predecessorId: string | null;
  /** One entry per removed leader, in document order. */
  removedSectionsSnapshot: RemovedSectionSnapshot[];
}

/** One top-level node of the document with the block id the block-id plugin holds for it (undefined for the marker atoms,
 * which sit outside the plugin's allowlist, and for any block that has no id yet). */
interface TopLevelEntry {
  node: ProsemirrorNode;
  pos: number;
  id: string | undefined;
}

export type SectionRange =
  | {
      ok: true;
      /** Document positions: `from` is before the root leader, `to` is after the last removed node. */
      from: number;
      to: number;
      removed: TopLevelEntry[];
      predecessorId: string | null;
    }
  | { ok: false; reason: 'rootNotFound' | 'managedRoot' | 'rootNotLeader' };

/** A leader's effective level: headings by their own level, section breaks as level 1; `undefined` for anything else (an `hr`
 * is NOT a leader). Mirrors the database rule `leader = heading || pseudo-section, level = headingLevel ?? 1`
 * (Database+SectionOps.swift `resolveSectionSubtree`). */
function leaderLevel(node: ProsemirrorNode): number | undefined {
  if (node.type.name === 'heading') return (node.attrs.level as number | undefined) ?? 1;
  if (node.type.name === 'section_break') return 1;
  return undefined;
}

/** Notes/Bibliography content: a block whose id Swift passed as managed, or one of the two bibliography marker atoms (they carry no
 * block id, so Swift's list cannot name them, and the opening marker sits directly before the Bibliography heading). */
function isManagedEntry(entry: TopLevelEntry, managedIds: ReadonlySet<string>): boolean {
  const name = entry.node.type.name;
  if (name === 'auto_bibliography' || name === 'auto_bibliography_end') return true;
  return entry.id !== undefined && managedIds.has(entry.id);
}

/**
 * The one shared rule for "the section" (plan D1.0), JS side. Leaders are headings and section breaks (level 1), never `hr`. The
 * range runs from the root leader up to, not including, the next leader at the same or a higher level (a smaller or equal level
 * number), so deeper leaders and everything under them belong to it whatever levels were skipped. It never includes Notes or
 * Bibliography content and stops before the first such node. `managedIds` is Swift's list, read from the database at the click;
 * JS never trusts its own managed set (the block-id plugin's copy is replaced wholesale by every push and can be stale).
 */
export function findSectionRange(
  doc: ProsemirrorNode,
  ids: ReadonlyMap<number, string>,
  rootBlockId: string,
  managedIds: ReadonlySet<string>
): SectionRange {
  const entries: TopLevelEntry[] = [];
  doc.forEach((node, pos) => {
    entries.push({ node, pos, id: ids.get(pos) });
  });

  const rootIndex = entries.findIndex((entry) => entry.id === rootBlockId);
  if (rootIndex < 0) return { ok: false, reason: 'rootNotFound' };
  if (managedIds.has(rootBlockId)) return { ok: false, reason: 'managedRoot' };
  const rootLevel = leaderLevel(entries[rootIndex].node);
  if (rootLevel === undefined) return { ok: false, reason: 'rootNotLeader' };

  let end = rootIndex + 1;
  while (end < entries.length) {
    const entry = entries[end];
    if (isManagedEntry(entry, managedIds)) break;
    const level = leaderLevel(entry.node);
    if (level !== undefined && level <= rootLevel) break;
    end++;
  }

  let predecessorId: string | null = null;
  for (let i = rootIndex - 1; i >= 0; i--) {
    const id = entries[i].id;
    if (id !== undefined) {
      predecessorId = id;
      break;
    }
  }

  const last = entries[end - 1];
  return {
    ok: true,
    from: entries[rootIndex].pos,
    to: last.pos + last.node.nodeSize,
    removed: entries.slice(rootIndex, end),
    predecessorId,
  };
}

// Test seam (web tests only; production never sets it): runs right after the removal was dispatched, before block-sync is
// re-baselined. A throw from it exercises the failure path a real error after the dispatch would take (addendum A6, W10).
let afterRemovalHook: (() => void) | null = null;
export function setTestAfterRemovalHook(hook: (() => void) | null): void {
  afterRemovalHook = hook;
}

/** A diagnostic must never break the operation it observes. Counts and ids only, never document text. */
function trace(message: string): void {
  try {
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[STRUCT-TRACE] ${message}`,
    });
  } catch {
    // Swallowed on purpose: see the comment above.
  }
}

/** The steps of `deleteSectionEditorFirst` that get their own lap in the success trace line (plan round 13b, measurement only). */
type StepName =
  | 'flush' // (a) flushPendingBlockChanges
  | 'changes' // (b) getBlockChanges
  | 'begin' // (c)+(d) pause block-sync, beginStructuralOp, the checkpoint read
  | 'maps' // the two block-id map copies
  | 'range' // (e) findSectionRange
  | 'collect' // the loop building removedIds / removedLeaderIds / removedSectionsSnapshot
  | 'dispatch' // (f) view.dispatch (plugin state, node views, DOM mutation)
  | 'snapshot' // (g) resetAndSnapshot (the removal-paint note and the test hook, both negligible, fall in here)
  | 'finalize'; // (h)+(i) resume block-sync, finalizeStructuralOpPostOpDoc

/**
 * Wall-clock laps of one `deleteSectionEditorFirst` call. `lap(step)` records the time since the previous lap (or since
 * construction) under `step`; `summary()` renders every lap and the time since construction as whole milliseconds. One small
 * object per call, no allocation per lap. Counts of time only, never document text.
 */
class StepTimer {
  private readonly start = performance.now();
  private last = this.start;
  private readonly ms: Record<StepName, number> = {
    flush: 0,
    changes: 0,
    begin: 0,
    maps: 0,
    range: 0,
    collect: 0,
    dispatch: 0,
    snapshot: 0,
    finalize: 0,
  };

  lap(step: StepName): void {
    const now = performance.now();
    this.ms[step] = now - this.last;
    this.last = now;
  }

  /** ` jsMs total=<n> flush=<n> ...`, appended to the success trace line. A step that was never reached reads 0. */
  summary(): string {
    const total = performance.now() - this.start;
    const m = this.ms;
    return (
      ` jsMs total=${Math.round(total)} flush=${Math.round(m.flush)} changes=${Math.round(m.changes)} ` +
      `begin=${Math.round(m.begin)} maps=${Math.round(m.maps)} range=${Math.round(m.range)} ` +
      `collect=${Math.round(m.collect)} dispatch=${Math.round(m.dispatch)} snapshot=${Math.round(m.snapshot)} ` +
      `finalize=${Math.round(m.finalize)}`
    );
  }
}

/** Puts the document, the block-id maps and block-sync's baseline back to what they were at `beginStructuralOp`. */
function restoreBeforeRemoval(
  view: EditorView,
  checkpoint: EditorState,
  ids: ReadonlyMap<number, string>,
  types: ReadonlyMap<number, string>
): void {
  view.updateState(checkpoint);
  rebindCurrentStateFromView(view);
  restoreBlockIdMaps(ids, types);
  resetAndSnapshot(view.state.doc);
}

/**
 * Bridge target for `window.FinalFinal.deleteSectionEditorFirst`. Synchronous; Swift calls it as
 * `JSON.stringify(window.FinalFinal.deleteSectionEditorFirst(opId, rootBlockId, managedIds))`.
 * `managedIds` is the list of block ids Swift's database flags Notes or Bibliography (never empty on a real document).
 */
export function deleteSectionEditorFirst(opId: string, rootBlockId: string, managedIds: string[]): DeleteSectionResult {
  let batch: BlockChanges = { updates: [], inserts: [], deletes: [] };
  const failure = (reason: string): DeleteSectionResult => ({
    batch,
    ok: false,
    reason,
    removedIds: [],
    removedLeaderIds: [],
    predecessorId: null,
    removedSectionsSnapshot: [],
  });

  const editorInstance = getEditorInstance();
  if (!editorInstance) return failure('noEditor');

  let paused = false;
  let begun = false;
  let dispatched = false;
  let completed = false;
  let checkpoint: EditorState | undefined;
  let savedIds: Map<number, string> = new Map();
  let savedTypes: Map<number, string> = new Map();
  const view = editorInstance.ctx.get(editorViewCtx);
  const timer = new StepTimer();

  try {
    flushPendingBlockChanges(); // (a)
    timer.lap('flush');
    batch = getBlockChanges(); // (b)
    timer.lap('changes');
    setSyncPaused(true); // (c)
    paused = true;
    begun = beginStructuralOp(opId); // (d)
    if (!begun) return failure('beginFailed');
    checkpoint = getRegistry().get(opId)?.checkpoint;
    timer.lap('begin');
    savedIds = getAllBlockIds();
    savedTypes = getAllBlockTypes();
    timer.lap('maps');

    const range = findSectionRange(view.state.doc, savedIds, rootBlockId, new Set(managedIds)); // (e)
    if (!range.ok) return failure(range.reason);
    timer.lap('range');

    const removedIds: string[] = [];
    const removedLeaderIds: string[] = [];
    const removedSectionsSnapshot: RemovedSectionSnapshot[] = [];
    for (const entry of range.removed) {
      if (entry.id !== undefined) removedIds.push(entry.id);
      const level = leaderLevel(entry.node);
      if (level !== undefined && entry.id !== undefined) {
        removedLeaderIds.push(entry.id);
        removedSectionsSnapshot.push({
          id: entry.id,
          kind: entry.node.type.name === 'section_break' ? 'section_break' : 'heading',
          level,
          title: entry.node.type.name === 'heading' ? entry.node.textContent : '',
        });
      }
    }

    timer.lap('collect');

    dispatched = true;
    view.dispatch(
      view.state.tr.delete(range.from, range.to).setMeta('structuralRemoval', true).setMeta('addToHistory', false)
    ); // (f)
    timer.lap('dispatch');
    noteRemovalForPaint(opId);
    afterRemovalHook?.();

    resetAndSnapshot(view.state.doc); // (g)
    timer.lap('snapshot');
    setSyncPaused(false); // (h)
    paused = false;
    finalizeStructuralOpPostOpDoc(opId); // (i)
    timer.lap('finalize');

    completed = true;
    trace(
      `delete-editor-first opId=${opId.slice(0, 8)} ok=true removed=${removedIds.length} leaders=${removedLeaderIds.length} ` +
        `batchUpdates=${batch.updates.length} batchInserts=${batch.inserts.length} batchDeletes=${batch.deletes.length}` +
        timer.summary()
    );
    return {
      batch,
      ok: true,
      removedIds,
      removedLeaderIds,
      predecessorId: range.predecessorId,
      removedSectionsSnapshot,
    }; // (j)
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    trace(`delete-editor-first opId=${opId.slice(0, 8)} threw after dispatch=${dispatched}: ${message.slice(0, 200)}`);
    return failure(`exception: ${message}`);
  } finally {
    if (!completed) {
      if (dispatched && checkpoint) {
        try {
          restoreBeforeRemoval(view, checkpoint, savedIds, savedTypes);
        } catch (e) {
          trace(
            `delete-editor-first opId=${opId.slice(0, 8)} could not restore the section: ${String(e).slice(0, 200)}`
          );
        }
      }
      if (begun) clearFailedStructuralOpEntry(opId);
    }
    if (paused) setSyncPaused(false);
  }
}
