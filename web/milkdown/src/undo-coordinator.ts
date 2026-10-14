// Unified chronological undo -- JS routing module for Milkdown.
// Mirrored (not shared) in web/codemirror/src/undo-coordinator.ts -- see that file's header
// for why this is two near-identical files rather than one shared module.
//
// Routing module (docs/architecture/unified-undo.md): owns the registry, descriptor,
// document-equality routing decision, in-flight latch, and historyEdited predicate that
// decide, on every Cmd-Z/Cmd-Shift-Z, whether the next step back is a structural operation
// (version restore, section delete/duplicate/reorder -- handed to Swift) or plain text (left
// to Milkdown's own text undo/redo, prosemirror-history). `descriptor.undoTopOpId`/
// `redoTopOpId` reflect whatever is actually on top of the native `UnifiedUndoService`
// stacks; when both are empty (nothing structural recorded, or everything already undone),
// every routing decision falls through unchanged to Milkdown's own history.

import { editorViewCtx } from '@milkdown/kit/core';
import { closeHistory, isHistoryTransaction, redo, redoDepth, undo, undoDepth } from '@milkdown/kit/prose/history';
import type { Node } from '@milkdown/kit/prose/model';
import type { EditorState, Transaction } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { commitAndCloseAnnotationEditPopup } from './annotation-edit-popup';
import { clearEditorHistory, getContent } from './api-content';
import { clearBlockIds } from './block-id-plugin';
import {
  hasPendingChanges,
  hasUnsettledLocalEdit,
  rebindCurrentStateFromView,
  resetAndSnapshot,
  setSyncPaused,
} from './block-sync-plugin';
import { resetCAYWState } from './cayw';
import { commitAndCloseEditPopup } from './citation-edit-popup';
import { explainDerivedDifference } from './derived-equivalence';
import { getEditorInstance, setCurrentContent } from './editor-state';
import { clearSearch } from './find-replace';
import { consumePendingDropPos, consumePendingPastePos } from './image-plugin';
import { hideLinkPopups } from './link-tooltip';
import { noteRealUserEditForEcho } from './typing-trace';

// Real user-transaction counter for the permanent `[UnifiedUndo]` fallthrough log below
// (undo-mode-switch-focus investigation legacy -- kept because it proved genuinely useful
// diagnostic signal, not because it's still under investigation). ProseMirror equivalent of
// the CodeMirror mirror's `Transaction.addToHistory` check -- `tr.getMeta('addToHistory')
// !== false` is the same "not explicitly marked sync-origin" idiom
// `isRealUserEditTransaction` (below) shares with the registry advancement rule. Wired into the
// `view.dispatch` override in main.ts (via `runUndoTrackedDispatch`).
let userTxCount = 0;
export function noteUserTransaction(tr: Transaction): void {
  // P3 (undo-mode-switch-focus second timing gap): a `derivedCorrection`-tagged
  // transaction IS user-undoable (addToHistory !== false) by design, but it isn't a real
  // user keystroke -- `isRealUserEditTransaction` (below) excludes it, so this diagnostic
  // counter still means what its name says.
  if (isRealUserEditTransaction(tr)) {
    userTxCount += 1;
    // Slice 0 measurement (typing-trace.ts): posts `typingEcho` from the next animation frame, ONLY while Swift has switched
    // the trace flag on. Same predicate as the counter above, so the echo is for real user edits and nothing else.
    noteRealUserEditForEcho();
  }
}

// === Types (see docs/architecture/unified-undo.md's registry/descriptor bridge protocol
// section) ===

/** One registered structural op's editor-side inverse material, populated by
 * `beginStructuralOp`/`finalizeStructuralOpPostOpDoc` for every real structural op. */
export interface UndoRegistryEntry {
  /** Full EditorState captured at op time (pre-op) -- swapped in wholesale on structural
   * undo (checkpoint-swap, see docs/architecture/unified-undo.md's Checkpoints section). */
  checkpoint: EditorState;
  /** Full EditorState captured at UNDO time (see the doc's audited-sequences section, undo
   * step 2) -- the post-op state as it stood the moment undo fired. Swapped in wholesale on
   * structural REDO. Absent until this entry has actually been undone once (mirrors
   * StructuralEntry.redoSnapshotId on the Swift side). */
  redoCheckpoint?: EditorState;
  /** Document immediately after the op -- the equality target for structural undo (see the
   * doc's routing section). */
  postOpDoc: Node;
  /** Document immediately before the op -- the equality target for structural redo. */
  preOpDoc: Node;
  /** True from `beginStructuralOp` until `finalizeStructuralOpPostOpDoc` (or
   * `clearFailedStructuralOpEntry`, which removes the entry entirely) -- explicit mid-op
   * marker, NOT inferred from `postOpDoc === preOpDoc` reference identity. A zero-diff op
   * (e.g. a Document Note delete, which changes no document text) legitimately finalizes
   * with `postOpDoc` and `preOpDoc` pointing at the exact same doc object -- that used to be
   * indistinguishable from "still mid-op" for `maybeAdvanceRegistryOnSyncOriginTx`'s detector
   * below, which would then treat the entry as permanently mid-flight and skip advancing
   * EVERY entry in the registry for the rest of the session. See
   * docs/architecture/unified-undo.md's "Tracked entries for DB-only mutations" subsection.
   * Optional (not every test-constructed entry sets it) -- `undefined` reads as `false`
   * (not mid-op), which is the correct default for an already-finalized entry. */
  midOp?: boolean;
}

/** Swift-pushed pointer to the top of each stack (see docs/architecture/unified-undo.md's
 * registry/descriptor bridge protocol section), pushed by `pushDescriptor()` after every
 * recorded op, undo, and redo. `{}` (both fields absent) is the steady state whenever
 * nothing structural is recorded, or everything has been undone. */
export interface UndoDescriptor {
  undoTopOpId?: string;
  redoTopOpId?: string;
}

export type RoutingDecision =
  | { action: 'structural'; opId: string }
  | { action: 'fallthrough' }
  // In-flight latch held (hazard H7, see docs/architecture/unified-undo.md): don't fall through
  // to the editor's own undo -- a second Cmd-Z while a structural undo is settling must not
  // interleave with it. The live callers (the keydown and menu paths) QUEUE the press instead of
  // dropping it (plan D9) and route it, deciding afresh, once Swift's reply for the in-flight
  // request arrives.
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
 * note above): if Swift's reply is ever lost -- a torn-down WebView, a hung app -- this
 * self-clears the latch instead of leaving every future Cmd-Z/Cmd-Shift-Z held for the rest of
 * the session. It is only a hung-app safety net: since Phase 4b part 2 Swift replies on every
 * path (its command gate holds a request instead of refusing it, and every job resolves), and a
 * slow undo on a book can legitimately take several seconds, so 3s would have cut a healthy
 * request off. On expiry any presses still queued behind the latch are dropped and Swift is told
 * once (`undoQueueDropped`). */
