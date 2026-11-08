// @vitest-environment jsdom
//
// Phase 5 job A9 (t-94369a83; design docs/architecture/write-queue-plan/phase5/a7-a10-design.md, section 3; run record a9-notes.md): the
// OUTGOING Rich Text page of a switch to Markdown. `takeTransitionBatch` drains what was typed since the begin (or the previous take) WITHOUT
// ending the hold, so the page stays typeable and held until the incoming Markdown page has its text (TransTwoPage); the last take (the
// catch-up) comes after the page has left the window. Break patches are recorded in a9-notes.md.

import { describe, expect, it } from 'vitest';

import { beginTransition, endTransition, swapTransition, takeTransitionBatch } from '../api-transition';
import { getTransitionToken } from '../undo-coordinator';
import {
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
import { hasReportablePending, takePendingAsReport } from './pending-for-test';

const book: Spec[] = [heading('h1', 1, 'Chapter One'), para('p1', 'First paragraph.'), para('p2', 'Second paragraph.')];
const cursor = () => ({ line: 3, column: 7 });

describe('takeTransitionBatch (the switch to Markdown, TransSwap)', () => {
  // Break patch A9-BP-TakeEndsHold: call `endHold()` at the end of takeTransitionBatch.
  // Predicted failure: the token is gone after the first take, the second take is refused and the polls see the later typing.
  it('drains the typing since the begin, keeps holding, and a second take sees only the later typing', async () => {
    const { view } = await makeEditor();
    await load(book);
    const began = beginTransition();
    if (!began.ok) throw new Error('begin refused');
    typeInto(view, 'First', ' alpha');
    const first = takeTransitionBatch(began.token, cursor);
    expect(first.ok).toBe(true);
    if (!first.ok) return;
    expect(first.batch.updates.map((update) => update.id)).toEqual(['p1']);
    expect(first.batch.updates[0].markdownFragment).toContain('alpha');
    expect(first.cursor).toEqual({ line: 3, column: 7 });
    expect(getTransitionToken()).toBe(began.token);
    // Typing after the take is held from the polls and drained by the next take (the catch-up).
    typeInto(view, 'Second', ' beta');
    await sleep(150);
    expect(hasReportablePending()).toBe(false);
    const second = takeTransitionBatch(began.token, cursor);
    expect(second.ok && second.batch.updates.map((update) => update.id)).toEqual(['p2']);
    expect(endTransition(began.token)).toEqual({ ended: true });
  });

  // Break patch A9-BP-TakeNoFlush: delete `flushPendingBlockChanges();` in takeTransitionBatch.
  // Predicted failure: keys typed in the last 100 ms (the detection debounce) are not in the take: `updates` is empty.
  it('takes the keys of the last 100 ms too (the detection debounce is flushed first)', async () => {
    const { view } = await makeEditor();
    await load(book);
    const began = beginTransition();
    if (!began.ok) throw new Error('begin refused');
    typeInto(view, 'Second', ' gamma');
    const take = takeTransitionBatch(began.token, cursor);
    expect(take.ok && take.batch.updates.map((update) => update.id)).toEqual(['p2']);
    endTransition(began.token);
  });

  it('answers an empty batch with no caret, and refuses a stale token', async () => {
    await makeEditor();
    await load(book);
    const began = beginTransition();
    if (!began.ok) throw new Error('begin refused');
    const empty = takeTransitionBatch(began.token, cursor);
    expect(empty.ok && empty.cursor).toBeNull();
    expect(takeTransitionBatch(began.token + 1, cursor).ok).toBe(false);
    endTransition(began.token);
    expect(takePendingAsReport().updates).toEqual([]);
  });
});

describe('the incoming Rich Text page of a switch to Rich Text (A10, TransIncomingReady and TransSwap)', () => {
  // The prepare (begin + swap of the rows' document on the detached page, then a second begin) and the carry swap (the rows after the
  // Markdown typing was written) with typing done on the new page since the flip put back on top.
  // Break patch A10-BP-NoReplay: remove the replay dispatch in swapTransition (A7's NoReplay): the word typed on the new page is lost.
  it('carries the rows written from the Markdown typing in, with the typing done on the new page put back on top', async () => {
    const { view } = await makeEditor();
    await load([para('x', 'Old page.')]);
    // The prepare: the rows' document with its ids, then the hold for typing after the flip.
    const prep = beginTransition();
    if (!prep.ok) throw new Error('begin refused');
    const prepared = swapTransition(prep.token, { markdown: markdownOf(book), blockIds: ['h1', 'p1', 'p2'] });
    expect(prepared.ok).toBe(true);
    expect(idsInOrder()).toEqual(['h1', 'p1', 'p2']);
    const hold = beginTransition();
    if (!hold.ok) throw new Error('hold refused');
    // After the flip the user types on the new page.
    typeInto(view, 'Second', ' local');
    // The carry: the rows now hold the Markdown typing done in the outgoing page (in p1).
    const carried: Spec[] = [
      heading('h1', 1, 'Chapter One'),
      para('p1', 'First paragraph. markdown'),
      para('p2', 'Second paragraph.'),
    ];
    const swapped = swapTransition(hold.token, { markdown: markdownOf(carried), blockIds: ['h1', 'p1', 'p2'] });
    expect(swapped.ok, JSON.stringify(swapped)).toBe(true);
    const texts: string[] = [];
    view.state.doc.forEach((node) => {
      texts.push(node.textContent);
    });
    expect(texts).toEqual(['Chapter One', 'First paragraph. markdown', 'Second paragraph. local']);
    // Block sync sees the new page's own typing as pending (the Markdown typing is already in the rows).
    await sleep(150);
    const pending = takePendingAsReport();
    expect(pending.updates.map((update) => update.id)).toEqual(['p2']);
  });
  // Break patch A10-BP-CarriedFirst: pass `carriedTextFirst: false` (or drop the option) in the carry swap.
  // Predicted failure: the keys typed on the new page come out BEFORE the keys typed in the outgoing page (`03 p5r`).
  it('puts keys typed on the new page after the carried keys typed at the same place in the outgoing page', async () => {
    const { view } = await makeEditor();
    await load([para('x', 'Old page.')]);
    const prep = beginTransition();
    if (!prep.ok) throw new Error('begin refused');
    swapTransition(prep.token, { markdown: markdownOf(book), blockIds: ['h1', 'p1', 'p2'] });
    const hold = beginTransition();
    if (!hold.ok) throw new Error('hold refused');
    // The outgoing Markdown page got " p5r" at the end of p2 (now in the rows); the new page got " 03" at the same place after the flip.
    typeInto(view, 'Second', ' 03');
    const carried: Spec[] = [
      heading('h1', 1, 'Chapter One'),
      para('p1', 'First paragraph.'),
      para('p2', 'Second paragraph. p5r'),
    ];
    const swapped = swapTransition(hold.token, {
      markdown: markdownOf(carried),
      blockIds: ['h1', 'p1', 'p2'],
      carriedTextFirst: true,
    });
    expect(swapped.ok, JSON.stringify(swapped)).toBe(true);
    const texts: string[] = [];
    view.state.doc.forEach((node) => {
      texts.push(node.textContent);
    });
    expect(texts[2]).toBe('Second paragraph. p5r 03');
  });

  // Hand test 2026-11-06 (a9-notes.md, "Cursor fix and switch notice"), run-1793947506-54633: " box with f" typed in the outgoing page in
  // the middle of a paragraph, right before " harbour"; "ive" typed on the new page at the same caret. The carried text starts with the
  // character that follows the caret (a space), so the diff finds it one character later ("box with f " after the space), and the new
  // page's keys went BEFORE it: "pack myive box with f harbour". Break patch A10-BP-Slide (`carriedAt` true only at `offset === diff.start`).
  it('puts keys typed on the new page after carried keys whose diff slid past a repeated character', async () => {
    const { view } = await makeEditor();
    const start: Spec[] = [
      heading('h1', 1, 'Chapter One'),
      para('p1', 'First paragraph.'),
      para('p2', 'Second pack my harbour.'),
    ];
    await load([para('x', 'Old page.')]);
    const prep = beginTransition();
    if (!prep.ok) throw new Error('begin refused');
    swapTransition(prep.token, { markdown: markdownOf(start), blockIds: ['h1', 'p1', 'p2'] });
    const hold = beginTransition();
    if (!hold.ok) throw new Error('hold refused');
    let caret = -1;
    view.state.doc.descendants((node, pos) => {
      if (caret < 0 && node.isText && node.text?.includes('pack my'))
        caret = pos + (node.text?.indexOf('pack my') ?? 0) + 7;
      return caret < 0;
    });
    view.dispatch(view.state.tr.insertText('ive', caret));
    const carried: Spec[] = [
      heading('h1', 1, 'Chapter One'),
      para('p1', 'First paragraph.'),
      para('p2', 'Second pack my box with f harbour.'),
    ];
    const swapped = swapTransition(hold.token, {
      markdown: markdownOf(carried),
      blockIds: ['h1', 'p1', 'p2'],
      carriedTextFirst: true,
    });
    expect(swapped.ok, JSON.stringify(swapped)).toBe(true);
    const texts: string[] = [];
    view.state.doc.forEach((node) => {
      texts.push(node.textContent);
    });
    expect(texts[2]).toBe('Second pack my box with five harbour.');
  });
});
