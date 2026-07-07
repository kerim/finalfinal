// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { afterEach, describe, expect, it } from 'vitest';
import { blockIdPlugin, getAllBlockIds, setBlockIdZoomMode } from '../block-id-plugin';
import { blockSyncPlugin, flushPendingBlockChanges, getBlockChanges, resetBlockSyncState } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';

// Regression tests for the "heading inserted before an already-saved paragraph
// sorts after its own paragraph" export-order bug (docs: cross-cycle leading
// insert, Scenario D of BlockInsertHeadingParagraphOrderTests.swift).
//
// The Swift-side fix anchors a new block before the current first block
// instead of appending it at the end of the document, but ONLY when JS tells
// it the new block is genuinely at ProseMirror document position 0 (no
// afterBlockId at all) AND the editor is not in zoom mode (zoomed inserts
// must never be treated as "document start" — the zoomed view's position 0
// is not the real document's position 0).
//
// These tests exercise the REAL wiring end-to-end: a real Milkdown editor, a
// real transaction inserting a new block, and assert the resulting insert
// payload via the real getBlockChanges() surface — not just a hand-built
// BlockInsert payload (which is all the existing Swift-side test covers).

describe('detectChanges — atDocumentStart flag on position-0 inserts', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
    setBlockIdZoomMode(false);
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

  it('non-zoomed: a new block inserted at document position 0 gets atDocumentStart=true and no afterBlockId', async () => {
    const editor = await makeEditor('Existing paragraph.');
    setEditorInstance(editor);

    const view = editor.ctx.get(editorViewCtx);
    const schema = view.state.schema;

    // Insert a brand-new heading node at the very start of the document —
    // "the user goes back and adds a heading before the paragraph" from
    // Scenario D, modeled as a single real transaction.
    const headingNode = schema.nodes.heading!.create({ level: 2 }, schema.text('New Section'));
    const insertTr = view.state.tr.insert(0, headingNode);
    view.dispatch(insertTr);

    flushPendingBlockChanges();
    const changes = getBlockChanges();

    const headingInsert = changes.inserts.find((i) => i.textContent === 'New Section');
    expect(headingInsert).toBeDefined();
    expect(headingInsert?.blockType).toBe('heading');
    expect(headingInsert?.tempId.startsWith('temp-')).toBe(true);
    expect(headingInsert?.afterBlockId).toBeUndefined();
    expect(headingInsert?.atDocumentStart).toBe(true);

    // The pre-existing paragraph must be unaffected (keeps its own identity,
    // no spurious update/insert/delete) — it merely shifted position.
    expect(changes.inserts.some((i) => i.textContent === 'Existing paragraph.')).toBe(false);
    expect(changes.updates.length).toBe(0);
    expect(changes.deletes.length).toBe(0);
  });

  it('zoomed: the same position-0 insert does NOT get atDocumentStart=true', async () => {
    const editor = await makeEditor('Existing paragraph.');
    setEditorInstance(editor);
    setBlockIdZoomMode(true);

    const view = editor.ctx.get(editorViewCtx);
    const schema = view.state.schema;

    const headingNode = schema.nodes.heading!.create({ level: 2 }, schema.text('New Section'));
    const insertTr = view.state.tr.insert(0, headingNode);
    view.dispatch(insertTr);

    flushPendingBlockChanges();
    const changes = getBlockChanges();

    const headingInsert = changes.inserts.find((i) => i.textContent === 'New Section');
    expect(headingInsert).toBeDefined();
    expect(headingInsert?.afterBlockId).toBeUndefined();
    // The zoom gate must suppress atDocumentStart even though this is still
    // literal ProseMirror position 0 — proving the gate actually works, not
    // just that position-0 detection works.
    expect(headingInsert?.atDocumentStart).toBeFalsy();
  });

  it('a normal non-position-0 insert is unaffected: gets afterBlockId, never atDocumentStart', async () => {
    const editor = await makeEditor('Existing paragraph.');
    setEditorInstance(editor);

    const view = editor.ctx.get(editorViewCtx);
    const idsBefore = getAllBlockIds();
    const existingId = idsBefore.get(0);
    expect(existingId).toBeDefined();

    const schema = view.state.schema;
    const trailingNode = schema.nodes.paragraph!.create({}, schema.text('Trailing paragraph.'));
    const insertTr = view.state.tr.insert(view.state.doc.content.size, trailingNode);
    view.dispatch(insertTr);

    flushPendingBlockChanges();
    const changes = getBlockChanges();

    const trailingInsert = changes.inserts.find((i) => i.textContent === 'Trailing paragraph.');
    expect(trailingInsert).toBeDefined();
    expect(trailingInsert?.afterBlockId).toBe(existingId);
    expect(trailingInsert?.atDocumentStart).toBeFalsy();
  });
});
