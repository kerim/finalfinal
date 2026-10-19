// Editor-first slow snapshot undo and redo -- the editor half of Phase 4b slice 3, round 3b (t-18b7fa48).
//
// Today a structural undo that cannot take the quick path (`performUndo` / `performRedo` in Swift's StructuralUndoController) flushes the
// editor, swaps the saved EditorState in (`performStructuralSwap`), restores the database from a snapshot, then pushes block ids and
// settles (`finishStructuralSwapSettle`); anything typed while that runs is lost. Here the EDITOR is swapped first, in one synchronous
// JavaScript turn, with the ids the database is about to hold, and the database catches up afterwards as a queued write job (Swift
// side, round 3c) that writes exactly the payload's rows. Nothing is pushed back over the user's text.
//
// `structuralSwapEditorFirst(opId, direction, payload)` is that turn. In order:
//   (0) the boundary hygiene every structural op performs (`closeEditingPopupsAndClearBoundaryState`, `cancelPendingInsertions`);
//   (a) flush the 100 ms detection debounce, so an edit typed a moment ago is a pending change now;
//   (b) consume everything pending (`getBlockChanges`) as the batch Swift applies BEFORE the job. It is taken FIRST and in this very
//       turn: the re-check below and the swap can then never see a document that holds an edit the batch does not (binding
//       requirement R2, README "Requirements the model puts on rounds 3b and 3c"). The batch comes back on EVERY path;
//   (c) find the target: for 'undo' the entry's pre-op `checkpoint`, for 'redo' the `redoCheckpoint` that `performStructuralSwap`
//       stored when the entry was undone. No entry, or no such checkpoint: `noCheckpoint`, nothing swapped (Swift then falls back to
//       slice 2's whole-document replace);
//   (d) RE-CHECK that the live document still equals the saved copy the press was routed against (`liveDocMatchesSavedCopy`, THE one
//       shared comparison the routing decision, the quick undo's re-check and the quick redo's gate use; `postOpDoc` for an undo,
//       `preOpDoc` for a redo, exactly or modulo what the app regenerates). Swift reads the snapshot and builds the payload between
//       the press and this turn, the editor is live meanwhile, and the user can type in that stretch (the model's
//       EFSnapTypedInWait). If anything differs: `docChanged`, nothing swapped, the entry stays recorded (binding requirement R5);
//   (e) the FULL top-level id alignment pre-check of the payload against the TARGET document (`alignmentProblem`, shared with the
//       restore: count both ways, node types, non-blank content). A mismatch is `idAlignment`: nothing swapped;
//   (f) the swap itself, EXACTLY as today's `performStructuralSwap` does it (undo-coordinator.ts, called unchanged): the redo checkpoint
//       is captured for an undo, the checkpoint state is swapped in whole (text history included), a redo re-anchors `postOpDoc`,
//       block-sync is paused, the ids are cleared. Then the payload's ids and managed ids are applied, the editor repaints them,
//       and the ids are checked once more against the swapped-in document (`idProblem`);
//   (g) `finishStructuralSwapSettle`, unchanged: re-baseline block-sync on the swapped-in document WITH its ids, resume block-sync,
//       refresh the JS-side content cache;
//   (h) schedule the ordinary `contentChanged` notification for the swapped-in text (api-section-undo.ts `scheduleContentChanged`,
//       the quick undo's mechanism): a checkpoint swap changes the document with no document-changing transaction, so main.ts's
//       typing debounce never fires for it.
// All of it is ONE synchronous call: no `await`, no animation-frame-deferred re-baseline (the whole-document push's deferred snapshot
// would swallow typing made in the first frame after the reply). If anything fails after the swap, the `finally` puts the live
// state, the ids, the managed set, the entry's bookkeeping and the baseline back and unpauses, and the reply is `ok: false` with the
// batch, so a failed swap leaves the document as the user had it.
//
// What this call deliberately does NOT do, and what Swift therefore must not do around it (binding requirement R1): it posts no
// content-state change, bumps no generation, runs no direct flush and sets no `.structuralUndo` state. From Swift's side the click
// is a live-editor operation, so the editor's own 50 ms content push is accepted while the job waits.
//
// What it leaves for Swift (round 3c): reserve the queued job in the reply turn, apply the returned batch first, hide/show the
// sidebar leaders from the reply, move the undo/redo stacks and push the descriptor, settle (re-push the Notes and Bibliography
// regions from the database, `forceResyncDerivedContent`), and answer the in-flight latch with `receiveUndoOutcome` /
// `receiveRedoOutcome`. On a refusal Swift applies the batch, shows the notice and leaves the entry where it was.

