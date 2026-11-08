// @vitest-environment jsdom
//
// Phase 5 job B3 (docs/architecture/write-queue-plan/phase5/b2-b4-design.md, sections 3.2 to 3.6): the editor's reports are the
// writer's input. A report per settled batch takes the pending maps, monotone numbers per session, the spacing R, nothing posted while
// held, the outbox kept until Swift acknowledges it (and the ids confirmed in the same call), `flushReports` posts and answers in one
// turn, the cover (a route's drain returns every report still on its way to Swift plus its own part, once), the session token.
// Real Milkdown editor, real transactions, fake timers for the 100 ms debounce and R.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  ackReportsApi,
  beginReportCoverApi,
  endReportCoverApi,
  flushReportsApi,
  holdReportsForSaveApi,
  releaseReportHoldApi,
  reportOutboxSinceApi,
  resetForProjectSwitch,
} from '../api-content';
import { blockIdPlugin, getAllBlockIds } from '../block-id-plugin';
import {
  type BlockChanges,
  blockSyncPlugin,
  getBlockChanges,
  hasPendingChanges,
  resetAndSnapshot,
} from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import {
  __resetReportOutboxForTest,
  foldBatches,
  outboxEntries,
  reportSession,
  setReportHoldProbe,
} from '../report-outbox';

interface Posted {
  es: number;
  session: string;
  kind: string;
  changes: BlockChanges;
  postedAt: number;
}

let posted: Posted[] = [];
/** Re-posts (B4), kept apart so the B3 tests above read first posts only. */
let reposted: Posted[] = [];

function capture(enabled = true, repost = true): void {
  posted = [];
  reposted = [];
  __resetReportOutboxForTest({
    enabled,
    intervalMs: 250,
    repost,
    poster: (body) => {
      (body.repost === true ? reposted : posted).push({
        es: body.es as number,
        session: body.session as string,
        kind: body.kind as string,
        changes: JSON.parse(body.json as string) as BlockChanges,
        postedAt: body.postedAt as number,
      });
      return true;
    },
  });
}

async function makeEditor(markdown: string): Promise<{ editor: Editor; view: EditorView }> {
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
  setEditorInstance(editor);
  const view = editor.ctx.get(editorViewCtx);
  resetAndSnapshot(view.state.doc);
  return { editor, view };
}

function endOfBlock(view: EditorView, index: number): number {
  let found = -1;
  view.state.doc.forEach((node, offset, i) => {
    if (i === index) found = offset + node.nodeSize - 1;
  });
  expect(found).toBeGreaterThan(0);
  return found;
}

function type(view: EditorView, index: number, text: string): void {
  view.dispatch(view.state.tr.insertText(text, endOfBlock(view, index)));
}

function idOf(index: number): string {
  const ids = Array.from(getAllBlockIds().entries())
    .sort((a, b) => a[0] - b[0])
    .map(([, id]) => id);
  return ids[index];
}

function textOf(changes: BlockChanges, id: string): string | undefined {
  return changes.updates.find((u) => u.id === id)?.textContent;
}

const DOC = 'First paragraph.\n\nSecond paragraph.\n\nThird paragraph.';

