// The editor-first click skeleton, shared by every operation that changes the document in the editor FIRST and lets the database
// catch up afterwards as a queued write job (t-18b7fa48 round 1b; the first user is the section delete, api-section-delete.ts).
//
// `runEditorFirstChange` is one synchronous JavaScript turn. Swift reserves its writer ticket for the batch the call returns and
// submits the call in the same synchronous stretch, so reservation order equals execution order. The call returns the batch of
// pending edits it consumed on EVERY path -- success, refusal and failure alike -- and Swift always applies a returned batch,
// because the consumed edits are gone from the editor's queue.
//
// The skeleton owns everything that is the same for every such operation; the caller's `mutate` owns the one thing that differs:
//   (0) boundary hygiene: close an open popup, a Find session or a pending paste position, which must not act on offsets the
//       change is about to invalidate (a popup edit committed here lands BEFORE the checkpoint);
//   (a) flush the 100 ms detection debounce, so an edit typed a moment ago is a pending change now;
//   (b) consume everything pending (`getBlockChanges`) as the batch Swift applies BEFORE the job;
//   (c) pause block-sync, so the change below is not read back as a wave of inserts/deletes;
//   (d) begin a structural op (pre-op checkpoint into the undo registry), keep copies of the block-id and block-type maps beside
//       it, and list the temp ids among them so Swift's later confirmations can be logged against the entry;
//   (e) `mutate(view, savedIds, ctx)`: find the range and dispatch the change. THE CALLER'S PART;
//   (g) re-baseline block-sync on the document after the change (`resetAndSnapshot`);
//   (h) resume block-sync;
//   (i) finalize the op (`finalizeStructuralOpPostOpDoc`: saves `postOpDoc` AND clears the registry entry's `midOp` marker; the
//       post-op document is never assigned directly, because a left-over `midOp` makes the registry skip every entry);
//   (j) return the batch and whatever `mutate` produced.
// If anything throws after the first dispatch, the `finally` puts the document back BEFORE block-sync resumes: it swaps the
// checkpoint in, restores the block-id maps, re-baselines, and only then unpauses; the reply is `ok: false` with the batch, so
// Swift's failure alert is true (the document is as it was and block-sync queued no changes).
//
// What protects the editor while the change is dispatched (plan D16): NOT the `structuralRemoval` meta tag a mutator may put on
// its transaction -- nothing in production reads that tag; it is a label for tests and the trace. The real protection is
// `setSyncPaused(true)` (block-sync does not read the change back as edits), `resetAndSnapshot` (block-sync's baseline is
// re-taken on the document after the change before it resumes), and the `midOp` guard in the undo registry (while the entry is
// mid-op, `advanceRegistryEntries` skips every entry, so no rewrite is mistaken for typing).

import { editorViewCtx } from '@milkdown/kit/core';
import type { EditorState } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { getAllBlockIds, getAllBlockTypes, isTempBlockId, restoreBlockIdMaps } from './block-id-plugin';
import {
  type BlockChanges,
  flushPendingBlockChanges,
  getBlockChanges,
  rebindCurrentStateFromView,
  resetAndSnapshot,
  setSyncPaused,
} from './block-sync-plugin';
import { getEditorInstance } from './editor-state';
import {
  beginStructuralOp,
  cancelPendingInsertions,
  clearFailedStructuralOpEntry,
  closeEditingPopupsAndClearBoundaryState,
  finalizeStructuralOpPostOpDoc,
  getRegistry,
  type UndoRegistryEntry,
} from './undo-coordinator';

