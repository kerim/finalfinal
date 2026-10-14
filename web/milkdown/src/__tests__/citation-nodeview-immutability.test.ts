// @vitest-environment jsdom
//
// Phase 4b part 2, slice 2a (t-94369a83): the citation node view must never write into a node's attrs.
//
// The bug (found by the VM test `testDeleteUndoAtOnce_article`): after delete, undo, quit and reopen, 18 paragraphs after the
// deleted section cited DIFFERENT sources, cascading down the document. ProseMirror reuses ONE node view for a different
// citation when the document around it changes (its `update` is called with whatever compatible node lands in the slot), and the
// citation node view's `update` copied the new citation's attrs INTO the old node's attrs object (`Object.assign(attrs, ...)`,
// where `attrs` was the real `node.attrs`). That object is shared with every editor state that holds the node, so a saved undo
// checkpoint's own citations were rewritten when the undo swapped the checkpoint back in and the view reconciled it against a
// document whose tail differed from the checkpoint's tail.
//
// Real Milkdown editors with the real citation plugin, real ProseMirror view reconciliation (`view.updateState`, the call
// `performStructuralSwap` makes). Without the fix every test below fails: a citation of the saved state comes back with another
// citation's keys.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { Node } from '@milkdown/kit/prose/model';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { citationPlugin } from '../citation-plugin';
import { resetCiteprocEngine } from '../citeproc-engine';
import { headingNodeViewPlugin } from '../heading-nodeview-plugin';

describe('the citation node view never rewrites the attrs of a node a saved editor state still holds', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    resetCiteprocEngine();
  });

  async function makeEditor(markdown: string): Promise<EditorView> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      // Registered before commonmark/gfm, as main.ts does.
      .use(citationPlugin)
      .use(commonmark)
      .use(gfm)
      // The app's own heading node view: its `update` reuses a heading view for any heading of the same level, whatever the
      // heading's id. That is what lets the view reconciler walk a restored document against a changed one block by block, as in
      // the real app (the default heading view refuses to be reused across different heading ids).
      .use(headingNodeViewPlugin)
      .create();
    editor = e;
    return e.ctx.get(editorViewCtx);
  }

  /** The citekeys attr of every citation node, in document order. */
  function citationKeys(doc: Node): string[] {
    const keys: string[] = [];
    doc.descendants((node) => {
      if (node.type.name === 'citation') keys.push(node.attrs.citekeys as string);
      return true;
    });
    return keys;
  }

  /** Document positions around the top-level child at `index`: `from` is before it, `to` is after it. */
  function childRange(doc: Node, index: number): { from: number; to: number } {
    let from = 0;
    for (let i = 0; i < index; i++) from += doc.child(i).nodeSize;
    return { from, to: from + doc.child(index).nodeSize };
  }

  it('swapping a saved state back in after deleting a paragraph and changing the tail leaves every citation as it was (3 paragraphs)', async () => {
    const view = await makeEditor('Cites [@a].\n\nCites [@b].\n\ntail');
    const before = view.state;
    expect(citationKeys(before.doc)).toEqual(['a', 'b']);

    // One transaction: the first paragraph goes and the tail's text changes -- nothing in the new document matches the saved one
    // by identity except paragraph two, so the view reuses node views for different citations on the way back.
    const first = childRange(before.doc, 0);
    const tail = childRange(before.doc, 2);
    const tr = view.state.tr.insertText(' changed', tail.to - 1).delete(first.from, first.to);
    view.dispatch(tr);
    expect(citationKeys(view.state.doc)).toEqual(['b']);

    view.updateState(before);

    expect(citationKeys(before.doc)).toEqual(['a', 'b']); // the saved state itself is untouched
    expect(citationKeys(view.state.doc)).toEqual(['a', 'b']);
  });

  it('the same on an article-shaped document: citations in two consecutive sections and a tail, first section deleted, tail changed', async () => {
    const markdown = [
      '# Section one',
      'First cites [@k1] and [@k2].',
      'Second cites [@k3].',
      '# Section two',
      'Third cites [@k4] and [@k5; @k6].',
      'Fourth cites [@k7].',
      '# Section three',
      'Fifth cites [@k8].',
      'Sixth cites [@k9; @k10].',
      'Seventh cites [@k11].',
    ].join('\n\n');
    const view = await makeEditor(markdown);
    const before = view.state;
    // Top-level children: 0 heading one, 1-2 its paragraphs, 3 heading two, 4-5, 6 heading three, 7-9.
    expect(before.doc.childCount).toBe(10);
    const keysBefore = citationKeys(before.doc);
    expect(keysBefore.length).toBe(9); // k1, k2, k3, k4, (k5; k6), k7, k8, (k9; k10), k11
    expect(keysBefore[0]).toBe('k1');

    // Delete the whole first section (heading and both paragraphs) and change the text of two paragraphs in the tail, as the
    // Notes and bibliography rebuilds do after a delete.
    const sectionStart = childRange(before.doc, 0).from;
    const sectionEnd = childRange(before.doc, 3).from;
    const seventh = childRange(before.doc, 9);
    const fifth = childRange(before.doc, 7);
    const tr = view.state.tr
      .insertText(' (rebuilt)', seventh.to - 1)
      .insertText(' (rebuilt)', fifth.to - 1)
      .delete(sectionStart, sectionEnd);
    view.dispatch(tr);
    expect(citationKeys(view.state.doc)).toEqual(keysBefore.slice(3));

    view.updateState(before);

    expect(citationKeys(before.doc)).toEqual(keysBefore);
    expect(citationKeys(view.state.doc)).toEqual(keysBefore);
  });

  it('a node view update writes nothing into the node it replaces: the old node keeps its attrs when its citation is changed in place', async () => {
    const view = await makeEditor('Cites [@a].');
    const before = view.state;
    let citationPos = -1;
    before.doc.descendants((node, pos) => {
      if (node.type.name === 'citation') citationPos = pos;
      return true;
    });
    expect(citationPos).toBeGreaterThanOrEqual(0);
    const oldNode = before.doc.nodeAt(citationPos) as Node;
    expect(oldNode.attrs.citekeys).toBe('a');

    // Change the citation's keys the way an edit does: ProseMirror hands the existing node view the new node.
    view.dispatch(view.state.tr.setNodeMarkup(citationPos, undefined, { ...oldNode.attrs, citekeys: 'z' }));

    expect(citationKeys(view.state.doc)).toEqual(['z']);
    expect(oldNode.attrs.citekeys).toBe('a'); // the node the saved state holds is not touched
    expect(citationKeys(before.doc)).toEqual(['a']);
  });
});
