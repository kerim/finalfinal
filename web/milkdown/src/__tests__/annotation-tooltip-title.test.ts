// @vitest-environment jsdom
// Regression tests for the duplicate-tooltip bug on collapsed annotations.
//
// annotation-display-plugin.ts renders a 'collapsed' annotation with the
// `.ff-annotation-collapsed` class, which shows a custom CSS hover tooltip
// (`.ff-annotation-collapsed::after`, driven by the `data-text` attribute).
// Separately, annotation-plugin.ts's NodeView (and toDOM) used to
// unconditionally set the native `title` attribute to the same text — so a
// collapsed annotation showed BOTH the custom bubble AND the browser's own
// native tooltip on hover, overlapping. Only the collapsed case is affected
// ("sometimes"); inline annotations have no competing CSS tooltip, so keeping
// `title` there is fine and unchanged.
//
// Uses a real Milkdown Editor with BOTH annotationPlugin and
// annotationDisplayPlugin (mirrors main.ts's registration), since the display
// mode is decoration-driven, not a node attribute — exercising the real
// interaction between the two plugins is the point of this test, not just
// the NodeView in isolation.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { annotationDisplayPlugin, setAnnotationDisplayModes } from '../annotation-display-plugin';
import { annotationPlugin } from '../annotation-plugin';

describe('annotation title attribute vs collapsed CSS tooltip', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    // Reset module-level display-mode state so it doesn't leak into other
    // tests in this file (or, in watch mode, other files sharing the worker).
    setAnnotationDisplayModes({ task: 'inline', comment: 'inline', reference: 'inline' });
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
      .use(annotationPlugin)
      .use(annotationDisplayPlugin)
      .use(commonmark)
      .use(gfm)
      .create();
    editor = e;
    return e.ctx.get(editorViewCtx);
  }

  it('keeps the native title attribute for an INLINE annotation (no competing CSS tooltip)', async () => {
    const view = await makeEditor('<!-- ::comment:: Needs more detail -->');
    const wrapper = view.dom.querySelector('.ff-annotation') as HTMLElement;

    expect(wrapper.classList.contains('ff-annotation-collapsed')).toBe(false);
    expect(wrapper.getAttribute('title')).toBe('Needs more detail');
  });

  it('clears the native title attribute for a COLLAPSED annotation at creation time (CSS bubble already covers it)', async () => {
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const view = await makeEditor('<!-- ::comment:: Needs more detail -->');
    const wrapper = view.dom.querySelector('.ff-annotation') as HTMLElement;

    expect(wrapper.classList.contains('ff-annotation-collapsed')).toBe(true);
    expect(wrapper.hasAttribute('title')).toBe(false);
    // The custom CSS tooltip still has the full text available via data-text.
    expect(wrapper.getAttribute('data-text')).toBe('Needs more detail');
  });

  it('clears the native title attribute reactively when display mode switches to collapsed at runtime', async () => {
    const view = await makeEditor('<!-- ::comment:: Needs more detail -->');
    const wrapper = view.dom.querySelector('.ff-annotation') as HTMLElement;
    expect(wrapper.getAttribute('title')).toBe('Needs more detail');

    // Mirrors api-annotations.ts's setAnnotationDisplayModes(): change the
    // mode, then dispatch an empty transaction to force redecoration — no
    // node attrs change, only the decoration (and therefore only the
    // NodeView's live re-check of display mode) drives this.
    setAnnotationDisplayModes({ comment: 'collapsed' });
    view.dispatch(view.state.tr);

    expect(wrapper.classList.contains('ff-annotation-collapsed')).toBe(true);
    expect(wrapper.hasAttribute('title')).toBe(false);
  });

  it('restores the native title attribute when display mode switches back to inline', async () => {
    setAnnotationDisplayModes({ comment: 'collapsed' });
    const view = await makeEditor('<!-- ::comment:: Needs more detail -->');
    const wrapper = view.dom.querySelector('.ff-annotation') as HTMLElement;
    expect(wrapper.hasAttribute('title')).toBe(false);

    setAnnotationDisplayModes({ comment: 'inline' });
    view.dispatch(view.state.tr);

    expect(wrapper.classList.contains('ff-annotation-collapsed')).toBe(false);
    expect(wrapper.getAttribute('title')).toBe('Needs more detail');
  });
});
