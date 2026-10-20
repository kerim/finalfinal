// @vitest-environment jsdom
//
// Cmd-Z after an editor-first section reorder of a chapter that holds footnotes (t-0b70d1e9, the driver's VM run of
// testReorderEFFootnoteChapterTypeDuringJob_book6; review finding W2: "after the renumber Cmd-Z still routes to the reorder").
//
// The harness loads the REAL footnote plugin, so the flow is the app's: the reorder moves the chapter (labels unchanged), the user
// types, Swift's footnote write relabels the references and definitions in text order (`renumberFootnotes(mapping)`), and the Notes
// rebuild then reaches the editor as a content push that keeps the user's blocks (`setContentWithBlockIds` with
// `preserveUserBlocks`), which leaves the definitions in a different physical order.
//
// What went wrong: the renumber was a text-undo step of its own, on top of the typing. Cmd-Z #1 took back the renumber ALONE: the
// references went back to the old numbers while the rebuilt Notes kept the new ones, so every label was defined twice with two
// different texts ("a footnote label is defined twice": never equivalent) and no later Cmd-Z could reach the structural undo.
// Now the reorder's registry entry takes the renumber in as an automatic rewrite (no history step; the saved copy follows it
// through the rebase), so Cmd-Z #1 takes back the typing and Cmd-Z #2 is the reorder's structural undo.

import { closeHistory, undo, undoDepth } from '@milkdown/kit/prose/history';
import type { Node } from '@milkdown/kit/prose/model';
import type { EditorView } from '@milkdown/kit/prose/view';
import { describe, expect, it } from 'vitest';
import { setContentWithBlockIds } from '../api-content';
import { reorderSectionsEditorFirst } from '../api-section-reorder';
import { bibliographyEndMarkerPlugin } from '../bibliography-end-marker-plugin';
import { bibliographyPlugin } from '../bibliography-plugin';
import { footnotePlugin, insertFootnote, renumberFootnotes } from '../footnote-plugin';
import { finishStructuralSwapSettle, handleUndoReplyFromSwift, performStructuralSwap } from '../undo-coordinator';
import {
  heading,
  load,
  makeEditor,
  markdownOf,
  para,
  pressRedo,
  pressUndo,
  sleep,
  typeInto,
  waitForRAF,
} from './editor-first-harness';

const OP = 'ffffffff-2222-3333-4444-555555555555';

function labelsIn(doc: Node, typeName: 'footnote_ref' | 'footnote_def'): string[] {
  const out: string[] = [];
  doc.descendants((n) => {
    if (n.type.name === typeName) out.push(String(n.attrs.label));
  });
  return out;
}

// Six chapters of ten paragraphs; the first nine of each carry a footnote: 54 notes, the shape of the book in the VM run.
const CHAPTERS = 6;
const PER = 9;
const TOTAL = CHAPTERS * PER;

function chapterSpecs(order: number[], labelOf: (original: number) => number) {
  const specs: Array<{ name: string; md: string }> = [];
  for (const c of order) {
    specs.push(heading(`c${c}`, 1, `Chapter ${c}`));
    for (let k = 1; k <= 10; k++) {
      const note = k <= PER ? `[^${labelOf((c - 1) * PER + k)}]` : '';
      specs.push(para(`p${c}-${k}`, `Chapter ${c} paragraph ${k}.${note}`));
    }
  }
  return specs;
}

/** Notes: one definition per footnote (its text names the NOTE, not its number), in the order of the labels. */
function notesSpecs(labelOf: (original: number) => number) {
  const originals = Array.from({ length: TOTAL }, (_, i) => i + 1).sort((a, b) => labelOf(a) - labelOf(b));
  return [
    heading('notes', 1, 'Notes'),
    ...originals.map((o) => para(`d-${o}`, `[^${labelOf(o)}]: Note ${o} NoteTag${o}x.`)),
  ];
}

