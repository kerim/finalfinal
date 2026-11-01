// @vitest-environment jsdom
//
// Typing done while a Cmd-Z waits (Phase 4c, job 2, t-d2061b27), round 2b: the QUICK routes. `undoSectionDeleteEditorFirst`
// (api-section-undo.ts) is the quick undo of a Delete, a Duplicate and the three Version History restores; the quick redos
// (`checkQuickRedoAllowed`) re-run the operation on the live document.
//
// What is tested, with the real routes, plugins and Swift-facing calls (Swift's side is played by the test):
//   * the re-check compares the document AS IT WAS WHEN THE KEY WAS PRESSED and writes `typing-since-press press=P steps=N decision=...`;
//   * the replay is built and tried against the target BEFORE the swap and dispatched after it; the reply says `typingReplayed`, and its
//     batch is empty: the wait typing is NOT taken as batch N, the replay is its only carrier (found by `detectEditsSinceSnapshot` at
//     the resume and queued behind the reinsert once);
//   * only a typed step the target has no place for refuses, before anything is consumed or swapped; the typing stays pending and goes
//     out when the latch ends (D1); a replay that goes wrong after the swap is put back and the held batch comes back (D2);
//   * a quick redo is not a swap (it re-runs the operation on the live document as a fresh command), so it has no replay: typing done
//     elsewhere is kept and the redo runs; it is refused only when the typing sits inside the text the redo takes out.
//
// Each case FIRST asserts the premise: the collector recorded steps and the trace line says so. Typing includes a Return.

import { redo as historyRedo, redoDepth, undo } from '@milkdown/kit/prose/history';
import { describe, expect, it } from 'vitest';
import { getBlockChangesApi } from '../api-content';
import { deleteSectionEditorFirst } from '../api-section-delete';
import { duplicateSectionEditorFirst, redoSectionDuplicateEditorFirst } from '../api-section-duplicate';
import {
  redoSectionDeleteEditorFirst,
  setTestAfterQuickReplayHook,
  undoSectionDeleteEditorFirst,
} from '../api-section-undo';
import {
  type ReplaceRangePayload,
  redoReplaceRangeEditorFirst,
  replaceRangeEditorFirst,
} from '../api-structural-replace';
import { flushPendingBlockChanges } from '../block-sync-plugin';
import { setAsideRedoOf } from '../redo-branch';
import {
  getQuickUndoPausedOpId,
  getRegistry,
  getTypingCollector,
  receiveRedoOutcome,
  receiveUndoOutcome,
} from '../undo-coordinator';
import {
  automaticRewrite,
  EMPTY_BATCH,
  endOfNthParagraph,
  heading,
  idsInOrder,
  load,
  makeEditor,
  type Posted,
  para,
  pressRedo,
  pressUndo,
  type Spec,
  sleep,
  swiftFinishesRedo,
  swiftFinishesUndo,
  typeIntoNth,
} from './editor-first-harness';
import {
  endOfParagraphText,
  paragraphText,
  placeCaret,
  pressBackspaceAtBlockStart,
  pressEnter,
  startOfParagraph,
  texts,
  typeText,
} from './typing-across-undo-support';

const OP = 'ffffffff-1111-2222-3333-444444444444';

const DOC: Spec[] = [
  heading('c1h', 1, 'Chapter 1'),
  para('c1p', 'one'),
  heading('c2h', 1, 'Chapter 2'),
  para('c2p', 'two'),
  heading('c3h', 1, 'Chapter 3'),
  para('c3p', 'three'),
  heading('c4h', 1, 'Chapter 4'),
  para('c4p', 'four'),
];
const ORIGINAL = ['Chapter 1', 'one', 'Chapter 2', 'two', 'Chapter 3', 'three', 'Chapter 4', 'four'];

function blockTypeOf(md: string): string {
  return md.startsWith('#') ? 'heading' : 'paragraph';
}

function payloadOf(
  mode: ReplaceRangePayload['mode'],
  specs: Spec[],
  extra: Partial<ReplaceRangePayload> = {}
): ReplaceRangePayload {
  return {
    mode,
    markdown: specs.map((s) => s.md).join('\n\n'),
    blockIds: specs.map((s) => s.name),
    expectedBlocks: specs.map((s) => ({ blockType: blockTypeOf(s.md), nonEmpty: true })),
    managedIds: [],
    ...extra,
  };
}

