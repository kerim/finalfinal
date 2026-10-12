// @vitest-environment jsdom
// Routing/registry test suite for undo-coordinator.ts (see docs/architecture/unified-undo.md):
// (1) a routing truth table against fake registries, both empty and populated -- pure, no
// real editor needed; (2) live-wiring proofs against a real CodeMirror EditorView, including
// the always-empty-registry case where every path (keyboard interceptor, menu-path
// requestUnifiedUndo/Redo, the Swift reply handler) falls through to CodeMirror's own
// undo/redo unchanged; and (3) registry-advancement, eviction, and latch self-clear
// regression tests for real production bugs found after real structural ops shipped.

import { history, redoDepth, undo, undoDepth } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorState, Text, Transaction } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { renumberFootnotes, setContent } from '../api';
import { explainTextDifference, textsEquivalentIgnoringDerived } from '../derived-equivalence';
import { setEditorExtensions, setEditorView } from '../editor-state';
import { noteTransactionForEditSpanTracking, resetRecentUserEditSpanForTests } from '../recent-edit-span';
import {
  beginStructuralOp,
  clearStructuralUndoRegistry,
  clearStructuralUndoState,
  decideRedoRouting,
  decideUndoRouting,
  finalizeStructuralOpPostOpDoc,
  getInFlightOpId,
  getRegistry,
  getUndoDescriptor,
  handleGlobalUndoRedoKeydown,
  handleUndoReplyFromSwift,
  handleUnifiedUndoKeydown,
  isLatched,
  maybeAdvanceRegistryOnSyncOriginTx,
  maybeNotifyHistoryEdited,
  noteUserTransaction,
  requestUnifiedRedo,
  requestUnifiedUndo,
  resetUndoCoordinatorState,
  setInFlightOpId,
  setLatched,
  setRegistryEntry,
  setUndoDescriptor,
} from '../undo-coordinator';

// jsdom has no real layout engine and doesn't implement Range.prototype.getBoundingClientRect --
// clearStructuralUndoState() below calls clearHistory(), which calls installLineHeightFix(),
// which measures dummy elements via the Range API. Polyfill to a zeroed DOMRect (identical to
// clear-history.test.ts's rationale) so that measurement path doesn't throw here.
beforeAll(() => {
  if (typeof Range !== 'undefined' && !Range.prototype.getBoundingClientRect) {
    Range.prototype.getBoundingClientRect = function (this: Range): DOMRect {
      return {
        x: 0,
        y: 0,
        width: 0,
        height: 0,
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        toJSON() {
          return {};
        },
      } as DOMRect;
    };
  }
});

// === (1) Pure routing truth table -- fake string "docs", no editor at all ===
// Identical in shape to web/milkdown/src/__tests__/undo-coordinator.test.ts's truth table --
// the pure decideUndoRouting/decideRedoRouting logic is intentionally mirrored line-for-line
// between the two editors (see undo-coordinator.ts's header in each package).

describe('decideUndoRouting / decideRedoRouting (pure truth table, fake registries)', () => {
  const docsEqual = (a: string, b: string) => a === b;

  it('routes structural when the top entry exists, maps are empty, and the doc matches postOpDoc', () => {
    const registry = new Map([['op-1', { postOpDoc: 'doc-v2', preOpDoc: 'doc-v1' }]]);
    const decision = decideUndoRouting({
      descriptor: { undoTopOpId: 'op-1' },
      registry,
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: 'doc-v2',
      docsEqual,
    });
    expect(decision).toEqual({ action: 'structural', opId: 'op-1' });
  });

  it("falls through when no structural undo top exists (Phase 2's permanent state)", () => {
    const decision = decideUndoRouting({
      descriptor: {},
      registry: new Map(),
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: 'doc-v1',
      docsEqual,
    });
    expect(decision).toEqual({ action: 'fallthrough' });
  });

  it('falls through when the registry is missing the entry the descriptor points at', () => {
    const decision = decideUndoRouting({
      descriptor: { undoTopOpId: 'op-missing' },
      registry: new Map(),
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: 'doc-v1',
      docsEqual,
    });
    expect(decision).toEqual({ action: 'fallthrough' });
  });

  it('falls through when a newer text edit is present (doc no longer equals postOpDoc)', () => {
    const registry = new Map([['op-1', { postOpDoc: 'doc-v2', preOpDoc: 'doc-v1' }]]);
    const decision = decideUndoRouting({
      descriptor: { undoTopOpId: 'op-1' },
      registry,
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: 'doc-v3', // user typed more after the op
      docsEqual,
    });
    expect(decision).toEqual({ action: 'fallthrough' });
  });

  it('falls through when pendingMapsEmpty is false (parameter still respected even though CodeMirror always passes true live)', () => {
    const registry = new Map([['op-1', { postOpDoc: 'doc-v2', preOpDoc: 'doc-v1' }]]);
    const decision = decideUndoRouting({
      descriptor: { undoTopOpId: 'op-1' },
      registry,
      pendingMapsEmpty: false,
      latched: false,
      currentDoc: 'doc-v2',
      docsEqual,
    });
    expect(decision).toEqual({ action: 'fallthrough' });
  });

  it('swallows (never falls through) when the in-flight latch is already held', () => {
    const registry = new Map([['op-1', { postOpDoc: 'doc-v2', preOpDoc: 'doc-v1' }]]);
    const decision = decideUndoRouting({
      descriptor: { undoTopOpId: 'op-1' },
      registry,
      pendingMapsEmpty: true,
      latched: true,
      currentDoc: 'doc-v2',
      docsEqual,
    });
    expect(decision).toEqual({ action: 'swallow' });
  });

  it('redo routes structural when the top entry exists and the doc matches preOpDoc', () => {
    const registry = new Map([['op-1', { postOpDoc: 'doc-v2', preOpDoc: 'doc-v1' }]]);
    const decision = decideRedoRouting({
      descriptor: { redoTopOpId: 'op-1' },
      registry,
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: 'doc-v1',
      docsEqual,
    });
    expect(decision).toEqual({ action: 'structural', opId: 'op-1' });
  });

  it('redo falls through when no structural redo top exists', () => {
    const decision = decideRedoRouting({
      descriptor: {},
      registry: new Map(),
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: 'doc-v1',
      docsEqual,
    });
    expect(decision).toEqual({ action: 'fallthrough' });
  });

  it('redo falls through when a newer text edit means the doc no longer equals preOpDoc', () => {
    const registry = new Map([['op-1', { postOpDoc: 'doc-v2', preOpDoc: 'doc-v1' }]]);
    const decision = decideRedoRouting({
      descriptor: { redoTopOpId: 'op-1' },
      registry,
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: 'doc-v0', // does not match preOpDoc
      docsEqual,
    });
    expect(decision).toEqual({ action: 'fallthrough' });
  });

  it('redo falls through when the registry is missing the entry the descriptor points at', () => {
    const decision = decideRedoRouting({
      descriptor: { redoTopOpId: 'op-missing' },
      registry: new Map(),
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: 'doc-v1',
      docsEqual,
    });
    expect(decision).toEqual({ action: 'fallthrough' });
  });

  it('redo falls through when pendingMapsEmpty is false', () => {
    const registry = new Map([['op-1', { postOpDoc: 'doc-v2', preOpDoc: 'doc-v1' }]]);
    const decision = decideRedoRouting({
      descriptor: { redoTopOpId: 'op-1' },
      registry,
      pendingMapsEmpty: false,
      latched: false,
      currentDoc: 'doc-v1',
      docsEqual,
    });
    expect(decision).toEqual({ action: 'fallthrough' });
  });

  it('redo swallows (never falls through) when the in-flight latch is already held', () => {
    const registry = new Map([['op-1', { postOpDoc: 'doc-v2', preOpDoc: 'doc-v1' }]]);
    const decision = decideRedoRouting({
      descriptor: { redoTopOpId: 'op-1' },
      registry,
      pendingMapsEmpty: true,
      latched: true,
      currentDoc: 'doc-v1',
      docsEqual,
    });
    expect(decision).toEqual({ action: 'swallow' });
  });
});

// === (2) Live wiring -- real EditorView, empty registry (Phase 2's permanent state) ===

