// Quick undo and quick redo of an editor-first section delete -- the editor half of Phase 4b part 2, slice 2b (t-07eac5cb).
//
// Today's Cmd-Z after a section delete waits for the delete's own saving job and its follow-up work, swaps the editor state, and
// then restores the whole project from a Version History copy; anything typed in that window is lost. Here the EDITOR puts the
// section back first, in one synchronous JavaScript turn, exactly the way `deleteSectionEditorFirst` removed it, and the database
// catches up afterwards through a queued reinsert job (Swift side). Nothing is pushed back over the user's text.
//
// `undoSectionDeleteEditorFirst(opId)` is that turn. What it does, in order (plan C1, addenda v2 to v4):
//   (0) the boundary hygiene every structural op performs (`closeEditingPopupsAndClearBoundaryState`, `cancelPendingInsertions`):
//       a Find session, an open popup or a pending paste position must not act on offsets the swap is about to invalidate;
//   (a) flush the 100 ms detection debounce, so an edit typed a moment ago is a pending change now;
//   (b) RE-CHECK that this press may still swap: the latch is held for this very op, the registry entry is finished and was made
//       by the editor-first delete, and the document AS IT WAS WHEN THE KEY WAS PRESSED still equals the saved post-op copy
//       (exactly, or modulo what the app regenerates). It is the same comparison the routing decision made when the key was pressed
//       (`liveDocMatchesSavedCopy`, one shared function, here with the press: typing-rebase.ts `docAtPress` inverts every step
//       recorded since). Typing since the press is not a difference (phase 4c, job 2): it is put back on top of the restored
//       document by a replay that is built and tried against the target BEFORE anything is consumed or swapped
//       (`buildReplayDryRun`); only a typed step the target has no place for refuses (`docChanged`, nothing consumed). The line
//       `typing-since-press press=P steps=N decision=...` is written here whatever the outcome. If anything else differs the call
//       refuses and has changed nothing;
//   (c) consume everything pending (`getBlockChanges`) as the batch Swift applies BEFORE the reinsert job. Under `rebased` that batch
//       is the held wait typing and is NOT sent: the replay is its only carrier, found by `detectEditsSinceSnapshot` at the resume
//       and queued behind the reinsert once (sent as well, an Enter-made paragraph would be inserted twice). It is kept aside and
//       comes back in the reply if the swap or the replay fails (D2). Under every other decision it is sent as before;
//   (d) pause block-sync (no redo state is stored: a quick-undone entry is never redone by a swap, see the redo below);
//   (e) swap the entry's pre-op `checkpoint` back in. It is the whole EditorState, so the section returns with its own text
//       history, and the labels and Notes outside the section are the ones the delete found, not the renumbered ones. The one
//       thing the swap would lose is the editor's REDO branch (what the user typed after the delete and then undid): it is carried
//       across, mapped onto the restored document (redo-branch.ts), and handed to the history plugin with the (h) dispatch. A carry
//       that cannot be built falls back to the plain swap, with a trace line. The same branch, untouched and in post-operation
//       coordinates, is also kept aside for the quick redo of a Duplicate or a restore (`setAsideRedoBranch`, after (h)): the
//       carry maps away every redo step the user made inside the text this undo takes out, and the quick redo puts the kept
//       branch back once it has put that text back (`putBackAfterQuickRedo`);
//   (f) put the block-id maps captured with that checkpoint back, with the temp ids Swift has confirmed since resolved through
//       the entry's confirmation log. The ids are NOT cleared (the slow path clears them and waits for Swift to push fresh
//       ones); the restored rows keep the ids they had, and the reinsert job writes them back;
//   (g) re-baseline block-sync on the restored document, so the restore itself is never read as a wave of edits;
//   (h) scroll the caret into view, mark the paint, and leave block-sync PAUSED. Swift reserves the reinsert's ticket next and then
//       calls `resumeSyncAfterQuickUndo`, which hands block-sync back and queues whatever was typed meanwhile BEHIND the reinsert;
//   (h2) dispatch the replay (the typing since the press, put back on top). It goes AFTER (h): that dispatch hands the carried history
//       to the history plugin wholesale, which would drop the replay's undo step. The live document must then equal the dry run's;
//       any failure puts the live state back in the `finally`, with the held batch returned.
// If anything throws after the swap, the `finally` puts the live state, the id maps and the baseline back and unpauses, and the
// reply is `ok: false` with the batch, so a refused undo leaves the document as the user had it.
//
// The quick REDO is not a swap at all: `redoSectionDeleteEditorFirst` removes the section again from the document as it stands
// NOW, under the same opId, through the shared `removeSectionInEditor` (api-section-delete.ts). Swift then queues an ordinary delete
// job behind the reinsert. A stored redo state would put back labels and Notes the automatic rewrites have changed since.
//
// The undo is generic: it swaps the entry's pre-op checkpoint back in, whatever the op changed. It is also the quick undo of an
// editor-first DUPLICATE (api-section-duplicate.ts), where the swap takes the copy OUT; the reply's `removedLeaderIds` names the
// leaders it removed so Swift can hide them from the sidebar at once (t-18b7fa48 [S4]). The duplicate's redo (a fresh duplicate
// under the same opId) passes the same `checkQuickRedoAllowed` gate as the delete's.

