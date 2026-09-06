// @vitest-environment jsdom
// Regression test for the citation SEARCH/INSERT PICKER computing the wrong citekey
// precedence. Better BibTeX (BBT) returns Zotero items keyed by CSL `citation-key`
// but *resolves/matches* by its own KeyManager key, exposed as CSL `id`. For an item
// where `citation-key` != `id`, the picker used to compute
// `citekey = item['citation-key'] || item.citationKey || item.id` (citation-key
// first) and write that stale value straight into the document on insert.
// Downstream, citeproc-engine.ts keys its bibliography map by `id` (see
// citeproc-engine-id-precedence.test.ts), so the stale inserted citekey shows up as
// an unresolved "(key?)" placeholder — the exact symptom this whole bug family is
// about, just moved to a different entry point (the picker instead of the render
// path). The fix flips the precedence to `id` first via citeproc-engine.ts's
// exported resolveKey(), reused here rather than re-derived.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { citationPlugin } from '../citation-plugin';
import { hideSearchPopup, searchCitationsCallback, showCitationSearchPopup } from '../citation-search';
import type { CSLItem } from '../citeproc-engine';

describe('citation search/insert picker id-vs-citation-key precedence', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    hideSearchPopup();
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
      // citationPlugin MUST be registered before commonmark/gfm — mirrors
      // citation-delete.test.ts / main.ts's registration ordering.
      .use(citationPlugin)
      .use(commonmark)
      .use(gfm)
      .use(history)
      .create();
    editor = e;
    return e;
  }

  /** All citation node positions in the document, in document order. */
  function citationPositions(view: EditorView): number[] {
    const positions: number[] = [];
    view.state.doc.descendants((node, pos) => {
      if (node.type.name === 'citation') positions.push(pos);
    });
    return positions;
  }

  // `id` (BBT's canonical KeyManager key) differs from BOTH `citation-key` (a stale
  // legacy value, e.g. left over from an old `Citation Key:` line in the item's
  // Zotero Extra field) and `citationKey`. Correct precedence must pick `id`.
  const ITEM: CSLItem & { 'citation-key': string } = {
    id: 'friedman2010',
    type: 'book',
    title: 'A Test Book',
    author: [{ family: 'Friedman', given: 'P. Kerim' }],
    issued: { 'date-parts': [[2010]] },
    citationKey: 'anotherStaleKey2010',
    'citation-key': 'oldLegacyKey2010',
  };

  it('inserts the item `id` as the citekey (not the stale `citation-key`/`citationKey`), and displays `id` in the result badge', async () => {
    const e = await makeEditor('Some text here.');
    const view = e.ctx.get(editorViewCtx);

    // Place the cursor inside the paragraph, before the doc end, and open the
    // search popup as if the user typed `/cite` at this position.
    const cmdPos = view.state.doc.content.size - 1;
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, cmdPos)));

    // jsdom has no real layout engine (see annotation-edit-popup-width.test.ts's own
    // note on this): at this text position, ProseMirror's coordsAtPos() builds a DOM
    // Range and calls Range.getClientRects(), which jsdom doesn't implement, throwing
    // "target.getClientRects is not a function". That's an unrelated popup-positioning
    // cosmetic, not part of the citekey-precedence behavior under test, so stub it out.
    view.coordsAtPos = () => ({ left: 0, right: 0, top: 0, bottom: 0 }) as ReturnType<EditorView['coordsAtPos']>;

    showCitationSearchPopup(cmdPos, view);
    searchCitationsCallback([ITEM]);

    const resultItem = document.querySelector('.ff-citation-search-item') as HTMLElement | null;
    expect(resultItem).toBeTruthy();

    // Display-only citekey badge (createResultItem's `@${citekey}` span) must also
    // prefer `id`, not the stale citation-key/citationKey.
    const spans = resultItem!.querySelectorAll('span');
    const keySpan = spans[spans.length - 1];
    expect(keySpan.textContent).toBe(`@${ITEM.id}`);
    expect(keySpan.textContent).not.toContain(ITEM['citation-key']);
    expect(keySpan.textContent).not.toContain(ITEM.citationKey);

    // Click to select/insert (the real insertCitation() path).
    resultItem!.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));

    const positions = citationPositions(view);
    expect(positions).toHaveLength(1);
    const attrs = view.state.doc.nodeAt(positions[0])!.attrs as { citekeys: string };
    expect(attrs.citekeys).toBe(ITEM.id);
    expect(attrs.citekeys).not.toBe(ITEM['citation-key']);
    expect(attrs.citekeys).not.toBe(ITEM.citationKey);
  });
});