describe('undo-coordinator live wiring (real CodeMirror EditorView, always-empty Phase 2 registry)', () => {
  let view: EditorView | null = null;

  afterEach(() => {
    setEditorView(null);
    setEditorExtensions([]);
    if (view) {
      view.destroy();
      view = null;
    }
    resetUndoCoordinatorState();
    delete (window as any).webkit;
  });

  function makeEditor(doc: string): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const extensions = [markdown({ base: markdownLanguage }), history()];
    const v = new EditorView({
      state: EditorState.create({ doc, extensions }),
      parent: div,
    });
    view = v;
    setEditorView(v);
    setEditorExtensions(extensions);
    return v;
  }

  it('handleUnifiedUndoKeydown returns false (fallthrough) and does not preventDefault, leaving the editor keymap untouched', () => {
    const v = makeEditor('Paragraph one.');
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    const consumed = handleUnifiedUndoKeydown(event, v, 'undo');

    expect(consumed).toBe(false);
    expect(event.defaultPrevented).toBe(false);
  });

  it("requestUnifiedUndo (menu path) performs the editor's own undo when the registry is empty", () => {
    const v = makeEditor('Paragraph one.');
    v.dispatch({ changes: { from: 0, insert: 'X' } });
    expect(undoDepth(v.state)).toBeGreaterThan(0);

    requestUnifiedUndo();

    expect(undoDepth(v.state)).toBe(0);
    expect(redoDepth(v.state)).toBeGreaterThan(0);
  });

  it("requestUnifiedRedo (menu path) performs the editor's own redo when the registry is empty", () => {
    const v = makeEditor('Paragraph one.');
    v.dispatch({ changes: { from: 0, insert: 'X' } });
    requestUnifiedUndo();
    expect(redoDepth(v.state)).toBeGreaterThan(0);

    requestUnifiedRedo();

    expect(redoDepth(v.state)).toBe(0);
    expect(undoDepth(v.state)).toBeGreaterThan(0);
  });

  it("the in-flight latch swallows a second Cmd-Z instead of falling through to the editor's own undo", () => {
    const v = makeEditor('Paragraph one.');
    v.dispatch({ changes: { from: 0, insert: 'X' } });
    const depthBefore = undoDepth(v.state);
    setLatched(true);
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    const consumed = handleUnifiedUndoKeydown(event, v, 'undo');

    expect(consumed).toBe(true); // swallowed, not fallen through
    expect(event.defaultPrevented).toBe(true);
    expect(undoDepth(v.state)).toBe(depthBefore); // editor's own undo did NOT run
  });

  it('handleUnifiedUndoKeydown fires preventDefault, holds the latch, and posts structuralUndoRequested with the right opId when routing decides structural', () => {
    const v = makeEditor('Paragraph one.');
    setRegistryEntry('op-42', { checkpoint: v.state as any, postOpDoc: v.state.doc, preOpDoc: v.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-42' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage } } };
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    const consumed = handleUnifiedUndoKeydown(event, v, 'undo');

    expect(consumed).toBe(true);
    expect(event.defaultPrevented).toBe(true);
    expect(isLatched()).toBe(true);
    expect(postMessage).toHaveBeenCalledWith({ opId: 'op-42' });
  });

  it('handleUnifiedUndoKeydown posts structuralRedoRequested (not structuralUndoRequested) for the redo direction', () => {
    const v = makeEditor('Paragraph one.');
    setRegistryEntry('op-7', { checkpoint: v.state as any, postOpDoc: v.state.doc, preOpDoc: v.state.doc });
    setUndoDescriptor({ redoTopOpId: 'op-7' });
    const undoPost = vi.fn();
    const redoPost = vi.fn();
    (window as any).webkit = {
      messageHandlers: {
        structuralUndoRequested: { postMessage: undoPost },
        structuralRedoRequested: { postMessage: redoPost },
      },
    };
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, shiftKey: true, cancelable: true });

    const consumed = handleUnifiedUndoKeydown(event, v, 'redo');

    expect(consumed).toBe(true);
    expect(event.defaultPrevented).toBe(true);
    expect(isLatched()).toBe(true);
    expect(redoPost).toHaveBeenCalledWith({ opId: 'op-7' });
    expect(undoPost).not.toHaveBeenCalled();
  });

  it('handleGlobalUndoRedoKeydown normalizes a genuinely shifted Cmd-Shift-Z (key: "Z", not "z") to the redo direction', () => {
    const v = makeEditor('Paragraph one.');
    setRegistryEntry('op-9', { checkpoint: v.state as any, postOpDoc: v.state.doc, preOpDoc: v.state.doc });
    // Deliberately set up ONLY a redo-capable descriptor (no undoTopOpId) -- if the key
    // normalization regressed back to a bare `e.key === 'z'` comparison (review finding),
    // this genuinely-shifted event's uppercase 'Z' would fail that comparison entirely, the
    // 'y'-branch wouldn't match either, and handleGlobalUndoRedoKeydown would return false
    // with nothing posted -- a real KeyboardEvent built with `key: 'Z'`, not a hand-set
    // `key: 'z'` plus a separately-interpreted shiftKey, is what actually exercises the bug.
    setUndoDescriptor({ redoTopOpId: 'op-9' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { structuralRedoRequested: { postMessage } } };
    const event = new KeyboardEvent('keydown', { key: 'Z', metaKey: true, shiftKey: true, cancelable: true });

    const consumed = handleGlobalUndoRedoKeydown(event, v);

    expect(consumed).toBe(true);
    expect(event.defaultPrevented).toBe(true);
    expect(postMessage).toHaveBeenCalledWith({ opId: 'op-9' });
  });

  it('handleUndoReplyFromSwift performs the suppressed text undo on a "fallback" reply and releases the latch', () => {
    const v = makeEditor('Paragraph one.');
    v.dispatch({ changes: { from: 0, insert: 'X' } });
    setLatched(true);
    setInFlightOpId('op-1');

    handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'fallback' }, 'undo');

    expect(isLatched()).toBe(false);
    expect(undoDepth(v.state)).toBe(0);
  });

  it('handleUndoReplyFromSwift does nothing beyond releasing the latch on a "performed" reply', () => {
    const v = makeEditor('Paragraph one.');
    v.dispatch({ changes: { from: 0, insert: 'X' } });
    const depthBefore = undoDepth(v.state);
    setLatched(true);
    setInFlightOpId('op-1');

    handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'performed' }, 'undo');

    expect(isLatched()).toBe(false);
    expect(undoDepth(v.state)).toBe(depthBefore); // no extra undo performed
  });

  it('handleUndoReplyFromSwift ignores a reply that arrives while not latched (stale/duplicate reply guard)', () => {
    expect(isLatched()).toBe(false);

    expect(() => handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'fallback' }, 'undo')).not.toThrow();

    expect(isLatched()).toBe(false);
  });

  // === N5 (Phase B remediation plan): reply must match the specific in-flight opId ===

  it('handleUndoReplyFromSwift ignores a reply for a stale opId even while the latch is held for a DIFFERENT request', () => {
    const v = makeEditor('Paragraph one.');
    v.dispatch({ changes: { from: 0, insert: 'X' } });
    const depthBefore = undoDepth(v.state);
    setLatched(true);
    setInFlightOpId('op-current');

    handleUndoReplyFromSwift({ opId: 'op-stale', outcome: 'fallback' }, 'undo');

    expect(undoDepth(v.state)).toBe(depthBefore);
    expect(isLatched()).toBe(true);
    expect(getInFlightOpId()).toBe('op-current');
  });

  it('a genuine reply for the actual in-flight opId still works correctly (control for the mismatch test above)', () => {
    const v = makeEditor('Paragraph one.');
    v.dispatch({ changes: { from: 0, insert: 'X' } });
    setLatched(true);
    setInFlightOpId('op-current');

    handleUndoReplyFromSwift({ opId: 'op-current', outcome: 'fallback' }, 'undo');

    expect(undoDepth(v.state)).toBe(0);
    expect(isLatched()).toBe(false);
    expect(getInFlightOpId()).toBe(null);
  });

  // === historyEdited predicate (plan §4.1/§4.6) ===

  it('maybeNotifyHistoryEdited does not post when no structural redo entry exists (constraint 3: zero per-keystroke cost in the steady state)', () => {
    const v = makeEditor('Paragraph one.');
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { historyEdited: { postMessage } } };
    const tr = v.state.update({ changes: { from: 0, insert: 'X' } });

    maybeNotifyHistoryEdited(tr);

    expect(postMessage).not.toHaveBeenCalled();
  });

  it('maybeNotifyHistoryEdited posts when a real doc-changing edit lands while a structural redo entry exists', () => {
    const v = makeEditor('Paragraph one.');
    setUndoDescriptor({ redoTopOpId: 'op-1' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { historyEdited: { postMessage } } };
    const tr = v.state.update({ changes: { from: 0, insert: 'X' } });

    maybeNotifyHistoryEdited(tr);

    expect(postMessage).toHaveBeenCalledTimes(1);
  });

  it('maybeNotifyHistoryEdited does not post for a sync-origin transaction (Transaction.addToHistory === false)', () => {
    const v = makeEditor('Paragraph one.');
    setUndoDescriptor({ redoTopOpId: 'op-1' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { historyEdited: { postMessage } } };
    const tr = v.state.update({
      changes: { from: 0, insert: 'X' },
      annotations: Transaction.addToHistory.of(false),
    });

    maybeNotifyHistoryEdited(tr);

    expect(postMessage).not.toHaveBeenCalled();
  });

  it('maybeNotifyHistoryEdited does not post for an undo-replay transaction -- pins the canonical redo half (plan §4.1, found wrong twice in review)', () => {
    const v = makeEditor('Paragraph one.');
    v.dispatch({ changes: { from: 0, insert: 'X' } });
    setUndoDescriptor({ redoTopOpId: 'op-1' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { historyEdited: { postMessage } } };

    // Route the REAL transaction @codemirror/commands's undo() produces through the
    // predicate -- its "undo" userEvent is set by the real command, not fakeable by hand.
    undo({
      state: v.state,
      dispatch: (tr) => {
        v.update([tr]);
        maybeNotifyHistoryEdited(tr);
      },
    });

    expect(postMessage).not.toHaveBeenCalled();
  });

  // === §4.6 advancement rule (maybeAdvanceRegistryOnSyncOriginTx) ===
  // Round-5 must-fix: mirrors web/milkdown/src/__tests__/undo-coordinator.test.ts's suite --
  // the rule was documented (§4.6) and even claimed "already shipped" in a stale comment, but
  // no code ever implemented it.

  it('maybeAdvanceRegistryOnSyncOriginTx does nothing when the registry is empty (constraint 3: near-zero per-keystroke cost)', () => {
    const v = makeEditor('Paragraph one.');
    const tr = v.state.update({
      changes: { from: 0, insert: 'X' },
      annotations: Transaction.addToHistory.of(false),
    });

    expect(() => maybeAdvanceRegistryOnSyncOriginTx(tr)).not.toThrow();
    expect(getRegistry().size).toBe(0);
  });

  it('maybeAdvanceRegistryOnSyncOriginTx does not advance for a non-sync-origin transaction (addToHistory annotation not false)', () => {
    const v = makeEditor('Paragraph one.');
    const preOpDoc = v.state.doc;
    setRegistryEntry('op-1', { checkpoint: v.state as any, postOpDoc: preOpDoc, preOpDoc });
    const tr = v.state.update({ changes: { from: 0, insert: 'X' } });

    maybeAdvanceRegistryOnSyncOriginTx(tr);

    expect(getRegistry().get('op-1')?.postOpDoc).toBe(preOpDoc);
  });

  it('maybeAdvanceRegistryOnSyncOriginTx advances postOpDoc when the doc before a sync-origin transaction structurally matches it', () => {
    const v = makeEditor('Paragraph one.');
    const opStartDoc = v.state.doc;
    // Simulate the op's own content push landing (this is what postOpDoc gets captured as).
    v.dispatch({ changes: { from: 0, insert: 'OP' }, annotations: Transaction.addToHistory.of(false) });
    const postOpDoc = v.state.doc;
    setRegistryEntry('op-1', { checkpoint: v.state as any, postOpDoc, preOpDoc: opStartDoc });

    // A later sync-origin transaction -- a delayed bibliography/footnote resync -- rewrites
    // the doc again (H5).
    const resyncTr = v.state.update({
      changes: { from: 0, insert: 'RESYNC' },
      annotations: Transaction.addToHistory.of(false),
    });
    v.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    const entry = getRegistry().get('op-1');
    expect(entry?.postOpDoc.eq(v.state.doc)).toBe(true);
    expect(entry?.postOpDoc.eq(postOpDoc)).toBe(false);
    // preOpDoc is untouched -- the resync's "before" doc matched postOpDoc, not preOpDoc.
    expect(entry?.preOpDoc.eq(opStartDoc)).toBe(true);
  });

  it('maybeAdvanceRegistryOnSyncOriginTx advances preOpDoc (redo target) the same way', () => {
    const v = makeEditor('Paragraph one.');
    const preOpDoc = v.state.doc;

    // A later sync-origin transaction whose "before" doc is preOpDoc itself.
    const resyncTr = v.state.update({
      changes: { from: 0, insert: 'RESYNC' },
      annotations: Transaction.addToHistory.of(false),
    });
    v.dispatch(resyncTr);

    // Finalized entry shape: postOpDoc is a DISTINCT object from preOpDoc, as it is once
    // finalizeStructuralOpPostOpDoc has run -- NOT the beginStructuralOp mid-op placeholder
    // shape (postOpDoc === preOpDoc by reference). A placeholder-shaped entry is inert to
    // advancement (see the regression test below) -- this test exercises the real
    // advancement path on an entry that's actually eligible for it.
    const postOpDoc = v.state.doc;
    setRegistryEntry('op-1', { checkpoint: v.state as any, postOpDoc, preOpDoc });

    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    expect(getRegistry().get('op-1')?.preOpDoc.eq(resyncTr.newDoc)).toBe(true);
  });

  it("regression: the op's OWN content push (still mid-op, before finalizeStructuralOpPostOpDoc has run) must not corrupt preOpDoc -- the exact live production bug behind redo2 hanging (notes.md 2026-08-18)", () => {
    const v = makeEditor('Paragraph one.');
    const opStartDoc = v.state.doc;

    // Op-sequence step 3: begin the op. Registers the mid-op placeholder entry --
    // postOpDoc === preOpDoc by reference, per beginStructuralOp's doc comment.
    expect(beginStructuralOp('op-1')).toBe(true);

    // Op-sequence step 6: the op's own content push lands (mirrors setContent, dispatched
    // with the addToHistory:false annotation). main.ts's EditorView.updateListener calls
    // maybeAdvanceRegistryOnSyncOriginTx on EVERY sync-origin transaction, including this
    // one -- BEFORE finalizeStructuralOpPostOpDoc (step 7) ever runs.
    const pushTr = v.state.update({
      changes: { from: 0, insert: 'RESTORED' },
      annotations: Transaction.addToHistory.of(false),
    });
    v.dispatch(pushTr);
    maybeAdvanceRegistryOnSyncOriginTx(pushTr);

    // Op-sequence step 7: capture postOpDoc for real.
    expect(finalizeStructuralOpPostOpDoc('op-1')).toBe(true);

    // Without the fix, pushTr.startState.doc equals the placeholder postOpDoc (===
    // preOpDoc), so the §4.6 rule wrongly advances preOpDoc forward onto the post-op doc --
    // permanently corrupting the redo equality target for this entry's whole lifetime, even
    // though finalizeStructuralOpPostOpDoc correctly repairs postOpDoc right after.
    const entry = getRegistry().get('op-1');
    expect(entry?.preOpDoc.eq(opStartDoc)).toBe(true);

    // Real-world consequence: structural redo against the ORIGINAL pre-op doc must still
    // route structurally. This is exactly what failed live -- redo2 fell through to a no-op
    // text redo because preOpDoc had already been silently corrupted to equal postOpDoc.
    const decision = decideRedoRouting({
      descriptor: { redoTopOpId: 'op-1' },
      registry: getRegistry(),
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: opStartDoc,
      docsEqual: (a, b) => a.eq(b),
    });
    expect(decision).toEqual({ action: 'structural', opId: 'op-1' });
  });

  it("regression: a NEW op's own primary content push must not silently advance a DIFFERENT, already-finalized entry's equality target -- the exact restore-then-reorder collision behind the second Cmd-Z silently doing nothing (notes.md 2026-08-18). This must fail without the whole-function mid-op guard.", () => {
    const v = makeEditor('Paragraph one.');

    // Op A (e.g. a version restore) begins and finalizes -- entryA.postOpDoc is now a real,
    // distinct document (DOC_A), not the beginStructuralOp placeholder.
    expect(beginStructuralOp('op-A')).toBe(true);
    v.dispatch({ changes: { from: 0, insert: 'RESTORED' }, annotations: Transaction.addToHistory.of(false) });
    expect(finalizeStructuralOpPostOpDoc('op-A')).toBe(true);
    const entryABefore = getRegistry().get('op-A');
    const docA = v.state.doc; // === entryA.postOpDoc

    // Op B (e.g. a drag reorder) begins immediately after, with nothing else having changed in
    // between -- beginStructuralOp captures preOpDoc = docA, exactly matching op A's postOpDoc.
    expect(beginStructuralOp('op-B')).toBe(true);

    // Op B's OWN primary content push: a sync-origin transaction whose "before" doc is docA --
    // mirroring exactly what happens when two structural ops run back-to-back with no
    // intervening real edit.
    const pushTrB = v.state.update({
      changes: { from: 0, insert: 'REORDERED' },
      annotations: Transaction.addToHistory.of(false),
    });
    v.dispatch(pushTrB);
    maybeAdvanceRegistryOnSyncOriginTx(pushTrB);

    // entryA must be COMPLETELY UNCHANGED. Without the fix, entryA.postOpDoc.eq(before) is true
    // (docA == docA) because op B is not entryA's own mid-op entry, so the old single-entry
    // guard doesn't skip it -- entryA.postOpDoc gets wrongly advanced to op B's post-push doc,
    // permanently breaking the second Cmd-Z.
    const entryAAfter = getRegistry().get('op-A');
    expect(entryAAfter?.postOpDoc).toBe(entryABefore?.postOpDoc);
    expect(entryAAfter?.preOpDoc).toBe(entryABefore?.preOpDoc);
    expect(entryAAfter?.postOpDoc.eq(docA)).toBe(true);

    // Real-world consequence: once op B is later undone (routing the doc back to docA), the
    // routing check for the now-top-of-stack entryA must still see postOpDoc.eq(currentDoc).
    const decision = decideUndoRouting({
      descriptor: { undoTopOpId: 'op-A' },
      registry: getRegistry(),
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: docA,
      docsEqual: (a, b) => a.eq(b),
    });
    expect(decision).toEqual({ action: 'structural', opId: 'op-A' });
  });

  it("maybeAdvanceRegistryOnSyncOriginTx still advances a matching entry when NO entry is mid-op, even with a second finalized entry present -- confirms the cross-entry guard above does not disable the rule's legitimate case (genuine async derived-content churn, e.g. a delayed bibliography/footnote resync landing well after any op has finished)", () => {
    const v = makeEditor('Paragraph one.');

    // Op A finalizes.
    expect(beginStructuralOp('op-A')).toBe(true);
    v.dispatch({ changes: { from: 0, insert: 'RESTORED' }, annotations: Transaction.addToHistory.of(false) });
    expect(finalizeStructuralOpPostOpDoc('op-A')).toBe(true);
    const entryABefore = getRegistry().get('op-A');

    // Op B ALSO finalizes -- both entries are now finalized (postOpDoc !== preOpDoc for
    // either), so no entry is mid-op by the time the resync below fires.
    expect(beginStructuralOp('op-B')).toBe(true);
    v.dispatch({ changes: { from: 0, insert: 'REORDERED' }, annotations: Transaction.addToHistory.of(false) });
    expect(finalizeStructuralOpPostOpDoc('op-B')).toBe(true);
    const docB = v.state.doc; // === entryB.postOpDoc

    // A genuine async derived-content resync lands well after both ops finished, matching op
    // B's postOpDoc (the current live doc) -- this is the rule's actual intended trigger.
    const resyncTr = v.state.update({
      changes: { from: 0, insert: 'BIB' },
      annotations: Transaction.addToHistory.of(false),
    });
    v.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    // Op B's matching reference advances...
    const entryBAfter = getRegistry().get('op-B');
    expect(entryBAfter?.postOpDoc.eq(v.state.doc)).toBe(true);
    expect(entryBAfter?.postOpDoc.eq(docB)).toBe(false);

    // ...while op A, whose reference doesn't match this transaction's "before" doc, is
    // completely untouched.
    const entryAAfter = getRegistry().get('op-A');
    expect(entryAAfter?.postOpDoc).toBe(entryABefore?.postOpDoc);
    expect(entryAAfter?.preOpDoc).toBe(entryABefore?.preOpDoc);
  });

  it('maybeAdvanceRegistryOnSyncOriginTx does not advance when the transaction is unrelated to either reference', () => {
    const v = makeEditor('Paragraph one.');
    const preOpDoc = v.state.doc;
    // A real, non-sync-origin edit moves the live doc away from preOpDoc/postOpDoc first.
    v.dispatch({ changes: { from: 0, insert: 'UNRELATED' } });
    setRegistryEntry('op-1', { checkpoint: v.state as any, postOpDoc: preOpDoc, preOpDoc });

    const resyncTr = v.state.update({
      changes: { from: 0, insert: 'X' },
      annotations: Transaction.addToHistory.of(false),
    });
    v.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    const entry = getRegistry().get('op-1');
    expect(entry?.postOpDoc.eq(preOpDoc)).toBe(true);
    expect(entry?.preOpDoc.eq(preOpDoc)).toBe(true);
  });

  // === must-fix 3 (judge round review): explicit `midOp` marker coverage ===
  // Mirrors web/milkdown/src/__tests__/undo-coordinator.test.ts's matching suite. These
  // exercise the `midOp` field directly (every existing test above only reaches it indirectly
  // via beginStructuralOp/finalizeStructuralOpPostOpDoc) -- see UndoRegistryEntry's doc
  // comment for why a zero-diff op (postOpDoc === preOpDoc by reference, e.g. a Document Note
  // delete) needed this explicit marker in the first place.

  it('a finalized entry (midOp: false) whose preOpDoc === postOpDoc by reference (zero-diff op, e.g. a Document Note delete) does NOT block advancing a DIFFERENT, unrelated entry', () => {
    const v = makeEditor('Paragraph one.');

    // Zero-diff entry: preOpDoc and postOpDoc are the SAME doc object, but explicitly
    // finalized (midOp: false) -- exactly the shape midOp exists to disambiguate from
    // "still mid-op", which the OLD `postOpDoc === preOpDoc` reference-identity detector could
    // not tell apart.
    const zeroDiffDoc = v.state.doc;
    setRegistryEntry('op-zero-diff', {
      checkpoint: v.state as any,
      postOpDoc: zeroDiffDoc,
      preOpDoc: zeroDiffDoc,
      midOp: false,
    });

    // A second, unrelated, already-finalized entry with a genuinely distinct preOpDoc/postOpDoc.
    v.dispatch({ changes: { from: 0, insert: 'RESTORED' }, annotations: Transaction.addToHistory.of(false) });
    const docB = v.state.doc;
    setRegistryEntry('op-B', { checkpoint: v.state as any, postOpDoc: docB, preOpDoc: zeroDiffDoc, midOp: false });

    // A later async derived-content resync (e.g. a delayed bibliography fetch) lands, matching
    // op-B's postOpDoc.
    const resyncTr = v.state.update({
      changes: { from: 0, insert: 'BIB' },
      annotations: Transaction.addToHistory.of(false),
    });
    v.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    // Without the midOp fix, op-zero-diff's reference-identical postOpDoc/preOpDoc would read
    // as "mid-op" under the old detector, blocking advancement for EVERY entry -- including
    // op-B here.
    const entryB = getRegistry().get('op-B');
    expect(entryB?.postOpDoc.eq(v.state.doc)).toBe(true);
    expect(entryB?.postOpDoc.eq(docB)).toBe(false);
  });

  it('an entry with midOp: true DOES block advancing a different, unrelated entry', () => {
    const v = makeEditor('Paragraph one.');

    // Op A: finalized, with a distinct preOpDoc/postOpDoc pair.
    const opAStart = v.state.doc;
    v.dispatch({ changes: { from: 0, insert: 'RESTORED' }, annotations: Transaction.addToHistory.of(false) });
    const docA = v.state.doc;
    setRegistryEntry('op-A', { checkpoint: v.state as any, postOpDoc: docA, preOpDoc: opAStart, midOp: false });

    // Op B: explicitly mid-op (midOp: true) -- its own doc references don't matter here, only
    // its presence in the registry while mid-op.
    setRegistryEntry('op-B', { checkpoint: v.state as any, postOpDoc: docA, preOpDoc: docA, midOp: true });

    // A sync-origin transaction whose "before" doc matches op-A's postOpDoc.
    const resyncTr = v.state.update({
      changes: { from: 0, insert: 'BIB' },
      annotations: Transaction.addToHistory.of(false),
    });
    v.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    // op-A must be untouched: op-B being mid-op blocks advancement for the WHOLE registry.
    const entryA = getRegistry().get('op-A');
    expect(entryA?.postOpDoc.eq(docA)).toBe(true);
    expect(entryA?.postOpDoc.eq(v.state.doc)).toBe(false);
  });

  it('an entry with midOp undefined/missing is treated as not-mid-op (defensive default) and does not block advancing a different entry', () => {
    const v = makeEditor('Paragraph one.');

    // Constructed WITHOUT the midOp field at all (e.g. an older test-constructed entry shape)
    // -- must read as "not mid-op", the documented default for `undefined`.
    const preOpDoc = v.state.doc;
    setRegistryEntry('op-legacy', { checkpoint: v.state as any, postOpDoc: preOpDoc, preOpDoc });
    expect(getRegistry().get('op-legacy')?.midOp).toBeUndefined();

    // A second, unrelated, finalized entry.
    v.dispatch({ changes: { from: 0, insert: 'RESTORED' }, annotations: Transaction.addToHistory.of(false) });
    const docB = v.state.doc;
    setRegistryEntry('op-B', { checkpoint: v.state as any, postOpDoc: docB, preOpDoc, midOp: false });

    const resyncTr = v.state.update({
      changes: { from: 0, insert: 'BIB' },
      annotations: Transaction.addToHistory.of(false),
    });
    v.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    const entryB = getRegistry().get('op-B');
    expect(entryB?.postOpDoc.eq(v.state.doc)).toBe(true);
    expect(entryB?.postOpDoc.eq(docB)).toBe(false);
  });

  it('integration: postOpDoc captured at push-tr keeps tracking through sync-origin resyncs, and equality routing recognizes the advanced state as reachable (plan §8)', () => {
    const v = makeEditor('Paragraph one.');

    // Op-sequence step 3: begin the op (isolateHistory + capture preOpDoc/placeholder postOpDoc).
    expect(beginStructuralOp('op-1')).toBe(true);

    // Op-sequence step 6/7: the op's own content push lands, then postOpDoc is captured from
    // the current doc -- deliberately NOT waiting for any later normalization.
    v.dispatch({ changes: { from: 0, insert: 'RESTORED' }, annotations: Transaction.addToHistory.of(false) });
    expect(finalizeStructuralOpPostOpDoc('op-1')).toBe(true);
    expect(getRegistry().get('op-1')?.postOpDoc.eq(v.state.doc)).toBe(true);

    // A subsequent sync-origin transaction lands AFTER capture -- e.g. a delayed
    // bibliography/footnote resync (H5) -- rewriting the doc again.
    const resyncTr = v.state.update({
      changes: { from: 0, insert: 'BIB' },
      annotations: Transaction.addToHistory.of(false),
    });
    v.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    const finalDoc = v.state.doc;
    // Without the advancement rule this would still equal the pre-resync doc, and equality
    // routing below would fall through forever -- the exact H5 "permanently bricked entry"
    // hazard the rule exists to prevent.
    expect(getRegistry().get('op-1')?.postOpDoc.eq(finalDoc)).toBe(true);

    const decision = decideUndoRouting({
      descriptor: { undoTopOpId: 'op-1' },
      registry: getRegistry(),
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: finalDoc,
      docsEqual: (a, b) => a.eq(b),
    });
    expect(decision).toEqual({ action: 'structural', opId: 'op-1' });
  });

  // === Phase 5: barrier/eviction JS-side clears (plan §4.1/§4.5/§5 backlog) ===

  it('clearStructuralUndoRegistry clears the registry and resets the descriptor WITHOUT touching editor text-undo history', () => {
    const v = makeEditor('Paragraph one.');
    v.dispatch({ changes: { from: 0, insert: 'typed text' } });
    const depthBefore = undoDepth(v.state);
    expect(depthBefore).toBeGreaterThan(0);

    expect(beginStructuralOp('op-1')).toBe(true);
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    expect(getRegistry().size).toBe(1);

    clearStructuralUndoRegistry();

    expect(getRegistry().size).toBe(0);
    expect(getUndoDescriptor()).toEqual({});
    // The editor's own text-undo history is untouched -- a barrier must not wipe legitimate
    // in-flight typing undo steps, only the now-invalid structural registry/descriptor.
    expect(undoDepth(v.state)).toBe(depthBefore);
  });

  it('clearStructuralUndoState (eviction) removes only the evicted opId from the registry AND clears the editor text-undo history (MF-1, Phase 5 review round)', () => {
    const v = makeEditor('Paragraph one.');
    v.dispatch({ changes: { from: 0, insert: 'typed text' } });
    expect(undoDepth(v.state)).toBeGreaterThan(0);

    expect(beginStructuralOp('op-1')).toBe(true);
    setUndoDescriptor({ undoTopOpId: 'op-1' });

    clearStructuralUndoState('op-1');

    expect(getRegistry().has('op-1')).toBe(false);
    // clearHistory() rebuilds the EditorState via setState() -- read the module-level view
    // back out (setEditorView is called inside clearHistory) rather than trusting the local
    // `v` reference, mirroring makeEditor's own bookkeeping.
    expect(undoDepth(v.state)).toBe(0);
  });

  it("clearStructuralUndoState (eviction) does NOT wipe a DIFFERENT, still-live opId's registry entry -- regression for MF-1 (Phase 5 review round): the eviction path used to call clearStructuralUndoRegistry()/clearRegistry(), a WHOLE-registry wipe. record() (UnifiedUndoService.swift) calls this closure as the LAST step of performStructuralOp -- AFTER that same op's own registry entry was already created and finalized -- so the old whole-registry clear wiped the CURRENT op's own just-recorded entry too, breaking structural undo/redo the moment the stack crossed capacity (op #51+)", () => {
    const v = makeEditor('Paragraph one.');

    // 'op-evicted' stands in for the oldest entry that just fell off the undo stack at
    // capacity; 'op-current' stands in for the CURRENT op's own entry, already fully recorded
    // (finalizeStructuralOpPostOpDoc has run) by the time eviction's JS-side clear fires.
    expect(beginStructuralOp('op-evicted')).toBe(true);
    expect(finalizeStructuralOpPostOpDoc('op-evicted')).toBe(true);
    v.dispatch({ changes: { from: 0, insert: 'X' }, annotations: Transaction.addToHistory.of(false) });
    expect(beginStructuralOp('op-current')).toBe(true);
    expect(finalizeStructuralOpPostOpDoc('op-current')).toBe(true);
    expect(getRegistry().has('op-evicted')).toBe(true);
    expect(getRegistry().has('op-current')).toBe(true);

    clearStructuralUndoState('op-evicted');

    expect(getRegistry().has('op-evicted')).toBe(false);
    expect(getRegistry().has('op-current')).toBe(true);
  });
});

// === N8 (Phase B remediation plan): the 3s latch self-clear timeout ===
// Zero test coverage previously existed for this belt-and-braces mechanism (a lost Swift
// reply must not swallow every future Cmd-Z/Cmd-Shift-Z for the rest of the session).
// Mirrors Milkdown's undo-coordinator.test.ts N8 block.
describe('undo-coordinator latch self-clear timeout (N8)', () => {
  let view: EditorView | null = null;

  afterEach(() => {
    vi.useRealTimers();
    setEditorView(null);
    setEditorExtensions([]);
    if (view) {
      view.destroy();
      view = null;
    }
    resetUndoCoordinatorState();
    delete (window as any).webkit;
  });

  function makeEditor(doc: string): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const extensions = [markdown({ base: markdownLanguage }), history()];
    const v = new EditorView({
      state: EditorState.create({ doc, extensions }),
      parent: div,
    });
    view = v;
    setEditorView(v);
    setEditorExtensions(extensions);
    return v;
  }

  it('self-clears the latch after 3s with no reply from Swift, so a later Cmd-Z is not swallowed forever', async () => {
    const v = makeEditor('Paragraph one.');
    setRegistryEntry('op-1', { checkpoint: v.state as any, postOpDoc: v.state.doc, preOpDoc: v.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage: vi.fn() } } };
    vi.useFakeTimers();

    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    handleUnifiedUndoKeydown(event, v, 'undo');
    expect(isLatched()).toBe(true);

    await vi.advanceTimersByTimeAsync(3000);

    expect(isLatched()).toBe(false);
    expect(getInFlightOpId()).toBe(null);
  });

  it('does NOT self-clear before 3s -- a reply that genuinely takes a while is not preempted', async () => {
    const v = makeEditor('Paragraph one.');
    setRegistryEntry('op-1', { checkpoint: v.state as any, postOpDoc: v.state.doc, preOpDoc: v.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage: vi.fn() } } };
    vi.useFakeTimers();

    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    handleUnifiedUndoKeydown(event, v, 'undo');

    await vi.advanceTimersByTimeAsync(2999);

    expect(isLatched()).toBe(true);
  });

  it('a genuine reply that arrives before the timeout cancels the pending timer, so it cannot later fire against a newer request', async () => {
    const v = makeEditor('Paragraph one.');
    setRegistryEntry('op-1', { checkpoint: v.state as any, postOpDoc: v.state.doc, preOpDoc: v.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage: vi.fn() } } };
    vi.useFakeTimers();

    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    handleUnifiedUndoKeydown(event, v, 'undo');
    handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'performed' }, 'undo');
    expect(isLatched()).toBe(false);

    // Let 1s elapse before the second request -- see Milkdown's mirror test for why this gap
    // is needed to distinguish "cancelled" from "coincidentally fires at the same time".
    await vi.advanceTimersByTimeAsync(1000);

    setRegistryEntry('op-2', { checkpoint: v.state as any, postOpDoc: v.state.doc, preOpDoc: v.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-2' });
    const event2 = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    handleUnifiedUndoKeydown(event2, v, 'undo');
    expect(getInFlightOpId()).toBe('op-2');

    // t=3000ms overall: when the first request's original timer would have fired, but 1s
    // before the second request's own fresh 3s window elapses.
    await vi.advanceTimersByTimeAsync(2000);

    expect(isLatched()).toBe(true);
    expect(getInFlightOpId()).toBe('op-2');
  });
});