import { editorViewCtx } from '@milkdown/kit/core';
import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import type { EditorState } from '@milkdown/kit/prose/state';
import { leaderLevel } from './api-section-delete';
import { Laps, scheduleContentChanged } from './api-section-undo';
import { alignmentProblem, idProblem, leadersOf, type ReplaceRangeResult } from './api-structural-replace';
import {
  getAllBlockIds,
  getAllBlockTypes,
  getManagedBlockIds,
  pointPluginStateAtLiveIds,
  restoreBlockIdMaps,
  setBlockIdsForTopLevel,
  setManagedBlockIds,
} from './block-id-plugin';
import {
  type BlockChanges,
  flushPendingBlockChanges,
  getBlockChanges,
  rebindCurrentStateFromView,
  resetAndSnapshot,
  setSyncPaused,
} from './block-sync-plugin';
import { trace } from './editor-first-op';
import { getEditorInstance } from './editor-state';
import type { ExpectedBlockMeta } from './types';
import {
  cancelPendingInsertions,
  closeEditingPopupsAndClearBoundaryState,
  finishStructuralSwapSettle,
  getRegistry,
  liveDocMatchesSavedCopy,
  performStructuralSwap,
} from './undo-coordinator';

/**
 * What Swift sends: the ids of the DOCUMENT THE SWAP PUTS IN (the pre-op document for an undo, the post-op document for a redo). The
 * field names are those of Swift's `ContentView.BlockFetchResult` (what `StructuralUndoController.editorPayload(for: planRows)`
 * returns), so the struct can be encoded as it is; fields this call does not read (`markdown`, `imageMeta`, the bibliography
 * boundaries) are ignored, because the document comes from the saved EditorState, not from a parse.
 */
export interface StructuralSwapPayload {
  /** One id per top-level block node of the document being swapped in, in document order (`BlockParser.alignmentPairs` order,
   * marker atoms excluded): the ids of the rows the queued job will write. */
  blockIds: string[];
  /** One entry per id: what the node must be and whether it must have text (`BlockFetchResult.expectedBlocks`). */
  expectedBlocks: ExpectedBlockMeta[];
  /** The ids among `blockIds` that are Notes or Bibliography content (`BlockFetchResult.managedBlockIds`). Replaces the editor's
   * managed-id set, which paints `data-managed`. May be empty. */
  managedBlockIds: string[];
}

/**
 * What `structuralSwapEditorFirst` returns, on every path. Swift reads it as `JSON.stringify(...)`. It has exactly the shape of
 * `ReplaceRangeResult` for a WHOLE-document replace, so Swift can decode it with the restore's reply type: the whole old document is
 * what the swap took out, the whole new one is what it put in. `predecessorId` is always null. Plus `swappedTo`.
 *
 * `reason` when `ok` is false: 'noEditor', 'beginFailed' (kept in the vocabulary for parity with the other editor-first calls; this
 * call has no begin step, so it is never produced), 'noCheckpoint' (no registry entry for the op, or the entry has no checkpoint
 * for this direction: nothing swapped), 'docChanged' (the live document no longer equals the saved copy: nothing swapped, the entry
 * stays recorded), 'idAlignment' (the payload does not fit the target document; before the swap nothing was touched, after it the
 * live state is put back), or 'exception: <message>' (put back as well).
 */
