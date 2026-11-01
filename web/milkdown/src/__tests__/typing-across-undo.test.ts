// @vitest-environment jsdom
//
// Typing done while a Cmd-Z waits (Phase 4c, job 2, t-d2061b27) -- the pure layer, Rich Text half: web/milkdown/src/typing-rebase.ts.
//
// Real ProseMirror on the editor-first harness (the app's block-id, block-sync and history plugins, the real `view.dispatch` override),
// plus the footnote and smart-quote plugins where a case needs them. Each case plays what a route will do once it is wired:
//   (1) keep the state and the ids from before a structural operation (`checkpoint`, the swap's target),
//   (2) run the operation (a drag, a duplicate, a delete, a restore) on the live document,
//   (3) latch a press (the collector starts recording), type,
//   (4) at the re-check: inspect the press, build the replay against the target (the dry run),
//   (5) swap the checkpoint in and dispatch the replay.
// Every case FIRST asserts the premise: the collector recorded at least one step and the trace line says so. A case that only asserted
// the end state could pass while no typing ever happened.

import { joinBackward, splitBlock } from '@milkdown/kit/prose/commands';
import { undo } from '@milkdown/kit/prose/history';
import { type Node as ProsemirrorNode, Slice } from '@milkdown/kit/prose/model';
import { Plugin, TextSelection } from '@milkdown/kit/prose/state';
import { ReplaceStep } from '@milkdown/kit/prose/transform';
import type { EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import { describe, expect, it, vi } from 'vitest';
import { getAllBlockIds, getAllBlockTypes, restoreBlockIdMaps, setBlockIdsForTopLevel } from '../block-id-plugin';
import {
  flushPendingBlockChanges,
  hasUnsettledLocalEdit,
  rebindCurrentStateFromView,
  resetAndSnapshot,
  setSyncPaused,
} from '../block-sync-plugin';
import { footnotePlugin } from '../footnote-plugin';
import { smartQuotesPlugin } from '../smart-quotes-plugin';
import {
  buildReplayDryRun,
  createTypingCollectorPlugin,
  docAtPress,
  formatTypingSincePressLine,
  inspectPress,
  type RecordedStep,
  type ReplayDryRun,
  TypingCollector,
  type TypingDecision,
} from '../typing-rebase';
import { idsOfDocumentAtPress } from '../typing-route';
import { endOfNthParagraph, endOfParagraph, heading, load, makeEditor, para, type Spec } from './editor-first-harness';

// === Scene ===

interface Checkpoint {
  state: EditorView['state'];
  ids: Map<number, string>;
  types: Map<number, string>;
}

interface Scene {
  view: EditorView;
  collector: TypingCollector;
}

async function makeScene(
  specs: Spec[],
  extra: Array<NonNullable<Parameters<typeof makeEditor>[0]>[number]> = []
): Promise<Scene> {
  const collector = new TypingCollector();
  const collectorPlugin = $prose(() => createTypingCollectorPlugin(collector));
  const { view } = await makeEditor([collectorPlugin, ...extra]);
  await load(specs);
  return { view, collector };
}

const checkpointOf = (view: EditorView): Checkpoint => ({
  state: view.state,
  ids: getAllBlockIds(),
  types: getAllBlockTypes(),
});

const book: Spec[] = [
  heading('c1h', 1, 'Chapter 1'),
  para('c1p', 'one'),
  heading('c2h', 1, 'Chapter 2'),
  para('c2p', 'two'),
  heading('c3h', 1, 'Chapter 3'),
  para('c3p', 'three'),
  heading('c4h', 1, 'Chapter 4'),
  para('c4p', 'four'),
];

/** A block's text, with a footnote reference written `[^label]` (an atom has no text of its own). */
function describeBlock(node: ProsemirrorNode): string {
  return node.textBetween(0, node.content.size, '', (leaf) =>
    leaf.type.name === 'footnote_ref' ? `[^${leaf.attrs.label}]` : ''
  );
}

const texts = (view: EditorView): string[] => {
  const out: string[] = [];
  view.state.doc.forEach((node) => {
    out.push(describeBlock(node));
  });
  return out;
};

const headingTitles = (view: EditorView): string[] => {
  const out: string[] = [];
  view.state.doc.forEach((node) => {
    if (node.type.name === 'heading') out.push(node.textContent);
  });
  return out;
};

/** The top-level blocks by id, as the editor holds them now. */
function blocksById(view: EditorView): Map<string, ProsemirrorNode> {
  const ids = getAllBlockIds();
  const byId = new Map<string, ProsemirrorNode>();
  view.state.doc.forEach((node, offset) => {
    byId.set(ids.get(offset) as string, node);
  });
  return byId;
}

/** A structural operation as the editor sees it: the top-level blocks become `entries`, with those ids; not a text-history step. */
function rewriteBlocks(view: EditorView, entries: Array<{ id: string; node: ProsemirrorNode }>): void {
  view.dispatch(
    view.state.tr
      .replaceWith(
        0,
        view.state.doc.content.size,
        entries.map((entry) => entry.node)
      )
      .setMeta('addToHistory', false)
  );
  setBlockIdsForTopLevel(
    entries.map((entry) => entry.id),
    view.state.doc
  );
}

function dragChapter4Above2(view: EditorView): void {
  const b = blocksById(view);
  const order = ['c1h', 'c1p', 'c4h', 'c4p', 'c2h', 'c2p', 'c3h', 'c3p'];
  rewriteBlocks(
    view,
    order.map((id) => ({ id, node: b.get(id) as ProsemirrorNode }))
  );
}

function deleteChapter4(view: EditorView): void {
  const b = blocksById(view);
  const order = ['c1h', 'c1p', 'c2h', 'c2p', 'c3h', 'c3p'];
  rewriteBlocks(
    view,
    order.map((id) => ({ id, node: b.get(id) as ProsemirrorNode }))
  );
}

/** Duplicate chapter 2: the copy (new ids) follows the original. */
function duplicateChapter2(view: EditorView): void {
  const b = blocksById(view);
  const order: Array<[string, string]> = [
    ['c1h', 'c1h'],
    ['c1p', 'c1p'],
    ['c2h', 'c2h'],
    ['c2p', 'c2p'],
    ['c2h-copy', 'c2h'],
    ['c2p-copy', 'c2p'],
    ['c3h', 'c3h'],
    ['c3p', 'c3p'],
    ['c4h', 'c4h'],
    ['c4p', 'c4p'],
  ];
  rewriteBlocks(
    view,
    order.map(([id, from]) => ({ id, node: b.get(from) as ProsemirrorNode }))
  );
}

// === Typing, as the editor receives it ===

function placeCaret(view: EditorView, pos: number): void {
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)).setMeta('addToHistory', false));
}

