// Unified chronological undo -- JS routing module for Milkdown.
// Mirrored (not shared) in web/codemirror/src/undo-coordinator.ts -- see that file's header
// for why this is two near-identical files rather than one shared module.
//
// Phase 2 skeleton (docs/plans/patient-rewinding-clockwork.md §4.1/§4.2/§4.6/§4.7): builds
// the registry, descriptor, routing decision, in-flight latch, and historyEdited predicate
// with ZERO real structural entries ever recorded. `descriptor.undoTopOpId`/`redoTopOpId`
// never exist in this phase, so every routing decision below falls through to Milkdown's own
// text undo/redo (prosemirror-history) unchanged -- this module adds no user-visible
// behavior yet. Phase 3+ starts calling `setUndoDescriptor()`/populating the registry from
// real structural operations (version restore, section delete/duplicate).

import { editorViewCtx } from '@milkdown/kit/core';
import { closeHistory, isHistoryTransaction, redo, redoDepth, undo, undoDepth } from '@milkdown/kit/prose/history';
import type { Node } from '@milkdown/kit/prose/model';
import type { EditorState, Transaction } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { getContent } from './api-content';
import { clearBlockIds } from './block-id-plugin';
import {
  hasUnsettledLocalEdit,
  rebindCurrentStateFromView,
  resetAndSnapshot,
  setSyncPaused,
} from './block-sync-plugin';
import { resetCAYWState } from './cayw';
import { getEditorInstance, setCurrentContent } from './editor-state';
import { consumePendingDropPos, consumePendingPastePos } from './image-plugin';

// === Types (plan §4.1) ===

/** One registered structural op's editor-side inverse material. Nothing constructs one of
 * these until Phase 3 -- the type is defined now per the plan so Phase 3 only has to
 * populate the registry, not design its shape. */
export interface UndoRegistryEntry {
  /** Full EditorState captured at op time (pre-op) -- swapped in wholesale on structural
   * undo (checkpoint-swap, plan §4.3). */
  checkpoint: EditorState;
  /** Full EditorState captured at UNDO time (plan §4.4 undo step 2) -- the post-op state as
   * it stood the moment undo fired. Swapped in wholesale on structural REDO. Absent until
   * this entry has actually been undone once (mirrors StructuralEntry.redoSnapshotId on the
   * Swift side). */
  redoCheckpoint?: EditorState;
  /** Document immediately after the op -- the equality target for structural undo (§4.2). */
  postOpDoc: Node;
  /** Document immediately before the op -- the equality target for structural redo. */
  preOpDoc: Node;
}

/** Swift-pushed pointer to the top of each stack (plan §4.1). `{}` (both fields absent) is
 * Phase 2's permanent state -- nothing ever calls `setUndoDescriptor`. */
export interface UndoDescriptor {
  undoTopOpId?: string;
  redoTopOpId?: string;
}

export type RoutingDecision =
  | { action: 'structural'; opId: string }
  | { action: 'fallthrough' }
  // In-flight latch held (plan §4.7 H7): drop the keystroke entirely, don't even fall
  // through to the editor's own undo -- a second Cmd-Z while a structural undo is settling
  // must not interleave with it.
  | { action: 'swallow' };

// === Module state ===

const registry = new Map<string, UndoRegistryEntry>();
let descriptor: UndoDescriptor = {};
let latched = false;
/** Belt-and-braces timeout for the latch (review round, promoted from the Phase 2 DEFERRED
 * note above): if Swift's reply is ever lost -- a multi-window mismatch bailing without a
 * reply, a torn-down WebView, a crash mid-sequence -- this self-clears the latch instead of
 * leaving every future Cmd-Z/Cmd-Shift-Z silently swallowed for the rest of the session.
 * 3s is comfortably longer than the audited sequence's real-world duration budget in the
 * common case, short enough that a genuine loss recovers within one user-visible pause. */
const LATCH_TIMEOUT_MS = 3000;
let latchTimeoutId: ReturnType<typeof setTimeout> | null = null;