const LATCH_TIMEOUT_MS = 30000;
let latchTimeoutId: ReturnType<typeof setTimeout> | null = null;

/** Cmd-Z / Cmd-Shift-Z presses made while the in-flight latch was held (plan D9), oldest first. Each one is routed afresh
 * against the live document when Swift's reply for the in-flight request arrives -- structural presses (and text presses
 * alike, so the order the user pressed them in is kept) wait here instead of being dropped. */
const queuedPresses: Array<{ direction: 'undo' | 'redo' }> = [];

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

/** Barrier-only registry clear (see docs/architecture/unified-undo.md's Barriers section):
 * clears the registry and resets the
 * descriptor to `{}` WITHOUT touching this editor's own text-undo history -- unlike
 * `clearStructuralUndoState()` (eviction, below), a barrier (zoom, project/mode switch,
 * hierarchy enforcement, annotation ops, section metadata edits) must NOT wipe
 * legitimate in-flight text-undo steps, only the now-invalid structural checkpoints/descriptor.
 * Correctness was already backstopped without this (a stale opId request gets `.fallback` --
 * see the doc's routing section), but leaving the registry populated is a per-session
 * `EditorState` leak (every
 * checkpoint retains a full ProseMirror doc) and defeats the JS-side fast path (the descriptor
 * keeps claiming there's something to route). Bridge target for
 * `window.FinalFinal.clearStructuralUndoRegistry`, called by Swift from
 * `UnifiedUndoService.invalidateAll()`. */
export function clearStructuralUndoRegistry(): void {
  clearRegistry();
  setUndoDescriptor({});
  // The barrier replaces the timeline the latch and the queued presses belonged to (a project
  // switch, close, mode switch): a request still in flight will never be answered for it, and a
  // later reply is ignored (`handleUndoReplyFromSwift`'s `!latched` guard). Leaving the latch
  // held would swallow every later press until the safety net fired.
  releaseLatchAndQueue();
}

/** Eviction mini-barrier (see docs/architecture/unified-undo.md's Eviction section): the
 * oldest structural entry just fell off the undo
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
 * closure.
 *
 * Mount-flash fix (doc-open-blank-regression follow-up): deliberately does NOT begin/end a
 * native cloak (webView.alphaValue hide/show, MilkdownCoordinator+MessageHandlers.swift's
 * beginCloak/endCloak) even though it calls `clearEditorHistory()`, the same function
 * `resetForProjectSwitch()` uses (which DOES cloak, at ITS OWN Swift call site). This path
 * fires on ordinary undo-stack eviction during normal editing (op #51+, ring-buffer capacity)
 * -- a routine, frequent event, not a structural document rebuild -- and must have zero
 * flicker. See `clearEditorHistory()`'s own doc comment (api-content.ts) for the matching
 * note on its side. */
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
/** Bridge target for window.FinalFinal.setUndoDescriptor -- called by Swift's
 * `StructuralUndoController.pushDescriptor()` after every recorded op, undo, and redo. NOT
 * called on a barrier -- barriers reset descriptor state locally via
 * `clearStructuralUndoRegistry()` above instead. */
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
/** Test-only: how many presses are queued behind the latch right now, and in which direction (oldest first). */
export function getQueuedPressDirections(): Array<'undo' | 'redo'> {
  return queuedPresses.map((press) => press.direction);
}

/** Test-only full reset, mirroring resetBlockIdState()/resetBlockSyncState() elsewhere in
 * this codebase's test suites. Not part of the window.FinalFinal bridge. */
export function resetUndoCoordinatorState(): void {
  registry.clear();
  descriptor = {};
  latched = false;
  inFlightOpId = null;
  queuedPresses.length = 0;
  lastEquivalence = null;
  lastRoutingMs = null;
  clearLatchTimeout();
}

// === Structural-operation diagnostics (permanent) ===
// One-line records of what a structural operation (section delete / duplicate / reorder, version
// restore, and the undo or redo of one) does to the editor, posted on the existing
// `type: 'debug'` errorHandler channel under the `[STRUCT-TRACE]` prefix (the prefix is what log
// readers and the end-to-end tests search for). Swift logs each as
// `[MilkdownEditor] JS DEBUG: [STRUCT-TRACE] ...` (category `.editor`, via
// MilkdownCoordinator+MessageDispatch.swift's logJSDiagnostic), and into the diagnostic log file
// as `[editor] [MilkdownEditor] JS DEBUG: [STRUCT-TRACE] ...` when Diagnostics logging is on.
// The lines: `finalize` (op saved its post-op document), `registry-advance` (an automatic rewrite
// moved a saved document forward), `push-probe` (did the user type between the op's start and its
// content push), `routing-refused` (why a Cmd-Z / Cmd-Shift-Z was not routed structurally),
// `swap` and `settle` (the checkpoint swap and its settle). Every caller is a structural-op path
// that only runs while a registry entry exists, and only on structural events -- never once per
// keystroke -- and nothing here changes behaviour. Swift's matching timing lines are
// `StructTrace` in StructuralUndoController.swift. A line NEVER carries document text (typed words,
// heading or footnote text: docs/guides/debug-logging.md): sizes, counts, positions, node types and
// timings only.

function structTrace(message: string): void {
  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'debug',
    message: `[STRUCT-TRACE] ${message}`,
  });
}

/** A diagnostic must never break the operation it observes: every probe below runs through this. */
function guardedTrace(probe: () => void): void {
  try {
    probe();
  } catch {
    // Swallowed on purpose -- see the doc comment above.
  }
}

function shortOpId(opId: string | undefined): string {
  return opId === undefined ? 'none' : opId.slice(0, 8);
}

interface DocDiff {
  eq: boolean;
  /** First differing position in `a.content` coordinates (-1 when equal). */
  firstDiffPos: number;
  /** Index of the top-level child holding that first difference (-1 when equal). */
  firstDiffChild: number;
  /** Top-level children that differ position by position; surplus children on either side count. */
  diffChildren: number;
}