/** Typed characters take the path the browser's input takes: input rules first (smart quotes), then the plain insertion. */
function typeText(view: EditorView, text: string): void {
  for (const char of text) {
    const { from, to } = view.state.selection;
    const handled = view.someProp('handleTextInput', (handler) =>
      handler(view, from, to, char, () => view.state.tr.insertText(char, from, to))
    );
    if (!handled) view.dispatch(view.state.tr.insertText(char, from, to));
  }
}

const pressEnter = (view: EditorView): boolean => splitBlock(view.state, (tr) => view.dispatch(tr), view);
const pressBackspaceAtBlockStart = (view: EditorView): boolean =>
  joinBackward(view.state, (tr) => view.dispatch(tr), view);

/** Document position at the start of the text of the first paragraph starting with `startsWith`. */
function startOfParagraph(view: EditorView, startsWith: string): number {
  return endOfParagraph(view, startsWith) - (describeBlockStartingWith(view, startsWith).length || 0);
}

function describeBlockStartingWith(view: EditorView, startsWith: string): string {
  let found = '';
  view.state.doc.forEach((node) => {
    if (!found && node.type.name === 'paragraph' && node.textContent.startsWith(startsWith)) found = node.textContent;
  });
  return found;
}

// === The route's side: re-check, dry run, swap, replay ===

