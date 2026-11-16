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
//   (b) consume everything pending (`getBlockChanges`, block-sync-plugin's own: it takes the pending maps even while the page's reports
//       hold the typing back for a latched press) as the batch Swift applies BEFORE the job. It is taken FIRST and in this very
//       turn: the re-check below and the swap can then never see a document that holds an edit the batch does not (binding
//       requirement R2, README "Requirements the model puts on rounds 3b and 3c"). The batch comes back on EVERY path EXCEPT a
//       swap that put the typing back (`typingReplayed`): the amended invariant is "typing is saved as batch N before any swap,
//       except under `rebased`, where the wait typing is saved exactly once, by the replay, behind the job" (the job rewrites the rows
//       to the snapshot, so a batch N sent as well would only be overwritten, and its Enter-made rows would be inserted twice);
//   (c) find the target: for 'undo' the entry's pre-op `checkpoint`, for 'redo' the `redoCheckpoint` that `performStructuralSwap`
//       stored when the entry was undone. No entry, or no such checkpoint: `noCheckpoint`, nothing swapped (Swift then falls back to
//       slice 2's whole-document replace);
//   (d) RE-CHECK that the live document still equals the saved copy the press was routed against (`liveDocMatchesSavedCopy`, THE one
//       shared comparison the routing decision, the quick undo's re-check and the quick redo's gate use; `postOpDoc` for an undo,
//       `preOpDoc` for a redo, exactly or modulo what the app regenerates). Swift reads the snapshot and builds the payload between
//       the press and this turn, the editor is live meanwhile, and the user can type in that stretch (the model's
//       EFSnapTypedInWait). Typing since the PRESS is not a difference (phase 4c, job 2): the comparison is made on the document as it
//       was when the key was pressed (`liveDocMatchesSavedCopy` with the press, typing-rebase.ts `docAtPress`), and the typing is
//       put back on top of the swapped-in document by a replay built and tried against the TARGET before anything is swapped
//       (`buildReplayDryRun`). If something else differs (a change that is not typing, or a typed step the target has no place for):
//       `docChanged`, nothing swapped, the entry stays recorded (binding requirement R5). The line
//       `typing-since-press press=P steps=N decision=...` is written at this re-check whatever the outcome;
//   (e) the FULL top-level id alignment pre-check of the payload against the TARGET document (`alignmentProblem`, shared with the
//       restore: count both ways, node types, non-blank content). A mismatch is `idAlignment`: nothing swapped;
//   (f) the swap itself, EXACTLY as today's `performStructuralSwap` does it (undo-coordinator.ts, called unchanged): the redo checkpoint
//       is captured for an undo, the checkpoint state is swapped in whole (text history included), a redo re-anchors `postOpDoc`,
//       block-sync is paused, the ids are cleared. Then the payload's ids and managed ids are applied, the editor repaints them,
//       and the ids are checked once more against the swapped-in document (`idProblem`);
//   (g) `finishStructuralSwapSettle`, unchanged: re-baseline block-sync on the swapped-in document WITH its ids, resume block-sync,
//       refresh the JS-side content cache;
//   (g2) dispatch the replay (typing since the press, put back on top), after the swap, the ids and the settle's `resetAndSnapshot`,
//       so block-sync sees it as new typing; the live document must then equal the dry run's. Anything else puts the live state back;
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
import { setAsideRedoBranch } from './redo-branch';
import type { ExpectedBlockMeta } from './types';
import {
  buildReplayDryRun,
  formatTypingSincePressLine,
  inspectPress,
  type ReplayDryRun,
  type TypingDecision,
} from './typing-rebase';
import { idsByOffsetFromPayload, idsOfDocumentAtPress } from './typing-route';
import {
  adoptReplayedTyping,
  cancelPendingInsertions,
  closeEditingPopupsAndClearBoundaryState,
  finishStructuralSwapSettle,
  getInFlightOpId,
  getInFlightPress,
  getRegistry,
  getTypingCollector,
  isLatched,
  liveDocMatchesSavedCopy,
  performStructuralSwap,
  typingAlreadySent,
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
  /** True when the typing done while the press waited was put back on top of the swapped-in document (decision `rebased`). Then
   * `batch` is empty: the replay is the only carrier of that typing, saved once behind the job. Swift ends the redo branch on it
   * (inside the gate, after the stacks have moved). Absent otherwise. */
  typingReplayed?: boolean;
}

// Test seam (web tests only; production never sets it): runs right after the swap, the payload's ids and the repaint, before the ids
// are checked and before the settle. A throw from it exercises the failure path a real error after the swap would take; a hook that
// tampers with an id exercises the post-swap alignment check.
let afterSwapHook: (() => void) | null = null;
export function setTestAfterSwapHook(hook: (() => void) | null): void {
  afterSwapHook = hook;
}