export function getRegistry(): Map<string, UndoRegistryEntry> {
  return registry;
}
export function setRegistryEntry(opId: string, entry: UndoRegistryEntry): void {
  registry.set(opId, entry);
}
export function deleteRegistryEntry(opId: string): void {
  registry.delete(opId);
}
export function clearRegistry(): void {
  registry.clear();
}
export function getUndoDescriptor(): UndoDescriptor {
  return descriptor;
}
/** Bridge target for window.FinalFinal.setUndoDescriptor -- called by Swift on every
 * timeline change (record/undo/redo/barrier). Never called in Phase 2: no Swift call site
 * changes UnifiedUndoService's stacks yet. */
export function setUndoDescriptor(next: UndoDescriptor): void {
  descriptor = next;
}
export function isLatched(): boolean {
  return latched;
}
export function setLatched(value: boolean): void {
  latched = value;
}

/** Test-only full reset, mirroring resetBlockIdState()/resetBlockSyncState() elsewhere in
 * this codebase's test suites. Not part of the window.FinalFinal bridge. */
export function resetUndoCoordinatorState(): void {
  registry.clear();
  descriptor = {};
  latched = false;
  clearLatchTimeout();
}

// === Pure routing decision (plan §4.2) ===
// Generic over the doc type so the routing truth-table tests can run against fake
// registries/comparators with no real editor -- the live wrappers below plug in
// ProseMirror's real Node.eq and the real registry/descriptor/latch module state.

export interface RoutingParams<TDoc> {
  descriptor: UndoDescriptor;
  registry: ReadonlyMap<string, { postOpDoc: TDoc; preOpDoc: TDoc }>;
  /** "blockSync pending-change maps are empty" (§4.2) -- closes the unflushed-delta race. */
  pendingMapsEmpty: boolean;
  latched: boolean;
  currentDoc: TDoc;
  docsEqual: (a: TDoc, b: TDoc) => boolean;
}

function decideRouting<TDoc>(params: RoutingParams<TDoc>, direction: 'undo' | 'redo'): RoutingDecision {
  if (params.latched) return { action: 'swallow' };

  const opId = direction === 'undo' ? params.descriptor.undoTopOpId : params.descriptor.redoTopOpId;
  if (opId === undefined) return { action: 'fallthrough' };

  const entry = params.registry.get(opId);
  if (!entry) return { action: 'fallthrough' };

  if (!params.pendingMapsEmpty) return { action: 'fallthrough' };

  const target = direction === 'undo' ? entry.postOpDoc : entry.preOpDoc;
  if (!params.docsEqual(params.currentDoc, target)) return { action: 'fallthrough' };

  return { action: 'structural', opId };
}

export function decideUndoRouting<TDoc>(params: RoutingParams<TDoc>): RoutingDecision {
  return decideRouting(params, 'undo');
}
export function decideRedoRouting<TDoc>(params: RoutingParams<TDoc>): RoutingDecision {
  return decideRouting(params, 'redo');
}

// === Live wiring ===

function docsEqual(a: Node, b: Node): boolean {
  return a.eq(b);
}

/**
 * "blockSync pending-change maps are empty" (§4.2) -- closes the unflushed-delta race.
 *
 * Originally read `hasPendingChanges()` (block-sync-plugin's committed
 * pendingUpdates/pendingInserts/pendingDeletes maps directly), but those maps are only
 * CLEARED once Swift's poll drains them via `getBlockChanges()` -- BlockSyncService's
 * fixed 2.0s cadence -- not synchronously when a text edit settles. A redo/undo pressed
 * roughly 100ms-2000ms after a preceding text edit could see a STALE "non-empty"
 * reading purely because Swift hadn't polled yet, even though the document itself
 * already matched the routing target (`docsEqual` below) -- silently falling through
 * to a text-redo no-op instead of firing the structural redo (confirmed via live e2e
 * testing; see notes.md 2026-08-17/18 for the reproduction).
 *
 * Fixed to key off block-sync's own LOCAL 100ms debounce settling
 * (`hasUnsettledLocalEdit()`) instead of Swift's poll cadence: true only in the narrow
 * window between a docChanged transaction landing and its diff being computed, which
 * settles independent of when Swift next polls. `StructuralUndoController.swift`'s
 * `performUndo`/`performRedo` now also flush live content to the DB unconditionally
 * (mirroring the forward op's H6 mode-aware flush) before snapshotting, so DB accuracy
 * no longer depends on this check either -- this is now purely about not swapping out
 * from under an edit block-sync hasn't even diffed yet.
 */
