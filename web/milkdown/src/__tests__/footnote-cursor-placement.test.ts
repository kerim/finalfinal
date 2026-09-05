// @vitest-environment jsdom
//
// E1 (Stage E, notes-heading-scanner-unify): tests for `focusFootnoteDefinition` — the new
// id-addressed cursor-placement API that resolves a footnote definition's real DB block id
// via `getAllBlockIds()` before falling back to the pre-existing node-by-label / text-search
// chain (`scrollToFootnoteDefinition`). Companion to
// `../../../codemirror/src/__tests__/footnote-cursor-region.test.ts` — E5's cross-editor
// contract (both editors land the cursor at the START of the definition's own body text for
// the same document/label) is asserted independently in each file, since the two editors live
// in separate packages with separate schemas/environments; see that file's own E5 test for the
// CodeMirror half of the same invariant.
//
// T9 (plan's Test Discipline section): the blank-twin test below seeds the PRE-CALL selection
// INSIDE the blank twin, then does an explicit pre-call/post-call comparison — this is what
// distinguishes "focusFootnoteDefinition did nothing" from "it actually resolved to the real
// row", which a bare "cursor ended up somewhere in the real row" assertion could pass by
// accident if e.g. the blank twin happened to sit at the same offset. See
// block-id-deleted-position-guard.test.ts for this repo's other precedent of pinning a
// same-vs-different-node identity distinction this explicitly.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { blockIdPlugin, getAllBlockIds } from '../block-id-plugin';
import { setEditorInstance } from '../editor-state';
import {
  focusFootnoteDefinition,
  footnotePlugin,
  scrollToFootnoteDefinition,
  selectFootnoteReference,
} from '../footnote-plugin';

describe('focusFootnoteDefinition / scrollToFootnoteDefinition — E1 cursor placement', () => {
  afterEach(() => {
    setEditorInstance(null);
  });

  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const editor = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(commonmark)
      .use(gfm)
      .use(footnotePlugin)
      .use(blockIdPlugin)
      .create();
    return editor;
  }

  /** Finds the top-level block id of the `[^label]:` definition paragraph, the same way a
   *  real caller would (walk descendants for the footnote_def atom, resolve its containing
   *  block's own top-level offset, look that offset up in getAllBlockIds()) — not a
   *  reimplementation of focusFootnoteDefinition's own resolution logic. When `label` appears
   *  more than once (the blank-twin shape), returns every match's block id in document order. */
  function findDefBlockIds(view: EditorView, label: string): string[] {
    const positions: number[] = [];
    view.state.doc.descendants((node, pos) => {
      if (node.type.name === 'footnote_def' && node.attrs.label === label) {
        const $pos = view.state.doc.resolve(pos);
        positions.push($pos.before($pos.depth));
      }
    });
    const blockIds = getAllBlockIds();
    return positions.map((pos) => blockIds.get(pos)).filter((id): id is string => id !== undefined);
  }

  it('places the cursor right after the "[^N]: " prefix inside the correct definition, resolved by block id', async () => {
    const editor = await makeEditor('# Notes\n\n[^1]: first def\n\n[^2]: second def');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const [blockId] = findDefBlockIds(view, '2');
    expect(blockId).toBeDefined();

    focusFootnoteDefinition('2', blockId);

    const $pos = view.state.doc.resolve(view.state.selection.from);
    expect($pos.parent.textContent.trim()).toBe('second def');
    expect($pos.parentOffset).toBe(2); // past the atom (1) + space (1)
  });

  it('E5: lands at the start of the definition body text — the shared cross-editor position contract (see codemirror/src/__tests__/footnote-cursor-region.test.ts)', async () => {
    const editor = await makeEditor('# Notes\n\n[^1]: alpha\n\n[^2]: beta text');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    // Label-only call shape (no blockId) — exercises the pre-existing fallback chain that
    // focusFootnoteDefinition also falls through to.
    scrollToFootnoteDefinition('2');

    const $pos = view.state.doc.resolve(view.state.selection.from);
    expect($pos.parent.textContent.trim()).toBe('beta text');
  });

  it('T9: an absent/stale blockId (not in getAllBlockIds()) falls back to the node-by-label match, not silence', async () => {
    const editor = await makeEditor('# Notes\n\n[^1]: first\n\n[^2]: second def');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    focusFootnoteDefinition('2', 'temp-stale-id-not-in-block-id-map');

    const $pos = view.state.doc.resolve(view.state.selection.from);
    expect($pos.parent.textContent.trim()).toBe('second def');
  });

  it('T9: resolves to the REAL twin via block id — explicit pre-call/post-call comparison seeded inside the BLANK twin', async () => {
    // Two rows both matching label "2": a blank one (document-first) and the real one
    // (document-second) — the exact "blank twin" shape reconcileNotesBlocks's dedup/B5 logic
    // (Swift side) exists to never destroy. Id-addressing must land in the REAL one even
    // though a plain label search alone cannot tell them apart.
    const editor = await makeEditor('# Notes\n\n[^1]: first\n\n[^2]: \n\n[^2]: real text');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const [blankTwinBlockId, realTwinBlockId] = findDefBlockIds(view, '2');
    expect(blankTwinBlockId).toBeDefined();
    expect(realTwinBlockId).toBeDefined();
    expect(blankTwinBlockId).not.toBe(realTwinBlockId);

    // Find the blank twin's own paragraph position to seed the pre-call cursor inside it.
    let blankTwinPos = -1;
    view.state.doc.forEach((_node, offset) => {
      if (blankTwinPos !== -1) return;
      if (getAllBlockIds().get(offset) === blankTwinBlockId) blankTwinPos = offset;
    });
    expect(blankTwinPos).not.toBe(-1);
    const preCallPos = blankTwinPos + 1;
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, preCallPos)));
    expect(view.state.selection.from).toBe(preCallPos);

    focusFootnoteDefinition('2', realTwinBlockId);

    const postCallPos = view.state.selection.from;
    // Explicit pre/post comparison — distinguishes "did nothing" from "resolved to the real
    // row" (a no-op would leave postCallPos === preCallPos, which is itself inside the blank
    // twin and would satisfy a weaker "cursor is somewhere in a [^2] node" assertion).
    expect(postCallPos).not.toBe(preCallPos);
    const $post = view.state.doc.resolve(postCallPos);
    expect($post.before($post.depth)).not.toBe(blankTwinPos);
    expect($post.parent.textContent.trim()).toBe('real text');
  });

  it('NOT_FOUND (no matching label anywhere, no valid blockId) leaves the cursor at its pre-call value', async () => {
    const editor = await makeEditor('# Notes\n\n[^1]: only def');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const preCallPos = 3;
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, preCallPos)));

    focusFootnoteDefinition('99', 'nonexistent-block-id');

    expect(view.state.selection.from).toBe(preCallPos);
  });
});

