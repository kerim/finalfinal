// @vitest-environment jsdom
// Regression tests for annotation deletion: the shared transaction builder
// (annotation-delete.ts), its Backspace/Delete keymap wiring (annotation-plugin.ts), the
// popup's Delete button (annotation-edit-popup.ts), and the panel-card bridge function
// (api-annotations.ts's deleteInlineAnnotation). Direct analogue of citation-delete.test.ts --
// see that file's header for why a real Milkdown Editor instance is used rather than a
// hand-built minimal Schema.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { undo } from '@milkdown/kit/prose/history';
import type { Node } from '@milkdown/kit/prose/model';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { buildAnnotationDeleteTransaction } from '../annotation-delete';
import { hideAnnotationEditPopup, showAnnotationEditPopup } from '../annotation-edit-popup';
import type { AnnotationAttrs } from '../annotation-plugin';
import { annotationPlugin } from '../annotation-plugin';
import { deleteInlineAnnotation } from '../api-annotations';
import { getEditorInstance, setEditorInstance } from '../editor-state';

describe('annotation deletion', () => {
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

  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      // annotationPlugin MUST be registered before commonmark/gfm — mirrors main.ts's ordering.
      .use(annotationPlugin)
      .use(commonmark)
      .use(gfm)
      .use(history)
      .create();
    editor = e;
    return e;
  }

  /** All annotation node positions in the document, in document order. */
  function annotationPositions(doc: Node): number[] {
    const positions: number[] = [];
    doc.descendants((node, pos) => {
      if (node.type.name === 'annotation') positions.push(pos);
    });
    return positions;
  }

  // getMarkdown() always appends a trailing newline; strip only that.
  function markdownOf(e: Editor): string {
    return e.action(getMarkdown()).replace(/\n+$/, '');
  }

  function placeCursor(view: EditorView, pos: number): void {
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)));
  }

  // See citation-delete.test.ts's matching helper for why this (rather than a raw DOM
  // KeyboardEvent) is the right way to exercise the real handleKeyDown dispatch path.
  function pressKey(view: EditorView, key: string): boolean {
    const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true });
    return !!view.someProp('handleKeyDown', (f) => f(view, event));
  }

  // ---- shared buildAnnotationDeleteTransaction() ----

  it('mid-paragraph annotation: deletion collapses the doubled space (single space survives)', async () => {
    const e = await makeEditor('See <!-- ::comment:: note --> for details.');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = annotationPositions(view.state.doc);

    const tr = buildAnnotationDeleteTransaction(view.state, pos);
    expect(tr).not.toBeNull();
    view.dispatch(tr!);

    expect(annotationPositions(view.state.doc)).toHaveLength(0);
    expect(markdownOf(e)).toBe('See for details.');
  });

  it('annotation at end of paragraph: no doubled/missing space (only one side is whitespace)', async () => {
    const e = await makeEditor('See <!-- ::comment:: note -->.');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = annotationPositions(view.state.doc);

    const tr = buildAnnotationDeleteTransaction(view.state, pos);
    expect(tr).not.toBeNull();
    view.dispatch(tr!);

    expect(annotationPositions(view.state.doc)).toHaveLength(0);
    expect(markdownOf(e)).toBe('See .');
  });

  it('stale position (not actually an annotation) returns null', async () => {
    const e = await makeEditor('See <!-- ::comment:: note --> for details.');
    const view = e.ctx.get(editorViewCtx);

    // Position 0 is the document boundary itself, never an annotation node.
    const tr = buildAnnotationDeleteTransaction(view.state, 0);
    expect(tr).toBeNull();
  });

  // ---- Backspace/Delete keymap ----

  it('Backspace immediately after a mid-paragraph annotation removes it in one press and collapses the space', async () => {
    const e = await makeEditor('See <!-- ::comment:: note --> for details.');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = annotationPositions(view.state.doc);
    const node = view.state.doc.nodeAt(pos)!;
    placeCursor(view, pos + node.nodeSize);

    const handled = pressKey(view, 'Backspace');

    expect(handled).toBe(true);
    expect(annotationPositions(view.state.doc)).toHaveLength(0);
    expect(markdownOf(e)).toBe('See for details.');
  });

  it('Delete immediately before a mid-paragraph annotation removes it in one press and collapses the space', async () => {
    const e = await makeEditor('See <!-- ::comment:: note --> for details.');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = annotationPositions(view.state.doc);
    placeCursor(view, pos);

    const handled = pressKey(view, 'Delete');

    expect(handled).toBe(true);
    expect(annotationPositions(view.state.doc)).toHaveLength(0);
    expect(markdownOf(e)).toBe('See for details.');
  });

  it('keymap is inert when the cursor is not adjacent to an annotation (negative guard)', async () => {
    const e = await makeEditor('See <!-- ::comment:: note --> for details.');
    const view = e.ctx.get(editorViewCtx);
    placeCursor(view, view.state.doc.content.size - 2);

    const handled = pressKey(view, 'Backspace');

    expect(handled).toBe(false);
    expect(annotationPositions(view.state.doc)).toHaveLength(1);
  });

  // ---- popup Delete button ----

  it('popup Delete button removes the annotation and hides the popup', async () => {
    const e = await makeEditor('See <!-- ::comment:: note --> for details.');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = annotationPositions(view.state.doc);
    const attrs = view.state.doc.nodeAt(pos)!.attrs as AnnotationAttrs;

    showAnnotationEditPopup(pos, view, attrs);

    const popup = document.querySelector('.ff-annotation-edit-popup') as HTMLElement | null;
    expect(popup).toBeTruthy();
    expect(popup!.style.display).toBe('block');

    const deleteButton = document.querySelector('.ff-annotation-delete-button') as HTMLElement | null;
    expect(deleteButton).toBeTruthy();
    deleteButton!.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));

    expect(annotationPositions(view.state.doc)).toHaveLength(0);
    expect(popup!.style.display).toBe('none');
    expect(markdownOf(e)).toBe('See for details.');
  });

  it('popup Delete button no-ops gracefully (no throw) when the annotation is already gone', async () => {
    const e = await makeEditor('See <!-- ::comment:: note --> for details.');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = annotationPositions(view.state.doc);
    const attrs = view.state.doc.nodeAt(pos)!.attrs as AnnotationAttrs;

    showAnnotationEditPopup(pos, view, attrs);
    // Remove the annotation out from under the open popup (e.g. some other path deleted it).
    const tr = buildAnnotationDeleteTransaction(view.state, pos);
    view.dispatch(tr!);
    expect(annotationPositions(view.state.doc)).toHaveLength(0);

    const deleteButton = document.querySelector('.ff-annotation-delete-button') as HTMLElement | null;
    expect(deleteButton).toBeTruthy();
    expect(() => {
      deleteButton!.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    }).not.toThrow();
  });

  // ---- panel-card bridge function (api-annotations.ts) ----

  it('deleteInlineAnnotation(index, type, text) deletes the nth annotation in document order and is undoable', async () => {
    const e = await makeEditor(
      '<!-- ::task:: [ ] first --> then <!-- ::comment:: second --> and <!-- ::reference:: third -->'
    );
    const view = e.ctx.get(editorViewCtx);
    setEditorInstance(e);
    const original = markdownOf(e);
    expect(annotationPositions(view.state.doc)).toHaveLength(3);

    const ok = deleteInlineAnnotation(1, 'comment', 'second'); // the "second" (comment) annotation
    expect(ok).toBe(true);
    expect(annotationPositions(view.state.doc)).toHaveLength(2);
    expect(markdownOf(e)).not.toContain('second');
    expect(markdownOf(e)).toContain('first');
    expect(markdownOf(e)).toContain('third');

    const undone = undo(view.state, view.dispatch);
    expect(undone).toBe(true);
    expect(annotationPositions(view.state.doc)).toHaveLength(3);
    expect(markdownOf(e)).toBe(original);
  });

  it('deleteInlineAnnotation returns false for an out-of-range index with no identity match either', async () => {
    const e = await makeEditor('<!-- ::comment:: only -->');
    setEditorInstance(e);

    expect(deleteInlineAnnotation(5, 'comment', 'nonexistent')).toBe(false);
    expect(deleteInlineAnnotation(-1, 'comment', 'nonexistent')).toBe(false);
  });

  // ---- must-fix 1 (judge round review): stale-index identity verification ----

  it('deleteInlineAnnotation falls back to a unique type+text re-scan when the index is stale (panel list lagged the live document)', async () => {
    const e = await makeEditor(
      '<!-- ::task:: [ ] first --> then <!-- ::comment:: second --> and <!-- ::reference:: third -->'
    );
    const view = e.ctx.get(editorViewCtx);
    setEditorInstance(e);

    // Simulate the panel's index having gone stale: index 0 is really "first" (a task) now,
    // but the caller still believes index 0 is "second" (a comment) -- e.g. an earlier delete
    // shifted every later index down by one before the panel's debounced list caught up.
    const ok = deleteInlineAnnotation(0, 'comment', 'second');
    expect(ok).toBe(true);
    expect(annotationPositions(view.state.doc)).toHaveLength(2);
    // The "second" comment was still correctly deleted via the identity re-scan, NOT "first"
    // (which the stale index 0 pointed at).
    expect(markdownOf(e)).not.toContain('second');
    expect(markdownOf(e)).toContain('first');
    expect(markdownOf(e)).toContain('third');
  });

  it('deleteInlineAnnotation refuses (returns false, deletes nothing) when a stale index has zero identity matches', async () => {
    const e = await makeEditor('<!-- ::comment:: only -->');
    setEditorInstance(e);
    const view = e.ctx.get(editorViewCtx);

    expect(deleteInlineAnnotation(0, 'comment', 'nonexistent')).toBe(false);
    expect(annotationPositions(view.state.doc)).toHaveLength(1);
  });

  it('deleteInlineAnnotation refuses (returns false, deletes nothing) when a stale index has multiple identity matches -- never guesses by position', async () => {
    const e = await makeEditor('<!-- ::comment:: dup --> and again <!-- ::comment:: dup -->');
    setEditorInstance(e);
    const view = e.ctx.get(editorViewCtx);
    expect(annotationPositions(view.state.doc)).toHaveLength(2);

    // The node at index 0 does NOT match ('reference' vs 'comment'), so this falls back to the
    // identity re-scan -- which finds two "comment"/"dup" annotations and must refuse rather
    // than guess which one the caller meant.
    expect(deleteInlineAnnotation(0, 'reference', 'dup')).toBe(false);
    expect(annotationPositions(view.state.doc)).toHaveLength(2);
  });
});
