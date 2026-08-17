// @vitest-environment jsdom
// Phase 2 exit-criteria tests (docs/plans/patient-rewinding-clockwork.md §7 Phase 2, §8):
// (1) a routing truth table against fake registries -- pure, no real editor needed; and
// (2) live-wiring proofs that with the Phase 2 permanently-empty registry, every path
// (keyboard interceptor, menu-path requestUnifiedUndo/Redo, the Swift reply handler)
// behaves EXACTLY like Milkdown's own undo/redo with no unified-undo wiring at all.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { redoDepth, undo, undoDepth } from '@milkdown/kit/prose/history';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { getPendingSlashUndo, setEditorInstance, setPendingSlashUndo } from '../editor-state';
import { configureSlash, slash } from '../slash-commands';
import {
  decideRedoRouting,
  decideUndoRouting,
  handleGlobalUndoRedoKeydown,
  handleUndoReplyFromSwift,
  handleUnifiedUndoKeydown,
  isLatched,
  maybeNotifyHistoryEdited,
  requestUnifiedRedo,
  requestUnifiedUndo,
  resetUndoCoordinatorState,
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

  it("slash's smart-undo pending-flag window takes priority over unified-undo routing (merged handler, not a double listener)", async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    // Configure the registry so that, IF unified-undo's own branch were reached for this
    // keystroke, it would make a real 'structural' decision (preventDefault + latch +
    // postMessage) -- a genuine discriminator (review finding: the previous version of this
    // test only asserted pendingSlashUndo cleared, which happens on ANY single-character
    // keypress via the unrelated "reset flags" block further down in this same handler,
    // regardless of which branch -- or no branch at all -- actually ran; it would still have
    // passed with unified-undo's handler deleted entirely).
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage } } };
    // Simulates "a slash command just ran" without actually running one -- the real
    // production integration point is the single document-level capture listener
    // registered by configureSlash(), which contains BOTH branches merged in code order.
    setPendingSlashUndo(true);
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    document.dispatchEvent(event);

    // Slash's branch consumed the keystroke (its unconditional setPendingSlashUndo(false)
    // ran, and it calls preventDefault() itself)...
    expect(getPendingSlashUndo()).toBe(false);
    expect(event.defaultPrevented).toBe(true);
    // ...but unified-undo's OWN branch never got a turn: no structural request was posted
    // and the latch was never taken, even though the registry above was deliberately set up
    // so it WOULD have posted one had it been reached -- the actual regression a
    // double-listener (or wrong ordering) would cause.
    expect(postMessage).not.toHaveBeenCalled();
    expect(isLatched()).toBe(false);
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

    handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'performed' }, 'undo');

    expect(isLatched()).toBe(false);
    expect(undoDepth(view.state)).toBe(depthBefore); // no extra undo performed
  });

  it('handleUndoReplyFromSwift ignores a reply that arrives while not latched (stale/duplicate reply guard)', () => {
    expect(isLatched()).toBe(false);

    expect(() => handleUndoReplyFromSwift({ opId: 'op-1', outcome: 'fallback' }, 'undo')).not.toThrow();

    expect(isLatched()).toBe(false);
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
});