function summarizeDocDiff(a: Node, b: Node): DocDiff {
  if (a.eq(b)) return { eq: true, firstDiffPos: -1, firstDiffChild: -1, diffChildren: 0 };
  const pos = a.content.findDiffStart(b.content);
  const firstDiffChild = pos === null ? -1 : a.resolve(Math.min(pos, a.content.size)).index(0);
  let diffChildren = Math.abs(a.childCount - b.childCount);
  const shared = Math.min(a.childCount, b.childCount);
  for (let i = 0; i < shared; i++) {
    if (!a.child(i).eq(b.child(i))) diffChildren++;
  }
  return { eq: false, firstDiffPos: pos ?? -1, firstDiffChild, diffChildren };
}

function docShape(doc: Node): string {
  // No `textContent`: on a book it builds a ~350,000-character string per call, and a refused Cmd-Z runs
  // this twice. The size and the child count already say how far two documents are apart.
  return `size=${doc.content.size} children=${doc.childCount}`;
}

/** [STRUCT-TRACE] push probe: called by api-content.ts's `setContentWithBlockIds` when
 * `options.detectPausedEdits` is set, BEFORE the block-level replace. For the registry entry that
 * is mid-op, reports whether the live document still equals that entry's `preOpDoc` -- i.e.
 * whether the user typed (or otherwise changed the document) between `beginStructuralOp` and
 * this push -- and, if not, how many top-level children differ and where the first difference is.
 * Also reports whether block-sync's pending queue (or its 100ms debounce) holds an edit at this
 * moment: the edits the replace below is about to overwrite. A no-op when the registry is empty
 * or nothing is mid-op. */
export function traceMidOpPushDrift(liveDoc: Node, incomingDoc: Node): void {
  if (registry.size === 0) return;
  guardedTrace(() => {
    for (const [opId, entry] of registry) {
      if (!entry.midOp) continue;
      const d = summarizeDocDiff(liveDoc, entry.preOpDoc);
      structTrace(
        `push-probe opId=${shortOpId(opId)} eq=${d.eq} diffChildren=${d.diffChildren} firstDiffChild=${d.firstDiffChild} ` +
          `firstDiffPos=${d.firstDiffPos} liveSize=${liveDoc.content.size} preOpSize=${entry.preOpDoc.content.size} ` +
          `incomingSize=${incomingDoc.content.size} liveChildren=${liveDoc.childCount} ` +
          `incomingChildren=${incomingDoc.childCount} pendingQueue=${hasPendingChanges()} ` +
          `unsettledEdit=${hasUnsettledLocalEdit()}`
      );
    }
  });
}

/** [STRUCT-TRACE] routing probe: called after every Cmd-Z/Cmd-Shift-Z routing decision. When the
 * decision is not 'structural' although Swift's descriptor names a structural entry on top of the
 * stack, reports which condition of `decideRouting` failed (checked in the same order it checks
 * them: latched, no registry entry, pending local edit, documents not equal), and for the
 * not-equal case the sizes of the live document and of the target document the entry holds. */
function traceRoutingRefusal(view: EditorView, direction: 'undo' | 'redo', decision: RoutingDecision): void {
  if (decision.action === 'structural') return;
  const topOpId = direction === 'undo' ? descriptor.undoTopOpId : descriptor.redoTopOpId;
  if (topOpId === undefined) return;
  guardedTrace(() => {
    const diagStart = performance.now();
    const entry = registry.get(topOpId);
    const unsettled = hasUnsettledLocalEdit();
    const current = view.state.doc;
    let failed = 'unknown';
    let detail = '';
    if (entry) {
      const targetName = direction === 'undo' ? 'postOpDoc' : 'preOpDoc';
      const target = direction === 'undo' ? entry.postOpDoc : entry.preOpDoc;
      const d = summarizeDocDiff(current, target);
      if (latched) failed = 'latched';
      else if (unsettled) failed = 'pendingMapsEmpty=false';
      else if (!d.eq) failed = 'docs-not-equal';
      detail =
        ` target=${targetName} docsEqual=${d.eq} midOp=${entry.midOp === true}` +
        ` current(${docShape(current)}) target(${docShape(target)})` +
        ` firstDiffChild=${d.firstDiffChild} firstDiffPos=${d.firstDiffPos} diffChildren=${d.diffChildren}` +
        ` entryPreOpSize=${entry.preOpDoc.content.size} entryPostOpSize=${entry.postOpDoc.content.size}` +
        ` checkpointSize=${entry.checkpoint.doc.content.size} hasRedoCheckpoint=${entry.redoCheckpoint !== undefined}`;
    } else {
      failed = latched ? 'latched' : 'no-registry-entry';
      detail = ` registryIds=[${[...registry.keys()].slice(0, 5).map(shortOpId).join(',')}]`;
    }
    // `routingMs` is the whole routing decision for this press (decideLiveRouting); `diagMs` is what
    // building THIS line cost on top, so the two together are what a refused Cmd-Z added to the press.
    const diagMs = performance.now() - diagStart;
    structTrace(
      `routing-refused direction=${direction} decision=${decision.action} topOpId=${shortOpId(topOpId)} failed=${failed} ` +
        `latched=${latched} registryEntry=${entry !== undefined} registrySize=${registry.size} ` +
        `pendingMapsEmpty=${!unsettled} equivalent=${lastEquivalence === null ? 'not-run' : lastEquivalence.result} ` +
        `routingMs=${lastRoutingMs === null ? 'n/a' : lastRoutingMs.toFixed(1)} diagMs=${diagMs.toFixed(1)}` +
        `${lastEquivalence?.reason ? ` equivalenceReason=${lastEquivalence.reason}` : ''}${detail}`
    );
  });
}

// === Pure routing decision (see docs/architecture/unified-undo.md's routing section) ===
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
  /** Fallback comparison, consulted ONLY after `docsEqual` has failed: "equal modulo what the app
   * regenerates" (footnote numbers, heading ids, Notes, bibliography -- see derived-equivalence.ts).
   * Optional: absent means exact equality alone, exactly the behaviour before this fallback existed. */
  docsEquivalent?: (a: TDoc, b: TDoc) => boolean;
}

