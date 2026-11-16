// @vitest-environment jsdom
//
// Typing done while a Cmd-Z waits (Phase 4c, job 2, t-d2061b27), round 2a: the coordinator and the SLOW route
// (`structuralSwapEditorFirst`, api-structural-swap.ts) with the real routes, the real plugins and the real Swift-facing calls:
//
//   * the press records its steps (typing-rebase.ts collector, registered as a plugin in the harness as in main.ts);
//   * while a press is latched, what the user types is held back from the page's reports (in the poll's time: from Swift's polls, via the
//     removed `hasBlockChanges` / `getBlockChanges` bridge), and every way the latch ends lets it go out once (D1);
//   * at the re-check the route compares the document AS IT WAS WHEN THE KEY WAS PRESSED, writes the trace line
//     `typing-since-press press=P steps=N decision=...` whatever the outcome, tries the replay against the target before the swap
//     (only a truly unplaceable step refuses, before the swap) and dispatches it after the swap; the reply says `typingReplayed`;
//   * held presses (Cmd-Z, Cmd-Shift-Z pressed while the first waits) act on the document as it was at THEIR press (amendment 5, D3).
//
// Swift's side of the conversation is played by the test, as in slow-swap-editor-first.test.ts. Each case FIRST asserts the premise:
// the collector recorded steps and (where the route runs) the trace line says so.

import type { EditorView } from '@milkdown/kit/prose/view';
import { describe, expect, it, vi } from 'vitest';
import { releaseHeldTypingAndGetBatch, setContentWithBlockIds } from '../api-content';
import { deleteSectionEditorFirst } from '../api-section-delete';
import { type StructuralSwapPayload, setTestAfterReplayHook, structuralSwapEditorFirst } from '../api-structural-swap';
import { bibliographyEndMarkerPlugin } from '../bibliography-end-marker-plugin';
import { bibliographyPlugin } from '../bibliography-plugin';
import { flushPendingBlockChanges } from '../block-sync-plugin';
import { footnotePlugin } from '../footnote-plugin';
import {
  getRegistry,
  getTypingCollector,
  isTypingPushHeld,
  receiveUndoOutcome,
  releaseHeldTypingPushes,
  setUndoDescriptor,
} from '../undo-coordinator';
import {
  automaticRewrite,
  EMPTY_BATCH,
  endOfParagraph,
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
  typeInto,
  waitForRAF,
} from './editor-first-harness';
import { hasReportablePending, takePendingAsReport } from './pending-for-test';
import {
  endOfParagraphText,
  paragraphText,
  placeCaret,
  pressBackspaceAtBlockStart,
  pressEnter,
  replaceBlockNode,
  rewriteBlocks,
  runRegisteredOp,
  startOfParagraph,
  texts,
  typeText,
} from './typing-across-undo-support';

const OP = 'eeeeeeee-1111-2222-3333-444444444444';
const OP_A = 'aaaaaaaa-1111-2222-3333-444444444444';
const OP_B = 'bbbbbbbb-1111-2222-3333-444444444444';
const OP_C = 'cccccccc-1111-2222-3333-444444444444';

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
/** Chapter 4 dragged above Chapter 2. */
const AFTER_DRAG = ['c1h', 'c1p', 'c4h', 'c4p', 'c2h', 'c2p', 'c3h', 'c3p'];

function blockTypeOf(md: string): string {
  return md.startsWith('#') ? 'heading' : 'paragraph';
}

/** What Swift's `editorPayload(for: planRows)` gives for these blocks: the ids of the snapshot rows, which for a delete, a duplicate and
 * a drag are the ids the blocks had before the operation (so, the editor's own). `prefix` makes them fresh, as the rows of a restore are. */
function payloadFor(specs: Spec[], prefix = ''): StructuralSwapPayload {
  return {
    blockIds: specs.map((s) => `${prefix}${s.name}`),
    expectedBlocks: specs.map((s) => ({ blockType: blockTypeOf(s.md), nonEmpty: true })),
    managedBlockIds: [],
  };
}
const specsOf = (names: string[]): Spec[] => names.map((name) => DOC.find((s) => s.name === name) as Spec);

const dragOp = (view: EditorView) => () => rewriteBlocks(view, AFTER_DRAG);

/** The trace lines `typing-since-press ...` the route wrote, oldest first. */
function typingLines(posted: Posted): string[] {
  return posted
    .filter((p) => p.handler === 'errorHandler' && typeof p.body?.message === 'string')
    .map((p) => p.body.message as string)
    .filter((m) => m.startsWith('[STRUCT-TRACE] typing-since-press'))
    .map((m) => m.replace('[STRUCT-TRACE] ', ''));
}

const messagesOf = (posted: Posted, handler: string) => posted.filter((p) => p.handler === handler).map((p) => p.body);

/** The slow route's own trace lines (`swap-editor-first ...`), oldest first. */
function swapTraceLines(posted: Posted): string[] {
  return posted
    .filter((p) => p.handler === 'errorHandler' && typeof p.body?.message === 'string')
    .map((p) => p.body.message as string)
    .filter((m) => m.startsWith('[STRUCT-TRACE] swap-editor-first'));
}

/** The premise of every case: typing was recorded since the press, and the line the route wrote says `rebased` with at least one step. */
function expectRebasedPremise(posted: Posted, press = 1): void {
  expect(getTypingCollector().stepsSince(press).length, 'the collector recorded typing').toBeGreaterThanOrEqual(1);
  const lines = typingLines(posted);
  expect(lines.length, 'the route wrote the typing line').toBeGreaterThanOrEqual(1);
  const swapTrace = posted
    .map((p) => p.body?.message)
    .filter((m): m is string => typeof m === 'string' && m.includes('swap-editor-first'))
    .pop();
  expect(lines[lines.length - 1], swapTrace).toMatch(
    new RegExp(`^typing-since-press press=${press} steps=[1-9]\\d* decision=rebased$`)
  );
}

/** What Swift does after a slow undo: push the descriptor, reply (the reply releases the in-flight latch and routes held presses). */
function swiftReplies(opId: string, descriptor: { undoTopOpId?: string; redoTopOpId?: string }): void {
  setUndoDescriptor(descriptor);
  receiveUndoOutcome(opId, 'performed');
}

async function sceneWithDrag() {
  const { view, posted } = await makeEditor();
  await load(DOC);
  runRegisteredOp(view, OP, dragOp(view));
  expect(texts(view)).toEqual(['Chapter 1', 'one', 'Chapter 4', 'four', 'Chapter 2', 'two', 'Chapter 3', 'three']);
  return { view, posted };
}

