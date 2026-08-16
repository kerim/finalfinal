// @vitest-environment jsdom
// Tests for the "Delete table" button added to the floating table toolbar
// (table-tools-plugin.ts). Builds a real Milkdown editor with a GFM table
// fixture between two paragraphs and drives the button via a real click,
// same as the existing ×row/×col wiring.
//
// Toolbar visibility (`data-show`) IS asserted below: getTableInfo()'s call to
// view.coordsAtPos() doesn't throw under jsdom — it just returns degenerate
// (zero-ish) coordinates, since jsdom has no real layout engine — so the
// show/hide toggle itself is cheap and reliable to test here. What jsdom
// can't give us is meaningful *pixel positioning* (the toolbar's computed
// left/top), so that — and driving the button with a real mousedown-then-click
// sequence instead of a bare dispatched click — stays covered by the
// e2e-verify pipeline stage against real WebKit instead.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { tableToolsPlugin } from '../table-tools-plugin';

const fixture = ['Before paragraph.', '', '| A | B |', '| --- | --- |', '| 1 | 2 |', '', 'After paragraph.', ''].join(
  '\n'
);

describe('table-tools-plugin: Delete table', () => {
  let editor: Editor | null = null;
  const containers: HTMLElement[] = [];

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    // tableToolsPlugin appends its toolbar directly to document.body; make
    // sure a leftover from one test doesn't leak into the next.
    for (const el of document.querySelectorAll('.table-toolbar')) el.remove();
    // makeEditor's own mount div is likewise appended straight to
    // document.body and was never cleaned up, leaking one <div> per test.
    for (const el of containers.splice(0)) el.remove();
  });

  async function makeEditor(markdown: string): Promise<EditorView> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    containers.push(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(commonmark)
      .use(gfm)
      .use(tableToolsPlugin)
      .create();
    editor = e;
    return e.ctx.get(editorViewCtx);
  }

  function hasNodeType(doc: EditorView['state']['doc'], typeName: string): boolean {
    let found = false;
    doc.descendants((node) => {
      if (node.type.name === typeName) found = true;
    });
    return found;
  }

  // Only top-level paragraphs (direct children of the doc) — table cells also
  // wrap their content in `paragraph` nodes, so a full descendants() walk
  // would pick up cell text too and defeat the "surrounding paragraphs
  // survive, table content doesn't" assertion this is meant to make.
  function topLevelParagraphTexts(doc: EditorView['state']['doc']): string[] {
    const texts: string[] = [];
    doc.forEach((node) => {
      if (node.type.name === 'paragraph') texts.push(node.textContent);
    });
    return texts;
  }

  it('renders exactly one "Delete table" button in the toolbar', async () => {
    await makeEditor(fixture);
    const buttons = document.querySelectorAll('[aria-label="Delete table"]');
    expect(buttons.length).toBe(1);
  });

  it('places "Delete table" after the alignment dropdown', async () => {
    await makeEditor(fixture);
    const kids = Array.from((document.querySelector('.table-toolbar') as HTMLElement).children);
    const alignIdx = kids.findIndex((el) => el.classList.contains('table-toolbar-align'));
    const delIdx = kids.findIndex((el) => el.getAttribute('aria-label') === 'Delete table');
    expect(alignIdx).toBeGreaterThan(-1);
    expect(delIdx).toBeGreaterThan(alignIdx);
  });

  it('shows the toolbar when the caret is in a table cell, hides it when the caret leaves', async () => {
    const view = await makeEditor(fixture);
    const toolbar = document.querySelector('.table-toolbar') as HTMLElement;

    // Editor starts with the caret at the top of the doc, outside the table.
    expect(toolbar.getAttribute('data-show')).toBe('false');

    const cellEl = view.dom.querySelector('td, th') as HTMLElement;
    const cellPos = view.posAtDOM(cellEl, 0);
    view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(cellPos))));
    expect(toolbar.getAttribute('data-show')).toBe('true');

    // Move the caret back out into the trailing paragraph.
    const lastParaPos = view.state.doc.content.size - 1;
    view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(lastParaPos))));
    expect(toolbar.getAttribute('data-show')).toBe('false');
  });

  it('removes the whole table on click with the caret in a cell, leaving the surrounding paragraphs intact', async () => {
    const view = await makeEditor(fixture);

    expect(hasNodeType(view.state.doc, 'table')).toBe(true);
    expect(topLevelParagraphTexts(view.state.doc)).toEqual(['Before paragraph.', 'After paragraph.']);

    // Place the caret inside a table cell, same as a real user click before
    // reaching for the toolbar.
    const cellEl = view.dom.querySelector('td, th') as HTMLElement;
    expect(cellEl).toBeTruthy();
    const pos = view.posAtDOM(cellEl, 0);
    view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos))));

    const deleteBtn = document.querySelector('[aria-label="Delete table"]') as HTMLButtonElement;
    expect(deleteBtn).toBeTruthy();
    expect(deleteBtn.disabled).toBe(false);

    deleteBtn.dispatchEvent(new MouseEvent('click', { bubbles: true }));

    expect(hasNodeType(view.state.doc, 'table')).toBe(false);
    expect(topLevelParagraphTexts(view.state.doc)).toEqual(['Before paragraph.', 'After paragraph.']);
  });

  // NOTE: this only asserts the table node itself is gone. It deliberately
  // does NOT assert anything about the enclosing blockquote — deleting a
  // table nested inside one currently leaves an empty blockquote behind
  // (containing a single empty paragraph) rather than removing the now-empty
  // container. That's a real gap, reported separately; fixing it is out of
  // scope here (see task notes) so this test only locks in the part of the
  // behavior that already works correctly: the table is really gone and the
  // command doesn't silently no-op.
  it('deletes a table nested inside a blockquote', async () => {
    const view = await makeEditor(['> | A | B |', '> | --- | --- |', '> | 1 | 2 |', ''].join('\n'));
    expect(hasNodeType(view.state.doc, 'table')).toBe(true);
    const cellEl = view.dom.querySelector('td, th') as HTMLElement;
    const pos = view.posAtDOM(cellEl, 0);
    view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos))));
    (document.querySelector('[aria-label="Delete table"]') as HTMLButtonElement).dispatchEvent(
      new MouseEvent('click', { bubbles: true })
    );
    expect(hasNodeType(view.state.doc, 'table')).toBe(false);
  });
});
