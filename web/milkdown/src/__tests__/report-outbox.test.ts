// @vitest-environment jsdom
//
// Phase 5 job B2 (docs/architecture/write-queue-plan/phase5/b2-b4-design.md, section 2.3): the editor's SHADOW reports.
// A report per settled batch, monotone sequence numbers, the spacing R, nothing posted while held, and above all: the pending queue
// the poll drains is untouched by a report, and the reports of a window fold (with the plugin's own rules) to exactly what the drain
// takes. Real Milkdown editor, real transactions, fake timers for the 100 ms debounce and R.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { getBlockChangesReportedApi } from '../api-content';
import { blockIdPlugin, getAllBlockIds } from '../block-id-plugin';
import {
  type BlockChanges,
  blockSyncPlugin,
  getBlockChanges,
  hasPendingChanges,
  resetAndSnapshot,
  resetBlockSyncState,
  updateSnapshotIds,
} from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import { __resetReportOutboxForTest, applyOps, type BlockOp, setReportHoldProbe } from '../report-outbox';

interface Posted {
  es: number;
  session: string;
  kind: 'changes' | 'drain' | 'rebase';
  changes: BlockChanges;
  postedAt: number;
}

let posted: Posted[] = [];
/** What the capturing poster answers: false plays a page whose `blockReport` handler Swift has not registered yet. */
let delivering = true;