describe('typing across a waiting Cmd-Z: the slow route', () => {
  it('W1: a drag undo with typing in another chapter during the wait is performed, the typing lands where it was typed, the caret follows', async () => {
    const { view, posted } = await sceneWithDrag();
    expect(pressUndo(view, OP)).toBe(true);
    placeCaret(view, endOfParagraphText(view, 'two'));
    typeText(view, ' typed');
    const live = view.state.doc;

    const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));

    expectRebasedPremise(posted);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.typingReplayed).toBe(true);
    expect(r.batch, 'the replay is the only carrier of the wait typing: no batch N').toEqual(EMPTY_BATCH);
    expect(view.state.doc.eq(live)).toBe(false);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one',
      'Chapter 2',
      'two typed',
      'Chapter 3',
      'three',
      'Chapter 4',
      'four',
    ]);
    expect(view.state.selection.from, 'the caret is after the replayed text').toBe(
      endOfParagraphText(view, 'two typed')
    );
    swiftReplies(OP, { redoTopOpId: OP });

    // Saved once, by the replay: the next report has exactly this one update, and then nothing.
    flushPendingBlockChanges();
    const batch = takePendingAsReport();
    expect(batch.updates.map((u) => u.id)).toEqual(['c2p']);
    expect(batch.updates[0].textContent).toBe('two typed');
    expect(batch.inserts).toEqual([]);
    expect(batch.deletes).toEqual([]);
    expect(takePendingAsReport()).toEqual(EMPTY_BATCH);
  });

  it('W1b: a Return in the wait makes one new row, saved once', async () => {
    const { view, posted } = await sceneWithDrag();
    expect(pressUndo(view, OP)).toBe(true);
    placeCaret(view, endOfParagraphText(view, 'two'));
    typeText(view, ' x');
    expect(pressEnter(view)).toBe(true);
    typeText(view, 'more');

    const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));

    expectRebasedPremise(posted);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one',
      'Chapter 2',
      'two x',
      'more',
      'Chapter 3',
      'three',
      'Chapter 4',
      'four',
    ]);
    swiftReplies(OP, { redoTopOpId: OP });
    flushPendingBlockChanges();
    const batch = takePendingAsReport();
    expect(batch.inserts.length, 'the new paragraph is inserted once, not twice').toBe(1);
    expect(batch.inserts[0].textContent).toBe('more');
    expect(takePendingAsReport()).toEqual(EMPTY_BATCH);
  });

  it('W9-route: a letter typed straight after the swap lands right after the replayed text', async () => {
    const { view, posted } = await sceneWithDrag();
    expect(pressUndo(view, OP)).toBe(true);
    placeCaret(view, endOfParagraphText(view, 'two'));
    typeText(view, ' ab');

    const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));
    expectRebasedPremise(posted);
    expect(r.ok).toBe(true);
    swiftReplies(OP, { redoTopOpId: OP });
    typeText(view, 'Q');

    expect(paragraphText(view, 'two')).toBe('two abQ');
  });

  describe('the hold: while a press is latched, what is typed is not pushed', () => {
    it("H1: nothing typed leaves through Swift's polls while latched; it goes out once when the latch ends", async () => {
      const { view } = await sceneWithDrag();
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'two'));
      typeText(view, ' typed');
      flushPendingBlockChanges();
      expect(getTypingCollector().stepsSince(1).length, 'premise: typing recorded').toBeGreaterThanOrEqual(1);

      expect(isTypingPushHeld()).toBe(true);
      expect(hasReportablePending()).toBe(false);
      expect(takePendingAsReport()).toEqual(EMPTY_BATCH);

      receiveUndoOutcome(OP, 'failed');
      expect(isTypingPushHeld()).toBe(false);
      expect(hasReportablePending()).toBe(true);
      const batch = takePendingAsReport();
      expect(batch.updates.map((u) => u.id)).toEqual(['c2p']);
      expect(batch.updates[0].textContent).toBe('two typed');
      expect(takePendingAsReport()).toEqual(EMPTY_BATCH);
    });

    it.each([
      'cancelled',
      'failed',
    ] as const)('D1: a %s reply releases the held typing as the next batch, exactly once', async (outcome) => {
      const { view } = await sceneWithDrag();
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'two'));
      typeText(view, ' typed');
      flushPendingBlockChanges();
      expect(getTypingCollector().stepsSince(1).length, 'premise: typing recorded').toBeGreaterThanOrEqual(1);
      expect(takePendingAsReport(), 'held while latched').toEqual(EMPTY_BATCH);

      receiveUndoOutcome(OP, outcome);

      expect(isTypingPushHeld()).toBe(false);
      const batch = takePendingAsReport();
      expect(batch.updates.map((u) => u.id)).toEqual(['c2p']);
      expect(batch.updates[0].textContent).toBe('two typed');
      expect(takePendingAsReport()).toEqual(EMPTY_BATCH);
      expect(getTypingCollector().isRecording, 'the collector is reset on this exit').toBe(false);
    });

    it('D1: the 30 s latch timeout releases the held typing as the next batch, exactly once', async () => {
      const { view } = await sceneWithDrag();
      vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
      try {
        expect(pressUndo(view, OP)).toBe(true);
        placeCaret(view, endOfParagraphText(view, 'two'));
        typeText(view, ' typed');
        expect(getTypingCollector().stepsSince(1).length, 'premise: typing recorded').toBeGreaterThanOrEqual(1);
        vi.advanceTimersByTime(30_000);
      } finally {
        vi.useRealTimers(); // the harness's cleanup sleeps on a real timer
      }
      flushPendingBlockChanges();

      expect(isTypingPushHeld()).toBe(false);
      const batch = takePendingAsReport();
      expect(batch.updates.map((u) => u.id)).toEqual(['c2p']);
      expect(takePendingAsReport()).toEqual(EMPTY_BATCH);
      expect(getTypingCollector().isRecording).toBe(false);
    });

    it('D1: the lifecycle flush ends the hold, sees the typing, and the press that follows is refused (already sent)', async () => {
      const { view, posted } = await sceneWithDrag();
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'two'));
      typeText(view, ' typed');
      flushPendingBlockChanges();
      expect(getTypingCollector().stepsSince(1).length, 'premise: typing recorded').toBeGreaterThanOrEqual(1);

      expect(releaseHeldTypingPushes()).toBe(true);
      const batch = takePendingAsReport();
      expect(batch.updates.map((u) => u.id)).toEqual(['c2p']);

      // Sent once already: the replay would save it a second time, so the press refuses and keeps the document.
      const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));
      expect(r.ok).toBe(false);
      expect(r.reason).toBe('docChanged');
      expect(typingLines(posted).pop()).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=changed$/);
      expect(r.batch, 'nothing is sent a second time').toEqual(EMPTY_BATCH);
    });
  });

  describe('refusals before the swap keep the typing and save it once', () => {
    const JOIN_DOC: Spec[] = [
      heading('h', 1, 'Chapter'),
      para('a', 'alpha'),
      para('between', 'between'),
      para('b', 'beta'),
    ];

    it('W13-route: a step the target has no place for is refused BEFORE the swap; the document is the live one; the typing is in the batch once', async () => {
      const { view, posted } = await makeEditor();
      await load(JOIN_DOC);
      runRegisteredOp(view, OP, () => rewriteBlocks(view, ['h', 'a', 'b']));
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, startOfParagraph(view, 'beta'));
      expect(pressBackspaceAtBlockStart(view)).toBe(true); // joins beta onto alpha: in the target "between" sits between them
      expect(getTypingCollector().stepsSince(1).length, 'premise: the join was recorded').toBeGreaterThanOrEqual(1);
      const docBefore = view.state.doc;
      const entryBefore = getRegistry().get(OP);
      const idsBefore = idsInOrder();

      const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(JOIN_DOC));

      expect(typingLines(posted).pop()).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=unplaceable$/);
      expect(r.ok).toBe(false);
      expect(r.reason).toBe('docChanged');
      expect(r.typingReplayed).toBeUndefined();
      expect(view.state.doc.eq(docBefore), 'nothing was swapped').toBe(true);
      expect(idsInOrder()).toEqual(idsBefore);
      expect(getRegistry().get(OP), 'the entry stays recorded, untouched').toBe(entryBefore);
      expect(r.batch.updates.map((u) => u.id)).toEqual(['a']);
      expect(r.batch.updates[0].textContent).toBe('alphabeta');
      expect(r.batch.deletes).toEqual(['b']);
      receiveUndoOutcome(OP, 'failed'); // Swift: refuse with the notice, release the latch
      flushPendingBlockChanges();
      expect(takePendingAsReport(), 'the typing was sent once, with the batch').toEqual(EMPTY_BATCH);
    });

    it('W7-route: a Backspace that joins two paragraphs which are ALSO adjacent in the target is placed there: one joined paragraph, once', async () => {
      const ADJACENT: Spec[] = [
        heading('h', 1, 'Chapter'),
        para('a', 'alpha'),
        para('b', 'beta'),
        heading('h2', 1, 'Chapter 2'),
        para('p2', 'two'),
      ];
      const { view, posted } = await makeEditor();
      await load(ADJACENT);
      runRegisteredOp(view, OP, () => rewriteBlocks(view, ['h', 'a', 'b'])); // Delete Chapter 2
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, startOfParagraph(view, 'beta'));
      expect(pressBackspaceAtBlockStart(view)).toBe(true);
      expect(getTypingCollector().stepsSince(1).length, 'premise: the join was recorded').toBeGreaterThanOrEqual(1);
      expect(texts(view)).toEqual(['Chapter', 'alphabeta']);

      const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(ADJACENT));

      expectRebasedPremise(posted);
      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(r.typingReplayed).toBe(true);
      expect(texts(view)).toEqual(['Chapter', 'alphabeta', 'Chapter 2', 'two']);
    });

    it('D2: a replay that goes wrong after the swap is put back, and the typing is still sent once (batch N before the baseline reset)', async () => {
      const { view, posted } = await sceneWithDrag();
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'two'));
      typeText(view, ' typed');
      expect(getTypingCollector().stepsSince(1).length, 'premise: typing recorded').toBeGreaterThanOrEqual(1);
      const docBefore = view.state.doc;
      const idsBefore = idsInOrder();
      const entryBefore = getRegistry().get(OP);
      setTestAfterReplayHook(() => {
        throw new Error('the replay went wrong');
      });

      try {
        const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));
        expect(r.ok).toBe(false);
        // F13: `exception: ...` would make Swift run the old restore body, which silently drops the typing. The press is refused with
        // the notice instead; the exception text is in the trace line only.
        expect(r.reason).toBe('docChanged');
        expect(swapTraceLines(posted).pop()).toMatch(/reason=docChanged detail=exception: the replay went wrong/);
        expect(r.typingReplayed).toBeUndefined();
        expect(view.state.doc.eq(docBefore), 'the live document is back').toBe(true);
        expect(idsInOrder()).toEqual(idsBefore);
        expect(getRegistry().get(OP)).toBe(entryBefore);
        expect(
          r.batch.updates.map((u) => u.id),
          'the typing comes back as batch N'
        ).toEqual(['c2p']);
        expect(r.batch.updates[0].textContent).toBe('two typed');
        // F21: the rebase was decided at the dry run but the typing was not put back: ONE line, the final decision.
        expect(typingLines(posted)).toHaveLength(1);
        expect(typingLines(posted)[0]).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=unplaceable$/);
      } finally {
        setTestAfterReplayHook(null);
      }
      receiveUndoOutcome(OP, 'failed');
      flushPendingBlockChanges();
      expect(takePendingAsReport(), 'saved once: the baseline was reset after the batch was taken').toEqual(
        EMPTY_BATCH
      );
    });

    it('F13: a replay that does not give the document the dry run built is refused with docChanged: nothing swapped, the typing comes back in the batch', async () => {
      const { view, posted } = await sceneWithDrag();
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'two'));
      typeText(view, ' typed');
      expect(getTypingCollector().stepsSince(1).length, 'premise: typing recorded').toBeGreaterThanOrEqual(1);
      const docBefore = view.state.doc;
      const idsBefore = idsInOrder();
      const entryBefore = getRegistry().get(OP);
      setTestAfterReplayHook(() => {
        // Something else changes the document between the replay and the check: the document is not the one the dry run built.
        view.dispatch(view.state.tr.insertText('!', 1).setMeta('addToHistory', false));
      });

      try {
        const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));
        expect(r.ok).toBe(false);
        expect(r.reason).toBe('docChanged');
        expect(swapTraceLines(posted).pop()).toMatch(
          /reason=docChanged detail=the replay did not produce the document/
        );
        expect(view.state.doc.eq(docBefore), 'nothing was swapped: the live document is back').toBe(true);
        expect(idsInOrder()).toEqual(idsBefore);
        expect(getRegistry().get(OP)).toBe(entryBefore);
        expect(r.batch.updates.map((u) => u.id)).toEqual(['c2p']);
        expect(r.batch.updates[0].textContent).toBe('two typed');
      } finally {
        setTestAfterReplayHook(null);
      }
      receiveUndoOutcome(OP, 'failed');
    });
  });

  describe('W14-route: the trace line is written whatever the outcome', () => {
    it('matched: no typing since the press', async () => {
      const { view, posted } = await sceneWithDrag();
      expect(pressUndo(view, OP)).toBe(true);

      const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));

      expect(r.ok).toBe(true);
      expect(r.typingReplayed).toBeUndefined();
      expect(typingLines(posted)).toEqual(['typing-since-press press=1 steps=0 decision=matched']);
    });

    // The commute (typing-rebase.ts `computeCommute`) refuses in two separate places: guard B, the final check "the rebased typing on
    // top of the result is the live document" (an automatic change that touches the typed spot without replacing text: the order of the
    // two cannot be told apart, this test), and guard A, the null map in `rebaseTypingOver` (the typing lay strictly INSIDE text the
    // automatic change replaced, the next test). Each guard has its own PURE test and break patch (typing-across-undo.test.ts, C2 and
    // C3); at the route level the saved-copy comparison refuses these presses too, so these two only show the end result.
    it('changed (final check): the user typed and an automatic change landed right against the typed text (the order of the two cannot be told)', async () => {
      const { view, posted } = await sceneWithDrag();
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'two'));
      typeText(view, ' x');
      view.dispatch(view.state.tr.insertText(' auto').setMeta('addToHistory', false)); // an automatic rewrite, at the typed spot
      expect(getTypingCollector().stepsSince(1).length, 'premise: steps were recorded').toBeGreaterThanOrEqual(3);

      const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));

      expect(r.ok).toBe(false);
      expect(r.reason).toBe('docChanged');
      expect(typingLines(posted)).toEqual(['typing-since-press press=1 steps=3 decision=changed']);
    });

    it('changed (no place for the typing): the user typed INSIDE text that an automatic change then rewrote', async () => {
      const { view, posted } = await sceneWithDrag();
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, startOfParagraph(view, 'two') + 2); // tw|o
      typeText(view, 'x');
      expect(paragraphText(view, 'twxo')).toBe('twxo');
      const from = startOfParagraph(view, 'twxo');
      view.dispatch(
        view.state.tr
          .replaceWith(from, endOfParagraphText(view, 'twxo'), view.state.schema.text('TWO'))
          .setMeta('addToHistory', false)
      ); // a rebuild that writes the paragraph again: the typed letter sat inside the text it replaced
      expect(getTypingCollector().stepsSince(1).length, 'premise: the typing and the rewrite were recorded').toBe(2);

      const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));

      expect(r.ok).toBe(false);
      expect(r.reason).toBe('docChanged');
      expect(typingLines(posted)).toEqual(['typing-since-press press=1 steps=2 decision=changed']);
    });

    it('an automatic change alone during the wait (the saved copy follows it) is not a reason to refuse: the press swaps as before', async () => {
      const { view, posted } = await sceneWithDrag();
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'two'));
      view.dispatch(view.state.tr.insertText(' auto').setMeta('addToHistory', false)); // a Notes or bibliography rebuild, say
      expect(getTypingCollector().stepsSince(1).length, 'premise: a step was recorded').toBeGreaterThanOrEqual(1);

      const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));

      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(r.typingReplayed).toBeUndefined();
      expect(typingLines(posted)).toEqual(['typing-since-press press=1 steps=1 decision=matched']);
      expect(texts(view)).toEqual(['Chapter 1', 'one', 'Chapter 2', 'two', 'Chapter 3', 'three', 'Chapter 4', 'four']);
    });

    // F21: ONE line per press, at its FINAL decision. A refusal that Swift hands to another road (an id mismatch, an exception) writes
    // no line: that road decides, and an earlier line from this attempt would be a second line for the same press. The refusals that
    // name their own reason (round 6, R-2: no registry entry, entry mid-operation, no id map) are final and write their line.
    it('noEntry (nothing registered for the op): the line says noEntry', async () => {
      const { view, posted } = await sceneWithDrag();
      expect(pressUndo(view, OP)).toBe(true);
      getRegistry().delete(OP);

      const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));

      expect(r.reason).toBe('noCheckpoint');
      expect(typingLines(posted)).toEqual(['typing-since-press press=1 steps=0 decision=noEntry']);
    });

    it('F21: a refusal that is retried (a payload that does not fit, then the right one) leaves ONE line, the final decision', async () => {
      const { view, posted } = await sceneWithDrag();
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, endOfParagraphText(view, 'two'));
      typeText(view, ' typed');

      const refused = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC.slice(0, -1))); // one block too few
      expect(refused.reason).toBe('idAlignment');
      expect(typingLines(posted), 'a refusal Swift hands to another road writes no line').toEqual([]);

      const retried = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));
      expect(retried.ok, `reason: ${retried.reason}`).toBe(true);
      expect(typingLines(posted)).toHaveLength(1);
      expect(typingLines(posted)[0]).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=rebased$/);
    });
  });

  describe('W6c-route: typing in the text a restore replaced', () => {
    // A restore gives the blocks it brings back fresh ids (only a section's root heading keeps its own), so no block matches by id.
    // Blocks of the same type that sit between the same anchors are the same block with changed content (restore pairing).
    it('a restore replaced a block with a block of the same type: the typing goes INSIDE the surviving block, at the edge of the changed run', async () => {
      const { view, posted } = await makeEditor();
      await load(DOC);
      const schema = view.state.schema;
      runRegisteredOp(view, OP, () =>
        replaceBlockNode(view, 'c2p', 'c2p-restored', schema.nodes.paragraph.create(null, schema.text('restored two')))
      );
      expect(texts(view)).toEqual([
        'Chapter 1',
        'one',
        'Chapter 2',
        'restored two',
        'Chapter 3',
        'three',
        'Chapter 4',
        'four',
      ]);
      expect(pressUndo(view, OP)).toBe(true);
      placeCaret(view, startOfParagraph(view, 'restored two') + 'rest'.length); // in the middle of the restored words
      typeText(view, 'XY');

      const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC)); // the target rows hold the old ids

      expectRebasedPremise(posted);
      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      // "restored two" against "two": the changed run is "restored " (the words the restore brought back); a position inside it goes
      // to its edge, here the start of the surviving paragraph. Mid-sentence is accepted.
      expect(texts(view)).toEqual([
        'Chapter 1',
        'one',
        'Chapter 2',
        'XYtwo',
        'Chapter 3',
        'three',
        'Chapter 4',
        'four',
      ]);
      swiftReplies(OP, { redoTopOpId: OP });
      flushPendingBlockChanges();
      const batch = takePendingAsReport();
      expect(batch.updates.map((u) => u.id)).toEqual(['c2p']);
      expect(batch.updates[0].textContent).toBe('XYtwo');
      expect(takePendingAsReport()).toEqual(EMPTY_BATCH);
    });

    it('the restore changed the block type: no pairing, the typing becomes its OWN paragraph at the edge of the changed run (after the block that took its place), the headings are unchanged', async () => {
      const { view, posted } = await makeEditor();
      await load(DOC);
      const schema = view.state.schema;
      runRegisteredOp(view, OP, () =>
        replaceBlockNode(
          view,
          'c2p',
          'c2p-restored',
          schema.nodes.heading.create({ level: 2 }, schema.text('restored two'))
        )
      );
      expect(pressUndo(view, OP)).toBe(true);
      let endOfRestoredHeading = -1;
      view.state.doc.forEach((node, offset) => {
        if (endOfRestoredHeading === -1 && node.type.name === 'heading' && node.textContent === 'restored two') {
          endOfRestoredHeading = offset + node.nodeSize - 1;
        }
      });
      placeCaret(view, endOfRestoredHeading);
      typeText(view, 'XY');

      const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));

      expectRebasedPremise(posted);
      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      // Round 3 (Q3(i)) moved the place of an unpaired block from the START of the changed run to its EDGE: the typing was done at the
      // END of the restored heading, so it follows "two" (the old expectation had it before "two").
      expect(texts(view)).toEqual([
        'Chapter 1',
        'one',
        'Chapter 2',
        'two',
        'XY',
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
    });
  });
});

