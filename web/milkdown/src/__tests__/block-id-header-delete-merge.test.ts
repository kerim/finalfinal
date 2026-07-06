// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { Node } from '@milkdown/kit/prose/model';
import { afterEach, describe, expect, it } from 'vitest';
import { blockIdPlugin, getAllBlockIds } from '../block-id-plugin';
import { blockSyncPlugin, flushPendingBlockChanges, getBlockChanges, resetBlockSyncState } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';

// Regression tests for the header-delete-merge outline-sidebar desync bug.
//
// Root cause: block-id-plugin's phase1CanClaim() matched blocks by
// position+type only, with no content check. When a heading+body is deleted,
// the next heading (or its following body paragraph) slides into the deleted
// heading's old offset and — being type-compatible — unconditionally steals
// its block ID. This causes the WRONG DB row to be deleted (the surviving
// block, misattributed) while the actually-deleted heading's row survives,
// misattributed as still present.
//
// These tests exercise the REAL wiring end-to-end: a real Milkdown editor, a
// real transaction deleting a heading (and/or its body), and assert the
// deletion is captured correctly via the real getBlockChanges()/getAllBlockIds()
// surface — not just the underlying phase1CanClaim() comparator in isolation
// (covered separately in block-id-phase1.test.ts).

describe('header-delete-merge: block ID misattribution regression', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
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
      .use(highlightPlugin)
      .use(blockIdPlugin)
      .use(blockSyncPlugin)
      .create();
    return editor;
  }

  /** Map each top-level block's own text content to its currently assigned block ID. */
  function idsByContent(doc: Node): Map<string, string> {
    const ids = getAllBlockIds();
    const map = new Map<string, string>();
    doc.forEach((node, offset) => {
      const id = ids.get(offset);
      if (id) map.set(node.textContent, id);
    });
    return map;
  }

  /** Find a top-level block by its exact text content. Throws if not found. */
  function findBlock(doc: Node, text: string): { pos: number; node: Node } {
    let result: { pos: number; node: Node } | undefined;
    doc.forEach((node, offset) => {
      if (node.textContent === text) result = { pos: offset, node };
    });
    if (!result) {
      throw new Error(`block not found: "${text}"`);
    }
    return result;
  }

  it('(a) same-type shape: heading+body deleted as one unit — Conclusion keeps its own id', async () => {
    const editor = await makeEditor('# Intro\n\nIntro body text.\n\n# Conclusion\n\nConclusion body text.');
    setEditorInstance(editor);

    const view = editor.ctx.get(editorViewCtx);
    const before = idsByContent(view.state.doc);
    const introHeadingId = before.get('Intro');
    const conclusionHeadingId = before.get('Conclusion');
    const conclusionBodyId = before.get('Conclusion body text.');
    expect(introHeadingId).toBeDefined();
    expect(conclusionHeadingId).toBeDefined();
    expect(conclusionBodyId).toBeDefined();
    expect(introHeadingId).not.toBe(conclusionHeadingId);

    // Delete the Intro heading + its body paragraph in one transaction.
    const introHeading = findBlock(view.state.doc, 'Intro');
    const introBody = findBlock(view.state.doc, 'Intro body text.');
    const introBodyEnd = introBody.pos + introBody.node.nodeSize;
    const deleteTr = view.state.tr.delete(introHeading.pos, introBodyEnd);
    view.dispatch(deleteTr);

    // Flush the debounced detectChanges() (block-sync-plugin schedules it via
    // setTimeout(100ms) — flushPendingBlockChanges() runs it synchronously now).
    flushPendingBlockChanges();

    const changes = getBlockChanges();
    expect(changes.deletes).toContain(introHeadingId);
    expect(changes.deletes).not.toContain(conclusionHeadingId);
    expect(changes.updates.some((u) => u.id === conclusionHeadingId)).toBe(false);

    // Conclusion heading must still map to its OWN original id (not a fresh
    // temp id, and not Intro's stolen id) at its new (shifted) offset.
    const idsAfter = getAllBlockIds();
    const conclusionPosAfter = Array.from(idsAfter.entries()).find(([, id]) => id === conclusionHeadingId)?.[0];
    expect(conclusionPosAfter).toBeDefined();
    expect(view.state.doc.nodeAt(conclusionPosAfter!)?.textContent).toBe('Conclusion');

    // Conclusion body paragraph must also still map to its OWN original id
    // (not reassigned, not lost) at its new (shifted) offset.
    const conclusionBodyPosAfter = Array.from(idsAfter.entries()).find(([, id]) => id === conclusionBodyId)?.[0];
    expect(conclusionBodyPosAfter).toBeDefined();
    expect(view.state.doc.nodeAt(conclusionBodyPosAfter!)?.textContent).toBe('Conclusion body text.');
  });

  it('(a-2) cross-type shape: heading deleted alone, its body paragraph left in place — body keeps its own id', async () => {
    // Deliberately NOT "# Intro / Intro body text." — that body text
    // coincidentally starts with the heading's own text ("Intro body text."
    // starts with "Intro"), which would pass meaningfulTextOverlap's
    // prefix check for the wrong reason and mask the very bug this test
    // guards against. Using unrelated heading/body text isolates the check.
    const editor = await makeEditor('# Section One\n\nDetailed content goes here.');
    setEditorInstance(editor);

    const view = editor.ctx.get(editorViewCtx);
    const before = idsByContent(view.state.doc);
    const headingId = before.get('Section One');
    const bodyId = before.get('Detailed content goes here.');
    expect(headingId).toBeDefined();
    expect(bodyId).toBeDefined();
    expect(headingId).not.toBe(bodyId);

    // Delete ONLY the heading node's range — its body paragraph is left in
    // place and slides up into the heading's old offset. This is the shape
    // that actually produces the "silently retyped to paragraph" symptom:
    // shape (a) above only produces same-type misattribution, since real
    // heading content slides in and stays typed heading.
    const heading = findBlock(view.state.doc, 'Section One');
    const deleteTr = view.state.tr.delete(heading.pos, heading.pos + heading.node.nodeSize);
    view.dispatch(deleteTr);

    flushPendingBlockChanges();

    const changes = getBlockChanges();
    expect(changes.deletes).toContain(headingId);
    expect(changes.deletes).not.toContain(bodyId);
    expect(changes.updates.some((u) => u.id === headingId)).toBe(false);

    // The body paragraph must still map to its OWN original id (not the
    // heading's stolen id) at its new (shifted) offset.
    const idsAfter = getAllBlockIds();
    const bodyPosAfter = Array.from(idsAfter.entries()).find(([, id]) => id === bodyId)?.[0];
    expect(bodyPosAfter).toBeDefined();
    const nodeAfter = view.state.doc.nodeAt(bodyPosAfter!);
    expect(nodeAfter?.type.name).toBe('paragraph');
    expect(nodeAfter?.textContent).toBe('Detailed content goes here.');
  });
});
