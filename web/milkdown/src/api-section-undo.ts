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
//       by the editor-first delete, and the live document still equals the saved post-op copy (exactly, or modulo what the app
//       regenerates). It is the same comparison the routing decision made when the key was pressed (`liveDocMatchesSavedCopy`,
//       one shared function), asked again because Swift reserves its writer ticket between the press and this turn and the user
//       can type in those milliseconds. If anything differs the call refuses and has changed nothing;
//   (c) consume everything pending (`getBlockChanges`) as the batch Swift applies BEFORE the reinsert job;
//   (d) pause block-sync (no redo state is stored: a quick-undone entry is never redone by a swap, see the redo below);
//   (e) swap the entry's pre-op `checkpoint` back in. It is the whole EditorState, so the section returns with its own text
//       history, and the labels and Notes outside the section are the ones the delete found, not the renumbered ones. The one
//       thing the swap would lose is the editor's REDO branch (what the user typed after the delete and then undid): it is carried
//       across, mapped onto the restored document (redo-branch.ts), and handed to the history plugin with the (h) dispatch. A carry
//       that cannot be built falls back to the plain swap, with a trace line;
//   (f) put the block-id maps captured with that checkpoint back, with the temp ids Swift has confirmed since resolved through
//       the entry's confirmation log. The ids are NOT cleared (the slow path clears them and waits for Swift to push fresh
//       ones); the restored rows keep the ids they had, and the reinsert job writes them back;
//   (g) re-baseline block-sync on the restored document, so the restore itself is never read as a wave of edits;
//   (h) scroll the caret into view, mark the paint, and leave block-sync PAUSED. Swift reserves the reinsert's ticket next and then
//       calls `resumeSyncAfterQuickUndo`, which hands block-sync back and queues whatever was typed meanwhile BEHIND the reinsert.
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
import { carryRedoBranch, setCarriedHistory } from './redo-branch';
import {
  cancelPendingInsertions,
  closeEditingPopupsAndClearBoundaryState,
  getInFlightOpId,
  getQuickUndoPausedOpId,
  getRegistry,
  isLatched,
  liveDocMatchesSavedCopy,
  noteRestoreForPaint,
  setQuickUndoPausedOpId,
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
  /** What the diff added to block-sync's queue: edits made while it was paused. They are queued, not returned, and go out with
   * the next poll, which Swift reserves AFTER the reinsert. */
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
  const refuse = (reason: string): QuickUndoResult => {
    trace(`quick-undo opId=${shortId} refused reason=${reason.slice(0, 200)}`);
    return { batch, ok: false, reason, restoredIds: [], restoredLeaderIds: [], removedLeaderIds: [] };
  };

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
    if (!entry) return refuse('noEntry');
    if (entry.midOp) return refuse('midOp');
    if (!entry.idMap || !entry.typeMap) return refuse('noIdMap');
    if (!liveDocMatchesSavedCopy(view, entry, 'undo')) return refuse('docChanged');
    laps.lap('recheck');

    batch = getBlockChanges(); // (c)
    laps.lap('changes');
    setSyncPaused(true); // (d)
    paused = true;
    idsBefore = getAllBlockIds();
    typesBefore = getAllBlockTypes();

    const restoredIdMap = applyConfirmLog(entry.idMap, entry.confirmLog ?? []);
    // [S4] The leaders the swap is about to take out: live leaders whose id the restored document does not hold. Read from the
    // LIVE document and its id map, so it has to happen before `updateState` below.
    const keptIds = new Set(restoredIdMap.values());
    const removedLeaderIds: string[] = [];
    stateBefore.doc.forEach((node, pos) => {
      const id = idsBefore.get(pos);
      if (id === undefined || keptIds.has(id) || leaderLevel(node) === undefined) return;
      removedLeaderIds.push(id);
    });
    const carry = carryRedoBranch(view.state, entry.checkpoint, idsBefore, restoredIdMap); // (e), first half: see `redo-branch.ts`
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

    completed = true;
    trace(
      `quick-undo opId=${shortId} ok=true restored=${restoredIds.length} leaders=${restoredLeaderIds.length} ` +
        `redoCarried=${carry?.carried ? carry.events : 0} batchUpdates=${batch.updates.length} batchInserts=${batch.inserts.length} batchDeletes=${batch.deletes.length}` +
        laps.summary()
    );
    return { batch, ok: true, restoredIds, restoredLeaderIds, removedLeaderIds };
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
    }
  }
}

/**
 * Bridge target for `window.FinalFinal.resumeSyncAfterQuickUndo`. Swift calls it after the reinsert job holds its writer ticket
 * (and in a `defer`, so on EVERY exit of the quick undo, including a refused one). Hands block-sync back, queues what was typed
 * while it was paused (they go out with the next poll, which takes its ticket after the reinsert's), and schedules the
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
export function checkQuickRedoAllowed(opId: string): { entry: UndoRegistryEntry } | { reason: string } {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return { reason: 'noEditor' };
  const view = editorInstance.ctx.get(editorViewCtx);
  closeEditingPopupsAndClearBoundaryState();
  cancelPendingInsertions();
  flushPendingBlockChanges();
  const entry = getRegistry().get(opId);
  if (!isLatched() || getInFlightOpId() !== opId) return { reason: 'notInFlight' };
  if (!entry) return { reason: 'noEntry' };
  if (entry.midOp) return { reason: 'midOp' };
  if (!liveDocMatchesSavedCopy(view, entry, 'redo')) return { reason: 'docChanged' };
  return { entry };
}

/**
 * Bridge target for `window.FinalFinal.redoSectionDeleteEditorFirst`. Synchronous; Swift calls it, with the structural-redo latch
 * held for `opId`, as `JSON.stringify(window.FinalFinal.redoSectionDeleteEditorFirst(opId, rootBlockId, managedIds))`, the same
 * way it calls `deleteSectionEditorFirst`, and reads the same reply (`DeleteSectionResult`). Re-checks that the live document is
 * still the saved pre-op copy (`checkQuickRedoAllowed`; nothing is touched on a refusal: `ok: false`, `reason: 'docChanged'`, an
 * empty batch), then removes the section from the document as it is NOW, under the same opId, as a fresh editor-first delete.
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
  return removeSectionInEditor(opId, rootBlockId, managedIds, { label: 'redo', previousEntry: gate.entry });
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