describe('typing across a waiting Cmd-Z: held presses', () => {
  it('W11a: a held Cmd-Shift-Z that the user typed after is over: the notice, nothing routed, the typing once', async () => {
    const { view, posted } = await sceneWithDrag();
    expect(pressUndo(view, OP)).toBe(true);
    expect(pressRedo(view, OP)).toBe(true); // queued behind the first press
    placeCaret(view, endOfParagraphText(view, 'two'));
    typeText(view, ' typed'); // after the redo's press: it carries the redo's tag
    expect(
      getTypingCollector().stepsSince(2).length,
      'premise: typing recorded after the held redo'
    ).toBeGreaterThanOrEqual(1);

    const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));
    expectRebasedPremise(posted);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    swiftReplies(OP, { redoTopOpId: OP });

    expect(messagesOf(posted, 'undoQueueDropped')).toEqual([{ count: 1 }]);
    expect(messagesOf(posted, 'structuralRedoRequested'), 'nothing was routed').toEqual([]);
    expect(messagesOf(posted, 'undoHeldPressSettled')).toEqual([{ count: 1 }]);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one',
      'Chapter 2',
      'two typed',
      'Chapter 3',
      'three',
      'Chapter 4',
      'four',
    ]);
  });

  it('W11b: a held Cmd-Shift-Z pressed after the typing acts on the document of ITS press and falls through (no doubling)', async () => {
    const { view, posted } = await sceneWithDrag();
    expect(pressUndo(view, OP)).toBe(true);
    placeCaret(view, endOfParagraphText(view, 'two'));
    typeText(view, ' typed'); // before the redo's press
    expect(pressRedo(view, OP)).toBe(true);
    expect(getTypingCollector().stepsSince(1).length, 'premise: typing recorded').toBeGreaterThanOrEqual(1);

    const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));
    expectRebasedPremise(posted);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    swiftReplies(OP, { redoTopOpId: OP });

    expect(
      messagesOf(posted, 'structuralRedoRequested'),
      'the redo cannot be structural: the typing sits before its press'
    ).toEqual([]);
    expect(messagesOf(posted, 'undoQueueDropped')).toEqual([]);
    expect(messagesOf(posted, 'undoHeldPressSettled')).toEqual([{ count: 1 }]);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one',
      'Chapter 2',
      'two typed',
      'Chapter 3',
      'three',
      'Chapter 4',
      'four',
    ]);
  });

  it('W11c: a held Cmd-Z acts on the document as it was at ITS press, so the typing after it does not stop it being structural', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    runRegisteredOp(view, OP_A, dragOp(view));
    const afterDrag = specsOf(AFTER_DRAG);
    runRegisteredOp(view, OP_B, () => rewriteBlocks(view, ['c1h', 'c1p', 'c4h', 'c4p', 'c2h', 'c2p'])); // delete Chapter 3
    expect(texts(view)).toEqual(['Chapter 1', 'one', 'Chapter 4', 'four', 'Chapter 2', 'two']);
    expect(pressUndo(view, OP_B)).toBe(true); // press 1: undo the delete
    expect(pressUndo(view, OP_A)).toBe(true); // press 2: held, undo the drag
    placeCaret(view, endOfParagraphText(view, 'two'));
    typeText(view, ' typed'); // after press 2: its tag
    expect(
      getTypingCollector().stepsSince(2).length,
      'premise: typing recorded after the held press'
    ).toBeGreaterThanOrEqual(1);

    const first = structuralSwapEditorFirst(OP_B, 'undo', payloadFor(afterDrag));
    expect(first.ok, `reason: ${first.reason}`).toBe(true);
    expect(first.typingReplayed).toBe(true);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one',
      'Chapter 4',
      'four',
      'Chapter 2',
      'two typed',
      'Chapter 3',
      'three',
    ]);
    swiftReplies(OP_B, { undoTopOpId: OP_A, redoTopOpId: OP_B });

    // The held press is routed against the document at ITS press (without the typing that came after it): structural, with its own request.
    expect(messagesOf(posted, 'structuralUndoRequested').pop()).toEqual({ opId: OP_A, held: true });
    expect(
      getTypingCollector().stepsSince(2).length,
      'the typing is still recorded for the held press'
    ).toBeGreaterThanOrEqual(1);

    const second = structuralSwapEditorFirst(OP_A, 'undo', payloadFor(DOC));
    expect(typingLines(posted).pop()).toMatch(/^typing-since-press press=2 steps=[1-9]\d* decision=rebased$/);
    expect(second.ok, `reason: ${second.reason}`).toBe(true);
    expect(second.typingReplayed).toBe(true);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one',
      'Chapter 2',
      'two typed',
      'Chapter 3',
      'three',
      'Chapter 4',
      'four',
    ]);
    receiveUndoOutcome(OP_A, 'performed');
    expect(texts(view).join('|').split('typed').length - 1, 'the typing is there once').toBe(1);
  });
});

