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
import { commitAndCloseAnnotationEditPopup } from './annotation-edit-popup';
import { clearEditorHistory, getContent } from './api-content';
import { clearBlockIds } from './block-id-plugin';
import {
  hasUnsettledLocalEdit,
  rebindCurrentStateFromView,
  resetAndSnapshot,
  setSyncPaused,
} from './block-sync-plugin';
import { resetCAYWState } from './cayw';
import { commitAndCloseEditPopup } from './citation-edit-popup';
import { getEditorInstance, setCurrentContent } from './editor-state';
import { clearSearch } from './find-replace';
import { consumePendingDropPos, consumePendingPastePos } from './image-plugin';
import { hideLinkPopups } from './link-tooltip';

// Real user-transaction counter for the permanent `[UnifiedUndo]` fallthrough log below
// (undo-mode-switch-focus investigation legacy -- kept because it proved genuinely useful
// diagnostic signal, not because it's still under investigation). ProseMirror equivalent of
// the CodeMirror mirror's `Transaction.addToHistory` check -- `tr.getMeta('addToHistory')
// !== false` is the same "not explicitly marked sync-origin" idiom
// `maybeAdvanceRegistryOnSyncOriginTx` (below) already uses for the opposite check
// (`=== false`). Wired into the `view.dispatch` override in main.ts.
let userTxCount = 0;
export function noteUserTransaction(tr: Transaction): void {
  // P3 (undo-mode-switch-focus second timing gap): a `derivedCorrection`-tagged
  // transaction IS user-undoable (addToHistory !== false) by design, but it isn't a real
  // user keystroke -- exclude it so this diagnostic counter still means what its name says.
  if (tr.docChanged && tr.getMeta('addToHistory') !== false && !tr.getMeta('derivedCorrection')) {
    userTxCount += 1;
  }
}

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
/** N5 (minor, Phase B remediation plan): the opId of the specific in-flight request the
 * latch is currently held for. Previously the latch alone gated `handleUndoReplyFromSwift`
 * -- "harmless today" per a comment that predated Phase 3 (real ops) and was stale by the
 * time this was reviewed: with real structural entries, a stale/duplicate reply (a
 * multi-window mismatch's own late reply, a race between the latch timeout firing and a
 * genuine reply arriving) could be misapplied to a DIFFERENT request that happened to latch
 * afterward, purely because the latch was still (or newly) held. Set by `requestStructural`,
 * cleared whenever the latch itself clears (a real reply, the timeout, or a manual
 * `setLatched(false)` in tests). */
let inFlightOpId: string | null = null;
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

/** Barrier-only registry clear (plan §4.5/§5 backlog): clears the registry and resets the
 * descriptor to `{}` WITHOUT touching this editor's own text-undo history -- unlike
 * `clearStructuralUndoState()` (eviction, below), a barrier (zoom, project/mode switch, drag
 * reorder, hierarchy enforcement, annotation ops, section metadata edits) must NOT wipe
 * legitimate in-flight text-undo steps, only the now-invalid structural checkpoints/descriptor.
 * Correctness was already backstopped without this (a stale opId request gets `.fallback`,
 * plan §4.2), but leaving the registry populated is a per-session `EditorState` leak (every
 * checkpoint retains a full ProseMirror doc) and defeats the JS-side fast path (the descriptor
 * keeps claiming there's something to route). Bridge target for
 * `window.FinalFinal.clearStructuralUndoRegistry`, called by Swift from
 * `UnifiedUndoService.invalidateAll()`. */
export function clearStructuralUndoRegistry(): void {
  clearRegistry();
  setUndoDescriptor({});
}

