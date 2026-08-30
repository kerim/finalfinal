// @vitest-environment jsdom
// Must-fix #6 (mount-flash fix, review round 2): dedicated coverage for main.ts's initEditor()
// mount-success and mount-failure paint signals specifically -- mount-paint-signal.test.ts
// only covers resetForProjectSwitch()/clearEditorHistory()/clearStructuralUndoState(), not
// initEditor() itself. Exercises the REAL top-level auto-invoked initEditor() (main.ts calls
// it, unexported, at module-import time) via a fresh dynamic import per test, rather than
// re-implementing its logic against a hand-built double.

import { afterEach, describe, expect, it, vi } from 'vitest';

describe('initEditor() mount-success paint signal (main.ts, real editor construction)', () => {
  afterEach(() => {
    delete (window as any).webkit;
    document.body.innerHTML = '';
    vi.resetModules();
  });

  it('posts exactly one paintComplete signal with reason: "mount" once the real editor mounts', async () => {
    const root = document.createElement('div');
    root.id = 'editor';
    document.body.appendChild(root);

    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };

    // main.ts calls initEditor() unexported, at module-import time -- importing it is what
    // triggers the real Editor.make().create() chain (blockIdPlugin, commonmark, citeproc,
    // tables, math, the works) against the #editor div created above.
    await import('../main');

    // Real (not fake) timers: the real plugin chain and signalPaintComplete's double-RAF
    // both need genuine event-loop turns to settle.
    await vi.waitFor(
      () => {
        expect(postMessage).toHaveBeenCalled();
      },
      { timeout: 5000, interval: 25 }
    );

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ reason: 'mount' }));
    // The success path goes through signalPaintComplete (double-RAF + micro-scroll), which
    // always includes scrollHeight -- distinguishes it from the direct, RAF-less failure-path
    // post covered by the sibling describe block below.
    expect(postMessage.mock.calls[0][0]).toHaveProperty('scrollHeight');
  });
});

describe('initEditor() mount-failure paint signal (main.ts, forced Editor.make().create() rejection)', () => {
  afterEach(() => {
    delete (window as any).webkit;
    document.body.innerHTML = '';
    vi.doUnmock('@milkdown/kit/core');
    vi.resetModules();
  });

  it('posts a direct (no scrollHeight) paintComplete signal with reason: "mount" when Editor.make().create() rejects', async () => {
    const root = document.createElement('div');
    root.id = 'editor';
    document.body.appendChild(root);

    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { paintComplete: { postMessage } } };

    // Stub Editor.make()'s fluent chain so .create() always rejects, forcing initEditor()'s
    // own try/catch (main.ts) into its failure path -- everything else from
    // '@milkdown/kit/core' (defaultValueCtx, editorViewCtx, rootCtx) stays real, since
    // main.ts's .config() callback (never actually invoked by this stub) and other modules
    // in the import graph still reference them.
    vi.doMock('@milkdown/kit/core', async (importOriginal) => {
      const actual = await importOriginal<typeof import('@milkdown/kit/core')>();
      const chainable: any = {};
      chainable.config = () => chainable;
      chainable.use = () => chainable;
      chainable.create = () => Promise.reject(new Error('forced Editor.make().create() failure for must-fix #6 test'));
      return { ...actual, Editor: { make: () => chainable } };
    });

    // main.ts's own module-level `initEditor().catch((e) => console.error(...))` swallows the
    // rethrow -- suppress the expected console.error noise so this test's output stays clean,
    // matching how other suites in this codebase silence expected error logging.
    const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    await import('../main');

    await vi.waitFor(
      () => {
        expect(postMessage).toHaveBeenCalled();
      },
      { timeout: 5000, interval: 25 }
    );

    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ reason: 'mount' }));
    // The failure path goes through signalPaintCompleteDirect (no RAF, no scroll) -- must NOT
    // carry a scrollHeight key, distinguishing it from the success-path post covered by the
    // sibling describe block above.
    expect(postMessage.mock.calls[0][0]).not.toHaveProperty('scrollHeight');

    consoleErrorSpy.mockRestore();
  });
});