import { editorViewCtx } from '@milkdown/kit/core';
import type { EditorState } from '@milkdown/kit/prose/state';
import { type DeleteSectionResult, leaderLevel, removeSectionInEditor } from './api-section-delete';
import { getAllBlockIds, getAllBlockTypes, restoreBlockIdMaps } from './block-id-plugin';
import {
  type BlockChanges,
  detectEditsSinceSnapshot,
  flushPendingBlockChanges,
  getBlockChanges,
  rebindCurrentStateFromView,
  resetAndSnapshot,
  setSyncPaused,
} from './block-sync-plugin';
import { pushLiveContentToSwift } from './content-push';
import { getContentHasBeenSet, getEditorInstance, getIsSettingContent } from './editor-state';
import {
  carryRedoBranch,
  putBackSetAsideRedo,
  redoBranchOf,
  resetSetAsideRedo,
  setAsideRedoBranch,
  setCarriedHistory,
} from './redo-branch';
import {
  buildReplayDryRun,
  formatTypingSincePressLine,
  inspectPress,
  type ReplayDryRun,
  type TypingDecision,
} from './typing-rebase';
import { idsOfDocumentAtPress } from './typing-route';
import {
  adoptReplayedTyping,
  cancelPendingInsertions,
  clearStructuralUndoRegistry,
  closeEditingPopupsAndClearBoundaryState,
  getInFlightOpId,
  getInFlightPress,
  getQuickUndoPausedOpId,
  getRegistry,
  getTypingCollector,
  isLatched,
  liveDocMatchesSavedCopy,
  noteRestoreForPaint,
  setQuickUndoPausedOpId,
  typingAlreadySent,
  typingSincePressTouches,
  type UndoRegistryEntry,
} from './undo-coordinator';

/** What `undoSectionDeleteEditorFirst` returns, on every path. Swift reads it as `JSON.stringify(...)`, like `getBlockChanges`. */
export interface QuickUndoResult {
  /** Every pending edit this call consumed, in `getBlockChanges()` shape. Empty on a refusal (nothing is consumed before the
   * re-check passes) and when nothing was pending. Swift always applies a returned batch. */
  batch: BlockChanges;
  ok: boolean;
  /** Why `ok` is false: 'noEditor', 'notInFlight', 'noEntry', 'midOp', 'noIdMap', 'docChanged', or 'exception: <message>'. */
  reason?: string;
  /** Ids of the top-level blocks the restore brought back (leaders and body), in document order, as the editor holds them now
   * (temp ids Swift has already confirmed are permanent; one it has not confirmed yet is still the temp id). */
  restoredIds: string[];
  /** The subset of `restoredIds` that are section leaders (headings and section breaks). */
  restoredLeaderIds: string[];
  /** Ids of the section leaders (headings and section breaks) the undo took OUT of the document: the live leaders whose id the
   * restored document does not hold, read before the swap, in document order. Empty for the undo of a delete (a delete only
   * removes). For the undo of an editor-first duplicate they are the copy's leaders, so Swift can hide them from the sidebar at once
   * (t-18b7fa48 [S4]). */
  removedLeaderIds: string[];
  /** True when the typing done while the press waited was put back on top of the restored document (decision `rebased`). Then
   * `batch` is empty: the replay is the only carrier of that typing, queued behind the reinsert at the resume. Swift ends the redo
   * branch on it (inside the gate, after the stacks have moved). Absent otherwise. */
  typingReplayed?: boolean;
}