/** Eviction mini-barrier (plan §4.1/§4.5): the oldest structural entry just fell off the undo
 * stack at capacity. Clears this editor's OWN text-undo history (`clearEditorHistory`, the
 * same double-reconfigure technique `resetForProjectSwitch()` already uses) AND removes just
 * that ONE evicted entry from the registry -- pre-boundary text steps must not stay reachable
 * past a boundary the timeline no longer guards against (H1 laundering / H2 rebase collapse).
 *
 * Takes the evicted entry's `opId` and calls `deleteRegistryEntry(opId)` (MF-1, Phase 5 review
 * round) -- NOT `clearStructuralUndoRegistry()`/`clearRegistry()`, which wipe every entry. This
 * used to be a whole-registry clear, but `record()` (`UnifiedUndoService.swift`) calls this
 * closure as the LAST step of `performStructuralOp` -- AFTER that same op's own registry entry
 * has already been created and finalized -- so a whole-registry clear here was wiping the
 * current op's own just-recorded entry too, breaking structural undo/redo the moment the stack
 * crossed capacity (op #51+). The descriptor is left untouched here: the caller
 * (`UnifiedUndoService.record()`) always calls `pushDescriptor()` right after this fires, which
 * refreshes it to the current top-of-stack pointers regardless. Bridge target for
 * `window.FinalFinal.clearStructuralUndoState`, called by Swift from
 * `UnifiedUndoService.record()`'s eviction path via `ContentView`'s `clearEditorHistories`
 * closure. */
export function clearStructuralUndoState(opId: string): void {
  const editorInstance = getEditorInstance();
  if (editorInstance) {
    const view = editorInstance.ctx.get(editorViewCtx);
    clearEditorHistory(view);
  }
  deleteRegistryEntry(opId);
}

/** N6 (minor, Phase B remediation plan): mid-sequence forward-op failure cleanup -- mirrors
 * CodeMirror's `undo-coordinator.ts` function of the same name. Removes just the ONE
 * in-flight op's own registry entry (created by `beginStructuralOp`, never finalized because
 * a later step in `performStructuralOp` failed) WITHOUT touching this editor's own
 * text-undo history (unlike `clearStructuralUndoState` above, which is eviction-only): the
 * op failed, but the user's prior typing history is still perfectly valid. Without this, a
 * failed forward op left the registry entry (a full retained ProseMirror `EditorState`)
 * permanently leaked -- keyed by a fresh opId every time, so never overwritten and never
 * referenced by the descriptor Swift pushes (a failed op is never `record()`-ed). */