interface Rebase {
  steps: RecordedStep[];
  inspection: ReturnType<typeof inspectPress>;
  dry: ReplayDryRun;
  decision: TypingDecision;
  line: string;
}

function recheck(view: EditorView, collector: TypingCollector, cp: Checkpoint, press = 1): Rebase {
  const steps = collector.stepsSince(press);
  const inspection = inspectPress(collector, press, view.state.doc);
  // As the routes call it: the typing the commute re-expressed after the automatic changes, not every recorded step.
  const dry = buildReplayDryRun(cp.state, {
    steps: inspection.typing,
    docAtPress: inspection.docAtPress,
    idsAtPress: idsOfDocumentAtPress(collector, press, view.state.doc, getAllBlockIds()),
    targetIds: cp.ids,
    liveSelection: view.state.selection,
    syncPausedAfter: false,
    liveState: view.state,
  });
  const decision: TypingDecision =
    inspection.kind === 'matched' ? 'matched' : inspection.kind === 'changed' ? 'changed' : dry.decision;
  return { steps, inspection, dry, decision, line: formatTypingSincePressLine(press, steps.length, decision) };
}

/** The premise every case asserts first: typing was recorded and the trace line says so. */
function expectPremise(result: Rebase, press = 1): void {
  expect(result.steps.length, 'the collector recorded typing').toBeGreaterThanOrEqual(1);
  expect(result.decision).toBe('rebased');
  expect(result.line).toMatch(new RegExp(`^typing-since-press press=${press} steps=[1-9]\\d* decision=rebased$`));
}

/** What a quick route does with a successful dry run: swap the checkpoint in, then dispatch the replay. */
function swapAndReplay(view: EditorView, cp: Checkpoint, dry: ReplayDryRun): void {
  setSyncPaused(true);
  view.updateState(cp.state);
  rebindCurrentStateFromView(view);
  restoreBlockIdMaps(cp.ids, cp.types);
  resetAndSnapshot(view.state.doc);
  for (const tr of dry.replayTrs) view.dispatch(tr);
  setSyncPaused(false);
}

// === Cases ===

