// @vitest-environment jsdom
// Regression tests for CAYW (Cite-As-You-Write) position tracking (cayw.ts).
//
// The bug this hardens against: /cite command position tracking used to live in
// a single module-level singleton (`pendingCAYWRange`). The Zotero round-trip is
// a real async HTTP call that can take arbitrary time and is NOT blocked by the
// app's own UI, so (a) a second /cite before the first resolves would clobber
// the first's stored range, and (b) continued editing during the round-trip
// would make stale raw offsets point at the wrong content. The fix replaces the
// singleton with a Map keyed by an opaque, monotonically-increasing requestId,
// plus a ProseMirror plugin (caywRemapPlugin) that remaps every pending entry
// across doc-changing transactions.
//
// Uses a real Milkdown Editor instance (commonmark + gfm + citationPlugin +
// caywRemapPlugin), not a hand-built minimal Schema — mirrors citation-delete.test.ts.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { Node } from '@milkdown/kit/prose/model';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import {
  caywRemapPlugin,
  getCAYWDebugState,
  handleCAYWCallback,
  handleCAYWCancelled,
  handleCAYWError,
  openCAYWPicker,
  resetCAYWState,
} from '../cayw';
import type { CSLItem } from '../citation-plugin';
import { citationPlugin } from '../citation-plugin';
import { setEditorInstance } from '../editor-state';
import type { CAYWCallbackData } from '../types';