function decideRouting<TDoc>(params: RoutingParams<TDoc>, direction: 'undo' | 'redo'): RoutingDecision {
  if (params.latched) return { action: 'swallow' };

  const opId = direction === 'undo' ? params.descriptor.undoTopOpId : params.descriptor.redoTopOpId;
  if (opId === undefined) return { action: 'fallthrough' };

  const entry = params.registry.get(opId);
  if (!entry) return { action: 'fallthrough' };

  if (!params.pendingMapsEmpty) return { action: 'fallthrough' };

  const target = direction === 'undo' ? entry.postOpDoc : entry.preOpDoc;
  // Exact equality first and short-circuiting: on the everyday path the fallback is never called.
  if (!params.docsEqual(params.currentDoc, target) && !(params.docsEquivalent?.(params.currentDoc, target) ?? false)) {
    return { action: 'fallthrough' };
  }

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

/** The last fallback comparison made while deciding ONE Cmd-Z / Cmd-Shift-Z (null when none ran:
 * exact equality held, or routing stopped before reaching the comparison). Reset by
 * `decideLiveRouting` before every decision; read by the `routing-equivalence` trace line and by
 * `traceRoutingRefusal`. */
let lastEquivalence: { result: boolean; ms: number; reason: string | null } | null = null;

/** Milliseconds the whole last routing decision took (`decideLiveRouting`: the live-parameter build, the
 * exact comparison, the fallback comparison when it ran), null before the first press. Read by the
 * `routing-equivalence` and `routing-refused` trace lines: it is what Cmd-Z pays per press, and a held key
 * repeats it. Reset with the rest of the module state. */
let lastRoutingMs: number | null = null;

/** Longest `reason` the trace lines carry (the reason is one short line; this only bounds a pathological one). */
const MAX_REASON_CHARS = 400;

/** The fallback comparison, timed on the app's own clock so the book run can report what it costs. It runs
 * `explainDerivedDifference` (the comparison itself, returning the reason it said "different", null when
 * equivalent), so a refused Cmd-Z can log WHY; the boolean the routing uses is `reason === null`. */
function docsEquivalentTimed(a: Node, b: Node): boolean {
  const start = performance.now();
  const reason = explainDerivedDifference(a, b);
  lastEquivalence = {
    result: reason === null,
    ms: performance.now() - start,
    reason: reason === null ? null : reason.slice(0, MAX_REASON_CHARS),
  };
  return reason === null;
}

function liveRoutingParams(view: EditorView): RoutingParams<Node> {
  return {
    descriptor,
    registry,
    pendingMapsEmpty: pendingMapsEmpty(),
    latched,
    currentDoc: view.state.doc,
    docsEqual,
    docsEquivalent: docsEquivalentTimed,
  };
}

/** The ONE live routing decision for a Cmd-Z / Cmd-Shift-Z: the keydown path and the menu path
 * (`requestUnified`) both call it, so both use the fallback comparison and both log it. Runs only on
 * those key presses, never per keystroke. */
function decideLiveRouting(view: EditorView, direction: 'undo' | 'redo'): RoutingDecision {
  const routingStart = performance.now();
  lastEquivalence = null;
  const params = liveRoutingParams(view);
  const decision = direction === 'undo' ? decideUndoRouting(params) : decideRedoRouting(params);
  const totalMs = performance.now() - routingStart;
  lastRoutingMs = totalMs;
  // `docsEquivalentTimed` (called from inside the decision above) sets this; TypeScript cannot see
  // that assignment, so it would narrow the variable to `null` here without the cast.
  const ran = lastEquivalence as { result: boolean; ms: number; reason: string | null } | null;
  if (ran !== null) {
    guardedTrace(() =>
      structTrace(
        `routing-equivalence direction=${direction} decision=${decision.action} result=${ran.result} ms=${ran.ms.toFixed(1)} ` +
          `totalMs=${totalMs.toFixed(1)}` +
          (ran.reason === null ? '' : ` reason=${ran.reason}`)
      )
    );
  }
  return decision;
}

/** True when the editor's own text undo/redo has nothing to do -- the trigger condition for
 * the refusal beep (a Cmd-Z that would otherwise be a silent no-op; see
 * docs/architecture/unified-undo.md's routing section). */
function hasNoTextHistory(view: EditorView, direction: 'undo' | 'redo'): boolean {
  return direction === 'undo' ? undoDepth(view.state) === 0 : redoDepth(view.state) === 0;
}

/** Refusal UX (see docs/architecture/unified-undo.md's routing section, "specified --
 * review found it merely asserted"): a fallthrough decision with nothing left in the
 * editor's own text history either means Cmd-Z would otherwise be a silent no-op. Beep
 * instead, via the same safe-optional-chaining postMessage pattern as every other Swift
 * bridge call in this module. */
function maybeBeepOnRefusal(view: EditorView, direction: 'undo' | 'redo'): void {
  if (!hasNoTextHistory(view, direction)) return;
  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'debug',
    message: `[undo-coordinator] refusal beep: no structural entry and no text ${direction} available`,
  });
  (window as any).webkit?.messageHandlers?.structuralUndoRefused?.postMessage({ direction });
}

// === Structural op lifecycle (see docs/architecture/unified-undo.md's audited-sequences
// section) ===
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
 * from under them. This was called for in the original design's Phase 0 spike inventory of
 * module-level JS state and never landed until now.
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
  setRegistryEntry(opId, { checkpoint: view.state, postOpDoc: preOpDoc, preOpDoc, midOp: true });
  return true;
}

/** Op-sequence step 6/7: capture `postOpDoc` from the push transaction's own doc -- i.e. the
 * live doc at the moment this is called, which Swift calls immediately after its own content
 * push (`setContentWithBlockIds`) resolves. See docs/architecture/unified-undo.md's
 * audited-sequences section, step 6: this deliberately does NOT
 * wait for RAF-time normalization transactions to settle first; `runUndoTrackedDispatch`
 * (below -- the `view.dispatch` override in main.ts) is what actually absorbs any automatic
 * rewrite that lands after this call, including RAF-time normalization and derived-content
 * resyncs: once the outermost dispatch of such a rewrite returns, it advances this entry's
 * `postOpDoc`/`preOpDoc` reference forward to the LIVE document whenever the doc the dispatch
 * started from structurally matches one of them (and no transaction in it was a real user edit). */
