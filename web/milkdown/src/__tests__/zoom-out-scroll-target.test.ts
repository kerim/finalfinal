// @vitest-environment jsdom
// Regression test for the Milkdown zoom-out "wrong scroll position" flash (2026-09-04).
//
// EditorViewState.zoomOut() (EditorViewState+Zoom.swift) calls setContentWithBlockIds() with no
// `scrollToStart`, which makes setContentWithBlockIds() capture the CURRENT (zoomed) view's
// scroll position as a restore anchor and re-apply that same y-coordinate to the newly-restored,
// un-zoomed document -- a coordinate-space mismatch that visibly lands the reader at the
// document's actual top for one frame, before performUserZoomOut()'s follow-up
// scrollToSection() call corrects it (ContentView+NotificationHandlers.swift). The fix threads
// the target block id (the section the user zoomed out OF) through the push itself, via a new
// `scrollToBlockId` option, so the correct landing position is resolved and applied BEFORE
// signalPaintComplete tells Swift the redraw is done -- closing the visible gap instead of
// papering over it with a second, later scroll.
//
// Coverage beyond the happy path: case 1 uses a POSITION-DEPENDENT coordsAtPos stub (not a
// constant) so the test can actually distinguish "targeted the right block" from "targeted some
// block" -- a constant stub would pass identically no matter which blockId was requested. Case 4
// exercises the `targetTop === 0` branch api-content.ts's own comment calls out as load-bearing
// (a truthiness check would treat a legitimate top-of-document target as "no target"). Case 5
// exercises the browser-clamped/end-of-document case: paintAnchor is re-captured from
// window.scrollY AFTER the in-push scroll specifically so a clamped landing is preserved instead
// of the unreachable raw target.
//
// LIMITS OF THIS TEST -- read before trusting it. This exercises the JS-side scroll-target math
// and the paintAnchor plumbing in isolation, using a mocked `coordsAtPos` and a mocked
// `window.scrollTo`. It cannot prove the exact on-screen pixel placement in the real app, nor
// the absence of an intermediate frame during a real WKWebView compositor repaint -- both need
// manual or e2e verification against the running app.

import { defaultValueCtx, Editor, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setContentWithBlockIds } from '../api-content';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';