// Test seam (web tests only): runs right after the replay is dispatched, before the check that the document equals the dry run's. A throw
// from it exercises the put-back after a replay that went wrong.
let afterReplayHook: (() => void) | null = null;
export function setTestAfterReplayHook(hook: (() => void) | null): void {
  afterReplayHook = hook;
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
  // F21: ONE `typing-since-press` line per press, written when this call ends, at its FINAL decision (set below once the press is
  // known). A refusal that Swift hands to another road (the old body, the caller's whole replace) writes none: that road decides.
  let finalizeLine: (reason: string | null) => void = () => {};
  const refuse = (reason: string): StructuralSwapResult => {
    finalizeLine(reason);
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
  // The press this call answers (the latch is held for this very op), and the line the re-check writes whatever the outcome.
  const press = isLatched() && getInFlightOpId() === opId ? getInFlightPress() : undefined;
  const collector = getTypingCollector();
  let decision: TypingDecision | null = null;
  const decide = (next: TypingDecision): void => {
    if (decision === null) decision = next;
  };
  finalizeLine = (reason) => {
    if (press === undefined || decision === null) return;
    // A refusal Swift hands to another road (`idAlignment`, `exception`, ...) writes none: that road decides. The refusals that name
    // their own reason (no registry entry, entry mid-operation, no id map) are final here and write their line.
    const named = decision === 'noEntry' || decision === 'midOp' || decision === 'noIdMap';
    if (reason !== null && reason !== 'docChanged' && !named) return;
    // `rebased` is decided at the dry run; a failure after it means the typing was not put back.
    const final = reason !== null && decision === 'rebased' ? 'unplaceable' : decision;
    trace(formatTypingSincePressLine(press, collector.stepsSince(press).length, final));
  };
  let replay: ReplayDryRun | null = null;
  let typingReplayed = false;

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
      decide('noEntry');
      return refuse('noCheckpoint');
    }

    // (d) the re-check, on the document as it was when the key was pressed (without a press: on the live document, as before).
    const inspection = press === undefined ? null : inspectPress(collector, press, view.state.doc);
    if (press === undefined || inspection === null) {
      if (!liveDocMatchesSavedCopy(view, entry, direction)) return refuse('docChanged');
    } else {
      // Typing that was already sent (the lifecycle flush released the hold) cannot be put back: it would be saved twice.
      const alreadySent = inspection.kind === 'typing' && typingAlreadySent(press);
      if (inspection.kind === 'changed' || alreadySent || !liveDocMatchesSavedCopy(view, entry, direction, press)) {
        decide('changed');
        return refuse('docChanged');
      }
      if (inspection.kind === 'matched') decide('matched');
    }
    laps.lap('recheck');

    // (e) the payload against the document it is about to name, BEFORE anything is touched.
    const problem = alignmentProblem(target.doc, payload);
    if (problem !== null) {
      detail = problem;
      decide('unplaceable');
      return refuse('idAlignment');
    }
    laps.lap('align');

    // The typing since the press, rebuilt against the TARGET and tried there before anything is touched. Only a typed step the target
    // has no place for refuses, here, before the swap (typing kept: the batch comes back).
    if (press !== undefined && inspection !== null && inspection.kind === 'typing') {
      const dry = buildReplayDryRun(target, {
        steps: inspection.typing,
        docAtPress: inspection.docAtPress,
        idsAtPress: idsOfDocumentAtPress(collector, press, view.state.doc, getAllBlockIds()),
        targetIds: idsByOffsetFromPayload(target.doc, payload.blockIds, payload.expectedBlocks),
        liveSelection: view.state.selection,
        syncPausedAfter: false,
        liveState: view.state,
      });
      if (!dry.ok) {
        detail = `unplaceable: ${dry.reason ?? ''}`;
        decide('unplaceable');
        return refuse('docChanged');
      }
      decide('rebased');
      replay = dry;
      laps.lap('replay-dry-run');
    }

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

    // (g2) the typing put back, as new typing for block-sync (the settle just re-baselined it on the swapped-in document). The ids
    // and the managed set are installed above, so plugin state they reset is not seen by the replay.
    if (replay?.dryState && press !== undefined) {
      for (const replayTr of replay.replayTrs) view.dispatch(replayTr);
      afterReplayHook?.();
      if (!view.state.doc.eq(replay.dryState.doc)) {
        // Refuse with the notice (F13): `exception: ...` would make Swift run the old restore body, which silently drops the typing.
        // The `finally` below puts the live state back; the batch of the typing comes back with the refusal.
        detail = 'the replay did not produce the document the dry run built';
        return refuse('docChanged');
      }
      adoptReplayedTyping(press, replay.rebased);
      setAsideRedoBranch(opId, null, getRegistry().keys()); // no later quick redo may put back steps the typing has ended
      batch = emptyBatch(); // the replay is the only carrier of the wait typing (saved once, behind the job)
      typingReplayed = true;
      laps.lap('replay');
    }
    completed = true;
    finalizeLine(null);
    scheduleContentChanged(); // (h)
    trace(
      `swap-editor-first direction=${direction} opId=${shortId} ok=true blocks=${payload.blockIds.length} ` +
        `removed=${removedIds.length} insertedLeaders=${leaderIds.length} removedLeaders=${removedLeaderIds.length} ` +
        `batchUpdates=${batch.updates.length} batchInserts=${batch.inserts.length} batchDeletes=${batch.deletes.length}` +
        (typingReplayed ? ' typingReplayed=true' : '') +
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
      ...(typingReplayed ? { typingReplayed: true } : {}),
    };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    if (replay !== null) {
      // The user's typing is in play (F13): refuse with the notice and keep the typing; `exception: ...` would make Swift run the old
      // restore body, which silently drops it. The exception text goes to the trace line only.
      detail = `exception: ${message}`;
      return refuse('docChanged');
    }
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