// === Phase 4b: automatic rewrites after a structural op must not break Cmd-Z (Markdown mode) ===
//
// Markdown mode has no nested-dispatch problem (CodeMirror 6 forbids a dispatch from inside an
// update; the update listener sees every transaction in order), so the only gap here is the footnote
// renumber, which dispatches with no annotation and therefore reads as typing. The Notes /
// bibliography pushes arrive through setContent (addToHistory:false). Both are checked against the
// registry exactly the way Cmd-Z routes: decideUndoRouting with the unsettled-edit check held true.
//
// The update listener below is a copy of the one main.ts installs (main.ts exports no listener to
// import; its initEditor() builds the whole app editor): same four calls, same order, per transaction.

describe('Markdown mode: automatic rewrites after a structural op keep Cmd-Z structural (Phase 4b)', () => {
  let view: EditorView | null = null;

  afterEach(() => {
    setEditorView(null);
    setEditorExtensions([]);
    if (view) {
      view.destroy();
      view = null;
    }
    resetUndoCoordinatorState();
  });

  /** A live editor with main.ts's undo-tracking update listener installed. */
  function makeTrackedEditor(doc: string): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const extensions = [
      markdown({ base: markdownLanguage }),
      history(),
      EditorView.updateListener.of((update) => {
        for (const tr of update.transactions) {
          maybeNotifyHistoryEdited(tr);
          maybeAdvanceRegistryOnSyncOriginTx(tr);
          noteUserTransaction(tr);
          noteTransactionForEditSpanTracking(tr);
        }
      }),
    ];
    const v = new EditorView({ state: EditorState.create({ doc, extensions }), parent: div });
    view = v;
    setEditorView(v);
    setEditorExtensions(extensions);
    return v;
  }

  /** A section delete as Swift runs it, minus the database: begin, push the post-op text as one
   * sync-origin transaction (addToHistory:false, like setContent's push), finalize. */
  function deleteSectionPushing(v: EditorView, postOpText: string): void {
    expect(beginStructuralOp('op-1')).toBe(true);
    v.dispatch({
      changes: { from: 0, to: v.state.doc.length, insert: postOpText },
      annotations: Transaction.addToHistory.of(false),
    });
    expect(finalizeStructuralOpPostOpDoc('op-1')).toBe(true);
    setUndoDescriptor({ undoTopOpId: 'op-1' });
  }

  function undoDecision(v: EditorView) {
    return decideUndoRouting({
      descriptor: getUndoDescriptor(),
      registry: getRegistry(),
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: v.state.doc,
      docsEqual: (a, b) => a.eq(b),
    });
  }

  it('Markdown mode: renumbering footnotes after a structural op keeps Cmd-Z structural', () => {
    const v = makeTrackedEditor('Alpha text.[^1]\n\nBeta text.[^2]\n\n[^1]: First note.\n[^2]: Second note.\n');
    // The op's own push removes Alpha's paragraph and footnote 1's definition; footnote 2 is left behind.
    deleteSectionPushing(v, 'Beta text.[^2]\n\n[^2]: Second note.\n');
    expect(v.state.doc.toString()).toBe('Beta text.[^2]\n\n[^2]: Second note.\n');

    // The automatic renumber that follows: footnote 2 becomes footnote 1 (reference and definition).
    renumberFootnotes({ '2': '1' });

    expect(v.state.doc.toString()).toBe('Beta text.[^1]\n\n[^1]: Second note.\n');
    expect(getRegistry().get('op-1')?.postOpDoc.eq(v.state.doc)).toBe(true);
    expect(undoDecision(v)).toEqual({ action: 'structural', opId: 'op-1' });
  });

  it('Markdown mode: a Notes push via setContent is absorbed', () => {
    const v = makeTrackedEditor('Alpha text.[^1]\n\nBeta text.\n\n[^1]: First note.\n');
    // The op's own push removes Alpha's paragraph only; its footnote definition is still there.
    deleteSectionPushing(v, 'Beta text.\n\n[^1]: First note.\n');
    expect(v.state.doc.toString()).toBe('Beta text.\n\n[^1]: First note.\n');

    // The automatic Notes rebuild that follows: the deleted section's footnote definition goes away.
    setContent('Beta text.\n', { origin: 'derived' });

    expect(v.state.doc.toString()).toBe('Beta text.\n');
    expect(getRegistry().get('op-1')?.postOpDoc.eq(v.state.doc)).toBe(true);
    expect(undoDecision(v)).toEqual({ action: 'structural', opId: 'op-1' });
  });
});

