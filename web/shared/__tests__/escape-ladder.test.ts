// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  type DismissTopLayer,
  installEscapeLadder,
  postEscapeComposition,
  postEscapeLadder,
  postEscapeWebPopupOpen,
  recomputeAndPushWebPopupState,
  registerWebPopupOpenCheck,
  setTestEscapeReportDelayMs,
} from '../escape-ladder';

// UX contract §6: one bubble-phase `document` keydown listener owns Escape dismissal. These
// tests cover the acceptance criteria directly: composing keydowns are inert to the native
// ladder, an already-`defaultPrevented` keydown reports handled without touching
// dismissTopLayer, an open/registered layer gets dismissed and reports handled, and nothing
// open reports not-handled.

let escapeLadderPostMessage: ReturnType<typeof vi.fn>;
let escapeCompositionPostMessage: ReturnType<typeof vi.fn>;
let escapeWebPopupOpenPostMessage: ReturnType<typeof vi.fn>;
let disposeLadder: (() => void) | null = null;

/** Wraps `installEscapeLadder` so every test's listeners are removed afterward -- otherwise
 * they'd accumulate across tests sharing this jsdom `document`, and a later test would see
 * events already `defaultPrevented` (or `dismissTopLayer` called more than once) by a prior
 * test's still-attached listener. */
function install(dismissTopLayer: DismissTopLayer): void {
  disposeLadder = installEscapeLadder(dismissTopLayer);
}

beforeEach(() => {
  escapeLadderPostMessage = vi.fn();
  escapeCompositionPostMessage = vi.fn();
  escapeWebPopupOpenPostMessage = vi.fn();
  (window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      escapeLadder: { postMessage: escapeLadderPostMessage },
      escapeComposition: { postMessage: escapeCompositionPostMessage },
      escapeWebPopupOpen: { postMessage: escapeWebPopupOpenPostMessage },
    },
  };
});

afterEach(() => {
  delete (window as unknown as { webkit?: unknown }).webkit;
  disposeLadder?.();
  disposeLadder = null;
  // Reset module-level state so a later test never inherits a check or delay a prior test set.
  registerWebPopupOpenCheck(() => false);
  setTestEscapeReportDelayMs(0);
});

function dispatchEscape(init: KeyboardEventInit = {}): void {
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true, ...init }));
}

describe('postEscapeLadder / postEscapeComposition', () => {
  it('posts {handled} to the escapeLadder message handler', () => {
    postEscapeLadder(true);
    expect(escapeLadderPostMessage).toHaveBeenCalledWith({ handled: true });
  });

  it('posts {composing} to the escapeComposition message handler', () => {
    postEscapeComposition(true);
    expect(escapeCompositionPostMessage).toHaveBeenCalledWith({ composing: true });
  });
});

// t-784ff3aa fix round: the new synchronous "is a web-owned popup open" signal that replaces
// the old race-prone watchdog-timeout design. Pushed the instant a popup opens or closes,
// independent of any particular Escape keypress -- see escape-ladder.ts's own doc comment.
describe('postEscapeWebPopupOpen / registerWebPopupOpenCheck / recomputeAndPushWebPopupState', () => {
  it('posts {open} to the escapeWebPopupOpen message handler', () => {
    postEscapeWebPopupOpen(true);
    expect(escapeWebPopupOpenPostMessage).toHaveBeenLastCalledWith({ open: true });

    postEscapeWebPopupOpen(false);
    expect(escapeWebPopupOpenPostMessage).toHaveBeenLastCalledWith({ open: false });
  });

  it("recomputeAndPushWebPopupState posts the registered check's current result, not a cached one", () => {
    let popupOpen = false;
    registerWebPopupOpenCheck(() => popupOpen);

    recomputeAndPushWebPopupState();
    expect(escapeWebPopupOpenPostMessage).toHaveBeenLastCalledWith({ open: false });

    // The check is re-invoked on every call -- flipping the underlying state and recomputing
    // again must reflect the NEW value, not whatever was true at registration time.
    popupOpen = true;
    recomputeAndPushWebPopupState();
    expect(escapeWebPopupOpenPostMessage).toHaveBeenLastCalledWith({ open: true });

    popupOpen = false;
    recomputeAndPushWebPopupState();
    expect(escapeWebPopupOpenPostMessage).toHaveBeenLastCalledWith({ open: false });
  });

  it('recomputeAndPushWebPopupState posts false when the registered check itself returns false for every popup', () => {
    // An editor's real aggregate check (isAnyWebPopupOpen in each main.ts) is an OR of several
    // predicates -- confirm recompute reports false when all of them would, not just when a
    // single trivial check does.
    registerWebPopupOpenCheck(() => false || false || false);
    recomputeAndPushWebPopupState();
    expect(escapeWebPopupOpenPostMessage).toHaveBeenLastCalledWith({ open: false });
  });
});