describe('setContentWithBlockIds scrollToBlockId — zoom-out scroll-target resolution', () => {
  let editor: Editor | null = null;
  let scrollTo: ReturnType<typeof vi.fn>;
  // Mutable backing value for the `window.scrollY` getter, same pattern as
  // paint-scroll-preservation.test.ts.
  let scrollYValue: number;
  let originalScrollTo: PropertyDescriptor | undefined;
  let originalScrollX: PropertyDescriptor | undefined;
  let originalScrollY: PropertyDescriptor | undefined;
  let coordsAtPosSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    originalScrollTo = Object.getOwnPropertyDescriptor(window, 'scrollTo');
    originalScrollX = Object.getOwnPropertyDescriptor(window, 'scrollX');
    originalScrollY = Object.getOwnPropertyDescriptor(window, 'scrollY');
    scrollYValue = 400;
    // Applies `top` straight through, like an ordinary unclamped page -- lets the assertions
    // below check the exact resulting scroll position, not just recorded call arguments.
    // Case 5 overrides this with a clamping implementation of its own.
    scrollTo = vi.fn((opts: { top: number }) => {
      scrollYValue = opts.top;
    });
    Object.defineProperty(window, 'scrollTo', { value: scrollTo, configurable: true, writable: true });
    Object.defineProperty(window, 'scrollX', { value: 0, configurable: true });
    Object.defineProperty(window, 'scrollY', { get: () => scrollYValue, configurable: true });

    // Position-DEPENDENT stub (not a constant): isolates the scroll-target MATH (the -100
    // offset, the addition of the captured scrollY) from real jsdom layout, which has no real
    // geometry to lay text out with, WHILE still letting different `pos` arguments produce
    // different results -- a constant stub here would make case 1 unable to tell "targeted the
    // right block" apart from "targeted some block" (must-fix, review round). Cases 4 and 5
    // override this per-test with a constant return value tuned for their own specific branch.
    coordsAtPosSpy = vi
      .spyOn(EditorView.prototype, 'coordsAtPos')
      .mockImplementation((pos: number) => ({ top: pos * 100 + 50, bottom: pos * 100 + 70, left: 0, right: 0 }));
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
    coordsAtPosSpy.mockRestore();
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

  it("case 1: scrollToBlockId resolves to EACH block's own position — proves the fix, not just the arithmetic", async () => {
    await makeEditor('Para A.\n\nPara B.');
    vi.useFakeTimers();

    // 'Para A.' and 'Para B.' are both 7-char paragraphs (nodeSize 9), so id-a sits at document
    // position 0 and id-b at position 9 -- setBlockIdsForTopLevel assigns ids in that order.
    // Target id-a first.
    scrollYValue = 400;
    setContentWithBlockIds('Para A.\n\nPara B.', ['id-a', 'id-b'], { scrollToBlockId: 'id-a' });
    await drain();
    // coordsAtPos(0 + 1).top = 1*100+50 = 150; 150 + captured scrollY (400) - 100 offset = 450.
    const targetA = window.scrollY;
    expect(targetA).toBe(450);

    // Same document, same block ids, but target id-b this time -- a fresh push, not a re-read
    // of stale state.
    scrollYValue = 400;
    setContentWithBlockIds('Para A.\n\nPara B.', ['id-a', 'id-b'], { scrollToBlockId: 'id-b' });
    await drain();
    // coordsAtPos(9 + 1).top = 10*100+50 = 1050; 1050 + 400 - 100 = 1350.
    const targetB = window.scrollY;
    expect(targetB).toBe(1350);

    // The headline assertion: targeting a DIFFERENT block id lands on a DIFFERENT, correctly-
    // computed position. With the old CONSTANT coordsAtPos stub this file used to have, targetA
    // and targetB would have come out identical no matter which id was requested -- passing
    // even if the wrong block were targeted. This is what actually proves the RIGHT block
    // drives the result, which is the entire point of the fix.
    expect(targetA).not.toBe(targetB);
  });

  it('case 2: an unknown scrollToBlockId falls back to the captured-anchor (pre-fix) behavior', async () => {
    await makeEditor('Para A.\n\nPara B.');
    vi.useFakeTimers();

    scrollYValue = 400;
    setContentWithBlockIds('Para A.\n\nPara B.', ['id-a', 'id-b'], { scrollToBlockId: 'id-missing' });
    await drain();

    expect(window.scrollY).toBe(400);
  });

  it('case 3: scrollToStart wins outright even when scrollToBlockId is also supplied', async () => {
    await makeEditor('Para A.\n\nPara B.');
    vi.useFakeTimers();

    scrollYValue = 400;
    setContentWithBlockIds('Para A.\n\nPara B.', ['id-a', 'id-b'], {
      scrollToStart: true,
      scrollToBlockId: 'id-b',
    });
    await drain();

    expect(window.scrollY).toBe(0);
    // Not just that the FINAL position is 0 -- prove the in-push scrollToBlockId branch never
    // even ran. Under this file's default pos-dependent coordsAtPos stub, id-b's own resolved
    // target here would be 1350 (see case 1's identical computation). If the
    // `!options?.scrollToStart && options?.scrollToBlockId` short-circuit ever regressed, that
    // in-push scrollTo call would show up here even though the FINAL position still ends up 0
    // via signalPaintComplete's own separate top-reset -- a bug the final-position check alone
    // can't catch.
    expect(scrollTo.mock.calls.some((call) => call[0]?.top === 1350)).toBe(false);
  });

  it('case 4: a target resolving to document-top (0) actually lands at 0, not the captured-anchor fallback', async () => {
    await makeEditor('Para A.\n\nPara B.');
    vi.useFakeTimers();

    // Constant stub tuned so the computed target is EXACTLY 0: coords.top=-300, captured
    // scrollY=400 -> Math.max(0, -300 + 400 - 100) = Math.max(0, 0) = 0. This is exactly the
    // case api-content.ts's own comment calls out as load-bearing: `if (targetTop)` (a
    // truthiness check) would treat this legitimate 0 as falsy and silently fall through to the
    // captured-anchor fallback (400) instead of applying the correctly-resolved 0.
    coordsAtPosSpy.mockReturnValue({ top: -300, bottom: -280, left: 0, right: 0 });

    scrollYValue = 400;
    setContentWithBlockIds('Para A.\n\nPara B.', ['id-a', 'id-b'], { scrollToBlockId: 'id-b' });
    await drain();

    // 0 (the resolved top-of-document target), not 400 (the captured-anchor fallback) --
    // distinguishes the `!== null` check from a truthiness check.
    expect(window.scrollY).toBe(0);
  });

  it('case 5: a browser-clamped/unreachable target lands on the CLAMPED position, not the raw computed target', async () => {
    await makeEditor('Para A.\n\nPara B.');
    vi.useFakeTimers();

    // Constant stub whose computed target is unreachable: coords.top=2000, captured scrollY=400
    // -> Math.max(0, 2000 + 400 - 100) = 2300.
    coordsAtPosSpy.mockReturnValue({ top: 2000, bottom: 2020, left: 0, right: 0 });

    // Clamp every scrollTo call to a max of 800 -- simulates the browser refusing to scroll
    // past the end of a short document, same pattern as paint-scroll-preservation.test.ts's own
    // shrunk-document case.
    scrollTo.mockImplementation((opts: { top: number }) => {
      scrollYValue = Math.max(0, Math.min(opts.top, 800));
    });

    scrollYValue = 400;
    setContentWithBlockIds('Para A.\n\nPara B.', ['id-a', 'id-b'], { scrollToBlockId: 'id-b' });
    await drain();

    // 800 (the browser-clamped landing paintAnchor was re-captured from AFTER the in-push
    // scroll), not 2300 (the raw, unreachable computed target) -- proves paintAnchor reflects
    // reality rather than the request that produced it.
    expect(window.scrollY).toBe(800);
  });
});