function pendingMapsEmpty(): boolean {
  return !hasUnsettledLocalEdit();
}

function liveRoutingParams(view: EditorView): RoutingParams<Node> {
  return {
    descriptor,
    registry,
    pendingMapsEmpty: pendingMapsEmpty(),
    latched,
    currentDoc: view.state.doc,
    docsEqual,
  };
}

/** True when the editor's own text undo/redo has nothing to do -- the trigger condition for
 * the plan §4.2 refusal beep (a Cmd-Z that would otherwise be a silent no-op). */
function hasNoTextHistory(view: EditorView, direction: 'undo' | 'redo'): boolean {
  return direction === 'undo' ? undoDepth(view.state) === 0 : redoDepth(view.state) === 0;
}

/** Refusal UX (plan §4.2, "specified -- review found it merely asserted"): a fallthrough
 * decision with nothing left in the editor's own text history either means Cmd-Z would
 * otherwise be a silent no-op. Beep instead, via the same safe-optional-chaining postMessage
 * pattern as every other Swift bridge call in this module -- a no-op until Phase 3+ registers
 * the handler, which this phase does. */
function maybeBeepOnRefusal(view: EditorView, direction: 'undo' | 'redo'): void {
  if (!hasNoTextHistory(view, direction)) return;
  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'debug',
    message: `[undo-coordinator] refusal beep: no structural entry and no text ${direction} available`,
  });
  (window as any).webkit?.messageHandlers?.structuralUndoRefused?.postMessage({ direction });
}

// === Structural op lifecycle (plan §4.4) ===
// Called by Swift, via window.FinalFinal, at the audited op-sequence and undo-sequence
// boundaries. Every function here is a thin, synchronous wrapper the Swift-side controller
// orchestrates between its own async DB/JS steps -- see StructuralUndoController.swift.

/** Op-sequence step 1 (partial) + step 3: cancel pending async insertions (CAYW picker
 * requests, image paste/drop positions) that could otherwise silently apply against content
 * a structural op or undo/redo is about to replace out from under them. */
export function cancelPendingInsertions(): void {
  resetCAYWState();
  consumePendingDropPos();
  consumePendingPastePos();
}

/** Op-sequence step 3: close the current history group (H3 -- prevents this op's boundary
 * merging into an adjacent typing group) and capture the pre-op checkpoint + preOpDoc into
 * the registry. `postOpDoc` starts equal to `preOpDoc` as a placeholder;
 * `finalizeStructuralOpPostOpDoc` overwrites it once the op's content push has landed. */
export function beginStructuralOp(opId: string): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  const view = editorInstance.ctx.get(editorViewCtx);
  view.dispatch(closeHistory(view.state.tr));
  const preOpDoc = view.state.doc;
  setRegistryEntry(opId, { checkpoint: view.state, postOpDoc: preOpDoc, preOpDoc });
  return true;
}

/** Op-sequence step 6/7: capture `postOpDoc` from the push transaction's own doc -- i.e. the
 * live doc at the moment this is called, which Swift calls immediately after its own content
 * push (`setContentWithBlockIds`) resolves. Per plan §4.4 step 6, this deliberately does NOT
 * wait for RAF-time normalization transactions to settle first; `maybeAdvanceRegistryOnSyncOriginTx`
 * (§4.6, below -- wired into the `view.dispatch` override in main.ts alongside
 * `maybeNotifyHistoryEdited`) is what actually absorbs any sync-origin transaction that lands
 * after this call, including RAF-time normalization and derived-content resyncs: it advances
 * this entry's `postOpDoc`/`preOpDoc` reference forward whenever the doc immediately before
 * such a transaction structurally matches one of them. */
