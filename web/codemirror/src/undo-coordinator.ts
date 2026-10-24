// Unified chronological undo -- JS routing module for CodeMirror.
// Mirrored (not shared) in web/milkdown/src/undo-coordinator.ts -- see that file's header
// for why this is two near-identical files rather than one shared module.
//
// Routing module (docs/architecture/unified-undo.md): owns the registry, descriptor,
// document-equality routing decision, in-flight latch, and historyEdited predicate that
// decide, on every Cmd-Z/Cmd-Shift-Z, whether the next step back is a structural operation
// (version restore, section delete/duplicate/reorder -- handed to Swift) or plain text (left
// to CodeMirror's own text undo/redo, @codemirror/commands). `descriptor.undoTopOpId`/
// `redoTopOpId` reflect whatever is actually on top of the native `UnifiedUndoService`
// stacks; when both are empty (nothing structural recorded, or everything already undone),
// every routing decision falls through unchanged to CodeMirror's own history.
//
// Unlike Milkdown, CodeMirror has no existing capture-phase document keydown interceptor to
// merge into (its "smart slash undo" lives inside a bubble-phase keymap binding, main.ts's
// `Mod-z` entry) -- this module's keydown interceptor is registered as a brand-new
// `document.addEventListener('keydown', ..., true)` listener in main.ts, which is fine
// precisely because CodeMirror has no capture-phase sibling listener it could double-fire
// alongside (see Milkdown's undo-coordinator.ts for why that WOULD matter there).
// CodeMirror also has no block-sync channel at all (BlockSyncService only ever attaches to
// the Milkdown WebView -- see the plan's §2 "Source mode caveat"), so the
// "blockSync pending-change maps are empty" routing condition is trivially always true here.

import { isolateHistory, redo, redoDepth, undo, undoDepth } from '@codemirror/commands';
import { type EditorState, type Text, Transaction } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { clearHistory } from './api';
import type { MarkdownEntryExtras } from './api-structural-markdown';
import { derivedCorrection } from './derived-correction';
import { explainTextDifference } from './derived-equivalence';
import { getEditorView } from './editor-state';

// Real user-transaction counter for the permanent `[UnifiedUndo]` fallthrough log below
// (undo-mode-switch-focus investigation legacy -- kept because it proved genuinely useful
// diagnostic signal, not because it's still under investigation). Same
// `Transaction.addToHistory` provenance marker `maybeAdvanceRegistryOnSyncOriginTx` already
// uses for the opposite check (`=== false`); this counts the complement (`!== false`, i.e.
// NOT a sync-origin/programmatic push) on every doc-changing transaction. Wired into the
// `EditorView.updateListener` in main.ts.
let userTxCount = 0;
export function noteUserTransaction(tr: Transaction): void {
  // P3 (4e, undo-mode-switch-focus second timing gap): a `derivedCorrection`-annotated
  // transaction IS user-undoable (addToHistory !== false) by design, but it isn't a real
  // user keystroke -- exclude it so this diagnostic counter still means what its name says.
  if (tr.docChanged && tr.annotation(Transaction.addToHistory) !== false && !tr.annotation(derivedCorrection)) {
    userTxCount += 1;
  }
}

// === Types (see docs/architecture/unified-undo.md's registry/descriptor bridge protocol
// section) ===

/** One registered structural op's editor-side inverse material, populated by
 * `beginStructuralOp`/`finalizeStructuralOpPostOpDoc` for every real structural op. */