function typingLines(posted: Posted): string[] {
  return posted
    .filter((p) => p.handler === 'errorHandler' && typeof p.body?.message === 'string')
    .map((p) => p.body.message as string)
    .filter((m) => m.startsWith('[STRUCT-TRACE] typing-since-press'))
    .map((m) => m.replace('[STRUCT-TRACE] ', ''));
}

/** The premise of every case: typing was recorded since the press, and the line the route wrote says `rebased` with at least one step. */
function expectRebasedPremise(posted: Posted, press = 1): void {
  expect(getTypingCollector().stepsSince(press).length, 'the collector recorded typing').toBeGreaterThanOrEqual(1);
  const lines = typingLines(posted);
  expect(lines[lines.length - 1]).toMatch(
    new RegExp(`^typing-since-press press=${press} steps=[1-9]\\d* decision=rebased$`)
  );
}

/** What the operation itself left pending is not what these tests are about. */
async function settle(): Promise<void> {
  await sleep(160);
  getBlockChangesApi();
}

function poll() {
  flushPendingBlockChanges();
  return getBlockChangesApi();
}

async function sceneWith(op: () => void | Promise<void>) {
  const made = await makeEditor();
  await load(DOC);
  await op();
  await settle();
  return made;
}

describe('typing across a waiting Cmd-Z: the quick undo', () => {
  it('W3: a Delete quick undo with typing (Return included) elsewhere during the wait is performed; the typing is sent once, by the replay', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    expect(deleteSectionEditorFirst(OP, 'c3h', []).ok).toBe(true);
    await settle();
    expect(texts(view)).toEqual(['Chapter 1', 'one', 'Chapter 2', 'two', 'Chapter 4', 'four']);
    expect(pressUndo(view, OP)).toBe(true);
    placeCaret(view, endOfParagraphText(view, 'one'));
    typeText(view, ' typed');
    expect(pressEnter(view)).toBe(true);
    typeText(view, 'more');

    const r = undoSectionDeleteEditorFirst(OP);

    expectRebasedPremise(posted);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.typingReplayed).toBe(true);
    expect(r.batch, 'the wait typing is NOT batch N: the replay is its only carrier').toEqual(EMPTY_BATCH);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one typed',
      'more',
      'Chapter 2',
      'two',
      'Chapter 3',
      'three',
      'Chapter 4',
      'four',
    ]);
    expect(view.state.selection.from, 'the caret follows the replayed text').toBe(endOfParagraphText(view, 'more'));
    swiftFinishesUndo(OP, { redoTopOpId: OP });

    const batch = poll();
    expect(batch.updates.map((u) => u.id)).toEqual(['c1p']);
    expect(batch.updates[0].textContent).toBe('one typed');
    expect(batch.inserts.length, 'the Return made one row, not two').toBe(1);
    expect(batch.inserts[0].textContent).toBe('more');
    expect(batch.deletes).toEqual([]);
    expect(poll()).toEqual(EMPTY_BATCH);
  });

  it('W4: a Duplicate quick undo with typing in the original (outside the copy) is performed: the copy goes, the typing stays', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    expect(duplicateSectionEditorFirst(OP, 'c2h', []).ok).toBe(true);
    await settle();
    expect(pressUndo(view, OP)).toBe(true);
    placeCaret(view, endOfNthParagraph(view, 'two', 0)); // the original: the copy follows it
    typeText(view, ' typed');
    expect(pressEnter(view)).toBe(true);
    typeText(view, 'more');

    const r = undoSectionDeleteEditorFirst(OP);

    expectRebasedPremise(posted);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.typingReplayed).toBe(true);
    expect(r.batch).toEqual(EMPTY_BATCH);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one',
      'Chapter 2',
      'two typed',
      'more',
      'Chapter 3',
      'three',
      'Chapter 4',
      'four',
    ]);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    const batch = poll();
    expect(batch.updates.map((u) => u.id)).toEqual(['c2p']);
    expect(batch.inserts.length).toBe(1);
    expect(poll()).toEqual(EMPTY_BATCH);
  });

  it('W5-route: typing INSIDE a duplicate copy becomes its own paragraph at the gap; the headings are unchanged', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    expect(duplicateSectionEditorFirst(OP, 'c2h', []).ok).toBe(true);
    await settle();
    expect(pressUndo(view, OP)).toBe(true);
    placeCaret(view, endOfNthParagraph(view, 'two', 1)); // the copy's paragraph
    typeText(view, 'xyz');

    const r = undoSectionDeleteEditorFirst(OP);

    expectRebasedPremise(posted);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.typingReplayed).toBe(true);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one',
      'Chapter 2',
      'two',
      'xyz',
      'Chapter 3',
      'three',
      'Chapter 4',
      'four',
    ]);
    const titles: string[] = [];
    view.state.doc.forEach((node) => {
      if (node.type.name === 'heading') titles.push(node.textContent);
    });
    expect(titles).toEqual(['Chapter 1', 'Chapter 2', 'Chapter 3', 'Chapter 4']);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    const batch = poll();
    expect(batch.inserts.length, 'the own paragraph is inserted once').toBe(1);
    expect(batch.inserts[0].textContent).toBe('xyz');
    expect(poll()).toEqual(EMPTY_BATCH);
  });

  describe('the three Version History restores', () => {
    const whole = () => payloadOf('whole', [heading('w1', 1, 'Whole'), para('w2', 'Whole body.')]);
    const section = () =>
      payloadOf('section', [heading('c2h', 1, 'Chapter 2 restored'), para('c2p2', 'two restored')], {
        rootBlockId: 'c2h',
      });
    const insertAfter = () =>
      payloadOf('insertAfter', [heading('ins', 1, 'Inserted'), para('insp', 'Inserted body.')], {
        anchorBlockId: 'c1p',
      });

    it('W6d: Restore Entire Project, typing inside the restored text: kept once, as its own paragraph at the EDGE of the changed run (never at the top of the document)', async () => {
      const { view, posted } = await makeEditor();
      await load(DOC);
      expect(replaceRangeEditorFirst(OP, whole()).ok).toBe(true);
      await settle();
      expect(texts(view)).toEqual(['Whole', 'Whole body.']);
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'Whole body'));
      typeText(view, 'XY');

      const r = undoSectionDeleteEditorFirst(OP);

      expectRebasedPremise(posted);
      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(r.typingReplayed).toBe(true);
      // Every block of the restored document is gone from the old one (no id matches), so the typing has no block to go into: it goes to
      // the EDGE of the changed run -- the end of the old document here, right after the text typed in -- and not to position 0.
      expect(texts(view)).toEqual([...ORIGINAL, 'XY']);
      swiftFinishesUndo(OP, { redoTopOpId: OP });
    });

    it('W6b: Replace Current Section, typing OUTSIDE the replaced text: put back where it was typed', async () => {
      const { view, posted } = await makeEditor();
      await load(DOC);
      expect(replaceRangeEditorFirst(OP, section()).ok).toBe(true);
      await settle();
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'four'));
      typeText(view, ' typed');
      expect(pressEnter(view)).toBe(true);
      typeText(view, 'more');

      const r = undoSectionDeleteEditorFirst(OP);

      expectRebasedPremise(posted);
      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(texts(view)).toEqual([
        'Chapter 1',
        'one',
        'Chapter 2',
        'two',
        'Chapter 3',
        'three',
        'Chapter 4',
        'four typed',
        'more',
      ]);
      swiftFinishesUndo(OP, { redoTopOpId: OP });
      const batch = poll();
      expect(batch.updates.map((u) => u.id)).toEqual(['c4p']);
      expect(batch.inserts.length).toBe(1);
      expect(poll()).toEqual(EMPTY_BATCH);
    });

    it('W6b-in: Replace Current Section, typing INSIDE the replaced text goes inside the surviving paragraph, at the edge of the changed run', async () => {
      const { view, posted } = await makeEditor();
      await load(DOC);
      expect(replaceRangeEditorFirst(OP, section()).ok).toBe(true);
      await settle();
      expect(texts(view)).toEqual([
        'Chapter 1',
        'one',
        'Chapter 2 restored',
        'two restored',
        'Chapter 3',
        'three',
        'Chapter 4',
        'four',
      ]);
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, startOfParagraph(view, 'two restored') + 'two rest'.length);
      typeText(view, 'XY');

      const r = undoSectionDeleteEditorFirst(OP);

      expectRebasedPremise(posted);
      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(r.typingReplayed).toBe(true);
      // "two restored" against "two": the changed run is " restored"; a position inside it goes to its edge. Mid-sentence is accepted.
      expect(texts(view)).toEqual([
        'Chapter 1',
        'one',
        'Chapter 2',
        'twoXY',
        'Chapter 3',
        'three',
        'Chapter 4',
        'four',
      ]);
      swiftFinishesUndo(OP, { redoTopOpId: OP });
      const batch = poll();
      expect(batch.updates.map((u) => u.id)).toEqual(['c2p']);
      expect(batch.updates[0].textContent).toBe('twoXY');
      expect(poll()).toEqual(EMPTY_BATCH);
    });

    it('W6c: Insert as New Section, typing outside it is put back, and typing inside it is its own paragraph at the gap', async () => {
      const { view, posted } = await makeEditor();
      await load(DOC);
      expect(replaceRangeEditorFirst(OP, insertAfter()).ok).toBe(true);
      await settle();
      expect(texts(view)).toEqual(['Chapter 1', 'one', 'Inserted', 'Inserted body.', ...ORIGINAL.slice(2)]);
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'four'));
      typeText(view, ' out');
      placeCaret(view, endOfParagraphText(view, 'Inserted body'));
      typeText(view, 'XY');

      const r = undoSectionDeleteEditorFirst(OP);

      expectRebasedPremise(posted);
      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(texts(view)).toEqual([
        'Chapter 1',
        'one',
        'XY',
        'Chapter 2',
        'two',
        'Chapter 3',
        'three',
        'Chapter 4',
        'four out',
      ]);
      swiftFinishesUndo(OP, { redoTopOpId: OP });
    });
  });

  describe('exits', () => {
    // After Delete of Chapter 3, Chapter 2's paragraph is followed by Chapter 4's heading. Backspace at the start of that heading joins
    // it into the paragraph; in the target Chapter 3 sits between them, so the step has no place there.
    async function sceneWithJoin() {
      const made = await sceneWith(() => {
        expect(deleteSectionEditorFirst(OP, 'c3h', []).ok).toBe(true);
      });
      expect(pressUndo(made.view, OP)).toBe(true);
      let headingStart = -1;
      made.view.state.doc.forEach((node, offset) => {
        if (headingStart === -1 && node.type.name === 'heading' && node.textContent === 'Chapter 4')
          headingStart = offset + 1;
      });
      placeCaret(made.view, headingStart);
      expect(pressBackspaceAtBlockStart(made.view)).toBe(true);
      expect(getTypingCollector().stepsSince(1).length, 'premise: the join was recorded').toBeGreaterThanOrEqual(1);
      return made;
    }

    it('D1-quick: a step the target has no place for refuses BEFORE anything is consumed or swapped; the typing goes out once when the latch ends', async () => {
      const { view, posted } = await sceneWithJoin();
      const docBefore = view.state.doc;
      const entryBefore = getRegistry().get(OP);
      const idsBefore = idsInOrder();

      const r = undoSectionDeleteEditorFirst(OP);

      expect(typingLines(posted).pop()).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=unplaceable$/);
      expect(r.ok).toBe(false);
      expect(r.reason).toBe('docChanged');
      expect(r.typingReplayed).toBeUndefined();
      expect(r.batch, 'nothing was consumed').toEqual(EMPTY_BATCH);
      expect(view.state.doc.eq(docBefore), 'nothing was swapped').toBe(true);
      expect(idsInOrder()).toEqual(idsBefore);
      expect(getRegistry().get(OP), 'the entry is untouched').toBe(entryBefore);
      expect(getQuickUndoPausedOpId()).toBeNull();
      flushPendingBlockChanges();
      expect(getBlockChangesApi(), 'held while the press is latched').toEqual(EMPTY_BATCH);
      receiveUndoOutcome(OP, 'failed');
      const batch = getBlockChangesApi();
      expect(
        batch.updates.length + batch.deletes.length,
        'the join goes out once the latch has ended'
      ).toBeGreaterThanOrEqual(1);
      expect(poll()).toEqual(EMPTY_BATCH);
    });

    it('D2-quick: a replay that goes wrong after the swap is put back; the held typing comes back as batch N, once', async () => {
      const { view, posted } = await sceneWith(() => {
        expect(deleteSectionEditorFirst(OP, 'c3h', []).ok).toBe(true);
      });
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'one'));
      typeText(view, ' typed');
      expect(getTypingCollector().stepsSince(1).length, 'premise: typing recorded').toBeGreaterThanOrEqual(1);
      const docBefore = view.state.doc;
      const idsBefore = idsInOrder();
      const entryBefore = getRegistry().get(OP);
      setTestAfterQuickReplayHook(() => {
        throw new Error('the replay went wrong');
      });

      try {
        const r = undoSectionDeleteEditorFirst(OP);
        expect(r.ok).toBe(false);
        expect(r.reason).toMatch(/exception: the replay went wrong/);
        expect(r.typingReplayed).toBeUndefined();
        expect(view.state.doc.eq(docBefore), 'the live document is back').toBe(true);
        expect(idsInOrder()).toEqual(idsBefore);
        expect(getRegistry().get(OP)).toBe(entryBefore);
        expect(getQuickUndoPausedOpId(), 'nothing left to resume').toBeNull();
        expect(r.batch.updates.map((u) => u.id)).toEqual(['c1p']);
        expect(r.batch.updates[0].textContent).toBe('one typed');
        // F21: an exception is not the final decision (Swift may retry the press on another road): no line from this attempt.
        expect(typingLines(posted)).toEqual([]);
      } finally {
        setTestAfterQuickReplayHook(null);
      }
      receiveUndoOutcome(OP, 'failed');
      expect(poll(), 'saved once: the baseline was reset after the batch was taken').toEqual(EMPTY_BATCH);
    });

    it('an automatic change right against the typed text cannot be unpicked (the order of the two is unknown): it still refuses with the existing reason, nothing consumed, the line saying changed', async () => {
      const { view, posted } = await sceneWith(() => {
        expect(deleteSectionEditorFirst(OP, 'c3h', []).ok).toBe(true);
      });
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'four'));
      typeText(view, ' typed');
      view.dispatch(
        view.state.tr.insertText(' CORR', endOfParagraphText(view, 'four')).setMeta('derivedCorrection', true)
      );
      expect(getTypingCollector().stepsSince(1).length, 'premise: the changes were recorded').toBeGreaterThanOrEqual(2);

      const r = undoSectionDeleteEditorFirst(OP);

      expect(r.ok).toBe(false);
      expect(r.reason).toBe('docChanged');
      expect(r.batch).toEqual(EMPTY_BATCH);
      expect(typingLines(posted).pop()).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=changed$/);
      expect(paragraphText(view, 'four')).toBe('four typed CORR');
      receiveUndoOutcome(OP, 'failed');
    });

    it('an automatic change alone during the wait (the saved copy follows it) is not a reason to refuse: the quick undo runs as before', async () => {
      const { view, posted } = await sceneWith(() => {
        expect(deleteSectionEditorFirst(OP, 'c3h', []).ok).toBe(true);
      });
      expect(pressUndo(view, OP)).toBe(true);
      view.dispatch(view.state.tr.insertText(' auto', endOfParagraphText(view, 'four')).setMeta('addToHistory', false));
      expect(getTypingCollector().stepsSince(1).length, 'premise: a step was recorded').toBeGreaterThanOrEqual(1);

      const r = undoSectionDeleteEditorFirst(OP);

      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(r.typingReplayed).toBeUndefined();
      expect(typingLines(posted)).toEqual(['typing-since-press press=1 steps=1 decision=matched']);
      swiftFinishesUndo(OP, { redoTopOpId: OP });
    });

    // Round 6 (R-2): the refusals that name their own reason write the line too, so a press always leaves one line.
    it.each([
      'noEntry',
      'midOp',
      'noIdMap',
    ] as const)('R2-quick-%s: the refusal writes `decision=%s`', async (reason) => {
      const { view, posted } = await sceneWith(() => {
        expect(deleteSectionEditorFirst(OP, 'c3h', []).ok).toBe(true);
      });
      expect(pressUndo(view, OP)).toBe(true);
      const entry = getRegistry().get(OP);
      expect(entry, 'premise: the op is registered').toBeDefined();
      if (!entry) return;
      if (reason === 'noEntry') getRegistry().delete(OP);
      else if (reason === 'midOp') getRegistry().set(OP, { ...entry, midOp: true });
      else getRegistry().set(OP, { ...entry, idMap: undefined });

      const r = undoSectionDeleteEditorFirst(OP);

      expect(r.ok).toBe(false);
      expect(r.reason).toBe(reason);
      expect(typingLines(posted)).toEqual([`typing-since-press press=1 steps=0 decision=${reason}`]);
      receiveUndoOutcome(OP, 'failed');
    });

    it('matched: a press with nothing typed writes the line and swaps as before', async () => {
      const { view, posted } = await sceneWith(() => {
        expect(deleteSectionEditorFirst(OP, 'c3h', []).ok).toBe(true);
      });
      expect(pressUndo(view, OP)).toBe(true);

      const r = undoSectionDeleteEditorFirst(OP);

      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(r.typingReplayed).toBeUndefined();
      expect(typingLines(posted)).toEqual(['typing-since-press press=1 steps=0 decision=matched']);
      swiftFinishesUndo(OP, { redoTopOpId: OP });
    });
  });
});

