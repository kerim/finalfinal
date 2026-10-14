// @vitest-environment jsdom
// Routing/registry test suite for undo-coordinator.ts (see docs/architecture/unified-undo.md):
// (1) a routing truth table against fake registries, both empty and populated -- pure, no
// real editor needed; (2) live-wiring proofs against a real Milkdown editor, including the
// always-empty-registry case where every path (keyboard interceptor, menu-path
// requestUnifiedUndo/Redo, the Swift reply handler) falls through to Milkdown's own undo/redo
// unchanged; and (3) registry-advancement, eviction, and latch self-clear regression tests
// for real production bugs found after real structural ops shipped.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { closeHistory, redoDepth, undo, undoDepth } from '@milkdown/kit/prose/history';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { blockSyncPlugin, hasPendingChanges, resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import {
  getPendingSlashUndo,
  PENDING_SLASH_UNDO_FRESHNESS_MS,
  setEditorInstance,
  setPendingSlashUndo,
} from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import { configureSlash, slash } from '../slash-commands';
import {
  beginStructuralOp,
  clearStructuralUndoRegistry,
  clearStructuralUndoState,
  decideRedoRouting,
  decideUndoRouting,
  finalizeStructuralOpPostOpDoc,
  getInFlightOpId,
  getQueuedPressDirections,
  getRegistry,
  getUndoDescriptor,
  handleGlobalUndoRedoKeydown,
  handleUndoReplyFromSwift,
  handleUnifiedUndoKeydown,
  heldUndoPressCount,
  isLatched,
  maybeAdvanceRegistryOnSyncOriginTx,
  maybeNotifyHistoryEdited,
  receiveRedoOutcome,
  receiveUndoOutcome,
  requestUnifiedRedo,
  requestUnifiedUndo,
  resetUndoCoordinatorState,
  setInFlightOpId,
  setLatched,
  setRegistryEntry,
  setUndoDescriptor,
} from '../undo-coordinator';

