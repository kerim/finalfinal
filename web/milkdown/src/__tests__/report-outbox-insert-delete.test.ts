// @vitest-environment jsdom
//
// t-80274c66: a paragraph made with Return and removed again before its insert was sent must leave nothing in any report (no
// insert, no delete), in one report, across a held stretch and across a route's cover; a paragraph whose insert WAS sent must
// still have its delete sent. Real Milkdown editor, real transactions, fake timers (report-outbox.test.ts's harness).

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { closeHistory, undo } from '@milkdown/kit/prose/history';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ackReportsApi, beginReportCoverApi, endReportCoverApi } from '../api-content';
import { blockIdPlugin, getAllBlockIds, setBlockIdZoomMode } from '../block-id-plugin';
import {
  type BlockChanges,
  blockSyncPlugin,
  getBlockChanges,
  hasPendingChanges,
  resetAndSnapshot,
} from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import { __resetReportOutboxForTest, foldBatches, reportSession, setReportHoldProbe } from '../report-outbox';

let posted: BlockChanges[] = [];
/** `detectedAt` of each report in `posted` (when its oldest change was detected). */
let detectedAts: number[] = [];

function capture(intervalMs: number): void {
  posted = [];
  detectedAts = [];
  __resetReportOutboxForTest({
    enabled: true,
    intervalMs,
    repost: false,
    poster: (body) => {
      if (body.repost !== true) {
        posted.push(JSON.parse(body.json as string) as BlockChanges);
        detectedAts.push(body.detectedAt as number);
      }
      return true;
    },
  });
}

async function makeEditor(markdown: string, withHistory = false): Promise<{ editor: Editor; view: EditorView }> {
  const div = document.createElement('div');
  document.body.appendChild(div);
  let make = Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, markdown);
    })
    .use(commonmark)
    .use(gfm)
    .use(highlightPlugin)
    .use(blockIdPlugin)
    .use(blockSyncPlugin);
  if (withHistory) make = make.use(historyPlugin);
  const editor = await make.create();
  setEditorInstance(editor);
  const view = editor.ctx.get(editorViewCtx);
  resetAndSnapshot(view.state.doc);
  return { editor, view };
}

function blockRange(view: EditorView, index: number): { from: number; to: number } {
  let range: { from: number; to: number } | undefined;
  view.state.doc.forEach((node, offset, i) => {
    if (i === index) range = { from: offset, to: offset + node.nodeSize };
  });
  expect(range, `block ${index} exists`).toBeDefined();
  return range as { from: number; to: number };
}

function type(view: EditorView, index: number, text: string): void {
  view.dispatch(view.state.tr.insertText(text, blockRange(view, index).to - 1));
}

/** Return at the end of block `index`: a new empty paragraph with a temp id at `index + 1`. */
function enterAtEnd(view: EditorView, index: number): void {
  view.dispatch(view.state.tr.split(blockRange(view, index).to - 1));
}

function removeBlock(view: EditorView, index: number, ownUndoStep = false): void {
  const { from, to } = blockRange(view, index);
  const tr = view.state.tr.delete(from, to);
  view.dispatch(ownUndoStep ? closeHistory(tr) : tr);
}

function idOf(index: number): string {
  return Array.from(getAllBlockIds().entries())
    .sort((a, b) => a[0] - b[0])
    .map(([, id]) => id)[index];
}

const sentInserts = (): string[] => posted.flatMap((c) => c.inserts.map((i) => i.tempId));
const sentDeletes = (): string[] => posted.flatMap((c) => c.deletes);
const sentUpdates = (): string[] => posted.flatMap((c) => c.updates.map((u) => u.id));

const DOC = 'First paragraph.\n\nSecond paragraph.\n\nThird paragraph.';