// Regression test for t-fee9dce6: clicking a footnote's number to return to the main text
// (the reverse of the above — def-to-ref, not ref-to-def) used to place the cursor BEFORE the
// footnote_ref atom instead of after it, because Selection.near(doc.resolve(refPos)) was given
// the position before the atom, which is already a legal text position and so Selection.near
// stopped right there without advancing past the marker. selectFootnoteReference fixes this by
// resolving at refPos + node.nodeSize instead. Covers both call sites that share the helper:
// the footnote_def pill's click handler and footnoteClickPlugin's raw-text safety net.
describe('selectFootnoteReference — ref-return cursor placement (t-fee9dce6)', () => {
  afterEach(() => {
    setEditorInstance(null);
  });

  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const editor = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(commonmark)
      .use(gfm)
      .use(footnotePlugin)
      .create();
    return editor;
  }

  /** Locates the footnote_ref atom's own position and nodeSize the same way a real caller
   *  would (walk descendants), rather than hardcoding the atom's nodeSize. */
  function findRefPosAndSize(view: EditorView, label: string): { pos: number; nodeSize: number } | null {
    let found: { pos: number; nodeSize: number } | null = null;
    view.state.doc.descendants((node, pos) => {
      if (found) return false;
      if (node.type.name === 'footnote_ref' && node.attrs.label === label) {
        found = { pos, nodeSize: node.nodeSize };
        return false;
      }
    });
    return found;
  }

  it('places the caret at refPos + node.nodeSize, immediately after the marker, not before it', async () => {
    const editor = await makeEditor('Body text[^1] tail.\n\n[^1]: the note');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const ref = findRefPosAndSize(view, '1');
    expect(ref).not.toBeNull();

    selectFootnoteReference(view, '1');

    expect(view.state.selection.from).toBe(ref!.pos + ref!.nodeSize);
    // Sanity check that this is genuinely past the marker, not at/before it (the regression).
    expect(view.state.selection.from).toBeGreaterThan(ref!.pos);
  });

  it('a real click on the rendered .ff-footnote-def pill lands the caret in the same place', async () => {
    const editor = await makeEditor('Body text[^1] tail.\n\n[^1]: the note');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const ref = findRefPosAndSize(view, '1');
    expect(ref).not.toBeNull();

    const defEl = view.dom.querySelector('.ff-footnote-def');
    expect(defEl).not.toBeNull();
    defEl!.dispatchEvent(new MouseEvent('click', { bubbles: true }));

    expect(view.state.selection.from).toBe(ref!.pos + ref!.nodeSize);
  });
});
