// @vitest-environment jsdom
// Regression guard for annotation-edit-popup.ts's max-width cap.
//
// This exact regression already happened once on this branch: an unrelated
// accessibility-focused edit accidentally widened `min-width` from 250px to
// 280px (fine, matches citation-edit-popup.ts/math-edit-popup.ts's own
// convention) but ALSO dropped the `max-width` cap entirely — from
// `min(400px, calc(100vw - 16px))` down to a bare `calc(100vw - 16px)`,
// letting the popup grow to the full window width minus a small margin. This
// pins the exact string back down so it can't silently regress again.
//
// NOTE: this only guards the STRING that gets set — jsdom has no real layout
// engine, so it cannot verify that the popup actually renders clamped to
// 400px, or that min()/calc() are honored at paint time. That requires
// real-WebKit measurement (this project's e2e-verify pipeline stage), not
// this test.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { hideAnnotationEditPopup } from '../annotation-edit-popup';
import { annotationPlugin } from '../annotation-plugin';

describe('annotation edit popup max-width regression guard', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
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
      .use(annotationPlugin)
      .use(commonmark)
      .use(gfm)
      .create();
    editor = e;
    return e.ctx.get(editorViewCtx);
  }

  it('caps max-width at min(400px, calc(100vw - 16px)), not a bare calc(100vw - 16px)', async () => {
    const view = await makeEditor('<!-- ::comment:: Needs more detail -->');
    const anno = view.dom.querySelector('.ff-annotation') as HTMLElement;
    anno.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));

    const popup = document.querySelector('.ff-annotation-edit-popup') as HTMLElement;
    expect(popup).toBeTruthy();
    expect(popup.style.maxWidth).toBe('min(400px, calc(100vw - 16px))');
    // Not the regressed (uncapped) value.
    expect(popup.style.maxWidth).not.toBe('calc(100vw - 16px)');
  });
});