// === Early typing: the rewrites land AFTER the user typed (Phase 4b fallback comparison) ===
//
// Same situation as Milkdown's early-typing tests (structural-undo-derived-rewrites.test.ts): the user
// types after a section delete, the Notes / bibliography rebuild (and the footnote renumber) land after
// the typing, then the user undoes the typing. The document is then the saved copy plus those rewrites:
// not equal, but equal modulo what the app regenerates, which decideRouting asks `docsEquivalent` about.

describe('Markdown mode: early typing, rewrites landing after the user typed (Phase 4b fallback comparison)', () => {
  let view: EditorView | null = null;

  // The "recent user edit" span (recent-edit-span.ts) is module state with a 2.5 s lifetime and merges
  // successive typing into one growing range: without a reset between these tests, an earlier test's
  // typing makes a later test's derived push look like it overlaps fresh typing (it would then be
  // recorded as an undoable correction instead of landing silently, as it does in the real sequence).
  afterEach(() => {
    setEditorView(null);
    setEditorExtensions([]);
    view?.destroy();
    view = null;
    resetUndoCoordinatorState();
    resetRecentUserEditSpanForTests();
    delete (window as any).webkit;
  });

  const SID = (n: number) => `<!-- @sid:aaaaaaaa-0000-0000-0000-00000000000${n} -->`;
  const MD = [
    `${SID(1)}# Alpha`,
    '',
    'Alpha text.[^1]',
    '',
    `${SID(2)}# Beta`,
    '',
    'Beta text.[^2] And another.[^3]',
    '',
    `${SID(3)}# Gamma`,
    '',
    'Gamma plain text.',
    '',
    `${SID(4)}# Notes`,
    '',
    '[^1]: First note.',
    '[^2]: Second note.',
    '[^3]: Third note.',
    '',
    '<!-- ::auto-bibliography:: --># Bibliography',
    '',
    'Entry Alpha.',
    '',
    'Entry Beta.',
    '',
    '<!-- ::auto-bibliography-end:: -->',
    '',
  ].join('\n');
  const POST_OP = MD.replace(`${SID(1)}# Alpha\n\nAlpha text.[^1]\n\n`, '');

  /** A live editor with main.ts's undo-tracking update listener (a copy: main.ts exports none). */
  function makeTracked(doc: string): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const extensions = [
      markdown({ base: markdownLanguage }),
      history(),
      EditorView.updateListener.of((u) => {
        for (const tr of u.transactions) {
          maybeNotifyHistoryEdited(tr);
          maybeAdvanceRegistryOnSyncOriginTx(tr);
          noteUserTransaction(tr);
          noteTransactionForEditSpanTracking(tr);
        }
      }),
    ];
    const v = new EditorView({ state: EditorState.create({ doc, extensions }), parent: div });
    view = v;
    setEditorView(v);
    setEditorExtensions(extensions);
    return v;
  }

  /** The op's own push: Alpha's heading and paragraph go; Notes is untouched, so `[^1]: First note.` is
   * left behind as an orphan definition (Swift's op push leaves the Notes rows). */
  function deleteAlphaAsOp(v: EditorView): void {
    expect(beginStructuralOp('op-1')).toBe(true);
    v.dispatch({
      changes: { from: 0, to: v.state.doc.length, insert: POST_OP },
      annotations: Transaction.addToHistory.of(false),
    });
    expect(finalizeStructuralOpPostOpDoc('op-1')).toBe(true);
    setUndoDescriptor({ undoTopOpId: 'op-1' });
  }

  function typeAfter(v: EditorView, after: string, word: string): void {
    const at = v.state.doc.toString().indexOf(after);
    expect(at, `"${after}" must be in the document`).toBeGreaterThanOrEqual(0);
    v.dispatch({ changes: { from: at + after.length, insert: word }, userEvent: 'input.type' });
  }

  /** The Notes + bibliography rebuild: drops the orphan definition, re-anchors the Notes heading, drops
   * Alpha's bibliography entry. Pushed the way Swift pushes derived content (minimal-diff setContent). */
  function rebuildNotesAndBibliography(): void {
    const v = view!;
    setContent(
      v.state.doc
        .toString()
        .replace(/^\[\^\d+\]: First note\.\n/m, '')
        .replace(SID(4), SID(9))
        .replace('Entry Alpha.\n\n', ''),
      { origin: 'derived' }
    );
  }

  const decide = (v: EditorView) =>
    decideUndoRouting({
      descriptor: getUndoDescriptor(),
      registry: getRegistry(),
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: v.state.doc,
      docsEqual: (a, b) => a.eq(b),
      docsEquivalent: textsEquivalentIgnoringDerived,
    });
  const STRUCT = { action: 'structural', opId: 'op-1' };
  const FALL = { action: 'fallthrough' };

  it('MD-F0: the fallback is never consulted when the document exactly equals the saved copy', () => {
    const v = makeTracked(MD);
    deleteAlphaAsOp(v);
    const spy = vi.fn(() => false);
    expect(
      decideUndoRouting({
        descriptor: getUndoDescriptor(),
        registry: getRegistry(),
        pendingMapsEmpty: true,
        latched: false,
        currentDoc: v.state.doc,
        docsEqual: (a, b) => a.eq(b),
        docsEquivalent: spy,
      })
    ).toEqual(STRUCT);
    expect(spy).not.toHaveBeenCalled();
  });

  it('MD-F1: rebuild lands after the typing: undo the typing, then Cmd-Z restores the section', () => {
    const v = makeTracked(MD);
    deleteAlphaAsOp(v);
    typeAfter(v, 'Gamma plain text.', ' EARLYWORD');
    rebuildNotesAndBibliography();
    expect(decide(v)).toEqual(FALL);
    expect(undo(v)).toBe(true);
    expect(v.state.doc.toString()).not.toContain('EARLYWORD');
    expect(v.state.doc.eq(getRegistry().get('op-1')!.postOpDoc), 'premise: only the fallback can route this').toBe(
      false
    );
    expect(decide(v)).toEqual(STRUCT);
  });

  it('MD-F2: renumber after the typing: Cmd-Z undoes the renumber, then the typing, then restores the section', () => {
    const v = makeTracked(MD);
    deleteAlphaAsOp(v);
    typeAfter(v, 'Gamma plain text.', ' EARLYWORD');
    renumberFootnotes({ '2': '1', '3': '2' });
    rebuildNotesAndBibliography();
    expect(decide(v)).toEqual(FALL);
    expect(undo(v)).toBe(true);
    expect(v.state.doc.toString()).toContain('Beta text.[^2] And another.[^3]');
    expect(v.state.doc.toString()).toContain('EARLYWORD');
    expect(decide(v)).toEqual(FALL);
    expect(undo(v)).toBe(true);
    expect(decide(v)).toEqual(STRUCT);
  });

  it('MD-F3 fail-safe: while the typed word is in the text, Cmd-Z never routes to the section', () => {
    const v = makeTracked(MD);
    deleteAlphaAsOp(v);
    typeAfter(v, 'Gamma plain text.', ' EARLYWORD');
    renumberFootnotes({ '2': '1', '3': '2' });
    rebuildNotesAndBibliography();
    expect(decide(v)).toEqual(FALL);
    expect(undo(v)).toBe(true);
    expect(v.state.doc.toString()).toContain('EARLYWORD');
    expect(decide(v)).toEqual(FALL);
  });

  it('MD-F4 fail-safe: an edit to a still-referenced footnote is never skipped', () => {
    const v = makeTracked(MD);
    deleteAlphaAsOp(v);
    typeAfter(v, 'Second note.', ' EDITEDNOTE');
    rebuildNotesAndBibliography();
    expect(decide(v)).toEqual(FALL);
    expect(undo(v)).toBe(true);
    expect(v.state.doc.toString()).not.toContain('EDITEDNOTE');
    expect(decide(v)).toEqual(STRUCT);
  });

  it('MD-F6 wiring: requestUnifiedUndo routes structurally through the fallback', () => {
    const posted: unknown[] = [];
    (window as any).webkit = {
      messageHandlers: {
        errorHandler: { postMessage: () => {} },
        structuralUndoRequested: { postMessage: (m: unknown) => posted.push(m) },
      },
    };
    const v = makeTracked(MD);
    deleteAlphaAsOp(v);
    typeAfter(v, 'Gamma plain text.', ' EARLYWORD');
    rebuildNotesAndBibliography();
    expect(undo(v)).toBe(true);
    requestUnifiedUndo();
    expect(posted).toEqual([{ opId: 'op-1' }]);
  });

  it('MD-F7 fail-safe: text typed into a footnote that is an orphan on BOTH sides is never skipped', () => {
    const v = makeTracked(MD);
    deleteAlphaAsOp(v); // `[^1]: First note.` is now an orphan in the saved copy
    typeAfter(v, 'First note.', ' ORPHANEDIT'); // typed into the orphan before any rebuild
    setContent(v.state.doc.toString().replace('Entry Alpha.\n\n', ''), { origin: 'derived' }); // bibliography-only rebuild
    expect(v.state.doc.toString(), 'premise: the typed text sits in the orphan').toContain('First note. ORPHANEDIT');
    expect(decide(v)).toEqual(FALL);
    expect(undo(v)).toBe(true);
    expect(v.state.doc.toString()).not.toContain('ORPHANEDIT');
    expect(v.state.doc.eq(getRegistry().get('op-1')!.postOpDoc), 'premise: only the fallback can route this').toBe(
      false
    );
    expect(decide(v)).toEqual(STRUCT);
  });

  const eq = (a: string, b: string) => textsEquivalentIgnoringDerived(Text.of(a.split('\n')), Text.of(b.split('\n')));

  /** `base` with the first `from` replaced by `to`. Fails when `from` is not in `base` or the result is the same
   * text: a no-op replace would make every "must stay equivalent" check below pass for nothing. */
  const mod = (base: string, from: string, to: string): string => {
    expect(base.includes(from), `premise: "${from}" is in the text`).toBe(true);
    const out = base.replace(from, to);
    expect(out, `premise: replacing "${from}" changed the text`).not.toBe(base);
    return out;
  };

  it('MD comparison view: ignores labels, anchors, the bibliography, orphans on one side and blank-line runs', () => {
    expect(POST_OP, 'premise: the operation removed Alpha from the text').not.toBe(MD);
    const relabelled = mod(
      mod(
        mod(mod(POST_OP, '[^2] And another.[^3]', '[^1] And another.[^2]'), '[^2]: Second', '[^1]: Second'),
        '[^3]: Third',
        '[^2]: Third'
      ),
      '[^1]: First note.\n',
      ''
    );
    expect(eq(POST_OP, relabelled)).toBe(true);
    expect(eq(POST_OP, mod(POST_OP, SID(2), SID(8)))).toBe(true);
    expect(eq(POST_OP, mod(POST_OP, 'Entry Alpha.\n\n', ''))).toBe(true);
    expect(eq(POST_OP, mod(POST_OP, 'Gamma plain text.\n', 'Gamma plain text.\n\n'))).toBe(true);
  });

  it('MD comparison view: never ignores typed text, a referenced footnote, a moved reference, text after the bibliography', () => {
    expect(eq(POST_OP, mod(POST_OP, 'Gamma plain', 'Gamma PLAIN'))).toBe(false);
    expect(eq(POST_OP, mod(POST_OP, 'Second note.', 'Second note. EDIT'))).toBe(false);
    expect(
      eq(POST_OP, mod(mod(POST_OP, 'Beta text.[^2]', 'Beta text.'), 'Gamma plain text.', 'Gamma plain text.[^2]'))
    ).toBe(false);
    expect(
      eq(POST_OP, mod(POST_OP, '<!-- ::auto-bibliography-end:: -->', '<!-- ::auto-bibliography-end:: -->\n\nAfter.'))
    ).toBe(false);
    // Judge must-fix 3: trailing whitespace is trimmed only at the very end of the whole text, never per
    // line (two trailing spaces are a Markdown hard line break; one is ordinary typing).
    expect(eq(POST_OP, mod(POST_OP, 'Gamma plain text.', 'Gamma plain text.  '))).toBe(false);
    expect(eq(POST_OP, mod(POST_OP, 'Gamma plain text.', 'Gamma plain text. '))).toBe(false);
    // Judge must-fix 1: an orphan definition on BOTH sides is compared by its text, never ignored.
    expect(eq(POST_OP, mod(POST_OP, 'First note.', 'First note. EDIT'))).toBe(false);
    // Judge must-fix 2: with no bibliography end marker the region is compared exactly, never skipped to
    // the end of the text.
    const noEnd = mod(POST_OP, '<!-- ::auto-bibliography-end:: -->', '');
    expect(eq(noEnd, mod(noEnd, 'Entry Alpha.', 'Entry ALPHA.'))).toBe(false);
    expect(eq(noEnd, `${noEnd}\n\nAfter.`)).toBe(false);
  });
});

