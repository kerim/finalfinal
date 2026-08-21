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
  getRegistry,
  getUndoDescriptor,
  handleGlobalUndoRedoKeydown,
  handleUndoReplyFromSwift,
  handleUnifiedUndoKeydown,
  isLatched,
  maybeAdvanceRegistryOnSyncOriginTx,
  maybeNotifyHistoryEdited,
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

// === N8 (Phase B remediation plan): the 3s latch self-clear timeout ===
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

  it('self-clears the latch after 3s with no reply from Swift, so a later Cmd-Z is not swallowed forever', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage: vi.fn() } } };
    vi.useFakeTimers();

    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    handleUnifiedUndoKeydown(event, view, 'undo');
    expect(isLatched()).toBe(true); // request sent, latch held, no reply has arrived yet

    await vi.advanceTimersByTimeAsync(3000);

    expect(isLatched()).toBe(false); // self-cleared, not stuck forever
    expect(getInFlightOpId()).toBe(null);
  });

  it('does NOT self-clear before 3s -- a reply that genuinely takes a while is not preempted', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    setRegistryEntry('op-1', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-1' });
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage: vi.fn() } } };
    vi.useFakeTimers();

    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    handleUnifiedUndoKeydown(event, view, 'undo');

    await vi.advanceTimersByTimeAsync(2999);

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
    // ORIGINAL fire time (t=3000ms from its own scheduling) and the second timer's fire time
    // (t=1000ms + 3000ms = t=4000ms overall) are distinguishable -- without this gap, both
    // timers would be scheduled at the same virtual instant and this test couldn't tell
    // "cancelled" apart from "coincidentally fires at the same time as the new one".
    await vi.advanceTimersByTimeAsync(1000);

    // A second, later request now latches for a NEW opId.
    setRegistryEntry('op-2', { checkpoint: view.state as any, postOpDoc: view.state.doc, preOpDoc: view.state.doc });
    setUndoDescriptor({ undoTopOpId: 'op-2' });
    const event2 = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    handleUnifiedUndoKeydown(event2, view, 'undo');
    expect(getInFlightOpId()).toBe('op-2');

    // Advance to t=3000ms overall -- exactly when the FIRST request's original timer would
    // have fired had it not been cancelled, but 1s BEFORE the second request's own fresh 3s
    // window elapses (t=4000ms). If the first (already-cleared) timer were still live, it
    // would fire here and could clear the second request's latch prematurely --
    // clearLatchTimeout() on the first reply must have prevented that.
    await vi.advanceTimersByTimeAsync(2000);

    expect(isLatched()).toBe(true);
    expect(getInFlightOpId()).toBe('op-2');
  });
});