describe('typing across a waiting Cmd-Z: the quick redo', () => {
  // A quick redo is a FRESH editor-first command on the document as it stands: nothing is swapped in, so there is no replay
  // (`typingReplayed` stays false) and typing done elsewhere in the wait is simply kept. It is refused only when the typing sits inside
  // the text the redo takes out (the typed words would go with it).
  async function sceneAfterQuickUndo() {
    const made = await makeEditor();
    await load(DOC);
    expect(deleteSectionEditorFirst(OP, 'c3h', []).ok).toBe(true);
    await settle();
    expect(pressUndo(made.view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    await settle();
    expect(pressRedo(made.view, OP)).toBe(true);
    return made;
  }

  it('W16a: typing elsewhere in the wait does not end the redo: Delete runs again, the typing is kept and sent once, nothing is replayed', async () => {
    const { view, posted } = await sceneAfterQuickUndo();
    placeCaret(view, endOfParagraphText(view, 'four')); // Chapter 4: not the text the redo takes out
    typeText(view, ' typed');
    expect(
      getTypingCollector().stepsSince(2).length,
      'premise: typing recorded after the redo press'
    ).toBeGreaterThanOrEqual(1);

    const redo = redoSectionDeleteEditorFirst(OP, 'c3h', []);

    expect(redo.ok, `reason: ${redo.reason}`).toBe(true);
    expect((redo as { typingReplayed?: boolean }).typingReplayed, 'a quick redo replays nothing').toBeFalsy();
    expect(typingLines(posted).pop()).toMatch(/^typing-since-press press=2 steps=[1-9]\d* decision=rebased$/);
    expect(texts(view)).toEqual(['Chapter 1', 'one', 'Chapter 2', 'two', 'Chapter 4', 'four typed']);
    const sent = [...redo.batch.updates];
    swiftFinishesRedo(OP, { undoTopOpId: OP });
    sent.push(...poll().updates);
    expect(
      sent.filter((u) => u.id === 'c4p').map((u) => u.textContent),
      'the typing went out once, in the reply or the next poll'
    ).toEqual(['four typed']);
    expect(poll()).toEqual(EMPTY_BATCH);
  });

  it('W16b: typing INSIDE the chapter the redo takes out refuses it with the existing reason (the notice): nothing removed, the typing kept and sent once', async () => {
    const { view, posted } = await sceneAfterQuickUndo();
    placeCaret(view, endOfParagraphText(view, 'three')); // the very text the redo would take out
    typeText(view, ' typed');
    expect(
      getTypingCollector().stepsSince(2).length,
      'premise: typing recorded after the redo press'
    ).toBeGreaterThanOrEqual(1);
    const docBefore = view.state.doc;
    const entryBefore = getRegistry().get(OP);

    const redo = redoSectionDeleteEditorFirst(OP, 'c3h', []);

    expect(typingLines(posted).pop()).toMatch(/^typing-since-press press=2 steps=[1-9]\d* decision=unplaceable$/);
    expect(redo.ok).toBe(false);
    expect(redo.reason).toBe('docChanged');
    expect(view.state.doc.eq(docBefore), 'the typed text was not taken out with the section').toBe(true);
    expect(getRegistry().get(OP)).toBe(entryBefore);
    const sent = [...redo.batch.updates];
    receiveRedoOutcome(OP, 'failed');
    sent.push(...poll().updates);
    expect(
      sent.filter((u) => u.id === 'c3p').map((u) => u.textContent),
      'the typing went out once'
    ).toEqual(['three typed']);
    expect(poll()).toEqual(EMPTY_BATCH);
  });

  it('F11: a Backspace (a pure deletion) inside the chapter the redo takes out does not refuse it: no typed words go with the chapter', async () => {
    const { view } = await sceneAfterQuickUndo();
    const end = endOfParagraphText(view, 'three');
    view.dispatch(view.state.tr.delete(end - 1, end)); // Backspace at the end of "three"
    expect(paragraphText(view, 'thre')).toBe('thre');
    expect(
      getTypingCollector().stepsSince(2).length,
      'premise: the deletion was recorded after the redo press'
    ).toBeGreaterThanOrEqual(1);

    const redo = redoSectionDeleteEditorFirst(OP, 'c3h', []);

    expect(redo.ok, `reason: ${redo.reason}`).toBe(true);
    expect(texts(view)).toEqual(['Chapter 1', 'one', 'Chapter 2', 'two', 'Chapter 4', 'four']);
    swiftFinishesRedo(OP, { undoTopOpId: OP });
  });

  it('F10: a quick redo that had typing in its wait does not put the redo steps kept aside back, even when the redo list happens to have the same length again', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const first = duplicateSectionEditorFirst(OP, 'c2h', []);
    expect(first.ok).toBe(true);
    await settle();
    typeIntoNth(view, 'two', 1, ' inside'); // typing inside the copy ...
    expect(undo(view.state, view.dispatch)).toBe(true); // ... taken back by a text undo: one redoable event
    expect(redoDepth(view.state), 'premise: the typing is redoable').toBe(1);
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    await settle();
    const record = setAsideRedoOf(OP);
    expect(record?.depthAfterUndo, 'premise: the quick undo kept one redo event aside').toBe(1);
    expect(pressRedo(view, OP)).toBe(true);
    // In the redo's wait the user types and takes it back with a text undo: typing ends every pending redo (the old redo steps are
    // gone), and the redo list is one event long again, the same length the record expects.
    placeCaret(view, endOfParagraphText(view, 'four'));
    typeText(view, ' typed');
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(redoDepth(view.state), 'premise: the list is as long as the record expects').toBe(1);
    expect(paragraphText(view, 'four')).toBe('four');

    const redo = redoSectionDuplicateEditorFirst(OP, 'c2h', [], first.copies);

    expect(redo.ok, `reason: ${redo.reason}`).toBe(true);
    expect(setAsideRedoOf(OP), 'the record is gone').toBeUndefined();
    expect(redoDepth(view.state), "the redo list is the user's own undone typing, not the steps kept aside").toBe(1);
    expect(historyRedo(view.state, view.dispatch), "Cmd-Shift-Z redoes the user's own typing").toBe(true);
    expect(paragraphText(view, 'four')).toBe('four typed');
    expect(view.state.doc.textContent, 'and not the typing inside the copy that the old redo steps held').not.toContain(
      'inside'
    );
    swiftFinishesRedo(OP, { undoTopOpId: OP });
  });

  it('W16c: a HELD Cmd-Shift-Z of a quick redo that the user typed after (elsewhere) is not ended: it is routed, it runs, the typing is kept', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    expect(deleteSectionEditorFirst(OP, 'c3h', []).ok).toBe(true);
    await settle();
    expect(pressUndo(view, OP)).toBe(true); // press 1: the quick undo
    expect(pressRedo(view, OP)).toBe(true); // press 2: held behind it
    placeCaret(view, endOfParagraphText(view, 'four'));
    typeText(view, ' typed'); // after press 2
    expect(
      getTypingCollector().stepsSince(2).length,
      'premise: typing recorded after the held redo'
    ).toBeGreaterThanOrEqual(1);

    const undone = undoSectionDeleteEditorFirst(OP);
    expect(undone.ok, `reason: ${undone.reason}`).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP }); // the reply releases press 1 and routes the held press

    const dropped = posted.filter((p) => p.handler === 'undoQueueDropped').map((p) => p.body);
    expect(dropped, 'the held redo was not ended by the typing').toEqual([]);
    expect(posted.filter((p) => p.handler === 'structuralRedoRequested').map((p) => p.body)).toEqual([
      { opId: OP, held: true },
    ]);
    const redo = redoSectionDeleteEditorFirst(OP, 'c3h', []);
    expect(redo.ok, `reason: ${redo.reason}`).toBe(true);
    expect(typingLines(posted).pop()).toMatch(/^typing-since-press press=2 steps=[1-9]\d* decision=rebased$/);
    expect(texts(view)).toEqual(['Chapter 1', 'one', 'Chapter 2', 'two', 'Chapter 4', 'four typed']);
    swiftFinishesRedo(OP, { undoTopOpId: OP });
  });

  it('a redo with nothing typed in its wait writes the matched line and runs as before', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    expect(deleteSectionEditorFirst(OP, 'c3h', []).ok).toBe(true);
    await settle();
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    await settle();
    expect(pressRedo(view, OP)).toBe(true);

    const redo = redoSectionDeleteEditorFirst(OP, 'c3h', []);

    expect(redo.ok, `reason: ${redo.reason}`).toBe(true);
    expect(typingLines(posted).pop()).toBe('typing-since-press press=2 steps=0 decision=matched');
    swiftFinishesRedo(OP, { undoTopOpId: OP });
  });
});