// === The real Markdown-mode text (Swift-assembled, hidden markers injected; real-app run run-1791716965-74146) ===
//
// The fixtures above kept the Notes definitions on consecutive lines and wrote the bibliography heading
// without an anchor. The real text is what Swift hands CodeMirror: BlockParser.assembleMarkdownForEditor
// joins the stored blocks with a blank line (every definition is its own block, so there is a blank line
// between definitions) and appends the end marker after the last bibliography block
// (BlockParser+Assembly.swift:59-66); SectionSyncService.injectSectionAnchors prefixes EVERY heading line
// (the Notes and the bibliography heading included) with `<!-- @sid:UUID -->`; injectBibliographyMarker
// then inserts `<!-- ::auto-bibliography:: -->` at the START of the bibliography heading's line, in front
// of the anchor (SectionSyncService+Anchors.swift:269-273 and the `insert(... at: lowerBound)` below it).
// The generated bibliography itself carries no opening marker (BibliographySyncService+EntryFormatting.swift:
// 33-38); CodeMirror's copy gets it from the injection, which is why this editor's shape differs from the
// Rich Text editor's.

describe('Markdown mode: the real text shape (blank lines between definitions, anchors on every heading, marker before the anchor)', () => {
  let view: EditorView | null = null;

  afterEach(() => {
    setEditorView(null);
    setEditorExtensions([]);
    view?.destroy();
    view = null;
    resetUndoCoordinatorState();
    resetRecentUserEditSpanForTests();
    delete (window as any).webkit;
  });

  const SID = (n: number) => `<!-- @sid:aaaaaaaa-0000-0000-0000-00000000000${n} -->`;
  const ENTRY_ADAMS = 'Adams, A. (2019). *Alpha Title*. Press.';
  const ENTRY_BAKER = 'Baker, B. (2011). *Beta Title*. Press.';
  const REAL_MD = [
    `${SID(1)}# Alpha`,
    '',
    'Alpha text.[^1]',
    '',
    `${SID(2)}# Beta`,
    '',
    'Beta text.[^2] And another.[^3]',
    '',
    `${SID(3)}# Gamma`,
    '',
    'Gamma plain text.',
    '',
    `${SID(4)}# Notes`,
    '',
    '[^1]: First note.',
    '',
    '[^2]: Second note.',
    '',
    '[^3]: Third note.',
    '',
    `<!-- ::auto-bibliography:: -->${SID(5)}# Bibliography`,
    '',
    ENTRY_ADAMS,
    '',
    ENTRY_BAKER,
    '',
    '<!-- ::auto-bibliography-end:: -->',
  ].join('\n');
  const POST_OP = REAL_MD.replace(`${SID(1)}# Alpha\n\nAlpha text.[^1]\n\n`, '');

  function makeTracked(doc: string): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const extensions = [
      markdown({ base: markdownLanguage }),
      history(),
      EditorView.updateListener.of((u) => {
        for (const tr of u.transactions) {
          maybeNotifyHistoryEdited(tr);
          maybeAdvanceRegistryOnSyncOriginTx(tr);
          noteUserTransaction(tr);
          noteTransactionForEditSpanTracking(tr);
        }
      }),
    ];
    const v = new EditorView({ state: EditorState.create({ doc, extensions }), parent: div });
    view = v;
    setEditorView(v);
    setEditorExtensions(extensions);
    return v;
  }

  function deleteAlphaAsOp(v: EditorView): void {
    expect(beginStructuralOp('op-1')).toBe(true);
    v.dispatch({
      changes: { from: 0, to: v.state.doc.length, insert: POST_OP },
      annotations: Transaction.addToHistory.of(false),
    });
    expect(finalizeStructuralOpPostOpDoc('op-1')).toBe(true);
    setUndoDescriptor({ undoTopOpId: 'op-1' });
  }

  function typeAfter(v: EditorView, after: string, word: string): void {
    const at = v.state.doc.toString().indexOf(after);
    expect(at, `"${after}" must be in the document`).toBeGreaterThanOrEqual(0);
    v.dispatch({ changes: { from: at + after.length, insert: word }, userEvent: 'input.type' });
  }

  /** The Notes + bibliography rebuild as Swift pushes it: the orphan definition (with its blank line) goes,
   * the Notes heading gets a fresh anchor, and the deleted section's bibliography entry goes. */
  function rebuildNotesAndBibliography(): void {
    const v = view!;
    setContent(
      v.state.doc
        .toString()
        .replace('[^1]: First note.\n\n', '')
        .replace(SID(4), SID(9))
        .replace(`${ENTRY_ADAMS}\n\n`, ''),
      { origin: 'derived' }
    );
  }

  const decide = (v: EditorView) =>
    decideUndoRouting({
      descriptor: getUndoDescriptor(),
      registry: getRegistry(),
      pendingMapsEmpty: true,
      latched: false,
      currentDoc: v.state.doc,
      docsEqual: (a, b) => a.eq(b),
      docsEquivalent: textsEquivalentIgnoringDerived,
    });
  const STRUCT = { action: 'structural', opId: 'op-1' };
  const FALL = { action: 'fallthrough' };

  it('RMD1: the rebuild lands after the typing: undo the typing, then Cmd-Z restores the section', () => {
    const v = makeTracked(REAL_MD);
    deleteAlphaAsOp(v);
    typeAfter(v, 'Gamma plain text.', ' EARLYWORD');
    rebuildNotesAndBibliography();
    expect(decide(v)).toEqual(FALL);
    expect(undo(v)).toBe(true);
    expect(v.state.doc.toString()).not.toContain('EARLYWORD');
    expect(v.state.doc.eq(getRegistry().get('op-1')!.postOpDoc), 'premise: only the fallback can route this').toBe(
      false
    );
    expect(decide(v)).toEqual(STRUCT);
  });

  it('RMD2: renumber after the typing: Cmd-Z undoes the renumber, then the typing, then restores the section', () => {
    const v = makeTracked(REAL_MD);
    deleteAlphaAsOp(v);
    typeAfter(v, 'Gamma plain text.', ' EARLYWORD');
    renumberFootnotes({ '2': '1', '3': '2' });
    rebuildNotesAndBibliography();
    expect(decide(v)).toEqual(FALL);
    expect(undo(v)).toBe(true);
    expect(v.state.doc.toString()).toContain('EARLYWORD');
    expect(decide(v)).toEqual(FALL);
    expect(undo(v)).toBe(true);
    expect(decide(v)).toEqual(STRUCT);
  });

  it('RMD3 fail-safe: while the typed word is in the text, Cmd-Z never routes to the section', () => {
    const v = makeTracked(REAL_MD);
    deleteAlphaAsOp(v);
    typeAfter(v, 'Gamma plain text.', ' EARLYWORD');
    rebuildNotesAndBibliography();
    expect(decide(v)).toEqual(FALL);
  });

  const eq = (a: string, b: string) => textsEquivalentIgnoringDerived(Text.of(a.split('\n')), Text.of(b.split('\n')));

  /** `base` with the first `from` replaced by `to`. Fails when `from` is not in `base` or the result is the same
   * text: a no-op replace would make every "must stay equivalent" check below pass for nothing. */
  const mod = (base: string, from: string, to: string): string => {
    expect(base.includes(from), `premise: "${from}" is in the text`).toBe(true);
    const out = base.replace(from, to);
    expect(out, `premise: replacing "${from}" changed the text`).not.toBe(base);
    return out;
  };

  it('RMD comparison view: ignores the bibliography (entries changed or removed), every anchor and blank-line layout; never ignores text after the end marker', () => {
    expect(POST_OP, 'premise: the operation removed Alpha from the text').not.toBe(REAL_MD);
    expect(eq(POST_OP, mod(POST_OP, `${ENTRY_ADAMS}\n\n`, ''))).toBe(true);
    expect(eq(POST_OP, mod(POST_OP, ENTRY_ADAMS, `${ENTRY_ADAMS} EDIT`))).toBe(true);
    expect(eq(POST_OP, mod(mod(POST_OP, SID(5), SID(8)), SID(2), SID(7)))).toBe(true);
    expect(eq(POST_OP, mod(POST_OP, '[^2]: Second note.\n\n', '[^2]: Second note.\n\n\n'))).toBe(true);
    expect(eq(POST_OP, `${POST_OP}\n\nAfter.`)).toBe(false);
    expect(eq(POST_OP, mod(POST_OP, 'Gamma plain text.', 'Gamma plain text. EDIT'))).toBe(false);
  });

  it('RMD comparison view: a text with no opening marker is compared exactly (Markdown mode always carries the injected marker; the start is not inferred from the heading)', () => {
    const noStart = mod(POST_OP, '<!-- ::auto-bibliography:: -->', '');
    expect(eq(noStart, mod(noStart, ENTRY_ADAMS, `${ENTRY_ADAMS} EDIT`))).toBe(false);
  });
});

