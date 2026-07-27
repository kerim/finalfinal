// @vitest-environment jsdom
// Regression tests for click-to-edit on COLLAPSED annotations.
//
// annotation-display-plugin.ts renders a 'collapsed' annotation by hiding its
// text span via CSS (`.ff-annotation-collapsed .ff-annotation-text { display:
// none }`), leaving the marker span as the only visible/clickable surface.
// annotation-plugin.ts's NodeView used to treat any click landing on the
// marker as "belongs to the task-completion toggle" and never open the edit
// popup from it — for task annotations that meant clicking a collapsed
// annotation silently toggled completion instead of editing; for
// comment/reference annotations (whose marker has no click listener at all)
// it meant clicking did nothing.
//
// Uses a real Milkdown Editor (commonmark + gfm + annotationPlugin), not a
// hand-built minimal Schema, so `<!-- ::type:: text -->` really parses through
// the actual remark-based annotation plugin end-to-end and the real NodeView
// click listeners are exercised — mirrors citation-delete.test.ts's approach
// for its own subsystem.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { setAnnotationDisplayModes } from '../annotation-display-plugin';
import { hideAnnotationEditPopup, isAnnotationEditPopupOpen } from '../annotation-edit-popup';
import { annotationPlugin } from '../annotation-plugin';

describe('collapsed annotation click-to-edit', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    // Reset the module-level display-mode state so it doesn't leak into other
    // tests in this file (or, in watch mode, other files sharing the worker).
    setAnnotationDisplayModes({ task: 'inline', comment: 'inline', reference: 'inline' });
    hideAnnotationEditPopup();
    if (editor) {
      await editor.destroy();
      editor = null;
    }
  });

  async function makeEditor(markdown: string): Promise<EditorView> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      // annotationPlugin MUST be registered before commonmark/gfm to intercept
      // the `<!-- ::type:: ... -->` HTML comments — mirrors main.ts's ordering.
      .use(annotationPlugin)
      .use(commonmark)
      .use(gfm)
      .create();
    editor = e;
    return e.ctx.get(editorViewCtx);
  }

  /** The rendered marker span for the first annotation node in the view. */
  function markerSpan(view: EditorView): HTMLElement {
    const el = view.dom.querySelector('.ff-annotation .ff-annotation-marker');
    if (!el) throw new Error('no annotation marker span found in rendered view');
    return el as HTMLElement;
  }

  function click(el: HTMLElement): void {
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  }

  it('opens the edit popup when a collapsed comment annotation marker is clicked', async () => {
    const view = await makeEditor('<!-- ::comment:: Needs more detail -->');
    setAnnotationDisplayModes({ comment: 'collapsed' });

    expect(isAnnotationEditPopupOpen()).toBe(false);
    click(markerSpan(view));
    expect(isAnnotationEditPopupOpen()).toBe(true);
  });

  it('opens the edit popup when a collapsed reference annotation marker is clicked', async () => {
    const view = await makeEditor('<!-- ::reference:: See Smith 2023 -->');
    setAnnotationDisplayModes({ reference: 'collapsed' });

    expect(isAnnotationEditPopupOpen()).toBe(false);
    click(markerSpan(view));
    expect(isAnnotationEditPopupOpen()).toBe(true);
  });

  it('opens the edit popup (not a completion toggle) when a collapsed task marker is clicked', async () => {
    const view = await makeEditor('<!-- ::task:: [ ] Review introduction -->');
    setAnnotationDisplayModes({ task: 'collapsed' });

    expect(isAnnotationEditPopupOpen()).toBe(false);
    click(markerSpan(view));
    expect(isAnnotationEditPopupOpen()).toBe(true);

    // The click must not have also toggled completion — editing, not toggling,
    // is the collapsed-marker interaction now.
    let isCompleted: boolean | undefined;
    view.state.doc.descendants((node) => {
      if (node.type.name === 'annotation') isCompleted = node.attrs.isCompleted;
      return true;
    });
    expect(isCompleted).toBe(false);
  });

  it('still toggles completion (not the edit popup) for an INLINE task marker click', async () => {
    const view = await makeEditor('<!-- ::task:: [ ] Review introduction -->');
    // 'inline' is the default, but set explicitly so this test doesn't depend on it.
    setAnnotationDisplayModes({ task: 'inline' });

    click(markerSpan(view));

    expect(isAnnotationEditPopupOpen()).toBe(false);
    let isCompleted: boolean | undefined;
    view.state.doc.descendants((node) => {
      if (node.type.name === 'annotation') isCompleted = node.attrs.isCompleted;
      return true;
    });
    expect(isCompleted).toBe(true);
  });
});