export interface UndoRegistryEntry {
  /** Full EditorState captured at op time. The Markdown undo (`markdownStructuralSwap`, api-structural-markdown.ts, t-4a8fd8af)
   * swaps this whole state back in (`view.setState`) for EVERY entry it undoes -- the editor-first commands' own and the ones the
   * old body recorded through `beginStructuralOp` -- so the section returns with its own text history, as Rich Text's quick undo
   * does. The old body's own undo (regenerated sourceContent + minimal-diff setContent) never reads it. */
  checkpoint: EditorState;
  /** Document immediately after the op -- the equality target for structural undo (see the
   * doc's routing section). */
  postOpDoc: Text;
  /** Document immediately before the op -- the equality target for structural redo. */
  preOpDoc: Text;
  /** True from `beginStructuralOp` until `finalizeStructuralOpPostOpDoc` (or
   * `clearFailedStructuralOpEntry`, which removes the entry entirely) -- explicit mid-op
   * marker, NOT inferred from `postOpDoc === preOpDoc` reference identity. Mirrors Milkdown's
   * undo-coordinator.ts -- see that file's matching doc comment for why a zero-diff op (e.g.
   * a Document Note delete) needs this. Optional (not every test-constructed entry sets it)
   * -- `undefined` reads as `false` (not mid-op), the correct default for a finalized entry. */
  midOp?: boolean;
  /** Set only by an editor-first Markdown command (api-structural-markdown.ts): the request it ran
   * and the ChangeSet it applied. Its presence is what lets the quick redo re-run the command and
   * the redo carry (round 2b) map the redo branch. Absent on entries made by the old body. */
  markdown?: MarkdownEntryExtras;
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
  // In-flight latch held (hazard H7, see docs/architecture/unified-undo.md): drop the
  // keystroke entirely, don't even fall through to the editor's own undo -- a second Cmd-Z
  // while a structural undo is settling
  // must not interleave with it.
  | { action: 'swallow' };

// === Module state ===

const registry = new Map<string, UndoRegistryEntry>();
let descriptor: UndoDescriptor = {};
let latched = false;
/** N5 (minor, Phase B remediation plan): the opId of the specific in-flight request the
 * latch is currently held for -- mirrors Milkdown's undo-coordinator.ts (see its comment for
 * the full rationale: matching only "is the latch held" let a stale/duplicate reply be
 * misapplied to whatever happened to be latched afterward). Set by `requestStructural`,
 * cleared whenever the latch itself clears. */
let inFlightOpId: string | null = null;
/** Belt-and-braces timeout for the latch -- mirrors Milkdown's undo-coordinator.ts, value included (see its comment for the full
 * rationale: a lost Swift reply must not swallow Cmd-Z forever). It is only a hung-app safety net: Swift replies on every path, and a
 * healthy slow undo (a drag's Cmd-Z or a footnoted delete's undo on a long book) can legitimately take several seconds. Since presses
 * made during the latch are HELD (O19), an expiry drops them with the "could not be carried out" notice, so a timeout shorter than a
 * healthy undo would drop a keypress although nothing is wrong. It was 3000 ms before held presses existed. Exported for tests. */
export const LATCH_TIMEOUT_MS = 30000;
let latchTimeoutId: ReturnType<typeof setTimeout> | null = null;

/** Cmd-Z / Cmd-Shift-Z presses made while the in-flight latch was held (O19, mirrors Milkdown's undo-coordinator.ts), oldest first.
 * Each one is routed afresh against the LIVE document when the latch clears -- structural presses and text presses alike, so the
 * order the user pressed them in is kept -- instead of being dropped. */
const queuedPresses: Array<{ direction: 'undo' | 'redo' }> = [];

function clearLatchTimeout(): void {
  if (latchTimeoutId !== null) {
    clearTimeout(latchTimeoutId);
    latchTimeoutId = null;
  }
}

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
 * `clearStructuralUndoState()` (eviction, below), a barrier must not wipe legitimate in-flight
 * text-undo steps, only the now-invalid structural checkpoints/descriptor. See Milkdown's
 * `undo-coordinator.ts` (mirrored file) for the full reasoning. Bridge target for
 * `window.FinalFinal.clearStructuralUndoRegistry`, called by Swift from
 * `UnifiedUndoService.invalidateAll()`. */
export function clearStructuralUndoRegistry(): void {
  clearRegistry();
  setUndoDescriptor({});
  // The barrier replaces the timeline the latch and the queued presses belonged to (a project switch, close, mode switch): a request
  // still in flight will never be answered for it, and a later reply is ignored (`handleUndoReplyFromSwift`'s `!latched` guard).
  // Leaving the latch held would swallow every later press until the safety net fired.
  releaseLatchAndQueue();
}

/** Eviction mini-barrier (see docs/architecture/unified-undo.md's Eviction section): the
 * oldest structural entry just fell off the undo
 * stack at capacity. Clears this editor's OWN text-undo history (`clearHistory`, `./api.ts`)
 * AND removes just that ONE evicted entry from the registry -- pre-boundary text steps must not
 * stay reachable past a boundary the timeline no longer guards against (H1/H2). Note: Markdown structural entries DO swap their
 * `checkpoint` back in (api-structural-markdown.ts), so after this rebuild another entry's checkpoint still carries its own
 * pre-boundary text history and the image widths are not carried (a known, rare gap: 50 structural operations). `clearHistory()`'s
 * full-`EditorState` rebuild (rather than a scoped swap) is the same technique `resetForProjectSwitch()` already uses.
 *
 * Takes the evicted entry's `opId` and calls `deleteRegistryEntry(opId)` (MF-1, Phase 5 review
 * round) -- NOT `clearStructuralUndoRegistry()`/`clearRegistry()`, which wipe every entry. See
 * Milkdown's `undo-coordinator.ts` (mirrored file) for the full reasoning: `record()` calls this
 * closure as the LAST step of `performStructuralOp`, after that same op's own registry entry has
 * already been recorded -- a whole-registry clear here used to wipe it too. Bridge target for
 * `window.FinalFinal.clearStructuralUndoState`, called by Swift from
 * `UnifiedUndoService.record()`'s eviction path via `ContentView`'s `clearEditorHistories`
 * closure. */
export function clearStructuralUndoState(opId: string): void {
  clearHistory();
  deleteRegistryEntry(opId);
}

/** N6 (minor, Phase B remediation plan): mid-sequence forward-op failure cleanup. Removes
 * just the ONE in-flight op's own registry entry (created by `beginStructuralOp`, never
 * finalized because a later step in `performStructuralOp` failed) -- unlike
 * `clearStructuralUndoState` above (eviction), this must NOT clear this editor's own
 * text-undo history: the op failed, but the user's prior typing history is still perfectly
 * valid and must survive the failure. Without this, a failed forward op left the registry
 * entry (a full retained `EditorState`) permanently leaked -- it's keyed by a fresh opId
 * every time, so it's never overwritten and never referenced by the descriptor Swift pushes
 * (a failed op is never `record()`-ed), just dead memory for the rest of the session. */
export function clearFailedStructuralOpEntry(opId: string): void {
  deleteRegistryEntry(opId);
}
export function getUndoDescriptor(): UndoDescriptor {
  return descriptor;
}
/** Bridge target for window.FinalFinal.setUndoDescriptor -- called by Swift's
 * `StructuralUndoController.pushDescriptor()` after every recorded op, undo, and redo. NOT
 * called on a barrier -- barriers reset descriptor state locally via
 * `clearStructuralUndoRegistry()` below instead. */
export function setUndoDescriptor(next: UndoDescriptor): void {
  descriptor = next;
}
export function isLatched(): boolean {
  return latched;
}
export function setLatched(value: boolean): void {
  latched = value;
}
/** Test-only accessor/setter for the in-flight opId (N5). Not part of the
 * window.FinalFinal bridge -- production code only ever sets this via `requestStructural`. */
export function getInFlightOpId(): string | null {
  return inFlightOpId;
}
export function setInFlightOpId(opId: string | null): void {
  inFlightOpId = opId;
}

/** Test-only full reset. Not part of the window.FinalFinal bridge. */
export function resetUndoCoordinatorState(): void {
  registry.clear();
  descriptor = {};
  latched = false;
  inFlightOpId = null;
  queuedPresses.length = 0;
  lastEquivalence = null;
  clearLatchTimeout();
}

// === Pure routing decision (see docs/architecture/unified-undo.md's routing section) ===
// Generic over the doc type so the routing truth-table tests can run against fake
// registries/comparators with no real editor -- the live wrappers below plug in
// CodeMirror's real Text.eq and the real registry/descriptor/latch module state.

export interface RoutingParams<TDoc> {
  descriptor: UndoDescriptor;
  registry: ReadonlyMap<string, { postOpDoc: TDoc; preOpDoc: TDoc }>;
  /** "blockSync pending-change maps are empty" (§4.2). Always true for CodeMirror -- see
   * this file's header. */
  pendingMapsEmpty: boolean;
  latched: boolean;
  currentDoc: TDoc;
  docsEqual: (a: TDoc, b: TDoc) => boolean;
  /** Fallback comparison, consulted ONLY after `docsEqual` has failed: "equal modulo what the app
   * regenerates" (footnote numbers, section anchors, Notes, bibliography -- see
   * derived-equivalence.ts). Optional: absent means exact equality alone, exactly the behaviour before
   * this fallback existed. Mirrors Milkdown's undo-coordinator.ts. */
  docsEquivalent?: (a: TDoc, b: TDoc) => boolean;
  /** The opId of the structural request THIS call is made on behalf of: set only by the swap that
   * carries out a request the keydown/menu path already latched (api-structural-markdown.ts). The
   * latch exists to swallow a SECOND press while the first is in flight; the in-flight request's own
   * re-check is not a second press, so it must not be swallowed by its own latch. Absent for the
   * keydown and menu paths, so for them the latch holds exactly as before. */
  ownRequestOpId?: string;
  /** The opId the latch is currently held for (module state `inFlightOpId`), supplied by the live
   * wrapper so this function stays pure. Only read together with `ownRequestOpId`. */
  inFlightOpId?: string | null;
}

function decideRouting<TDoc>(params: RoutingParams<TDoc>, direction: 'undo' | 'redo'): RoutingDecision {
  // The latch swallows every press but the in-flight request's own re-check (B-1): without the exception
  // the swap's "may I still swap?" question could never be answered while the latch it depends on is up.
  const isOwnRequest = params.ownRequestOpId !== undefined && params.ownRequestOpId === params.inFlightOpId;
  if (params.latched && !isOwnRequest) return { action: 'swallow' };

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

function docsEqual(a: Text, b: Text): boolean {
  return a.eq(b);
}

/** The last fallback comparison made while deciding ONE Cmd-Z / Cmd-Shift-Z (null when none ran:
 * exact equality held, or routing stopped before reaching the comparison). Reset by
 * `decideLiveRouting` before every decision. Mirrors Milkdown's undo-coordinator.ts. */
let lastEquivalence: { result: boolean; ms: number; reason: string | null } | null = null;

/** Longest `reason` the trace line carries (the reason is one short line; this only bounds a pathological one). */
const MAX_REASON_CHARS = 400;

/** The fallback comparison, timed on the app's own clock so the book run can report what it costs. It runs
 * `explainTextDifference` (the comparison itself, returning the reason it said "different", null when
 * equivalent), so a refused Cmd-Z can log WHY; the boolean the routing uses is `reason === null`. */
function textsEquivalentTimed(a: Text, b: Text): boolean {
  const start = performance.now();
  const reason = explainTextDifference(a, b);
  lastEquivalence = {
    result: reason === null,
    ms: performance.now() - start,
    reason: reason === null ? null : reason.slice(0, MAX_REASON_CHARS),
  };
  return reason === null;
}

function liveRoutingParams(view: EditorView, ownRequestOpId?: string): RoutingParams<Text> {
  return {
    descriptor,
    registry,
    pendingMapsEmpty: true, // no block-sync channel in CodeMirror -- see header
    latched,
    currentDoc: view.state.doc,
    docsEqual,
    docsEquivalent: textsEquivalentTimed,
    ownRequestOpId,
    inFlightOpId,
  };
}

/** [STRUCT-TRACE] one line per Cmd-Z / Cmd-Shift-Z that reached the fallback comparison, on the
 * existing `type: 'debug'` errorHandler channel (the same prefix and wording Milkdown's undo
 * coordinator uses, so one log search finds both editors). Never per keystroke. */
function traceRoutingEquivalence(
  direction: 'undo' | 'redo',
  decision: RoutingDecision,
  topOpId: string | undefined,
  totalMs: number
): void {
  // `textsEquivalentTimed` (called from inside the decision) sets this; TypeScript cannot see that
  // assignment, so it would narrow the variable to `null` here without the cast.
  const ran = lastEquivalence as { result: boolean; ms: number; reason: string | null } | null;
  if (ran === null) return;
  try {
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message:
        `[STRUCT-TRACE] routing-equivalence direction=${direction} decision=${decision.action} ` +
        `result=${ran.result} ms=${ran.ms.toFixed(1)} totalMs=${totalMs.toFixed(1)} ` +
        `topOpId=${topOpId === undefined ? 'none' : topOpId.slice(0, 8)}` +
        (ran.reason === null ? '' : ` reason=${ran.reason}`),
    });
  } catch {
    // A diagnostic must never break the undo it observes.
  }
}