describe('t-80274c66: an insert cancelled by its delete before it is sent', () => {
  afterEach(() => {
    vi.useRealTimers();
    setReportHoldProbe(() => false);
    setBlockIdZoomMode(false);
    document.body.innerHTML = '';
  });

  it('W1: Return, then the new paragraph removed before its insert is sent: no report names it', async () => {
    capture(1000);
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(120); // report 1 leaves at once; the next waits for R = 1000 ms
    expect(posted.length).toBe(1);
    enterAtEnd(view, 0);
    vi.advanceTimersByTime(120);
    const tempId = idOf(1);
    expect(tempId.startsWith('temp-'), 'premise: the Enter made a temp-id paragraph').toBe(true);
    expect(posted.length, 'premise: its insert is still waiting').toBe(1);
    removeBlock(view, 1);
    vi.advanceTimersByTime(2200);
    expect(sentInserts(), 'no report carries the insert of a paragraph removed before it was sent').not.toContain(
      tempId
    );
    expect(sentDeletes(), 'no report carries the delete of a paragraph that was never sent').not.toContain(tempId);
    expect(
      posted.length,
      'only the first typing report left: no report, empty or not, was sent for the removed paragraph'
    ).toBe(1);
    expect(hasPendingChanges()).toBe(false);
  });

  it('W2: the same with text typed into the new paragraph before it is removed', async () => {
    capture(1000);
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(120);
    enterAtEnd(view, 0);
    vi.advanceTimersByTime(120);
    const tempId = idOf(1);
    type(view, 1, 'typed');
    vi.advanceTimersByTime(120);
    removeBlock(view, 1);
    vi.advanceTimersByTime(2200);
    expect(sentInserts(), 'no insert of the removed paragraph').not.toContain(tempId);
    expect(sentDeletes(), 'no delete of the removed paragraph').not.toContain(tempId);
    expect(sentUpdates(), 'no update of the removed paragraph').not.toContain(tempId);
  });

  it('W3: across a held stretch (a save or a zoom holding the reports), the held report does not name it', async () => {
    capture(250);
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    let held = true;
    setReportHoldProbe(() => held);
    type(view, 0, ' kept');
    enterAtEnd(view, 0);
    vi.advanceTimersByTime(1000);
    const tempId = idOf(1);
    expect(tempId.startsWith('temp-')).toBe(true);
    removeBlock(view, 1);
    vi.advanceTimersByTime(1000);
    expect(posted.length, 'premise: nothing leaves while held').toBe(0);
    held = false;
    vi.advanceTimersByTime(300);
    expect(posted.length).toBe(1);
    expect(posted[0].updates.find((u) => u.id === idOf(0))?.textContent).toBe('First paragraph. kept');
    expect(sentInserts(), 'the held report carries no insert of the removed paragraph').not.toContain(tempId);
    expect(sentDeletes(), 'the held report carries no delete of it').not.toContain(tempId);
  });

  it('W4: foldBatches cancels the insert and re-anchors the paragraph chained after it (anchor and document start)', () => {
    const p = (tempId: string, afterBlockId?: string, atDocumentStart?: boolean) => ({
      tempId,
      blockType: 'paragraph',
      textContent: '',
      markdownFragment: '',
      afterBlockId,
      atDocumentStart,
    });
    const fold = foldBatches([
      { updates: [], deletes: [], inserts: [p('temp-A', 'x'), p('temp-B', 'temp-A')] },
      {
        updates: [{ id: 'temp-A', textContent: 't', markdownFragment: 't', blockType: 'paragraph' }],
        inserts: [],
        deletes: [],
      },
      { updates: [], inserts: [], deletes: ['temp-A'] },
    ]);
    expect(fold.deletes, 'the cancelled paragraph is not deleted').toEqual([]);
    expect(fold.updates).toEqual([]);
    expect(
      fold.inserts.map((i) => i.tempId),
      'only the chained paragraph is inserted'
    ).toEqual(['temp-B']);
    expect(fold.inserts[0].afterBlockId, "it takes the cancelled one's anchor").toBe('x');

    const atStart = foldBatches([
      { updates: [], deletes: [], inserts: [p('temp-C', undefined, true), p('temp-D', 'temp-C')] },
      { updates: [], inserts: [], deletes: ['temp-C'] },
    ]);
    expect(atStart.inserts.map((i) => i.tempId)).toEqual(['temp-D']);
    expect(atStart.inserts[0]).toMatchObject({ atDocumentStart: true });
    expect(atStart.inserts[0].afterBlockId).toBeUndefined();
  });

  it('W5a: a paragraph whose insert WAS sent (not yet acknowledged) still has its delete sent, by its temp id', async () => {
    capture(250);
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    enterAtEnd(view, 0);
    vi.advanceTimersByTime(400);
    const tempId = posted[0]?.inserts[0]?.tempId as string;
    expect(tempId?.startsWith('temp-')).toBe(true);
    removeBlock(view, 1);
    vi.advanceTimersByTime(400);
    expect(sentDeletes(), 'the sent paragraph is deleted').toContain(tempId);
  });

  it('W5b: once the insert is acknowledged and confirmed, the delete names the permanent id', async () => {
    capture(250);
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    enterAtEnd(view, 0);
    vi.advanceTimersByTime(400);
    const tempId = posted[0]?.inserts[0]?.tempId as string;
    ackReportsApi({ session: reportSession(), through: 1, idMapping: { [tempId]: 'perm-1' } });
    removeBlock(view, 1);
    vi.advanceTimersByTime(400);
    expect(sentDeletes()).toContain('perm-1');
  });

  it('W6: under a cover, an insert still on its way to Swift and its delete still in the maps fold away together', async () => {
    capture(5000);
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' r1');
    vi.advanceTimersByTime(120); // report 1 leaves at once: Swift took it in (since = 1)
    vi.advanceTimersByTime(5000); // R = 5000 ms has passed since report 1
    enterAtEnd(view, 1);
    vi.advanceTimersByTime(120); // report 2 leaves at once, carrying the insert: still on its way to Swift
    const tempId = posted[1]?.inserts[0]?.tempId as string;
    expect(tempId?.startsWith('temp-'), 'premise: report 2 carries the insert').toBe(true);
    removeBlock(view, 2);
    vi.advanceTimersByTime(120); // less than R after report 2: the delete is detected and waits in the maps
    expect(posted.length, 'premise: the delete has not been posted').toBe(2);
    expect(hasPendingChanges(), 'premise: the delete is pending in the maps').toBe(true);
    beginReportCoverApi(reportSession(), 1);
    const batch = getBlockChanges();
    endReportCoverApi();
    expect(
      batch.inserts.map((i) => i.tempId),
      'the route batch carries no insert of the removed paragraph'
    ).not.toContain(tempId);
    expect(batch.deletes, 'and no delete of it').not.toContain(tempId);
    expect(hasPendingChanges(), 'and nothing is left pending').toBe(false);
  });

  it('W7 (premise of the Swift guard): an undo that brings back a sent-then-removed paragraph uses a NEW temp id', async () => {
    capture(1000);
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC, true);
    enterAtEnd(view, 0);
    vi.advanceTimersByTime(120); // report 1 carries the insert
    const tempId = posted[0]?.inserts[0]?.tempId as string;
    expect(tempId?.startsWith('temp-')).toBe(true);
    removeBlock(view, 1, true);
    vi.advanceTimersByTime(120);
    expect(undo(view.state, view.dispatch), 'premise: the removal is one undo step').toBe(true);
    vi.advanceTimersByTime(2200);
    expect(posted.length).toBe(2);
    expect(posted[1].deletes).toContain(tempId);
    expect(posted[1].inserts.length, 'the undo re-inserts the paragraph').toBe(1);
    expect(posted[1].inserts[0].tempId, 'under a new temp id, never the deleted one').not.toBe(tempId);
  });

  it('W8: Return, Backspace before the insert is sent, Cmd-Z, then typing: one insert goes out, under a new temp id, with the typed text', async () => {
    capture(1000);
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC, true);
    type(view, 0, ' a');
    vi.advanceTimersByTime(120); // report 1 leaves at once; the next waits for R = 1000 ms
    expect(posted.length).toBe(1);
    enterAtEnd(view, 0);
    vi.advanceTimersByTime(120);
    const cancelledId = idOf(1);
    expect(cancelledId.startsWith('temp-'), 'premise: the Enter made a temp-id paragraph').toBe(true);
    removeBlock(view, 1, true); // the removal is its own undo step
    vi.advanceTimersByTime(120);
    expect(posted.length, 'premise: the insert was cancelled before it was sent').toBe(1);
    expect(undo(view.state, view.dispatch), 'premise: the removal is one undo step').toBe(true);
    vi.advanceTimersByTime(120);
    type(view, 1, 'typed');
    vi.advanceTimersByTime(2200);
    expect(posted.length, 'one more report: the paragraph the undo brought back, with its typing').toBe(2);
    expect(sentInserts().length, 'exactly one insert goes out (no repeat)').toBe(1);
    expect(sentInserts()[0], 'under a temp id that is not the cancelled one').not.toBe(cancelledId);
    expect(posted[1].inserts[0].textContent, 'the typed text arrives with the insert').toContain('typed');
    expect(posted[1].inserts[0].markdownFragment, 'in its markdown too').toContain('typed');
    expect(sentDeletes(), 'the cancelled paragraph is still never deleted').not.toContain(cancelledId);
    expect(sentUpdates(), 'the typing is not a separate update').not.toContain(sentInserts()[0]);
    expect(hasPendingChanges()).toBe(false);
  });

  it('W9: a chain whose cancelled head has no anchor at all (zoom mode, first block): the survivor goes out with no anchor', async () => {
    capture(1000);
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    setBlockIdZoomMode(true); // a zoomed page: its first block has no afterBlockId and no atDocumentStart
    type(view, 0, ' a');
    vi.advanceTimersByTime(120); // report 1 leaves at once; the next waits for R = 1000 ms
    const paragraph = view.state.schema.nodes.paragraph;
    view.dispatch(view.state.tr.insert(0, paragraph.create({}, view.state.schema.text('Head.'))));
    vi.advanceTimersByTime(120);
    const headId = idOf(0);
    expect(headId.startsWith('temp-'), 'premise: the new first paragraph has a temp id').toBe(true);
    view.dispatch(
      view.state.tr.insert(blockRange(view, 0).to, paragraph.create({}, view.state.schema.text('Survivor.')))
    );
    vi.advanceTimersByTime(120);
    expect(idOf(1).startsWith('temp-'), 'premise: the paragraph after it has a temp id').toBe(true);
    removeBlock(view, 0);
    vi.advanceTimersByTime(2200);
    expect(posted.length, 'premise: one more report').toBe(2);
    expect(sentInserts(), 'the cancelled head is not inserted').not.toContain(headId);
    expect(sentDeletes(), 'nor deleted').not.toContain(headId);
    const survivor = posted[1].inserts.find((i) => i.textContent === 'Survivor.');
    expect(survivor, 'the survivor is inserted').toBeDefined();
    expect(survivor?.afterBlockId, 'with no anchor, not anchored on the cancelled paragraph').toBeUndefined();
    expect(survivor?.atDocumentStart, 'and no document-start flag in zoom mode').toBeFalsy();
  });

  it("W10: after a cancel, the next report's detectedAt is the time of its own oldest change, not of the cancelled Return", async () => {
    capture(1000);
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(120); // report 1 leaves at once
    enterAtEnd(view, 0);
    vi.advanceTimersByTime(120);
    removeBlock(view, 1);
    vi.advanceTimersByTime(120); // the insert is cancelled: nothing is left unreported
    vi.advanceTimersByTime(10000); // a long pause
    expect(posted.length, 'premise: nothing more was sent').toBe(1);
    const editedAt = Date.now();
    type(view, 0, ' b');
    vi.advanceTimersByTime(2200);
    expect(posted.length, 'premise: the real edit is the second report').toBe(2);
    expect(
      detectedAts[1],
      "the report's detectedAt is the real edit's time, not the cancelled Return's"
    ).toBeGreaterThanOrEqual(editedAt);
  });
});