const MANAGED = ['notes', ...Array.from({ length: TOTAL }, (_, i) => `d-${i + 1}`)];
const identity = (o: number) => o;
/** Chapter 2 (notes 10 to 18) moves above chapter 1 (notes 1 to 9): the references read in the new text order. */
const movedLabel = (o: number) => (o >= 10 && o <= 18 ? o - 9 : o <= 9 ? o + 9 : o);
const MOVED_ORDER = [
  { id: 'c2' },
  { id: 'c1' },
  { id: 'c3' },
  { id: 'c4' },
  { id: 'c5' },
  { id: 'c6' },
  { id: 'notes' },
];
const ascending = Array.from({ length: TOTAL }, (_, i) => String(i + 1));

async function bookWithChapterTwoMovedUp(): Promise<{
  view: EditorView;
  posted: Array<{ handler: string; body: any }>;
}> {
  const { view, posted } = await makeEditor([footnotePlugin, bibliographyPlugin, bibliographyEndMarkerPlugin].flat());
  await load([...chapterSpecs([1, 2, 3, 4, 5, 6], identity), ...notesSpecs(identity)]);
  const reply = reorderSectionsEditorFirst(OP, 'c2', MANAGED, MOVED_ORDER);
  expect(reply.ok, `reason: ${reply.reason}`).toBe(true);
  return { view, posted };
}

/** Swift's footnote write, as it reaches the editor: the references and definitions are relabelled in place. */
function swiftRenumbers(): void {
  const mapping: Record<string, string> = {};
  for (let o = 1; o <= TOTAL; o++) mapping[String(o)] = String(movedLabel(o));
  renumberFootnotes(mapping);
}

/** Swift's Notes rebuild: the database's document after the footnote write (new order, new labels), pushed so that the user's own
 * blocks stay as the editor has them. */
async function swiftPushesNotes(): Promise<void> {
  const db = [...chapterSpecs([2, 1, 3, 4, 5, 6], movedLabel), ...notesSpecs(movedLabel)];
  setContentWithBlockIds(
    markdownOf(db),
    db.map((s) => s.name),
    { managedBlockIds: MANAGED, preserveUserBlocks: true }
  );
  await waitForRAF();
  await sleep(150);
}

const requests = (posted: Array<{ handler: string; body: any }>) =>
  posted.filter((p) => p.handler === 'structuralUndoRequested').map((p) => p.body);

/** Swift's footnote write for whatever the references read now: every reference is numbered in text order. */
function swiftRenumbersInTextOrder(view: EditorView): void {
  const mapping: Record<string, string> = {};
  labelsIn(view.state.doc, 'footnote_ref').forEach((label, index) => {
    if (label !== String(index + 1)) mapping[label] = String(index + 1);
  });
  renumberFootnotes(mapping);
}

/** Position of the first top-level paragraph whose text starts with `prefix`. */
function paragraphAt(view: EditorView, prefix: string): number {
  let found = -1;
  view.state.doc.forEach((node, pos) => {
    if (found < 0 && node.type.name === 'paragraph' && node.textContent.startsWith(prefix)) found = pos;
  });
  expect(found, `a paragraph starting "${prefix}" exists`).toBeGreaterThanOrEqual(0);
  return found;
}

const chapterHeadings = (view: EditorView) => {
  const out: string[] = [];
  view.state.doc.forEach((node) => {
    if (node.type.name === 'heading') out.push(node.textContent);
  });
  return out.slice(0, CHAPTERS);
};
const ORIGINAL_CHAPTERS = ['Chapter 1', 'Chapter 2', 'Chapter 3', 'Chapter 4', 'Chapter 5', 'Chapter 6'];
const carriedOnce = (labels: string[]) => new Set(labels).size === labels.length;

/** The structural undo as Swift runs it: the press is routed, the editor swaps the checkpoint in, Swift answers. */
function structuralSwap(view: EditorView, direction: 'undo' | 'redo'): void {
  expect(direction === 'undo' ? pressUndo(view, OP) : pressRedo(view, OP), `the ${direction} press is routed`).toBe(
    true
  );
  expect(performStructuralSwap(OP, direction)).toBe(true);
  handleUndoReplyFromSwift({ opId: OP, outcome: 'performed' }, direction);
  finishStructuralSwapSettle();
}