export function finalizeStructuralOpPostOpDoc(opId: string): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  const entry = registry.get(opId);
  if (!entry) return false;
  const view = editorInstance.ctx.get(editorViewCtx);
  registry.set(opId, { ...entry, postOpDoc: view.state.doc, midOp: false });
  guardedTrace(() => {
    const doc = view.state.doc;
    structTrace(
      `finalize opId=${shortOpId(opId)} postOpSize=${doc.content.size} postOpChildren=${doc.childCount} ` +
        `postOpTextLen=${doc.textContent.length} preOpSize=${entry.preOpDoc.content.size} ` +
        `preOpChildren=${entry.preOpDoc.childCount}`
    );
  });
  return true;
}

/**
 * The ONE definition of "this transaction is a real user edit": it changes the document, it adds a
 * history step (`addToHistory` is not `false` -- the established sync-origin marker), and it is not
 * tagged `derivedCorrection` (P3, undo-mode-switch-focus second timing gap: an automatic correction
 * such as the heading-level overlap fix or the footnote renumber is dispatched WITHOUT
 * addToHistory:false so it stays user-undoable, but it is not something the user typed).
 *
 * Shared by `runUndoTrackedDispatch` (the production, per-dispatch-chain path),
 * `maybeAdvanceRegistryOnSyncOriginTx` (the single-transaction form the unit tests drive) and
 * `noteUserTransaction`, so the shipped rule and the tested rule cannot drift apart.
 */
export function isRealUserEditTransaction(tr: Transaction): boolean {
  return tr.docChanged && tr.getMeta('addToHistory') !== false && !tr.getMeta('derivedCorrection');
}

/**
 * Derived-content advancement rule (hazard H5, see docs/architecture/unified-undo.md's
 * registry/descriptor bridge protocol section): for each registry entry, if `before` structurally
 * equals the entry's `postOpDoc` or `preOpDoc` reference, advance that reference to `after`.
 * This is what keeps a structural entry's equality target (§4.2) tracking harmless
 * derived-content churn -- a delayed bibliography fetch, an async footnote renumber, a
 * block-ID push, Milkdown's own heading-id write -- that lands after the entry was captured,
 * instead of permanently bricking the entry's equality check the moment such a resync fires after
 * the op (H5).
 *
 * Production calls this once per dispatch CHAIN (`runUndoTrackedDispatch`), with `before` = the
 * live document before the outermost dispatch and `after` = the live document after it returned.
 * The unit tests also drive it per transaction through `maybeAdvanceRegistryOnSyncOriginTx`.
 *
 * CROSS-ENTRY GUARD (found live 2026-08-18, notes.md): the mid-op skip below used to be scoped
 * to a single entry -- `if (entry.postOpDoc === entry.preOpDoc) continue`, protecting only an
 * op's OWN entry from its own sequence corrupting itself. That is not enough once two entries
 * can be live in the registry at once (possible since Phase 7 made reorder a tracked op instead
 * of a registry-clearing barrier). Concrete collision: the user restores a section (op A
 * finalizes, `entryA.postOpDoc = DOC_A`), then immediately drag-reorders it (op B begins). Op
 * B's OWN primary content push is a sync-origin transaction with `before = DOC_A` (nothing
 * changed between A finishing and B starting) and `after = DOC_B`. A single-entry guard only
 * skips B's own (still-placeholder) entry -- it does nothing to stop this same transaction from
 * scanning `entryA` too, finding `entryA.postOpDoc.eq(before)` true (`DOC_A == DOC_A`), and
 * wrongly advancing `entryA.postOpDoc` to `DOC_B`. After the user undoes B (back to `DOC_A`),
 * the routing check for the now-top-of-stack `entryA` needs `entryA.postOpDoc.eq(currentDoc)`
 * -- but `postOpDoc` is now `DOC_B`, not `DOC_A`, so it fails and the second Cmd-Z silently
 * does nothing instead of undoing the restore.
 *
 * Fixed by widening the guard to the whole function: while ANY entry in the registry is
 * currently mid-op (tracked via the explicit `midOp` marker -- see `UndoRegistryEntry`'s doc
 * comment for why reference identity, `postOpDoc === preOpDoc`, was retired as the detector; at
 * most one entry can be mid-op at a time, since `StructuralUndoController.isPerforming`'s latch
 * prevents concurrent structural op sequences), skip advancing EVERY entry, not just the mid-op
 * one. This is the rule's actual documented intent: only genuine async derived-content churn
 * landing OUTSIDE of any active op's own sequence window should ever advance another entry --
 * never a new op's own primary push or its own pre-finalize resyncs reaching back and silently
 * mutating a DIFFERENT, already-finalized entry's equality target.
 *
 * Costs one property read (`registry.size === 0`) in the common case (no structural entries
 * recorded yet), matching constraint 3 (no per-keystroke cost).
 */
function advanceRegistryEntries(before: Node, after: Node): void {
  if (registry.size === 0 || before === after) return;

  // Whole-function mid-op guard (see doc comment above): if ANY entry is currently mid-op, this
  // chain could be that op's own primary push (or one of its own pre-finalize resyncs)
  // reaching back onto a DIFFERENT, already-finalized entry -- never advance anything until the
  // in-flight op has finalized. Exact, not a heuristic: at most one entry is ever mid-op at a
  // time (StructuralUndoController.isPerforming's latch).
  const anyMidOp = [...registry.values()].some((entry) => entry.midOp);
  if (anyMidOp) return;

  const advanced: string[] = [];
  for (const [opId, entry] of registry) {
    const advancesPost = entry.postOpDoc.eq(before);
    const advancesPre = entry.preOpDoc.eq(before);
    if (!advancesPost && !advancesPre) continue;
    advanced.push(`${shortOpId(opId)}:${advancesPost && advancesPre ? 'post+pre' : advancesPost ? 'post' : 'pre'}`);
    registry.set(opId, {
      ...entry,
      postOpDoc: advancesPost ? after : entry.postOpDoc,
      preOpDoc: advancesPre ? after : entry.preOpDoc,
    });
  }
  // ONE line per chain, however many entries moved (up to 50 can match, and the zero-diff Document Note
  // entries all do). Every matching entry held `before`, so the sizes are the old size of each one.
  if (advanced.length > 0) {
    guardedTrace(() =>
      structTrace(
        `registry-advance count=${advanced.length} opIds=${advanced.join(',')} ` +
          `size=${before.content.size}->${after.content.size} children=${before.childCount}->${after.childCount}`
      )
    );
  }
}