/** The ONE live routing decision for a Cmd-Z / Cmd-Shift-Z: the keydown path and the menu path
 * (`requestUnified`) both call it, so both use the fallback comparison and both log it. Runs only on
 * those key presses, never per keystroke. The editor-first Markdown swap (api-structural-markdown.ts)
 * calls it a third time, with its own opId, to re-check that the live document still equals the saved
 * copy after Swift reserved its writer ticket: same function, same comparison, and only that call may
 * pass `ownRequestOpId` (keydown and menu pass nothing, so the latch still holds their presses). */
export function decideLiveRouting(
  view: EditorView,
  direction: 'undo' | 'redo',
  ownRequestOpId?: string
): RoutingDecision {
  const routingStart = performance.now();
  lastEquivalence = null;
  const params = liveRoutingParams(view, ownRequestOpId);
  const decision = direction === 'undo' ? decideUndoRouting(params) : decideRedoRouting(params);
  // The whole decision's time (what Cmd-Z pays per press, not only the fallback comparison), taken before
  // the trace line is built.
  const totalMs = performance.now() - routingStart;
  traceRoutingEquivalence(
    direction,
    decision,
    direction === 'undo' ? descriptor.undoTopOpId : descriptor.redoTopOpId,
    totalMs
  );
  return decision;
}