describe('CAYW position tracking', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    resetCAYWState();
    delete (window as any).webkit;
    setEditorInstance(null);
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
      .use(citationPlugin)
      .use(commonmark)
      .use(gfm)
      .use(history)
      .use(caywRemapPlugin)
      .create();
    editor = e;
    setEditorInstance(e);
    return e;
  }

  /** All citation node positions in the document, in document order. */
  function citationPositions(doc: Node): number[] {
    const positions: number[] = [];
    doc.descendants((node, pos) => {
      if (node.type.name === 'citation') positions.push(pos);
    });
    return positions;
  }

  /** citekeys of citation nodes nested under each TOP-LEVEL child (paragraph), in order.
   * Used to prove each resolved citation landed in its own correct paragraph. */
  function citekeysPerTopLevelNode(doc: Node): string[][] {
    const result: string[][] = [];
    doc.forEach((node) => {
      const keys: string[] = [];
      node.descendants((child) => {
        if (child.type.name === 'citation') keys.push(child.attrs.citekeys as string);
      });
      result.push(keys);
    });
    return result;
  }

  /** All start positions of a text substring across the document, in document order. */
  function findAllTextPositions(doc: Node, substr: string): number[] {
    const positions: number[] = [];
    doc.descendants((node, pos) => {
      if (node.isText && node.text) {
        let idx = node.text.indexOf(substr);
        while (idx !== -1) {
          positions.push(pos + idx);
          idx = node.text.indexOf(substr, idx + 1);
        }
      }
      return true;
    });
    return positions;
  }

  function markdownOf(e: Editor): string {
    return e.action(getMarkdown()).replace(/\n+$/, '');
  }

  /** Installs a fake Swift bridge for openCitationPicker and returns the array
   * that captures every requestId posted through it, in call order. */
  function installOpenPickerMock(): number[] {
    const captured: number[] = [];
    (window as any).webkit = {
      messageHandlers: {
        openCitationPicker: {
          postMessage: (id: number) => {
            captured.push(id);
          },
        },
      },
    };
    return captured;
  }

  function makeCallbackData(overrides: Partial<CAYWCallbackData>): CAYWCallbackData {
    return {
      rawSyntax: '[@testkey]',
      citekeys: ['testkey'],
      locators: '[]',
      prefix: '',
      suppressAuthor: false,
      requestId: -1,
      ...overrides,
    };
  }

  const items: CSLItem[] = [{ id: 'testkey', type: 'article' }];

  // ---- 1: monotonic id generation ----

  it('openCAYWPicker produces strictly increasing requestIds across multiple calls', async () => {
    await makeEditor('Hello world.');
    const captured = installOpenPickerMock();

    openCAYWPicker(0, 0);
    openCAYWPicker(1, 1);
    openCAYWPicker(2, 2);

    expect(captured).toHaveLength(3);
    expect(captured[1]).toBeGreaterThan(captured[0]);
    expect(captured[2]).toBeGreaterThan(captured[1]);
  });

  // ---- 2: resetCAYWState clears the map but NOT the counter ----

  it('resetCAYWState() clears pending requests but the id counter keeps increasing across the reset', async () => {
    await makeEditor('Hello world.');
    const captured = installOpenPickerMock();

    openCAYWPicker(0, 0);
    const idBeforeReset = captured[0];

    resetCAYWState();
    // The pre-reset request must be gone.
    expect(getCAYWDebugState().pendingCAYWRequests).toHaveLength(0);

    openCAYWPicker(0, 0);
    const idAfterReset = captured[1];

    // The counter survived the reset: the new id is strictly greater, never reused.
    expect(idAfterReset).toBeGreaterThan(idBeforeReset);
    // Only the post-reset request is pending.
    const pending = getCAYWDebugState().pendingCAYWRequests;
    expect(pending).toHaveLength(1);
    expect(pending[0].requestId).toBe(idAfterReset);
  });

  // ---- 3: no-op for an unrecognized requestId ----

  it('handleCAYWCallback/handleCAYWCancelled/handleCAYWError silently no-op for a requestId not in the pending map', async () => {
    const e = await makeEditor('See details.');
    const view = e.ctx.get(editorViewCtx);
    const before = markdownOf(e);
    const STALE_REQUEST_ID = 999999;

    expect(() => {
      handleCAYWCallback(makeCallbackData({ requestId: STALE_REQUEST_ID }), items);
    }).not.toThrow();
    expect(citationPositions(view.state.doc)).toHaveLength(0);
    expect(markdownOf(e)).toBe(before);

    expect(() => {
      handleCAYWCancelled(STALE_REQUEST_ID);
    }).not.toThrow();
    expect(markdownOf(e)).toBe(before);

    expect(() => {
      handleCAYWError('some error', STALE_REQUEST_ID);
    }).not.toThrow();
    expect(markdownOf(e)).toBe(before);
  });

  // ---- 4: remap plugin shifts a pending range across an intervening edit ----

  it('caywRemapPlugin shifts the pending range when an unrelated edit lands before it, so the citation is inserted at the correct (shifted) position', async () => {
    const e = await makeEditor('Hello /cite world.');
    const view = e.ctx.get(editorViewCtx);
    const captured = installOpenPickerMock();

    const [cmdStart] = findAllTextPositions(view.state.doc, '/cite');
    expect(cmdStart).toBeGreaterThan(-1);
    const cmdEnd = cmdStart + '/cite'.length;

    openCAYWPicker(cmdStart, cmdEnd);
    const requestId = captured[0];

    // Intervening unrelated edit: insert text BEFORE the pending range's start,
    // simulating the user continuing to type while the async Zotero round-trip
    // is still in flight.
    view.dispatch(view.state.tr.insertText('XX ', 1, 1));
    const inserted = 'XX '.length;

    // Resolve the (now-stale-if-unmapped) request.
    handleCAYWCallback(makeCallbackData({ requestId }), items);

    const positions = citationPositions(view.state.doc);
    expect(positions).toHaveLength(1);
    // The citation must land at the shifted position, not the stale original offset.
    expect(positions[0]).toBe(cmdStart + inserted);
    expect(view.state.doc.nodeAt(positions[0])?.attrs.citekeys).toBe('testkey');

    // No leftover /cite text, and the surrounding content survived intact and in order.
    const text = view.state.doc.textContent;
    expect(text).not.toContain('/cite');
    expect(text.indexOf('XX Hello')).toBeLessThan(text.indexOf('world.'));
  });

  // ---- 5: two overlapping requests, resolved out of order ----

  it('two overlapping /cite requests in different paragraphs, resolved out of order, each land in their own correct paragraph with no cross-contamination', async () => {
    const e = await makeEditor('First /cite paragraph.\n\nSecond /cite paragraph.');
    const view = e.ctx.get(editorViewCtx);
    const captured = installOpenPickerMock();

    const [posA, posB] = findAllTextPositions(view.state.doc, '/cite');
    expect(posA).toBeGreaterThan(-1);
    expect(posB).toBeGreaterThan(posA);

    // Open request A (first paragraph) ...
    openCAYWPicker(posA, posA + '/cite'.length);
    const requestA = captured[0];

    // ... then open request B (second paragraph) BEFORE resolving A.
    openCAYWPicker(posB, posB + '/cite'.length);
    const requestB = captured[1];

    expect(getCAYWDebugState().pendingCAYWRequests).toHaveLength(2);

    // Resolve B first, then A — out of order relative to when they were opened.
    handleCAYWCallback(makeCallbackData({ requestId: requestB, rawSyntax: '[@bravo]', citekeys: ['bravo'] }), [
      { id: 'bravo', type: 'article' },
    ]);
    handleCAYWCallback(makeCallbackData({ requestId: requestA, rawSyntax: '[@alpha]', citekeys: ['alpha'] }), [
      { id: 'alpha', type: 'article' },
    ]);

    expect(getCAYWDebugState().pendingCAYWRequests).toHaveLength(0);

    const perParagraph = citekeysPerTopLevelNode(view.state.doc);
    // Exactly two top-level paragraphs, each with exactly its own citation —
    // no duplication, no cross-contamination between the two requests.
    expect(perParagraph).toEqual([['alpha'], ['bravo']]);

    const text = view.state.doc.textContent;
    expect(text).not.toContain('/cite');
    expect(text).toContain('First');
    expect(text).toContain('Second');
  });
});