/**
 * The advancement rule for ONE sync-origin transaction: `tr.before` -> `tr.doc`. Production does
 * NOT call this (it advances per dispatch chain, `runUndoTrackedDispatch` below, because a nested
 * dispatch can leave `tr.doc` one transaction behind the live document); it is kept as the thin
 * single-transaction form the unit tests drive, and shares the "is this a real user edit"
 * predicate (`isRealUserEditTransaction`) with the production path.
 *
 * A `derivedCorrection`-tagged transaction counts as sync-origin here -- an automatic correction,
 * not a real user edit -- even though it is dispatched without addToHistory:false and so stays in
 * the text history. That is safe for the structural entry: a correction can only be absorbed when
 * the document equals the entry's `postOpDoc` (or `preOpDoc`) right before it, and while the
 * document equals `postOpDoc`, Cmd-Z routes to the structural undo before any text undo of the
 * correction could run (routing is by document equality, `decideRouting` above). The correction's
 * own undo step is only reachable after the user has really edited -- the document then differs
 * from every saved copy, and structural routing is off until their own text undo brings it back.
 */
export function maybeAdvanceRegistryOnSyncOriginTx(tr: Transaction): void {
  if (registry.size === 0 || !tr.docChanged || isRealUserEditTransaction(tr)) return;
  advanceRegistryEntries(tr.before, tr.doc);
}

// Per-dispatch-chain state for `runUndoTrackedDispatch`. A "chain" is one outermost
// `view.dispatch` call, plus every dispatch made inside it (Milkdown's own nested heading-id
// write, a plugin's `dispatch` from a view update), plus anything a plugin appended to it.
let chainDepth = 0;
let chainBeforeDoc: Node | null = null;
let chainHasUserEdit = false;

/**
 * The editor's `view.dispatch` override (main.ts) routes every transaction through this, so the
 * undo bookkeeping around the real dispatch lives in one testable place: the real dispatch, then
 * the `historyEdited` predicate, then the real user-transaction counter -- and, once per chain,
 * the registry advancement rule.
 *
 * Why per chain, not per transaction (Phase 4b, Fault A): Milkdown's `syncHeadingIdPlugin` runs
 * inside the plugin-view update of the OUTER dispatch and, whenever a freshly parsed heading's
 * `id` attribute is out of date, dispatches a NESTED sync-origin transaction. The nested one
 * finishes first and sees a `before` that no registry entry holds (the outer transaction's result
 * is not yet the live document), so it advanced nothing; then the outer one advanced the entry to
 * ITS `tr.doc` -- one transaction behind the live document -- and equality never returned. Every
 * Notes or bibliography rebuild adds freshly parsed headings, so every rebuild did this. A
 * plugin's `appendTransaction` result is likewise missing from the outer `tr.doc`.
 *
 * So: remember the live document at the OUTERMOST dispatch, run everything, and once the outermost
 * call returns advance every entry whose saved copy equals that remembered document to the LIVE
 * document -- the saved copy follows the live document, whatever the chain did to it.
 *
 * Fail-safe: nothing is advanced if any transaction in the chain was a real user edit
 * (`isRealUserEditTransaction`) or if anything threw. A real user transaction changed the
 * document, so the live document then differs from every saved copy until the user's own text
 * undo brings it back exactly (the intended chronological rule). Absorption also needs
 * `before.eq(saved copy)`, i.e. nothing unabsorbed happened since the operation, so an automatic
 * rewrite can only follow the operation directly. Worst case for an untagged automatic dispatch is
 * a refused structural undo (a beep), never a wrong one.
 */
export function runUndoTrackedDispatch(
  view: EditorView,
  tr: Transaction,
  originalDispatch: (tr: Transaction) => void
): void {
  const outermost = chainDepth === 0;
  if (outermost) {
    chainBeforeDoc = view.state.doc;
    chainHasUserEdit = false;
  }
  chainDepth += 1;
  let completed = false;
  try {
    originalDispatch(tr);
    maybeNotifyHistoryEdited(tr);
    if (isRealUserEditTransaction(tr)) chainHasUserEdit = true;
    noteUserTransaction(tr);
    completed = true;
  } finally {
    chainDepth -= 1;
    if (!completed) chainHasUserEdit = true; // a dispatch that threw is never absorbed
    if (outermost) {
      const before = chainBeforeDoc;
      chainBeforeDoc = null;
      if (before !== null && !chainHasUserEdit) advanceRegistryEntries(before, view.state.doc);
    }
  }
}

/** Undo-sequence step 2: capture the redo checkpoint (the post-op EditorState, as it stands
 * the moment undo fires) into the registry BEFORE the swap below moves the live view away
 * from it. Routing (§4.2) already guaranteed that `currentDoc` equals `entry.postOpDoc` OR is
 * equivalent to it (`docsEquivalentIgnoringDerived`: equal except for what the app regenerates)
 * before this is reachable, so "the state right now" IS the correct redo target. */
function captureRedoCheckpoint(opId: string, view: EditorView): void {
  const entry = registry.get(opId);
  if (!entry) return;
  registry.set(opId, { ...entry, redoCheckpoint: view.state });
}