export interface StructuralSwapResult extends ReplaceRangeResult {
  /** Which saved state was swapped in: 'checkpoint' (direction 'undo') or 'redo' (the stored redo checkpoint). Absent on a refusal. */
  swappedTo?: 'checkpoint' | 'redo';
}

// Test seam (web tests only; production never sets it): runs right after the swap, the payload's ids and the repaint, before the ids
// are checked and before the settle. A throw from it exercises the failure path a real error after the swap would take; a hook that
// tampers with an id exercises the post-swap alignment check.
let afterSwapHook: (() => void) | null = null;
export function setTestAfterSwapHook(hook: (() => void) | null): void {
  afterSwapHook = hook;
}

const emptyBatch = (): BlockChanges => ({ updates: [], inserts: [], deletes: [] });

const failureReply = (batch: BlockChanges, reason: string): StructuralSwapResult => ({
  batch,
  ok: false,
  reason,
  insertedIds: [],
  insertedLeaderIds: [],
  insertedSectionsSnapshot: [],
  removedIds: [],
  removedLeaderIds: [],
  predecessorId: null,
});

/**
 * Bridge target for `window.FinalFinal.structuralSwapEditorFirst`. Synchronous; Swift calls it as
 * `JSON.stringify(window.FinalFinal.structuralSwapEditorFirst(opId, direction, payload))` in the same synchronous stretch in which it
 * reserves its writer ticket for the returned batch, so reservation order equals execution order. The structural-undo (or redo)
 * latch must be held for `opId` by the press that routed here; this call neither checks nor releases it (Swift replies with
 * `receiveUndoOutcome` / `receiveRedoOutcome`, exactly as the legacy path does).
 */
