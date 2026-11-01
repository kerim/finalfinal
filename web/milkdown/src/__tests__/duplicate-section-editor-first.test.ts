// @vitest-environment jsdom
//
// Phase 4b slice 3, round 1d (t-18b7fa48): `duplicateSectionEditorFirst` and `redoSectionDuplicateEditorFirst`
// (api-section-duplicate.ts) -- the editor inserts a section's copy first, in one synchronous JavaScript turn, with a fresh
// PERMANENT id per copied block, and hands Swift the batch of pending edits it consumed. The quick undo of a duplicate is the
// generic `undoSectionDeleteEditorFirst` (api-section-undo.ts); its reply names the leaders it removed (`removedLeaderIds`, [S4]).
//
// V1-1 copies get permanent ids and typing in a copy is an UPDATE of its id (plan D4), V1-2 " copy" only when the root node is a
// heading (S3), V1-3 the quick undo gives back the exact pre-op document and reports the copy leaders it removed (S4), V1-4 the quick
// redo gives the SAME copy ids (S9). The rest pin what the reply carries and what a refusal or a failure leaves behind.
//
// The harness (editor-first-harness.ts) is the real thing: a real Milkdown editor with the block-id, block-sync and history plugins,
// `view.dispatch` wired through the production `runUndoTrackedDispatch`. Swift's side of the conversation is played by the test.

import { afterEach, describe, expect, it } from 'vitest';
import { confirmBlockIdsApi, getBlockChangesApi } from '../api-content';
import { deleteSectionEditorFirst } from '../api-section-delete';
import {
  type DuplicateSectionResult,
  duplicateSectionEditorFirst,
  redoSectionDuplicateEditorFirst,
  setTestAfterInsertHook,
} from '../api-section-duplicate';
import { undoSectionDeleteEditorFirst } from '../api-section-undo';
import { isTempBlockId } from '../block-id-plugin';
import { flushPendingBlockChanges } from '../block-sync-plugin';
import { imagePlugin } from '../image-plugin';
import { getRegistry } from '../undo-coordinator';
import {
  automaticRewrite,
  EMPTY_BATCH,
  heading,
  idsInOrder,
  load,
  makeEditor,
  para,
  pressRedo,
  pressUndo,
  sectionBreak,
  sleep,
  swiftFinishesRedo,
  swiftFinishesUndo,
  typeInto,
  typeIntoNth,
} from './editor-first-harness';

const OP = 'dddddddd-2222-3333-4444-555555555555';
const OP_2 = 'eeeeeeee-2222-3333-4444-555555555555';

const DOC = [
  heading('h1', 1, 'Chapter'),
  para('p1', 'Chapter body.'),
  heading('a', 2, 'Section A'),
  para('pa', 'A body.'),
  heading('b', 2, 'Section B'),
  para('pb', 'B body.'),
];

afterEach(() => {
  setTestAfterInsertHook(null);
});

