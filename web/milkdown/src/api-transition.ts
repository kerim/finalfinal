// The zoom transition, editor side (Phase 5 job A7, t-94369a83; design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md,
// sections 0 and 1). A zoom in or out used to write a cached copy of the text, re-read the rows and push the whole document over the
// editor; keys typed between the copy and the push were lost (the sync model's windows W1 and W2). Now the page hands Swift what it has
// and starts holding and recording in the same turn (`beginTransition`), Swift writes that through the ordered queue and waits for it,
// reads the rows, and the page then swaps the new document in with the recorded typing put back on top, in one turn (`swapTransition`).
//
// The model's names (docs/architecture/tla/README.md, "Phase 5 step T"), at the step that is each one:
//   TransBegin + TransLiveRead  `beginTransition`: the 100 ms debounce is flushed, the pending batch is drained and returned (the live
//                               editor's own changes, never a cached copy), the collector starts recording, the hold starts (`pend' = {}`:
//                               `hasBlockChanges` / `getBlockChanges` of the bridge answer nothing while the token is set).
//   TransCarryWindow            from `beginTransition` to `swapTransition`: every change is recorded (`TypingCollector`), none reaches
//                               Swift's polls. The window begins at the flush, stricter than the model (which opens it after), and must:
//                               the take and the hold are one turn, so no key can be both in the batch and in the recording.
//   TransBarrier                Swift's side (`BlockSyncService.flushForTransition`): `awaitSettled(through:)` after the batch is written.
//   TransPushFrom + TransReplay `swapTransition`: the parsed target replaces the live document (the body of `setContentWithBlockIds`,
//                               with a SYNCHRONOUS re-baseline of block-sync in place of its animation-frame-deferred one: the one-turn
//                               rule), the recorded typing is rebased onto it block by block (typing-rebase.ts) and dispatched as one
//                               history step that block-sync sees as new typing. A key the target does not hold (typing in a block outside
//                               the zoomed range) comes back as `outside`, an ordinary batch Swift writes after the swap (the model's
//                               carried key with a TEMP id). The hold ends in the same turn.
//   the refusal path            not modelled (the web tests cover it): `{ok: false, refused: true, batch}` with the held typing as the
//                               batch and the live document as the user had it; Swift writes the batch, waits, re-reads and pushes with
//                               today's `setContentWithBlockIds` (the one catch-up the plan allows).
//
// The refusals, and where the live document stands at each:
//   before the replace (nothing touched): a stale token, no editor, the collector's records gone (a barrier cleared them: the typing is in
//     the document and in block-sync's queue, so the batch carries it), a change since the begin that is not typing (`changed`), a target
//     that does not parse, a typed step the target has no place for or that spans the edge of the zoomed range (`unplaceable`).
//   after the replace: a plugin changed the replayed document, or anything threw. The live state, the ids, the managed set and the
//     block-sync baseline are put back exactly as api-structural-swap.ts puts them back, and the batch is the pending diff taken before
//     the replace (block-sync's queue was re-baselined by the replace, so it cannot be read again).