// Test seam (web tests only): runs right after the replay is dispatched, before the check that the document equals the dry run's.
let afterReplayHook: (() => void) | null = null;
export function setTestAfterQuickReplayHook(hook: (() => void) | null): void {
  afterReplayHook = hook;
}

/** What `resumeSyncAfterQuickUndo` returns. Swift reads it as `JSON.stringify(...)`; the call never throws. */
export interface QuickResumeResult {
  ok: boolean;
  /** Why `ok` is false: 'noEditor' or 'exception: <message>'. */
  reason?: string;
  /** True when this call handed block-sync back (a quick undo had paused it); false when there was nothing of the quick undo's to
   * resume, e.g. the undo was refused, or this is a second call. Then nothing was touched: block-sync's pause belongs to whoever
   * took it. */
  resumed: boolean;
  /** What the diff added to block-sync's queue: edits made while it was paused. They are queued, not returned, and go out as
   * the page's next report, which Swift reserves AFTER the reinsert. */
  pausedEdits: { updates: number; inserts: number; deletes: number };
  /** True when a `contentChanged` notification was scheduled (about 50 ms later, or at idle where the browser has an idle
   * callback). It carries the live Markdown, read when it runs, so it can never be older than the typing. */
  contentChangedScheduled: boolean;
}

/** A diagnostic must never break the operation it observes. Counts, ids and timings only, never document text. */
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

const emptyBatch = (): BlockChanges => ({ updates: [], inserts: [], deletes: [] });

/** Wall-clock laps of one call, as whole milliseconds in the trace line. Exported for api-structural-swap.ts, which traces the same way. */
export class Laps {
  private readonly start = performance.now();
  private last = this.start;
  private readonly ms: Array<[string, number]> = [];
  lap(step: string): void {
    const now = performance.now();
    this.ms.push([step, now - this.last]);
    this.last = now;
  }
  summary(): string {
    const total = Math.round(performance.now() - this.start);
    return ` jsMs total=${total}${this.ms.map(([step, ms]) => ` ${step}=${Math.round(ms)}`).join('')}`;
  }
}

/** The saved id map with every logged temp -> permanent pair applied (a temp id confirmed after the delete is permanent now). */
function applyConfirmLog(ids: ReadonlyMap<number, string>, log: ReadonlyArray<[string, string]>): Map<number, string> {
  if (log.length === 0) return new Map(ids);
  const permanentOf = new Map(log);
  const out = new Map<number, string>();
  for (const [offset, id] of ids) out.set(offset, permanentOf.get(id) ?? id);
  return out;
}

/**
 * Bridge target for `window.FinalFinal.undoSectionDeleteEditorFirst`. Synchronous; Swift calls it, with the structural-undo latch
 * held for `opId` (the press that routed here set it), as `JSON.stringify(window.FinalFinal.undoSectionDeleteEditorFirst(opId))`
 * in the same synchronous stretch in which it reserves its writer ticket for the returned batch. Leaves block-sync paused on
 * success: Swift calls `resumeSyncAfterQuickUndo` once the reinsert job holds its ticket.
 */