export function structuralSwapEditorFirst(
  opId: string,
  direction: 'undo' | 'redo',
  payload: StructuralSwapPayload
): StructuralSwapResult {
  const shortId = opId.slice(0, 8);
  let batch: BlockChanges = emptyBatch();
  let detail = ''; // counts and positions only, for the trace line of a refusal
  const refuse = (reason: string): StructuralSwapResult => {
    trace(
      `swap-editor-first direction=${direction} opId=${shortId} ok=false reason=${reason.slice(0, 200)}` +
        (detail ? ` detail=${detail.slice(0, 200)}` : '')
    );
    return failureReply(batch, reason);
  };

  // (0) before anything is read: a popup edit committed here changes the document and the re-check then refuses (`docChanged`).
  closeEditingPopupsAndClearBoundaryState();
  cancelPendingInsertions();
  const editorInstance = getEditorInstance();
  if (!editorInstance) return refuse('noEditor');
  const view = editorInstance.ctx.get(editorViewCtx);
  const laps = new Laps();

  // What the `finally` puts back. `entryBefore` also carries the redo bookkeeping the swap may add (`redoCheckpoint` on an undo,
  // a re-anchored `postOpDoc` on a redo), so a failed swap leaves the entry exactly as it was.
  const entryBefore = getRegistry().get(opId);
  const stateBefore: EditorState = view.state;
  const managedBefore = getManagedBlockIds();
  let idsBefore: Map<number, string> = new Map();
  let typesBefore: Map<number, string> = new Map();
  let swapStarted = false;
  let completed = false;

  try {
    flushPendingBlockChanges(); // (a)
    laps.lap('flush');
    batch = getBlockChanges(); // (b)
    laps.lap('changes');

    // (c) the target
    const entry = entryBefore;
    const target = direction === 'undo' ? entry?.checkpoint : entry?.redoCheckpoint;
    if (!entry || !target) {
      detail = entry ? 'the entry has no redo checkpoint' : 'no registry entry';
      return refuse('noCheckpoint');
    }

    // (d) the re-check: the document the batch above was taken from is `view.state.doc`, so typing taken into the batch counts as live.
    if (!liveDocMatchesSavedCopy(view, entry, direction)) return refuse('docChanged');
    laps.lap('recheck');

    // (e) the payload against the document it is about to name, BEFORE anything is touched.
    const problem = alignmentProblem(target.doc, payload);
    if (problem !== null) {
      detail = problem;
      return refuse('idAlignment');
    }
    laps.lap('align');

    // The blocks the swap takes out, read from the LIVE document and its ids before they are cleared.
    idsBefore = getAllBlockIds();
    typesBefore = getAllBlockTypes();
    const removedIds: string[] = [];
    const removedLeaderIds: string[] = [];
    stateBefore.doc.forEach((node, pos) => {
      const id = idsBefore.get(pos);
      if (id === undefined) return;
      removedIds.push(id);
      if (leaderLevel(node) !== undefined) removedLeaderIds.push(id);
    });

    // (f) the swap, unchanged, then the payload's ids. From the next line on a throw puts the live state back.
    swapStarted = true;
    if (!performStructuralSwap(opId, direction)) throw new Error('performStructuralSwap returned false');
    laps.lap('swap');
    setBlockIdsForTopLevel(payload.blockIds, view.state.doc, payload.expectedBlocks);
    setManagedBlockIds(payload.managedBlockIds);
    // `data-block-id` and `data-managed` are decorations that only recompute on a transaction (api-content.ts `redecorateBlockIds`),
    // and they are painted from the swapped-in state's OWN plugin state, which still names the ids map of the moment it was saved.
    pointPluginStateAtLiveIds(view.state);
    view.dispatch(view.state.tr);
    laps.lap('ids');
    afterSwapHook?.();
    const idMismatch = idProblem(view.state.doc, payload.blockIds);
    if (idMismatch !== null) {
      detail = idMismatch;
      return refuse('idAlignment');
    }

    const nodes: ProsemirrorNode[] = [];
    view.state.doc.forEach((node) => {
      nodes.push(node);
    });
    const { leaderIds, snapshot } = leadersOf(nodes, payload.blockIds);
    laps.lap('collect');

    // (g) re-baseline on the swapped-in document with its ids, resume block-sync, refresh the JS-side content cache.
    if (!finishStructuralSwapSettle()) throw new Error('finishStructuralSwapSettle returned false');
    laps.lap('settle');
    completed = true;
    scheduleContentChanged(); // (h)
    trace(
      `swap-editor-first direction=${direction} opId=${shortId} ok=true blocks=${payload.blockIds.length} ` +
        `removed=${removedIds.length} insertedLeaders=${leaderIds.length} removedLeaders=${removedLeaderIds.length} ` +
        `batchUpdates=${batch.updates.length} batchInserts=${batch.inserts.length} batchDeletes=${batch.deletes.length}` +
        laps.summary()
    );
    return {
      batch,
      ok: true,
      insertedIds: payload.blockIds.slice(),
      insertedLeaderIds: leaderIds,
      insertedSectionsSnapshot: snapshot,
      removedIds,
      removedLeaderIds,
      predecessorId: null,
      swappedTo: direction === 'undo' ? 'checkpoint' : 'redo',
    };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return refuse(`exception: ${message}`);
  } finally {
    if (!completed && swapStarted) {
      try {
        view.updateState(stateBefore);
        rebindCurrentStateFromView(view);
        restoreBlockIdMaps(idsBefore, typesBefore);
        setManagedBlockIds(managedBefore);
        if (entryBefore) getRegistry().set(opId, entryBefore);
        resetAndSnapshot(view.state.doc);
        pointPluginStateAtLiveIds(view.state);
        view.dispatch(view.state.tr); // repaint the ids that were put back
      } catch (e) {
        trace(
          `swap-editor-first direction=${direction} opId=${shortId} could not put the live state back: ${String(e).slice(0, 200)}`
        );
      }
      setSyncPaused(false);
    }
  }
}