import { editorViewCtx, parserCtx } from '@milkdown/kit/core';
import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import { type EditorState, Selection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import {
  blockScrollTargetTop,
  buildBlockLevelReplace,
  noteTypewriterContentLoad,
  redecorateBlockIds,
  signalPaintComplete,
  syncFigureBlockIdAttrs,
} from './api-content';
import {
  clearBlockIds,
  getAllBlockIds,
  getAllBlockTypes,
  getBlockIdZoomMode,
  getManagedBlockIds,
  pointPluginStateAtLiveIds,
  restoreBlockIdMaps,
  setBlockIdsForTopLevel,
  setBlockIdZoomMode,
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
import {
  clearContentPushTimer,
  getEditorInstance,
  setContentHasBeenSet,
  setCurrentContent,
  setIsSettingContent,
} from './editor-state';
import type { ExpectedBlockMeta, ImageBlockMeta } from './types';
import { buildReplayDryRun, inspectPress, type PressInspection, rebaseTypingSteps } from './typing-rebase';
import { idsByOffsetFromPayload, idsOfDocumentAtPress } from './typing-route';
import {
  allocatePressNumber,
  getTransitionConfirms,
  getTransitionToken,
  getTypingCollector,
  isLatched,
  setTransitionToken,
} from './undo-coordinator';

export interface TransitionBeginOk {
  ok: true;
  token: number;
  /** The pending changes the call drained: what Swift writes through the queue before the barrier. */
  batch: BlockChanges;
}
export interface TransitionBeginRefused {
  ok: false;
  reason: string;
}
export type TransitionBeginResult = TransitionBeginOk | TransitionBeginRefused;

export interface SwapTransitionOptions {
  markdown: string;
  /** One id per top-level block of the parsed target, in document order (`BlockParser.alignmentPairs` order). */
  blockIds: string[];
  expected?: ExpectedBlockMeta[];
  managedBlockIds?: string[];
  imageMeta?: ImageBlockMeta[];
  zoomMode?: boolean;
  scrollToStart?: boolean;
  scrollToBlockId?: string;
  /** Phase 5 job A10: typing replayed at the very point where the target inserted text goes after that text (the target's text there was
   * typed first, in the outgoing Markdown page). Default false (the zoom). */
  carriedTextFirst?: boolean;
}

export interface SwapTransitionOk {
  ok: true;
  /** The recorded typing steps put back on top of the swapped-in document. */
  replayed: number;
  /** Recorded steps the target had no place for and that were dropped (typing in a block outside the zoomed range: it is in `outside`). */
  dropped: number;
  /** Typing in blocks the target does not hold, as an ordinary batch: Swift writes it through the queue right after the swap. */
  outside: BlockChanges;
}
export interface SwapTransitionRefused {
  ok: false;
  refused: true;
  reason: string;
  /** The typing held since the begin, as a batch: Swift writes it, waits, re-reads the rows and pushes the old way (the catch-up). */
  batch: BlockChanges;
}
export type SwapTransitionResult = SwapTransitionOk | SwapTransitionRefused;

// Test seam (web tests only; production never sets it): runs right after the replace and the ids, before the re-baseline and the replay.
// A throw from it exercises the put-back a real failure after the replace would take.
let afterReplaceHook: (() => void) | null = null;
export function setTestAfterTransitionReplaceHook(hook: (() => void) | null): void {
  afterReplaceHook = hook;
}

const emptyBatch = (): BlockChanges => ({ updates: [], inserts: [], deletes: [] });
const sizeOf = (batch: BlockChanges): string =>
  `u=${batch.updates.length} i=${batch.inserts.length} d=${batch.deletes.length}`;

/** Ends the hold and forgets the records (every exit of a transition). */
function endHold(): void {
  setTransitionToken(null);
  getTypingCollector().reset();
}

/**
 * Bridge target for `window.FinalFinal.beginTransition()` (TransBegin + TransLiveRead). ONE synchronous turn: flushes the 100 ms detection
 * debounce, drains the pending batch, starts the collector with a token drawn from the press counter, and sets the token, from which
 * moment the polls' pushes are held (undo-coordinator.ts `isTypingPushHeld`). Refuses, holding nothing, when there is no editor or a
 * Cmd-Z press is latched (the two cannot coexist; Swift then takes today's path for this one transition). A token a previous transition
 * never ended (Swift's call threw) is ended first, so its hold cannot outlive it.
 */
export function beginTransition(): TransitionBeginResult {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return { ok: false, reason: 'noEditor' };
  if (isLatched()) return { ok: false, reason: 'pressLatched' };
  const stale = getTransitionToken();
  if (stale !== null) {
    trace(`transition begin: a stale token ${stale} is ended first`);
    endHold();
  }
  try {
    flushPendingBlockChanges(); // the keys of the last 100 ms are pending changes now
    const batch = getBlockChanges(); // drained: the live editor's own changes, the one batch Swift writes before the barrier
    const token = allocatePressNumber();
    getTypingCollector().startPress(token, getAllBlockIds()); // TransCarryWindow opens
    setTransitionToken(token); // the hold: pend' = {}
    trace(`transition begin token=${token} batch ${sizeOf(batch)}`);
    return { ok: true, token, batch };
  } catch (e) {
    endHold();
    const message = e instanceof Error ? e.message : String(e);
    trace(`transition begin failed: ${message.slice(0, 200)}`);
    return { ok: false, reason: `exception: ${message}`.slice(0, 200) };
  }
}

/**
 * Bridge target for `window.FinalFinal.endTransition(token)`: the failure paths of the Swift side (the barrier timed out, the swap call
 * threw before the page could answer). Ends the hold and forgets the records; the typing held meanwhile is still in block-sync's own
 * pending queue, so the next poll sends it as an ordinary batch (`'send'`). Returns whether a hold for `token` was ended.
 */
export function endTransition(token: number | null): { ended: boolean } {
  // `null`: Swift could not read the begin's reply (the bridge threw), so it does not know the token; whatever hold is on is ended.
  const live = getTransitionToken();
  if (live === null || (token !== null && live !== token)) return { ended: false };
  endHold();
  trace(`transition end token=${live} mode=send`);
  return { ended: true };
}

export type TransitionTakeResult =
  | {
      ok: true;
      /** The changes typed since the begin (or the previous take), drained: Swift writes them through the queue. */
      batch: BlockChanges;
      /** The caret as a Markdown line and column (`getCursorPosition`), only when the batch is not empty (it serialises the document). */
      cursor: { line: number; column: number } | null;
    }
  | { ok: false; reason: string };

/**
 * Phase 5 job A9 (the Rich Text -> Markdown switch; a9-notes.md): drains what was typed since the begin (or the last take) WITHOUT
 * ending the hold. The outgoing page stays on screen and typeable until the incoming Markdown page has its text (TransTwoPage); this is
 * the carry of TransSwap: Swift writes the batch through the queue, re-reads the rows and hands the incoming page the difference. The
 * last take (the catch-up) comes after the outgoing page has left the window, then `endTransition(token)` ends the hold.
 */
export function takeTransitionBatch(
  token: number,
  cursorOf: () => { line: number; column: number }
): TransitionTakeResult {
  if (getTransitionToken() !== token) return { ok: false, reason: 'staleToken' };
  if (!getEditorInstance()) return { ok: false, reason: 'noEditor' };
  try {
    flushPendingBlockChanges();
    const batch = getBlockChanges();
    const empty = batch.updates.length === 0 && batch.inserts.length === 0 && batch.deletes.length === 0;
    const cursor = empty ? null : cursorOf();
    trace(`transition take token=${token} batch ${sizeOf(batch)}`);
    return { ok: true, batch, cursor: cursor ? { line: cursor.line, column: cursor.column } : null };
  } catch (e) {
    return { ok: false, reason: `exception: ${e instanceof Error ? e.message : String(e)}`.slice(0, 200) };
  }
}

/** The top-level block id at the start of the live document, if it has one. */
function firstTopLevelId(): string | undefined {
  return getAllBlockIds().get(0);
}

/** The part of `pending` whose blocks the target does not hold: typing outside the zoomed range. An insert is in range when the
 * block it follows (or the document's first block, for an insert at the start) is in the target: it is then recreated by the replay. */
function outsideOf(pending: BlockChanges, targetIds: ReadonlySet<string>): BlockChanges {
  const first = firstTopLevelId() ?? '';
  return {
    updates: pending.updates.filter((update) => !targetIds.has(update.id)),
    inserts: pending.inserts.filter((insert) => !targetIds.has(insert.afterBlockId ?? first)),
    deletes: pending.deletes.filter((id) => !targetIds.has(id)),
  };
}

/** The top-level nodes from the zoom-notes marker on (a zoomed chapter's mini-Notes), or null when the document has no marker. */
function zoomNotesTail(doc: ProsemirrorNode): ProsemirrorNode[] | null {
  const nodes: ProsemirrorNode[] = [];
  let seen = false;
  doc.forEach((node) => {
    if (node.type.name === 'zoom_notes_marker') seen = true;
    if (seen) nodes.push(node);
  });
  return seen ? nodes : null;
}

/** True when the mini-Notes of `after` differ from those of `before`. Their blocks carry no ids (block-sync does not report them; Swift
 * writes them back from the text, `syncMiniNotesBackPublic`), so typing there cannot be carried by id: the swap refuses and Swift's
 * catch-up reads the page's text, which then holds that typing. */
function zoomNotesChanged(before: ProsemirrorNode, after: ProsemirrorNode): boolean {
  const a = zoomNotesTail(before);
  const b = zoomNotesTail(after);
  if (a === null || b === null) return a !== b;
  return a.length !== b.length || a.some((node, index) => !node.eq(b[index]));
}

/** The figure-metadata pass of `setContentWithBlockIds`: width, caption and block id onto each figure node, positionally. */
function applyImageMeta(view: EditorView, imageMeta: ImageBlockMeta[] | undefined): void {
  if (!imageMeta || imageMeta.length === 0) return;
  let figureIdx = 0;
  let metaTr = view.state.tr;
  view.state.doc.forEach((node, pos) => {
    if (node.type.name === 'figure' && figureIdx < imageMeta.length) {
      const meta = imageMeta[figureIdx];
      metaTr = metaTr.setNodeMarkup(pos, undefined, {
        ...node.attrs,
        caption: meta.caption || '',
        width: meta.width ?? node.attrs.width ?? null,
        blockId: meta.id,
      });
      figureIdx++;
    }
  });
  if (metaTr.steps.length > 0) view.dispatch(metaTr.setMeta('addToHistory', false));
}

/** What the put-back restores after a replace that could not be completed. */
interface PutBack {
  state: EditorState;
  ids: Map<number, string>;
  types: Map<number, string>;
  managed: Set<string>;
  zoomMode: boolean;
}

/** The live state, the ids, the managed set, the zoom-mode flag and the block-sync baseline, exactly as api-structural-swap.ts puts
 * them back: the document is the user's again, with everything typed since the begin. */
function putBack(view: EditorView, saved: PutBack): void {
  try {
    view.updateState(saved.state);
    rebindCurrentStateFromView(view);
    restoreBlockIdMaps(saved.ids, saved.types);
    setManagedBlockIds(saved.managed);
    setBlockIdZoomMode(saved.zoomMode);
    resetAndSnapshot(view.state.doc);
    pointPluginStateAtLiveIds(view.state);
    view.dispatch(view.state.tr); // repaint the ids that were put back
  } catch (e) {
    trace(`transition swap: could not put the live state back: ${String(e).slice(0, 200)}`);
  }
  setSyncPaused(false);
  setIsSettingContent(false);
}

/**
 * Bridge target for `window.FinalFinal.swapTransition(token, options)` (TransPushFrom + TransReplay). ONE synchronous turn, in order:
 *   (1) the records since the begin (`inspectPress`): `matched` (nothing typed), `typing` (the typing, with any automatic change commuted
 *       into the base), or `changed` (a refusal before anything is touched);
 *   (2) the target is parsed and its ids placed as `setBlockIdsForTopLevel` will place them;
 *   (3) the typed steps are rebased onto the parsed target by block id, purely, BEFORE the live document is touched: a step in a block
 *       the target lacks is dropped here (it is outside the zoomed range and reaches the rows as `outside`), a step that spans the
 *       range's edge refuses;
 *   (4) block-sync's pending diff is drained: the part of it in blocks the target lacks is `outside`; the rest is carried by the replay;
 *   (5) the replace, the ids, the managed ids, the image metadata and the repaint, as `setContentWithBlockIds` does them;
 *   (6) block-sync is re-baselined on the new document SYNCHRONOUSLY and resumed (the one-turn rule);
 *   (7) the replay is built on the live state (`buildReplayDryRun`, plugins contained) and dispatched: one history step per press
 *       segment, the live selection mapped through the rebase, tagged `typingReplay` (the collector does not record it); block-sync
 *       sees it as new typing and the 50 ms content push carries the replayed text to Swift;
 *   (8) the hold ends, the paint signal goes out as today's push sends it.
 * On any failure after (5) the live state is put back (`putBack`) and the reply refuses with the batch drained at (4).
 */
export function swapTransition(token: number, options: SwapTransitionOptions): SwapTransitionResult {
  const began = performance.now();
  // `taken` is the pending diff once it has been drained (step 4): a refusal after that returns it, never a fresh drain (the replace
  // re-baselines block-sync, so a fresh drain after it would be empty and the typing lost from the batch).
  let taken: BlockChanges | null = null;
  const refuse = (reason: string): SwapTransitionRefused => {
    let batch = taken;
    if (batch === null) {
      flushPendingBlockChanges();
      batch = getBlockChanges();
    }
    endHold();
    trace(`transition swap token=${token} ok=false reason=${reason.slice(0, 200)} batch ${sizeOf(batch)}`);
    return { ok: false, refused: true, reason, batch };
  };

  if (getTransitionToken() !== token) {
    trace(`transition swap: token ${token} is not the transition in progress (${String(getTransitionToken())})`);
    return { ok: false, refused: true, reason: 'staleToken', batch: emptyBatch() };
  }
  const editorInstance = getEditorInstance();
  if (!editorInstance) return refuse('noEditor');
  const view = editorInstance.ctx.get(editorViewCtx);
  const parser = editorInstance.ctx.get(parserCtx);
  const collector = getTypingCollector();
  if (!collector.isRecording) return refuse('collectorReset');

  // (1)
  let inspection: PressInspection;
  try {
    inspection = inspectPress(collector, token, view.state.doc);
  } catch (e) {
    return refuse(`inspect: ${String(e).slice(0, 160)}`);
  }
  if (inspection.kind === 'changed') return refuse('changed');
  if (inspection.kind === 'typing' && zoomNotesChanged(inspection.docAtPress, view.state.doc))
    return refuse('zoomNotesTyped');

  // (2)
  let doc: ProsemirrorNode | null = null;
  try {
    doc = parser(options.markdown) ?? null;
  } catch (e) {
    return refuse(`parse: ${String(e).slice(0, 160)}`);
  }
  if (!doc) return refuse('parse');
  const targetIds = idsByOffsetFromPayload(doc, options.blockIds, options.expected ?? []);

  // (3) Ids Swift confirmed during the barrier (the begin's own inserts) are one block under both names.
  const confirms = getTransitionConfirms();
  const canonical = (id: string): string => confirms.get(id) ?? id;
  const idsAtPress =
    inspection.kind === 'typing' ? idsOfDocumentAtPress(collector, token, view.state.doc, getAllBlockIds()) : new Map();
  if (inspection.kind === 'typing') {
    const check = rebaseTypingSteps({
      steps: inspection.typing,
      docAtPress: inspection.docAtPress,
      idsAtPress,
      targetDoc: doc,
      targetIds,
      canonical,
      ghostsForGoneBlocks: false,
      pairUnmatched: false,
      carriedTextFirst: options.carriedTextFirst === true,
    });
    if (!check.ok) return refuse(`unplaceable: ${check.reason ?? ''}`);
  }

  // (4)
  flushPendingBlockChanges();
  taken = getBlockChanges();
  const outside = outsideOf(taken, new Set(targetIds.values()));

  // (5): from here a failure puts the live state back.
  const saved: PutBack = {
    state: view.state,
    ids: getAllBlockIds(),
    types: getAllBlockTypes(),
    managed: getManagedBlockIds(),
    zoomMode: getBlockIdZoomMode(),
  };
  let replayed = 0;
  let dropped = 0;
  try {
    clearContentPushTimer();
    noteTypewriterContentLoad();
    setBlockIdZoomMode(options.zoomMode ?? false);
    setContentHasBeenSet(true);
    setIsSettingContent(true);
    setSyncPaused(true);
    const { from } = view.state.selection;
    const scrollAnchor = options.scrollToStart
      ? undefined
      : { x: window.scrollX, y: window.scrollY, domTop: view.dom.scrollTop };
    let tr = buildBlockLevelReplace(view.state.tr, view.state.doc, doc);
    if (options.scrollToStart) {
      tr = tr.setSelection(Selection.atStart(tr.doc));
    } else {
      const safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));
      try {
        tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
      } catch {
        tr = tr.setSelection(Selection.atStart(tr.doc));
      }
    }
    view.dispatch(tr.setMeta('addToHistory', false));
    clearBlockIds();
    if (options.blockIds.length > 0) setBlockIdsForTopLevel(options.blockIds, view.state.doc, options.expected);
    setManagedBlockIds(options.managedBlockIds ?? []);
    redecorateBlockIds(view);
    applyImageMeta(view, options.imageMeta);
    syncFigureBlockIdAttrs(view);
    let paintAnchor = scrollAnchor;
    const targetTop =
      !options.scrollToStart && options.scrollToBlockId ? blockScrollTargetTop(view, options.scrollToBlockId) : null;
    if (targetTop !== null) {
      window.scrollTo({ top: targetTop, left: window.scrollX, behavior: 'instant' });
      paintAnchor = { x: window.scrollX, y: window.scrollY, domTop: view.dom.scrollTop };
    }
    afterReplaceHook?.();

    // (6) synchronous, where setContentWithBlockIds defers to the next animation frame: a key in that frame would be swallowed.
    resetAndSnapshot(view.state.doc);
    setSyncPaused(false);
    setIsSettingContent(false);

    // (7)
    if (inspection.kind === 'typing') {
      const dry = buildReplayDryRun(view.state, {
        steps: inspection.typing,
        docAtPress: inspection.docAtPress,
        idsAtPress,
        targetIds: new Map(getAllBlockIds()),
        canonical,
        liveSelection: saved.state.selection,
        syncPausedAfter: false,
        liveState: view.state,
        ghostsForGoneBlocks: false,
        pairUnmatched: false,
        carriedTextFirst: options.carriedTextFirst === true,
      });
      if (!dry.ok) throw new Error(`replay: ${dry.reason ?? ''}`);
      for (const replayTr of dry.replayTrs) view.dispatch(replayTr);
      if (dry.dryState && !view.state.doc.eq(dry.dryState.doc)) {
        throw new Error('the replay did not produce the document the dry run built');
      }
      replayed = dry.rebased.length;
      dropped = Math.max(0, inspection.typing.length - replayed);
    }

    // (8)
    endHold();
    setCurrentContent(options.markdown);
    signalPaintComplete(view.dom, {}, { restoreScroll: paintAnchor });
    trace(
      `transition swap token=${token} ok=true blocks=${options.blockIds.length} replayed=${replayed} dropped=${dropped} ` +
        `outside ${sizeOf(outside)} jsMs=${Math.round(performance.now() - began)}`
    );
    return { ok: true, replayed, dropped, outside };
  } catch (e) {
    putBack(view, saved);
    const message = e instanceof Error ? e.message : String(e);
    return refuse(`exception: ${message}`.slice(0, 200));
  }
}
