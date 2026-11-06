// @vitest-environment jsdom
//
// The zoom transition's page calls (Phase 5 job A7, api-transition.ts): `beginTransition` drains the batch and holds the typing that
// follows; `swapTransition` puts the typing recorded meanwhile back on top of the swapped-in document and hands back what the target
// cannot take (typing outside the zoomed range) as an ordinary batch; a refusal leaves the live document as the user had it and hands
// back the held typing. Design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md, sections 0, 1 and 7.
//
// The three ablations of the sync model (`P5_Ablate_Carry_NoReplay`, `_NoPend`, `_OnlyInDoc`) each have a test here that fails when the
// matching piece is switched off: no replay (the in-range typing is missing after the swap, E), no re-baseline (block-sync's queue after
// the swap is not exactly the replay, V), a dropped outside key (`outside` lacks the typing, E). The break patches are recorded in
// docs/architecture/write-queue-plan/phase5/a7-notes.md.

import { undo } from '@milkdown/kit/prose/history';
import { describe, expect, it } from 'vitest';
import { confirmBlockIdsApi, getBlockChangesApi, hasBlockChanges, setContentWithBlockIds } from '../api-content';
import {
  beginTransition,
  endTransition,
  setTestAfterTransitionReplaceHook,
  swapTransition,
  type TransitionBeginOk,
} from '../api-transition';
import { getTransitionToken, getTypingCollector, releaseHeldTypingPushes, setLatched } from '../undo-coordinator';
import { zoomNotesMarkerPlugin } from '../zoom-notes-marker-plugin';
import {
  EMPTY_BATCH,
  endOfParagraph,
  heading,
  idsInOrder,
  load,
  makeEditor,
  markdownOf,
  para,
  type Spec,
  sleep,
  typeInto,
} from './editor-first-harness';

const chapterOne: Spec[] = [heading('h1', 1, 'Chapter One'), para('p1', 'First paragraph.')];
const chapterTwo: Spec[] = [heading('h2', 1, 'Chapter Two'), para('p2', 'Second paragraph.')];
const book = [...chapterOne, ...chapterTwo];

function begun(): TransitionBeginOk {
  const result = beginTransition();
  if (!result.ok) throw new Error(`beginTransition refused: ${result.reason}`);
  return result;
}

/** The zoomed target: chapter two alone, as Swift assembles it from the rows. */
const zoomedTwo = () => ({
  markdown: markdownOf(chapterTwo),
  blockIds: ['h2', 'p2'],
  zoomMode: true,
  scrollToStart: true,
});

/** The text of every top-level block, in order. */
function texts(view: { state: { doc: { forEach: (f: (node: { textContent: string }) => void) => void } } }): string[] {
  const out: string[] = [];
  view.state.doc.forEach((node) => {
    out.push(node.textContent);
  });
  return out;
}

describe('beginTransition (TransBegin + TransLiveRead)', () => {
  it('returns the pending batch and holds the typing that follows from the polls', async () => {
    const { view } = await makeEditor();
    await load(book);
    typeInto(view, 'First', ' alpha');
    const result = begun();
    expect(result.batch.updates.map((update) => update.id)).toEqual(['p1']);
    expect(result.batch.updates[0].markdownFragment).toContain('alpha');
    expect(getTransitionToken()).toBe(result.token);
    // A key typed after the begin is recorded, not sent: the polls see nothing while the hold is on.
    typeInto(view, 'Second', ' beta');
    await sleep(150);
    expect(hasBlockChanges()).toBe(false);
    expect(getBlockChangesApi()).toEqual(EMPTY_BATCH);
    expect(
      getTypingCollector()
        .stepsSince(result.token)
        .some((step) => step.typing)
    ).toBe(true);
    expect(result.batch.updates.some((update) => update.id === 'p2')).toBe(false);
    endTransition(result.token);
  });

  it('refuses, holding nothing, while a Cmd-Z press is latched', async () => {
    await makeEditor();
    await load(book);
    setLatched(true);
    const result = beginTransition();
    setLatched(false);
    expect(result.ok).toBe(false);
    expect(getTransitionToken()).toBeNull();
  });

  it('endTransition ends the hold and leaves the typing for the next poll', async () => {
    const { view } = await makeEditor();
    await load(book);
    const result = begun();
    typeInto(view, 'Second', ' beta');
    expect(endTransition(result.token)).toEqual({ ended: true });
    expect(endTransition(result.token)).toEqual({ ended: false });
    expect(getTransitionToken()).toBeNull();
    await sleep(150);
    expect(hasBlockChanges()).toBe(true);
    expect(getBlockChangesApi().updates.map((update) => update.id)).toEqual(['p2']);
  });
});