export function finalizeStructuralOpPostOpDoc(opId: string): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  const entry = registry.get(opId);
  if (!entry) return false;
  const view = editorInstance.ctx.get(editorViewCtx);
  registry.set(opId, { ...entry, postOpDoc: view.state.doc });
  return true;
}

/**
 * §4.6 derived-content advancement rule (plan §4.6, H5): when a sync-origin transaction lands
 * (`addToHistory:false` -- the established provenance marker), for each registry entry, if the
 * doc BEFORE this transaction (`tr.before`) structurally equals the entry's `postOpDoc` or
 * `preOpDoc` reference, advance that reference to the doc AFTER this transaction (`tr.doc`).
 * This is what keeps a structural entry's equality target (§4.2) tracking harmless
 * derived-content churn -- a delayed bibliography fetch, an async footnote renumber, a
 * block-ID push -- that lands after the entry was captured, instead of permanently bricking
 * the entry's equality check the moment such a resync fires after the op (H5).
 *
 * Deliberately disjoint from `maybeNotifyHistoryEdited`'s trigger condition (that one requires
 * `addToHistory !== false`; this one requires `=== false`), so call order relative to it in the
 * dispatch pipeline doesn't matter -- a transaction can only ever satisfy one of the two.
 * Costs one property read (`registry.size === 0`) per transaction in the common case (no
 * structural entries recorded yet), matching constraint 3 (no per-keystroke cost) -- the same
 * short-circuit shape as `maybeNotifyHistoryEdited`'s own descriptor check.
 */
export function maybeAdvanceRegistryOnSyncOriginTx(tr: Transaction): void {
  if (registry.size === 0) return;
  if (tr.getMeta('addToHistory') !== false) return;
  if (!tr.docChanged) return;
  const before = tr.before;
  const after = tr.doc;
  for (const [opId, entry] of registry) {
    // Mid-op entry: postOpDoc is still beginStructuralOp's placeholder (the SAME object as
    // preOpDoc), so the op's OWN content push has tr.before === preOpDoc. Advancing here drags
    // the redo equality target (§4.2/§4.6) forward onto the post-op doc, making structural redo
    // unroutable for the entry's whole lifetime. finalizeStructuralOpPostOpDoc re-arms it.
    if (entry.postOpDoc === entry.preOpDoc) continue;
    const advancesPost = entry.postOpDoc.eq(before);
    const advancesPre = entry.preOpDoc.eq(before);
    if (!advancesPost && !advancesPre) continue;
    registry.set(opId, {
      ...entry,
      postOpDoc: advancesPost ? after : entry.postOpDoc,
      preOpDoc: advancesPre ? after : entry.preOpDoc,
    });
  }
}

/** Undo-sequence step 2: capture the redo checkpoint (the post-op EditorState, as it stands
 * the moment undo fires) into the registry BEFORE the swap below moves the live view away
 * from it. Routing (§4.2) already guaranteed `currentDoc.eq(entry.postOpDoc)` before this is
 * reachable, so "the state right now" IS the correct redo target. */
function captureRedoCheckpoint(opId: string, view: EditorView): void {
  const entry = registry.get(opId);
  if (!entry) return;
  registry.set(opId, { ...entry, redoCheckpoint: view.state });
}