describe('explainTextDifference: the reason for every "different" (Markdown mode)', () => {
  const explain = (a: string, b: string) => explainTextDifference(Text.of(a.split('\n')), Text.of(b.split('\n')));
  const BASE = [
    '# Alpha',
    '',
    'Alpha text.[^1] And more.[^2]',
    '',
    '# Notes',
    '',
    '[^1]: First note.',
    '',
    '[^2]: Second note.',
    '',
    '<!-- ::auto-bibliography:: --># Bibliography',
    '',
    'Entry one.',
    '',
    '<!-- ::auto-bibliography-end:: -->',
  ].join('\n');

  /** `base` with the first `from` replaced by `to`; fails when that changes nothing (a no-op replace would make
   * every "stays equivalent" or "names the difference" check pass or fail for the wrong reason). */
  const mod = (base: string, from: string, to: string): string => {
    expect(base.includes(from), `premise: "${from}" is in the text`).toBe(true);
    const out = base.replace(from, to);
    expect(out, `premise: replacing "${from}" changed the text`).not.toBe(base);
    return out;
  };

  it('is null when the texts differ only in regenerated content, and names the difference once a real one is added', () => {
    // Everything the app regenerates after a swap, all at once: relabelled footnotes (references and
    // definitions together), a rebuilt bibliography entry, and an extra blank line.
    const regenerated = mod(
      mod(
        mod(
          mod(
            mod(BASE, 'Alpha text.[^1] And more.[^2]', 'Alpha text.[^7] And more.[^8]'),
            '[^1]: First',
            '[^7]: First'
          ),
          '[^2]: Second',
          '[^8]: Second'
        ),
        'Entry one.',
        'Entry two.'
      ),
      '# Notes\n\n',
      '# Notes\n\n\n'
    );
    expect(regenerated).not.toBe(BASE);
    expect(explain(BASE, regenerated)).toBeNull();
    expect(explain(regenerated, BASE)).toBeNull();

    // The same regenerated variant PLUS one real change: not equivalent, and the reason names where. This is
    // the half that goes red if the body comparison is removed.
    expect(explain(BASE, mod(regenerated, 'Alpha text.', 'Alpha TEXT.'))).toContain('body differs at line');
  });

  it('names a footnote label defined twice', () => {
    const dup = mod(BASE, '[^2]: Second note.', '[^1]: Second note.');
    expect(explain(BASE, dup)).toBe('a footnote label is defined twice in b');
    expect(explain(dup, BASE)).toBe('a footnote label is defined twice in a');
  });

  it('names the first differing line of the body by position and length, never by text, and says how the bibliography was cut', () => {
    const reason = explain(BASE, mod(BASE, 'Alpha text.', 'Alpha TEXT.')) ?? '';
    expect(reason).toContain('body differs at line 3 of the projected body');
    expect(reason).toContain('first difference at column 6');
    // "Alpha text.[^] And more.[^]" is 27 characters on both sides.
    expect(reason).toContain('a=(27 chars) b=(27 chars)');
    expect(reason).toContain('bibliography a: 1 region(s) cut (opening marker .. end marker)');
    expect(reason).not.toContain('Alpha');
    expect(reason).not.toContain('TEXT');
  });

  it('says when an opening marker has no end marker, and when an end marker has no opening marker', () => {
    const noEnd = mod(BASE, '<!-- ::auto-bibliography-end:: -->', '');
    expect(explain(noEnd, mod(noEnd, 'Entry one.', 'Entry two.'))).toContain(
      'opening marker has no end marker (compared exactly)'
    );
    const noStart = mod(BASE, '<!-- ::auto-bibliography:: -->', '');
    expect(explain(noStart, mod(noStart, 'Entry one.', 'Entry two.'))).toContain(
      'end marker without an opening marker before it (compared exactly)'
    );
  });

  it('names a footnote whose text differs, by length only', () => {
    const reason = explain(BASE, mod(BASE, 'Second note.', 'Second note. EDIT')) ?? '';
    expect(reason).toContain('footnote text differs at reference 1 of 2');
    // "Second note." is 12 characters, "Second note. EDIT" 17.
    expect(reason).toContain('a=(12 chars) b=(17 chars)');
    expect(reason).not.toContain('Second');
  });

  it('names orphan definitions that differ on both sides, by length only', () => {
    const orphanA = mod(BASE, 'And more.[^2]', 'And more.');
    const reason = explain(orphanA, mod(orphanA, 'Second note.', 'Second note. EDIT')) ?? '';
    expect(reason).toContain('orphan definitions differ');
    expect(reason).not.toContain('Second');
  });

  it('is carried by the routing-equivalence log line (result=false), and absent when the press is routed', () => {
    const logs: string[] = [];
    (window as any).webkit = {
      messageHandlers: { errorHandler: { postMessage: (m: { message: string }) => logs.push(m.message) } },
    };
    const div = document.createElement('div');
    document.body.appendChild(div);
    const extensions = [markdown({ base: markdownLanguage }), history()];
    const v = new EditorView({ state: EditorState.create({ doc: BASE, extensions }), parent: div });
    try {
      setEditorView(v);
      setEditorExtensions(extensions);
      expect(beginStructuralOp('op-1')).toBe(true);
      v.dispatch({
        changes: { from: 0, to: v.state.doc.length, insert: BASE.replace('Alpha text.', 'Alpha TEXT.') },
        annotations: Transaction.addToHistory.of(false),
      });
      expect(finalizeStructuralOpPostOpDoc('op-1')).toBe(true);
      setUndoDescriptor({ undoTopOpId: 'op-1' });
      // Differs from the saved copy by body text: the fallback runs and says why it refused.
      v.dispatch({ changes: { from: 0, insert: 'X' }, userEvent: 'input.type' });
      handleUnifiedUndoKeydown(new KeyboardEvent('keydown', { key: 'z', metaKey: true }), v, 'undo');
      const refused = logs.find((l) => l.includes('routing-equivalence')) ?? '';
      expect(refused).toContain('result=false');
      expect(refused).toContain(' reason=body differs at line');
      // The whole decision's time rides on the line (what the fall-through cost test reads), after `ms=`.
      expect(refused).toMatch(/ ms=\d+\.\d totalMs=\d+\.\d /);
      expect(refused).not.toContain('Alpha');

      // Only a bibliography entry differs: equivalent, so routed structurally, and no reason on the line.
      logs.length = 0;
      v.dispatch({ changes: { from: 0, to: 1 }, annotations: Transaction.addToHistory.of(false) });
      v.dispatch({
        changes: {
          from: v.state.doc.toString().indexOf('Entry one.'),
          to: v.state.doc.toString().indexOf('Entry one.') + 'Entry one.'.length,
          insert: 'Entry two.',
        },
        annotations: Transaction.addToHistory.of(false),
      });
      handleUnifiedUndoKeydown(new KeyboardEvent('keydown', { key: 'z', metaKey: true }), v, 'undo');
      const routed = logs.find((l) => l.includes('routing-equivalence')) ?? '';
      expect(routed).toContain('decision=structural result=true');
      expect(routed).not.toContain('reason=');
    } finally {
      setEditorView(null);
      setEditorExtensions([]);
      v.destroy();
      resetUndoCoordinatorState();
      delete (window as any).webkit;
    }
  });
});