describe('swapTransition into a zoomed target (TransPushFrom + TransReplay)', () => {
  it('replays the in-range typing, returns the out-of-range typing as an ordinary batch, and re-baselines block-sync on the replay', async () => {
    const { view } = await makeEditor();
    await load(book);
    const { token } = begun();
    // Outside the range: a word in chapter one and an Enter there with a word in the new paragraph. Inside: a word in chapter two.
    typeInto(view, 'First', ' alpha');
    const splitAt = endOfParagraph(view, 'First');
    view.dispatch(view.state.tr.split(splitAt));
    view.dispatch(view.state.tr.insertText('delta', splitAt + 2));
    typeInto(view, 'Second', ' beta');
    await sleep(150);

    const result = swapTransition(token, zoomedTwo());
    expect(result.ok, JSON.stringify(result)).toBe(true);
    if (!result.ok) return;
    expect(result.replayed).toBeGreaterThanOrEqual(1);
    // The document is the zoomed chapter with the in-range typing on top (ablation NoReplay: this line fails).
    expect(texts(view)).toEqual(['Chapter Two', 'Second paragraph. beta']);
    expect(idsInOrder()).toEqual(['h2', 'p2']);
    // The out-of-range typing comes back as a batch (ablation OnlyInDoc: these lines fail).
    expect(result.outside.updates.map((update) => update.id)).toEqual(['p1']);
    expect(result.outside.updates[0].markdownFragment).toContain('alpha');
    expect(result.outside.inserts).toHaveLength(1);
    expect(result.outside.inserts[0].tempId.startsWith('temp-')).toBe(true);
    expect(result.outside.inserts[0].afterBlockId).toBe('p1');
    expect(result.outside.inserts[0].markdownFragment).toBe('delta');
    expect(result.outside.deletes).toEqual([]);
    // The hold has ended and block-sync's queue holds exactly the replay (ablation NoPend: this fails).
    expect(getTransitionToken()).toBeNull();
    await sleep(150);
    const pending = getBlockChangesApi();
    expect(pending.updates.map((update) => update.id)).toEqual(['p2']);
    expect(pending.inserts).toEqual([]);
    expect(pending.deletes).toEqual([]);
    // The replay is one undo step.
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(texts(view)).toEqual(['Chapter Two', 'Second paragraph.']);
  });

  it('with nothing typed it is a plain replace: no replay, nothing pending, the hold ended', async () => {
    const { view } = await makeEditor();
    await load(book);
    const { token, batch } = begun();
    expect(batch).toEqual(EMPTY_BATCH);
    const result = swapTransition(token, zoomedTwo());
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.replayed).toBe(0);
    expect(result.outside).toEqual(EMPTY_BATCH);
    expect(texts(view)).toEqual(['Chapter Two', 'Second paragraph.']);
    expect(getTransitionToken()).toBeNull();
    await sleep(150);
    expect(getBlockChangesApi()).toEqual(EMPTY_BATCH);
  });

  it('zoom out: the target is the whole document and the typing done while zoomed is carried into it', async () => {
    const { view } = await makeEditor();
    await load(chapterTwo); // the editor shows the zoomed chapter
    const { token } = begun();
    typeInto(view, 'Second', ' gamma');
    const result = swapTransition(token, {
      markdown: markdownOf(book),
      blockIds: ['h1', 'p1', 'h2', 'p2'],
      scrollToBlockId: 'h2',
    });
    expect(result.ok, JSON.stringify(result)).toBe(true);
    if (!result.ok) return;
    expect(result.replayed).toBe(1);
    expect(result.outside).toEqual(EMPTY_BATCH);
    expect(texts(view)).toEqual(['Chapter One', 'First paragraph.', 'Chapter Two', 'Second paragraph. gamma']);
    expect(idsInOrder()).toEqual(['h1', 'p1', 'h2', 'p2']);
    await sleep(150);
    expect(getBlockChangesApi().updates.map((update) => update.id)).toEqual(['p2']);
  });
});