/** True when CodeMirror's own text undo/redo has nothing to do -- the trigger condition for
 * the refusal beep (a Cmd-Z that would otherwise be a silent no-op; see
 * docs/architecture/unified-undo.md's routing section). */
function hasNoTextHistory(view: EditorView, direction: 'undo' | 'redo'): boolean {
  return direction === 'undo' ? undoDepth(view.state) === 0 : redoDepth(view.state) === 0;
}

/** Refusal UX (see docs/architecture/unified-undo.md's routing section) -- mirrors
 * Milkdown's undo-coordinator.ts. */
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
// Mirrors Milkdown's undo-coordinator.ts. The OLD Source-mode body's own undo never performs a checkpoint swap (it regenerates
// sourceContent from the restored DB instead), so this file has no performStructuralSwap/finishStructuralSwapSettle: it holds the
// registry population for the equality-based routing decision (see the doc's routing section), which is identical regardless of
// which editor performed the op. The Markdown undo (`markdownStructuralSwap`, api-structural-markdown.ts, t-4a8fd8af) does swap
// `entry.checkpoint` back in -- for the entries it records itself and for the ones the old body recorded through
// `beginStructuralOp` -- using this module's registry, latch and `decideLiveRouting` unchanged.

/** Op-sequence step 3: isolate the current history group (H3) and capture the pre-op
 * checkpoint + preOpDoc. `postOpDoc` starts equal to `preOpDoc` as a placeholder;
 * `finalizeStructuralOpPostOpDoc` overwrites it once the op's content push has landed. */
