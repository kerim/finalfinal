// @vitest-environment jsdom
// Typewriter-scrolling trigger classification — CodeMirror (plan §7, "Classifier units").
//
// Same real-`EditorView` harness pattern as `set-content-origin-overlap.test.ts` (copied, not
// edited — that file's own expectations are untouched). Reason strings are asserted against
// the exported labels from the SHARED module, so a test and the implementation cannot drift
// apart. The only count-only assertion is the `'unclassified'` catch-all.
//
// jsdom performs no layout, so `coordsAtPos` / `lineBlockAt` are zero and a real trigger would
// (correctly) abandon its write. `__setTypewriterTestGeometry` installs a non-degenerate line
// box so `triggerCount` / `lastReason` are observable. Never used in production.

import { history, redo, undo } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorState, type Extension, Transaction } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  getTypewriterTestState,
  markDocumentReady,
  REASON_DELETE,
  REASON_HISTORY_REDO,
  REASON_HISTORY_UNDO,
  REASON_INPUT,
  REASON_PASTE,
  REASON_UNCLASSIFIED,
  resetTypewriterForTests,
  setTypewriterEnabled,
  setTypewriterLineOffset,
} from '../../../shared/typewriter-scrolling';
import { renumberFootnotes, setContent } from '../api';
import { setEditorExtensions, setEditorView } from '../editor-state';
import { __setTypewriterTestGeometry, typewriterExtension } from '../typewriter-plugin';

beforeAll(() => {
  if (typeof Range !== 'undefined' && !Range.prototype.getBoundingClientRect) {
    Range.prototype.getBoundingClientRect = function (this: Range): DOMRect {
      return { x: 0, y: 0, width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0, toJSON: () => ({}) } as DOMRect;
    };
  }
  // jsdom implements neither of the two rect APIs CodeMirror's `coordsAtPos` needs. Without
  // this one, `coordsAtPos` throws `textRange(...).getClientRects is not a function` in jsdom
  // even OUTSIDE an update window, which would turn the deferral tests below into a test of
  // jsdom rather than of the update window. An empty rect list is the honest shim: CodeMirror's
  // own code path then returns `null` for the coordinate, exactly as it does for an off-screen
  // caret — and the plugin's documented response to an unmeasurable caret box is to abandon the
  // trigger. The *legality* of the read (which is what these tests are about) is unaffected.
  if (typeof Range !== 'undefined' && !Range.prototype.getClientRects) {
    Range.prototype.getClientRects = function (this: Range): DOMRectList {
      return { length: 0, item: () => null, [Symbol.iterator]: [][Symbol.iterator] } as unknown as DOMRectList;
    };
  }
});

const DOC = '# Heading\n\nBody one.\n\nBody two.\n\nBody three.\n\nBody four.\n';

/* --------------------------------------------------------------- fake frames */

// The instant write is deferred to an animation frame and a glide is a chain of them, so
// the tests drive frames explicitly and can OBSERVE `gliding` instead of inferring it.
let rafCallbacks: Map<number, FrameRequestCallback>;
let rafNextId: number;

function flushFrames(): void {
  const pending = [...rafCallbacks.entries()].sort((a, b) => a[0] - b[0]);
  rafCallbacks.clear();
  for (const [, cb] of pending) cb(0);
}