// === (1) Pure routing truth table -- fake string "docs", no editor at all ===

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

  it('falls through when blockSync pending-change maps are non-empty (unflushed-delta race)', () => {
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

  it('redo falls through when blockSync pending-change maps are non-empty (unflushed-delta race)', () => {
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

// === (2) Live wiring -- real editor, empty registry (Phase 2's permanent state) ===

describe('undo-coordinator live wiring (real Milkdown editor, always-empty Phase 2 registry)', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    vi.useRealTimers(); // safety net for the N3 stale-flag test below, which uses fake timers
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    resetBlockIdState();
    resetBlockSyncState();
    setSyncPaused(false);
    resetUndoCoordinatorState();
    setPendingSlashUndo(false);
    delete (window as any).webkit;
  });

  // Mirrors clear-history.test.ts's makeEditor -- blockIdPlugin before commonmark/gfm,
  // history last, plus slash configured so the merged capture-phase listener (the actual
  // production integration point) is registered on `document`.
  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .config(configureSlash)
      .use(blockIdPlugin)
      .use(commonmark)
      .use(gfm)
      .use(historyPlugin)
      .use(slash)
      .create();
    editor = e;
    setEditorInstance(e);
    return e;
  }

  it('handleUnifiedUndoKeydown returns false (fallthrough) and does not preventDefault, leaving the editor keymap untouched', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    const consumed = handleUnifiedUndoKeydown(event, view, 'undo');

    expect(consumed).toBe(false);
    expect(event.defaultPrevented).toBe(false);
  });

  it("requestUnifiedUndo (menu path) performs the editor's own undo when the registry is empty", async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    expect(undoDepth(view.state)).toBeGreaterThan(0);

    requestUnifiedUndo();

    expect(undoDepth(view.state)).toBe(0);
    expect(redoDepth(view.state)).toBeGreaterThan(0);
  });

  it("requestUnifiedRedo (menu path) performs the editor's own redo when the registry is empty", async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    requestUnifiedUndo();
    expect(redoDepth(view.state)).toBeGreaterThan(0);

    requestUnifiedRedo();

    expect(redoDepth(view.state)).toBe(0);
    expect(undoDepth(view.state)).toBeGreaterThan(0);
  });

  it("the in-flight latch swallows a second Cmd-Z instead of falling through to the editor's own undo", async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    const depthBefore = undoDepth(view.state);
    setLatched(true);
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    const consumed = handleUnifiedUndoKeydown(event, view, 'undo');

    expect(consumed).toBe(true); // swallowed, not fallen through
    expect(event.defaultPrevented).toBe(true);
    expect(undoDepth(view.state)).toBe(depthBefore); // editor's own undo did NOT run
  });

  // N3 (major, Phase B remediation plan): the canonical order is now structural-FIRST
  // (unified with CodeMirror's own existing order), not slash-first. The three tests below
  // replace the single pre-N3 test that asserted the opposite priority.

  it("slash's smart-undo still fires when unified-undo naturally falls through (the realistic case: the slash command's own edit already broke doc equality)", async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    const preSlashDoc = view.state.doc;
    // Registry entry's postOpDoc is the doc BEFORE the simulated slash edit below -- once
    // that edit lands, currentDoc no longer equals postOpDoc, so structural routing falls
    // through on its own, exactly as it would in real production use (a slash command always
    // mutates the document). This is the realistic scenario the pre-N3 test's artificial
    // "don't actually change the doc" setup never exercised.
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc: preSlashDoc, preOpDoc: preSlashDoc });
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage } } };
    // Simulates "a slash command just ran": a real doc-changing edit, then the flag is armed
    // -- the real production integration point is the single document-level capture listener
    // registered by configureSlash(), which contains both branches merged in code order.
    view.dispatch(view.state.tr.insertText('inserted'));
    setPendingSlashUndo(true);
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    document.dispatchEvent(event);

    // Structural routing ran FIRST (N3) but found no match (doc changed) and fell through;
    // slash's branch then consumed the keystroke.
    expect(getPendingSlashUndo()).toBe(false);
    expect(event.defaultPrevented).toBe(true);
    expect(postMessage).not.toHaveBeenCalled();
    expect(isLatched()).toBe(false);
  });

  it('unified-undo routing wins over a fresh, pending slash-undo flag when the document genuinely, structurally matches a registered entry (N3: structural-first)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    // Deliberately construct the "spurious equality" edge (docs/architecture/unified-undo.md's
    // routing section) rather than the unrealistic "no edit at all" shape the old test used:
    // the registry's postOpDoc genuinely, structurally equals the CURRENT document.
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage } } };
    setPendingSlashUndo(true); // fresh and pending -- would win under the OLD (pre-N3) order
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    document.dispatchEvent(event);

    // Structural wins: it's the more specific, document-verified match, checked first.
    expect(postMessage).toHaveBeenCalledWith({ opId: 'op-1' });
    expect(isLatched()).toBe(true);
  });

  it('a STALE pendingSlashUndo (older than the freshness window) does not swallow the keystroke at all -- N3, the actual bug this closes', async () => {
    await makeEditor('Paragraph one.');
    // No structural entry registered -- unified-undo routing falls through on its own.
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage } } };
    vi.useFakeTimers();
    setPendingSlashUndo(true);
    await vi.advanceTimersByTimeAsync(PENDING_SLASH_UNDO_FRESHNESS_MS + 1); // now stale
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    document.dispatchEvent(event);

    // Under the OLD (unbounded) check, this stale flag would have fired the smart-undo
    // branch, calling preventDefault()/stopPropagation() and consuming the keystroke. With
    // the freshness bound, it must NOT fire -- the event is left completely untouched by this
    // handler and falls through to Milkdown's own plain undo keymap, exactly as if no slash
    // command had ever run. NOTE: deliberately NOT asserting on getPendingSlashUndo() here --
    // the unrelated "reset flags on any editing key" block further down in this same handler
    // clears it for ANY single-character key (including 'z') regardless of which branch, if
    // any, actually consumed the event -- the same false-positive shape the original version
    // of this test file's "slash wins" test was written to avoid. event.defaultPrevented and
    // postMessage are the only reliable discriminators of which branch actually ran.
    expect(event.defaultPrevented).toBe(false);
    expect(postMessage).not.toHaveBeenCalled();
    vi.useRealTimers();
  });

  it('handleUnifiedUndoKeydown fires preventDefault, holds the latch, and posts structuralUndoRequested with the right opId when routing decides structural', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    setRegistryEntry('op-42', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-42' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage } } };
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    const consumed = handleUnifiedUndoKeydown(event, view, 'undo');

    expect(consumed).toBe(true);
    expect(event.defaultPrevented).toBe(true);
    expect(isLatched()).toBe(true);
    expect(postMessage).toHaveBeenCalledWith({ opId: 'op-42' });
  });

  it('handleUnifiedUndoKeydown posts structuralRedoRequested (not structuralUndoRequested) for the redo direction', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    setRegistryEntry('op-7', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
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

    const consumed = handleUnifiedUndoKeydown(event, view, 'redo');

    expect(consumed).toBe(true);
    expect(event.defaultPrevented).toBe(true);
    expect(isLatched()).toBe(true);
    expect(redoPost).toHaveBeenCalledWith({ opId: 'op-7' });
    expect(undoPost).not.toHaveBeenCalled();
  });

  it('handleGlobalUndoRedoKeydown normalizes a genuinely shifted Cmd-Shift-Z (key: "Z", not "z") to the redo direction', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    setRegistryEntry('op-9', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
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

    const consumed = handleGlobalUndoRedoKeydown(event, view);

    expect(consumed).toBe(true);
    expect(event.defaultPrevented).toBe(true);
    expect(postMessage).toHaveBeenCalledWith({ opId: 'op-9' });
  });

  it('handleUndoReplyFromSwift performs the suppressed text undo on a "fallback" reply and releases the latch', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    setLatched(true);
    setInFlightOpId('op-1');

    handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'fallback' }, 'undo');

    expect(isLatched()).toBe(false);
    expect(undoDepth(view.state)).toBe(0);
  });

  it('handleUndoReplyFromSwift does nothing beyond releasing the latch on a "performed" reply', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    const depthBefore = undoDepth(view.state);
    setLatched(true);
    setInFlightOpId('op-1');

    handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'performed' }, 'undo');

    expect(isLatched()).toBe(false);
    expect(undoDepth(view.state)).toBe(depthBefore); // no extra undo performed
  });

  it('handleUndoReplyFromSwift ignores a reply that arrives while not latched (stale/duplicate reply guard)', () => {
    expect(isLatched()).toBe(false);

    expect(() => handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'fallback' }, 'undo')).not.toThrow();

    expect(isLatched()).toBe(false);
  });

  // === N5 (Phase B remediation plan): reply must match the specific in-flight opId ===

  it('handleUndoReplyFromSwift ignores a reply for a stale opId even while the latch is held for a DIFFERENT request', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    const depthBefore = undoDepth(view.state);
    setLatched(true);
    setInFlightOpId('op-current'); // the latch is genuinely held, but for a DIFFERENT opId

    // A stale reply for a superseded/earlier request arrives.
    handleUndoReplyFromSwift({ opId: 'op-stale', outcome: 'fallback' }, 'undo');

    // The mismatched reply must be ignored entirely: no text-undo replayed, and the latch
    // (still legitimately held for op-current) must NOT be released by someone else's reply.
    expect(undoDepth(view.state)).toBe(depthBefore);
    expect(isLatched()).toBe(true);
    expect(getInFlightOpId()).toBe('op-current');
  });

  it('a genuine reply for the actual in-flight opId still works correctly (control for the mismatch test above)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    setLatched(true);
    setInFlightOpId('op-current');

    handleUndoReplyFromSwift({ opId: 'op-current', outcome: 'fallback' }, 'undo');

    expect(undoDepth(view.state)).toBe(0);
    expect(isLatched()).toBe(false);
    expect(getInFlightOpId()).toBe(null);
  });

  it('requestStructural (via handleUnifiedUndoKeydown) records the requested opId as in-flight', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    setRegistryEntry('op-99', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-99' });
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage: vi.fn() } } };
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    handleUnifiedUndoKeydown(event, view, 'undo');

    expect(getInFlightOpId()).toBe('op-99');
  });

  // === historyEdited predicate (plan §4.1/§4.6) ===

  it('maybeNotifyHistoryEdited does not post when no structural redo entry exists (constraint 3: zero per-keystroke cost in the steady state)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { historyEdited: { postMessage } } };

    maybeNotifyHistoryEdited(view.state.tr.insertText('X'));

    expect(postMessage).not.toHaveBeenCalled();
  });

  it('maybeNotifyHistoryEdited posts when a real doc-changing edit lands while a structural redo entry exists', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    setUndoDescriptor({ redoTopOpId: 'op-1' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { historyEdited: { postMessage } } };

    maybeNotifyHistoryEdited(view.state.tr.insertText('X'));

    expect(postMessage).toHaveBeenCalledTimes(1);
  });

  it('maybeNotifyHistoryEdited does not post for a sync-origin transaction (addToHistory:false)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    setUndoDescriptor({ redoTopOpId: 'op-1' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { historyEdited: { postMessage } } };

    maybeNotifyHistoryEdited(view.state.tr.insertText('X').setMeta('addToHistory', false));

    expect(postMessage).not.toHaveBeenCalled();
  });

  it('maybeNotifyHistoryEdited does not post for an undo-replay transaction -- pins the canonical redo half (plan §4.1, found wrong twice in review)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    setUndoDescriptor({ redoTopOpId: 'op-1' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { historyEdited: { postMessage } } };

    // Route the REAL transaction prosemirror-history's undo() produces through the
    // predicate -- isHistoryTransaction() checks a plugin-internal meta key that can't be
    // faked by hand-building a Transaction, so this must come from the real command.
    undo(view.state, (tr) => {
      view.updateState(view.state.apply(tr));
      maybeNotifyHistoryEdited(tr);
    });

    expect(postMessage).not.toHaveBeenCalled();
  });

  // === §4.6 advancement rule (maybeAdvanceRegistryOnSyncOriginTx) ===
  // Round-5 must-fix: the rule was documented (§4.6) and even claimed "already shipped" in a
  // stale comment, but no code ever implemented it. These tests exercise the real function.

  it('maybeAdvanceRegistryOnSyncOriginTx does nothing when the registry is empty (constraint 3: near-zero per-keystroke cost)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);

    expect(() =>
      maybeAdvanceRegistryOnSyncOriginTx(view.state.tr.insertText('X').setMeta('addToHistory', false))
    ).not.toThrow();
    expect(getRegistry().size).toBe(0);
  });

  it('maybeAdvanceRegistryOnSyncOriginTx does not advance for a non-sync-origin transaction (addToHistory not false)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    const preOpDoc = view.state.doc;
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc: preOpDoc, preOpDoc });

    maybeAdvanceRegistryOnSyncOriginTx(view.state.tr.insertText('X'));

    expect(getRegistry().get('op-1')?.postOpDoc).toBe(preOpDoc);
  });

  it('maybeAdvanceRegistryOnSyncOriginTx advances postOpDoc when the doc before a sync-origin transaction structurally matches it', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    const opStartDoc = view.state.doc;
    // Simulate the op's own content push landing (this is what postOpDoc gets captured as).
    view.dispatch(view.state.tr.insertText('OP').setMeta('addToHistory', false));
    const postOpDoc = view.state.doc;
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc, preOpDoc: opStartDoc });

    // A later sync-origin transaction -- a delayed bibliography/footnote resync, or RAF-time
    // normalization -- rewrites the doc again (H5).
    const resyncTr = view.state.tr.insertText('RESYNC').setMeta('addToHistory', false);
    view.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    const entry = getRegistry().get('op-1');
    expect(entry?.postOpDoc.eq(view.state.doc)).toBe(true);
    expect(entry?.postOpDoc.eq(postOpDoc)).toBe(false);
    // preOpDoc is untouched -- the resync's "before" doc matched postOpDoc, not preOpDoc.
    expect(entry?.preOpDoc.eq(opStartDoc)).toBe(true);
  });

  it('maybeAdvanceRegistryOnSyncOriginTx advances preOpDoc (redo target) the same way', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    const preOpDoc = view.state.doc;

    // A later sync-origin transaction whose "before" doc is preOpDoc itself.
    const resyncTr = view.state.tr.insertText('RESYNC').setMeta('addToHistory', false);
    view.dispatch(resyncTr);

    // Finalized entry shape: postOpDoc is a DISTINCT object from preOpDoc, as it is once
    // finalizeStructuralOpPostOpDoc has run -- NOT the beginStructuralOp mid-op placeholder
    // shape (postOpDoc === preOpDoc by reference). A placeholder-shaped entry is inert to
    // advancement (see the regression test below) -- this test exercises the real
    // advancement path on an entry that's actually eligible for it.
    const postOpDoc = view.state.doc;
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc, preOpDoc });

    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    expect(getRegistry().get('op-1')?.preOpDoc.eq(resyncTr.doc)).toBe(true);
  });

  it("regression: the op's OWN content push (still mid-op, before finalizeStructuralOpPostOpDoc has run) must not corrupt preOpDoc -- the exact live production bug behind redo2 hanging (notes.md 2026-08-18)", async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    const opStartDoc = view.state.doc;

    // Op-sequence step 3: begin the op. Registers the mid-op placeholder entry --
    // postOpDoc === preOpDoc by reference, per beginStructuralOp's doc comment.
    expect(beginStructuralOp('op-1')).toBe(true);

    // Op-sequence step 6: the op's own content push lands (mirrors setContentWithBlockIds,
    // dispatched with addToHistory:false). main.ts's view.dispatch override calls
    // maybeAdvanceRegistryOnSyncOriginTx on EVERY sync-origin transaction, including this
    // one -- BEFORE finalizeStructuralOpPostOpDoc (step 7) ever runs.
    const pushTr = view.state.tr.insertText('RESTORED').setMeta('addToHistory', false);
    view.dispatch(pushTr);
    maybeAdvanceRegistryOnSyncOriginTx(pushTr);

    // Op-sequence step 7: capture postOpDoc for real.
    expect(finalizeStructuralOpPostOpDoc('op-1')).toBe(true);

    // Without the fix, pushTr.before equals the placeholder postOpDoc (=== preOpDoc), so the
    // §4.6 rule wrongly advances preOpDoc forward onto the post-op doc -- permanently
    // corrupting the redo equality target for this entry's whole lifetime, even though
    // finalizeStructuralOpPostOpDoc correctly repairs postOpDoc right after.
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

  it("regression: a NEW op's own primary content push must not silently advance a DIFFERENT, already-finalized entry's equality target -- the exact restore-then-reorder collision behind the second Cmd-Z silently doing nothing (notes.md 2026-08-18). This must fail without the whole-function mid-op guard.", async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);

    // Op A (e.g. a version restore) begins and finalizes -- entryA.postOpDoc is now a real,
    // distinct document (DOC_A), not the beginStructuralOp placeholder.
    expect(beginStructuralOp('op-A')).toBe(true);
    view.dispatch(view.state.tr.insertText('RESTORED').setMeta('addToHistory', false));
    expect(finalizeStructuralOpPostOpDoc('op-A')).toBe(true);
    const entryABefore = getRegistry().get('op-A');
    const docA = view.state.doc; // === entryA.postOpDoc

    // Op B (e.g. a drag reorder) begins immediately after, with nothing else having changed in
    // between -- beginStructuralOp captures preOpDoc = docA, exactly matching op A's postOpDoc.
    expect(beginStructuralOp('op-B')).toBe(true);

    // Op B's OWN primary content push: a sync-origin transaction whose "before" doc is docA --
    // mirroring exactly what happens when two structural ops run back-to-back with no
    // intervening real edit.
    const pushTrB = view.state.tr.insertText('REORDERED').setMeta('addToHistory', false);
    view.dispatch(pushTrB);
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

  it("maybeAdvanceRegistryOnSyncOriginTx still advances a matching entry when NO entry is mid-op, even with a second finalized entry present -- confirms the cross-entry guard above does not disable the rule's legitimate case (genuine async derived-content churn, e.g. a delayed bibliography/footnote resync landing well after any op has finished)", async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);

    // Op A finalizes.
    expect(beginStructuralOp('op-A')).toBe(true);
    view.dispatch(view.state.tr.insertText('RESTORED').setMeta('addToHistory', false));
    expect(finalizeStructuralOpPostOpDoc('op-A')).toBe(true);
    const entryABefore = getRegistry().get('op-A');

    // Op B ALSO finalizes -- both entries are now finalized (postOpDoc !== preOpDoc for
    // either), so no entry is mid-op by the time the resync below fires.
    expect(beginStructuralOp('op-B')).toBe(true);
    view.dispatch(view.state.tr.insertText('REORDERED').setMeta('addToHistory', false));
    expect(finalizeStructuralOpPostOpDoc('op-B')).toBe(true);
    const docB = view.state.doc; // === entryB.postOpDoc

    // A genuine async derived-content resync lands well after both ops finished, matching op
    // B's postOpDoc (the current live doc) -- this is the rule's actual intended trigger.
    const resyncTr = view.state.tr.insertText('BIB').setMeta('addToHistory', false);
    view.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    // Op B's matching reference advances...
    const entryBAfter = getRegistry().get('op-B');
    expect(entryBAfter?.postOpDoc.eq(view.state.doc)).toBe(true);
    expect(entryBAfter?.postOpDoc.eq(docB)).toBe(false);

    // ...while op A, whose reference doesn't match this transaction's "before" doc, is
    // completely untouched.
    const entryAAfter = getRegistry().get('op-A');
    expect(entryAAfter?.postOpDoc).toBe(entryABefore?.postOpDoc);
    expect(entryAAfter?.preOpDoc).toBe(entryABefore?.preOpDoc);
  });

  it('maybeAdvanceRegistryOnSyncOriginTx does not advance when the transaction is unrelated to either reference', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    const preOpDoc = view.state.doc;
    // A real, non-sync-origin edit moves the live doc away from preOpDoc/postOpDoc first.
    view.dispatch(view.state.tr.insertText('UNRELATED'));
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc: preOpDoc, preOpDoc });

    const resyncTr = view.state.tr.insertText('X').setMeta('addToHistory', false);
    view.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    const entry = getRegistry().get('op-1');
    expect(entry?.postOpDoc.eq(preOpDoc)).toBe(true);
    expect(entry?.preOpDoc.eq(preOpDoc)).toBe(true);
  });

  // === must-fix 3 (judge round review): explicit `midOp` marker coverage ===
  // These exercise the `midOp` field directly (every existing test above only reaches it
  // indirectly via beginStructuralOp/finalizeStructuralOpPostOpDoc) -- see UndoRegistryEntry's
  // doc comment for why a zero-diff op (postOpDoc === preOpDoc by reference, e.g. a Document
  // Note delete) needed this explicit marker in the first place.

  it('a finalized entry (midOp: false) whose preOpDoc === postOpDoc by reference (zero-diff op, e.g. a Document Note delete) does NOT block advancing a DIFFERENT, unrelated entry', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);

    // Zero-diff entry: preOpDoc and postOpDoc are the SAME doc object, but explicitly
    // finalized (midOp: false) -- exactly the shape midOp exists to disambiguate from
    // "still mid-op", which the OLD `postOpDoc === preOpDoc` reference-identity detector could
    // not tell apart.
    const zeroDiffDoc = view.state.doc;
    setRegistryEntry('op-zero-diff', {
      checkpoint: view.state as any,
      postOpDoc: zeroDiffDoc,
      preOpDoc: zeroDiffDoc,
      midOp: false,
    });

    // A second, unrelated, already-finalized entry with a genuinely distinct preOpDoc/postOpDoc.
    view.dispatch(view.state.tr.insertText('RESTORED').setMeta('addToHistory', false));
    const docB = view.state.doc;
    setRegistryEntry('op-B', { checkpoint: view.state as any, postOpDoc: docB, preOpDoc: zeroDiffDoc, midOp: false });

    // A later async derived-content resync (e.g. a delayed bibliography fetch) lands, matching
    // op-B's postOpDoc.
    const resyncTr = view.state.tr.insertText('BIB').setMeta('addToHistory', false);
    view.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    // Without the midOp fix, op-zero-diff's reference-identical postOpDoc/preOpDoc would read
    // as "mid-op" under the old detector, blocking advancement for EVERY entry -- including
    // op-B here.
    const entryB = getRegistry().get('op-B');
    expect(entryB?.postOpDoc.eq(view.state.doc)).toBe(true);
    expect(entryB?.postOpDoc.eq(docB)).toBe(false);
  });

  it('an entry with midOp: true DOES block advancing a different, unrelated entry', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);

    // Op A: finalized, with a distinct preOpDoc/postOpDoc pair.
    const opAStart = view.state.doc;
    view.dispatch(view.state.tr.insertText('RESTORED').setMeta('addToHistory', false));
    const docA = view.state.doc;
    setRegistryEntry('op-A', { checkpoint: view.state as any, postOpDoc: docA, preOpDoc: opAStart, midOp: false });

    // Op B: explicitly mid-op (midOp: true) -- its own doc references don't matter here, only
    // its presence in the registry while mid-op.
    setRegistryEntry('op-B', { checkpoint: view.state as any, postOpDoc: docA, preOpDoc: docA, midOp: true });

    // A sync-origin transaction whose "before" doc matches op-A's postOpDoc.
    const resyncTr = view.state.tr.insertText('BIB').setMeta('addToHistory', false);
    view.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    // op-A must be untouched: op-B being mid-op blocks advancement for the WHOLE registry.
    const entryA = getRegistry().get('op-A');
    expect(entryA?.postOpDoc.eq(docA)).toBe(true);
    expect(entryA?.postOpDoc.eq(view.state.doc)).toBe(false);
  });

  it('an entry with midOp undefined/missing is treated as not-mid-op (defensive default) and does not block advancing a different entry', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);

    // Constructed WITHOUT the midOp field at all (e.g. an older test-constructed entry shape)
    // -- must read as "not mid-op", the documented default for `undefined`.
    const preOpDoc = view.state.doc;
    setRegistryEntry('op-legacy', { checkpoint: view.state as any, postOpDoc: preOpDoc, preOpDoc });
    expect(getRegistry().get('op-legacy')?.midOp).toBeUndefined();

    // A second, unrelated, finalized entry.
    view.dispatch(view.state.tr.insertText('RESTORED').setMeta('addToHistory', false));
    const docB = view.state.doc;
    setRegistryEntry('op-B', { checkpoint: view.state as any, postOpDoc: docB, preOpDoc, midOp: false });

    const resyncTr = view.state.tr.insertText('BIB').setMeta('addToHistory', false);
    view.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    const entryB = getRegistry().get('op-B');
    expect(entryB?.postOpDoc.eq(view.state.doc)).toBe(true);
    expect(entryB?.postOpDoc.eq(docB)).toBe(false);
  });

  it('integration: postOpDoc captured at push-tr keeps tracking through RAF normalization / sync-origin resyncs, and equality routing recognizes the advanced state as reachable (plan §8)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);

    // Op-sequence step 3: begin the op (closeHistory + capture preOpDoc/placeholder postOpDoc).
    expect(beginStructuralOp('op-1')).toBe(true);

    // Op-sequence step 6: the op's own content push lands, then postOpDoc is captured from
    // that push transaction's own resulting doc (step 7) -- deliberately NOT waiting for any
    // later normalization (per finalizeStructuralOpPostOpDoc's doc comment).
    view.dispatch(view.state.tr.insertText('RESTORED').setMeta('addToHistory', false));
    expect(finalizeStructuralOpPostOpDoc('op-1')).toBe(true);
    expect(getRegistry().get('op-1')?.postOpDoc.eq(view.state.doc)).toBe(true);

    // A subsequent sync-origin transaction lands AFTER capture -- e.g. RAF-time normalization
    // or a delayed bibliography/footnote resync (H5) -- rewriting the doc again.
    const resyncTr = view.state.tr.insertText('BIB').setMeta('addToHistory', false);
    view.dispatch(resyncTr);
    maybeAdvanceRegistryOnSyncOriginTx(resyncTr);

    const finalDoc = view.state.doc;
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

  it('clearStructuralUndoRegistry clears the registry and resets the descriptor WITHOUT touching editor text-undo history', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);

    view.dispatch(view.state.tr.insertText('typed text'));
    const depthBefore = undoDepth(view.state);
    expect(depthBefore).toBeGreaterThan(0);

    expect(beginStructuralOp('op-1')).toBe(true);
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    expect(getRegistry().size).toBe(1);

    clearStructuralUndoRegistry();

    expect(getRegistry().size).toBe(0);
    expect(getUndoDescriptor()).toEqual({});
    // The editor's own text-undo history is untouched -- a barrier must not wipe legitimate
    // in-flight typing undo steps, only the now-invalid structural registry/descriptor.
    expect(undoDepth(view.state)).toBe(depthBefore);
  });

  it('clearStructuralUndoState (eviction) removes only the evicted opId from the registry AND clears the editor text-undo history (MF-1, Phase 5 review round)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);

    view.dispatch(view.state.tr.insertText('typed text'));
    expect(undoDepth(e.ctx.get(editorViewCtx).state)).toBeGreaterThan(0);

    expect(beginStructuralOp('op-1')).toBe(true);
    setUndoDescriptor({ undoTopOpId: 'op-1' });

    clearStructuralUndoState('op-1');

    expect(getRegistry().has('op-1')).toBe(false);
    // clearEditorHistory() reconfigures the view via updateState() -- re-fetch the live view
    // rather than trusting the pre-clear `view` reference.
    expect(undoDepth(e.ctx.get(editorViewCtx).state)).toBe(0);
  });

  it("clearStructuralUndoState (eviction) does NOT wipe a DIFFERENT, still-live opId's registry entry -- regression for MF-1 (Phase 5 review round): the eviction path used to call clearStructuralUndoRegistry()/clearRegistry(), a WHOLE-registry wipe. record() (UnifiedUndoService.swift) calls this closure as the LAST step of performStructuralOp -- AFTER that same op's own registry entry was already created and finalized -- so the old whole-registry clear wiped the CURRENT op's own just-recorded entry too, breaking structural undo/redo the moment the stack crossed capacity (op #51+)", async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);

    // 'op-evicted' stands in for the oldest entry that just fell off the undo stack at
    // capacity; 'op-current' stands in for the CURRENT op's own entry, already fully recorded
    // (finalizeStructuralOpPostOpDoc has run) by the time eviction's JS-side clear fires.
    expect(beginStructuralOp('op-evicted')).toBe(true);
    expect(finalizeStructuralOpPostOpDoc('op-evicted')).toBe(true);
    view.dispatch(view.state.tr.insertText('X').setMeta('addToHistory', false));
    expect(beginStructuralOp('op-current')).toBe(true);
    expect(finalizeStructuralOpPostOpDoc('op-current')).toBe(true);
    expect(getRegistry().has('op-evicted')).toBe(true);
    expect(getRegistry().has('op-current')).toBe(true);

    clearStructuralUndoState('op-evicted');

    expect(getRegistry().has('op-evicted')).toBe(false);
    expect(getRegistry().has('op-current')).toBe(true);
  });
});