export function beginStructuralOp(opId: string): boolean {
  const view = getEditorView();
  if (!view) return false;
  view.dispatch({ annotations: isolateHistory.of('full') });
  const preOpDoc = view.state.doc;
  setRegistryEntry(opId, { checkpoint: view.state, postOpDoc: preOpDoc, preOpDoc, midOp: true });
  return true;
}

/** Op-sequence step 6/7: capture `postOpDoc` from the current doc, called by Swift right
 * after its own content push (`setContent`) resolves. This deliberately doesn't wait for any
 * later normalization; `maybeAdvanceRegistryOnSyncOriginTx` (§4.6, below -- wired into the
 * `EditorView.updateListener` in main.ts alongside `maybeNotifyHistoryEdited`) is what
 * actually absorbs any sync-origin transaction that lands after this call, by advancing this
 * entry's `postOpDoc`/`preOpDoc` reference forward whenever the doc immediately before such a
 * transaction structurally matches one of them. */
export function finalizeStructuralOpPostOpDoc(opId: string): boolean {
  const view = getEditorView();
  if (!view) return false;
  const entry = registry.get(opId);
  if (!entry) return false;
  registry.set(opId, { ...entry, postOpDoc: view.state.doc, midOp: false });
  return true;
}

/**
 * Derived-content advancement rule (hazard H5, see docs/architecture/unified-undo.md's
 * registry/descriptor bridge protocol section) -- CodeMirror mirror of Milkdown's
 * undo-coordinator.ts function of the same name: when a sync-origin transaction lands
 * (`Transaction.addToHistory` annotation `=== false` -- the established provenance marker),
 * for each registry entry, if the doc BEFORE this transaction (`tr.startState.doc`)
 * structurally equals the entry's `postOpDoc` or `preOpDoc` reference, advance that reference
 * to the doc AFTER this transaction (`tr.newDoc`). Keeps a structural entry's equality target
 * (§4.2) tracking harmless derived-content churn (a delayed bibliography fetch, an async
 * footnote renumber) that lands after the entry was captured, instead of permanently bricking
 * the entry's equality check the moment such a resync fires after the op (H5).
 *
 * CROSS-ENTRY GUARD (found live 2026-08-18, notes.md) -- mirrors Milkdown's undo-coordinator.ts:
 * the mid-op skip used to be scoped to a single entry -- `if (entry.postOpDoc ===
 * entry.preOpDoc) continue`, protecting only an op's OWN entry from its own sequence corrupting
 * itself. That is not enough once two entries can be live in the registry at once (possible
 * since Phase 7 made reorder a tracked op instead of a registry-clearing barrier). Concrete
 * collision: the user restores a section (op A finalizes, `entryA.postOpDoc = DOC_A`), then
 * immediately drag-reorders it (op B begins). Op B's OWN primary content push is a sync-origin
 * transaction with `tr.startState.doc = DOC_A` (nothing changed between A finishing and B
 * starting) and `tr.newDoc = DOC_B`. A single-entry guard only skips B's own (still-placeholder)
 * entry -- it does nothing to stop this same transaction from scanning `entryA` too, finding
 * `entryA.postOpDoc.eq(before)` true (`DOC_A == DOC_A`), and wrongly advancing
 * `entryA.postOpDoc` to `DOC_B`. After the user undoes B (back to `DOC_A`), the routing check
 * for the now-top-of-stack `entryA` needs `entryA.postOpDoc.eq(currentDoc)` -- but `postOpDoc`
 * is now `DOC_B`, not `DOC_A`, so it fails and the second Cmd-Z silently does nothing instead of
 * undoing the restore.
 *
 * Fixed by widening the guard to the whole function: while ANY entry in the registry is
 * currently mid-op (tracked via the explicit `midOp` marker -- see `UndoRegistryEntry`'s doc
 * comment for why reference identity, `postOpDoc === preOpDoc`, was retired as the detector; at
 * most one entry can be mid-op at a time, since `StructuralUndoController.isPerforming`'s latch
 * prevents concurrent structural op sequences), skip advancing EVERY entry for this
 * transaction, not just the mid-op one. This is the rule's actual documented intent: only
 * genuine async derived-content churn landing OUTSIDE of any active op's own sequence window
 * should ever advance another entry -- never a new op's own primary push or its own
 * pre-finalize resyncs reaching back and silently mutating a DIFFERENT, already-finalized
 * entry's equality target.
 *
 * Deliberately disjoint from `maybeNotifyHistoryEdited`'s trigger condition (that one requires
 * the annotation `!== false`; this one requires `=== false`), so call order relative to it in
 * the update-listener loop doesn't matter -- a transaction can only ever satisfy one of the
 * two. Costs one property read (`registry.size === 0`) per transaction in the common case (no
 * structural entries recorded yet), matching constraint 3 (no per-keystroke cost).
 */