/**
 * Undo/redo-sequence checkpoint swap (plan §4.4 undo step 3a). Wraps the wholesale
 * `updateState()` swap with every step the plan's three-review round found load-bearing:
 * pause block-sync change detection for the whole swap, swap state, re-point the block-sync
 * module's `currentState` pointer at the swapped-in view (otherwise it keeps pointing at the
 * pre-swap plugin-state object and silently drops the first post-swap edit), and clear stale
 * block IDs so Swift's follow-up `pushBlockIds()` starts from a clean slate. Does NOT resume
 * sync (`setSyncPaused(false)`) or rebaseline (`resetAndSnapshot`) here -- those must wait
 * until AFTER Swift's block-ID push completes (undo step 3a's "only after the ID round-trip
 * completes"), so the Swift-side controller calls `finishStructuralSwapSettle` separately
 * once that round-trip is done.
 *
 * `direction: 'undo'` swaps to `entry.checkpoint` (pre-op state) and captures the redo
 * checkpoint first. `direction: 'redo'` swaps to `entry.redoCheckpoint` (post-op state as it
 * stood at undo time); returns false if that's missing (redo requested without a prior undo
 * of this entry -- should be structurally unreachable via routing, defense in depth only).
 */
export function performStructuralSwap(opId: string, direction: 'undo' | 'redo'): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  const view = editorInstance.ctx.get(editorViewCtx);

  if (direction === 'undo') {
    captureRedoCheckpoint(opId, view);
  }
  const entry = registry.get(opId);
  const target = direction === 'undo' ? entry?.checkpoint : entry?.redoCheckpoint;
  if (!entry || !target) return false;

  setSyncPaused(true);
  view.updateState(target);
  rebindCurrentStateFromView(view);
  clearBlockIds();
  return true;
}

/** Undo/redo-sequence tail of the swap: called by Swift once its follow-up `pushBlockIds()`
 * round-trip has landed real DB block ids onto the swapped-in doc. Rebaselines block-sync's
 * snapshot from the NOW-correct doc+ids and only then resumes change detection -- resuming
 * before this would let the very first post-swap poll see every block as a fresh
 * insert/delete pair against the stale pre-swap snapshot. */
export function finishStructuralSwapSettle(): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  const view = editorInstance.ctx.get(editorViewCtx);
  resetAndSnapshot(view.state.doc);
  setSyncPaused(false);
  // Content-mirror sync (plan §4.4 undo step 3c, the exact BLOCKER hazard documented at
  // ContentView+ContentRebuilding.swift:462-467): the JS-side `currentContent` cache is a
  // stale pre-swap value until refreshed here -- left stale, a later stray read of it (e.g.
  // main.ts's init race-condition check) would see the wrong document.
  setCurrentContent(getContent());
  return true;
}

/** Clears the pending latch-timeout timer, if any. Called both when a real reply arrives
 * (the timeout is now moot) and when a fresh request is about to schedule a new one (an
 * old timer must never fire against a newer request's latch). */
function clearLatchTimeout(): void {
  if (latchTimeoutId !== null) {
    clearTimeout(latchTimeoutId);
    latchTimeoutId = null;
  }
}