// === Live-wiring regression: the stale-pendingMapsEmpty redo race (notes.md 2026-08-17/18) ===
//
// Bug: pendingMapsEmpty() used to read block-sync-plugin's hasPendingChanges() directly --
// that map is only CLEARED once Swift's poll drains it via getBlockChanges(), up to
// BlockSyncService's 2.0s cadence, not synchronously when the local 100ms debounce settles.
// A text edit that lands, settles, and leaves the DOCUMENT already matching the routing
// target (docsEqual) could still read hasPendingChanges() === true purely because Swift
// hadn't polled yet -- silently falling through to a text-redo no-op instead of firing the
// structural redo. These tests exercise the REAL block-sync-plugin machinery (not a fake)
// with fake timers standing in for its 100ms debounce, so they fail against the old
// `!hasPendingChanges()` implementation and pass against the fixed `hasUnsettledLocalEdit()`
// one -- Swift's poll never runs in this test environment at all, so the old implementation
// would leave pendingUpdates permanently non-empty for the rest of the test.
describe('undo-coordinator live wiring — stale pendingMapsEmpty redo/undo race', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    vi.useRealTimers();
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    resetBlockIdState();
    resetBlockSyncState();
    setSyncPaused(false);
    resetUndoCoordinatorState();
    setPendingSlashUndo(false);
    delete (window as any).webkit;
  });

  // Mirrors block-sync-pause-race.test.ts's makeEditor, plus history + slash (needed for the
  // real capture-phase keydown wiring under test here).
  async function makeEditorWithBlockSync(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .config(configureSlash)
      .use(blockIdPlugin)
      .use(commonmark)
      .use(gfm)
      .use(highlightPlugin)
      .use(historyPlugin)
      .use(blockSyncPlugin)
      .use(slash)
      .create();
    editor = e;
    setEditorInstance(e);
    return e;
  }

  it('routes structurally when block-sync pending maps are stale-but-settled and the doc already matches the redo target', async () => {
    const e = await makeEditorWithBlockSync('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    const originalDoc = view.state.doc;

    vi.useFakeTimers();

    // Text edit #1 (stands in for the canonical scenario's "redo1: text-redo of A"): diverges
    // the doc, then settle block-sync's 100ms debounce so its diff gets computed and
    // committed into the pending-change maps -- exactly the moment hasPendingChanges()
    // becomes true and (under the old implementation) would stay true until a Swift poll that
    // never happens in this test.
    view.dispatch(view.state.tr.insertText('X'));
    await vi.advanceTimersByTimeAsync(150);
    expect(hasPendingChanges()).toBe(true); // sanity: the stale condition genuinely exists

    // Undo the edit via the editor's OWN text undo (not unified-undo) -- brings the doc back
    // to exactly `originalDoc`, mirroring "the document already matches the routing target"
    // after a chain of real text edits. This is itself a docChanged transaction, so block-sync
    // schedules ANOTHER 100ms debounce for it -- settle that one too so no debounce is
    // in-flight at the moment of the keydown below (the one case this fix does NOT relax).
    undo(view.state, view.dispatch);
    expect(view.state.doc.eq(originalDoc)).toBe(true);
    await vi.advanceTimersByTimeAsync(150);

    // Both debounces have now settled, but Swift never polled -- hasPendingChanges() is still
    // (and, absent a real Swift poll, will remain) true. This is the exact stale-but-safe
    // condition the fix targets.
    expect(hasPendingChanges()).toBe(true);

    setRegistryEntry('op-1', {
      checkpoint: view.state as any,
      postOpDoc: view.state.tr.insertText('POST').doc, // any doc distinct from originalDoc
      preOpDoc: originalDoc,
    });
    setUndoDescriptor({ redoTopOpId: 'op-1' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { structuralRedoRequested: { postMessage } } };
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, shiftKey: true, cancelable: true });

    const consumed = handleUnifiedUndoKeydown(event, view, 'redo');

    expect(consumed).toBe(true);
    expect(event.defaultPrevented).toBe(true);
    expect(postMessage).toHaveBeenCalledWith({ opId: 'op-1' });
  });

  it("still falls through while block-sync's local debounce is actively in flight (the fix is not a blanket bypass)", async () => {
    const e = await makeEditorWithBlockSync('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    const originalDoc = view.state.doc;

    vi.useFakeTimers();

    setRegistryEntry('op-1', {
      checkpoint: view.state as any,
      postOpDoc: view.state.tr.insertText('POST').doc,
      preOpDoc: originalDoc,
    });
    setUndoDescriptor({ redoTopOpId: 'op-1' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { structuralRedoRequested: { postMessage } } };

    // Diverge then revert the doc WITHOUT letting either debounce settle -- a transaction
    // landed within the last 100ms and block-sync hasn't diffed it yet.
    view.dispatch(view.state.tr.insertText('X'));
    undo(view.state, view.dispatch);
    expect(view.state.doc.eq(originalDoc)).toBe(true);

    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, shiftKey: true, cancelable: true });
    const consumed = handleUnifiedUndoKeydown(event, view, 'redo');

    expect(consumed).toBe(false); // fallthrough: let Milkdown's own keymap handle it
    expect(postMessage).not.toHaveBeenCalled();
  });
});

