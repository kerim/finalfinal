// @vitest-environment jsdom
// Phase 2 exit-criteria tests (docs/plans/patient-rewinding-clockwork.md §7 Phase 2, §8):
// (1) a routing truth table against fake registries -- pure, no real editor needed; and
// (2) live-wiring proofs that with the Phase 2 permanently-empty registry, every path
// (keyboard interceptor, menu-path requestUnifiedUndo/Redo, the Swift reply handler)
// behaves EXACTLY like CodeMirror's own undo/redo with no unified-undo wiring at all.

import { history, redoDepth, undo, undoDepth } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorState, Transaction } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { setEditorExtensions, setEditorView } from '../editor-state';
import {
  beginStructuralOp,
  decideRedoRouting,
  decideUndoRouting,
  finalizeStructuralOpPostOpDoc,
  getRegistry,
  handleGlobalUndoRedoKeydown,
  handleUndoReplyFromSwift,
  handleUnifiedUndoKeydown,
  isLatched,
  maybeAdvanceRegistryOnSyncOriginTx,
  maybeNotifyHistoryEdited,
  requestUnifiedRedo,
  requestUnifiedUndo,
  resetUndoCoordinatorState,
  setLatched,
  setRegistryEntry,
  setUndoDescriptor,
} from '../undo-coordinator';

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

    handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'fallback' }, 'undo');

    expect(isLatched()).toBe(false);
    expect(undoDepth(v.state)).toBe(0);
  });

  it('handleUndoReplyFromSwift does nothing beyond releasing the latch on a "performed" reply', () => {
    const v = makeEditor('Paragraph one.');
    v.dispatch({ changes: { from: 0, insert: 'X' } });
    const depthBefore = undoDepth(v.state);
    setLatched(true);

    handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'performed' }, 'undo');

    expect(isLatched()).toBe(false);
    expect(undoDepth(v.state)).toBe(depthBefore); // no extra undo performed
  });

  it('handleUndoReplyFromSwift ignores a reply that arrives while not latched (stale/duplicate reply guard)', () => {
    expect(isLatched()).toBe(false);

    expect(() => handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'fallback' }, 'undo')).not.toThrow();

    expect(isLatched()).toBe(false);
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
});