// A document with Notes, a Bibliography and a footnote, as the app holds it: what the settle rewrites on its own (the Notes and
// bibliography rebuild, the footnote renumber) lands at the END of a wait, AFTER the typing. The slow undo of "Title"'s delete.
const MANAGED_MD = [
  '# Title',
  'Body one.',
  '# Second',
  'Body two.',
  '## Notes',
  'Note text.',
  '<!-- ::auto-bibliography:: -->',
  '## Bibliography',
  'Reference one.',
  '<!-- ::auto-bibliography-end:: -->',
].join('\n\n');
const MANAGED_IDS = ['t', 'b1', 'u', 'b2', 'notes', 'np', 'bib', 'bp'];
const MANAGED = ['notes', 'np', 'bib', 'bp'];
const MANAGED_SPECS: Spec[] = [
  heading('t', 1, 'Title'),
  para('b1', 'Body one.'),
  heading('u', 1, 'Second'),
  para('b2', 'Body two.'),
  heading('notes', 2, 'Notes'),
  para('np', 'Note text.'),
  heading('bib', 2, 'Bibliography'),
  para('bp', 'Reference one.'),
];
const managedPayload = (): StructuralSwapPayload => ({ ...payloadFor(MANAGED_SPECS), managedBlockIds: MANAGED });

