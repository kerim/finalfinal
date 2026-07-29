// @vitest-environment jsdom
// Characterization tests for the annotation edit popup's module-level
// singleton (annotation-edit-popup.ts). They pin down that switching between
// annotations, or inserting a new annotation, while a popup is already open
// never leaves a second `.ff-annotation-edit-popup` element in the DOM — only
// ever one popup element exists, reused and repositioned/repopulated in
// place. This singleton-reuse behavior predates this task's changes; these
// tests document and guard the pre-existing correct behavior rather than
// covering a regression this task introduced or fixed.
//
// Uses a real Milkdown Editor (commonmark + gfm + annotationPlugin), matching
// annotation-collapsed-click.test.ts's approach, so the actual NodeView click
// listeners and the real showAnnotationEditPopup()/insertAnnotation() call
// sites are exercised end-to-end rather than a hand-rolled stand-in.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { hideAnnotationEditPopup, isAnnotationEditPopupOpen } from '../annotation-edit-popup';
import { annotationPlugin } from '../annotation-plugin';
import { insertAnnotation } from '../api-annotations';
import { getEditorInstance, setEditorInstance } from '../editor-state';

describe('annotation edit popup singleton', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    hideAnnotationEditPopup();
    if (getEditorInstance()) {
      setEditorInstance(null);
    }
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

  function click(el: HTMLElement): void {
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  }

  function popupCount(): number {
    return document.querySelectorAll('.ff-annotation-edit-popup').length;
  }

  it('clicking a second annotation while the first popup is still open reuses the same popup element', async () => {
    const view = await makeEditor('<!-- ::comment:: First annotation -->\n\n<!-- ::comment:: Second annotation -->');
    const annos = view.dom.querySelectorAll('.ff-annotation');
    expect(annos.length).toBe(2);

    click(annos[0] as HTMLElement);
    expect(isAnnotationEditPopupOpen()).toBe(true);
    expect(popupCount()).toBe(1);

    // Click annotation B directly, WITHOUT dismissing A first (no blur, no Escape).
    click(annos[1] as HTMLElement);

    expect(popupCount()).toBe(1);
    const textarea = document.querySelector('.ff-annotation-edit-input') as HTMLTextAreaElement;
    expect(textarea.value).toBe('Second annotation');
  });

  it('rapid re-clicks on the same annotation never create a second popup element', async () => {
    const view = await makeEditor('<!-- ::comment:: Only annotation -->');
    const anno = view.dom.querySelector('.ff-annotation') as HTMLElement;

    click(anno);
    click(anno);
    click(anno);

    expect(popupCount()).toBe(1);
  });

  it('insertAnnotation() while a different annotation popup is open does not create a second popup element, and still actually inserts + retargets the popup', async () => {
    const view = await makeEditor('<!-- ::comment:: Existing annotation -->');
    setEditorInstance(editor);

    function annotationCount(): number {
      let count = 0;
      view.state.doc.descendants((node) => {
        if (node.type.name === 'annotation') count += 1;
        return true;
      });
      return count;
    }

    const anno = view.dom.querySelector('.ff-annotation') as HTMLElement;
    click(anno);
    expect(isAnnotationEditPopupOpen()).toBe(true);
    expect(popupCount()).toBe(1);

    const countBefore = annotationCount();
    const textarea = document.querySelector('.ff-annotation-edit-input') as HTMLTextAreaElement;
    expect(textarea.value).toBe('Existing annotation');

    // Second call site (api-annotations.ts) firing while the first popup is
    // still open and undismissed.
    insertAnnotation('task');

    expect(popupCount()).toBe(1);
    // insertAnnotation()'s own try/catch (api-annotations.ts) could otherwise
    // swallow a thrown error silently and leave popupCount() at 1 whether or
    // not it actually did anything — assert real state change so this test
    // would fail if insertAnnotation() silently no-ops or throws: a new
    // annotation node must exist in the doc, and the (still-singleton) popup
    // must now be retargeted at it (empty text, not the original annotation's).
    expect(annotationCount()).toBe(countBefore + 1);
    expect(textarea.value).toBe('');
  });
});