export function undoSectionDeleteEditorFirst(opId: string): QuickUndoResult {
  const shortId = opId.slice(0, 8);
  let batch: BlockChanges = emptyBatch();
  // Under `rebased` the batch taken at (c) is the held wait typing: it is set aside here and comes back on every failure (D2).
  let heldBatch: BlockChanges | null = null;
  // F21: ONE `typing-since-press` line per press, written when this call ends, at its FINAL decision (set below once the press is
  // known). A refusal that Swift hands to another road writes none: that road decides.
  let finalizeLine: (reason: string | null) => void = () => {};
  const refuse = (reason: string): QuickUndoResult => {
    finalizeLine(reason);
    trace(`quick-undo opId=${shortId} refused reason=${reason.slice(0, 200)}`);
    return {
      batch: heldBatch ?? batch,
      ok: false,
      reason,
      restoredIds: [],
      restoredLeaderIds: [],
      removedLeaderIds: [],
    };
  };
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

  const editorInstance = getEditorInstance();
  if (!editorInstance) return refuse('noEditor');
  const view = editorInstance.ctx.get(editorViewCtx);
  const laps = new Laps();
  // (0) before the re-check: a popup edit committed here changes the document and the re-check then refuses (`docChanged`).
  closeEditingPopupsAndClearBoundaryState();
  cancelPendingInsertions();

  let paused = false;
  let swapped = false;
  let completed = false;
  const entryBefore = getRegistry().get(opId);
  const stateBefore: EditorState = view.state;
  let idsBefore: Map<number, string> = new Map();
  let typesBefore: Map<number, string> = new Map();

  try {
    flushPendingBlockChanges(); // (a)
    laps.lap('flush');

    // (b) the re-check: nothing is touched, and nothing consumed, unless every condition holds.
    if (!isLatched() || getInFlightOpId() !== opId) return refuse('notInFlight');
    const entry = entryBefore;
    if (!entry) {
      decide('noEntry');
      return refuse('noEntry');
    }
    if (entry.midOp) {
      decide('midOp');
      return refuse('midOp');
    }
    if (!entry.idMap || !entry.typeMap) {
      decide('noIdMap');
      return refuse('noIdMap');
    }
    const inspection = press === undefined ? null : inspectPress(collector, press, view.state.doc);
    if (press === undefined || inspection === null) {
      if (!liveDocMatchesSavedCopy(view, entry, 'undo')) return refuse('docChanged');
    } else {
      // Typing that was already sent (the lifecycle flush released the hold) cannot be put back: it would be saved twice.
      const alreadySent = inspection.kind === 'typing' && typingAlreadySent(press);
      if (inspection.kind === 'changed' || alreadySent || !liveDocMatchesSavedCopy(view, entry, 'undo', press)) {
        decide('changed');
        return refuse('docChanged');
      }
      if (inspection.kind === 'matched') decide('matched');
    }
    laps.lap('recheck');

    // The target ids (the saved id map with every logged temp -> permanent pair applied), known before the swap. The same log makes
    // an id the press stored as a temp id and the target holds as its permanent id one block.
    const restoredIdMap = applyConfirmLog(entry.idMap, entry.confirmLog ?? []);
    if (press !== undefined && inspection !== null && inspection.kind === 'typing') {
      const permanentOf = new Map(entry.confirmLog ?? []);
      const dry = buildReplayDryRun(entry.checkpoint, {
        steps: inspection.typing,
        docAtPress: inspection.docAtPress,
        idsAtPress: idsOfDocumentAtPress(collector, press, view.state.doc, getAllBlockIds()),
        targetIds: restoredIdMap,
        canonical: (id) => permanentOf.get(id) ?? id,
        liveSelection: view.state.selection,
        syncPausedAfter: false,
        liveState: view.state,
      });
      if (!dry.ok) {
        decide('unplaceable');
        return refuse('docChanged'); // nothing consumed: the typing stays pending and goes out when the latch ends
      }
      decide('rebased');
      replay = dry;
      laps.lap('replay-dry-run');
    }

    batch = getBlockChanges(); // (c)
    if (replay) {
      heldBatch = batch;
      batch = emptyBatch();
    }
    laps.lap('changes');
    setSyncPaused(true); // (d)
    paused = true;
    idsBefore = getAllBlockIds();
    typesBefore = getAllBlockTypes();

    // [S4] The leaders the swap is about to take out: live leaders whose id the restored document does not hold. Read from the
    // LIVE document and its id map, so it has to happen before `updateState` below.
    const keptIds = new Set(restoredIdMap.values());
    const removedLeaderIds: string[] = [];
    stateBefore.doc.forEach((node, pos) => {
      const id = idsBefore.get(pos);
      if (id === undefined || keptIds.has(id) || leaderLevel(node) === undefined) return;
      removedLeaderIds.push(id);
    });
    const live = view.state;
    const liveRedo = redoBranchOf(live); // kept aside below, for the quick redo of this operation (t-14f908b4)
    const carry = carryRedoBranch(live, entry.checkpoint, idsBefore, restoredIdMap); // (e), first half: see `redo-branch.ts`
    if (carry && !carry.carried) {
      // A never-expected guard: the plain swap below loses the editor's redo branch (what the user undid by typing), never the document.
      trace(`quick-undo opId=${shortId} redo branch not carried, plain swap: ${carry.reason.slice(0, 200)}`);
    }
    laps.lap('carry');

    view.updateState(entry.checkpoint); // (e), second half
    swapped = true;
    rebindCurrentStateFromView(view);
    laps.lap('swap');

    restoreBlockIdMaps(restoredIdMap, entry.typeMap); // (f)
    laps.lap('ids');
    resetAndSnapshot(view.state.doc); // (g)
    laps.lap('snapshot');

    const liveIds = new Set(idsBefore.values());
    const restoredNow = getAllBlockIds();
    const restoredIds: string[] = [];
    const restoredLeaderIds: string[] = [];
    view.state.doc.forEach((node, pos) => {
      const id = restoredNow.get(pos);
      if (id === undefined || liveIds.has(id)) return;
      restoredIds.push(id);
      if (leaderLevel(node) !== undefined) restoredLeaderIds.push(id);
    });
    laps.lap('collect');

    const scrollTr = view.state.tr.scrollIntoView();
    view.dispatch(carry?.carried ? setCarriedHistory(scrollTr, carry) : scrollTr); // (h): the carried redo branch rides on this dispatch
    setQuickUndoPausedOpId(opId); // block-sync stays paused; `resumeSyncAfterQuickUndo` ends it
    noteRestoreForPaint(opId, 'quick');
    laps.lap('scroll');

    // (h2) the typing put back, after the carried history is in place. The live document must equal the dry run's.
    if (replay?.dryState && press !== undefined) {
      for (const replayTr of replay.replayTrs) view.dispatch(replayTr);
      afterReplayHook?.();
      if (!view.state.doc.eq(replay.dryState.doc)) {
        throw new Error('the replay did not produce the document the dry run built');
      }
      adoptReplayedTyping(press, replay.rebased);
      heldBatch = null; // the replay is the only carrier of the wait typing (queued behind the reinsert at the resume)
      typingReplayed = true;
      laps.lap('replay');
    }

    completed = true;
    finalizeLine(null);
    // The live redo branch (post-operation coordinates, untouched) is kept for the quick redo of this operation, which puts it back
    // once it has run the operation again (`putBackAfterQuickRedo`). Always written, also with nothing to keep: that deletes a
    // record an earlier undo of the same operation left. Its block ids go through the entry's confirmation log, like the restored ones.
    // When Swift drops the structural redo afterwards (`quickUndoLiveDiffersFromRestored`) nothing takes the record; the next store
    // prunes it once the operation id has left the registry. A section DELETE stores a record too (this undo is shared); its redo
    // never takes it, so it is memory only and the next store prunes it.
    // Typing in the wait ends every pending redo, so under a replay nothing is kept aside (and the record of an earlier undo goes).
    const keptAside =
      liveRedo && !typingReplayed
        ? {
            branch: liveRedo,
            doc: live.doc,
            ids: applyConfirmLog(idsBefore, entry.confirmLog ?? []),
            depthAfterUndo: redoBranchOf(view.state)?.eventCount ?? 0,
          }
        : null;
    setAsideRedoBranch(opId, keptAside, getRegistry().keys());
    trace(
      `quick-undo opId=${shortId} ok=true restored=${restoredIds.length} leaders=${restoredLeaderIds.length} ` +
        `redoCarried=${carry?.carried ? carry.events : 0} setAside=${keptAside ? keptAside.branch.eventCount : 0} batchUpdates=${batch.updates.length} batchInserts=${batch.inserts.length} batchDeletes=${batch.deletes.length}` +
        (typingReplayed ? ' typingReplayed=true' : '') +
        laps.summary()
    );
    return {
      batch,
      ok: true,
      restoredIds,
      restoredLeaderIds,
      removedLeaderIds,
      ...(typingReplayed ? { typingReplayed: true } : {}),
    };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return refuse(`exception: ${message}`);
  } finally {
    if (!completed) {
      if (swapped) {
        try {
          view.updateState(stateBefore);
          rebindCurrentStateFromView(view);
          restoreBlockIdMaps(idsBefore, typesBefore);
          resetAndSnapshot(view.state.doc);
        } catch (e) {
          trace(`quick-undo opId=${shortId} could not put the live state back: ${String(e).slice(0, 200)}`);
        }
      }
      if (paused) setSyncPaused(false);
      if (getQuickUndoPausedOpId() === opId) setQuickUndoPausedOpId(null); // the failure came after (h): nothing to resume
    }
  }
}