/** The managed document with a footnote reference (label 1) in "Body two."; "Title" is deleted and Cmd-Z is pressed (press 1). */
async function managedSceneAfterDelete(withFootnote: boolean) {
  const made = await makeEditor([footnotePlugin, bibliographyPlugin, bibliographyEndMarkerPlugin]);
  const { view } = made;
  setContentWithBlockIds(MANAGED_MD, MANAGED_IDS, { managedBlockIds: MANAGED });
  await waitForRAF();
  takePendingAsReport();
  if (withFootnote) {
    const ref = view.state.schema.nodes.footnote_ref;
    view.dispatch(
      view.state.tr
        .insert(startOfParagraph(view, 'Body two') + 4, ref.create({ label: '1' }))
        .setMeta('addToHistory', false)
    );
  }
  flushPendingBlockChanges();
  takePendingAsReport();
  expect(deleteSectionEditorFirst(OP, 't', MANAGED).ok).toBe(true);
  await sleep(160);
  takePendingAsReport();
  expect(pressUndo(view, OP)).toBe(true);
  return made;
}

function footnoteRefPos(view: EditorView): number {
  let pos = -1;
  view.state.doc.descendants((node, at) => {
    if (node.type.name === 'footnote_ref') pos = at;
  });
  expect(pos, 'the footnote reference exists').toBeGreaterThan(-1);
  return pos;
}

