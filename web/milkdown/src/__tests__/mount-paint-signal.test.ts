// @vitest-environment jsdom
// Regression tests for the mount-flash fix (doc-open-blank-regression follow-up): Swift's
// token-based cloak system (beginCloak/endCloak, MilkdownCoordinator+MessageHandlers.swift)
// relies on exactly one `paintComplete` postMessage per cloak, and on `clearEditorHistory()`'s
// TWO callers staying divergent -- `resetForProjectSwitch()` (a structural rebuild, cloaked)
// must signal; `clearStructuralUndoState()` (ordinary undo-stack eviction during normal
// editing, deliberately left uncloaked -- see that function's own doc comment in
// undo-coordinator.ts) must NOT. A regression on either side would either leave the WebView
// stuck hidden (falling back to Swift's ~2.5s fallback timer every time) or introduce a new
// flicker on ordinary typing once the undo stack crosses capacity (op #51+).

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { clearEditorHistory, resetForProjectSwitch, signalMountPaintComplete } from '../api-content';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import {
  beginStructuralOp,
  clearStructuralUndoState,
  resetUndoCoordinatorState,
  setUndoDescriptor,
} from '../undo-coordinator';

describe('mount-paint-signal: paintComplete posting around clearEditorHistory()’s two callers', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    // Loop, not a single flush: signalPaintComplete schedules a rAF-inside-a-rAF chain (see
    // block-sync-document-start.test.ts's identical note on its own signalPaintComplete
    // afterEach) -- a single runOnlyPendingTimersAsync() call only drains timers that were
    // ALREADY pending when it started, leaving the inner rAF (registered mid-flush by the
    // outer one) to leak into whichever test runs next.
    if (vi.isFakeTimers()) {
      while (vi.getTimerCount() > 0) {
        await vi.runOnlyPendingTimersAsync();
      }
    }
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
    delete (window as any).webkit;
  });

  // Mirrors clear-history.test.ts's makeEditor: blockIdPlugin before commonmark/gfm, history
  // last -- same plugin registration order main.ts uses in production.
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

  it('resetForProjectSwitch() posts exactly one paintComplete signal, echoing the cloak token', async () => {
    await makeEditor('Project A content.');
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };
    vi.useFakeTimers();

    resetForProjectSwitch(42);

    while (vi.getTimerCount() > 0) {
      await vi.runOnlyPendingTimersAsync();
    }

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ reason: 'projectReset', token: 42 }));
  });

  it('resetForProjectSwitch() called with no token (resetEditorState()’s project-close caller) still posts, with no `token` key', async () => {
    await makeEditor('Project A content.');
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };
    vi.useFakeTimers();

    resetForProjectSwitch();

    while (vi.getTimerCount() > 0) {
      await vi.runOnlyPendingTimersAsync();
    }

    expect(postMessage).toHaveBeenCalledTimes(1);
    const body = postMessage.mock.calls[0][0];
    expect(body.reason).toBe('projectReset');
    expect(body.token).toBeUndefined();
  });

  it('clearEditorHistory() called directly (not via resetForProjectSwitch) posts no paintComplete signal -- regression guard', async () => {
    const e = await makeEditor('Project A content.');
    const view = e.ctx.get(editorViewCtx);
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };
    vi.useFakeTimers();

    clearEditorHistory(view);

    while (vi.getTimerCount() > 0) {
      await vi.runOnlyPendingTimersAsync();
    }

    expect(postMessage).not.toHaveBeenCalled();
  });

  it('clearStructuralUndoState() (ordinary undo-stack eviction, op #51+) posts no paintComplete signal -- must stay flicker-free', async () => {
    const e = await makeEditor('Paragraph one.');
    const view = e.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.insertText('typed text'));
    expect(beginStructuralOp('op-1')).toBe(true);
    setUndoDescriptor({ undoTopOpId: 'op-1' });

    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };
    vi.useFakeTimers();

    clearStructuralUndoState('op-1');

    while (vi.getTimerCount() > 0) {
      await vi.runOnlyPendingTimersAsync();
    }

    expect(postMessage).not.toHaveBeenCalled();
  });

  // Acceptance-review follow-up: signalMountPaintComplete() (api-content.ts) is the
  // claimed-preloaded-view mount-flash fix's actual release trigger -- the on-demand call
  // Swift's pollMountCloakReleaseForClaimedView (MilkdownCoordinator+MessageHandlers.swift)
  // makes once window.FinalFinal.isEditorReady() itself reports true. It was the single most
  // important piece of that redesign and had zero coverage before this test. It's a pure
  // function over getEditorInstance() (editor-state.ts) -- no preloading, no WKWebView claim
  // dance, no `window.FinalFinal` needed -- just a real editor instance and a stubbed
  // `postMessage` to observe against.
  it('signalMountPaintComplete() posts exactly one paintComplete signal with reason: "mount"', async () => {
    await makeEditor('Project A content.');
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };
    vi.useFakeTimers();

    signalMountPaintComplete();

    while (vi.getTimerCount() > 0) {
      await vi.runOnlyPendingTimersAsync();
    }

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ reason: 'mount' }));
  });
});
