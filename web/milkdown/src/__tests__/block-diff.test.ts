// @vitest-environment jsdom
// Regression tests for the block-level LCS diff that replaced
// setContentWithBlockIds()'s old unconditional full-document
// tr.replace(0, docSize, ...). That full-document replace corrupted
// prosemirror-history's undo-position-mapping for the ENTIRE document on
// every background resync (bibliography/notes/footnote regeneration, zoom,
// project restore, etc.) — even for content that hadn't actually changed.
// The most visible symptom: deleting a citation, then having a resync land
// ~1s later (before the user pressed Cmd+Z), made undo unable to restore it.
//
// Covers, in order:
//   1. diffTopLevelBlocks() — the pure block-index-range diff.
//   2. buildBlockLevelReplace() — applying that diff to a real transaction.
//   3. The accepted residual-risk pin (content-identical duplicate blocks).
//   4. The actual end-to-end regression: a real Editor, a real citation
//      deletion, a real setContentWithBlockIds() resync, then undo().

import { defaultValueCtx, Editor, editorViewCtx, parserCtx, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { undo } from '@milkdown/kit/prose/history';
import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import { ReplaceStep } from '@milkdown/kit/prose/transform';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import {
  buildBlockLevelReplace,
  diffTopLevelBlocks,
  setContentWithBlockIds,
  topLevelBlockStarts,
} from '../api-content';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { buildCitationDeleteTransaction } from '../citation-delete';
import { citationPlugin } from '../citation-plugin';
import { setEditorInstance } from '../editor-state';

describe('block-level diff for setContentWithBlockIds', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    resetBlockIdState();
    resetBlockSyncState();
    setSyncPaused(false);
  });

  // Mirrors main.ts's real registration order for these plugins: blockIdPlugin
  // before citationPlugin, both before commonmark/gfm, history last. Also
  // registers the editor as the "current" one (setEditorInstance) so the
  // real setContentWithBlockIds() — which reads getEditorInstance() —  works
  // in the end-to-end test below; harmless for the pure-function tests that
  // never call it.
  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(blockIdPlugin)
      .use(citationPlugin)
      .use(commonmark)
      .use(gfm)
      .use(history)
      .create();
    editor = e;
    setEditorInstance(e);
    return e;
  }

  function parseMarkdown(e: Editor, markdown: string): ProsemirrorNode {
    const parser = e.ctx.get(parserCtx);
    const doc = parser(markdown);
    if (!doc) throw new Error(`parse failed for: ${markdown}`);
    return doc;
  }

  function markdownOf(e: Editor): string {
    return e.action(getMarkdown()).replace(/\n+$/, '');
  }

  function citationPositions(doc: ProsemirrorNode): number[] {
    const positions: number[] = [];
    doc.descendants((node, pos) => {
      if (node.type.name === 'citation') positions.push(pos);
    });
    return positions;
  }

  // ---- diffTopLevelBlocks ----

  describe('diffTopLevelBlocks', () => {
    it('a changed block BEFORE and a changed block AFTER an unchanged block produce exactly 2 disjoint ranges', async () => {
      const e = await makeEditor('placeholder paragraph');
      const oldDoc = parseMarkdown(
        e,
        'Intro paragraph mentions ref one here.\n\nSee stays the same right here.\n\nBibliography old line.'
      );
      const newDoc = parseMarkdown(
        e,
        'Intro paragraph mentions ref ONE-UPDATED here.\n\nSee stays the same right here.\n\nNew bibliography line, regenerated.'
      );

      const ranges = diffTopLevelBlocks(oldDoc, newDoc);

      // This is the whole point of the fix: a single range spanning
      // [0,3) would sweep the untouched middle paragraph in unnecessarily
      // (== the pre-fix full-document-replace behavior, scoped down). Two
      // disjoint ranges proves the middle block's identity/position is left
      // alone.
      expect(ranges).toHaveLength(2);
      expect(ranges[0]).toEqual({ oldFrom: 0, oldTo: 1, newFrom: 0, newTo: 1 });
      expect(ranges[1]).toEqual({ oldFrom: 2, oldTo: 3, newFrom: 2, newTo: 3 });
    });

    it('a block inserted mid-document produces a single pure-insert range', async () => {
      const e = await makeEditor('placeholder paragraph');
      const oldDoc = parseMarkdown(e, 'First.\n\nThird.');
      const newDoc = parseMarkdown(e, 'First.\n\nSecond (inserted).\n\nThird.');

      const ranges = diffTopLevelBlocks(oldDoc, newDoc);

      expect(ranges).toEqual([{ oldFrom: 1, oldTo: 1, newFrom: 1, newTo: 2 }]);
    });

    it('a block deleted mid-document produces a single pure-delete range', async () => {
      const e = await makeEditor('placeholder paragraph');
      const oldDoc = parseMarkdown(e, 'First.\n\nSecond (to delete).\n\nThird.');
      const newDoc = parseMarkdown(e, 'First.\n\nThird.');

      const ranges = diffTopLevelBlocks(oldDoc, newDoc);

      expect(ranges).toEqual([{ oldFrom: 1, oldTo: 2, newFrom: 1, newTo: 1 }]);
    });

    it('fully identical top-level blocks produce zero ranges', async () => {
      const e = await makeEditor('placeholder paragraph');
      const markdown = 'Only one paragraph here, unchanged.';
      // Independently parsed (distinct Node instances), but content-identical —
      // exercises Node.eq() structural comparison, not reference equality.
      const oldDoc = parseMarkdown(e, markdown);
      const newDoc = parseMarkdown(e, markdown);

      expect(diffTopLevelBlocks(oldDoc, newDoc)).toEqual([]);
    });

    it('fully different top-level blocks produce a single range spanning everything', async () => {
      const e = await makeEditor('placeholder paragraph');
      const oldDoc = parseMarkdown(e, 'Alpha content here.');
      const newDoc = parseMarkdown(e, 'Completely different Zeta content.');

      const ranges = diffTopLevelBlocks(oldDoc, newDoc);

      expect(ranges).toEqual([{ oldFrom: 0, oldTo: 1, newFrom: 0, newTo: 1 }]);
    });
  });

  // ---- buildBlockLevelReplace ----

  describe('buildBlockLevelReplace', () => {
    it('disjoint two-region case: resulting tr.doc is deep-equal to newDoc', async () => {
      const e = await makeEditor(
        'Intro paragraph mentions ref one here.\n\nSee stays the same right here.\n\nBibliography old line.'
      );
      const view = e.ctx.get(editorViewCtx);
      const oldDoc = view.state.doc;
      const newDoc = parseMarkdown(
        e,
        'Intro paragraph mentions ref ONE-UPDATED here.\n\nSee stays the same right here.\n\nNew bibliography line, regenerated.'
      );

      const tr = buildBlockLevelReplace(view.state.tr, oldDoc, newDoc);

      expect(tr.doc.eq(newDoc)).toBe(true);
    });

    it('insert case: resulting tr.doc is deep-equal to newDoc', async () => {
      const e = await makeEditor('First.\n\nThird.');
      const view = e.ctx.get(editorViewCtx);
      const newDoc = parseMarkdown(e, 'First.\n\nSecond (inserted).\n\nThird.');

      const tr = buildBlockLevelReplace(view.state.tr, view.state.doc, newDoc);

      expect(tr.doc.eq(newDoc)).toBe(true);
    });

    it('delete case: resulting tr.doc is deep-equal to newDoc', async () => {
      const e = await makeEditor('First.\n\nSecond (to delete).\n\nThird.');
      const view = e.ctx.get(editorViewCtx);
      const newDoc = parseMarkdown(e, 'First.\n\nThird.');

      const tr = buildBlockLevelReplace(view.state.tr, view.state.doc, newDoc);

      expect(tr.doc.eq(newDoc)).toBe(true);
    });

    it('fully identical case: zero steps, tr.doc still deep-equal to newDoc', async () => {
      const e = await makeEditor('Only one paragraph here, unchanged.');
      const view = e.ctx.get(editorViewCtx);
      const newDoc = parseMarkdown(e, 'Only one paragraph here, unchanged.');

      const tr = buildBlockLevelReplace(view.state.tr, view.state.doc, newDoc);

      expect(tr.steps.length).toBe(0);
      expect(tr.doc.eq(newDoc)).toBe(true);
    });

    it('fully different case: resulting tr.doc is deep-equal to newDoc', async () => {
      const e = await makeEditor('Alpha content here.');
      const view = e.ctx.get(editorViewCtx);
      const newDoc = parseMarkdown(e, 'Completely different Zeta content.');

      const tr = buildBlockLevelReplace(view.state.tr, view.state.doc, newDoc);

      expect(tr.doc.eq(newDoc)).toBe(true);
    });

    it('disjoint two-region case: an interior position of the untouched middle block is never swallowed by any step', async () => {
      const e = await makeEditor(
        'Intro paragraph mentions ref one here.\n\nSee stays the same right here.\n\nBibliography old line.'
      );
      const view = e.ctx.get(editorViewCtx);
      const oldDoc = view.state.doc;
      const newDoc = parseMarkdown(
        e,
        'Intro paragraph mentions ref ONE-UPDATED here.\n\nSee stays the same right here.\n\nNew bibliography line, regenerated.'
      );

      const oldStarts = topLevelBlockStarts(oldDoc);
      // A position squarely inside the second (untouched) top-level block's text
      // ("See stays the same right here.") — not at either boundary.
      const untouchedInteriorPos = oldStarts[1] + 5;

      const tr = buildBlockLevelReplace(view.state.tr, oldDoc, newDoc);
      expect(tr.steps.length).toBe(2); // sanity: exactly the 2 disjoint ranges, each its own step

      // Walk the position through each step's own map in order — at the time
      // step i is checked, `pos` is already expressed in the coordinate space
      // step i's own from/to were defined in (mapped through every prior
      // step), so this is a faithful "was this position ever inside a
      // replaced range" check, not just a before/after snapshot comparison.
      let pos = untouchedInteriorPos;
      for (const step of tr.steps) {
        if (step instanceof ReplaceStep) {
          expect(pos > step.from && pos < step.to).toBe(false);
        }
        pos = step.getMap().map(pos);
      }
    });
  });

  // ---- Accepted residual risk: content-identical duplicate blocks ----

  describe('accepted residual risk: content-identical duplicate blocks', () => {
    it('pins current deterministic (but arbitrary-occurrence) behavior: 4 identical blocks collapsing to 3 sweeps exactly one block, never the whole run', async () => {
      const e = await makeEditor('placeholder paragraph');
      const dup = 'See [@samekey] for details.';
      const oldDoc = parseMarkdown(e, [dup, dup, dup, dup].join('\n\n'));
      const newDoc = parseMarkdown(e, [dup, dup, dup].join('\n\n'));

      const ranges = diffTopLevelBlocks(oldDoc, newDoc);

      // With 4 content-identical blocks collapsing to 3, there is no way to
      // know from content alone which specific occurrence a stale undo
      // position pointed at — every occurrence is an equally valid LCS
      // match (see diffTopLevelBlocks's doc comment on this exact scenario).
      // This test does NOT claim the resulting range below is "correct" —
      // there is no correct answer here. It pins the CURRENT algorithm's
      // deterministic tie-break (prefix-trim walks left-to-right and
      // greedily matches the first 3 occurrences, leaving the trailing 4th
      // swept into a change range) so a future change to the algorithm
      // can't silently regress into sweeping in MORE blocks than necessary
      // (e.g. all 4, which would reproduce the pre-fix "whole region"
      // behavior for this case).
      expect(ranges).toEqual([{ oldFrom: 3, oldTo: 4, newFrom: 3, newTo: 3 }]);
    });
  });

  // ---- End-to-end regression: the actual bug this fix addresses ----

  describe('end-to-end: citation-delete undo survives a real setContentWithBlockIds resync', () => {
    it('undo restores the citation, keeps the resynced paragraphs, and leaves the selection away from document end', async () => {
      const e = await makeEditor(
        'Intro paragraph mentions ref one here.\n\nSee [@smith2023] for details.\n\nBibliography old line.'
      );
      const view = e.ctx.get(editorViewCtx);

      // 1) User deletes the citation — a real, tracked (addToHistory: true,
      // the default) transaction via the same builder the Backspace/Delete
      // keymap and the popup's Delete button both use.
      const [citPos] = citationPositions(view.state.doc);
      expect(citPos).toBeDefined();
      const delTr = buildCitationDeleteTransaction(view.state, citPos);
      expect(delTr).not.toBeNull();
      view.dispatch(delTr!);
      expect(markdownOf(e)).toBe(
        'Intro paragraph mentions ref one here.\n\nSee for details.\n\nBibliography old line.'
      );

      // 2) ~1s later: a background resync fires (e.g. bibliography
      // regeneration) via the REAL setContentWithBlockIds — changing the
      // paragraph BEFORE the citation's paragraph AND the one AFTER it,
      // while the citation's own paragraph ("See for details." — already
      // edited by step 1) is untouched by the resync's target content.
      setContentWithBlockIds(
        'Intro paragraph mentions ref ONE-UPDATED here.\n\nSee for details.\n\nNew bibliography line, regenerated.',
        []
      );
      expect(markdownOf(e)).toBe(
        'Intro paragraph mentions ref ONE-UPDATED here.\n\nSee for details.\n\nNew bibliography line, regenerated.'
      );

      // 3) User presses Cmd+Z.
      const undone = undo(view.state, view.dispatch);

      expect(undone).toBe(true);
      const md = markdownOf(e);
      expect(md).toContain('smith2023'); // citation restored
      expect(md).toContain('ONE-UPDATED'); // resynced intro paragraph NOT reverted
      expect(md).toContain('New bibliography line, regenerated.'); // resynced bib paragraph NOT reverted

      // Selection must land within the first two paragraphs (near the
      // restored citation), never swept to/near document end — the exact
      // symptom of the pre-fix full-document-replace bug (every stale
      // position collapsing to the boundary of the one giant replaced
      // range).
      const starts = topLevelBlockStarts(view.state.doc);
      const thirdParagraphStart = starts[2];
      expect(view.state.selection.from).toBeLessThan(thirdParagraphStart);
    });
  });
});