describe('typing across a waiting Cmd-Z: typing first, the settle rewrite last (the order of an ordinary book)', () => {
  it('W15: typing, then a Notes and bibliography rebuild and a footnote renumber land, then the click: rebased, the typing once', async () => {
    const { view, posted } = await managedSceneAfterDelete(true);
    typeInto(view, 'Body two', ' TYPED');
    automaticRewrite(view, 'Note text', ' (rebuilt)'); // the Notes rebuild, after the typing
    automaticRewrite(view, 'Reference one', ' (rebuilt)'); // the bibliography rebuild
    view.dispatch(
      view.state.tr.setNodeMarkup(footnoteRefPos(view), undefined, { label: '2' }).setMeta('derivedCorrection', true)
    ); // the footnote renumber
    expect(texts(view)).toEqual([
      'Second',
      'Body[^2] two. TYPED',
      'Notes',
      'Note text. (rebuilt)',
      '', // the bibliography start marker
      'Bibliography',
      'Reference one. (rebuilt)',
      '', // the bibliography end marker
    ]);
    expect(getTypingCollector().stepsSince(1).length, 'premise: typing and the rewrites were recorded').toBeGreaterThan(
      3
    );

    const r = structuralSwapEditorFirst(OP, 'undo', managedPayload());

    expectRebasedPremise(posted);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.typingReplayed).toBe(true);
    expect(r.batch, 'the replay is the only carrier of the typing').toEqual(EMPTY_BATCH);
    expect(texts(view), 'the saved pre-op document is back, with the typing on top, once').toEqual([
      'Title',
      'Body one.',
      'Second',
      'Body[^1] two. TYPED',
      'Notes',
      'Note text.',
      '',
      'Bibliography',
      'Reference one.',
      '',
    ]);
    swiftReplies(OP, { redoTopOpId: OP });
    flushPendingBlockChanges();
    const batch = takePendingAsReport();
    expect(batch.updates.map((u) => u.id)).toEqual(['b2']);
    expect(batch.inserts).toEqual([]);
    expect(batch.deletes).toEqual([]);
    expect(takePendingAsReport(), 'not sent a second time').toEqual(EMPTY_BATCH);
  });

  it('W15b: typing INSIDE the bibliography entry, then a rebuild that rewrites that entry: refused before the swap, the live document untouched', async () => {
    const { view, posted } = await managedSceneAfterDelete(false);
    typeInto(view, 'Reference one', ' LATE');
    const from = startOfParagraph(view, 'Reference one');
    view.dispatch(
      view.state.tr
        .replaceWith(from, endOfParagraph(view, 'Reference one'), view.state.schema.text('Reference ONE.'))
        .setMeta('addToHistory', false)
    ); // the rebuild writes the whole entry again: the typed words are inside the text it replaced
    expect(paragraphText(view, 'Reference')).toBe('Reference ONE.');
    expect(getTypingCollector().stepsSince(1).length, 'premise: typing and the rebuild were recorded').toBeGreaterThan(
      1
    );
    const docBefore = view.state.doc;
    const entryBefore = getRegistry().get(OP);

    const r = structuralSwapEditorFirst(OP, 'undo', managedPayload());

    expect(typingLines(posted).pop()).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=changed$/);
    expect(r.ok).toBe(false);
    expect(r.reason).toBe('docChanged');
    expect(r.typingReplayed).toBeUndefined();
    expect(view.state.doc.eq(docBefore), 'nothing was swapped').toBe(true);
    expect(getRegistry().get(OP), 'the entry stays recorded, untouched').toBe(entryBefore);
    expect(
      r.batch.updates.map((u) => u.id),
      'the pending edit comes back with the refusal, once'
    ).toEqual(['bp']);
    expect(r.batch.updates[0].textContent).toBe('Reference ONE.');
    receiveUndoOutcome(OP, 'failed'); // Swift: refuse with the notice, release the latch
    flushPendingBlockChanges();
    expect(takePendingAsReport(), 'sent once').toEqual(EMPTY_BATCH);
  });

  // The old R2b (slow-swap-editor-first.test.ts) covered typing in a region the saved-copy comparison ignores (a bibliography entry):
  // the press stays routable with that typing pending, so it must not be lost by the swap. Round 7 adds the Rich Text coverage for the
  // typing-across-undo flow: the typing is either put back by the replay or the press is refused with the typing kept; never dropped.
  it('R2b-v2: typing inside a bibliography entry just before the click, then the slow-route swap: the typed text is in the rows exactly once after the settle, or the press ends changed with the typing kept; never a swap that drops it', async () => {
    const { view, posted } = await managedSceneAfterDelete(false);
    typeInto(view, 'Reference one', ' LATE');
    expect(getTypingCollector().stepsSince(1).length, 'premise: the typing was recorded').toBeGreaterThanOrEqual(1);
    expect(paragraphText(view, 'Reference one')).toBe('Reference one. LATE');

    const r = structuralSwapEditorFirst(OP, 'undo', managedPayload());

    const line = typingLines(posted).pop();
    expect(line, 'premise: the route wrote the trace line (steps counts what is left after a replay)').toMatch(
      /^typing-since-press press=1 steps=\d+ decision=(rebased|changed)$/
    );
    const rows = [...r.batch.updates];
    if (r.ok) {
      expect(line).toMatch(/decision=rebased$/);
      expect(r.typingReplayed).toBe(true);
      swiftReplies(OP, { redoTopOpId: OP });
    } else {
      expect(r.reason).toBe('docChanged');
      expect(line).toMatch(/decision=changed$/);
      receiveUndoOutcome(OP, 'failed');
    }
    flushPendingBlockChanges();
    rows.push(...takePendingAsReport().updates);

    // The typed text is in the editor, once, whichever way the press ended ...
    expect(paragraphText(view, 'Reference one'), 'the typing is still in the editor').toBe('Reference one. LATE');
    // ... and in the rows, exactly once (it rides the replay or the batch, never both and never neither).
    expect(rows.filter((u) => u.id === 'bp' && u.textContent.includes('LATE'))).toHaveLength(1);
    expect(takePendingAsReport(), 'nothing is sent a second time').toEqual(EMPTY_BATCH);
  });
});