// Round 6 (R-1): the `ok: true` reply of every Rich Text quick redo says whether the user TYPED since the key was pressed (`typed`, the
// page's own answer from the redo's gate). Swift ends the older redo entries only on `typed === true`: a non-empty batch is not proof of
// typing, it can hold a rewrite the previous command's settle left.
describe('the quick redo reply says whether the user typed (R-1)', () => {
  const sectionPayload = () =>
    payloadOf('section', [heading('c2h', 1, 'Chapter 2 restored'), para('c2p2', 'two restored')], {
      rootBlockId: 'c2h',
    });

  type Redo = () => { ok: boolean; reason?: string; typed?: boolean; batch: { updates: Array<{ id: string }> } };
  interface Scene {
    view: Awaited<ReturnType<typeof makeEditor>>['view'];
    redo: Redo;
  }

  /** The operation is done, undone by the quick undo, and Cmd-Shift-Z is pressed (the redo's latch is held). */
  async function delete_(): Promise<Scene> {
    const { view } = await makeEditor();
    await load(DOC);
    expect(deleteSectionEditorFirst(OP, 'c3h', []).ok).toBe(true);
    await settle();
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    await settle();
    expect(pressRedo(view, OP)).toBe(true);
    return { view, redo: () => redoSectionDeleteEditorFirst(OP, 'c3h', []) };
  }
  async function duplicate(): Promise<Scene> {
    const { view } = await makeEditor();
    await load(DOC);
    const first = duplicateSectionEditorFirst(OP, 'c2h', []);
    expect(first.ok).toBe(true);
    await settle();
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    await settle();
    expect(pressRedo(view, OP)).toBe(true);
    return { view, redo: () => redoSectionDuplicateEditorFirst(OP, 'c2h', [], first.copies) };
  }
  async function restore(): Promise<Scene> {
    const { view } = await makeEditor();
    await load(DOC);
    expect(replaceRangeEditorFirst(OP, sectionPayload()).ok).toBe(true);
    await settle();
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    await settle();
    expect(pressRedo(view, OP)).toBe(true);
    return { view, redo: () => redoReplaceRangeEditorFirst(OP, sectionPayload()) };
  }

  const routes: Array<[string, () => Promise<Scene>]> = [
    ['Delete Section', delete_],
    ['Duplicate Section', duplicate],
    ['Restore (replace a section)', restore],
  ];

  it.each(
    routes
  )('R1-%s (a): a rewrite that is not typing is pending in the batch, nothing was typed: typed is false', async (_name, make) => {
    const { view, redo } = await make();
    automaticRewrite(view, 'four', ' (rewritten)'); // not typing: addToHistory false, left in the batch for the redo to take
    expect(
      getTypingCollector()
        .stepsSince(2)
        .filter((recorded) => recorded.typing),
      'premise: no step since the press is typing'
    ).toEqual([]);
    expect(getTypingCollector().stepsSince(2).length, 'premise: the rewrite was recorded').toBeGreaterThanOrEqual(1);

    const reply = redo();

    expect(reply.ok, `reason: ${reply.reason}`).toBe(true);
    expect(
      reply.batch.updates.map((u) => u.id),
      'premise: the non-typing rewrite is in the batch'
    ).toContain('c4p');
    expect(reply.typed).toBe(false);
  });

  it.each(routes)('R1-%s (b): typing outside the text the redo takes out: typed is true', async (_name, make) => {
    const { view, redo } = await make();
    placeCaret(view, endOfParagraphText(view, 'four'));
    typeText(view, ' typed');
    expect(
      getTypingCollector()
        .stepsSince(2)
        .filter((recorded) => recorded.typing).length,
      'premise: typing recorded after the redo press'
    ).toBeGreaterThanOrEqual(1);

    const reply = redo();

    expect(reply.ok, `reason: ${reply.reason}`).toBe(true);
    expect(reply.typed).toBe(true);
  });

  it('R1-refused: a refused redo carries no typed field', async () => {
    const { view, redo } = await delete_();
    placeCaret(view, endOfParagraphText(view, 'three')); // inside the chapter the redo takes out
    typeText(view, ' typed');

    const reply = redo();

    expect(reply.ok).toBe(false);
    expect(reply.typed).toBeUndefined();
  });
});