describe('typewriter scrolling: CodeMirror trigger classification', () => {
  let view: EditorView | null = null;

  beforeEach(() => {
    resetTypewriterForTests();
    rafCallbacks = new Map();
    rafNextId = 0;
    vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => {
      const id = ++rafNextId;
      rafCallbacks.set(id, cb);
      return id;
    });
    vi.stubGlobal('cancelAnimationFrame', (id: number) => {
      rafCallbacks.delete(id);
    });
    document.documentElement.style.removeProperty('--typewriter-reserve');
    // A non-degenerate geometry so the trigger does not abandon its write in jsdom.
    __setTypewriterTestGeometry({
      caret: { top: 100, bottom: 124 },
      range: { maxScroll: 4000, visibleHeight: 480, lineHeight: 24 },
    });
  });

  afterEach(() => {
    __setTypewriterTestGeometry(null);
    resetTypewriterForTests();
    vi.unstubAllGlobals();
    setEditorView(null);
    setEditorExtensions([]);
    if (view) {
      view.destroy();
      view = null;
    }
  });

  function makeEditor(doc: string, extraExtensions: Extension[] = []): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const extensions: Extension[] = [
      markdown({ base: markdownLanguage }),
      history(),
      ...typewriterExtension,
      ...extraExtensions,
    ];
    const v = new EditorView({ state: EditorState.create({ doc, extensions }), parent: div });
    view = v;
    setEditorView(v);
    setEditorExtensions(extensions);
    setTypewriterEnabled(true);
    setTypewriterLineOffset(0);
    markDocumentReady();
    return v;
  }

  function snapshot() {
    return getTypewriterTestState();
  }

  /**
   * Lets the deferred trigger run. The plugin must NOT measure inside its update window — a
   * layout read there throws and CodeMirror then destroys the plugin permanently — so the
   * measure-and-trigger is queued on a microtask. Every assertion about a trigger's EFFECT
   * therefore has to await it; an assertion made synchronously would be testing the absence of
   * the fix's own scheduling.
   */
  async function flushTrigger(): Promise<void> {
    await Promise.resolve();
    await Promise.resolve();
  }

  /** Places the caret and dispatches a user-event-tagged document change there. */
  async function userEditAt(
    v: EditorView,
    pos: number,
    userEvent: string,
    insert = 'x'
  ): Promise<ReturnType<typeof snapshot>> {
    v.dispatch({ selection: { anchor: pos } });
    return userEdit(v, userEvent, insert);
  }

  /** Dispatches a user-event-tagged document change and returns the post-trigger state. */
  async function userEdit(v: EditorView, userEvent: string, insert = 'x'): Promise<ReturnType<typeof snapshot>> {
    const pos = v.state.selection.main.head;
    const tr = v.state.update({
      changes: { from: pos, to: pos, insert },
      annotations: Transaction.userEvent.of(userEvent),
    });
    v.dispatch(tr);
    await flushTrigger();
    return snapshot();
  }

  it("typing is 'input'", async () => {
    const v = makeEditor(DOC);
    const state = await userEdit(v, 'input.type');
    expect(state.triggerCount).toBeGreaterThan(0);
    expect(state.lastReason).toBe(REASON_INPUT);
  });

  it("Backspace is 'delete'", async () => {
    const v = makeEditor(DOC);
    await userEdit(v, 'input.type');
    const before = snapshot().triggerCount;
    v.dispatch(
      v.state.update({
        changes: { from: 1, to: 2 },
        annotations: Transaction.userEvent.of('delete.backward'),
      })
    );
    await flushTrigger();
    expect(snapshot().triggerCount).toBe(before + 1);
    expect(snapshot().lastReason).toBe(REASON_DELETE);
  });

  it("Delete is 'delete'", async () => {
    const v = makeEditor(DOC);
    v.dispatch(
      v.state.update({
        changes: { from: 2, to: 3 },
        annotations: Transaction.userEvent.of('delete.forward'),
      })
    );
    await flushTrigger();
    expect(snapshot().lastReason).toBe(REASON_DELETE);
  });

  it("Cut is 'delete' (no annotation distinguishes it)", async () => {
    const v = makeEditor(DOC);
    v.dispatch(
      v.state.update({
        changes: { from: 3, to: 4 },
        annotations: Transaction.userEvent.of('delete.cut'),
      })
    );
    await flushTrigger();
    expect(snapshot().lastReason).toBe(REASON_DELETE);
  });

  it("paste is 'paste'", async () => {
    const v = makeEditor(DOC);
    const state = await userEdit(v, 'input.paste', 'pasted ');
    expect(state.lastReason).toBe(REASON_PASTE);
  });

  it("a drop is 'paste'", async () => {
    const v = makeEditor(DOC);
    expect((await userEdit(v, 'input.drop', 'dropped')).lastReason).toBe(REASON_PASTE);
  });

  it("undo is 'history-undo'", async () => {
    const v = makeEditor(DOC);
    await userEdit(v, 'input.type');
    expect(undo(v)).toBe(true);
    await flushTrigger();
    expect(snapshot().lastReason).toBe(REASON_HISTORY_UNDO);
  });

  it("redo is 'history-redo'", async () => {
    const v = makeEditor(DOC);
    await userEdit(v, 'input.type');
    undo(v);
    await flushTrigger();
    expect(redo(v)).toBe(true);
    await flushTrigger();
    expect(snapshot().lastReason).toBe(REASON_HISTORY_REDO);
  });

  it("a browser correction (input.replace) is 'correction'", async () => {
    const v = makeEditor(DOC);
    await userEdit(v, 'input.type');
    v.dispatch(
      v.state.update({
        changes: { from: 1, to: 2, insert: 'y' },
        annotations: Transaction.userEvent.of('input.replace'),
      })
    );
    await flushTrigger();
    expect(snapshot().lastReason).toBe('correction');
  });

  it("a derivedCorrection-style dispatch counts, with the 'unclassified' catch-all reason", async () => {
    // A formatting command in this app dispatches with no `userEvent`, so it lands in the
    // catch-all rather than being guessed at. Asserted as a COUNT plus the catch-all label,
    // per the plan's own restriction.
    const v = makeEditor(DOC);
    await userEdit(v, 'input.type');
    const before = snapshot().triggerCount;
    v.dispatch(v.state.update({ changes: { from: 0, to: 1, insert: '##' } }));
    await flushTrigger();
    expect(snapshot().triggerCount).toBe(before + 1);
    expect(snapshot().lastReason).toBe(REASON_UNCLASSIFIED);
  });

  it('a selection-only transaction does not trigger', async () => {
    const v = makeEditor(DOC);
    await userEdit(v, 'input.type');
    const before = snapshot().triggerCount;
    v.dispatch({ selection: { anchor: 1 } });
    await flushTrigger();
    expect(snapshot().triggerCount).toBe(before);
  });

  it('a selection-only transaction cancels an in-flight glide', async () => {
    const v = makeEditor(DOC);
    // First trigger is instant, from line 1.
    await userEditAt(v, 1, 'input.type');
    flushFrames();
    const before = snapshot().triggerCount;

    // A distant edit is a multi-logical-line move, so it GLIDES — observed, not inferred.
    await userEditAt(v, v.state.doc.length - 2, 'input.type');
    expect(snapshot().gliding).toBe(true);

    // A selection-only transaction must be no trigger AND must cancel the glide.
    v.dispatch({ selection: { anchor: 1 } });
    expect(snapshot().triggerCount).toBe(before + 1);
    expect(snapshot().gliding).toBe(false);
  });

  it('a click-cancellation source (pointerdown on window) stops an in-flight glide', async () => {
    const v = makeEditor(DOC);
    await userEditAt(v, 1, 'input.type');
    flushFrames();
    await userEditAt(v, v.state.doc.length - 2, 'input.type');
    expect(snapshot().gliding).toBe(true);
    window.dispatchEvent(new Event('pointerdown'));
    expect(snapshot().gliding).toBe(false);
  });

  it('a scroll is not a transaction and does not trigger', async () => {
    const v = makeEditor(DOC);
    const before = snapshot().triggerCount;
    v.scrollDOM.dispatchEvent(new Event('scroll'));
    expect(snapshot().triggerCount).toBe(before);
  });

  /** Lets the readiness microtask `setContent` schedules actually run. */
  async function settleReadiness(): Promise<void> {
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
  }

  it('the first setContent in a JS context is a new document: it re-centres exactly once', async () => {
    makeEditor(DOC);
    const before = snapshot().triggerCount;
    setContent(`${DOC}\nNew paragraph.\n`, { origin: 'intentional' });
    await settleReadiness();
    flushFrames();
    // Exactly one: the activation edge. A second pass here would mean the readiness
    // re-assertion is not an edge.
    expect(snapshot().triggerCount).toBe(before + 1);
  });

  it('a later same-document setContent does not trigger, even after its readiness microtask', async () => {
    const v = makeEditor(DOC);
    // This is the first load for this JS context.
    setContent(`${DOC}\nFirst push.\n`, { origin: 'intentional' });
    await settleReadiness();
    flushFrames();
    const afterFirstLoad = snapshot().triggerCount;

    // Move the caret somewhere a spurious pass WOULD write, so the assertion is binding.
    v.dispatch({ selection: { anchor: v.state.doc.length - 2 } });
    setContent(`${DOC}\nFirst push.\nSecond push.\n`, { origin: 'intentional' });
    await settleReadiness();
    flushFrames();
    expect(snapshot().triggerCount).toBe(afterFirstLoad);
  });

  it('a derived setContent does not trigger either, after its readiness microtask', async () => {
    makeEditor(DOC);
    setContent(`${DOC}\nFirst push.\n`, { origin: 'intentional' });
    await settleReadiness();
    flushFrames();
    const before = snapshot().triggerCount;
    setContent(`${DOC}\nFirst push.\nCorrection.\n`, { origin: 'derived' });
    await settleReadiness();
    flushFrames();
    expect(snapshot().triggerCount).toBe(before);
  });

  it('measures OUTSIDE the update window, survives a keystroke, and stays active', async () => {
    // NO `__setTypewriterTestGeometry` seam in this test, deliberately. The seam short-circuits
    // `measureCaret` before it ever reaches `view.coordsAtPos`, which is exactly how the whole
    // suite missed a real crash: CodeMirror forbids layout reads during a plugin update, so a
    // synchronous read makes `PluginInstance.update` catch the throw, log "CodeMirror plugin
    // crashed", call `destroy()` and DEACTIVATE the plugin permanently — after which the feature
    // is inert for the rest of the session. This test is about WHEN the read happens.
    __setTypewriterTestGeometry(null);
    const v = makeEditor(DOC);

    const proto = EditorView.prototype as unknown as {
      coordsAtPos: (pos: number, side?: number) => unknown;
    };
    const originalCoords = proto.coordsAtPos;
    const updateStatesAtRead: number[] = [];
    const coordsSpy = vi.spyOn(proto, 'coordsAtPos').mockImplementation(function (
      this: EditorView,
      pos: number,
      side?: number
    ) {
      // Record the view's own updateState AT THE MOMENT of the read: 0 = Idle (legal), 2 =
      // Updating (throws, and CodeMirror then destroys the plugin).
      updateStatesAtRead.push((this as unknown as { updateState: number }).updateState);
      return originalCoords.call(this, pos, side);
    });

    try {
      const edit = (insert: string) => {
        const pos = v.state.selection.main.head;
        v.dispatch(
          v.state.update({
            changes: { from: pos, to: pos, insert },
            annotations: Transaction.userEvent.of('input.type'),
          })
        );
      };

      edit('a');
      // The trigger is deferred by one microtask, so nothing has measured yet.
      expect(updateStatesAtRead).toHaveLength(0);
      await Promise.resolve();
      await Promise.resolve();

      // 1. Every read happened outside the update window.
      expect(updateStatesAtRead.length).toBeGreaterThan(0);
      expect(updateStatesAtRead.every((state) => state === 0)).toBe(true);

      // 2. The plugin SURVIVED the keystroke: a destroyed plugin is never called again, so a
      //    second edit could not produce another read.
      const readsAfterFirstEdit = updateStatesAtRead.length;
      edit('b');
      await Promise.resolve();
      await Promise.resolve();
      expect(updateStatesAtRead.length).toBeGreaterThan(readsAfterFirstEdit);

      // 3. The feature is still armed — `destroy()` would have unregistered the host.
      expect(getTypewriterTestState().active).toBe(true);
    } finally {
      coordsSpy.mockRestore();
    }
  });

  it('renumberFootnotes does not trigger (application origin)', async () => {
    makeEditor('Text[^1] and [^2].\n');
    setContent('Text[^1] and [^2].\nAnd more.\n', { origin: 'intentional' });
    await settleReadiness();
    flushFrames();
    const before = snapshot().triggerCount;
    renumberFootnotes({ '1': '2', '2': '3' });
    await settleReadiness();
    await flushTrigger();
    flushFrames();
    expect(snapshot().triggerCount).toBe(before);
  });
});