describe('typing across a waiting Cmd-Z: three held presses with typing between them (Q3 iv)', () => {
  it('Q3iv: a press whose saved copy is not the document the earlier typing left is never swapped onto; every typed letter is in the document once', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    runRegisteredOp(view, OP_A, dragOp(view)); // Chapter 4 above Chapter 2
    runRegisteredOp(view, OP_B, () => rewriteBlocks(view, ['c1h', 'c1p', 'c4h', 'c4p', 'c2h', 'c2p'])); // delete Chapter 3
    runRegisteredOp(view, OP_C, () => rewriteBlocks(view, ['c4h', 'c4p', 'c2h', 'c2p'])); // delete Chapter 1
    expect(texts(view)).toEqual(['Chapter 4', 'four', 'Chapter 2', 'two']);
    expect(pressUndo(view, OP_C)).toBe(true); // press 1: runs
    placeCaret(view, endOfParagraphText(view, 'four'));
    typeText(view, 'Q1'); // tagged 1: before press 2
    expect(pressUndo(view, OP_B)).toBe(true); // press 2: held
    placeCaret(view, endOfParagraphText(view, 'two'));
    typeText(view, 'Q2'); // tagged 2: before press 3
    expect(pressUndo(view, OP_A)).toBe(true); // press 3: held
    placeCaret(view, endOfParagraphText(view, 'fourQ1'));
    typeText(view, 'Q3'); // tagged 3
    expect(getTypingCollector().stepsSince(3).length, 'premise: typing after the last press').toBeGreaterThanOrEqual(1);
    expect(getTypingCollector().stepsSince(1).length, 'premise: typing recorded since the first press').toBeGreaterThan(
      2
    );

    const first = structuralSwapEditorFirst(
      OP_C,
      'undo',
      payloadFor(specsOf(['c1h', 'c1p', 'c4h', 'c4p', 'c2h', 'c2p']))
    );
    expect(first.ok, `reason: ${first.reason}`).toBe(true);
    expect(first.typingReplayed).toBe(true);
    expect(texts(view)).toEqual(['Chapter 1', 'one', 'Chapter 4', 'fourQ1Q3', 'Chapter 2', 'twoQ2']);
    swiftReplies(OP_C, { undoTopOpId: OP_B, redoTopOpId: OP_C });

    // Press 2 and press 3 were each pressed after typing, so the document as it was at THEIR press is not the document the saved copy of
    // their operation is (it holds typing the saved copy never had). A base that does not match the saved copy is never swapped onto: the
    // two presses are no structural undo, the slow route is asked for nothing but the first press. Each would have run a plain text
    // undo, which would take back the NEWEST typing (typed after the press) and keep the older: they end with the existing notice
    // instead (F1), nothing removed.
    const requests = messagesOf(posted, 'structuralUndoRequested').map((m) => m.opId);
    expect(requests, 'neither held press was routed to a swap onto a wrong base').toEqual([OP_C]);
    expect(messagesOf(posted, 'undoHeldPressSettled'), 'each held press was settled, once').toEqual([
      { count: 1 },
      { count: 1 },
    ]);
    expect(messagesOf(posted, 'undoQueueDropped'), 'each ended with the notice').toEqual([{ count: 1 }, { count: 1 }]);
    const body = texts(view).join('|');
    for (const token of ['Q1', 'Q2', 'Q3']) {
      expect(
        body.split(token).length - 1,
        `${token} is in the document exactly once (never doubled by a replay, never taken back): ${body}`
      ).toBe(1);
    }
    expect(view.state.doc.textContent).toContain('Chapter 1');
  });

  it('Q3iv-b: three presses made before the typing: each acts on the document of ITS press, all three are swapped, and the typing is in the document once', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    runRegisteredOp(view, OP_A, dragOp(view));
    runRegisteredOp(view, OP_B, () => rewriteBlocks(view, ['c1h', 'c1p', 'c4h', 'c4p', 'c2h', 'c2p']));
    runRegisteredOp(view, OP_C, () => rewriteBlocks(view, ['c4h', 'c4p', 'c2h', 'c2p']));
    expect(pressUndo(view, OP_C)).toBe(true); // press 1: runs
    expect(pressUndo(view, OP_B)).toBe(true); // press 2: held
    expect(pressUndo(view, OP_A)).toBe(true); // press 3: held
    placeCaret(view, endOfParagraphText(view, 'four'));
    typeText(view, 'Q1'); // after all three presses: tagged 3
    placeCaret(view, endOfParagraphText(view, 'two'));
    typeText(view, 'Q2');
    expect(getTypingCollector().stepsSince(3).length, 'premise: typing recorded').toBeGreaterThanOrEqual(2);

    const afterDelete1 = ['c1h', 'c1p', 'c4h', 'c4p', 'c2h', 'c2p'];
    const first = structuralSwapEditorFirst(OP_C, 'undo', payloadFor(specsOf(afterDelete1)));
    expect(first.ok, `reason: ${first.reason}`).toBe(true);
    expect(first.typingReplayed).toBe(true);
    expect(texts(view)).toEqual(['Chapter 1', 'one', 'Chapter 4', 'fourQ1', 'Chapter 2', 'twoQ2']);
    swiftReplies(OP_C, { undoTopOpId: OP_B, redoTopOpId: OP_C });
    expect(messagesOf(posted, 'structuralUndoRequested').pop()).toEqual({ opId: OP_B, held: true });

    const second = structuralSwapEditorFirst(OP_B, 'undo', payloadFor(specsOf(AFTER_DRAG)));
    expect(typingLines(posted).pop()).toMatch(/^typing-since-press press=2 steps=[1-9]\d* decision=rebased$/);
    expect(second.ok, `reason: ${second.reason}`).toBe(true);
    expect(second.typingReplayed).toBe(true);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one',
      'Chapter 4',
      'fourQ1',
      'Chapter 2',
      'twoQ2',
      'Chapter 3',
      'three',
    ]);
    swiftReplies(OP_B, { undoTopOpId: OP_A, redoTopOpId: OP_B });
    expect(messagesOf(posted, 'structuralUndoRequested').pop()).toEqual({ opId: OP_A, held: true });

    const third = structuralSwapEditorFirst(OP_A, 'undo', payloadFor(DOC));
    expect(typingLines(posted).pop()).toMatch(/^typing-since-press press=3 steps=[1-9]\d* decision=rebased$/);
    expect(third.ok, `reason: ${third.reason}`).toBe(true);
    expect(third.typingReplayed).toBe(true);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one',
      'Chapter 2',
      'twoQ2',
      'Chapter 3',
      'three',
      'Chapter 4',
      'fourQ1',
    ]);
    receiveUndoOutcome(OP_A, 'performed');
    expect(messagesOf(posted, 'undoQueueDropped')).toEqual([]);
  });
});