describe('B3 reports (report-outbox.ts)', () => {
  afterEach(() => {
    vi.useRealTimers();
    setReportHoldProbe(() => false);
    document.body.innerHTML = '';
  });

  it('a settled batch leaves as one report that TAKES the pending maps, numbered in order, and stays in the outbox', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' one');
    vi.advanceTimersByTime(120);
    expect(posted.map((p) => p.es)).toEqual([1]);
    expect(hasPendingChanges()).toBe(false); // the report took the maps
    expect(textOf(posted[0].changes, idOf(0))).toBe('First paragraph. one');
    vi.advanceTimersByTime(300);
    type(view, 1, ' two');
    vi.advanceTimersByTime(120);
    expect(posted.map((p) => p.es)).toEqual([1, 2]);
    expect(posted.every((p) => p.session === reportSession())).toBe(true);
    expect(outboxEntries().map((e) => e.es)).toEqual([1, 2]);
  });

  it('spaces two reports at least R apart and the second carries everything typed meanwhile', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(120);
    type(view, 0, 'b');
    vi.advanceTimersByTime(120); // settled 120 ms after the first post: waits for R
    expect(posted.length).toBe(1);
    vi.advanceTimersByTime(200);
    expect(posted.length).toBe(2);
    expect(posted[1].postedAt - posted[0].postedAt).toBeGreaterThanOrEqual(250);
    expect(textOf(posted[1].changes, idOf(0))).toBe('First paragraph. ab');
  });

  it('posts nothing while held; the held stretch leaves as one report when the hold ends', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    let held = true;
    setReportHoldProbe(() => held);
    type(view, 0, ' x');
    vi.advanceTimersByTime(1000);
    type(view, 1, ' y');
    vi.advanceTimersByTime(1000);
    expect(posted.length).toBe(0);
    expect(hasPendingChanges()).toBe(true);
    held = false;
    vi.advanceTimersByTime(300);
    expect(posted.length).toBe(1);
    expect(textOf(posted[0].changes, idOf(0))).toBe('First paragraph. x');
    expect(textOf(posted[0].changes, idOf(1))).toBe('Second paragraph. y');
  });

  it('ackReports drops the outbox up to `through` and confirms the ids in the same call; another session changes nothing', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    view.dispatch(view.state.tr.split(endOfBlock(view, 0))); // Enter: an insert with a temp id
    vi.advanceTimersByTime(120);
    type(view, 2, ' z');
    vi.advanceTimersByTime(400);
    expect(posted.map((p) => p.es)).toEqual([1, 2]);
    const tempId = posted[0].changes.inserts[0]?.tempId;
    expect(tempId?.startsWith('temp-')).toBe(true);
    expect(ackReportsApi({ session: 'some-other-session', through: 2 })).toBe(0);
    expect(outboxEntries().length).toBe(2);
    expect(ackReportsApi({ session: reportSession(), through: 1, idMapping: { [tempId as string]: 'perm-1' } })).toBe(
      1
    );
    expect(outboxEntries().map((e) => e.es)).toEqual([2]);
    expect(Array.from(getAllBlockIds().values())).toContain('perm-1');
    // A later edit of the confirmed block names the permanent id.
    type(view, 1, 'q');
    vi.advanceTimersByTime(400);
    expect(posted[2].changes.updates.map((u) => u.id)).toContain('perm-1');
  });

  it('flushReports runs the pending detection and posts in the same turn, ignoring R, and answers the number', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(120);
    type(view, 1, ' b'); // inside the 100 ms debounce and inside R
    const reply = flushReportsApi();
    expect(reply).toMatchObject({ through: 2, session: reportSession(), held: false, enabled: true });
    expect(posted.map((p) => p.es)).toEqual([1, 2]);
    expect(textOf(posted[1].changes, idOf(1))).toBe('Second paragraph. b');
    expect(hasPendingChanges()).toBe(false);
  });

  it('flushReports does not post held typing, but still answers the highest number', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(120);
    setReportHoldProbe(() => true);
    type(view, 1, ' b');
    const reply = flushReportsApi();
    expect(reply).toMatchObject({ through: 1, held: true });
    expect(posted.length).toBe(1);
  });

  it('the cover: a route drain returns every report after `since` folded with its own part, posts its part numbered, once', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' r1');
    vi.advanceTimersByTime(400); // report 1 (Swift took it in: since = 1)
    type(view, 1, ' r2');
    vi.advanceTimersByTime(120); // report 2: still on its way to Swift
    type(view, 1, ' own');
    type(view, 2, ' own3');
    vi.advanceTimersByTime(120); // detected into the maps, but inside R: not posted yet
    beginReportCoverApi(reportSession(), 1);
    const batch = getBlockChanges();
    const second = getBlockChanges(); // a second drain in the same call is a plain drain
    const cover = endReportCoverApi();
    expect(textOf(batch, idOf(1))).toBe('Second paragraph. r2 own');
    expect(textOf(batch, idOf(2))).toBe('Third paragraph. own3');
    expect(textOf(batch, idOf(0))).toBeUndefined(); // report 1 was taken in before: not covered
    expect(second.updates.length + second.inserts.length + second.deletes.length).toBe(0);
    expect(posted.map((p) => [p.es, p.kind])).toEqual([
      [1, 'changes'],
      [2, 'changes'],
      [3, 'drain'],
    ]);
    expect(cover).toEqual({ session: reportSession(), since: 1, through: 3, drained: true });
    expect(hasPendingChanges()).toBe(false);
  });

  it('the cover with a session Swift does not know covers the whole outbox; a route that does not drain covers nothing', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' r1');
    vi.advanceTimersByTime(400);
    beginReportCoverApi('older-session', 5);
    const batch = getBlockChanges();
    endReportCoverApi();
    expect(textOf(batch, idOf(0))).toBe('First paragraph. r1');
    beginReportCoverApi(reportSession(), 1);
    expect(endReportCoverApi()).toMatchObject({ drained: false });
  });

  it('outboxSince answers the unacknowledged entries after `since` (all of them for another session)', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(400);
    type(view, 1, ' b');
    vi.advanceTimersByTime(400);
    expect(reportOutboxSinceApi(reportSession(), 1).entries.map((e) => e.es)).toEqual([2]);
    expect(reportOutboxSinceApi('other', 1).entries.map((e) => e.es)).toEqual([1, 2]);
    ackReportsApi({ session: reportSession(), through: 2 });
    expect(reportOutboxSinceApi(reportSession(), 0).entries).toEqual([]);
  });

  it('the save hold: nothing leaves after the live read until released; then one report', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(400);
    expect(holdReportsForSaveApi()).toEqual({ session: reportSession(), through: 1 });
    type(view, 1, ' b');
    vi.advanceTimersByTime(2000);
    expect(flushReportsApi()).toMatchObject({ through: 1, held: true });
    expect(posted.length).toBe(1);
    releaseReportHoldApi();
    vi.advanceTimersByTime(400);
    expect(posted.length).toBe(2);
  });

  it('a project switch starts a new session: numbers restart, the outbox is empty, the old session is gone', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(400);
    const before = reportSession();
    resetForProjectSwitch();
    expect(reportSession()).not.toBe(before);
    expect(outboxEntries().length).toBe(0);
    expect(ackReportsApi({ session: before, through: 1 })).toBe(0);
  });

  it('with reporting off nothing is posted and the drain keeps the old behaviour', async () => {
    capture(false);
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(1000);
    expect(posted.length).toBe(0);
    beginReportCoverApi(null, 0);
    const batch = getBlockChanges();
    expect(endReportCoverApi()).toBeNull();
    expect(textOf(batch, idOf(0))).toBe('First paragraph. a');
    expect(flushReportsApi()).toMatchObject({ enabled: false, through: 0 });
  });

  // B4: the re-post replaces the 2-second poll's net (b2-b4-design.md 4.2).
  it('re-posts an unacknowledged report 2 s after it was sent, unchanged, and again 2 s later', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(120);
    expect(posted.map((p) => p.es)).toEqual([1]);
    vi.advanceTimersByTime(1800); // 1.9 s after the post: not yet
    expect(reposted).toEqual([]);
    vi.advanceTimersByTime(200);
    expect(reposted.map((p) => [p.es, p.session])).toEqual([[1, reportSession()]]);
    expect(reposted[0].changes).toEqual(posted[0].changes);
    vi.advanceTimersByTime(1900);
    expect(reposted.length).toBe(1); // spaced 2 s from its LAST send
    vi.advanceTimersByTime(100);
    expect(reposted.map((p) => p.es)).toEqual([1, 1]);
  });

  it('spaces each entry 2 s from its own last send when two reports are on different schedules', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(1000); // report 1 at about 100 ms
    type(view, 1, ' b');
    vi.advanceTimersByTime(1000); // report 2 at about 1.1 s; report 1 re-posted at about 2.1 s
    vi.advanceTimersByTime(200);
    expect(reposted.map((p) => p.es)).toEqual([1]);
    vi.advanceTimersByTime(1000); // about 3.3 s: report 2 is due, report 1 (sent again at 2.1 s) is not
    expect(reposted.map((p) => p.es)).toEqual([1, 2]);
    vi.advanceTimersByTime(900); // about 4.2 s: report 1 is due again
    expect(reposted.map((p) => p.es)).toEqual([1, 2, 1]);
  });

  it('re-posts only what is still in the outbox, and stops once everything is acknowledged', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    type(view, 0, ' a');
    vi.advanceTimersByTime(400);
    type(view, 1, ' b');
    vi.advanceTimersByTime(400);
    expect(posted.map((p) => p.es)).toEqual([1, 2]);
    ackReportsApi({ session: reportSession(), through: 1 });
    vi.advanceTimersByTime(2000);
    expect(reposted.map((p) => p.es)).toEqual([2]);
    ackReportsApi({ session: reportSession(), through: 2 });
    vi.advanceTimersByTime(10_000);
    expect(reposted.map((p) => p.es)).toEqual([2]);
    expect(vi.getTimerCount()).toBe(0); // no timer runs while the outbox is empty
  });

  it('runs no re-post timer while the outbox is empty, nor while the save holds the reports, nor when switched off', async () => {
    capture();
    vi.useFakeTimers();
    const { view } = await makeEditor(DOC);
    vi.advanceTimersByTime(5000);
    expect(vi.getTimerCount()).toBe(0);
    type(view, 0, ' a');
    vi.advanceTimersByTime(400);
    holdReportsForSaveApi();
    vi.advanceTimersByTime(5000);
    expect(reposted).toEqual([]);
    releaseReportHoldApi();
    vi.advanceTimersByTime(100);
    expect(reposted.map((p) => p.es)).toEqual([1]); // overdue: sent again at once when the hold ends
    capture(true, false);
    const second = await makeEditor(DOC);
    type(second.view, 0, ' b');
    vi.advanceTimersByTime(5000);
    expect(posted.length).toBe(1);
    expect(reposted).toEqual([]);
  });

  it('foldBatches merges with the plugin rules (an update into a pending insert, a delete removing an update)', () => {
    const fold = foldBatches([
      {
        updates: [{ id: 'a', textContent: 'x', markdownFragment: 'x', blockType: 'paragraph' }],
        inserts: [
          { tempId: 'temp-1', blockType: 'paragraph', textContent: '', markdownFragment: '', afterBlockId: 'a' },
        ],
        deletes: [],
      },
      {
        updates: [{ id: 'temp-1', textContent: 'typed', markdownFragment: 'typed', blockType: 'paragraph' }],
        inserts: [],
        deletes: ['a'],
      },
    ]);
    expect(fold.updates).toEqual([]);
    expect(fold.deletes).toEqual(['a']);
    expect(fold.inserts[0]).toMatchObject({ tempId: 'temp-1', textContent: 'typed', afterBlockId: 'a' });
  });
});