// === N8 (Phase B remediation plan): the latch self-clear timeout (3s then; 30s since Phase 4b part 2, plan D9) ===
// Zero test coverage previously existed for this belt-and-braces mechanism (a lost Swift
// reply -- multi-window mismatch bailing without one, a torn-down WebView, a crash
// mid-sequence -- must not swallow every future Cmd-Z/Cmd-Shift-Z for the rest of the
// session). Uses the same real-editor-plus-fake-timers pattern already established above
// (the "stale pendingMapsEmpty redo/undo race" describe block).
describe('undo-coordinator latch self-clear timeout (N8)', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    vi.useRealTimers();
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    resetUndoCoordinatorState();
    delete (window as any).webkit;
  });

  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(blockIdPlugin)
      .use(commonmark)
      .use(gfm)
      .use(historyPlugin)
      .create();
    editor = e;
    setEditorInstance(e);
    return e;
  }

  it('self-clears the latch after 30s with no reply from Swift, so a later Cmd-Z is not held forever', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage: vi.fn() } } };
    vi.useFakeTimers();

    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    handleUnifiedUndoKeydown(event, view, 'undo');
    expect(isLatched()).toBe(true); // request sent, latch held, no reply has arrived yet

    await vi.advanceTimersByTimeAsync(30000);

    expect(isLatched()).toBe(false); // self-cleared, not stuck forever
    expect(getInFlightOpId()).toBe(null);
  });

  it('does NOT self-clear before 30s -- a reply that genuinely takes a while is not preempted', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage: vi.fn() } } };
    vi.useFakeTimers();

    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    handleUnifiedUndoKeydown(event, view, 'undo');

    await vi.advanceTimersByTimeAsync(29999);

    expect(isLatched()).toBe(true);
  });

  it('a genuine reply that arrives before the timeout cancels the pending timer, so it cannot later fire against a newer request', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage: vi.fn() } } };
    vi.useFakeTimers();

    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    handleUnifiedUndoKeydown(event, view, 'undo');
    handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'performed' }, 'undo');
    expect(isLatched()).toBe(false);

    // Let 1s elapse before the second request, so the (already-cleared) first timer's
    // ORIGINAL fire time (t=30000ms from its own scheduling) and the second timer's fire time
    // (t=1000ms + 30000ms = t=31000ms overall) are distinguishable -- without this gap, both
    // timers would be scheduled at the same virtual instant and this test couldn't tell
    // "cancelled" apart from "coincidentally fires at the same time as the new one".
    await vi.advanceTimersByTimeAsync(1000);

    // A second, later request now latches for a NEW opId.
    setRegistryEntry('op-2', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-2' });
    const event2 = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    handleUnifiedUndoKeydown(event2, view, 'undo');
    expect(getInFlightOpId()).toBe('op-2');

    // Advance to t=30000ms overall -- exactly when the FIRST request's original timer would
    // have fired had it not been cancelled, but 1s BEFORE the second request's own fresh 30s
    // window elapses (t=31000ms). If the first (already-cleared) timer were still live, it
    // would fire here and could clear the second request's latch prematurely --
    // clearLatchTimeout() on the first reply must have prevented that.
    await vi.advanceTimersByTimeAsync(29000);

    expect(isLatched()).toBe(true);
    expect(getInFlightOpId()).toBe('op-2');
  });
});