describe('typing across a waiting Cmd-Z: a held press that would run a plain text undo on newer typing (F1)', () => {
  it('F1: Cmd-Z waits, abc is typed, a second Cmd-Z is held, def is typed: the held press ends with the notice and nothing is removed', async () => {
    const { view, posted } = await sceneWithDrag();
    expect(pressUndo(view, OP)).toBe(true); // press 1: waits
    placeCaret(view, endOfParagraphText(view, 'two'));
    typeText(view, 'abc'); // tagged 1
    expect(pressUndo(view, OP)).toBe(true); // press 2: held
    typeText(view, 'def'); // tagged 2: after press 2, before press 1 is answered
    expect(getTypingCollector().stepsSince(2).length, 'premise: typing after the held press').toBeGreaterThanOrEqual(1);

    const r = structuralSwapEditorFirst(OP, 'undo', payloadFor(DOC));
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(paragraphText(view, 'two')).toBe('twoabcdef');
    swiftReplies(OP, { redoTopOpId: OP }); // no structural entry on top: press 2 would be a plain text undo

    expect(paragraphText(view, 'two'), 'abc and def are both still there').toBe('twoabcdef');
    expect(messagesOf(posted, 'undoQueueDropped'), 'the existing notice, once').toEqual([{ count: 1 }]);
    expect(messagesOf(posted, 'undoHeldPressSettled'), 'the held press is settled, once').toEqual([{ count: 1 }]);
    expect(messagesOf(posted, 'structuralUndoRequested').map((m) => m.opId)).toEqual([OP]);
  });

  it("F1b: a 'fallback' reply for a press the user typed after does not run a text undo on the newest typing either", async () => {
    const { view, posted } = await sceneWithDrag();
    expect(pressUndo(view, OP)).toBe(true);
    placeCaret(view, endOfParagraphText(view, 'two'));
    typeText(view, 'abc');
    expect(getTypingCollector().stepsSince(1).length, 'premise: typing recorded').toBeGreaterThanOrEqual(1);

    receiveUndoOutcome(OP, 'fallback'); // Swift's top entry no longer matched: the page would run the text undo it suppressed

    expect(paragraphText(view, 'two'), 'the typing is still there').toBe('twoabc');
    expect(messagesOf(posted, 'undoQueueDropped'), 'the existing notice, once').toEqual([{ count: 1 }]);
  });
});

describe('typing across a waiting Cmd-Z: ending the hold and taking the batch in one call (F7)', () => {
  it('F7: releaseHeldTypingAndGetBatch ends the hold and returns the typing at once, before the old body would run; the next poll is empty', async () => {
    const { view } = await sceneWithDrag();
    expect(pressUndo(view, OP)).toBe(true);
    placeCaret(view, endOfParagraphText(view, 'two'));
    typeText(view, ' typed'); // the 100 ms detection has not run yet
    expect(isTypingPushHeld(), 'premise: the typing is held back from the polls').toBe(true);
    expect(hasReportablePending()).toBe(false);
    expect(takePendingAsReport()).toEqual(EMPTY_BATCH);

    const taken = releaseHeldTypingAndGetBatch();

    expect(taken.released).toBe(true);
    expect(taken.batch.updates.map((u) => u.id)).toEqual(['c2p']);
    expect(taken.batch.updates[0].textContent).toBe('two typed');
    expect(isTypingPushHeld()).toBe(false);
    expect(takePendingAsReport(), 'sent once').toEqual(EMPTY_BATCH);
    receiveUndoOutcome(OP, 'failed');
  });

  it('F7: with nothing held it returns released=false and the ordinary pending batch', async () => {
    const { view } = await sceneWithDrag();
    typeInto(view, 'two', ' typed');

    const taken = releaseHeldTypingAndGetBatch();

    expect(taken.released).toBe(false);
    expect(taken.batch.updates.map((u) => u.id)).toEqual(['c2p']);
    expect(takePendingAsReport()).toEqual(EMPTY_BATCH);
  });
});