/**
 * Undo/redo-sequence checkpoint swap (see docs/architecture/unified-undo.md's Checkpoints
 * section). Wraps the wholesale `updateState()` swap with every step the design's
 * three-review round found load-bearing: pause block-sync change detection for the whole
 * swap, swap state, re-point the block-sync module's `currentState` pointer at the
 * swapped-in view (otherwise it keeps pointing at the pre-swap plugin-state object and
 * silently drops the first post-swap edit), and clear stale block IDs so Swift's follow-up
 * `pushBlockIds()` starts from a clean slate. Does NOT resume sync (`setSyncPaused(false)`)
 * or rebaseline (`resetAndSnapshot`) here -- those must wait until AFTER Swift's block-ID
 * push completes ("only after the ID round-trip completes"), so the Swift-side controller
 * calls `finishStructuralSwapSettle` separately once that round-trip is done.
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

  const traceBefore = view.state.doc;
  const traceQueuedAtStart = hasPendingChanges();
  const traceUnsettledAtStart = hasUnsettledLocalEdit();
  setSyncPaused(true);
  view.updateState(target);
  if (direction === 'redo') {
    // Re-anchor (Phase 4b review R1): the document swapped in is the one the user saw when they undid
    // -- the saved post-operation copy plus whatever rewrites had landed by then, which is NOT always
    // the exact `postOpDoc` (the fallback comparison routed that undo when the typing came first).
    // Anchor the entry's undo target to the document that is live now, so exact equality holds again
    // and the next automatic rewrite is absorbed by the chain, instead of leaving every later Cmd-Z
    // dependent on the fallback comparison.
    registry.set(opId, { ...entry, postOpDoc: view.state.doc });
  }
  rebindCurrentStateFromView(view);
  clearBlockIds();
  // N7 (minor, Phase B remediation plan): the original design specified a post-swap
  // scrollIntoView so the restored caret stays visible; never implemented until this fix.
  // `updateState()` swaps in the
  // checkpoint's own selection wholesale but does not itself scroll the viewport to it --
  // without this, a swap that restores the caret somewhere currently off-screen leaves it
  // there. Dispatched as its own no-op-doc transaction (matching the pattern used elsewhere
  // in this codebase, e.g. find-replace.ts's goToMatch) rather than folded into the swap
  // itself, since `updateState` bypasses the normal dispatch/scrollIntoView pipeline.
  view.dispatch(view.state.tr.scrollIntoView());
  guardedTrace(() => {
    const after = view.state.doc;
    structTrace(
      `swap opId=${shortOpId(opId)} direction=${direction} sizeBefore=${traceBefore.content.size} ` +
        `sizeAfter=${after.content.size} childrenBefore=${traceBefore.childCount} childrenAfter=${after.childCount} ` +
        `pendingQueueAtStart=${traceQueuedAtStart} unsettledEditAtStart=${traceUnsettledAtStart}`
    );
  });
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
  // [STRUCT-TRACE]: whether block-sync still holds edits at this moment -- exactly what the
  // resetAndSnapshot below drops from the pending queue and from the 100ms debounce.
  const traceBefore = view.state.doc;
  const traceQueuedAtStart = hasPendingChanges();
  const traceUnsettledAtStart = hasUnsettledLocalEdit();
  resetAndSnapshot(view.state.doc);
  setSyncPaused(false);
  // Content-mirror sync (see docs/architecture/unified-undo.md's audited-sequences section,
  // undo step 3c -- the exact BLOCKER hazard documented at
  // ContentView+ContentRebuilding.swift:462-467): the JS-side `currentContent` cache is a
  // stale pre-swap value until refreshed here -- left stale, a later stray read of it (e.g.
  // main.ts's init race-condition check) would see the wrong document.
  setCurrentContent(getContent());
  guardedTrace(() => {
    const after = view.state.doc;
    structTrace(
      `settle sizeBefore=${traceBefore.content.size} sizeAfter=${after.content.size} childrenBefore=${traceBefore.childCount} ` +
        `childrenAfter=${after.childCount} pendingQueueAtStart=${traceQueuedAtStart} ` +
        `unsettledEditAtStart=${traceUnsettledAtStart}`
    );
  });
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

/** Throws away the presses queued behind the latch and tells Swift ONCE, so it can show its one-line warning (plan A4). Used
 * by the safety-net timeout and by a failed reply; a no-op when nothing is queued. */
function dropQueuedPresses(why: string): void {
  const count = queuedPresses.length;
  if (count === 0) return;
  queuedPresses.length = 0;
  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'debug',
    message: `[undo-coordinator] dropped ${count} queued undo/redo press(es): ${why}`,
  });
  (window as any).webkit?.messageHandlers?.undoQueueDropped?.postMessage({ count });
  postHeldPressesSettled(count);
}

/** Tells Swift that `count` presses it may be counting as held (`heldUndoPressCount`) ended WITHOUT a request to Swift: they fell
 * through to a plain text undo/redo, or were dropped. Swift's close lets exactly the held presses through its closed gate and
 * waits until each has either arrived as a request or been settled here, so every way a held press can end must come through
 * this message. A no-op for 0. */
function postHeldPressesSettled(count: number): void {
  if (count <= 0) return;
  (window as any).webkit?.messageHandlers?.undoHeldPressSettled?.postMessage({ count });
}

/** How many Cmd-Z / Cmd-Shift-Z presses are being held behind the in-flight latch right now (0 when none). Bridge target for
 * `window.FinalFinal.heldUndoPressCount`; Swift reads it at the moment a close starts (plan 2a, "Cmd-Z, Cmd-Z, Cmd-W"). No side
 * effects. */
export function heldUndoPressCount(): number {
  return queuedPresses.length;
}

/** Releases the latch and forgets the queue (barrier clear): the timeline the presses were meant for is gone, so no warning is
 * shown for them. Swift is still told they ended (`undoHeldPressSettled`), so a close that counted them as held never waits
 * for them. */
function releaseLatchAndQueue(): void {
  const held = queuedPresses.length;
  latched = false;
  inFlightOpId = null;
  queuedPresses.length = 0;
  clearLatchTimeout();
  postHeldPressesSettled(held);
}

/** Holds a press made while the latch is held; it is routed when Swift's reply for the in-flight request arrives. */
function queuePress(direction: 'undo' | 'redo'): void {
  queuedPresses.push({ direction });
  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'debug',
    message: `[undo-coordinator] ${direction} press queued behind in-flight opId=${inFlightOpId} (queued=${queuedPresses.length})`,
  });
}

/** Routes the queued presses, oldest first, each one deciding afresh against the live document. A structural one takes the latch
 * again and the rest wait for ITS reply; a press that falls through runs the editor's own text undo/redo right here (called
 * directly, so the smart slash two-step is not applied to a held press -- known and logged as rare, plan section 7). */
function drainQueuedPresses(): void {
  while (!latched && queuedPresses.length > 0) {
    const press = queuedPresses.shift();
    const view = getEditorInstance()?.ctx.get(editorViewCtx);
    if (!press || !view) {
      const ended = (press ? 1 : 0) + queuedPresses.length;
      queuedPresses.length = 0;
      postHeldPressesSettled(ended);
      return;
    }
    const decision = decideLiveRouting(view, press.direction);
    traceRoutingRefusal(view, press.direction, decision);
    if (decision.action === 'structural') {
      requestStructural(decision.opId, press.direction, true); // a held press: Swift's close lets it through its closed gate
      return;
    }
    maybeBeepOnRefusal(view, press.direction);
    if (press.direction === 'undo') undo(view.state, view.dispatch);
    else redo(view.state, view.dispatch);
    postHeldPressesSettled(1); // this held press ended here, as a text undo/redo, with no request to Swift
  }
}

/** `held` is true only for a press that was queued behind the latch and is now being sent (drained): the request then carries
 * `held: true`. A press sent directly omits the field. */
