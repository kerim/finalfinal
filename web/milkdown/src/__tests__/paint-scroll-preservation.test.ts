// @vitest-environment jsdom
// Regression test for the Milkdown scroll-to-top on citation insert (2026-09-04).
//
// signalPaintComplete()'s WKWebView compositor nudge used to scroll the window to top: 0
// unconditionally. setContentWithBlockIds() calls it on EVERY push, including the
// scrollToStart:false bibliography resync that lands ~1s after a citation is inserted
// (ContentView+NotificationHandlers.swift's handleBibliographySectionChanged) -- so
// inserting a citation partway down a document jumped the view to the top. The nudge must
// still happen (it fixes a real blank/stale-frame bug, d9fa212e) but must return the reader
// to where they were, except when the caller explicitly asked to start at the top.
//
// LIMITS OF THIS TEST -- read before trusting it. `window.scrollTo` here is a mock; by
// default (see `beforeEach`) it faithfully applies whatever `top` it's given to the mutable
// `scrollYValue` backing `window.scrollY`, so most assertions below are checking real
// call arguments against a real (simulated) resulting scroll position, not just recorded
// numbers. The one test that overrides this default (the shrunk-document case) installs its
// own clamping `mockImplementation` specifically so it can exercise -- not just assert
// numbers about -- the readback-and-retry logic in api-content.ts that guarantees a real
// scroll event even when the browser would otherwise clamp the nudge to a no-op.

import { defaultValueCtx, Editor, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setContentWithBlockIds } from '../api-content';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';