// === Phase 4b part 2, plan D9 + A3 + A4: presses made while the latch is held are queued, not dropped ===
// Before: a Cmd-Z / Cmd-Shift-Z pressed while a structural undo was in flight was swallowed (and the latch timed out after 3s).
// Now the press is held in a FIFO and routed, deciding afresh against the live document, when Swift's reply for the in-flight
// request arrives. Text presses made while the latch is held queue too, so the order the user pressed them in is kept.
describe('undo-coordinator press queue behind the in-flight latch (D9, A3, A4)', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    vi.useRealTimers();
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    resetUndoCoordinatorState();
    delete (window as any).webkit;
  });

  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(blockIdPlugin)
      .use(commonmark)
      .use(gfm)
      .use(historyPlugin)
      .create();
    editor = e;
    setEditorInstance(e);
    return e;
  }

  /** One keydown. `repeat` is true for the auto-repeat events a held-down key keeps sending. */
  const press = (view: EditorView, direction: 'undo' | 'redo' = 'undo', repeat = false) => {
    const event = new KeyboardEvent('keydown', {
      key: 'z',
      metaKey: true,
      shiftKey: direction === 'redo',
      repeat,
      cancelable: true,
    });
    const consumed = handleUnifiedUndoKeydown(event, view, direction);
    return { consumed, event };
  };

  function messages() {
    const undoRequested = vi.fn();
    const redoRequested = vi.fn();
    const queueDropped = vi.fn();
    const heldSettled = vi.fn();
    (window as any).webkit = {
      messageHandlers: {
        structuralUndoRequested: { postMessage: undoRequested },
        structuralRedoRequested: { postMessage: redoRequested },
        undoQueueDropped: { postMessage: queueDropped },
        undoHeldPressSettled: { postMessage: heldSettled },
      },
    };
    return { undoRequested, redoRequested, queueDropped, heldSettled };
  }

  function registerOps(view: EditorView, ...opIds: string[]): void {
    for (const opId of opIds) {
      setRegistryEntry(opId, { checkpoint: view.state, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    }
  }

  it('W7: with the latch held, two structural presses become two queued routes, run in order after each reply, none dropped', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A', 'op-B', 'op-C');
    const { undoRequested, queueDropped } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });

    const first = press(view);
    expect(first.consumed).toBe(true);
    expect(undoRequested).toHaveBeenCalledTimes(1);
    expect(undoRequested).toHaveBeenLastCalledWith({ opId: 'op-A' });
    expect(getInFlightOpId()).toBe('op-A');

    // Two more presses while op-A is still in flight: both consumed (no default action, no editor undo) and held.
    const second = press(view);
    const third = press(view);
    expect(second.consumed).toBe(true);
    expect(second.event.defaultPrevented).toBe(true);
    expect(third.consumed).toBe(true);
    expect(third.event.defaultPrevented).toBe(true);
    expect(getQueuedPressDirections()).toEqual(['undo', 'undo']);
    expect(undoRequested).toHaveBeenCalledTimes(1); // nothing sent yet

    // Swift performs op-A (its descriptor now points at op-B) and replies: the next held press is routed, fresh.
    setUndoDescriptor({ undoTopOpId: 'op-B' });
    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'performed' }, 'undo');
    expect(undoRequested).toHaveBeenCalledTimes(2);
    expect(undoRequested).toHaveBeenLastCalledWith({ opId: 'op-B', held: true });
    expect(isLatched()).toBe(true);
    expect(getQueuedPressDirections()).toEqual(['undo']);

    setUndoDescriptor({ undoTopOpId: 'op-C' });
    handleUndoReplyFromSwift({ opId: 'op-B', outcome: 'performed' }, 'undo');
    expect(undoRequested).toHaveBeenCalledTimes(3);
    expect(undoRequested).toHaveBeenLastCalledWith({ opId: 'op-C', held: true });
    expect(getQueuedPressDirections()).toEqual([]);

    handleUndoReplyFromSwift({ opId: 'op-C', outcome: 'performed' }, 'undo');
    expect(isLatched()).toBe(false);
    expect(undoRequested.mock.calls.map((c) => c[0])).toEqual([
      { opId: 'op-A' },
      { opId: 'op-B', held: true },
      { opId: 'op-C', held: true },
    ]);
    expect(queueDropped).not.toHaveBeenCalled();
  });

  it("a held press is routed afresh: if the top of the timeline is no longer structural it runs the editor's own undo", async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    const depthBefore = undoDepth(view.state);
    expect(depthBefore).toBeGreaterThan(0);
    registerOps(view, 'op-A');
    const { undoRequested } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    // The registered entry's postOpDoc is the document as it stands (typed X included), so the first press routes structurally.
    expect(press(view).consumed).toBe(true);
    expect(getInFlightOpId()).toBe('op-A');

    // A press made while the latch is held: held, and the editor's own undo has NOT run.
    const held = press(view);
    expect(held.consumed).toBe(true);
    expect(held.event.defaultPrevented).toBe(true);
    expect(undoDepth(view.state)).toBe(depthBefore);
    expect(getQueuedPressDirections()).toEqual(['undo']);

    // Swift performed op-A: nothing structural is left on top, so the held press falls through to the text undo, called directly.
    setUndoDescriptor({});
    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'performed' }, 'undo');
    expect(undoDepth(view.state)).toBe(depthBefore - 1);
    expect(getQueuedPressDirections()).toEqual([]);
    expect(isLatched()).toBe(false);
    expect(undoRequested).toHaveBeenCalledTimes(1);
  });

  it('a "fallback" reply replays its own text undo first, then the held presses run in order', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    // Two separate history steps (a 600 ms pause between them is what prosemirror-history groups on, so close the group by hand).
    view.dispatch(view.state.tr.insertText('X'));
    view.dispatch(closeHistory(view.state.tr));
    view.dispatch(view.state.tr.insertText('Y', 1));
    expect(undoDepth(view.state)).toBe(2);
    registerOps(view, 'op-A');
    messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    press(view); // routed structurally, latch held
    press(view); // held
    setUndoDescriptor({});

    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'fallback' }, 'undo');

    // One text undo for the fallback itself and one for the held press.
    expect(undoDepth(view.state)).toBe(0);
    expect(getQueuedPressDirections()).toEqual([]);
  });

  it('the menu path queues too (requestUnifiedUndo while latched keeps the press instead of dropping it)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A');
    messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    press(view);
    expect(isLatched()).toBe(true);

    requestUnifiedUndo();
    requestUnifiedRedo();

    expect(getQueuedPressDirections()).toEqual(['undo', 'redo']);
  });

  it('a "failed" reply drops the held presses and tells Swift once (they must not run against an editor that disagrees with the database)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A');
    const { queueDropped } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    press(view);
    press(view);
    press(view);

    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'failed' }, 'undo');

    expect(getQueuedPressDirections()).toEqual([]);
    expect(isLatched()).toBe(false);
    expect(queueDropped).toHaveBeenCalledTimes(1);
    expect(queueDropped).toHaveBeenCalledWith({ count: 2 });
  });

  it('W8 barrierClearsLatchAndQueue: the barrier clear releases the latch, forgets the in-flight opId and the queue, and cancels the timer', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    const depthBefore = undoDepth(view.state);
    registerOps(view, 'op-A');
    const { queueDropped } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    vi.useFakeTimers();
    press(view);
    press(view);
    press(view, 'redo');
    expect(isLatched()).toBe(true);
    expect(getQueuedPressDirections()).toEqual(['undo', 'redo']);

    clearStructuralUndoRegistry(); // the barrier (project switch, close, mode switch)

    expect(isLatched()).toBe(false);
    expect(getInFlightOpId()).toBe(null);
    expect(getQueuedPressDirections()).toEqual([]);
    expect(getRegistry().size).toBe(0);
    // The safety-net timer died with the latch: 30s later nothing is reported.
    await vi.advanceTimersByTimeAsync(30000);
    expect(queueDropped).not.toHaveBeenCalled();
    // A late reply for the request the barrier cancelled is ignored: no stray text undo.
    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'fallback' }, 'undo');
    expect(undoDepth(view.state)).toBe(depthBefore);
    // And the next press is not held: with nothing structural on top it falls through to the editor's own undo.
    const next = press(view);
    expect(next.consumed).toBe(false);
  });

  it('W9 latchSafetyNetReportsDroppedPresses: on the 30s timeout with presses queued, exactly one undoQueueDropped message is posted', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A');
    const { queueDropped } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    vi.useFakeTimers();
    press(view);
    press(view);
    press(view, 'redo');
    expect(getQueuedPressDirections()).toEqual(['undo', 'redo']);

    await vi.advanceTimersByTimeAsync(29999);
    expect(queueDropped).not.toHaveBeenCalled();
    expect(isLatched()).toBe(true);

    await vi.advanceTimersByTimeAsync(1);

    expect(queueDropped).toHaveBeenCalledTimes(1);
    expect(queueDropped).toHaveBeenCalledWith({ count: 2 });
    expect(isLatched()).toBe(false);
    expect(getInFlightOpId()).toBe(null);
    expect(getQueuedPressDirections()).toEqual([]);
    await vi.advanceTimersByTimeAsync(60000);
    expect(queueDropped).toHaveBeenCalledTimes(1); // once, not again
  });

  it('W9 control: a timeout with nothing queued posts no undoQueueDropped message (only the latch clears)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A');
    const { queueDropped } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    vi.useFakeTimers();
    press(view);

    await vi.advanceTimersByTimeAsync(30000);

    expect(isLatched()).toBe(false);
    expect(queueDropped).not.toHaveBeenCalled();
  });

  // === Fix round 2a, item 3 (JS half): the `cancelled` reply ===
  // Swift cancels a Cmd-Z / Cmd-Shift-Z that arrives (or was waiting) when a close, quit or project switch has started. The
  // old reply for that was `fallback`, which made JS replay a PLAIN TEXT undo -- and the closing save then wrote it,
  // silently removing the user's latest typing. `cancelled` must leave the document alone and drop the held presses quietly.

  it('W8 variant: a cancelled reply clears the latch and drops the held presses silently, replays no text undo and leaves the document untouched', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X')); // typing a stray text undo would remove
    registerOps(view, 'op-A');
    const { undoRequested, queueDropped } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    vi.useFakeTimers();
    press(view); // Cmd-Z: routed structurally, latch held
    press(view); // Cmd-Z, held
    press(view, 'redo'); // Cmd-Shift-Z, held
    expect(getQueuedPressDirections()).toEqual(['undo', 'redo']);
    const docBefore = view.state.doc;
    const undoDepthBefore = undoDepth(view.state);
    const redoDepthBefore = redoDepth(view.state);
    let transactionsDispatched = 0;
    const dispatch = view.dispatch;
    view.dispatch = (tr) => {
      transactionsDispatched++;
      dispatch(tr);
    };

    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'cancelled' }, 'undo');

    expect(isLatched()).toBe(false);
    expect(getInFlightOpId()).toBe(null);
    expect(getQueuedPressDirections()).toEqual([]);
    // Byte for byte the same document: not one transaction ran (same object, not merely an equal one), history untouched.
    expect(transactionsDispatched).toBe(0);
    expect(view.state.doc).toBe(docBefore);
    expect(undoDepth(view.state)).toBe(undoDepthBefore);
    expect(redoDepth(view.state)).toBe(redoDepthBefore);
    expect(undoRequested).toHaveBeenCalledTimes(1); // the held presses were not routed either
    expect(queueDropped).not.toHaveBeenCalled(); // no "presses could not be carried out" warning: the window is closing
    await vi.advanceTimersByTimeAsync(30000);
    expect(queueDropped).not.toHaveBeenCalled(); // the safety-net timer died with the reply

    // The latch is free again: the next press is routed, not held.
    expect(press(view).consumed).toBe(true);
    expect(undoRequested).toHaveBeenCalledTimes(2);
    expect(getQueuedPressDirections()).toEqual([]);
  });

  it('a cancelled reply to a redo behaves the same (receiveRedoOutcome), held presses dropped silently', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    registerOps(view, 'op-A');
    const { redoRequested, queueDropped } = messages();
    setUndoDescriptor({ redoTopOpId: 'op-A' });
    press(view, 'redo');
    press(view);
    press(view);
    expect(redoRequested).toHaveBeenCalledWith({ opId: 'op-A' });
    expect(getQueuedPressDirections()).toEqual(['undo', 'undo']);
    const docBefore = view.state.doc;
    const undoDepthBefore = undoDepth(view.state);

    receiveRedoOutcome('op-A', 'cancelled');

    expect(isLatched()).toBe(false);
    expect(getQueuedPressDirections()).toEqual([]);
    expect(view.state.doc).toBe(docBefore);
    expect(undoDepth(view.state)).toBe(undoDepthBefore);
    expect(queueDropped).not.toHaveBeenCalled();
  });

  it('a cancelled reply for a stale opId is ignored like any other stale reply (the latch still belongs to the real request)', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A');
    messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    press(view);
    press(view);

    receiveUndoOutcome('op-OTHER', 'cancelled');

    expect(isLatched()).toBe(true);
    expect(getInFlightOpId()).toBe('op-A');
    expect(getQueuedPressDirections()).toEqual(['undo']);
  });

  // === Fix round 2a, item 7: auto-repeat keydowns are not presses ===

  it('W7 variant: holding the key down during a slow undo queues nothing: exactly one press is performed', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A', 'op-B');
    const { undoRequested, queueDropped } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });

    const first = press(view); // the key goes down
    expect(first.consumed).toBe(true);
    expect(undoRequested).toHaveBeenCalledTimes(1);
    for (let i = 0; i < 40; i++) {
      const repeat = press(view, 'undo', true); // the OS keeps sending auto-repeat while the undo runs
      expect(repeat.consumed).toBe(true); // consumed: the editor's own keymap must not run a text undo for it
      expect(repeat.event.defaultPrevented).toBe(true);
    }
    expect(getQueuedPressDirections()).toEqual([]);
    expect(getInFlightOpId()).toBe('op-A');

    // Swift finishes op-A and (as it would) points the descriptor at op-B: nothing was held, so nothing more is routed.
    setUndoDescriptor({ undoTopOpId: 'op-B' });
    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'performed' }, 'undo');
    expect(isLatched()).toBe(false);
    expect(undoRequested).toHaveBeenCalledTimes(1);
    expect(queueDropped).not.toHaveBeenCalled();
  });

  it('separate taps still queue, in order, while auto-repeat events between them are ignored', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A');
    messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    press(view);

    press(view, 'undo', true);
    press(view, 'undo', true);
    press(view, 'undo'); // a distinct tap
    press(view, 'undo', true);
    press(view, 'redo'); // another distinct tap
    press(view, 'redo', true);

    expect(getQueuedPressDirections()).toEqual(['undo', 'redo']);
  });

  it('a held-down key never produces the "presses could not be carried out" warning: not on the 30s safety net, not on a failed reply', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A');
    const { queueDropped } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    vi.useFakeTimers();
    press(view);
    for (let i = 0; i < 60; i++) press(view, 'undo', true);
    expect(getQueuedPressDirections()).toEqual([]);

    await vi.advanceTimersByTimeAsync(30000); // Swift never replies: the safety net clears the latch

    expect(isLatched()).toBe(false);
    expect(queueDropped).not.toHaveBeenCalled(); // nothing had been queued, so nothing was dropped

    // And a failed reply with only auto-repeat presses behind it warns about nothing either.
    press(view);
    for (let i = 0; i < 60; i++) press(view, 'undo', true);
    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'failed' }, 'undo');
    expect(queueDropped).not.toHaveBeenCalled();
  });

  // === Slice 2a, "Cmd-Z, Cmd-Z, Cmd-W": the held presses Swift's close must let through its closed gate ===
  // When a close starts Swift asks `heldUndoPressCount()` how many presses the editor is holding, lets exactly that many
  // through, and waits until each one has arrived as a request (marked `held: true`) or has been reported as ended without one
  // (`undoHeldPressSettled`).

  it('heldUndoPressCount: 0 with nothing held, 2 after two presses behind a held latch, 0 once the replies have drained them', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A', 'op-B', 'op-C');
    messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    expect(heldUndoPressCount()).toBe(0);

    press(view); // goes straight to Swift: in flight, not held
    expect(heldUndoPressCount()).toBe(0);
    press(view);
    press(view);
    expect(heldUndoPressCount()).toBe(2);
    press(view, 'undo', true); // an auto-repeat event is not a held press
    expect(heldUndoPressCount()).toBe(2);

    setUndoDescriptor({ undoTopOpId: 'op-B' });
    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'performed' }, 'undo');
    expect(heldUndoPressCount()).toBe(1); // one drained into a request, one still held
    setUndoDescriptor({ undoTopOpId: 'op-C' });
    handleUndoReplyFromSwift({ opId: 'op-B', outcome: 'performed' }, 'undo');
    expect(heldUndoPressCount()).toBe(0);
    handleUndoReplyFromSwift({ opId: 'op-C', outcome: 'performed' }, 'undo');
    expect(heldUndoPressCount()).toBe(0);
  });

  it('requests drained from the queue carry held: true (undo and redo); a first, direct request does not carry the field', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A', 'op-B', 'op-R');
    const { undoRequested, redoRequested } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });

    press(view); // direct
    press(view); // held
    press(view, 'redo'); // held
    expect(undoRequested.mock.calls).toEqual([[{ opId: 'op-A' }]]);
    expect('held' in undoRequested.mock.calls[0][0]).toBe(false);

    setUndoDescriptor({ undoTopOpId: 'op-B', redoTopOpId: 'op-R' });
    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'performed' }, 'undo');
    expect(undoRequested.mock.calls[1]).toEqual([{ opId: 'op-B', held: true }]);

    setUndoDescriptor({ redoTopOpId: 'op-R' });
    handleUndoReplyFromSwift({ opId: 'op-B', outcome: 'performed' }, 'undo');
    expect(redoRequested.mock.calls).toEqual([[{ opId: 'op-R', held: true }]]);
  });

  it('a drained press that falls through to a text undo posts undoHeldPressSettled {count: 1} and no structural request', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    const depthBefore = undoDepth(view.state);
    registerOps(view, 'op-A');
    const { undoRequested, redoRequested, heldSettled, queueDropped } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    press(view); // direct
    press(view); // held
    expect(heldSettled).not.toHaveBeenCalled(); // still held: nothing has ended yet

    setUndoDescriptor({}); // nothing structural is left on top
    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'performed' }, 'undo');

    expect(undoDepth(view.state)).toBe(depthBefore - 1); // the held press ran as the editor's own undo
    expect(heldSettled).toHaveBeenCalledTimes(1);
    expect(heldSettled).toHaveBeenCalledWith({ count: 1 });
    expect(undoRequested).toHaveBeenCalledTimes(1); // only the first, direct request
    expect(redoRequested).not.toHaveBeenCalled();
    expect(queueDropped).not.toHaveBeenCalled();
    expect(heldUndoPressCount()).toBe(0);
  });

  it('a cancelled reply with two held presses posts undoHeldPressSettled {count: 2}, no undoQueueDropped, and runs no text undo', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('X'));
    registerOps(view, 'op-A');
    const { queueDropped, heldSettled } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    press(view);
    press(view);
    press(view);
    expect(heldUndoPressCount()).toBe(2);
    const docBefore = view.state.doc;

    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'cancelled' }, 'undo');

    expect(heldSettled).toHaveBeenCalledTimes(1);
    expect(heldSettled).toHaveBeenCalledWith({ count: 2 });
    expect(queueDropped).not.toHaveBeenCalled();
    expect(view.state.doc).toBe(docBefore);
    expect(heldUndoPressCount()).toBe(0);
  });

  it('a cancelled reply with nothing held posts nothing at all', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A');
    const { queueDropped, heldSettled } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    press(view);

    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'cancelled' }, 'undo');

    expect(heldSettled).not.toHaveBeenCalled();
    expect(queueDropped).not.toHaveBeenCalled();
  });

  it('a failed reply posts both undoQueueDropped (the warning) and undoHeldPressSettled with the same count', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A');
    const { queueDropped, heldSettled } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    press(view);
    press(view);
    press(view);

    handleUndoReplyFromSwift({ opId: 'op-A', outcome: 'failed' }, 'undo');

    expect(queueDropped).toHaveBeenCalledTimes(1);
    expect(queueDropped).toHaveBeenCalledWith({ count: 2 });
    expect(heldSettled).toHaveBeenCalledTimes(1);
    expect(heldSettled).toHaveBeenCalledWith({ count: 2 });
  });

  it('the 30s safety net posts both undoQueueDropped and undoHeldPressSettled with the same count, once each', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A');
    const { queueDropped, heldSettled } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    vi.useFakeTimers();
    press(view);
    press(view);
    press(view, 'redo');

    await vi.advanceTimersByTimeAsync(30000);

    expect(queueDropped).toHaveBeenCalledTimes(1);
    expect(queueDropped).toHaveBeenCalledWith({ count: 2 });
    expect(heldSettled).toHaveBeenCalledTimes(1);
    expect(heldSettled).toHaveBeenCalledWith({ count: 2 });
    await vi.advanceTimersByTimeAsync(60000);
    expect(heldSettled).toHaveBeenCalledTimes(1);
  });

  it('a barrier clear reports the presses it discards as settled (no warning), so a close that counted them never waits; nothing held posts nothing', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    registerOps(view, 'op-A');
    const { queueDropped, heldSettled } = messages();
    setUndoDescriptor({ undoTopOpId: 'op-A' });
    press(view);
    press(view);
    press(view, 'redo');

    clearStructuralUndoRegistry();

    expect(heldSettled).toHaveBeenCalledTimes(1);
    expect(heldSettled).toHaveBeenCalledWith({ count: 2 });
    expect(queueDropped).not.toHaveBeenCalled();

    heldSettled.mockClear();
    clearStructuralUndoRegistry(); // nothing held now
    expect(heldSettled).not.toHaveBeenCalled();
  });
});