/**
 * Bridge target for `window.FinalFinal.resumeSyncAfterQuickUndo`. Swift calls it after the reinsert job holds its writer ticket
 * (and in a `defer`, so on EVERY exit of the quick undo, including a refused one). Hands block-sync back, queues what was typed
 * while it was paused (they go out with the next report, which takes its ticket after the reinsert's), and schedules the
 * `contentChanged` notification for the restored text. A no-op, touching nothing, when this editor has no quick undo to resume.
 */
export function resumeSyncAfterQuickUndo(): QuickResumeResult {
  const none = { updates: 0, inserts: 0, deletes: 0 };
  const opId = getQuickUndoPausedOpId();
  if (opId === null) return { ok: true, resumed: false, pausedEdits: none, contentChangedScheduled: false };
  setQuickUndoPausedOpId(null);

  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    setSyncPaused(false);
    return { ok: false, reason: 'noEditor', resumed: false, pausedEdits: none, contentChangedScheduled: false };
  }
  const view = editorInstance.ctx.get(editorViewCtx);
  const start = performance.now();
  let pausedEdits = none;
  let reason: string | undefined;
  try {
    setSyncPaused(false);
    pausedEdits = detectEditsSinceSnapshot(view.state.doc);
  } catch (e) {
    reason = `exception: ${e instanceof Error ? e.message : String(e)}`;
  }
  scheduleContentChanged();
  const ms = performance.now() - start;
  trace(
    `quick-resume opId=${opId.slice(0, 8)} ok=${reason === undefined} pausedUpdates=${pausedEdits.updates} ` +
      `pausedInserts=${pausedEdits.inserts} pausedDeletes=${pausedEdits.deletes} ms=${ms.toFixed(1)}`
  );
  return { ok: reason === undefined, reason, resumed: true, pausedEdits, contentChangedScheduled: true };
}

