// @vitest-environment jsdom
//
// Cmd-click-a-heading-to-zoom regression tests.
//
// This is an ALWAYS-ON editor interaction — no Focus Mode gate anywhere in the
// path, JS or Swift. Deliberately: this file imports and mocks NOTHING related
// to Focus Mode. The absence is itself the evidence that the gesture doesn't
// depend on it — a previous attempt at this feature was rejected in part
// because it was wrongly scoped to only work in Focus Mode.
//
// The other rejected-attempt root cause this guards against: a bare
// `?.postMessage` optional-chain-to-nothing silently did nothing when the
// Swift-side message handler wasn't registered. Every drop path here must be
// observable (console.error/warn, or a postMessage to `errorHandler`) — see
// the "handler missing" test below.

import { beforeEach, describe, expect, it, vi } from 'vitest';

// Imported for their side effects only — installs the capture-phase mousedown/click
// listeners on `document`. Both are imported (not just the module under test) so the
// "link inside a heading zooms, not opens" regression guard is actually exercised.
//
// Import order here does NOT matter in production: main.ts always imports
// heading-zoom-click-handler.ts before link-click-handler.ts, and it's THAT handler's
// own capture-phase stopImmediatePropagation() (fired first, on that fixed order) that
// actually prevents the link from opening. link-click-handler.ts's own
// `headingZoomTargetFor` bail-out check below is genuine defense-in-depth — dead code
// in production, since the event never reaches it — and this file deliberately imports
// link-click-handler FIRST (reversed from main.ts) so that if heading-zoom-click-handler's
// suppression ever regressed, THIS test would still catch the "no open" outcome via that
// bail-out check rather than passing for the wrong reason.
import '../link-click-handler';
import '../heading-zoom-click-handler';

interface HandlerSpies {
  zoomHeadingClicked: { postMessage: ReturnType<typeof vi.fn> };
  openURL: { postMessage: ReturnType<typeof vi.fn> };
  errorHandler: { postMessage: ReturnType<typeof vi.fn> };
}

function installHandlers(): HandlerSpies {
  const handlers: HandlerSpies = {
    zoomHeadingClicked: { postMessage: vi.fn() },
    openURL: { postMessage: vi.fn() },
    errorHandler: { postMessage: vi.fn() },
  };
  (window as any).webkit = { messageHandlers: handlers };
  return handlers;
}

function dispatchClick(el: HTMLElement, opts: Partial<MouseEventInit> = {}): MouseEvent {
  const event = new MouseEvent('click', { bubbles: true, cancelable: true, ...opts });
  el.dispatchEvent(event);
  return event;
}

function dispatchMousedown(el: HTMLElement, opts: Partial<MouseEventInit> = {}): MouseEvent {
  const event = new MouseEvent('mousedown', { bubbles: true, cancelable: true, ...opts });
  el.dispatchEvent(event);
  return event;
}

