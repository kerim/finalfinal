// @vitest-environment jsdom
// Regression tests for paintcomplete-zoom-reason: setContent()'s zoom branch
// (MilkdownCoordinator+Content.swift) now mints a real `.zoom` cloak token and threads it
// through as `options.cloakToken`, rather than relying on Swift's `resolveCloakToken`
// defaulting a reason-less body to `.zoom` (a fallback that broke once
// BlockSyncService.setContentWithBlockIds's 9 reason-less call sites started posting
// paintComplete on every ordinary paint too, not just zoom transitions).
//
// The critical must-fix this file guards: the token-bearing paint has to post on EVERY exit
// from setContent(), not just the scrollToStart success branch -- setContent() has five
// early returns (pre-mount stash, empty markdown, unchanged content, and the two parser-
// failure exits -- a thrown parser error and a null/undefined parsed doc -- inside the main
// parse-and-replace action) that used to post nothing at all. A zoom into an
// empty/unchanged/unparseable section left Swift's cloak stuck until its own 2.5s fallback
// timeout without this.
//
// TIMING NOTE: jsdom's requestAnimationFrame is implemented on top of the window's own
// setTimeout, which is why vi.useFakeTimers() + drain() (below) can flush it at all -- but
// that only works cleanly if every signalPaintComplete()-triggering call in this file happens
// AFTER vi.useFakeTimers() is engaged, and is drained BEFORE it is turned back off. A priming
// call made under REAL timers can leave a real, still-pending rAF batch that a LATER test's
// (fake-timer) requestAnimationFrame call silently piggybacks onto instead of registering its
// own trackable timer -- so every priming push below happens under fake timers too.

import { defaultValueCtx, Editor, parserCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { setContent, setContentWithBlockIds } from '../api-content';
import { resetBlockIdState } from '../block-id-plugin';
import { resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';

describe('setContent() zoom paintComplete token (paintcomplete-zoom-reason)', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    // signalPaintComplete schedules a rAF-inside-a-rAF chain -- a single
    // runOnlyPendingTimersAsync() call only drains timers that were ALREADY pending, leaving
    // the inner rAF (registered mid-flush by the outer one) to leak into the next test. See
    // mount-paint-signal.test.ts's identical note.
    if (vi.isFakeTimers()) {
      while (vi.getTimerCount() > 0) {
        await vi.runOnlyPendingTimersAsync();
      }
    }
    vi.useRealTimers();
    vi.restoreAllMocks();
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    resetBlockIdState();
    resetBlockSyncState();
    setSyncPaused(false);
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

  it('scrollToStart + cloakToken posts a paintComplete body carrying reason: "zoom" and the echoed token', async () => {
    await makeEditor('Old section content.');
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };
    vi.useFakeTimers();

    setContent('New zoomed-in section.', { scrollToStart: true, cloakToken: 42 });
    await drain();

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ reason: 'zoom', token: 42 }));
  });

  it('scrollToStart with no cloakToken posts a paintComplete body with neither key (unchanged behavior)', async () => {
    await makeEditor('Old section content.');
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };
    vi.useFakeTimers();

    setContent('A different zoomed-in section.', { scrollToStart: true });
    await drain();

    expect(postMessage).toHaveBeenCalledTimes(1);
    const body = postMessage.mock.calls[0][0];
    expect(body.reason).toBeUndefined();
    expect(body.token).toBeUndefined();
  });

  it('must-fix: an early-return exit (empty markdown) with a cloakToken still releases the cloak', async () => {
    // Zooming into a section that resolves to no body text takes the empty-markdown
    // early-return branch, never reaching the scrollToStart repaint below it. Before this
    // fix, that branch posted nothing at all -- Swift's cloak would sit out its full 2.5s
    // fallback on every zoom into an empty section.
    await makeEditor('Old section content.');
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };
    vi.useFakeTimers();

    setContent('', { scrollToStart: true, cloakToken: 7 });
    await drain();

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ reason: 'zoom', token: 7 }));
  });

  it('must-fix: the no-op exit (content already matches) with a cloakToken still releases the cloak', async () => {
    await makeEditor('Same content either way.');
    vi.useFakeTimers();
    // getCurrentContent() only reflects a prior push through setContent/setContentWithBlockIds
    // -- prime it via an ordinary, uncloaked push first so the second call hits the
    // `getCurrentContent() === markdown` early return. Drained (and webkit installed only
    // afterward) so this priming push's own paintComplete signal -- posted with no
    // `window.webkit` installed yet, a harmless no-op -- fully settles under fake timers
    // before the real assertion below, rather than leaving a stray pending rAF batch.
    setContentWithBlockIds('Same content either way.', []);
    await drain();

    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };

    setContent('Same content either way.', { scrollToStart: true, cloakToken: 99 });
    await drain();

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ reason: 'zoom', token: 99 }));
  });

  it('must-fix: the pre-mount exit (no editor instance yet) with a cloakToken still releases the cloak directly', () => {
    // No makeEditor() call -- getEditorInstance() must return null via this exact seam,
    // exercising setContent()'s "not yet mounted" early return (MF3's pre-mount stash).
    setEditorInstance(null);
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };

    setContent('Content for a not-yet-mounted editor.', { scrollToStart: true, cloakToken: 123 });

    // signalPaintCompleteDirect posts synchronously (no RAF) -- no fake timers/drain needed.
    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ reason: 'zoom', token: 123 }));
  });

  it('must-fix: a thrown parser error with a cloakToken still releases the cloak directly (review round 3)', async () => {
    const e = await makeEditor('Old section content.');
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };
    vi.useFakeTimers();

    const realGet = e.ctx.get.bind(e.ctx);
    vi.spyOn(e.ctx, 'get').mockImplementation((sliceType: unknown) => {
      if (sliceType === parserCtx) {
        return () => {
          throw new Error('simulated parser failure');
        };
      }
      return realGet(sliceType as never);
    });
    const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    setContent('New content that will fail to parse.', { scrollToStart: true, cloakToken: 55 });
    await drain();

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ reason: 'zoom', token: 55 }));
    consoleErrorSpy.mockRestore();
  });

  it('must-fix: a null/undefined parsed doc with a cloakToken still releases the cloak directly (review round 3)', async () => {
    const e = await makeEditor('Old section content.');
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };
    vi.useFakeTimers();

    const realGet = e.ctx.get.bind(e.ctx);
    vi.spyOn(e.ctx, 'get').mockImplementation((sliceType: unknown) => {
      if (sliceType === parserCtx) {
        return () => null;
      }
      return realGet(sliceType as never);
    });
    const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    setContent('Some content.', { scrollToStart: true, cloakToken: 66 });
    await drain();

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ reason: 'zoom', token: 66 }));
    consoleErrorSpy.mockRestore();
  });

  it('setContentWithBlockIds still posts no `reason` key -- unaffected by setContent()’s token threading', async () => {
    await makeEditor('Old unrelated content.');
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };
    vi.useFakeTimers();

    setContentWithBlockIds('# Zoomed Section\n\nBody text.', ['id-heading', 'id-body'], {
      zoomMode: true,
      scrollToStart: true,
    });
    await drain();

    expect(postMessage).toHaveBeenCalledTimes(1);
    const body = postMessage.mock.calls[0][0];
    expect(body.reason).toBeUndefined();
    expect(body.token).toBeUndefined();
  });
});