describe('installEscapeLadder', () => {
  it('ignores a composing keydown entirely -- nothing reaches the native ladder', () => {
    const dismissTopLayer = vi.fn(() => true);
    install(dismissTopLayer);

    // keyCode 229 is the IME "processing" sentinel, checked identically to e.isComposing.
    dispatchEscape({ keyCode: 229 });

    expect(dismissTopLayer).not.toHaveBeenCalled();
    expect(escapeLadderPostMessage).not.toHaveBeenCalled();
  });

  it('reports handled=true, without calling dismissTopLayer, when an element handler already preventDefault()ed', () => {
    const dismissTopLayer = vi.fn(() => false);
    // Simulate a popup's own element-level keydown handler (registered before the ladder, as
    // it would be by the time a popup is actually open) calling preventDefault(). `{ once:
    // true }` so it self-removes and can't leak into a later test.
    document.addEventListener(
      'keydown',
      (e) => {
        if (e.key === 'Escape') e.preventDefault();
      },
      { once: true }
    );
    install(dismissTopLayer);

    dispatchEscape();

    expect(dismissTopLayer).not.toHaveBeenCalled();
    expect(escapeLadderPostMessage).toHaveBeenCalledWith({ handled: true });
  });

  it('dismisses an open/registered layer via dismissTopLayer and reports handled=true', () => {
    const dismissTopLayer = vi.fn(() => true);
    install(dismissTopLayer);

    dispatchEscape();

    expect(dismissTopLayer).toHaveBeenCalledTimes(1);
    expect(escapeLadderPostMessage).toHaveBeenCalledWith({ handled: true });
  });

  it('reports handled=false when nothing is open to dismiss', () => {
    const dismissTopLayer = vi.fn(() => false);
    install(dismissTopLayer);

    dispatchEscape();

    expect(dismissTopLayer).toHaveBeenCalledTimes(1);
    expect(escapeLadderPostMessage).toHaveBeenCalledWith({ handled: false });
  });

  it('ignores an auto-repeated Escape keydown -- no dismissTopLayer call, no report to Swift', () => {
    // UX contract §6, "one press, one layer": a held Escape (or a synthesized repeat under VM
    // load) fires this listener once per repeat, not once per physical keypress. Without the
    // `e.repeat` guard, each repeat would call dismissTopLayer again and post its own
    // {handled} report -- resolving a DIFFERENT physical press's watchdog slot on the Swift
    // side (EscapeLadderContext.resolvePendingEscape()) than the one that armed it.
    const dismissTopLayer = vi.fn(() => true);
    install(dismissTopLayer);

    dispatchEscape({ repeat: true });

    expect(dismissTopLayer).not.toHaveBeenCalled();
    expect(escapeLadderPostMessage).not.toHaveBeenCalled();
  });

  it('ignores non-Escape keys', () => {
    const dismissTopLayer = vi.fn(() => true);
    install(dismissTopLayer);

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true }));

    expect(dismissTopLayer).not.toHaveBeenCalled();
    expect(escapeLadderPostMessage).not.toHaveBeenCalled();
  });

  it('forwards compositionstart/compositionend to the escapeComposition handler', () => {
    install(() => false);

    document.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    expect(escapeCompositionPostMessage).toHaveBeenLastCalledWith({ composing: true });

    document.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
    expect(escapeCompositionPostMessage).toHaveBeenLastCalledWith({ composing: false });
  });

  // t-784ff3aa fix round: setTestEscapeReportDelayMs is the test-only hook that lets an e2e
  // test simulate a genuinely slow web-layer Escape report (see the JS-side half of the
  // timing-independent proof; the Swift-side half asserts the native ladder never fires while
  // this delay is outstanding). This unit test proves the JS-side mechanics in isolation:
  // dismissTopLayer/postEscapeLadder genuinely wait for the configured delay, they are not
  // called synchronously, and they still fire correctly once the delay elapses.
  describe('setTestEscapeReportDelayMs (t-784ff3aa timing-independence proof mechanism)', () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it('delays both dismissTopLayer and the escapeLadder report by the configured amount, with no default behavior change (0)', () => {
      const dismissTopLayer = vi.fn(() => true);
      install(dismissTopLayer);
      setTestEscapeReportDelayMs(0);

      dispatchEscape();

      // Zero is a no-op: same synchronous behavior as every other test in this file.
      expect(dismissTopLayer).toHaveBeenCalledTimes(1);
      expect(escapeLadderPostMessage).toHaveBeenCalledWith({ handled: true });
    });

    it('does not call dismissTopLayer or post a report until the delay elapses, then does both', () => {
      const dismissTopLayer = vi.fn(() => true);
      install(dismissTopLayer);
      setTestEscapeReportDelayMs(3000);

      dispatchEscape();

      // Nothing yet -- this is the state a native fallback would incorrectly act during if it
      // were still racing a fixed watchdog deadline against this report.
      expect(dismissTopLayer).not.toHaveBeenCalled();
      expect(escapeLadderPostMessage).not.toHaveBeenCalled();

      vi.advanceTimersByTime(2999);
      expect(dismissTopLayer).not.toHaveBeenCalled();

      vi.advanceTimersByTime(1);
      expect(dismissTopLayer).toHaveBeenCalledTimes(1);
      expect(escapeLadderPostMessage).toHaveBeenCalledWith({ handled: true });
    });
  });
});