export function maybeAdvanceRegistryOnSyncOriginTx(tr: Transaction): void {
  if (registry.size === 0) return;
  // P3 (4e, undo-mode-switch-focus second timing gap): a `derivedCorrection`-annotated
  // transaction is dispatched WITHOUT `addToHistory: false` (it's deliberately
  // user-undoable, §4b) but must still be treated as sync-origin here -- it's an automatic
  // correction, not a real user edit, and a structural entry's postOpDoc/preOpDoc equality
  // target must keep tracking it exactly as it would any other derived refresh. The footnote
  // renumber (api.ts `renumberFootnotes`) is tagged the same way.
  //
  // Why that is safe although the correction is ALSO user-undoable (this was once filed as a
  // residual risk, "undoing it could leave the live doc unequal to postOpDoc"): a correction is
  // only absorbed when the doc equals the entry's postOpDoc (or preOpDoc) right before it, and
  // while the doc equals postOpDoc, Cmd-Z routes to the structural undo (routing is by document
  // equality) before any text undo of the correction could run. The correction's own undo step
  // is only reachable after the user has really edited -- the doc then differs from every saved
  // copy, and structural routing stays off until their own text undo brings it back exactly.
  if (tr.annotation(Transaction.addToHistory) !== false && !tr.annotation(derivedCorrection)) return;
  if (!tr.docChanged) return;

  // Whole-function mid-op guard (see doc comment above): if ANY entry is currently mid-op, this
  // transaction could be that op's own primary push (or one of its own pre-finalize resyncs)
  // reaching back onto a DIFFERENT, already-finalized entry -- never advance anything until the
  // in-flight op has finalized. Exact, not a heuristic: at most one entry is ever mid-op at a
  // time (StructuralUndoController.isPerforming's latch).
  const anyMidOp = [...registry.values()].some((entry) => entry.midOp);
  if (anyMidOp) return;

  const before = tr.startState.doc;
  const after = tr.newDoc;
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

/** Test-only: the directions of the presses queued behind the latch right now, oldest first. */
export function getQueuedPressDirections(): Array<'undo' | 'redo'> {
  return queuedPresses.map((press) => press.direction);
}

/** Tells Swift that `count` presses it may be counting as held (`heldUndoPressCount`) ended WITHOUT a request to Swift: they fell
 * through to a plain text undo/redo, or were dropped. Same message name and payload as Milkdown's. A no-op for 0. */
function postHeldPressesSettled(count: number): void {
  if (count <= 0) return;
  (window as any).webkit?.messageHandlers?.undoHeldPressSettled?.postMessage({ count });
}

/** Throws away the presses queued behind the latch and tells Swift ONCE, so it can show its one-line warning. Used by the latch
 * timeout and by a failed reply; a no-op when nothing is queued. Messages: `undoQueueDropped {count}` and `undoHeldPressSettled
 * {count}`, the names and payloads Milkdown posts. */
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

/** How many Cmd-Z / Cmd-Shift-Z presses are being held behind the in-flight latch right now (0 when none). Bridge target for
 * `window.FinalFinal.heldUndoPressCount`; Swift reads it at the moment a close starts. No side effects. */
export function heldUndoPressCount(): number {
  return queuedPresses.length;
}

/** Releases the latch and forgets the queue (barrier clear): the timeline the presses were meant for is gone, so no warning is shown
 * for them. Swift is still told they ended (`undoHeldPressSettled`), so a close that counted them as held never waits for them. */
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

/** Routes the queued presses, oldest first, each one deciding afresh against the LIVE document. A structural one takes the latch
 * again and the rest wait for ITS reply; a press that falls through runs the editor's own text undo/redo right here (called
 * directly, so the smart slash two-step is not applied to a held press -- as in Milkdown). */
function drainQueuedPresses(): void {
  while (!latched && queuedPresses.length > 0) {
    const press = queuedPresses.shift();
    const view = getEditorView();
    if (!press || !view) {
      const ended = (press ? 1 : 0) + queuedPresses.length;
      queuedPresses.length = 0;
      postHeldPressesSettled(ended);
      return;
    }
    const decision = decideLiveRouting(view, press.direction);
    if (decision.action === 'structural') {
      requestStructural(decision.opId, press.direction, true); // a held press: the request carries `held: true`
      return;
    }
    maybeBeepOnRefusal(view, press.direction);
    if (press.direction === 'undo') undo(view);
    else redo(view);
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
 * Capture-phase keydown entry point, registered directly in main.ts (no merge point on the
 * CodeMirror side -- see this file's header). Returns true if the event was consumed
 * (structurally routed, or swallowed by the latch); the caller must NOT preventDefault when
 * this returns false -- false means "let it bubble to CodeMirror's own keymap".
 */
export function handleUnifiedUndoKeydown(e: KeyboardEvent, view: EditorView, direction: 'undo' | 'redo'): boolean {
  const decision = decideLiveRouting(view, direction);

  // Permanent routing/history visibility (undo-mode-switch-focus investigation legacy --
  // kept because it proved useful for diagnosing undo behavior generally, not because it's
  // still under investigation; DOM-focus state was checked extensively during that
  // investigation and confirmed never the actual defect, so it's no longer logged here).
  // NOT the actual undo()/redo() call -- this function never makes it for the keydown path
  // (CodeMirror's own `Mod-z` keymap binding in main.ts does, after this returns false and
  // the event bubbles); see that keymap's own command-level logging for the real return
  // value + before/after doc length on THIS path, and `requestUnified` below for the
  // RPC/menu path's (which DOES call undo()/redo() directly, right here).
  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'debug',
    message:
      `[UnifiedUndo] keydown direction=${direction} decision=${decision.action} ` +
      `undoDepth=${undoDepth(view.state)} redoDepth=${redoDepth(view.state)} ` +
      `docLength=${view.state.doc.length} userTxCount=${userTxCount}`,
  });

  if (decision.action === 'fallthrough') {
    maybeBeepOnRefusal(view, direction);
    return false;
  }

  e.preventDefault();
  e.stopPropagation();

  if (decision.action === 'swallow') {
    // Latch held. A held-down key sends a stream of auto-repeat keydowns for as long as the undo takes; queueing them would undo that
    // many steps. They are consumed (so the editor's own keymap does not run a text undo for them) but not queued and not counted; a
    // separate tap (`repeat` false) still queues, in order. Mirrors Milkdown.
    if (e.repeat) return true;
    queuePress(direction); // keep the press, route it when Swift's reply arrives (O19)
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
 * through to CodeMirror's own keymap regardless), but would have silently broken structural
 * redo the moment Phase 3 wires real ops. Call this from the capture-phase listener in
 * main.ts instead of comparing `e.key` inline.
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
 * activation must run the SAME routing decision as the keyboard interceptor -- never a
 * direct UnifiedUndoService.performUndo()/performRedo() call from Swift, which would bypass
 * the equality guard. Unlike the keydown path there is no native event to fall through to,
 * so the fallthrough case here directly invokes CodeMirror's own undo/redo command --
 * whenever the timeline has nothing on top (or routing otherwise refuses), Undo/Redo menu
 * clicks behave exactly as they would with no unified-undo wiring at all.
 */
function requestUnified(direction: 'undo' | 'redo'): void {
  const view = getEditorView();
  if (!view) return;

  const decision = decideLiveRouting(view, direction);

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
    const docLengthBefore = view.state.doc.length;
    const commandReturned = direction === 'undo' ? undo(view) : redo(view);
    const docLengthAfter = view.state.doc.length;
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
 * docs/architecture/unified-undo.md's "Reply protocol (four outcomes)" section):
 * "fallback" means Swift's top entry no longer matched the opId JS sent (a barrier raced
 * the keystroke) -- JS must perform the text undo/redo it suppressed when it preventDefault
 * -ed, never silently drop the keystroke. "performed" means Swift actually restored the
 * structural entry; there is nothing more to do here. "cancelled" means Swift did not run the request because the
 * project is closing or switching: like "performed" it replays nothing (only "fallback" replays a text undo/redo), and
 * the latch is cleared. A reply that arrives while NOT latched
 * (stale/duplicate), or for a stale `opId` while a DIFFERENT request is in flight (checked
 * against `inFlightOpId` below -- N5, Phase B remediation plan), is ignored rather than
 * misapplied.
 */
export function handleUndoReplyFromSwift(
  reply: { opId: string; outcome: UndoReplyOutcome },
  direction: 'undo' | 'redo'
): void {
  if (!latched) return;
  // N5 (minor, Phase B remediation plan) -- mirrors Milkdown's undo-coordinator.ts: match
  // against the specific in-flight opId, not just "is the latch held". See that file's
  // matching comment for the full rationale.
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
    // The project is closing or switching: the document is left exactly as it is, and the presses held behind the request are
    // dropped WITHOUT a warning (the window is going away). Swift is still told they ended, so a close that counted them as held
    // does not wait for them. Mirrors Milkdown.
    const dropped = queuedPresses.length;
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[undo-coordinator] structural ${direction} cancelled at the lifecycle barrier (opId=${reply.opId}) -- document untouched, dropped ${dropped} held press(es) silently`,
    });
    queuedPresses.length = 0;
    postHeldPressesSettled(dropped);
    return;
  }
  if (reply.outcome === 'failed') {
    // Post-commit failure (plan review round MF-4) -- mirrors Milkdown's undo-coordinator.ts.
    // The DB has already been restored, but the Source-mode settle (the `setContent` content
    // push) didn't complete. Replaying a plain text-undo/redo here (the `fallback` handling
    // below) would apply an EXTRA edit on top of an already-committed DB write. Report and
    // stop -- do not touch editor content.
    (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'debug',
      message: `[undo-coordinator] structural ${direction} failed post-commit (opId=${reply.opId}) -- NOT replaying a text ${direction} on top of an already-restored DB`,
    });
    // Same reasoning for the presses held behind it: routing them against an editor that disagrees with the database would write the
    // disagreement back. Drop them, and tell Swift once.
    dropQueuedPresses(`structural ${direction} failed post-commit`);
    return;
  }
  if (reply.outcome === 'fallback') {
    const view = getEditorView();
    if (view) {
      if (direction === 'undo') undo(view);
      else redo(view);
    }
  }
  // The latch is free: route what was pressed while it was held, in order (O19).
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
 * sync-origin (Transaction.addToHistory annotation === false), not a history replay
 * (@codemirror/commands sets the "undo"/"redo" userEvent on transactions it produces;
 * `isUserEvent` is CodeMirror's public detector, matching or exceeding specificity like
 * `"undo.foo"`). Sent only while a structural redo entry exists, per constraint 3 (no
 * per-keystroke cost): the descriptor.redoTopOpId check is a single property read and runs
 * before any of the other (cheap, but not free) checks, so in the steady state (no redo
 * entry) this function costs one property comparison per keystroke and nothing else. Call
 * from the EditorView.updateListener registered in main.ts, once per transaction in the
 * update.
 */
export function maybeNotifyHistoryEdited(tr: Transaction): void {
  if (descriptor.redoTopOpId === undefined) return;
  if (!tr.docChanged) return;
  // P3 (4e, undo-mode-switch-focus second timing gap): a `derivedCorrection`-annotated
  // transaction IS user-undoable (so it does NOT hit the addToHistory===false check just
  // above) but it's still an automatic correction, not a genuine user edit -- must not
  // count as "the user edited history" for the redo-branch invalidation this guards.
  if (tr.annotation(Transaction.addToHistory) === false || tr.annotation(derivedCorrection)) return;
  if (tr.isUserEvent('undo') || tr.isUserEvent('redo')) return;
  (window as any).webkit?.messageHandlers?.historyEdited?.postMessage({});
}