describe('Cmd-Z after a reorder of a footnoted chapter (the renumber and the Notes rebuild have landed)', () => {
  it("R-FN1: no typing: the first Cmd-Z is the reorder's structural undo", async () => {
    const { view, posted } = await bookWithChapterTwoMovedUp();
    swiftRenumbers();
    await swiftPushesNotes();
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'premise: the references read in the new text order').toEqual(
      ascending
    );

    expect(pressUndo(view, OP), 'Cmd-Z routes to the reorder').toBe(true);
    expect(requests(posted)).toEqual([{ opId: OP }]);
  });

  it('R-FN2: typing before the renumber lands (the VM run): Cmd-Z #1 takes back the typing only, Cmd-Z #2 is the reorder', async () => {
    const { view, posted } = await bookWithChapterTwoMovedUp();
    typeInto(view, 'Chapter 2 paragraph 10', ' TYPED'); // typed while the reorder's job is still running
    const depthBefore = undoDepth(view.state);
    swiftRenumbers();
    expect(
      undoDepth(view.state),
      'the renumber left no step of its own in the text history (the absorb path ran)'
    ).toBe(depthBefore);
    await sleep(150);
    await swiftPushesNotes();
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'premise: the renumber landed').toEqual(ascending);
    expect(view.state.doc.textContent, 'premise: the typing is on screen').toContain('TYPED');

    // Cmd-Z #1: the typed word is on screen, so the press is the editor's own text undo ...
    expect(pressUndo(view, OP), 'press 1 is not routed to the reorder: the typing comes first').toBe(false);
    expect(undo(view.state, view.dispatch), "press 1 is the editor's text undo").toBe(true);
    // ... and it takes back the typing, NOT the renumber: the references still read in the new text order.
    expect(view.state.doc.textContent, 'the typed word is gone').not.toContain('TYPED');
    expect(
      labelsIn(view.state.doc, 'footnote_ref'),
      'the renumber was not taken back alone: the moved order never stands with the old footnote numbers'
    ).toEqual(ascending);

    // Cmd-Z #2: nothing of the user's is left, so it is the reorder's structural undo.
    expect(pressUndo(view, OP), 'press 2 routes to the reorder').toBe(true);
    expect(requests(posted)).toEqual([{ opId: OP }]);

    // The swap puts the document from before the move back: the original chapter order, the original numbers.
    expect(performStructuralSwap(OP, 'undo')).toBe(true);
    handleUndoReplyFromSwift({ opId: OP, outcome: 'performed' }, 'undo');
    const headings: string[] = [];
    view.state.doc.forEach((node) => {
      if (node.type.name === 'heading') headings.push(node.textContent);
    });
    expect(headings.slice(0, CHAPTERS)).toEqual([
      'Chapter 1',
      'Chapter 2',
      'Chapter 3',
      'Chapter 4',
      'Chapter 5',
      'Chapter 6',
    ]);
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(ascending);
    expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(ascending);
  });

  it('R-FN3: typing after the renumber: Cmd-Z #1 takes back the typing, Cmd-Z #2 is the reorder (the order the renumber came first)', async () => {
    const { view, posted } = await bookWithChapterTwoMovedUp();
    swiftRenumbers();
    await swiftPushesNotes();
    typeInto(view, 'Chapter 2 paragraph 10', ' TYPED');

    expect(pressUndo(view, OP), 'press 1: the typed word comes first').toBe(false);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('TYPED');
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(ascending);
    expect(pressUndo(view, OP), 'press 2 routes to the reorder').toBe(true);
    expect(requests(posted)).toEqual([{ opId: OP }]);
  });

  it('R-FN5: after a reorder, a renumber that changes the SET of labels (a footnote added or removed since) stays its own text-undo step', async () => {
    const { view } = await bookWithChapterTwoMovedUp();
    swiftRenumbers();
    const lastBefore = labelsIn(view.state.doc, 'footnote_ref').at(-1);
    expect(lastBefore).toBe(String(TOTAL));

    // A later footnote pushes the last reference to a label no reference carried: that renumber is not the move's.
    renumberFootnotes({ [String(TOTAL)]: String(TOTAL + 1) });
    expect(labelsIn(view.state.doc, 'footnote_ref').at(-1)).toBe(String(TOTAL + 1));

    expect(undo(view.state, view.dispatch), 'it is a step of the text history').toBe(true);
    expect(labelsIn(view.state.doc, 'footnote_ref').at(-1), 'and one Cmd-Z puts the old number back').toBe(
      String(TOTAL)
    );
  });

  it('R-FN4: without a reorder in play the renumber stays its own text-undo step', async () => {
    const { view } = await makeEditor([footnotePlugin, bibliographyPlugin, bibliographyEndMarkerPlugin].flat());
    await load([...chapterSpecs([1, 2, 3, 4, 5, 6], identity), ...notesSpecs(identity)]);
    swiftRenumbers();
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(
      ascending.map((_, i) => String(movedLabel(i + 1))).slice(0)
    );

    expect(undo(view.state, view.dispatch), 'the renumber is a step of the text history').toBe(true);

    expect(labelsIn(view.state.doc, 'footnote_ref'), 'and one Cmd-Z puts the old numbers back').toEqual(ascending);
  });

  // Review finding F1: the mark never clears, and any pure permutation of the labels would have been absorbed. A footnoted paragraph
  // cut and pasted somewhere else is a permutation too (the footnote write waits a few seconds before it renumbers), but the
  // references are no longer in the order the entry's saved copy holds: that renumber must stay a step of the text history.
  it('R-FN6: after the move and its renumber, a footnoted paragraph cut and pasted elsewhere keeps its own renumber step, and no Cmd-Z carries a label twice', async () => {
    const { view } = await bookWithChapterTwoMovedUp();
    const depthAtStart = undoDepth(view.state);
    swiftRenumbers();
    await swiftPushesNotes();
    expect(undoDepth(view.state), "premise: the move's own renumber is not a text step").toBe(depthAtStart);
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'premise: the references read 1 to 54').toEqual(ascending);

    // Cut "Chapter 1 paragraph 1." (label 10) and paste it after "Chapter 1 paragraph 3.": two text steps.
    const cutAt = paragraphAt(view, 'Chapter 1 paragraph 1.');
    const cut = view.state.doc.nodeAt(cutAt) as Node;
    view.dispatch(view.state.tr.delete(cutAt, cutAt + cut.nodeSize));
    const after = paragraphAt(view, 'Chapter 1 paragraph 3.');
    const pasteAt = after + (view.state.doc.nodeAt(after) as Node).nodeSize;
    view.dispatch(closeHistory(view.state.tr.insert(pasteAt, cut)));
    const depthAfterPaste = undoDepth(view.state);
    expect(depthAfterPaste, 'premise: the cut and the paste are text steps').toBeGreaterThan(depthAtStart);

    // The footnote write then numbers the references in the new text order: the same labels, read in another order.
    swiftRenumbersInTextOrder(view);
    expect(undoDepth(view.state), 'the paste is not the move: its renumber is a text step of its own').toBe(
      depthAfterPaste + 1
    );
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'premise: the references read 1 to 54 again').toEqual(ascending);

    // Cmd-Z through everything the user did: no step ever leaves a label carried twice.
    for (let press = 1; undoDepth(view.state) > depthAtStart; press++) {
      expect(press, 'the history runs out').toBeLessThan(8);
      expect(pressUndo(view, OP), `press ${press}: the user's own steps come first`).toBe(false);
      expect(undo(view.state, view.dispatch)).toBe(true);
      const labels = labelsIn(view.state.doc, 'footnote_ref');
      expect(carriedOnce(labels), `after press ${press} every reference label is carried once`).toBe(true);
    }
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'back to the state before the cut').toEqual(ascending);
    expect(
      labelsIn(view.state.doc, 'footnote_def').sort((a, b) => Number(a) - Number(b)),
      'and every reference has its definition'
    ).toEqual(ascending);
    expect(pressUndo(view, OP), 'nothing of the user is left: the next Cmd-Z is the reorder').toBe(true);
  });

  // Review finding F2: a footnote added before the move's renumber lands gives the new reference a label inside the existing set,
  // so Swift's mapping is still a permutation. The reference was added since the saved copy: the renumber stays a text step.
  it('R-FN7: a footnote added before the renumber lands keeps the renumber as its own text step; labels stay unique through Cmd-Z', async () => {
    const { view } = await bookWithChapterTwoMovedUp();
    const labelsBeforeInsert = labelsIn(view.state.doc, 'footnote_ref');
    const afterThirdReference: number[] = [];
    view.state.doc.descendants((node, pos) => {
      if (node.type.name === 'footnote_ref') afterThirdReference.push(pos + node.nodeSize);
    });
    expect(insertFootnote(afterThirdReference[2]), 'the new reference takes the label inside the set').toBe('4');
    const labelsAfterInsert = labelsIn(view.state.doc, 'footnote_ref');
    expect(labelsAfterInsert.length).toBe(TOTAL + 1);
    expect(carriedOnce(labelsAfterInsert)).toBe(true);
    const depthAfterInsert = undoDepth(view.state);

    swiftRenumbersInTextOrder(view);

    expect(undoDepth(view.state), 'the renumber is a text step of its own').toBe(depthAfterInsert + 1);
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(
      Array.from({ length: TOTAL + 1 }, (_, i) => String(i + 1))
    );
    expect(undo(view.state, view.dispatch), 'Cmd-Z #1 takes the renumber back').toBe(true);
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'and puts the labels the insert left').toEqual(labelsAfterInsert);
    expect(undo(view.state, view.dispatch), 'Cmd-Z #2 takes the new footnote back').toBe(true);
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'and the references read as they did after the move').toEqual(
      labelsBeforeInsert
    );
  });

  // Review finding F4: the entry stops absorbing while it is undone, and starts again when the redo swaps the document back in.
  it('R-FN8: after the reorder was undone and redone, the renumber is still absorbed: Cmd-Z takes back the typing, then the reorder', async () => {
    const { view, posted } = await bookWithChapterTwoMovedUp();
    structuralSwap(view, 'undo');
    expect(chapterHeadings(view), 'premise: the undo put the chapters back').toEqual(ORIGINAL_CHAPTERS);
    structuralSwap(view, 'redo');
    expect(chapterHeadings(view)[0], 'premise: the redo moved chapter 2 up again').toBe('Chapter 2');

    typeInto(view, 'Chapter 2 paragraph 10', ' TYPED');
    const depthBefore = undoDepth(view.state);
    swiftRenumbers();
    expect(undoDepth(view.state), 'the renumber left no step of its own').toBe(depthBefore);

    expect(pressUndo(view, OP), 'press 1: the typing comes first').toBe(false);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent, 'the typed word is gone').not.toContain('TYPED');
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'the renumber was not taken back alone').toEqual(ascending);
    const requestsBefore = requests(posted).length;
    structuralSwap(view, 'undo');
    expect(requests(posted).length, "press 2 asked Swift for the reorder's undo").toBe(requestsBefore + 1);
    expect(chapterHeadings(view), 'the sections are back in their original order').toEqual(ORIGINAL_CHAPTERS);
    const labels = labelsIn(view.state.doc, 'footnote_ref');
    expect(carriedOnce(labels)).toBe(true);
    expect(labels).toEqual(ascending);
  });

  // The overlap case: the typing is inside a paragraph that holds a reference the renumber relabels, so the saved copy cannot take
  // the renumber in (the same block changed on both sides). Cmd-Z must still take back only the typing first.
  it('R-FN9: typing inside a paragraph whose reference the renumber relabels: Cmd-Z #1 takes back the typing only, Cmd-Z #2 is the reorder', async () => {
    const { view, posted } = await bookWithChapterTwoMovedUp();
    typeInto(view, 'Chapter 2 paragraph 1.', ' TYPED'); // after the reference of the first paragraph (label 10)
    const depthBefore = undoDepth(view.state);
    swiftRenumbers();
    expect(undoDepth(view.state), 'the renumber left no step of its own (the absorb path ran)').toBe(depthBefore);
    await swiftPushesNotes();
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'premise: the renumber landed').toEqual(ascending);

    expect(pressUndo(view, OP), 'press 1: the typing comes first').toBe(false);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent, 'the typed word is gone').not.toContain('TYPED');
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'the renumber was not taken back alone').toEqual(ascending);

    const requestsBefore = requests(posted).length;
    structuralSwap(view, 'undo');
    expect(requests(posted).length, "press 2 asked Swift for the reorder's undo").toBe(requestsBefore + 1);
    expect(chapterHeadings(view), 'the sections are back in their original order').toEqual(ORIGINAL_CHAPTERS);
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'with the original labels').toEqual(ascending);
    expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(ascending);
  });
});