function requestStructural(opId: string, direction: 'undo' | 'redo'): void {
  latched = true;
  clearLatchTimeout();
  latchTimeoutId = setTimeout(() => {
    latchTimeoutId = null;
    if (!latched) return;
    latched = false;
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[undo-coordinator] latch timeout: no reply from Swift for ${direction} opId=${opId} -- self-clearing`,
    });
  }, LATCH_TIMEOUT_MS);
  const messageName = direction === 'undo' ? 'structuralUndoRequested' : 'structuralRedoRequested';
  // Safe no-op if Swift hasn't registered this handler yet (Phase 3+ wires it) -- same
  // optional-chaining pattern as every other Swift bridge postMessage call in this codebase
  // (e.g. contentChanged in main.ts).
  (window as any).webkit?.messageHandlers?.[messageName]?.postMessage({ opId });
}

/**
 * Capture-phase keydown entry point. Called from the merged handler in slash-commands.ts
 * (NOT a second independently-registered listener -- see that file for why). Returns true
 * if the event was consumed (structurally routed, or swallowed by the latch); the caller
 * must preventDefault/stopPropagation itself in that case (already done here) and must NOT
 * do so when this returns false -- false means "let it bubble to Milkdown's own keymap".
 */
export function handleUnifiedUndoKeydown(e: KeyboardEvent, view: EditorView, direction: 'undo' | 'redo'): boolean {
  const decision =
    direction === 'undo' ? decideUndoRouting(liveRoutingParams(view)) : decideRedoRouting(liveRoutingParams(view));

  if (decision.action === 'fallthrough') {
    // Refusal UX (plan §4.2): about to hand this back to Milkdown's own keymap, which will
    // itself be a silent no-op if there's no text history either -- beep now so the user
    // gets feedback instead of nothing happening at all.
    maybeBeepOnRefusal(view, direction);
    return false;
  }

  e.preventDefault();
  e.stopPropagation();

  if (decision.action === 'swallow') return true;

  requestStructural(decision.opId, direction);
  return true;
}

/**
 * Top-level Cmd-Z/Cmd-Shift-Z/Cmd-Y dispatch: normalizes the key comparison and delegates to
 * handleUnifiedUndoKeydown. `KeyboardEvent.key` for Shift+Z is the uppercase `'Z'`, not
 * lowercase `'z'` with `shiftKey` interpreted separately -- comparing `e.key === 'z'` directly
 * (as an earlier revision did here) silently makes the redo branch unreachable whenever Shift
 * is actually held (review finding, round 1 must-fix). Harmless in Phase 2 (everything falls
 * through to the editor's own keymap regardless), but would have silently broken structural
 * redo the moment Phase 3 wires real ops. Call this from the capture-phase listener in
 * slash-commands.ts instead of comparing `e.key` inline.
 */
export function handleGlobalUndoRedoKeydown(e: KeyboardEvent, view: EditorView): boolean {
  const key = e.key.toLowerCase();
  if (key === 'z' && (e.metaKey || e.ctrlKey)) {
    return handleUnifiedUndoKeydown(e, view, e.shiftKey ? 'redo' : 'undo');
  }
  if (key === 'y' && (e.metaKey || e.ctrlKey) && !e.shiftKey) {
    return handleUnifiedUndoKeydown(e, view, 'redo');
  }
  return false;
}

/**
 * Menu-path entry point (window.FinalFinal.requestUnifiedUndo/requestUnifiedRedo). Plan
 * §4.7: menu activation must run the SAME routing decision as the keyboard interceptor --
 * never a direct UnifiedUndoService.performUndo()/performRedo() call from Swift, which
 * would bypass the equality guard. Unlike the keydown path there is no native event to fall
 * through to, so the fallthrough case here directly invokes Milkdown's own undo/redo
 * command -- with the always-empty Phase 2 registry, this is the ONLY path ever taken, so
 * Undo/Redo menu clicks behave exactly as they would with no unified-undo wiring at all.
 *
 * DEFERRED (Phase 3, do not fix now): the fallthrough branch calls the plain `undo`/`redo`
 * commands directly, bypassing slash-commands.ts's smart-slash-undo two-step (which removes
 * both the slash command's result AND the "/" trigger on ONE Cmd-Z, but only runs from the
 * real keydown path). A menu-triggered Undo right after a slash command would therefore only
 * remove the command's result, leaving the "/" behind, unlike a keyboard Cmd-Z in the same
 * situation. Not fixed here -- didn't fall out for free while addressing the Swift-side
 * first-responder routing fix this phase's review round required.
 */
function requestUnified(direction: 'undo' | 'redo'): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  const view = editorInstance.ctx.get(editorViewCtx);

  const decision =
    direction === 'undo' ? decideUndoRouting(liveRoutingParams(view)) : decideRedoRouting(liveRoutingParams(view));

  if (decision.action === 'swallow') return; // in-flight -- drop, matches the keydown path

  if (decision.action === 'fallthrough') {
    maybeBeepOnRefusal(view, direction);
    if (direction === 'undo') undo(view.state, view.dispatch);
    else redo(view.state, view.dispatch);
    return;
  }

  requestStructural(decision.opId, direction);
}

export function requestUnifiedUndo(): void {
  requestUnified('undo');
}
export function requestUnifiedRedo(): void {
  requestUnified('redo');
}

/**
 * Swift's reply to a structuralUndoRequested/structuralRedoRequested message (plan §4.2):
 * "fallback" means Swift's top entry no longer matched the opId JS sent (a barrier raced
 * the keystroke) -- JS must perform the text undo/redo it suppressed when it preventDefault
 * -ed, never silently drop the keystroke. "performed" means Swift actually restored the
 * structural entry; Phase 3+ owns updating checkpoints/content on that path, nothing more
 * to do here. A reply that arrives while NOT latched (stale/duplicate) is ignored. Never
 * called in Phase 2 -- nothing ever sends the request this replies to.
 *
 * DEFERRED (Phase 3, do not fix now): this only checks whether the latch is currently held,
 * not whether `reply.opId` matches the specific request that set it -- a reply for a stale
 * request could be misapplied to a newer in-flight one if two requests are ever in flight in
 * quick succession. Harmless today (nothing ever calls requestStructural, so no reply is ever
 * possible), but Phase 3 should track and compare the in-flight opId explicitly.
 */
export function handleUndoReplyFromSwift(
  reply: { opId: string; outcome: 'performed' | 'fallback' | 'failed' },
  direction: 'undo' | 'redo'
): void {
  if (!latched) return;
  latched = false;
  clearLatchTimeout();
  if (reply.outcome === 'failed') {
    // Post-commit failure (plan review round MF-4): the DB has already been restored to a
    // new state, but a later step (the JS-side settle -- checkpoint-swap resume in WYSIWYG,
    // or the Source-mode content push) didn't complete. `fallback`'s handling below replays a
    // plain text-undo/redo on top of whatever's currently in the editor -- correct when
    // NOTHING has changed yet, but actively harmful here: it would apply an EXTRA edit on top
    // of a DB write that already landed, leaving DB/timeline/editor all disagreeing. Report
    // and stop -- do not touch editor content.
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[undo-coordinator] structural ${direction} failed post-commit (opId=${reply.opId}) -- NOT replaying a text ${direction} on top of an already-restored DB`,
    });
    return;
  }
  if (reply.outcome !== 'fallback') return;
  const view = getEditorInstance()?.ctx.get(editorViewCtx);
  if (!view) return;
  if (direction === 'undo') undo(view.state, view.dispatch);
  else redo(view.state, view.dispatch);
}