describe('heading Cmd-click zoom (always-on, no Focus Mode gate)', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
    delete (window as any).webkit;
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it('posts blockId to zoomHeadingClicked on Cmd+click of a heading', () => {
    const handlers = installHandlers();
    const h2 = document.createElement('h2');
    h2.setAttribute('data-block-id', 'b1');
    h2.textContent = 'Title';
    document.body.appendChild(h2);

    dispatchClick(h2, { metaKey: true });

    expect(handlers.zoomHeadingClicked.postMessage).toHaveBeenCalledWith({ blockId: 'b1' });
    expect(handlers.openURL.postMessage).not.toHaveBeenCalled();
  });

  it('Cmd+click on a link INSIDE a heading zooms, not opens the link', () => {
    const handlers = installHandlers();
    const h2 = document.createElement('h2');
    h2.setAttribute('data-block-id', 'b1');
    const a = document.createElement('a');
    a.setAttribute('href', 'https://x');
    a.textContent = 'link text';
    h2.appendChild(a);
    document.body.appendChild(h2);

    dispatchClick(a, { metaKey: true });

    expect(handlers.zoomHeadingClicked.postMessage).toHaveBeenCalledWith({ blockId: 'b1' });
    expect(handlers.openURL.postMessage).not.toHaveBeenCalled();
  });

  it('Cmd+click on a link inside a non-heading paragraph still opens the link', () => {
    const handlers = installHandlers();
    const p = document.createElement('p');
    p.setAttribute('data-block-id', 'p1');
    const a = document.createElement('a');
    a.setAttribute('href', 'https://x');
    a.textContent = 'link text';
    p.appendChild(a);
    document.body.appendChild(p);

    dispatchClick(a, { metaKey: true });

    expect(handlers.openURL.postMessage).toHaveBeenCalledWith('https://x');
    expect(handlers.zoomHeadingClicked.postMessage).not.toHaveBeenCalled();
  });

  it('plain click (no modifier) on a heading posts nothing and leaves defaultPrevented false', () => {
    const handlers = installHandlers();
    const h2 = document.createElement('h2');
    h2.setAttribute('data-block-id', 'b1');
    document.body.appendChild(h2);

    const event = dispatchClick(h2);

    expect(handlers.zoomHeadingClicked.postMessage).not.toHaveBeenCalled();
    expect(event.defaultPrevented).toBe(false);
  });

  // The mousedown capture-phase listener inspects EVERY click on EVERY heading (that's
  // what lets it beat ProseMirror's own Cmd-click node-selection to the punch) — so a
  // plain click leaving it untouched is the single most important regression guard here.
  it('plain mousedown (no modifier) on a heading leaves defaultPrevented false', () => {
    installHandlers();
    const h2 = document.createElement('h2');
    h2.setAttribute('data-block-id', 'b1');
    document.body.appendChild(h2);

    const event = dispatchMousedown(h2);

    expect(event.defaultPrevented).toBe(false);
  });

  it('Cmd+click on a non-heading block (paragraph) posts nothing', () => {
    const handlers = installHandlers();
    const p = document.createElement('p');
    p.setAttribute('data-block-id', 'p1');
    document.body.appendChild(p);

    dispatchClick(p, { metaKey: true });

    expect(handlers.zoomHeadingClicked.postMessage).not.toHaveBeenCalled();
  });

  describe('temporary block id retry', () => {
    it('drops and warns after 8s (in ~100ms poll ticks) if the block id is still temporary', () => {
      const handlers = installHandlers();
      const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
      vi.useFakeTimers();

      const h2 = document.createElement('h2');
      h2.setAttribute('data-block-id', 'temp-abc');
      document.body.appendChild(h2);

      const event = dispatchClick(h2, { metaKey: true });

      // Nothing posts immediately, but the click's default action was prevented
      // (ProseMirror's own Cmd-click node-select must not fire either).
      expect(handlers.zoomHeadingClicked.postMessage).not.toHaveBeenCalled();
      expect(event.defaultPrevented).toBe(true);

      // Advance in ~100ms poll ticks (not one big fast-forward) so this exercises the
      // actual poll loop, not just its end state.
      for (let i = 0; i < 79; i++) {
        vi.advanceTimersByTime(100);
        expect(handlers.zoomHeadingClicked.postMessage).not.toHaveBeenCalled();
        expect(warnSpy).not.toHaveBeenCalled();
      }

      vi.advanceTimersByTime(100); // the 80th tick, reaching the 8000ms cap

      expect(handlers.zoomHeadingClicked.postMessage).not.toHaveBeenCalled();
      expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('still temporary after 8s'));
    });

    it('resolves and posts on the very next poll tick, without waiting for the full 8s window', () => {
      const handlers = installHandlers();
      vi.useFakeTimers();

      const h2 = document.createElement('h2');
      h2.setAttribute('data-block-id', 'temp-abc');
      document.body.appendChild(h2);

      dispatchClick(h2, { metaKey: true });
      expect(handlers.zoomHeadingClicked.postMessage).not.toHaveBeenCalled();

      // Swift confirms the permanent id; block-id-plugin.ts rewrites the attribute
      // on the SAME live DOM node before the retry timer fires.
      h2.setAttribute('data-block-id', 'real-id-123');

      // A single ~100ms poll tick is enough — the fix under test is that a fast
      // resolution posts immediately rather than waiting out the full 8000ms window.
      vi.advanceTimersByTime(100);

      expect(handlers.zoomHeadingClicked.postMessage).toHaveBeenCalledWith({ blockId: 'real-id-123' });
    });

    it('stops polling and logs distinctly if the heading DOM node is replaced before the id resolves', () => {
      const handlers = installHandlers();
      const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
      vi.useFakeTimers();

      const h2 = document.createElement('h2');
      h2.setAttribute('data-block-id', 'temp-abc');
      document.body.appendChild(h2);

      dispatchClick(h2, { metaKey: true });

      // Simulate a full-document resync (undo/version-restore/zoom) replacing the node.
      h2.remove();

      vi.advanceTimersByTime(100);

      expect(handlers.zoomHeadingClicked.postMessage).not.toHaveBeenCalled();
      expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('heading DOM node was replaced'));

      // Confirm polling actually stopped (not just that it hasn't posted yet).
      warnSpy.mockClear();
      vi.advanceTimersByTime(8000);
      expect(warnSpy).not.toHaveBeenCalled();
    });
  });

  it('the mousedown capture listener prevents default on Cmd+mousedown over a heading', () => {
    installHandlers();
    const h2 = document.createElement('h2');
    h2.setAttribute('data-block-id', 'b1');
    document.body.appendChild(h2);

    const event = dispatchMousedown(h2, { metaKey: true });

    expect(event.defaultPrevented).toBe(true);
  });

  it('logs an error and notifies errorHandler when the zoomHeadingClicked handler is missing', () => {
    // No handlers installed at all — window.webkit is undefined.
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const postMessage = vi.fn();
    (window as any).webkit = { messageHandlers: { errorHandler: { postMessage } } };

    const h2 = document.createElement('h2');
    h2.setAttribute('data-block-id', 'b1');
    document.body.appendChild(h2);

    dispatchClick(h2, { metaKey: true });

    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining('zoomHeadingClicked'));
    expect(postMessage).toHaveBeenCalledWith({
      type: 'plugin-error',
      message: 'zoomHeadingClicked handler missing',
    });
  });
});