function capture(): void {
  posted = [];
  delivering = true;
  __resetReportOutboxForTest({
    intervalMs: 250,
    poster: (body) => {
      posted.push({
        es: body.es as number,
        session: body.session as string,
        kind: body.kind as Posted['kind'],
        changes: JSON.parse(body.json as string) as BlockChanges,
        postedAt: body.postedAt as number,
      });
      return delivering;
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
  // Start from a settled document: whatever the mount queued is drained (and its window closed).
  resetAndSnapshot(view.state.doc);
  return { editor, view };
}

/** Position of the end of the text of the top-level block at `index`. */
function endOfBlock(view: EditorView, index: number): number {
  let pos = 0;
  let found = -1;
  view.state.doc.forEach((node, offset, i) => {
    if (i === index) found = offset + node.nodeSize - 1;
    pos = offset;
  });
  expect(found).toBeGreaterThan(0);
  return found >= 0 ? found : pos;
}

function type(view: EditorView, index: number, text: string): void {
  view.dispatch(view.state.tr.insertText(text, endOfBlock(view, index)));
}

/** Swift's fold (ReportIntake): a rebase replaces the fold; any other report merges in with the plugin's rules. */
function fold(reports: readonly Posted[], idMap: ReadonlyMap<string, string> = new Map()): BlockChanges {
  const id = (raw: string) => idMap.get(raw) ?? raw;
  const acc = { pendingUpdates: new Map(), pendingInserts: new Map(), pendingDeletes: new Set<string>() };
  for (const report of reports) {
    if (report.kind === 'rebase') {
      acc.pendingUpdates.clear();
      acc.pendingInserts.clear();
      acc.pendingDeletes.clear();
    }
    const ops: BlockOp[] = [
      ...report.changes.deletes.map((raw) => ({ kind: 'delete' as const, id: id(raw) })),
      ...report.changes.updates.map((update) => ({
        kind: 'update' as const,
        id: id(update.id),
        update: { ...update, id: id(update.id) },
      })),
      ...report.changes.inserts.map((insert) => ({ kind: 'insert' as const, insert })),
    ];
    applyOps(acc, ops);
  }
  return {
    updates: Array.from(acc.pendingUpdates.values()),
    inserts: Array.from(acc.pendingInserts.values()),
    deletes: Array.from(acc.pendingDeletes),
  };
}

function sorted(changes: BlockChanges): BlockChanges {
  return {
    updates: [...changes.updates].sort((a, b) => a.id.localeCompare(b.id)),
    inserts: [...changes.inserts].sort((a, b) => a.tempId.localeCompare(b.tempId)),
    deletes: [...changes.deletes].sort(),
  };
}

/** Drains through the poll's bridge function and checks the window's reports fold to exactly the drained batch. */
function drainAndCompare(idMap: ReadonlyMap<string, string> = new Map()): BlockChanges & { reportThrough?: number } {
  const lastWindowEnd = posted.filter((p) => p.kind === 'drain').at(-1)?.es ?? 0;
  const drained = getBlockChangesReportedApi();
  expect(drained.reportThrough).toBeDefined();
  const window = posted.filter((p) => p.es > lastWindowEnd && p.es <= (drained.reportThrough ?? 0));
  expect(window.at(-1)?.kind).toBe('drain');
  const { reportThrough: _t, reportSession: _s, ...batch } = drained;
  expect(sorted(fold(window, idMap))).toEqual(sorted(batch));
  return drained;
}

describe('B2 shadow reports (report-outbox.ts)', () => {
  afterEach(() => {
    vi.useRealTimers();
    setReportHoldProbe(() => false);
    setEditorInstance(null);
    resetBlockSyncState();
  });

  it('posts one report per settled batch, does not touch the pending queue, and numbers reports in order', async () => {
    const { view } = await makeEditor('First paragraph.\n\nSecond paragraph.');
    capture();
    vi.useFakeTimers();
    type(view, 0, ' a');
    type(view, 0, 'b'); // same burst: inside the 100 ms debounce
    expect(posted).toHaveLength(0);
    vi.advanceTimersByTime(100);
    const changesReports = posted.filter((p) => p.kind === 'changes');
    expect(changesReports).toHaveLength(1);
    expect(changesReports[0].changes.updates).toHaveLength(1);
    expect(changesReports[0].changes.updates[0].textContent).toBe('First paragraph. ab');
    // The poll's queue still holds the change: the report took only the shadow.
    expect(hasPendingChanges()).toBe(true);
    vi.advanceTimersByTime(500);
    type(view, 1, ' c');
    vi.advanceTimersByTime(100);
    const es = posted.map((p) => p.es);
    expect(es).toEqual([...es].sort((a, b) => a - b));
    expect(new Set(es).size).toBe(es.length);
    expect(posted.every((p) => p.session === posted[0].session)).toBe(true);
    drainAndCompare();
  });

  it('spaces two reports at least R apart (R = 250 ms)', async () => {
    const { view } = await makeEditor('Para one.\n\nPara two.');
    capture();
    vi.useFakeTimers();
    type(view, 0, 'x');
    vi.advanceTimersByTime(100); // settles: posted at once (nothing posted before)
    type(view, 1, 'y');
    vi.advanceTimersByTime(100); // settles 100 ms after the first post: must wait until R
    const reports = posted.filter((p) => p.kind === 'changes');
    expect(reports).toHaveLength(1);
    vi.advanceTimersByTime(149);
    expect(posted.filter((p) => p.kind === 'changes')).toHaveLength(1);
    vi.advanceTimersByTime(1);
    const after = posted.filter((p) => p.kind === 'changes');
    expect(after).toHaveLength(2);
    expect(after[1].postedAt - after[0].postedAt).toBeGreaterThanOrEqual(250);
    drainAndCompare();
  });

  it('posts nothing while held, and the held stretch leaves as one report when the hold ends', async () => {
    const { view } = await makeEditor('Held one.\n\nHeld two.');
    capture();
    vi.useFakeTimers();
    let held = true;
    setReportHoldProbe(() => held);
    type(view, 0, ' p');
    vi.advanceTimersByTime(100);
    type(view, 1, ' q');
    vi.advanceTimersByTime(1_000);
    expect(posted.filter((p) => p.kind === 'changes')).toHaveLength(0);
    held = false;
    vi.advanceTimersByTime(250);
    const reports = posted.filter((p) => p.kind === 'changes');
    expect(reports).toHaveLength(1);
    expect(reports[0].changes.updates).toHaveLength(2);
    drainAndCompare();
  });

  it('a drain posts the unposted shadow first, and the reply names it', async () => {
    const { view } = await makeEditor('Drain one.\n\nDrain two.');
    capture();
    vi.useFakeTimers();
    type(view, 0, ' d');
    vi.advanceTimersByTime(100); // posted
    type(view, 1, ' e');
    vi.advanceTimersByTime(100); // settled, waiting for R: still in the shadow
    expect(posted.filter((p) => p.kind === 'changes')).toHaveLength(1);
    const drained = drainAndCompare();
    const drain = posted.at(-1);
    expect(drain?.kind).toBe('drain');
    expect(drained.reportThrough).toBe(drain?.es);
    expect(drain?.changes.updates.map((u) => u.textContent)).toEqual(['Drain two. e']);
    // Nothing is left to post afterwards: the waiting timer was cancelled with the drain.
    vi.advanceTimersByTime(1_000);
    expect(posted.at(-1)?.kind).toBe('drain');
  });

  it('folds to the drained batch for Enter (an insert), typing into the new block (update merged into the insert), a join and a paste', async () => {
    const { view } = await makeEditor('Alpha text.\n\nBeta text.\n\nGamma text.');
    capture();
    vi.useFakeTimers();
    // Enter at the end of Alpha: a new block with a temp id (an insert).
    view.dispatch(view.state.tr.split(endOfBlock(view, 0)));
    vi.advanceTimersByTime(100);
    vi.advanceTimersByTime(300);
    // Typing into the new block: an update merged into the pending insert (in the shadow AND in the real maps).
    type(view, 1, 'Typed');
    vi.advanceTimersByTime(100);
    vi.advanceTimersByTime(300);
    // Backspace joining Gamma onto Beta: a delete and an update.
    const betaEnd = endOfBlock(view, 2);
    view.dispatch(view.state.tr.delete(betaEnd, betaEnd + 2));
    vi.advanceTimersByTime(100);
    // A paste of two blocks after Alpha's end, inside R: still in the shadow at the drain.
    const schema = view.state.schema;
    const nodes = [
      schema.nodes.paragraph.create(null, schema.text('Pasted one.')),
      schema.nodes.paragraph.create(null, schema.text('Pasted two.')),
    ];
    view.dispatch(view.state.tr.insert(endOfBlock(view, 0) + 1, nodes));
    vi.advanceTimersByTime(100);
    const drained = drainAndCompare();
    expect(drained.inserts.length).toBeGreaterThanOrEqual(3);
    expect(drained.deletes.length).toBe(1);
  });

  it('re-keys the shadow when Swift confirms a temp id, so a later report names the permanent id', async () => {
    const { view } = await makeEditor('Rekey one.\n\nRekey two.');
    capture();
    vi.useFakeTimers();
    view.dispatch(view.state.tr.split(endOfBlock(view, 0)));
    vi.advanceTimersByTime(100);
    drainAndCompare(); // the poll takes the insert
    // The block Enter made (top-level index 1), keyed by position.
    const tempId = Array.from(getAllBlockIds().entries()).sort((a, b) => a[0] - b[0])[1]?.[1];
    expect(tempId).toBeDefined();
    type(view, 1, 'Later');
    vi.advanceTimersByTime(100);
    vi.advanceTimersByTime(150); // the report naming the temp id leaves at R
    expect(posted.at(-1)?.changes.updates.map((u) => u.id)).toEqual([tempId]);
    type(view, 1, 'More'); // settles inside R: in the shadow when the confirmation arrives
    vi.advanceTimersByTime(100);
    // What `confirmBlockIdsApi` does to the pending maps once the block-id plugin accepts the mapping.
    const mapping = new Map([[tempId as string, 'perm-0001']]);
    updateSnapshotIds(mapping);
    // Swift resolves the posted temp id through the writer's temp-id map (ReportIntake), as this fold does.
    const drained = drainAndCompare(mapping);
    expect(drained.updates.map((u) => u.id)).toEqual(['perm-0001']);
    expect(posted.at(-1)?.changes.updates.map((u) => u.id)).toEqual(['perm-0001']);
  });

  it('a reset of the pending queue posts a rebase, and the fold restarts from it', async () => {
    const { view } = await makeEditor('Reset one.\n\nReset two.');
    capture();
    vi.useFakeTimers();
    type(view, 0, ' gone');
    vi.advanceTimersByTime(100);
    resetAndSnapshot(view.state.doc); // a content push re-baselines: the queued update is discarded
    expect(posted.at(-1)?.kind).toBe('rebase');
    type(view, 1, ' kept');
    vi.advanceTimersByTime(100);
    const drained = drainAndCompare();
    expect(drained.updates.map((u) => u.textContent)).toEqual(['Reset two. kept']);
  });

  it('after reports the page could not deliver (no handler yet), the next report is preceded by a rebase of the real maps', async () => {
    const { view } = await makeEditor('Early one.\n\nEarly two.');
    capture();
    vi.useFakeTimers();
    delivering = false; // a prepared page, before Swift registers blockReport on it
    type(view, 0, ' lost');
    vi.advanceTimersByTime(100);
    vi.advanceTimersByTime(300);
    const undeliveredEs = posted.map((p) => p.es);
    expect(undeliveredEs.length).toBeGreaterThan(0);
    delivering = true;
    type(view, 1, ' seen');
    vi.advanceTimersByTime(100);
    // What Swift received: everything after the undelivered reports. The first of them is the rebase.
    const received = posted.filter((p) => !undeliveredEs.includes(p.es));
    expect(received[0]?.kind).toBe('rebase');
    expect(received[0]?.changes.updates.map((u) => u.textContent).sort()).toEqual([
      'Early one. lost',
      'Early two. seen',
    ]);
    const drained = getBlockChangesReportedApi();
    const window = posted.filter((p) => p.es >= received[0].es && p.es <= (drained.reportThrough ?? 0));
    const { reportThrough: _t, reportSession: _s, ...batch } = drained;
    expect(sorted(fold(window))).toEqual(sorted(batch));
  });

  it('with reporting off, nothing is posted and the poll reply carries no window', async () => {
    const { view } = await makeEditor('Off one.');
    __resetReportOutboxForTest({ enabled: false, poster: () => posted.push({} as Posted) > 0 });
    posted = [];
    vi.useFakeTimers();
    type(view, 0, ' z');
    vi.advanceTimersByTime(1_000);
    expect(posted).toHaveLength(0);
    const drained = getBlockChangesReportedApi();
    expect(drained.reportThrough).toBeUndefined();
    expect(drained.updates).toHaveLength(1);
    expect(getBlockChanges().updates).toHaveLength(0);
  });
});
