// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { setContentWithBlockIds } from '../api-content';
import { blockIdPlugin, getAllBlockIds, getBlockIdZoomMode, setBlockIdZoomMode } from '../block-id-plugin';
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

// Regression tests for the zoom-entry "atDocumentStart" flag race window.
//
// setContentWithBlockIds() unconditionally cleared blockIdZoomMode to false —
// even when the caller was pushing zoomed content (e.g. zoom entry) — and the
// flag only flipped back to true later, via an AWAITED Swift round-trip
// (pushBlockIds()/syncBlockIds()). Between those two points, a position-0
// insert into the zoomed section was misclassified atDocumentStart: true, as
// if it were a true document-start insert.
//
// The fix threads an explicit `zoomMode` option through setContentWithBlockIds
// so zoom-entry callers can flip the flag SYNCHRONOUSLY, in the same call that
// pushes the zoomed content — closing the window instead of narrowing it.
describe('setContentWithBlockIds zoomMode option — closes the zoom-entry atDocumentStart race', () => {
  afterEach(async () => {
    // Safety net, NOT the primary flush: if a test's own assertion throws
    // partway through (e.g. the very first test below is EXPECTED to fail
    // red against unpatched code), any RAF it scheduled via
    // setContentWithBlockIds's deferredSnapshotAndUnpause would otherwise be
    // abandoned mid-flight by vi.useRealTimers() below — leaving syncPaused
    // stuck `true` and leaking into whichever test runs next (since
    // getEditorInstance() is a shared global, not per-test). Flushing here,
    // unconditionally, keeps every test in this file hermetic regardless of
    // how its body exits.
    //
    // Looped, not a single call: setContentWithBlockIds also schedules
    // forceCompositorRepaint's nested rAF-inside-an-rAF chain. A single
    // runOnlyPendingTimersAsync() call only drains timers that were ALREADY
    // pending when it started — the inner rAF that the outer one schedules
    // once it runs is registered mid-flush and survives to the next call.
    // Left pending across the vi.useRealTimers() below, it carried into
    // whichever test ran next and corrupted its own fake-timer flush
    // (confirmed: the two zoomMode-race tests below failed only when run as
    // part of the full suite, not in isolation). Loop until nothing is left.
    if (vi.isFakeTimers()) {
      while (vi.getTimerCount() > 0) {
        await vi.runOnlyPendingTimersAsync();
      }
    }
    vi.useRealTimers();
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

  it('setContentWithBlockIds(..., { zoomMode: true }) flips getBlockIdZoomMode() synchronously — no RAF/timer involved', async () => {
    const editor = await makeEditor('Old unrelated content.');
    setEditorInstance(editor);

    vi.useFakeTimers();

    setContentWithBlockIds('# Zoomed Section\n\nBody text.', ['id-heading', 'id-body'], {
      zoomMode: true,
    });

    expect(getBlockIdZoomMode()).toBe(true);
  });

  it('race: a position-0 insert that lands before the Swift round-trip is NOT misclassified atDocumentStart when zoomMode is supplied synchronously', async () => {
    const editor = await makeEditor('Old unrelated content.');
    setEditorInstance(editor);

    vi.useFakeTimers();

    // Zoom entry: content + block IDs pushed atomically, WITH zoomMode supplied
    // synchronously — simulates the fixed zoomToSection() call site. Deliberately
    // never simulate the follow-up pushBlockIds()/syncBlockIds() Swift round-trip
    // at all, proving correctness no longer depends on its timing.
    setContentWithBlockIds('# Zoomed Section\n\nBody text.', ['id-heading', 'id-body'], {
      zoomMode: true,
      scrollToStart: true,
    });

    // setContentWithBlockIds pauses block-sync change detection (syncPaused)
    // while it settles, then unpauses via a RAF-deferred callback — flush that
    // RAF first so the plugin is actually listening again by the time our own
    // transaction dispatches below (this is NOT the race under test; it's the
    // ordinary "content push has settled" step that precedes it in the real app).
    await vi.runOnlyPendingTimersAsync();

    const view = editor.ctx.get(editorViewCtx);
    const schema = view.state.schema;
    const headingNode = schema.nodes.heading!.create({ level: 2 }, schema.text('New lead heading'));
    const insertTr = view.state.tr.insert(0, headingNode);
    view.dispatch(insertTr);

    // Let the 100ms block-sync detect debounce fire.
    await vi.advanceTimersByTimeAsync(100);

    const changes = getBlockChanges();
    const headingInsert = changes.inserts.find((i) => i.textContent === 'New lead heading');
    expect(headingInsert).toBeDefined();
    expect(headingInsert?.atDocumentStart).toBeFalsy();
  });

  it('regression: zoomMode omitted still clears the flag and produces atDocumentStart=true for a genuine non-zoomed load', async () => {
    const editor = await makeEditor('Old unrelated content.');
    setEditorInstance(editor);

    vi.useFakeTimers();

    // Non-zoomed full-document load — no zoomMode option at all, matching every
    // existing call site untouched by this fix.
    setContentWithBlockIds('Existing paragraph.', ['id-para'], { scrollToStart: true });

    // Flush the RAF-deferred unpause (see comment in the race test above).
    await vi.runOnlyPendingTimersAsync();

    const view = editor.ctx.get(editorViewCtx);
    const schema = view.state.schema;
    const headingNode = schema.nodes.heading!.create({ level: 2 }, schema.text('New Section'));
    const insertTr = view.state.tr.insert(0, headingNode);
    view.dispatch(insertTr);

    await vi.advanceTimersByTimeAsync(100);

    const changes = getBlockChanges();
    const headingInsert = changes.inserts.find((i) => i.textContent === 'New Section');
    expect(headingInsert).toBeDefined();
    expect(headingInsert?.atDocumentStart).toBe(true);
  });
});