describe('swapTransition and ids Swift confirmed during the barrier', () => {
  it('typing in a paragraph the begin saw under a temp id, confirmed by Swift meanwhile, is carried into the target', async () => {
    const { view } = await makeEditor();
    await load(chapterTwo);
    // An Enter and a word just before the zoom out: the new paragraph has a temp id and is in the begin's batch as an insert.
    const splitAt = endOfParagraph(view, 'Second');
    view.dispatch(view.state.tr.split(splitAt));
    view.dispatch(view.state.tr.insertText('fresh', splitAt + 2));
    const { token, batch } = begun();
    expect(batch.inserts).toHaveLength(1);
    const tempId = batch.inserts[0].tempId;
    // Swift writes the batch during the barrier and confirms the permanent id; the user goes on typing in the new paragraph.
    confirmBlockIdsApi({ [tempId]: 'p3' });
    typeInto(view, 'fresh', ' words');
    const result = swapTransition(token, {
      markdown: markdownOf([...book, para('p3', 'fresh')]),
      blockIds: ['h1', 'p1', 'h2', 'p2', 'p3'],
    });
    expect(result.ok, JSON.stringify(result)).toBe(true);
    if (!result.ok) return;
    expect(result.replayed).toBe(1);
    expect(texts(view)).toEqual(['Chapter One', 'First paragraph.', 'Chapter Two', 'Second paragraph.', 'fresh words']);
    expect(result.outside).toEqual(EMPTY_BATCH);
  });
});

describe('swapTransition and a zoomed chapter mini-Notes (blocks without ids)', () => {
  const zoomedWithNotes = (definition: string): Spec[] => [
    ...chapterTwo,
    { name: 'zn', md: '<!-- ::zoom-notes:: -->' },
    { name: 'nh', md: '# Notes' },
    { name: 'nd', md: `[^1]: ${definition}` },
  ];
  // Swift loads a zoomed chapter with ids for the chapter's own blocks only: the mini-Notes get none.
  async function loadZoomedWithNotes(view: { state: unknown }): Promise<void> {
    const specs = zoomedWithNotes('A note.');
    setContentWithBlockIds(markdownOf(specs), ['h2', 'p2'], { zoomMode: true });
    await sleep(100);
    getBlockChangesApi();
    void view;
  }

  it('typing in the mini-Notes refuses the swap (Swift catches up from the page text) and leaves the document as typed', async () => {
    const { view } = await makeEditor([zoomNotesMarkerPlugin]);
    await loadZoomedWithNotes(view);
    const { token } = begun();
    let at = -1;
    view.state.doc.descendants((node, pos) => {
      if (at === -1 && node.isText && node.text?.includes('A note.')) at = pos + (node.text?.length ?? 0);
    });
    expect(at).toBeGreaterThan(-1);
    view.dispatch(view.state.tr.insertText(' more', at));
    const before = view.state.doc;
    const result = swapTransition(token, { markdown: markdownOf(book), blockIds: ['h1', 'p1', 'h2', 'p2'] });
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe('zoomNotesTyped');
    expect(view.state.doc.eq(before)).toBe(true);
    expect(getTransitionToken()).toBeNull();
  });

  it('typing in the chapter itself is carried even though the zoomed document has mini-Notes', async () => {
    const { view } = await makeEditor([zoomNotesMarkerPlugin]);
    await loadZoomedWithNotes(view);
    const { token } = begun();
    typeInto(view, 'Second', ' gamma');
    const result = swapTransition(token, { markdown: markdownOf(book), blockIds: ['h1', 'p1', 'h2', 'p2'] });
    expect(result.ok, JSON.stringify(result)).toBe(true);
    if (!result.ok) return;
    expect(result.replayed).toBe(1);
    expect(texts(view)).toEqual(['Chapter One', 'First paragraph.', 'Chapter Two', 'Second paragraph. gamma']);
  });
});