export function receiveUndoOutcome(opId: string, outcome: 'performed' | 'fallback' | 'failed'): void {
  handleUndoReplyFromSwift({ opId, outcome }, 'undo');
}
export function receiveRedoOutcome(opId: string, outcome: 'performed' | 'fallback' | 'failed'): void {
  handleUndoReplyFromSwift({ opId, outcome }, 'redo');
}

/**
 * §4.6 predicate, corrected per plan §4.1 (an earlier draft broke the canonical redo case):
 * fires only for transactions that ADD a NEW history item -- docChanged, not sync-origin
 * (addToHistory:false), not a history replay (prosemirror-history sets its own `historyKey`
 * meta on undo/redo-generated transactions; isHistoryTransaction() is its public detector).
 * Sent only while a structural redo entry exists, per constraint 3 (no per-keystroke cost):
 * the descriptor.redoTopOpId check is a single property read and runs before any of the
 * other (cheap, but not free) checks, so with Phase 2's permanently-empty descriptor this
 * function costs one property comparison per keystroke and nothing else.
 */
export function maybeNotifyHistoryEdited(tr: Transaction): void {
  if (descriptor.redoTopOpId === undefined) return;
  if (!tr.docChanged) return;
  if (tr.getMeta('addToHistory') === false) return;
  if (isHistoryTransaction(tr)) return;
  (window as any).webkit?.messageHandlers?.historyEdited?.postMessage({});
}
