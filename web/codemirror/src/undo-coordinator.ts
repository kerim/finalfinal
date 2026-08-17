// Unified chronological undo -- JS routing module for CodeMirror.
// Mirrored (not shared) in web/milkdown/src/undo-coordinator.ts -- see that file's header
// for why this is two near-identical files rather than one shared module.
//
// Phase 2 skeleton (docs/plans/patient-rewinding-clockwork.md §4.1/§4.2/§4.6/§4.7): builds
// the registry, descriptor, routing decision, in-flight latch, and historyEdited predicate
// with ZERO real structural entries ever recorded. `descriptor.undoTopOpId`/`redoTopOpId`
// never exist in this phase, so every routing decision below falls through to CodeMirror's
// own text undo/redo (@codemirror/commands) unchanged -- this module adds no user-visible
// behavior yet. Phase 3+ starts calling `setUndoDescriptor()`/populating the registry from
// real structural operations (version restore, section delete/duplicate).
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

import { redo, undo } from '@codemirror/commands';
import { type EditorState, type Text, Transaction } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { getEditorView } from './editor-state';

// === Types (plan §4.1) ===

/** One registered structural op's editor-side inverse material. Nothing constructs one of
 * these until Phase 3 -- the type is defined now per the plan so Phase 3 only has to
 * populate the registry, not design its shape. */
export interface UndoRegistryEntry {
  /** Full EditorState captured at op time. Unused in Phase 2 (nothing reads it yet). */
  checkpoint: EditorState;
  /** Document immediately after the op -- the equality target for structural undo (§4.2). */
  postOpDoc: Text;
  /** Document immediately before the op -- the equality target for structural redo. */
  preOpDoc: Text;
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
// DEFERRED (Phase 3, do not fix now): no timeout and no reset-on-project-switch/mode-switch --
// if Swift's reply is ever lost (crash, dropped message), this stays true forever and every
// subsequent Cmd-Z silently swallows. Harmless today (nothing ever sets it), but Phase 3 needs
// either a timeout or a barrier hook that force-clears it.
let latched = false;

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

/** Test-only full reset. Not part of the window.FinalFinal bridge. */
export function resetUndoCoordinatorState(): void {
  registry.clear();
  descriptor = {};
  latched = false;
}

// === Pure routing decision (plan §4.2) ===
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

function docsEqual(a: Text, b: Text): boolean {
  return a.eq(b);
}

function liveRoutingParams(view: EditorView): RoutingParams<Text> {
  return {
    descriptor,
    registry,
    pendingMapsEmpty: true, // no block-sync channel in CodeMirror -- see header
    latched,
    currentDoc: view.state.doc,
    docsEqual,
  };
}

function requestStructural(opId: string, direction: 'undo' | 'redo'): void {
  latched = true;
  const messageName = direction === 'undo' ? 'structuralUndoRequested' : 'structuralRedoRequested';
  // Safe no-op if Swift hasn't registered this handler yet (Phase 3+ wires it) -- same
  // optional-chaining pattern as every other Swift bridge postMessage call in this codebase
  // (e.g. contentChanged in main.ts). Structurally unreachable in Phase 2: descriptor.
  // undoTopOpId/redoTopOpId never exist, so decideUndoRouting/decideRedoRouting never
  // return 'structural' and this function is never called.
  (window as any).webkit?.messageHandlers?.[messageName]?.postMessage({ opId });
}

/**
 * Capture-phase keydown entry point, registered directly in main.ts (no merge point on the
 * CodeMirror side -- see this file's header). Returns true if the event was consumed
 * (structurally routed, or swallowed by the latch); the caller must NOT preventDefault when
 * this returns false -- false means "let it bubble to CodeMirror's own keymap".
 */
export function handleUnifiedUndoKeydown(e: KeyboardEvent, view: EditorView, direction: 'undo' | 'redo'): boolean {
  const decision =
    direction === 'undo' ? decideUndoRouting(liveRoutingParams(view)) : decideRedoRouting(liveRoutingParams(view));

  if (decision.action === 'fallthrough') return false;

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
 * Menu-path entry point (window.FinalFinal.requestUnifiedUndo/requestUnifiedRedo). Plan
 * §4.7: menu activation must run the SAME routing decision as the keyboard interceptor --
 * never a direct UnifiedUndoService.performUndo()/performRedo() call from Swift, which
 * would bypass the equality guard. Unlike the keydown path there is no native event to fall
 * through to, so the fallthrough case here directly invokes CodeMirror's own undo/redo
 * command -- with the always-empty Phase 2 registry, this is the ONLY path ever taken, so
 * Undo/Redo menu clicks behave exactly as they would with no unified-undo wiring at all.
 */
function requestUnified(direction: 'undo' | 'redo'): void {
  const view = getEditorView();
  if (!view) return;

  const decision =
    direction === 'undo' ? decideUndoRouting(liveRoutingParams(view)) : decideRedoRouting(liveRoutingParams(view));

  if (decision.action === 'swallow') return; // in-flight -- drop, matches the keydown path

  if (decision.action === 'fallthrough') {
    if (direction === 'undo') undo(view);
    else redo(view);
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
  reply: { opId: string; outcome: 'performed' | 'fallback' },
  direction: 'undo' | 'redo'
): void {
  if (!latched) return;
  latched = false;
  if (reply.outcome !== 'fallback') return;
  const view = getEditorView();
  if (!view) return;
  if (direction === 'undo') undo(view);
  else redo(view);
}

export function receiveUndoOutcome(opId: string, outcome: 'performed' | 'fallback'): void {
  handleUndoReplyFromSwift({ opId, outcome }, 'undo');
}
export function receiveRedoOutcome(opId: string, outcome: 'performed' | 'fallback'): void {
  handleUndoReplyFromSwift({ opId, outcome }, 'redo');
}

/**
 * §4.6 predicate, corrected per plan §4.1 (an earlier draft broke the canonical redo case):
 * fires only for transactions that ADD a NEW history item -- docChanged, not sync-origin
 * (Transaction.addToHistory annotation === false), not a history replay (@codemirror/commands
 * sets the "undo"/"redo" userEvent on transactions it produces; `isUserEvent` is CodeMirror's
 * public detector, matching or exceeding specificity like `"undo.foo"`). Sent only while a
 * structural redo entry exists, per constraint 3 (no per-keystroke cost): the
 * descriptor.redoTopOpId check is a single property read and runs before any of the other
 * (cheap, but not free) checks, so with Phase 2's permanently-empty descriptor this function
 * costs one property comparison per keystroke and nothing else. Call from the
 * EditorView.updateListener registered in main.ts, once per transaction in the update.
 */
export function maybeNotifyHistoryEdited(tr: Transaction): void {
  if (descriptor.redoTopOpId === undefined) return;
  if (!tr.docChanged) return;
  if (tr.annotation(Transaction.addToHistory) === false) return;
  if (tr.isUserEvent('undo') || tr.isUserEvent('redo')) return;
  (window as any).webkit?.messageHandlers?.historyEdited?.postMessage({});
}