function requestStructural(opId: string, direction: 'undo' | 'redo', held = false): void {
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
    dropQueuedPresses('latch timeout');
  }, LATCH_TIMEOUT_MS);
  const messageName = direction === 'undo' ? 'structuralUndoRequested' : 'structuralRedoRequested';
  // Safe no-op if Swift hasn't registered this handler yet (Phase 3+ wires it) -- same
  // optional-chaining pattern as every other Swift bridge postMessage call in this codebase
  // (e.g. contentChanged in main.ts).
  (window as any).webkit?.messageHandlers?.[messageName]?.postMessage(held ? { opId, held: true } : { opId });
}

/**
 * Capture-phase keydown entry point. Called from the merged handler in slash-commands.ts
 * (NOT a second independently-registered listener -- see that file for why). Returns true
 * if the event was consumed (structurally routed, or queued behind the latch); the caller
 * must preventDefault/stopPropagation itself in that case (already done here) and must NOT
 * do so when this returns false -- false means "let it bubble to Milkdown's own keymap".
 */
export function handleUnifiedUndoKeydown(e: KeyboardEvent, view: EditorView, direction: 'undo' | 'redo'): boolean {
  const decision = decideLiveRouting(view, direction);
  traceRoutingRefusal(view, direction, decision);

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
    // Refusal UX (see docs/architecture/unified-undo.md's routing section): about to hand
    // this back to Milkdown's own keymap, which will
    // itself be a silent no-op if there's no text history either -- beep now so the user
    // gets feedback instead of nothing happening at all.
    maybeBeepOnRefusal(view, direction);
    return false;
  }

  e.preventDefault();
  e.stopPropagation();

  if (decision.action === 'swallow') {
    // Latch held. A held-down key sends a stream of auto-repeat keydowns (`e.repeat`) for as long as the undo takes -- dozens
    // on a book -- and queueing them would then undo that many steps. They are consumed (so the editor's own keymap does not
    // run a text undo for them) but not queued and not counted; a separate tap (`repeat` false) still queues, in order.
    if (e.repeat) return true;
    queuePress(direction); // keep the press, route it when Swift's reply arrives (plan D9)
    return true;
  }

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
 * Menu-path entry point (window.FinalFinal.requestUnifiedUndo/requestUnifiedRedo). Menu
 * activation must run the SAME routing decision as the keyboard interceptor --
 * never a direct UnifiedUndoService.performUndo()/performRedo() call from Swift, which
 * would bypass the equality guard. Unlike the keydown path there is no native event to fall
 * through to, so the fallthrough case here directly invokes Milkdown's own undo/redo
 * command -- whenever the timeline has nothing on top (or routing otherwise refuses),
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

  const decision = decideLiveRouting(view, direction);
  traceRoutingRefusal(view, direction, decision);

  if (decision.action === 'swallow') {
    queuePress(direction); // in-flight -- hold the press, matches the keydown path
    return;
  }

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

/** Swift's reply outcome to a structuralUndoRequested/structuralRedoRequested message. */
export type UndoReplyOutcome = 'performed' | 'fallback' | 'failed' | 'cancelled';

/**
 * Swift's reply to a structuralUndoRequested/structuralRedoRequested message (see
 * docs/architecture/unified-undo.md's "Reply protocol (four outcomes)" section; `cancelled` is the fourth outcome, added in
 * Phase 4b part 2):
 * "fallback" means Swift's top entry no longer matched the opId JS sent (a barrier raced
 * the keystroke) -- JS must perform the text undo/redo it suppressed when it preventDefault
 * -ed, never silently drop the keystroke. "performed" means Swift actually restored the
 * structural entry; there is nothing more to do here. "cancelled" means Swift did not run the request because the
 * project is closing or switching (the command was cancelled at the lifecycle barrier, plan A3/A21): it is neither a
 * failure nor a fallback -- the document is left exactly as it is (a text undo replayed here would be written by the closing
 * save, silently removing the user's latest typing) and the presses held behind the request are dropped without any
 * warning, because the window is going away. A reply that arrives while NOT latched
 * (stale/duplicate), or for a stale `opId` while a DIFFERENT request is in flight (checked
 * against `inFlightOpId` below -- N5, Phase B remediation plan), is ignored rather than
 * misapplied.
 */
export function handleUndoReplyFromSwift(
  reply: { opId: string; outcome: UndoReplyOutcome },
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
  if (reply.outcome === 'cancelled') {
    const dropped = queuedPresses.length;
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[undo-coordinator] structural ${direction} cancelled at the lifecycle barrier (opId=${reply.opId}) -- document untouched, dropped ${dropped} held press(es) silently`,
    });
    queuedPresses.length = 0;
    // No warning toast (`undoQueueDropped`): the window is closing. Swift is told the presses ended, so a close that counted
    // them as held does not wait for them.
    postHeldPressesSettled(dropped);
    return;
  }
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
    // Same reasoning for the presses held behind it: routing them against an editor that disagrees with the database would
    // write the disagreement back. Drop them, and tell Swift once (plan A4).
    dropQueuedPresses(`structural ${direction} failed post-commit`);
    return;
  }
  if (reply.outcome === 'fallback') {
    const view = getEditorInstance()?.ctx.get(editorViewCtx);
    if (view) {
      if (direction === 'undo') undo(view.state, view.dispatch);
      else redo(view.state, view.dispatch);
    }
  }
  // The latch is free: route what was pressed while it was held, in order (plan D9).
  drainQueuedPresses();
}

export function receiveUndoOutcome(opId: string, outcome: UndoReplyOutcome): void {
  handleUndoReplyFromSwift({ opId, outcome }, 'undo');
}
export function receiveRedoOutcome(opId: string, outcome: UndoReplyOutcome): void {
  handleUndoReplyFromSwift({ opId, outcome }, 'redo');
}

/**
 * `historyEdited` predicate (see docs/architecture/unified-undo.md's registry/descriptor
 * bridge protocol section; corrected in review -- an earlier draft broke the canonical redo
 * case): fires only for transactions that ADD a NEW history item -- docChanged, not
 * sync-origin (addToHistory:false), not a history replay (prosemirror-history sets its own
 * `historyKey` meta on undo/redo-generated transactions; isHistoryTransaction() is its public
 * detector). Sent only while a structural redo entry exists, per constraint 3 (no
 * per-keystroke cost): the descriptor.redoTopOpId check is a single property read and runs
 * before any of the other (cheap, but not free) checks, so in the steady state (no redo
 * entry) this function costs one property comparison per keystroke and nothing else.
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