/** The editor's `contentChanged` notification for the restored text, off the paint path: reading the Markdown of a whole book
 * takes long enough to delay the next keystroke's echo. Same quiet-period idea as main.ts's 50 ms typing debounce, and the same
 * function sends it. Uses an idle callback where the browser has one. The text is read when the callback runs, so it is never
 * older than what the user typed in between. Exported for api-structural-swap.ts: a checkpoint swap changes the document with no
 * document-changing transaction, so main.ts's typing debounce never fires for it. */
export function scheduleContentChanged(): void {
  const send = () => {
    if (getIsSettingContent() || !getContentHasBeenSet()) return; // a programmatic content set sends its own
    pushLiveContentToSwift(false);
  };
  const idle = (window as any).requestIdleCallback;
  if (typeof idle === 'function') idle(send, { timeout: 300 });
  else setTimeout(send, 50);
}

/**
 * The gate every quick REDO passes before it changes anything (the delete's, below, and the duplicate's, api-section-duplicate.ts):
 * the boundary hygiene every structural op performs, the flush of the 100 ms detection debounce, and the re-check that this press
 * may still run: the redo latch is held for this very op, the registry entry is finished, and the live document still equals the
 * saved pre-op copy (`liveDocMatchesSavedCopy`, the one shared comparison the routing decision made when the key was pressed,
 * exact or modulo what the app regenerates). Touches nothing on a refusal beyond the hygiene and the flush every path performs.
 * Returns the registry entry the redo replaces, or the reason: 'noEditor', 'notInFlight', 'noEntry', 'midOp' or 'docChanged'.
 */