/** A diagnostic must never break the operation it observes. Counts and ids only, never document text. */
export function trace(message: string): void {
  try {
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[STRUCT-TRACE] ${message}`,
    });
  } catch {
    // Swallowed on purpose: see the comment above.
  }
}

/** The steps of one editor-first turn that get their own lap in the success trace line (plan round 13b, measurement only). */
type StepName =
  | 'flush' // (a) flushPendingBlockChanges
  | 'changes' // (b) getBlockChanges
  | 'begin' // (c)+(d) pause block-sync, beginStructuralOp, the checkpoint read
  | 'maps' // the two block-id map copies
  | 'range' // (e) the caller's range finding
  | 'collect' // (e) the caller's loop collecting what the change touches
  | 'dispatch' // (e) view.dispatch (plugin state, node views, DOM mutation)
  | 'snapshot' // (g) resetAndSnapshot (a caller's post-dispatch notes and the test hook, both negligible, fall in here)
  | 'finalize'; // (h)+(i) resume block-sync, finalizeStructuralOpPostOpDoc

/** The laps `mutate` records (the others belong to the skeleton). */
export type MutatorStep = 'range' | 'collect' | 'dispatch';

/**
 * Wall-clock laps of one editor-first turn. `lap(step)` records the time since the previous lap (or since construction) under
 * `step`; `summary()` renders every lap and the time since construction as whole milliseconds. One small object per call, no
 * allocation per lap. Counts of time only, never document text.
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

/** What `mutate` gets besides the view and the saved id map. */
export interface EditorFirstContext {
  /** Records the time since the previous lap under `step`, for the trace's `jsMs` breakdown. */
  lap(step: MutatorStep): void;
  /** Call right BEFORE the first `view.dispatch`: from then on a throw puts the checkpoint back. A mutator that throws before
   * calling it changed nothing, so nothing is restored (the registry entry is still cleared). */
  markDispatching(): void;
}

/** What `mutate` returns: a refusal (nothing was dispatched; the entry is cleared, block-sync resumes) or the facts of the
 * change, with `traceDetail` as the words that go between `ok=true` and `batchUpdates=` in the success trace line. */
export type EditorFirstMutation<T> = { ok: false; reason: string } | { ok: true; value: T; traceDetail: string };

/** What `runEditorFirstChange` returns, on every path. `batch` is always the batch this call consumed. */
export type EditorFirstChangeResult<T> =
  | { ok: true; batch: BlockChanges; value: T }
  | { ok: false; batch: BlockChanges; reason: string };

/** Puts the document, the block-id maps and block-sync's baseline back to what they were at `beginStructuralOp`. */
function restoreBeforeChange(
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
 * One editor-first turn (see the header). `label` names the operation in the trace line (`<label>-editor-first opId=...`);
 * `traceTag`, when given, goes between `-editor-first` and ` opId=` (the replace puts ` mode=<m>` there).
 * `previousEntry` is the quick redo only: the registry entry this opId already has. It is deleted from the registry right
 * before `beginStructuralOp(opId)`, so the redone entry becomes the NEWEST key (the saved-copy rebase targets the last key,
 * undo-coordinator.ts `advanceRegistryEntries`; plan v3 D8), and it is put back untouched if the change does not complete: a
 * failed redo leaves the op undone with the entry it had, so a later press still routes.
 */
export function runEditorFirstChange<T>(
  opId: string,
  label: string,
  previousEntry: UndoRegistryEntry | undefined,
  mutate: (view: EditorView, savedIds: ReadonlyMap<number, string>, ctx: EditorFirstContext) => EditorFirstMutation<T>,
  traceTag = ''
): EditorFirstChangeResult<T> {
  // Boundary hygiene first, like every structural op (Swift's slow paths call the same two): an open popup, a Find session or a pending
  // paste position must not act on offsets this change is about to invalidate. A popup edit committed here lands BEFORE the checkpoint.
  closeEditingPopupsAndClearBoundaryState();
  cancelPendingInsertions();
  let batch: BlockChanges = { updates: [], inserts: [], deletes: [] };
  const failure = (reason: string): EditorFirstChangeResult<T> => ({ ok: false, batch, reason });

  const editorInstance = getEditorInstance();
  if (!editorInstance) return failure('noEditor');

  let paused = false;
  let begun = false;
  let replaced = false;
  let dispatched = false;
  let completed = false;
  let checkpoint: EditorState | undefined;
  let savedIds: Map<number, string> = new Map();
  let savedTypes: Map<number, string> = new Map();
  const view = editorInstance.ctx.get(editorViewCtx);
  const timer = new StepTimer();
  const ctx: EditorFirstContext = {
    lap: (step) => timer.lap(step),
    markDispatching: () => {
      dispatched = true;
    },
  };

  try {
    flushPendingBlockChanges(); // (a)
    timer.lap('flush');
    batch = getBlockChanges(); // (b)
    timer.lap('changes');
    setSyncPaused(true); // (c)
    paused = true;
    if (previousEntry) {
      getRegistry().delete(opId);
      replaced = true;
    }
    begun = beginStructuralOp(opId); // (d)
    if (!begun) return failure('beginFailed');
    const fresh = getRegistry().get(opId);
    checkpoint = fresh?.checkpoint;
    timer.lap('begin');
    savedIds = getAllBlockIds();
    savedTypes = getAllBlockTypes();
    if (fresh) {
      // The maps the quick undo puts back, beside the checkpoint they belong to (api-section-undo.ts), with an empty log of the
      // temp ids Swift confirms from here on (undo-coordinator.ts `recordConfirmationsInRegistry`).
      const tempIds = new Set<string>();
      for (const id of savedIds.values()) if (isTempBlockId(id)) tempIds.add(id);
      getRegistry().set(opId, { ...fresh, idMap: savedIds, typeMap: savedTypes, confirmLog: [], tempIds });
    }
    timer.lap('maps');

    const mutation = mutate(view, savedIds, ctx); // (e)
    if (!mutation.ok) return failure(mutation.reason);

    resetAndSnapshot(view.state.doc); // (g)
    timer.lap('snapshot');
    setSyncPaused(false); // (h)
    paused = false;
    finalizeStructuralOpPostOpDoc(opId); // (i)
    timer.lap('finalize');

    completed = true;
    trace(
      `${label}-editor-first${traceTag} opId=${opId.slice(0, 8)} ok=true ${mutation.traceDetail} ` +
        `batchUpdates=${batch.updates.length} batchInserts=${batch.inserts.length} batchDeletes=${batch.deletes.length}` +
        timer.summary()
    );
    return { ok: true, batch, value: mutation.value }; // (j)
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    trace(
      `${label}-editor-first${traceTag} opId=${opId.slice(0, 8)} threw after dispatch=${dispatched}: ${message.slice(0, 200)}`
    );
    return failure(`exception: ${message}`);
  } finally {
    if (!completed) {
      if (dispatched && checkpoint) {
        try {
          restoreBeforeChange(view, checkpoint, savedIds, savedTypes);
        } catch (e) {
          trace(
            `${label}-editor-first${traceTag} opId=${opId.slice(0, 8)} could not restore the section: ${String(e).slice(0, 200)}`
          );
        }
      }
      if (replaced && previousEntry) getRegistry().set(opId, previousEntry);
      else if (begun) clearFailedStructuralOpEntry(opId);
    }
    if (paused) setSyncPaused(false);
  }
}
