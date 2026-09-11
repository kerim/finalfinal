// @vitest-environment jsdom
import { Schema } from '@milkdown/kit/prose/model';
import type { Plugin } from '@milkdown/kit/prose/state';
import { EditorState } from '@milkdown/kit/prose/state';
import { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { installEscapeLadder } from '../../../shared/escape-ladder';
import { buildEscapePassthroughPlugin } from '../escape-passthrough-plugin';

// Cluster A regression coverage (see escape-passthrough-plugin.ts's doc comment for the full
// mechanism). escape-ladder.test.ts's `dismissTopLayer` stand-in can never catch this class of
// bug -- it dispatches synthetic events straight at `document` and never mounts a real
// prosemirror-view `EditorView`, so it never exercises the internal `editHandlers.keydown`
// listener that unconditionally calls `preventDefault()` on Escape via `captureKeyDown`. These
// tests mount a real view (minimal schema, no other plugins) to prove the fix works against the
// actual installed prosemirror-view package, not a stand-in for it.

const schema = new Schema({
  nodes: {
    doc: { content: 'paragraph+' },
    paragraph: { content: 'text*', toDOM: () => ['p', 0] },
    text: {},
  },
});

function mountView(plugins: Plugin[]): { view: EditorView; dom: HTMLElement } {
  const dom = document.createElement('div');
  document.body.appendChild(dom);
  const state = EditorState.create({
    doc: schema.node('doc', null, [schema.node('paragraph', null, [schema.text('hello')])]),
    plugins,
  });
  const view = new EditorView(dom, { state });
  return { view, dom };
}

/** Realistic Escape keydown: keyCode 27, matching what a real, non-IME Escape press carries. */
function dispatchEscapeOn(target: HTMLElement): KeyboardEvent {
  const event = new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27, bubbles: true, cancelable: true });
  target.dispatchEvent(event);
  return event;
}

describe('escapePassthroughPlugin, mounted in a real prosemirror-view EditorView', () => {
  let view: EditorView | null = null;
  let dom: HTMLElement | null = null;

  afterEach(() => {
    view?.destroy();
    dom?.remove();
    view = null;
    dom = null;
  });

  it('regression proof: WITHOUT the plugin, prosemirror-view preventDefault()s Escape on its own', () => {
    ({ view, dom } = mountView([]));

    const event = dispatchEscapeOn(view.dom);

    // This is the bug: prosemirror-view's captureKeyDown() returns true unconditionally for
    // keyCode 27, and editHandlers.keydown calls preventDefault() whenever it does.
    expect(event.defaultPrevented).toBe(true);
  });

  it('WITH the plugin, Escape reaches the bubble phase with defaultPrevented === false', () => {
    ({ view, dom } = mountView([buildEscapePassthroughPlugin()]));

    const event = dispatchEscapeOn(view.dom);

    expect(event.defaultPrevented).toBe(false);
  });

  it("does not claim a composing Escape -- escape-ladder.ts's own isComposing/keyCode-229 guard stays in charge", () => {
    const handler = buildEscapePassthroughPlugin().props.handleDOMEvents?.keydown;
    if (!handler) throw new Error('plugin has no handleDOMEvents.keydown');

    // A plain object literal (not a spread of a real KeyboardEvent) -- `key`/`isComposing` are
    // prototype accessors on a real KeyboardEvent, not own-enumerable properties, so spreading
    // one would silently drop them and the assertion would pass for the wrong reason.
    const composing = { key: 'Escape', isComposing: true, keyCode: 0 } as unknown as Event;
    const imeSentinel = new KeyboardEvent('keydown', { key: 'Escape', keyCode: 229 });

    expect(handler.call(undefined, {} as EditorView, composing)).toBe(false);
    expect(handler.call(undefined, {} as EditorView, imeSentinel)).toBe(false);
  });
});

describe('escapePassthroughPlugin, end to end with the shared escape ladder', () => {
  let view: EditorView | null = null;
  let dom: HTMLElement | null = null;
  let disposeLadder: (() => void) | null = null;

  afterEach(() => {
    disposeLadder?.();
    disposeLadder = null;
    view?.destroy();
    dom?.remove();
    view = null;
    dom = null;
  });

  it('lets escape-ladder.ts call dismissTopLayer, instead of swallowing Escape as already-handled', () => {
    const dismissTopLayer = vi.fn(() => true);
    disposeLadder = installEscapeLadder(dismissTopLayer);
    ({ view, dom } = mountView([buildEscapePassthroughPlugin()]));

    dispatchEscapeOn(view.dom);

    expect(dismissTopLayer).toHaveBeenCalledTimes(1);
  });

  it('regression proof: WITHOUT the plugin, escape-ladder.ts never calls dismissTopLayer', () => {
    const dismissTopLayer = vi.fn(() => true);
    disposeLadder = installEscapeLadder(dismissTopLayer);
    ({ view, dom } = mountView([]));

    dispatchEscapeOn(view.dom);

    // Reproduces the exact reported failure: PM's own preventDefault() makes the ladder think
    // something already dismissed itself, so it reports handled without ever calling
    // dismissTopLayer -- Focus Mode/find bar/slash menu never actually close.
    expect(dismissTopLayer).not.toHaveBeenCalled();
  });
});