describe('typing across a waiting Cmd-Z: the pure layer', () => {
  it('W2-RT: a drag undo with typing inside the moved chapter, Return included, moves the typing back with the chapter', async () => {
    const { view, collector } = await makeScene(book);
    const cp = checkpointOf(view);
    dragChapter4Above2(view);
    expect(texts(view)).toEqual(['Chapter 1', 'one', 'Chapter 4', 'four', 'Chapter 2', 'two', 'Chapter 3', 'three']);

    collector.startPress(1, getAllBlockIds());
    placeCaret(view, endOfParagraph(view, 'four'));
    typeText(view, " don't stop");
    expect(pressEnter(view)).toBe(true);
    typeText(view, 'more words');
    const result = recheck(view, collector, cp);
    expectPremise(result);
    expect(result.dry.ok).toBe(true);

    swapAndReplay(view, cp, result.dry);
    expect(texts(view)).toEqual([
      'Chapter 1',
      'one',
      'Chapter 2',
      'two',
      'Chapter 3',
      'three',
      'Chapter 4',
      "four don't stop",
      'more words',
    ]);
    expect(view.state.selection.from).toBe(endOfParagraph(view, 'more words'));
  });

  it('W5: typing inside a duplicate copy becomes its own paragraph at the gap; the headings are unchanged', async () => {
    const { view, collector } = await makeScene(book);
    const cp = checkpointOf(view);
    duplicateChapter2(view);
    expect(headingTitles(view)).toEqual(['Chapter 1', 'Chapter 2', 'Chapter 2', 'Chapter 3', 'Chapter 4']);

    collector.startPress(1, getAllBlockIds());
    placeCaret(view, endOfNthParagraph(view, 'two', 1));
    typeText(view, 'xyz');
    const result = recheck(view, collector, cp);
    expectPremise(result);

    swapAndReplay(view, cp, result.dry);
    expect(headingTitles(view)).toEqual(['Chapter 1', 'Chapter 2', 'Chapter 3', 'Chapter 4']);
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
  });

  it('W6c: typing inside text a restore replaced goes to the edge of the changed run', async () => {
    const { view, collector } = await makeScene([
      heading('h', 1, 'Chapter 1'),
      para('p', 'The quick brown fox jumps'),
      para('q', 'after'),
    ]);
    const cp = checkpointOf(view);
    // The restore: the same block, older words.
    const start = startOfParagraph(view, 'The quick');
    view.dispatch(
      view.state.tr
        .replaceWith(
          start,
          start + 'The quick brown fox jumps'.length,
          view.state.schema.text('The slow grass fox jumps')
        )
        .setMeta('addToHistory', false)
    );
    expect(texts(view)).toEqual(['Chapter 1', 'The slow grass fox jumps', 'after']);

    collector.startPress(1, getAllBlockIds());
    placeCaret(view, startOfParagraph(view, 'The slow') + 'The slow gra'.length);
    typeText(view, 'xyz');
    const result = recheck(view, collector, cp);
    expectPremise(result);

    swapAndReplay(view, cp, result.dry);
    // Mid-sentence is accepted: the letters sit at the end edge of the changed run ("quick brown"), inside the surviving paragraph.
    expect(texts(view)).toEqual(['Chapter 1', 'The quick brownxyz fox jumps', 'after']);
  });

  describe('W7: what counts as typing is placed', () => {
    it('an apostrophe typed through the smart-quote rule keeps its curly form', async () => {
      const { view, collector } = await makeScene(book, [smartQuotesPlugin]);
      const cp = checkpointOf(view);
      deleteChapter4(view);

      collector.startPress(1, getAllBlockIds());
      placeCaret(view, endOfParagraph(view, 'two'));
      typeText(view, " don't");
      expect(describeBlockStartingWith(view, 'two')).toBe('two don’t'); // the rule ran: the premise of this case
      const result = recheck(view, collector, cp);
      expectPremise(result);

      swapAndReplay(view, cp, result.dry);
      expect(texts(view)).toEqual([
        'Chapter 1',
        'one',
        'Chapter 2',
        'two don’t',
        'Chapter 3',
        'three',
        'Chapter 4',
        'four',
      ]);
    });

    it('Return in the middle of a block splits the block in the target', async () => {
      const { view, collector } = await makeScene([...book.slice(0, 4), para('c2q', 'two words'), ...book.slice(4)]);
      const cp = checkpointOf(view);
      const b = blocksById(view);
      rewriteBlocks(
        view,
        ['c1h', 'c1p', 'c2h', 'c2p', 'c2q', 'c3h', 'c3p'].map((id) => ({ id, node: b.get(id) as ProsemirrorNode }))
      );

      collector.startPress(1, getAllBlockIds());
      placeCaret(view, startOfParagraph(view, 'two words') + 'two '.length);
      expect(pressEnter(view)).toBe(true);
      typeText(view, 'X');
      const result = recheck(view, collector, cp);
      expectPremise(result);

      swapAndReplay(view, cp, result.dry);
      expect(texts(view)).toEqual([
        'Chapter 1',
        'one',
        'Chapter 2',
        'two',
        'two ',
        'Xwords',
        'Chapter 3',
        'three',
        'Chapter 4',
        'four',
      ]);
    });

    it('a joining backspace joins the two blocks in the target when they are adjacent there', async () => {
      const { view, collector } = await makeScene([
        heading('h', 1, 'Chapter 1'),
        para('a', 'alpha'),
        para('b', 'beta'),
        para('tail', 'tail'),
      ]);
      const cp = checkpointOf(view); // the target still holds "tail", which the operation removed
      const nodes = blocksById(view);
      rewriteBlocks(
        view,
        ['h', 'a', 'b'].map((id) => ({ id, node: nodes.get(id) as ProsemirrorNode }))
      );

      collector.startPress(1, getAllBlockIds());
      placeCaret(view, startOfParagraph(view, 'beta'));
      expect(pressBackspaceAtBlockStart(view)).toBe(true);
      expect(texts(view)).toEqual(['Chapter 1', 'alphabeta']);
      const result = recheck(view, collector, cp);
      expectPremise(result);

      swapAndReplay(view, cp, result.dry);
      expect(texts(view)).toEqual(['Chapter 1', 'alphabeta', 'tail']);
    });

    it('a joining backspace is unplaceable when the target holds a block between the two', async () => {
      const { view, collector } = await makeScene([
        heading('h', 1, 'Chapter 1'),
        para('a', 'alpha'),
        para('between', 'between'),
        para('b', 'beta'),
      ]);
      const cp = checkpointOf(view); // the target: "between" sits between alpha and beta
      const nodes = blocksById(view);
      rewriteBlocks(
        view,
        ['h', 'a', 'b'].map((id) => ({ id, node: nodes.get(id) as ProsemirrorNode }))
      );

      collector.startPress(1, getAllBlockIds());
      placeCaret(view, startOfParagraph(view, 'beta'));
      expect(pressBackspaceAtBlockStart(view)).toBe(true);
      const result = recheck(view, collector, cp);
      expect(result.steps.length).toBeGreaterThanOrEqual(1);
      expect(result.line).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=unplaceable$/);
      expect(result.dry.ok).toBe(false);
    });
  });

  it('W8: a footnote renumbered inside the typed block does not move the typing', async () => {
    const { view, collector } = await makeScene(
      [heading('h', 1, 'Chapter 1'), para('p', 'abc'), para('q', 'after')],
      [footnotePlugin]
    );
    const refType = view.state.schema.nodes.footnote_ref;
    const refAt = startOfParagraph(view, 'abc') + 2;
    view.dispatch(view.state.tr.insert(refAt, refType.create({ label: '1' })).setMeta('addToHistory', false));
    expect(texts(view)).toEqual(['Chapter 1', 'ab[^1]c', 'after']);
    const cp = checkpointOf(view); // the target: label 1
    view.dispatch(view.state.tr.setNodeMarkup(refAt, undefined, { label: '3' }).setMeta('addToHistory', false));
    expect(texts(view)).toEqual(['Chapter 1', 'ab[^3]c', 'after']);

    collector.startPress(1, getAllBlockIds());
    placeCaret(view, refAt + 1); // right after the reference, before "c"
    typeText(view, 'xyz');
    const result = recheck(view, collector, cp);
    expectPremise(result);

    swapAndReplay(view, cp, result.dry);
    expect(texts(view)).toEqual(['Chapter 1', 'ab[^1]xyzc', 'after']);
  });

  it('W9: a letter typed straight after the replay lands right after the replayed text', async () => {
    const { view, collector } = await makeScene(book);
    const cp = checkpointOf(view);
    deleteChapter4(view);

    collector.startPress(1, getAllBlockIds());
    placeCaret(view, endOfParagraph(view, 'two'));
    typeText(view, 'xyz');
    const result = recheck(view, collector, cp);
    expectPremise(result);

    swapAndReplay(view, cp, result.dry);
    view.dispatch(view.state.tr.insertText('Q'));
    expect(describeBlockStartingWith(view, 'two')).toBe('twoxyzQ');
  });

  it('W10: one undo removes exactly the replayed text since the last press, not the typing before it', async () => {
    const { view, collector } = await makeScene(book);
    // One frozen clock: the history groups typing by time (500 ms), so only closeHistory can keep the replay out of the earlier event.
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(1_000_000);
    placeCaret(view, endOfParagraph(view, 'two'));
    typeText(view, 'pre'); // an ordinary history event, before the operation
    const cp = checkpointOf(view);
    deleteChapter4(view);

    collector.startPress(1, getAllBlockIds());
    placeCaret(view, endOfParagraph(view, 'twopre'));
    typeText(view, 'xyz');
    const result = recheck(view, collector, cp);
    expectPremise(result);

    swapAndReplay(view, cp, result.dry);
    expect(describeBlockStartingWith(view, 'two')).toBe('twoprexyz');
    expect(undo(view.state, (tr) => view.dispatch(tr))).toBe(true);
    expect(describeBlockStartingWith(view, 'two')).toBe('twopre');
  });

  it('W13: a step that cannot be placed fails the dry run, and the live document is untouched', async () => {
    const { view, collector } = await makeScene([
      heading('h', 1, 'Chapter 1'),
      para('a', 'alpha'),
      para('between', 'between'),
      para('b', 'beta'),
    ]);
    const cp = checkpointOf(view);
    const b = blocksById(view);
    rewriteBlocks(
      view,
      ['h', 'a', 'b'].map((id) => ({ id, node: b.get(id) as ProsemirrorNode }))
    );
    collector.startPress(1, getAllBlockIds());
    placeCaret(view, startOfParagraph(view, 'beta'));
    expect(pressBackspaceAtBlockStart(view)).toBe(true);
    const liveBefore = view.state.doc;
    const idsBefore = getAllBlockIds();

    const result = recheck(view, collector, cp);
    expect(result.steps.length).toBeGreaterThanOrEqual(1);
    expect(result.line).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=unplaceable$/);
    expect(result.dry.ok).toBe(false);
    expect(result.dry.replayTr).toBeNull();
    // What the route does on a failed dry run: nothing is swapped, nothing is dispatched.
    if (result.dry.ok) swapAndReplay(view, cp, result.dry);
    expect(view.state.doc.eq(liveBefore)).toBe(true);
    expect(getAllBlockIds()).toEqual(idsBefore);
  });

  describe('W14: the trace line', () => {
    it('is written for matched, rebased and changed', async () => {
      const { view, collector } = await makeScene(book);
      const cp = checkpointOf(view);
      deleteChapter4(view);

      // matched: a press with no typing since (the one case without the steps >= 1 premise: no steps is what it says)
      collector.startPress(1, getAllBlockIds());
      expect(recheck(view, collector, cp).line).toBe('typing-since-press press=1 steps=0 decision=matched');

      // rebased
      placeCaret(view, endOfParagraph(view, 'two'));
      typeText(view, 'x');
      const rebased = recheck(view, collector, cp);
      expectPremise(rebased);

      // changed: an automatic rewrite that lands right against the typed text (the order of the two cannot be told apart)
      view.dispatch(view.state.tr.insertText('!', endOfParagraph(view, 'twox')).setMeta('addToHistory', false));
      const changed = recheck(view, collector, cp);
      expect(changed.steps.length).toBeGreaterThanOrEqual(1);
      expect(changed.line).toBe('typing-since-press press=1 steps=2 decision=changed');
    });

    it('has exactly the documented text for every decision', () => {
      expect(formatTypingSincePressLine(3, 12, 'unplaceable')).toBe(
        'typing-since-press press=3 steps=12 decision=unplaceable'
      );
      expect(formatTypingSincePressLine(1, 0, 'noEntry')).toBe('typing-since-press press=1 steps=0 decision=noEntry');
      expect(formatTypingSincePressLine(1, 0, 'midOp')).toBe('typing-since-press press=1 steps=0 decision=midOp');
    });
  });

  describe('W15: the dry run leaves the live editor alone', () => {
    it('restores the live block ids', async () => {
      const { view, collector } = await makeScene(book);
      const cp = checkpointOf(view);
      deleteChapter4(view);
      collector.startPress(1, getAllBlockIds());
      placeCaret(view, endOfParagraph(view, 'two'));
      typeText(view, 'xy');
      expect(pressEnter(view)).toBe(true); // a new block: the throwaway apply gives it an id of its own
      typeText(view, 'z');
      flushPendingBlockChanges();
      const idsBefore = getAllBlockIds();

      const result = recheck(view, collector, cp);
      expectPremise(result);
      expect(getAllBlockIds()).toEqual(idsBefore);
    });

    it('leaves block-sync with nothing new to detect', async () => {
      const { view, collector } = await makeScene(book);
      const cp = checkpointOf(view);
      deleteChapter4(view);
      collector.startPress(1, getAllBlockIds());
      placeCaret(view, endOfParagraph(view, 'two'));
      typeText(view, 'xyz');
      flushPendingBlockChanges();
      expect(hasUnsettledLocalEdit()).toBe(false);

      const result = recheck(view, collector, cp);
      expectPremise(result);
      expect(hasUnsettledLocalEdit()).toBe(false);
    });
  });

  describe('the collector', () => {
    it('W16: a transaction appended to typing is typing; the same change on its own is not', async () => {
      const appendPlugin = $prose(
        () =>
          new Plugin({
            appendTransaction(transactions, _old, newState) {
              if (!transactions[0]?.getMeta('addBang') || transactions.length > 1) return null;
              return newState.tr.insertText('!', newState.selection.from).setMeta('addToHistory', false);
            },
          })
      );
      const { view, collector } = await makeScene(book, [appendPlugin]);
      collector.startPress(1, getAllBlockIds());
      placeCaret(view, endOfParagraph(view, 'two'));
      view.dispatch(view.state.tr.insertText('.').setMeta('addBang', true));
      expect(describeBlockStartingWith(view, 'two')).toBe('two.!');
      expect(collector.stepsSince(1).length).toBe(2);
      expect(collector.stepsSince(1).map((recorded) => recorded.typing)).toEqual([true, true]);

      view.dispatch(view.state.tr.insertText('?').setMeta('addToHistory', false));
      expect(collector.stepsSince(1).map((recorded) => recorded.typing)).toEqual([true, true, false]);
    });

    it('W17: the document at the press has ALL steps since then inverted, typing or not', async () => {
      const { view, collector } = await makeScene(book);
      collector.startPress(1, getAllBlockIds());
      const atPress = view.state.doc;
      placeCaret(view, endOfParagraph(view, 'two'));
      typeText(view, 'xyz');
      view.dispatch(view.state.tr.insertText('~', endOfParagraph(view, 'one')).setMeta('addToHistory', false));
      typeText(view, 'q');
      expect(collector.stepsSince(1).length).toBeGreaterThanOrEqual(5);
      const back = docAtPress(collector, 1, view.state.doc);
      expect(back.ok).toBe(true);
      expect(back.doc.eq(atPress)).toBe(true);
    });

    it('W17b: a step that does not invert returns the live document and the press is changed', async () => {
      const { view, collector } = await makeScene(book);
      collector.startPress(1, getAllBlockIds());
      placeCaret(view, endOfParagraph(view, 'two'));
      typeText(view, 'x');
      const [recorded] = collector.stepsSince(1);
      // An inverse that cannot apply to the live document.
      const broken: RecordedStep = { ...recorded, inverted: new ReplaceStep(10_000, 10_001, Slice.empty) };
      collector.adoptRebased(1, [broken]);
      const inspection = inspectPress(collector, 1, view.state.doc);
      expect(inspection.kind).toBe('changed');
      expect(inspection.docAtPress).toBe(view.state.doc);
    });

    it('W18: reset forgets everything and recording stops', async () => {
      const { view, collector } = await makeScene(book);
      collector.startPress(1, getAllBlockIds());
      placeCaret(view, endOfParagraph(view, 'two'));
      typeText(view, 'x');
      expect(collector.stepsSince(1).length).toBe(1);
      collector.reset();
      expect(collector.isRecording).toBe(false);
      typeText(view, 'y');
      expect(collector.stepsSince(1).length).toBe(0);
      expect(collector.idsAtPress(1)).toBeUndefined();
    });
  });

  describe('the commute: typing first, an automatic rewrite after it (round 3)', () => {
    const topTexts = (doc: ProsemirrorNode): string[] => {
      const out: string[] = [];
      doc.forEach((node) => {
        out.push(describeBlock(node));
      });
      return out;
    };

    it('C1: typing, then an automatic change elsewhere: the press acts on the document at the press WITH the change, the typing comes after it, once', async () => {
      const { view, collector } = await makeScene(book);
      const cp = checkpointOf(view);
      deleteChapter4(view);
      collector.startPress(1, getAllBlockIds());
      placeCaret(view, endOfParagraph(view, 'two'));
      typeText(view, 'xy');
      view.dispatch(view.state.tr.insertText('~', endOfParagraph(view, 'one')).setMeta('addToHistory', false)); // the rebuild, after the typing

      const result = recheck(view, collector, cp);

      expectPremise(result);
      expect(result.inspection.kind).toBe('typing');
      expect(result.inspection.typing.length, 'the two letters, and nothing automatic').toBe(2);
      expect(
        topTexts(result.inspection.docAtPress),
        'the press acts on the document at the press, rewrite included'
      ).toEqual(['Chapter 1', 'one~', 'Chapter 2', 'two', 'Chapter 3', 'three']);
      swapAndReplay(view, cp, result.dry);
      expect(texts(view)).toEqual([...topTexts(cp.state.doc).slice(0, 3), 'twoxy', ...topTexts(cp.state.doc).slice(4)]);
    });

    // The commute refuses in two separate places and each has its own test here (the route-level tests cannot tell them apart: the
    // saved-copy comparison refuses too): guard B, the final check "the rebased typing on top of the result is the live document" (C2),
    // and guard A, the null map in `rebaseTypingOver` (C3).
    it('C2 (final check): an automatic change that rewrote the very text the user typed in has no order: changed (refused, the typing kept)', async () => {
      const { view, collector } = await makeScene(book);
      collector.startPress(1, getAllBlockIds());
      placeCaret(view, endOfParagraph(view, 'two'));
      typeText(view, 'xy');
      const from = endOfParagraph(view, 'twoxy') - 'twoxy'.length;
      view.dispatch(
        view.state.tr
          .replaceWith(from, from + 'twoxy'.length, view.state.schema.text('TWOXY'))
          .setMeta('addToHistory', false)
      ); // a rebuild that writes the paragraph again

      const inspection = inspectPress(collector, 1, view.state.doc);

      expect(collector.stepsSince(1).length, 'premise: the typing and the rewrite were recorded').toBe(3);
      expect(inspection.kind).toBe('changed');
      expect(inspection.docAtPress, 'the live document is handed back').toBe(view.state.doc);
    });

    it('C3 (no place for the typing): the user typed strictly INSIDE text that an automatic change then rewrote: changed, not matched', async () => {
      const { view, collector } = await makeScene(book);
      collector.startPress(1, getAllBlockIds());
      placeCaret(view, endOfParagraph(view, 'two') - 1); // tw|o
      typeText(view, 'x');
      expect(describeBlockStartingWith(view, 'tw')).toBe('twxo');
      const from = endOfParagraph(view, 'twxo') - 'twxo'.length;
      view.dispatch(
        view.state.tr
          .replaceWith(from, from + 'twxo'.length, view.state.schema.text('TWO'))
          .setMeta('addToHistory', false)
      ); // a rebuild that writes the paragraph again: the typed letter sat inside the text it replaced
      expect(collector.stepsSince(1).length, 'premise: the typing and the rewrite were recorded').toBe(2);

      const inspection = inspectPress(collector, 1, view.state.doc);

      // Without the rule the typing step would just be dropped and the result (the rewrite alone) would equal the live document: the
      // press would be `matched`, silently ignoring that the user had typed there.
      expect(inspection.kind).toBe('changed');
    });
  });
});