export function clearFailedStructuralOpEntry(opId: string): void {
  deleteRegistryEntry(opId);
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
/** Test-only accessor/setter for the in-flight opId (N5). Not part of the window.FinalFinal
 * bridge -- production code only ever sets this via `requestStructural`. Tests that simulate
 * "the latch is held" directly via `setLatched(true)` (bypassing `requestStructural`) must
 * also set this if they intend `handleUndoReplyFromSwift` to accept a specific opId. */
export function getInFlightOpId(): string | null {
  return inFlightOpId;
}
export function setInFlightOpId(opId: string | null): void {
  inFlightOpId = opId;
}

/** Test-only full reset, mirroring resetBlockIdState()/resetBlockSyncState() elsewhere in
 * this codebase's test suites. Not part of the window.FinalFinal bridge. */
export function resetUndoCoordinatorState(): void {
  registry.clear();
  descriptor = {};
  latched = false;
  inFlightOpId = null;
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

/**
 * N4 (major, Phase B remediation plan): checkpoint-swap/structural-boundary hygiene. Called
 * at the same three boundaries as `cancelPendingInsertions` above (op start, undo start,
 * redo start) -- force-closes any open editing popup (annotation edit, citation edit, link
 * tooltip) and clears find/replace's cached document positions/query, so none of them can
 * act on stale offsets against the document a structural op/undo/redo is about to swap out
 * from under them. This was called for in the original design's Phase 0 inventory and never
 * landed (plan §Phase 0(e)).
 *
 * No separate scroll-map cache exists on the Milkdown side to invalidate here (unlike
 * CodeMirror's heading-metrics cache, `codemirror/src/api.ts`'s mirror of this function) --
 * the checkpoint swap's wholesale `view.updateState()` already replaces the entire
 * ProseMirror view state, which inherently invalidates any DOM-position-dependent internal
 * caches as a side effect of the swap itself.
 *
 * Judge round 2 fix (must-fix 4): the annotation/citation popups are force-closed via
 * COMMIT-then-close, not discard-then-close -- `hideAnnotationEditPopup`/`hideEditPopup`
 * silently threw away an in-progress edit, and since `handleSlashKeydown` is a capture-phase
 * document listener, a Cmd-Z with the caret inside one of these popups' inputs would route
 * structurally and reach this boundary call, discarding whatever the user had just typed.
 * Safe to commit here specifically because this call runs BEFORE `mutate` (the op's DB
 * write), against the still-valid pre-op document -- see each `commitAndClose*` function's
 * own doc comment.
 */
export function closeEditingPopupsAndClearBoundaryState(): void {
  commitAndCloseAnnotationEditPopup();
  commitAndCloseEditPopup();
  hideLinkPopups();
  clearSearch();
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
 * CROSS-ENTRY GUARD (found live 2026-08-18, notes.md): the mid-op skip below used to be scoped
 * to a single entry -- `if (entry.postOpDoc === entry.preOpDoc) continue`, protecting only an
 * op's OWN entry from its own sequence corrupting itself. That is not enough once two entries
 * can be live in the registry at once (possible since Phase 7 made reorder a tracked op instead
 * of a registry-clearing barrier). Concrete collision: the user restores a section (op A
 * finalizes, `entryA.postOpDoc = DOC_A`), then immediately drag-reorders it (op B begins). Op
 * B's OWN primary content push is a sync-origin transaction with `tr.before = DOC_A` (nothing
 * changed between A finishing and B starting) and `tr.doc = DOC_B`. A single-entry guard only
 * skips B's own (still-placeholder) entry -- it does nothing to stop this same transaction from
 * scanning `entryA` too, finding `entryA.postOpDoc.eq(before)` true (`DOC_A == DOC_A`), and
 * wrongly advancing `entryA.postOpDoc` to `DOC_B`. After the user undoes B (back to `DOC_A`),
 * the routing check for the now-top-of-stack `entryA` needs `entryA.postOpDoc.eq(currentDoc)`
 * -- but `postOpDoc` is now `DOC_B`, not `DOC_A`, so it fails and the second Cmd-Z silently
 * does nothing instead of undoing the restore.
 *
 * Fixed by widening the guard to the whole function: while ANY entry in the registry is
 * currently mid-op (same detector as before -- `postOpDoc === preOpDoc`; at most one entry can
 * be mid-op at a time, since `StructuralUndoController.isPerforming`'s latch prevents concurrent
 * structural op sequences), skip advancing EVERY entry for this transaction, not just the
 * mid-op one. This is the rule's actual documented intent: only genuine async derived-content
 * churn landing OUTSIDE of any active op's own sequence window should ever advance another
 * entry -- never a new op's own primary push or its own pre-finalize resyncs reaching back and
 * silently mutating a DIFFERENT, already-finalized entry's equality target.
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
  // P3 (undo-mode-switch-focus second timing gap): a `derivedCorrection`-tagged
  // transaction is dispatched WITHOUT addToHistory:false (deliberately user-undoable,
  // heading-level overlap fix) but must still be treated as sync-origin here -- it's an
  // automatic correction, not a real user edit.
  //
  // FILED RESIDUAL, Phase-3 prerequisite (do not fix this round): widening this predicate
  // means a derived correction now advances postOpDoc even though it's ALSO
  // user-undoable. Undoing it could leave the live doc unequal to postOpDoc, so the next
  // Cmd-Z would fall through to text-undo instead of routing to a structural entry --
  // orphaning it (not corrupting anything, just missing an entry). Unreachable today: no
  // structural entries exist yet (descriptor.undoTopOpId is never populated until Phase 3).
  if (tr.getMeta('addToHistory') !== false && !tr.getMeta('derivedCorrection')) return;
  if (!tr.docChanged) return;

  // Whole-function mid-op guard (see doc comment above): if ANY entry is currently mid-op, this
  // transaction could be that op's own primary push (or one of its own pre-finalize resyncs)
  // reaching back onto a DIFFERENT, already-finalized entry -- never advance anything until the
  // in-flight op has finalized. Exact, not a heuristic: at most one entry is ever mid-op at a
  // time (StructuralUndoController.isPerforming's latch).
  const anyMidOp = [...registry.values()].some((entry) => entry.postOpDoc === entry.preOpDoc);
  if (anyMidOp) return;

  const before = tr.before;
  const after = tr.doc;
  for (const [opId, entry] of registry) {
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
  // N7 (minor, Phase B remediation plan): plan §4.3 specified a post-swap scrollIntoView so
  // the restored caret stays visible; never implemented. `updateState()` swaps in the
  // checkpoint's own selection wholesale but does not itself scroll the viewport to it --
  // without this, a swap that restores the caret somewhere currently off-screen leaves it
  // there. Dispatched as its own no-op-doc transaction (matching the pattern used elsewhere
  // in this codebase, e.g. find-replace.ts's goToMatch) rather than folded into the swap
  // itself, since `updateState` bypasses the normal dispatch/scrollIntoView pipeline.
  view.dispatch(view.state.tr.scrollIntoView());
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
  inFlightOpId = opId; // N5: track the specific request this latch is now held for
  clearLatchTimeout();
  latchTimeoutId = setTimeout(() => {
    latchTimeoutId = null;
    if (!latched) return;
    latched = false;
    inFlightOpId = null;
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

  // Permanent routing/history visibility (undo-mode-switch-focus investigation legacy --
  // kept because it proved useful for diagnosing undo behavior generally; DOM-focus state
  // was checked extensively during that investigation and confirmed never the actual
  // defect, so it's no longer logged here). NOT the actual undo()/redo() call: unlike
  // CodeMirror, Milkdown has no explicit custom keymap binding in this codebase's own
  // source for the keydown path's real invocation -- `.use(history)` in main.ts wires in
  // `@milkdown/kit/plugin/history` (vendored, prosemirror-history's own keymap plugin),
  // which calls `undo`/`redo` internally and is not a call site this code can safely wrap
  // without editing vendored library code. So for THIS path, only the depth/length
  // snapshot below is available, not the command's actual return value. The RPC/menu
  // path's `requestUnified` below DOES call undo()/redo() directly in code this file owns,
  // so that one IS logged with real command-level evidence.
  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'debug',
    message:
      `[UnifiedUndo] keydown direction=${direction} decision=${decision.action} ` +
      `undoDepth=${undoDepth(view.state)} redoDepth=${redoDepth(view.state)} ` +
      `docLength=${view.state.doc.content.size} userTxCount=${userTxCount}`,
  });

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
    // This IS the real, sole invocation of undo()/redo() for the RPC/menu path
    // (UndoRedoCommands.swift's performUndo/performRedo ->
    // window.FinalFinal.requestUnifiedUndo/requestUnifiedRedo -> here) -- logging around it
    // adds no extra call, just captures what the command actually reports (permanent
    // visibility, undo-mode-switch-focus investigation legacy).
    const docLengthBefore = view.state.doc.content.size;
    const commandReturned = direction === 'undo' ? undo(view.state, view.dispatch) : redo(view.state, view.dispatch);
    const docLengthAfter = view.state.doc.content.size;
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message:
        `[UnifiedUndo] menu-path-invocation direction=${direction} ` +
        `commandReturned=${commandReturned} docLengthBefore=${docLengthBefore} ` +
        `docLengthAfter=${docLengthAfter}`,
    });
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
  // N5 (minor, Phase B remediation plan): match against the specific in-flight opId, not
  // just "is the latch held" -- a reply for a stale/superseded request must not be applied
  // as if it were the reply for whatever is (or, after a timeout, isn't) actually latched
  // now. `inFlightOpId` is set by `requestStructural` and can only ever match the ONE
  // request the latch is currently held for (H7: only one structural sequence in flight at
  // a time), so a mismatch here is unambiguously a stale reply -- ignore it without
  // touching the latch, which still belongs to the real in-flight request.
  if (reply.opId !== inFlightOpId) {
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[undo-coordinator] ignoring ${direction} reply for stale opId=${reply.opId} (in-flight opId=${inFlightOpId})`,
    });
    return;
  }
  latched = false;
  inFlightOpId = null;
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
  // P3 (undo-mode-switch-focus second timing gap): a `derivedCorrection`-tagged
  // transaction IS user-undoable (so it does NOT hit the addToHistory===false check just
  // above) but it's still an automatic correction, not a genuine user edit.
  if (tr.getMeta('addToHistory') === false || tr.getMeta('derivedCorrection')) return;
  if (isHistoryTransaction(tr)) return;
  (window as any).webkit?.messageHandlers?.historyEdited?.postMessage({});
}