describe('signalPaintComplete scroll preservation', () => {
  let editor: Editor | null = null;
  let scrollTo: ReturnType<typeof vi.fn>;
  // Mutable backing value for the `window.scrollY` getter installed below -- a plain constant
  // (the old `{ value: 400 }` stub) can't prove capture-before-dispatch (M3, review round):
  // a regression that read `window.scrollY` late (inside signalPaintComplete's rAF, two
  // frames after dispatch) would read the exact same constant a correct, early capture would,
  // and the test would pass either way. A mutable value lets tests change it mid-flight and
  // catch that regression.
  let scrollYValue: number;
  // `scrollX`/`scrollY` are getter-only accessors on jsdom's Window and this module is
  // strict-mode ESM, so `window.scrollY = 400` throws. Redefine the property instead, and
  // put the original descriptors back afterwards so no other test file inherits the stub.
  let originalScrollTo: PropertyDescriptor | undefined;
  let originalScrollX: PropertyDescriptor | undefined;
  let originalScrollY: PropertyDescriptor | undefined;

  beforeEach(() => {
    originalScrollTo = Object.getOwnPropertyDescriptor(window, 'scrollTo');
    originalScrollX = Object.getOwnPropertyDescriptor(window, 'scrollX');
    originalScrollY = Object.getOwnPropertyDescriptor(window, 'scrollY');
    scrollYValue = 400;
    // Default behavior: apply `top` straight through, like an ordinary unclamped page. This
    // is what lets the two original tests below assert exact call sequences (the primary
    // nudge always "succeeds" here, so the readback-and-retry branch never fires for them).
    // The shrunk-document test overrides this with a clamping implementation of its own.
    scrollTo = vi.fn((opts: { top: number }) => {
      scrollYValue = opts.top;
    });
    Object.defineProperty(window, 'scrollTo', { value: scrollTo, configurable: true, writable: true });
    Object.defineProperty(window, 'scrollX', { value: 0, configurable: true });
    Object.defineProperty(window, 'scrollY', { get: () => scrollYValue, configurable: true });
  });

  afterEach(async () => {
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
    for (const [key, desc] of [
      ['scrollTo', originalScrollTo],
      ['scrollX', originalScrollX],
      ['scrollY', originalScrollY],
    ] as const) {
      if (desc) Object.defineProperty(window, key, desc);
      else delete (window as any)[key];
    }
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

  async function drain() {
    while (vi.getTimerCount() > 0) {
      await vi.runOnlyPendingTimersAsync();
    }
  }

  it('a scrollToStart:false push (bibliography resync) leaves the window where the reader was', async () => {
    await makeEditor('Para one.\n\nPara two.');
    vi.useFakeTimers();

    setContentWithBlockIds('Para one.\n\nPara two [@key].', []);
    // The dispatch inside setContentWithBlockIds is synchronous, so the anchor must already
    // be captured by the time this line runs. Mutate scrollY here, before the rAF pair (in
    // drain()) fires -- if a regression re-read window.scrollY late instead of using the
    // captured anchor, it would see this mutated value, and the assertions below would fail.
    scrollYValue = 0;
    await drain();

    expect(scrollTo).toHaveBeenCalled();
    const calls = scrollTo.mock.calls;
    // Lands back on the captured position (400), not the mutated 0 -- proves
    // capture-before-dispatch (M3).
    expect(calls[calls.length - 1][0].top).toBe(400);
    // Nudged AWAY from the clamp (downward, 399), not toward it -- see the direction note
    // in the header comment. Weak on its own; the readback-and-retry logic exercised by the
    // shrunk-document test below is what actually guarantees a real scroll event.
    expect(calls[calls.length - 2][0].top).toBe(399);
  });

  it('a scrollToStart:true push (document open / project switch) still lands at the top', async () => {
    await makeEditor('Para one.\n\nPara two.');
    vi.useFakeTimers();

    setContentWithBlockIds('Fresh document.', [], { scrollToStart: true });
    await drain();

    const calls = scrollTo.mock.calls;
    expect(calls[calls.length - 1][0].top).toBe(0);
  });

  it('a document that SHRINKS below the anchor still gets a real scroll event via the retry (M1/S3)', async () => {
    // The real shape of a bibliography regeneration: the reader was scrolled down (anchor.y
    // captured as 400), then the push shortens the document so far that 400 is now well past
    // the new bottom. The old code's single "y - 1, then y" nudge both clamp to the SAME
    // already-clamped position in this case and never produce a real scroll event at all --
    // silently skipping the compositor refresh this whole mechanism exists for (M1).
    await makeEditor('Para one.\n\nPara two.\n\nBibliography paragraph, much longer before the regenerate.');
    vi.useFakeTimers();

    // Install a clamping scrollTo so the retry logic has something real to react to: any
    // requested `top` is clamped into [0, maxScrollY], and the result is recorded so the test
    // can prove a real (non-clamped-to-the-same-value) scroll event occurred.
    let maxScrollY = Number.POSITIVE_INFINITY;
    const valuesAfterShrink: number[] = [];
    let recording = false;
    scrollTo.mockImplementation((opts: { top: number }) => {
      scrollYValue = Math.max(0, Math.min(opts.top, maxScrollY));
      if (recording) valuesAfterShrink.push(scrollYValue);
    });

    setContentWithBlockIds('Para one.\n\nPara two [@key].\n\nBib.', []);
    // Simulate the document having already shrunk (and the browser having already re-clamped
    // the live scroll position, exactly as it would by the time signalPaintComplete's double
    // rAF runs) to a max scroll well below the captured anchor (400).
    maxScrollY = 50;
    scrollYValue = 50;
    recording = true;

    await drain();

    // A genuine scroll event fired somewhere in the retry sequence -- not just the clamped
    // ceiling (50) repeating for every attempt, which is what the pre-fix code produced here.
    expect(valuesAfterShrink.some((v) => v !== 50)).toBe(true);

    // The final call still targets the real anchor (400); the browser -- not this code --
    // is what clamps it back down to 50. Restoring "as close as possible" is correct; only
    // the retry step's target differs from the un-shrunk case.
    const calls = scrollTo.mock.calls;
    expect(calls[calls.length - 1][0].top).toBe(400);
  });
});