export function checkQuickRedoAllowed(
  opId: string
):
  | { entry: UndoRegistryEntry; typed: boolean; guard: ((from: number, to: number) => boolean) | undefined }
  | { reason: string } {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return { reason: 'noEditor' };
  const view = editorInstance.ctx.get(editorViewCtx);
  closeEditingPopupsAndClearBoundaryState();
  cancelPendingInsertions();
  flushPendingBlockChanges();
  const entry = getRegistry().get(opId);
  if (!isLatched() || getInFlightOpId() !== opId) return { reason: 'notInFlight' };
  // The trace line of the re-check (typing-rebase.ts `formatTypingSincePressLine`), written whatever the outcome.
  const press = getInFlightPress();
  const line = (decision: TypingDecision): void => {
    if (press !== undefined)
      trace(formatTypingSincePressLine(press, getTypingCollector().stepsSince(press).length, decision));
  };
  if (!entry) {
    line('noEntry');
    return { reason: 'noEntry' };
  }
  if (entry.midOp) {
    line('midOp');
    return { reason: 'midOp' };
  }
  // A redo re-runs the operation on the LIVE document, so typing done in the wait is already in the document the operation runs on;
  // there is nothing to replay (`typingReplayed` stays false) and the typing goes out as batch N, once. The press-time check is on
  // the document AS IT WAS WHEN THE KEY WAS PRESSED. The redo is refused only when that typing sits inside the text the redo takes
  // out (the operation's own removal checks it, with `guard`, before it records anything): then the typing would go with it.
  const inspection = press === undefined ? null : inspectPress(getTypingCollector(), press, view.state.doc);
  if (press === undefined || inspection === null) {
    if (!liveDocMatchesSavedCopy(view, entry, 'redo')) {
      line('changed');
      return { reason: 'docChanged' };
    }
    line('matched');
    return { entry, typed: false, guard: undefined };
  }
  if (inspection.kind === 'changed' || !liveDocMatchesSavedCopy(view, entry, 'redo', press)) {
    line('changed');
    return { reason: 'docChanged' };
  }
  if (inspection.kind === 'matched') {
    line('matched');
    return { entry, typed: false, guard: undefined };
  }
  return { entry, typed: true, guard: typingSincePressTouches }; // the line is written once the redo has run: `finishQuickRedoLine`
}

/** The trace line of a quick redo that had typing since its press, written once the operation has run (or refused): `rebased` when
 * the redo ran with the typing kept, `unplaceable` when it was refused because the typing sits inside the text it takes out. A redo
 * without typing wrote its `matched` line at the gate. */
export function finishQuickRedoLine(gate: { typed: boolean }, performed: boolean): void {
  if (!gate.typed) return;
  const press = getInFlightPress();
  if (press === undefined) return;
  trace(
    formatTypingSincePressLine(
      press,
      getTypingCollector().stepsSince(press).length,
      performed ? 'rebased' : 'unplaceable'
    )
  );
}

/**
 * What the quick redo of a Duplicate or a restore does as its LAST step (`redoSectionDuplicateEditorFirst`,
 * `redoReplaceRangeEditorFirst`; not the delete's, which never loses typing): puts back the redo branch the quick undo kept aside
 * (`setAsideRedoBranch`), so the next Cmd-Shift-Z redoes the typing the user did inside the operation's text. Called after the
 * operation has been run again and its registry entry finalized, so the put-back is one meta-only transaction on the live state.
 * Writes one trace line, `<label> opId=... redoPutBack=<events>` or `<label> opId=... redo put-back skipped: <reason>`, and
 * nothing when no record was kept. Never throws.
 */
