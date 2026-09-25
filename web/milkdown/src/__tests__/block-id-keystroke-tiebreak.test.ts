// @vitest-environment jsdom
// F1b reachability: Enter, then a keystroke in the paragraph above, through the REAL plugin
// (no hand-built map order).
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { splitBlock } from '@milkdown/kit/prose/commands';
import { TextSelection } from '@milkdown/kit/prose/state';
import { describe, expect, it } from 'vitest';
import { blockIdPlugin, getAllBlockIds, resetBlockIdState, setBlockIdZoomMode } from '../block-id-plugin';

describe('F1b reachability: Enter, then type in the paragraph above', () => {
  it('each block keeps its own id', async () => {
    resetBlockIdState();
    setBlockIdZoomMode(false); // defensive: a leaked zoom mode would suppress temp ids and mask a real regression
    const div = document.createElement('div');
    document.body.appendChild(div);
    // blockIdPlugin before commonmark/gfm mirrors main.ts (see block-id-dom-decoration.test.ts).
    const editor = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, 'Alpha\n\nBeta');
      })
      .use(blockIdPlugin)
      .use(commonmark)
      .use(gfm)
      .create();
    try {
      const view = editor.ctx.get(editorViewCtx);
      view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, 6))); // end of "Alpha"
      splitBlock(view.state, view.dispatch);
      expect(view.state.doc.nodeAt(7)?.textContent).toBe('');
      expect(view.state.doc.nodeAt(9)?.textContent).toBe('Beta');
      const ids = getAllBlockIds();
      expect([...ids.keys()]).toEqual([0, 9, 7]); // precondition: a real Enter leaves the map out of doc order
      const alphaId = ids.get(0)!;
      const emptyId = ids.get(7)!;
      const betaId = ids.get(9)!;
      view.dispatch(view.state.tr.insertText('!', 6)); // one keystroke in "Alpha"
      const after = getAllBlockIds();
      expect(view.state.doc.nodeAt(10)?.textContent).toBe('Beta');
      expect(after.size).toBe(ids.size); // no block gained or lost an id
      expect(after.get(0)).toBe(alphaId); // Alpha's own id is unchanged
      expect(after.get(8)).toBe(emptyId);
      expect(after.get(10)).toBe(betaId);
    } finally {
      await editor.destroy();
      div.remove();
      resetBlockIdState();
    }
  });
});