describe('duplicateSectionEditorFirst', () => {
  it('V1-1: copies get permanent ids, and typing in a copy is an UPDATE of its id, never an insert', async () => {
    const { view } = await makeEditor();
    await load(DOC);

    const r = duplicateSectionEditorFirst(OP, idsInOrder()[2], []);

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.copies.length).toBe(2);
    for (const c of r.copies) expect(isTempBlockId(c.newId), `${c.newId} must be a permanent id`).toBe(false);
    expect(idsInOrder(), 'the copy sits after the original; every other block keeps its id').toEqual([
      'h1',
      'p1',
      'a',
      'pa',
      r.copies[0].newId,
      r.copies[1].newId,
      'b',
      'pb',
    ]);
    // The copy was re-baselined: the duplicate itself queues nothing, not even after block-sync's own debounce has run.
    await sleep(160);
    expect(getBlockChangesApi(), 'the copies are never reported as inserts').toEqual(EMPTY_BATCH);

    typeIntoNth(view, 'A body.', 1, ' typed'); // paragraph #1 starting "A body." is the COPY
    flushPendingBlockChanges();
    const diff = getBlockChangesApi();
    expect(diff.inserts, 'typing in a copy is not an insert').toEqual([]);
    expect(diff.deletes).toEqual([]);
    expect(diff.updates.map((u) => u.id)).toEqual([r.copies[1].newId]);
    expect(diff.updates[0].textContent).toBe('A body. typed');
  });

  it('V1-2: " copy" is appended only when the root node itself is a heading (S3)', async () => {
    const { view } = await makeEditor();
    await load([para('p0', 'Lead.'), sectionBreak('sb'), heading('x', 2, 'Inner'), para('px', 'X.')]);

    const r = duplicateSectionEditorFirst(OP, idsInOrder()[1], []);

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(
      view.state.doc.textContent,
      'a section break has no title to suffix, and the heading under it is not the root'
    ).not.toContain('copy');
    expect(view.state.doc.textContent.split('Inner').length - 1, 'the heading under the break exists twice').toBe(2);
    expect(r.copies.length).toBe(3);
    expect(r.insertedSectionsSnapshot).toEqual([
      { id: r.copies[0].newId, kind: 'section_break', level: 1, title: '' },
      { id: r.copies[1].newId, kind: 'heading', level: 2, title: 'Inner' },
    ]);
  });

  it('V1-2b: a heading root gets " copy"; headings under it are copied unchanged', async () => {
    const { view } = await makeEditor();
    await load([
      heading('c', 1, 'Chapter'),
      para('cp', 'Chapter text.'),
      heading('c1', 2, 'Sub'),
      para('c1p', 'Sub text.'),
      heading('d', 1, 'Next'),
    ]);

    const r = duplicateSectionEditorFirst(OP, 'c', []);

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    const texts: string[] = [];
    view.state.doc.forEach((node) => {
      texts.push(node.textContent);
    });
    expect(texts, 'the SUBTREE is copied (the sub-section too) and sits directly after the original subtree').toEqual([
      'Chapter',
      'Chapter text.',
      'Sub',
      'Sub text.',
      'Chapter copy',
      'Chapter text.',
      'Sub',
      'Sub text.',
      'Next',
    ]);
    expect(r.insertedSectionsSnapshot.map((s) => [s.level, s.title])).toEqual([
      [1, 'Chapter copy'],
      [2, 'Sub'],
    ]);
  });

  it('V1-3: the quick undo gives back the exact pre-op document and reports the copy leaders it removed (S4)', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const before = view.state.doc;
    const r = duplicateSectionEditorFirst(OP, idsInOrder()[2], []);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);

    expect(pressUndo(view, OP), 'Cmd-Z routes to the duplicate').toBe(true);
    const u = undoSectionDeleteEditorFirst(OP);

    expect(u.ok, `reason: ${u.reason}`).toBe(true);
    expect(view.state.doc.eq(before), 'the exact pre-op document is back').toBe(true);
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    expect(
      u.removedLeaderIds,
      'the copy leader the undo took out, so Swift can hide it from the sidebar at once'
    ).toEqual([r.copies[0].newId]);
    expect(u.restoredIds, 'the undo of a duplicate restores nothing').toEqual([]);
    expect(u.restoredLeaderIds).toEqual([]);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
  });

  it('V1-3b: the undo of a delete reports no removed leaders (delete behaviour unchanged)', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    expect(deleteSectionEditorFirst(OP, 'a', []).ok).toBe(true);

    expect(pressUndo(view, OP)).toBe(true);
    const u = undoSectionDeleteEditorFirst(OP);

    expect(u.ok, `reason: ${u.reason}`).toBe(true);
    expect(u.removedLeaderIds).toEqual([]);
    expect(u.restoredLeaderIds).toEqual(['a']);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
  });

  it('V1-4: the quick redo gives the SAME copy ids as the first click (S9), and typing in the redone copy is an update of them', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `reason: ${first.reason}`).toBe(true);
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    getBlockChangesApi();

    expect(pressRedo(view, OP), 'Cmd-Shift-Z routes to the undone duplicate').toBe(true);
    const redo = redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies);

    expect(redo.ok, `reason: ${redo.reason}`).toBe(true);
    expect(
      redo.copies.map((c) => c.newId),
      'the redo reuses the ids of the first click'
    ).toEqual(first.copies.map((c) => c.newId));
    expect(idsInOrder()).toEqual(['h1', 'p1', 'a', 'pa', ...first.copies.map((c) => c.newId), 'b', 'pb']);
    expect(redo.insertedLeaderIds).toEqual([first.copies[0].newId]);
    swiftFinishesRedo(OP, { undoTopOpId: OP });

    typeIntoNth(view, 'A body.', 1, ' typed');
    flushPendingBlockChanges();
    const diff = getBlockChangesApi();
    expect(diff.inserts).toEqual([]);
    expect(diff.updates.map((u) => u.id)).toEqual([first.copies[1].newId]);
  });

  it('V1-4c: after the redo, the next Cmd-Z undoes the redone duplicate and takes the same copy out again', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const before = view.state.doc;
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    expect(pressRedo(view, OP)).toBe(true);
    expect(redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies).ok).toBe(true);
    swiftFinishesRedo(OP, { undoTopOpId: OP });

    expect(pressUndo(view, OP), 'the redone duplicate is the newest registry entry and routes').toBe(true);
    const second = undoSectionDeleteEditorFirst(OP);

    expect(second.ok, `reason: ${second.reason}`).toBe(true);
    expect(second.removedLeaderIds).toEqual([first.copies[0].newId]);
    expect(view.state.doc.eq(before)).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
  });

  it("V1-4b: without the first click's copies the redo mints fresh ids (the default the Swift side must not rely on)", async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    expect(pressRedo(view, OP)).toBe(true);

    const redo = redoSectionDuplicateEditorFirst(OP, 'a', []);

    expect(redo.ok, `reason: ${redo.reason}`).toBe(true);
    expect(redo.copies.map((c) => c.newId)).not.toEqual(first.copies.map((c) => c.newId));
    for (const c of redo.copies) expect(isTempBlockId(c.newId)).toBe(false);
    swiftFinishesRedo(OP, { undoTopOpId: OP });
  });

  it('V1-5: the reply names the copies in document order, the copied leaders, and the block the copy sits after', async () => {
    const { view } = await makeEditor();
    await load([
      heading('c', 1, 'Chapter'),
      para('cp', 'Chapter text.'),
      heading('c1', 2, 'Sub'),
      para('c1p', 'Sub text.'),
    ]);
    typeInto(view, 'Sub text', ' (pending)'); // an edit not yet polled when the click arrives

    const r = duplicateSectionEditorFirst(OP, 'c', []);

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.copies.map((c) => c.sourceId)).toEqual(['c', 'cp', 'c1', 'c1p']);
    expect(r.insertedLeaderIds).toEqual([r.copies[0].newId, r.copies[2].newId]);
    expect(r.predecessorId, 'the copy sits directly after the last block of the original section').toBe('c1p');
    expect(
      r.batch.updates.map((u) => u.id),
      'the edit pending before the click is the batch Swift applies BEFORE the duplicate job'
    ).toEqual(['c1p']);
    expect(r.batch.updates[0].textContent).toBe('Sub text. (pending)');
    expect(r.batch.inserts).toEqual([]);
    expect(r.batch.deletes).toEqual([]);
    // The copy carries the pending text too (the editor is the truth), and the batch is consumed, not queued a second time.
    expect(view.state.doc.textContent.split('Sub text. (pending)').length - 1).toBe(2);
    await sleep(160);
    expect(getBlockChangesApi()).toEqual(EMPTY_BATCH);
  });

  it('V1-6: a managed root is refused: nothing dispatched, no registry entry left, block-sync running', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const before = view.state.doc;
    typeInto(view, 'B body', ' (pending)');

    const r = duplicateSectionEditorFirst(OP, 'b', ['b', 'pb']);

    expect(r.ok).toBe(false);
    expect(r.reason).toBe('managedRoot');
    expect(r.copies).toEqual([]);
    expect(r.insertedLeaderIds).toEqual([]);
    expect(r.insertedSectionsSnapshot).toEqual([]);
    expect(r.predecessorId).toBeNull();
    expect(
      r.batch.updates.map((u) => u.id),
      'a refusal still returns the batch it consumed'
    ).toEqual(['pb']);
    expect(view.state.doc.textContent).toBe(`${before.textContent} (pending)`);
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    expect(getRegistry().has(OP), 'no registry entry is left behind').toBe(false);
    // Block-sync is running: the next edit is recorded.
    typeInto(view, 'Chapter body', ' more');
    flushPendingBlockChanges();
    expect(getBlockChangesApi().updates.map((u) => u.id)).toEqual(['p1']);
  });

  it('V1-6b: an unknown root and a root that is not a section leader are refused', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const before = view.state.doc;

    expect(duplicateSectionEditorFirst(OP, 'nope', []).reason).toBe('rootNotFound');
    expect(duplicateSectionEditorFirst(OP, 'pa', []).reason).toBe('rootNotLeader');

    expect(view.state.doc.eq(before)).toBe(true);
    expect(getRegistry().has(OP)).toBe(false);
  });

  it('V1-7: the insertion is ONE transaction, tagged, and not added to the text history', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const seen: Array<{ structuralDuplicate: unknown; addToHistory: unknown; steps: number }> = [];
    const dispatch = view.dispatch;
    view.dispatch = (tr) => {
      if (tr.docChanged) {
        seen.push({
          structuralDuplicate: tr.getMeta('structuralDuplicate'),
          addToHistory: tr.getMeta('addToHistory'),
          steps: tr.steps.length,
        });
      }
      dispatch(tr);
    };

    duplicateSectionEditorFirst(OP, 'a', []);

    expect(seen[0], 'the first document change is the one tagged insertion, kept out of the text history').toEqual({
      structuralDuplicate: true,
      addToHistory: false,
      steps: 1,
    });
    // Anything after it is Milkdown's own heading-id correction for the suffixed heading (preset-commonmark `syncHeadingIdPlugin`):
    // an automatic rewrite, also kept out of the text history.
    expect(seen.slice(1).every((t) => t.addToHistory === false && t.structuralDuplicate === undefined)).toBe(true);
  });

  it('V1-8: the copies paint their permanent ids in the DOM, never a temp id', async () => {
    const { view } = await makeEditor();
    await load(DOC);

    const r = duplicateSectionEditorFirst(OP, 'a', []);

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    const painted = Array.from(view.dom.querySelectorAll('[data-block-id]')).map((el) =>
      el.getAttribute('data-block-id')
    );
    expect(painted, 'the decorations were recomputed after the ids were replaced').toEqual(idsInOrder());
    expect(painted.some((id) => id?.startsWith('temp-'))).toBe(false);
  });

  it('V1-9: a throw after the insertion puts the document, the ids and block-sync back, and the reply still carries the batch', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    typeInto(view, 'B body', ' (pending)');
    const docBefore = view.state.doc;
    setTestAfterInsertHook(() => {
      throw new Error('injected failure after the insertion');
    });

    const r = duplicateSectionEditorFirst(OP, 'a', []);

    expect(r.ok).toBe(false);
    expect(r.reason).toContain('injected failure after the insertion');
    expect(r.copies).toEqual([]);
    expect(
      r.batch.updates.map((u) => u.id),
      'the batch the call consumed is returned'
    ).toEqual(['pb']);
    expect(view.state.doc.eq(docBefore), 'the document is as it was').toBe(true);
    expect(idsInOrder(), 'and so are the block ids').toEqual(DOC.map((s) => s.name));
    expect(getRegistry().has(OP), 'no registry entry is left behind').toBe(false);
    setTestAfterInsertHook(null);
    // Block-sync runs against the restored document: an edit is exactly one update of the ORIGINAL block.
    typeInto(view, 'A body', ' after');
    flushPendingBlockChanges();
    const diff = getBlockChangesApi();
    expect(diff.updates.map((u) => u.id)).toEqual(['pa']);
    expect(diff.inserts).toEqual([]);
    expect(diff.deletes).toEqual([]);
  });

  // Round 3 (Q2): a Duplicate takes nothing out of the document, so typing since the redo's press can never go with anything and the
  // redo is not refused for it (it was refused for ANY typing before): the copy comes back and the typing is kept.
  it("V1-10: typing in the redo's wait does not refuse it (a duplicate removes nothing): the copy comes back, the typing is kept and goes out once", async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    const idsAfterFirst = idsInOrder();
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    await sleep(160);
    getBlockChangesApi();
    expect(pressRedo(view, OP), 'routed structurally: the document equalled the saved copy at the press').toBe(true);
    typeInto(view, 'B body', ' typed after the press'); // ... and the user types before the redo's turn

    const redo = redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies);

    expect(redo.ok, `reason: ${redo.reason}`).toBe(true);
    expect(idsInOrder(), 'the copy has the ids of the first click again').toEqual(idsAfterFirst);
    expect(view.state.doc.textContent.split('typed after the press').length - 1, 'the typing is there once').toBe(1);
    const sent = [...redo.batch.updates];
    swiftFinishesRedo(OP, { undoTopOpId: OP });
    await sleep(160);
    sent.push(...getBlockChangesApi().updates);
    expect(
      sent.filter((u) => u.id === 'pb').map((u) => u.textContent),
      'the typing went out once, in the reply or the next poll'
    ).toEqual(['B body. typed after the press']);
  });

  it("V1-11: a copied figure carries its OWN id on the node and on the DOM, never the source figure's", async () => {
    const { view } = await makeEditor([imagePlugin]);
    await load([
      heading('f', 1, 'Pictures'),
      para('fp', 'Look.'),
      { name: 'fig', md: '![cap](media/photo.png)' },
      heading('g', 1, 'After'),
    ]);

    const r = duplicateSectionEditorFirst(OP, 'f', []);

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.copies.map((c) => c.sourceId)).toEqual(['f', 'fp', 'fig']);
    const figureIds: string[] = [];
    view.state.doc.forEach((node) => {
      if (node.type.name === 'figure') figureIds.push(node.attrs.blockId);
    });
    expect(figureIds).toEqual(['fig', r.copies[2].newId]);
    const painted = Array.from(view.dom.querySelectorAll('[data-block-id]')).map((el) =>
      el.getAttribute('data-block-id')
    );
    expect(painted).toEqual(idsInOrder());
  });

  it('V1-12: two duplicates in a row each get their own ids, and the second one is undone first', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const one = duplicateSectionEditorFirst(OP, 'a', []);
    const two = duplicateSectionEditorFirst(OP_2, 'b', []);
    expect(one.ok && two.ok).toBe(true);
    const all = [...one.copies, ...two.copies].map((c) => c.newId);
    expect(new Set(all).size, 'all ids are distinct').toBe(4);

    expect(pressUndo(view, OP_2, {})).toBe(true);
    const u = undoSectionDeleteEditorFirst(OP_2);

    expect(u.ok, `reason: ${u.reason}`).toBe(true);
    expect(u.removedLeaderIds).toEqual([two.copies[0].newId]);
    expect(idsInOrder()).toEqual(['h1', 'p1', 'a', 'pa', ...one.copies.map((c) => c.newId), 'b', 'pb']);
    swiftFinishesUndo(OP_2, { undoTopOpId: OP, redoTopOpId: OP_2 });
  });

  // === Round 1g-C, review A9: an older delete, then a duplicate, then the automatic rewrite of a footnote renumber ===

  const OP_A = 'aaaaaaaa-2222-3333-4444-555555555555';
  const OP_C = 'cccccccc-2222-3333-4444-555555555555';

  /** The common tail of both variants: Cmd-Z twice, each one routed structurally and answered `ok`; the document ends as it was
   * before the delete. Swift's side between the two presses is `swiftFinishesUndo` (resume, descriptor, reply). */
  function expectTwoStructuralUndos(view: Parameters<typeof pressUndo>[0]): void {
    expect(pressUndo(view, OP_C, {}), 'the first Cmd-Z routes to the duplicate').toBe(true);
    const undoDuplicate = undoSectionDeleteEditorFirst(OP_C);
    expect(undoDuplicate.ok, `the duplicate's undo: reason ${undoDuplicate.reason}`).toBe(true);
    expect(undoDuplicate.removedLeaderIds, 'the copy leader the undo took out').toHaveLength(1);
    expect(idsInOrder(), 'the copy is gone; section A is still deleted').toEqual(['h1', 'p1', 'b', 'pb']);
    swiftFinishesUndo(OP_C, { undoTopOpId: OP_A, redoTopOpId: OP_C });

    expect(pressUndo(view, OP_A, { redoTopOpId: OP_C }), 'the second Cmd-Z routes to the delete').toBe(true);
    const undoDelete = undoSectionDeleteEditorFirst(OP_A);
    expect(undoDelete.ok, `the delete's undo: reason ${undoDelete.reason}`).toBe(true);
    expect(undoDelete.restoredLeaderIds).toEqual(['a']);
    expect(idsInOrder(), 'section A is back, in its place, under its own ids').toEqual(DOC.map((s) => s.name));
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
  }

  it('V1-14a: delete A, a footnote-renumber-like rewrite, duplicate B: both Cmd-Z route structurally and succeed', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    expect(deleteSectionEditorFirst(OP_A, 'a', []).ok).toBe(true);
    // The rewrite lands BETWEEN the delete and the duplicate: automatic (not in the text history), absorbed into the delete's entry.
    automaticRewrite(view, 'B body', ' [r]');
    expect(view.state.doc.textContent).toContain('B body. [r]');

    const dup = duplicateSectionEditorFirst(OP_C, 'b', []);
    expect(dup.ok, `reason: ${dup.reason}`).toBe(true);
    expect(view.state.doc.textContent.split('B body. [r]').length - 1, 'the copy carries the rewritten text').toBe(2);

    expectTwoStructuralUndos(view);
  });

  it('V1-14b: delete A, duplicate B, then the rewrite lands AFTER the duplicate: both Cmd-Z route structurally and succeed', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    expect(deleteSectionEditorFirst(OP_A, 'a', []).ok).toBe(true);
    const dup = duplicateSectionEditorFirst(OP_C, 'b', []);
    expect(dup.ok, `reason: ${dup.reason}`).toBe(true);
    // The rewrite lands after the duplicate (the original section B's paragraph, the first one starting "B body").
    automaticRewrite(view, 'B body', ' [r]');
    expect(view.state.doc.textContent).toContain('B body. [r]');

    expectTwoStructuralUndos(view);
  });

  // === Round 1g-C, review T2 (the proof of A2): a REAL reply of the web function, kept as a file Swift reads ===
  //
  // The document is a section with a tight list, a loose list (two database rows that the editor shows as ONE list node), a figure
  // and an empty paragraph the editor holds a confirmed id for (Enter pressed, the row inserted, the id confirmed). The reply the
  // production function gives for it is compared with `fixtures/duplicate-section-reply.json` (vitest's file snapshot: a changed
  // reply FAILS this test until the file is regenerated with `pnpm vitest run -u`, so the file cannot go stale). The Swift test
  // `DuplicateSectionsEditorCopiesTests.testARealWebReplyGivesEveryEditorCopyItsRow` feeds the same file to
  // `ProjectDatabase.duplicateSections(db:rootId:projectId:copies:)` on a database holding the described rows.
  it('V1-13: the real reply for a section with lists, a figure and an empty paragraph is the committed fixture Swift reads', async () => {
    const { view } = await makeEditor([imagePlugin]);
    const specs = [
      heading('sx', 2, 'Section X'),
      para('sx-intro', 'Intro paragraph.'),
      { name: 'sx-tight', md: '- tight one\n- tight two' },
      para('sx-gap-1', 'Between the lists.'),
      { name: 'sx-loose', md: '- loose one\n\n- loose two' },
      para('sx-gap-2', 'After the loose list.'),
      { name: 'sx-fig', md: '![cap](media/photo.png)' },
      para('sx-last', 'Last paragraph of X.'),
      heading('sy', 2, 'Section Y'),
      para('sy-p', 'Y body.'),
    ];
    await load(specs);
    // The empty paragraph: inserted before "Last paragraph of X." the way pressing Enter does, reported as an insert under a temp
    // id, and confirmed by Swift under the id of the row it inserted.
    let insertAt = -1;
    view.state.doc.forEach((node, offset) => {
      if (node.textContent === 'Last paragraph of X.') insertAt = offset;
    });
    expect(insertAt, 'the paragraph the blank one goes before must exist').toBeGreaterThan(-1);
    view.dispatch(view.state.tr.insert(insertAt, view.state.schema.nodes.paragraph.create()));
    flushPendingBlockChanges();
    const reported = getBlockChangesApi();
    expect(reported.inserts.length, 'the empty paragraph is reported as an insert').toBe(1);
    confirmBlockIdsApi({ [reported.inserts[0].tempId]: 'sx-blank' });
    getBlockChangesApi();
    expect(idsInOrder()).toEqual([
      'sx',
      'sx-intro',
      'sx-tight',
      'sx-gap-1',
      'sx-loose',
      'sx-gap-2',
      'sx-fig',
      'sx-blank',
      'sx-last',
      'sy',
      'sy-p',
    ]);

    const reply = duplicateSectionEditorFirst(OP, 'sx', []);

    expect(reply.ok, `reason: ${reply.reason}`).toBe(true);
    expect(reply.copies.map((c) => c.sourceId)).toEqual([
      'sx',
      'sx-intro',
      'sx-tight',
      'sx-gap-1',
      'sx-loose',
      'sx-gap-2',
      'sx-fig',
      'sx-blank',
      'sx-last',
    ]);
    const fixture = {
      about:
        'Written by duplicate-section-editor-first.test.ts (V1-13) from the real duplicateSectionEditorFirst reply; read by ' +
        'DuplicateSectionsEditorCopiesTests.testARealWebReplyGivesEveryEditorCopyItsRow. Regenerate with `cd web && pnpm vitest run -u`.',
      rootId: 'sx',
      // The rows the DATABASE holds for the section, ids equal to the editor's ids: the loose list is two rows (one editor node),
      // and the confirmed empty paragraph is a row with an empty fragment (the rows `BlockParser.alignmentPairs` skips).
      rows: [
        { id: 'sx', blockType: 'heading', headingLevel: 2, textContent: 'Section X', markdownFragment: '## Section X' },
        {
          id: 'sx-intro',
          blockType: 'paragraph',
          textContent: 'Intro paragraph.',
          markdownFragment: 'Intro paragraph.',
        },
        {
          id: 'sx-tight',
          blockType: 'bullet_list',
          textContent: 'tight one tight two',
          markdownFragment: '- tight one\n- tight two',
        },
        {
          id: 'sx-gap-1',
          blockType: 'paragraph',
          textContent: 'Between the lists.',
          markdownFragment: 'Between the lists.',
        },
        { id: 'sx-loose', blockType: 'bullet_list', textContent: 'loose one', markdownFragment: '- loose one' },
        { id: 'sx-loose-2', blockType: 'bullet_list', textContent: 'loose two', markdownFragment: '- loose two' },
        {
          id: 'sx-gap-2',
          blockType: 'paragraph',
          textContent: 'After the loose list.',
          markdownFragment: 'After the loose list.',
        },
        { id: 'sx-fig', blockType: 'image', textContent: 'cap', markdownFragment: '![cap](media/photo.png)' },
        { id: 'sx-blank', blockType: 'paragraph', textContent: '', markdownFragment: '' },
        {
          id: 'sx-last',
          blockType: 'paragraph',
          textContent: 'Last paragraph of X.',
          markdownFragment: 'Last paragraph of X.',
        },
      ],
      reply: normalizedReply(reply),
    };
    await expect(`${JSON.stringify(fixture, null, 2)}\n`).toMatchFileSnapshot(
      './fixtures/duplicate-section-reply.json'
    );
  });
});

/** The reply with each copy's new id replaced by `copy-<index>`: the ids are random UUIDs, and a file snapshot needs the same text
 * every run. Everything else (the source ids, the order, the leaders, the sidebar snapshot, the predecessor) is the function's own. */
function normalizedReply(reply: DuplicateSectionResult) {
  const names = new Map(reply.copies.map((c, index) => [c.newId, `copy-${index}`]));
  for (const c of reply.copies) expect(isTempBlockId(c.newId), `${c.newId} must be a permanent id`).toBe(false);
  expect(names.size, 'the copies have distinct ids').toBe(reply.copies.length);
  const named = (id: string) => names.get(id) ?? id;
  return {
    ok: reply.ok,
    batch: reply.batch,
    copies: reply.copies.map((c) => ({ sourceId: c.sourceId, newId: named(c.newId) })),
    insertedLeaderIds: reply.insertedLeaderIds.map(named),
    insertedSectionsSnapshot: reply.insertedSectionsSnapshot.map((section) => ({ ...section, id: named(section.id) })),
    predecessorId: reply.predecessorId,
  };
}