describe('a close, quit or project switch during a transition (the lifecycle release)', () => {
  it('releaseHeldTypingPushes ends the hold, the typing goes to the next poll, and a later swap refuses with nothing', async () => {
    const { view } = await makeEditor();
    await load(book);
    const { token } = begun();
    typeInto(view, 'Second', ' beta');
    expect(releaseHeldTypingPushes()).toBe(true);
    expect(getTransitionToken()).toBeNull();
    await sleep(150);
    expect(getBlockChangesApi().updates.map((update) => update.id)).toEqual(['p2']);
    const result = swapTransition(token, zoomedTwo());
    expect(result).toEqual({ ok: false, refused: true, reason: 'staleToken', batch: EMPTY_BATCH });
  });
});

describe('endTransition with no token (Swift could not read the begin reply)', () => {
  it('ends whatever hold is on', async () => {
    await makeEditor();
    await load(book);
    begun();
    expect(endTransition(null)).toEqual({ ended: true });
    expect(getTransitionToken()).toBeNull();
    expect(endTransition(null)).toEqual({ ended: false });
  });
});

describe('swapTransition refusals (the catch-up path)', () => {
  it('a typed step that spans the edge of the zoomed range refuses before the live document is touched, with the typing as the batch', async () => {
    const { view } = await makeEditor();
    await load(book);
    const { token } = begun();
    // A deletion from inside "First paragraph." into "Chapter Two": the join of a block outside the range with one inside it.
    const from = endOfParagraph(view, 'First') - 3;
    let headingStart = -1;
    view.state.doc.forEach((node, offset) => {
      if (node.textContent === 'Chapter Two') headingStart = offset + 1;
    });
    expect(headingStart).toBeGreaterThan(-1);
    view.dispatch(view.state.tr.delete(from, headingStart + 3));
    const before = view.state.doc;
    await sleep(150);
    const result = swapTransition(token, zoomedTwo());
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toContain('unplaceable');
    expect(view.state.doc.eq(before)).toBe(true);
    expect(result.batch.updates.length + result.batch.deletes.length).toBeGreaterThan(0);
    expect(getTransitionToken()).toBeNull();
    await sleep(150);
    expect(getBlockChangesApi()).toEqual(EMPTY_BATCH); // the batch was drained into the reply: nothing is sent twice
  });

  it('a failure after the replace puts the live document, its ids and the baseline back and hands back the held typing', async () => {
    const { view } = await makeEditor();
    await load(book);
    const { token } = begun();
    typeInto(view, 'Second', ' beta');
    typeInto(view, 'First', ' alpha');
    const before = view.state.doc;
    setTestAfterTransitionReplaceHook(() => {
      throw new Error('a plugin failed after the replace');
    });
    try {
      const result = swapTransition(token, zoomedTwo());
      expect(result.ok).toBe(false);
      if (result.ok) return;
      expect(result.reason).toContain('a plugin failed after the replace');
      expect(view.state.doc.eq(before)).toBe(true);
      expect(idsInOrder()).toEqual(['h1', 'p1', 'h2', 'p2']);
      expect(result.batch.updates.map((update) => update.id).sort()).toEqual(['p1', 'p2']);
      expect(getTransitionToken()).toBeNull();
      await sleep(150);
      expect(getBlockChangesApi()).toEqual(EMPTY_BATCH);
      // The editor is live again: the next key is an ordinary pending change.
      typeInto(view, 'First', ' more');
      await sleep(150);
      expect(getBlockChangesApi().updates.map((update) => update.id)).toEqual(['p1']);
    } finally {
      setTestAfterTransitionReplaceHook(null);
    }
  });

  it('a collector reset in the window (a barrier) refuses with the typing as the batch; a stale token refuses with nothing', async () => {
    const { view } = await makeEditor();
    await load(book);
    const { token } = begun();
    typeInto(view, 'Second', ' beta');
    const before = view.state.doc;
    expect(swapTransition(token + 1000, zoomedTwo())).toEqual({
      ok: false,
      refused: true,
      reason: 'staleToken',
      batch: EMPTY_BATCH,
    });
    expect(getTransitionToken()).toBe(token); // a stale token ends nothing
    getTypingCollector().reset();
    const result = swapTransition(token, zoomedTwo());
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe('collectorReset');
    expect(result.batch.updates.map((update) => update.id)).toEqual(['p2']);
    expect(view.state.doc.eq(before)).toBe(true);
    expect(getTransitionToken()).toBeNull();
  });
});