export function putBackAfterQuickRedo(opId: string, label: string, typingEndedIt = false): void {
  const shortId = opId.slice(0, 8);
  if (typingEndedIt) {
    // The user typed in the redo's wait: typing ends every pending redo, so the steps kept aside are gone for good (F10). The depth
    // check inside the put-back would not notice (the new typing empties the redo list, which is also what the quick undo left).
    setAsideRedoBranch(opId, null, getRegistry().keys());
    trace(`${label} opId=${shortId} redo put-back skipped: the user typed in the redo's wait`);
    return;
  }
  try {
    const editorInstance = getEditorInstance();
    if (!editorInstance) return;
    const view = editorInstance.ctx.get(editorViewCtx);
    const outcome = putBackSetAsideRedo(view, opId, getAllBlockIds());
    if (!outcome) return;
    if (!outcome.putBack) {
      trace(`${label} opId=${shortId} redo put-back skipped: ${outcome.reason.slice(0, 200)}`);
      return;
    }
    trace(`${label} opId=${shortId} redoPutBack=${outcome.events}`);
  } catch (e) {
    trace(`${label} opId=${shortId} redo put-back skipped: exception: ${String(e).slice(0, 200)}`);
  }
}

/**
 * Bridge target for `window.FinalFinal.clearStructuralUndoRegistry` (main.ts registers THIS, not the undo-coordinator function
 * alone): the barrier clear, plus the set-aside redo records, which belong to the timeline the barrier replaces. A record left
 * behind would be taken by a later quick redo of the same operation id.
 */
export function clearStructuralUndoRegistryAndRedoRecords(): void {
  clearStructuralUndoRegistry();
  resetSetAsideRedo();
}

/**
 * Bridge target for `window.FinalFinal.redoSectionDeleteEditorFirst`. Synchronous; Swift calls it, with the structural-redo latch
 * held for `opId`, as `JSON.stringify(window.FinalFinal.redoSectionDeleteEditorFirst(opId, rootBlockId, managedIds))`, the same
 * way it calls `deleteSectionEditorFirst`, and reads the same reply (`DeleteSectionResult`). Re-checks that the live document is
 * still the saved pre-op copy (`checkQuickRedoAllowed`; nothing is touched on a refusal: `ok: false`, `reason: 'docChanged'`, an
 * empty batch). Typing since the press elsewhere is kept; typing inside the section it removes refuses the redo with `docChanged`
 * (the batch then carries that typing). It removes the section from the document as it is NOW, under the same opId, as a fresh editor-first delete.
 */
export function redoSectionDeleteEditorFirst(
  opId: string,
  rootBlockId: string,
  managedIds: string[]
): DeleteSectionResult {
  const gate = checkQuickRedoAllowed(opId);
  if ('reason' in gate) {
    trace(`quick-redo opId=${opId.slice(0, 8)} refused reason=${gate.reason}`);
    return {
      batch: emptyBatch(),
      ok: false,
      reason: gate.reason,
      removedIds: [],
      removedLeaderIds: [],
      predecessorId: null,
      removedSectionsSnapshot: [],
    };
  }
  const result = removeSectionInEditor(opId, rootBlockId, managedIds, {
    label: 'redo',
    previousEntry: gate.entry,
    refuseIfTypedInside: gate.guard,
  });
  finishQuickRedoLine(gate, result.ok);
  return result.ok ? { ...result, typed: gate.typed } : result;
}

/**
 * Bridge target for `window.FinalFinal.quickUndoLiveDiffersFromRestored(opId)`. Swift asks it at the end of a quick undo, after the
 * resume, the stack move and the descriptor push: did the document change since the restore (typing in the paused window that the
 * resume could not report, or an edit between the restore and now)? True when the live document no longer equals the entry's `preOpDoc`
 * (the restored document, followed by every automatic rewrite since) by the same shared check the routing decision and the re-check
 * use (`liveDocMatchesSavedCopy`, exact or modulo what the app regenerates). Swift then drops the redo branch: the redo of a delete
 * is only valid for the document the delete left behind. False when there is no editor or no entry to compare with (nothing to
 * invalidate). Reads only: it flushes nothing and changes nothing.
 */
export function quickUndoLiveDiffersFromRestored(opId: string): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  const entry = getRegistry().get(opId);
  if (!entry) return false;
  const view = editorInstance.ctx.get(editorViewCtx);
  return !liveDocMatchesSavedCopy(view, entry, 'redo');
}
