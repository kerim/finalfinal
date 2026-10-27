// @vitest-environment jsdom
//
// Redo after a structural operation, Rich Text (t-14f908b4): the user's typing inside text that an operation added comes back when
// the operation is undone and redone. Each test states the behaviour the user is owed and runs the everyday sequence.
//
// The sequence: do a structural operation, type somewhere, press Cmd-Z until the typing and then the operation are undone, then
// press Cmd-Shift-Z until both are redone. The typed text must be back, where it was typed, and nothing else may differ from the
// document the user had right after typing. (Typing done BEFORE the operation is the control: it never depended on the fix.)
//
// The mechanism under test (redo-branch.ts, api-section-undo.ts): the quick undo of a Duplicate / restore keeps the live redo
// branch aside (`setAsideRedoBranch`), and the quick redo, once it has run the operation again, puts it back
// (`putBackAfterQuickRedo`), mapped through the difference between the document it belongs to and the document the redo produced.
//
//   RP1  the Rich Text DRAG (slow route: structuralSwapEditorFirst swaps whole saved states, redo checkpoint included): never had
//        the problem, pinned so it stays that way
//   RP2  the Duplicate (quick route: undoSectionDeleteEditorFirst + carryRedoBranch, the redo is a fresh re-run)
//   RP4  Restore Entire Project (quick route, whole mode), by which block ids the restore hands the blocks (a, b: unchanged blocks
//        keep their ids; c: every id fresh; d, e: Swift's own rule, headings keep their ids and every paragraph is fresh)
//   RP5  Replace Current Section and Insert as New Section (quick route, range modes)
//   RR1  two full cycles after a Duplicate         RR2  two full cycles after Restore Entire Project (Swift's id rule)
//   RR3  a chapter with a footnote: the renumber and the Notes rebuild land before the typing and again after the redo
//   RR3b the same, with the renumber landing AFTER the typing (it is its own Cmd-Z step)
//   RR4  a twelve-chapter book (about 1,200 blocks)                RR5a/RR5b  the fall-backs (nothing misplaced)
//   RR6  Delete Section is left as it was (a control)              RR7  typing before the operation as well
//   RR8  two operations in a row                                   RR9  typing in the copy, then in the original
//   RR10 a plain undo and redo first, then the cycle
//   RR11 user text after the Notes: a size change BEFORE the typed position (with RR5b, the only cover of the mapping step)
//   RR13 Replace Current Section with a footnote in the section (a, b: the renumber and the Notes rebuild around the typing)
//   RR14 Insert as New Section, two cycles
//   RR15 toggling the operation off and on   RR16 a leftover record and a quick undo with nothing to set aside
//   RR17 the put-back is one meta-only transaction and tells Swift nothing
//   RR18 typing in the footnote definition the copy shares with the original (a Duplicate adds no definition of its own)
//
// Every assertion's failure message ends with the final document as `docText` prints it (headings with their '#'), so a failure
// shows where the typing ended up. Messages starting "PREMISE" mean the scenario itself did not run as written (harness problem),
// not the redo bug.
//
// The harness (editor-first-harness.ts) is the real thing: a real Milkdown editor with the block-id, block-sync and history plugins,
// `view.dispatch` wired through the production `runUndoTrackedDispatch`, a Cmd-Z as a real keydown through
// `handleUnifiedUndoKeydown`. Swift's side of the conversation is played by the test.

import { redo, redoDepth, undo } from '@milkdown/kit/prose/history';
import { Transform } from '@milkdown/kit/prose/transform';
import type { EditorView } from '@milkdown/kit/prose/view';
import { describe, expect, it } from 'vitest';
import { setContentWithBlockIds } from '../api-content';
import { deleteSectionEditorFirst } from '../api-section-delete';
import { duplicateSectionEditorFirst, redoSectionDuplicateEditorFirst } from '../api-section-duplicate';
import { reorderSectionsEditorFirst } from '../api-section-reorder';
import { redoSectionDeleteEditorFirst, undoSectionDeleteEditorFirst } from '../api-section-undo';
import {
  type ReplaceRangePayload,
  redoReplaceRangeEditorFirst,
  replaceRangeEditorFirst,
} from '../api-structural-replace';
import { type StructuralSwapPayload, structuralSwapEditorFirst } from '../api-structural-swap';
import { bibliographyEndMarkerPlugin } from '../bibliography-end-marker-plugin';
import { bibliographyPlugin } from '../bibliography-plugin';
import { getAllBlockIds } from '../block-id-plugin';
import { footnotePlugin, renumberFootnotes } from '../footnote-plugin';
import { redoBranchOf, setAsideRedoBranch, setAsideRedoOf } from '../redo-branch';
import { getRegistry, receiveUndoOutcome, setUndoDescriptor } from '../undo-coordinator';
import {
  endOfNthParagraph,
  heading,
  idsInOrder,
  load,
  makeEditor,
  markdownOf,
  type Posted,
  para,
  pressRedo,
  pressUndo,
  type Spec,
  sleep,
  swiftFinishesRedo,
  swiftFinishesUndo,
  typeInto,
  typeIntoNth,
  waitForRAF,
} from './editor-first-harness';

const OP = 'dddddddd-2222-3333-4444-555555555555';
const TYPED = ' TYPED-AFTER-THE-OP';

/** The most Cmd-Z / Cmd-Shift-Z presses a scenario makes in one direction before the probe gives up (a loop guard, not a limit). */
const MAX_PRESSES = 8;

// === Reading the document ===

/** The document as text, one block per paragraph, headings with their '#': what every failure message prints. */
function docText(view: EditorView): string {
  const lines: string[] = [];
  view.state.doc.forEach((node) => {
    const prefix = node.type.name === 'heading' ? `${'#'.repeat(node.attrs.level)} ` : '';
    lines.push(prefix + node.textContent);
  });
  return lines.join('\n\n');
}

/** The document right after the typing, which is what the redo has to give back; fails (as a premise) if the typing is not in it. */
function snapshotWith(view: EditorView, ...typed: string[]): string {
  const text = docText(view);
  for (const word of typed) expect(text, `PREMISE: "${word}" was typed`).toContain(word);
  return text;
}

/** The document must read exactly `expected`; the failure message carries both texts. */
function expectDoc(view: EditorView, expected: string, what: string): void {
  const actual = docText(view);
  expect(actual, `${what}\n--- final document ---\n${actual}\n--- expected ---\n${expected}\n---`).toBe(expected);
}

// === The press sequences ===

interface Outcome {
  ok: boolean;
  reason?: string;
}

/**
 * Cmd-Z until the operation is on top (every press before it is a text undo of typing), then the operation's own undo through
 * `perform` and Swift's reply through `finish`, then `textUndosAfter` more text undos (typing done BEFORE the operation). Returns
 * how many text undos came before the operation's.
 */
function undoThroughOperation(
  view: EditorView,
  perform: () => Outcome,
  finish: () => void,
  textUndosAfter = 0,
  op = OP
): number {
  let textUndos = 0;
  let onTop = false;
  for (let i = 0; i < MAX_PRESSES && !onTop; i++) {
    if (pressUndo(view, op)) onTop = true;
    else {
      expect(undo(view.state, view.dispatch), `PREMISE: text undo ${i + 1} found a step\n${docText(view)}`).toBe(true);
      textUndos++;
    }
  }
  expect(onTop, `PREMISE: Cmd-Z reached the operation after ${textUndos} text undos\n${docText(view)}`).toBe(true);
  const outcome = perform();
  expect(outcome.ok, `PREMISE: the structural undo: ${outcome.reason}\n${docText(view)}`).toBe(true);
  finish();
  for (let i = 0; i < textUndosAfter; i++) {
    expect(undo(view.state, view.dispatch), `PREMISE: text undo after the operation ${i + 1}\n${docText(view)}`).toBe(
      true
    );
  }
  return textUndos;
}

/** The quick undo of a Duplicate or a restore (what Swift does around `undoSectionDeleteEditorFirst`). */
const quickUndoOf = (view: EditorView, textUndosAfter = 0) =>
  undoThroughOperation(
    view,
    () => undoSectionDeleteEditorFirst(OP),
    () => swiftFinishesUndo(OP, { redoTopOpId: OP }),
    textUndosAfter
  );

/** `docText` of a document built from `specs` (a heading spec is already `# Title`, a paragraph spec its text). */
const docTextOf = (specs: Spec[]) => specs.map((s) => s.md).join('\n\n');

/**
 * Cmd-Shift-Z until nothing is left: a press that routes to the operation re-does it through `rerun` (once), every other press is
 * the editor's own text redo. Returns how many text redos happened.
 */
function redoEverything(view: EditorView, rerun: () => Outcome): number {
  let textRedos = 0;
  let operationDone = false;
  for (let i = 0; i < MAX_PRESSES; i++) {
    if (!operationDone && pressRedo(view, OP)) {
      const outcome = rerun();
      expect(outcome.ok, `PREMISE: the structural redo: ${outcome.reason}\n${docText(view)}`).toBe(true);
      swiftFinishesRedo(OP, { undoTopOpId: OP });
      operationDone = true;
    } else if (redo(view.state, view.dispatch)) {
      textRedos++;
    } else {
      break;
    }
  }
  expect(operationDone, `PREMISE: Cmd-Shift-Z reached the operation\n${docText(view)}`).toBe(true);
  return textRedos;
}

/** One operation of `redoAll`: how its Cmd-Shift-Z is redone and what Swift and the app do right after it. */
interface RedoStep {
  op: string;
  rerun: () => Outcome;
  /** The descriptor Swift pushes when it has finished the redo (which operation is on top of each stack now). */
  afterRedo: { undoTopOpId?: string; redoTopOpId?: string };
  /** What lands in the editor right after the operation was redone (the app's automatic rewrites). */
  rewrites?: () => void | Promise<void>;
}

/**
 * `redoEverything` for several operations (and the app's rewrites): Cmd-Shift-Z until nothing is left. A press that routes to the
 * next operation re-does it through its `rerun` and then lets `rewrites` land; every other press is the editor's own text redo.
 * Returns how many text redos happened and how many of the `steps` were reached (a caller that expects them all checks it AFTER
 * it has checked the document, so a redo that cannot get that far fails with the document in its message).
 */
async function redoAll(view: EditorView, steps: RedoStep[]): Promise<{ textRedos: number; reached: number }> {
  let next = 0;
  let textRedos = 0;
  for (let i = 0; i < MAX_PRESSES; i++) {
    const step = steps[next];
    if (step && pressRedo(view, step.op)) {
      const outcome = step.rerun();
      expect(
        outcome.ok,
        `PREMISE: the structural redo of ${step.op.slice(0, 8)}: ${outcome.reason}\n${docText(view)}`
      ).toBe(true);
      swiftFinishesRedo(step.op, step.afterRedo);
      await step.rewrites?.();
      next++;
    } else if (redo(view.state, view.dispatch)) {
      textRedos++;
    } else {
      break;
    }
  }
  return { textRedos, reached: next };
}

// ================================================================================================================
// RP1: the Rich Text DRAG
// ================================================================================================================

// A preamble paragraph, three chapters, and a Notes chapter last (Swift flags its heading and body as managed).
const DRAG_DOC: Spec[] = [
  para('p0', 'Preamble.'),
  heading('a', 1, 'Section A'),
  para('pa', 'A body.'),
  heading('b', 1, 'Section B'),
  para('pb', 'B body.'),
  heading('c', 1, 'Section C'),
  para('pc', 'C body.'),
  heading('notes', 1, 'Notes'),
  para('pn', 'Notes body.'),
];
const DRAG_MANAGED = ['notes', 'pn'];
/** Dragging B below C: B and C swap places. */
const DRAG_ORDER = ['a', 'c', 'b', 'notes'].map((id) => ({ id }));
const DRAG_DOC_AFTER: Spec[] = [
  DRAG_DOC[0],
  DRAG_DOC[1],
  DRAG_DOC[2],
  DRAG_DOC[5],
  DRAG_DOC[6],
  DRAG_DOC[3],
  DRAG_DOC[4],
  DRAG_DOC[7],
  DRAG_DOC[8],
];

function blockTypeOf(md: string): string {
  if (md.startsWith('#')) return 'heading';
  if (md.startsWith('![')) return 'image';
  if (md.startsWith('<!-- ::break')) return 'section_break';
  if (md.startsWith('- ')) return 'bullet_list';
  return 'paragraph';
}

/** What Swift's `editorPayload(for: planRows)` gives for these blocks, with the spec names as ids (a drag keeps every id). */
function swapPayload(specs: Spec[], managedBlockIds: string[]): StructuralSwapPayload {
  return {
    blockIds: specs.map((s) => s.name),
    expectedBlocks: specs.map((s) => ({ blockType: blockTypeOf(s.md), nonEmpty: true })),
    managedBlockIds,
  };
}

/** Cmd-Z through the drag: any text undos first, the swap with the pre-drag blocks, then `textUndosAfter` more text undos. */
const dragUndo = (view: EditorView, textUndosAfter = 0) =>
  undoThroughOperation(
    view,
    () => structuralSwapEditorFirst(OP, 'undo', swapPayload(DRAG_DOC, DRAG_MANAGED)),
    () => {
      setUndoDescriptor({ redoTopOpId: OP });
      receiveUndoOutcome(OP, 'performed');
    },
    textUndosAfter
  );

/** Cmd-Shift-Z through the drag: the swap with the post-drag blocks. */
const dragRedo = () => structuralSwapEditorFirst(OP, 'redo', swapPayload(DRAG_DOC_AFTER, DRAG_MANAGED));

describe('RP1: a Rich Text drag, typing after it, Cmd-Z x2, Cmd-Shift-Z x2', () => {
  it('RP1a: typing INSIDE the moved chapter is back after undo, undo, redo, redo', async () => {
    const { view } = await makeEditor();
    await load(DRAG_DOC);
    const r = reorderSectionsEditorFirst(OP, 'b', DRAG_MANAGED, DRAG_ORDER);
    expect(r.ok, `PREMISE: the drag: ${r.reason}`).toBe(true);
    expect(idsInOrder(), 'PREMISE: B moved below C').toEqual(DRAG_DOC_AFTER.map((s) => s.name));
    const afterDrag = docText(view);

    typeInto(view, 'B body', TYPED); // B is the chapter that moved
    const afterTyping = snapshotWith(view, TYPED);

    const textUndos = dragUndo(view);
    expect(textUndos, 'PREMISE: one text undo took the typing away').toBe(1);
    expectDoc(view, docTextOf(DRAG_DOC), 'PREMISE: the drag is undone');
    redoEverything(view, dragRedo);

    expectDoc(
      view,
      afterTyping,
      `the typing inside the moved chapter must be back (the drag alone reads:\n${afterDrag}\n)`
    );
  });

  it('RP1b: typing inside the moved chapter AND typing outside it, both done after the drag, are both back', async () => {
    const { view } = await makeEditor();
    await load(DRAG_DOC);
    expect(reorderSectionsEditorFirst(OP, 'b', DRAG_MANAGED, DRAG_ORDER).ok, 'PREMISE: the drag').toBe(true);

    typeInto(view, 'B body', ' INSIDE-THE-MOVED-CHAPTER'); // B moved
    typeInto(view, 'A body', ' OUTSIDE-IT'); // A did not move
    const afterTyping = snapshotWith(view, 'INSIDE-THE-MOVED-CHAPTER', 'OUTSIDE-IT');

    dragUndo(view);
    redoEverything(view, dragRedo);

    expectDoc(view, afterTyping, 'both typed phrases must be back, each where it was typed');
  });

  it('RP1c (control): typing BEFORE the drag is back too', async () => {
    const { view } = await makeEditor();
    await load(DRAG_DOC);
    typeInto(view, 'B body', ' TYPED-BEFORE-THE-DRAG');
    expect(reorderSectionsEditorFirst(OP, 'b', DRAG_MANAGED, DRAG_ORDER).ok, 'PREMISE: the drag').toBe(true);
    const afterDrag = docText(view);

    // Cmd-Z 1: the drag (the document equals its post-op copy); Cmd-Z 2: the typing made before it.
    dragUndo(view, 1);
    redoEverything(view, dragRedo);

    expectDoc(view, afterDrag, 'the typing made before the drag and the drag itself must both be back');
  });
});

// ================================================================================================================
// RP2: Duplicate Section
// ================================================================================================================

const DUP_DOC: Spec[] = [
  heading('h1', 1, 'Chapter'),
  para('p1', 'Chapter body.'),
  heading('a', 2, 'Section A'),
  para('pa', 'A body.'),
  heading('b', 2, 'Section B'),
  para('pb', 'B body.'),
];

describe('RP2: Duplicate Section, typing, Cmd-Z x2, Cmd-Shift-Z x2', () => {
  it('RP2a: typing INSIDE THE COPY is back after undo, undo, redo, redo', async () => {
    const { view } = await makeEditor();
    await load(DUP_DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
    const afterDuplicate = docText(view);

    typeIntoNth(view, 'A body.', 1, TYPED); // paragraph #1 starting "A body." is the copy
    const afterTyping = snapshotWith(view, TYPED);

    const textUndos = quickUndoOf(view);
    expect(textUndos, 'PREMISE: one text undo took the typing away').toBe(1);
    expectDoc(view, docTextOf(DUP_DOC), 'PREMISE: the duplicate is undone');
    redoEverything(view, () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies));

    expectDoc(
      view,
      afterTyping,
      `the typing inside the copy must be back, in the copy (the duplicate alone reads:\n${afterDuplicate}\n)`
    );
  });

  it('RP2c (control): typing BEFORE the duplicate is back too', async () => {
    const { view } = await makeEditor();
    await load(DUP_DOC);
    typeIntoNth(view, 'A body.', 0, ' TYPED-BEFORE-THE-OP');
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
    const afterDuplicate = docText(view);

    // Cmd-Z 1: the duplicate; Cmd-Z 2: the typing made before it. Cmd-Shift-Z 1: that typing; Cmd-Shift-Z 2: the duplicate.
    quickUndoOf(view, 1);
    redoEverything(view, () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies));

    expectDoc(view, afterDuplicate, 'the typing made before the duplicate and the duplicate itself must both be back');
  });

  it('RP2d: typing inside the ORIGINAL chapter, after the duplicate, is back too', async () => {
    const { view } = await makeEditor();
    await load(DUP_DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);

    typeIntoNth(view, 'A body.', 0, TYPED); // paragraph #0 starting "A body." is the original
    const afterTyping = snapshotWith(view, TYPED);

    quickUndoOf(view);
    redoEverything(view, () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies));

    expectDoc(view, afterTyping, 'the typing inside the original must be back, in the original');
  });
});

// ================================================================================================================
// RP4: Restore Entire Project, by which ids the restore gives the blocks
// ================================================================================================================

function payloadOf(
  mode: ReplaceRangePayload['mode'],
  specs: Spec[],
  extra: Partial<ReplaceRangePayload> = {}
): ReplaceRangePayload {
  return {
    mode,
    markdown: markdownOf(specs),
    blockIds: specs.map((s) => s.name),
    expectedBlocks: specs.map((s) => {
      const blockType = blockTypeOf(s.md);
      return { blockType, nonEmpty: blockType !== 'image' && blockType !== 'section_break' };
    }),
    managedIds: [],
    ...extra,
  };
}

/** The restored version: DUP_DOC with ONE block changed (Section B's body, which also gets a fresh id; every other block keeps its id). */
const RESTORED_DOC: Spec[] = [
  heading('h1', 1, 'Chapter'),
  para('p1', 'Chapter body.'),
  heading('a', 2, 'Section A'),
  para('pa', 'A body.'),
  heading('b', 2, 'Section B'),
  para('pb-restored', 'B body, as restored.'),
];

/** The payload a Restore Entire Project sends when the blocks that did not change keep their ids and the changed one gets a fresh one. */
const wholeKeepingUnchangedIds = () => payloadOf('whole', RESTORED_DOC, { managedBlockIds: [] });

/**
 * The ids Swift's own plan gives (SnapshotService+RestorePlan.swift, `preparedRowsForWholeReplace`): a heading whose title is
 * unchanged keeps its id, every other block (each paragraph, changed or not) gets a fresh one.
 */
const wholeWithSwiftsIds = () => {
  const keep = wholeKeepingUnchangedIds();
  return {
    ...keep,
    blockIds: RESTORED_DOC.map((spec) => (blockTypeOf(spec.md) === 'heading' ? spec.name : `fresh-${spec.name}`)),
  };
};

/** The same document and the same restore, but every id is fresh (a restore that re-ids every block). */
const wholeWithEveryIdFresh = () => {
  const keep = wholeKeepingUnchangedIds();
  return { ...keep, blockIds: keep.blockIds.map((id) => `fresh-${id}`) };
};

async function restoreThenTypeThenUndoRedo(
  makePayload: () => ReplaceRangePayload,
  typeStartsWith: string,
  expectedIdsAfterRestore: string[]
): Promise<void> {
  const { view } = await makeEditor();
  await load(DUP_DOC);
  const first = replaceRangeEditorFirst(OP, makePayload());
  expect(first.ok, `PREMISE: the restore: ${first.reason}`).toBe(true);
  expect(idsInOrder(), 'PREMISE: the ids the restore gave the blocks').toEqual(expectedIdsAfterRestore);

  typeInto(view, typeStartsWith, TYPED);
  const afterTyping = snapshotWith(view, TYPED);

  const textUndos = quickUndoOf(view);
  expect(textUndos, 'PREMISE: one text undo took the typing away').toBe(1);
  expectDoc(view, docTextOf(DUP_DOC), 'PREMISE: the restore is undone');
  redoEverything(view, () => redoReplaceRangeEditorFirst(OP, makePayload()));

  expectDoc(view, afterTyping, `the typing inside "${typeStartsWith}..." must be back`);
}

describe('RP4: Restore Entire Project (whole mode), typing after it, Cmd-Z x2, Cmd-Shift-Z x2', () => {
  it('RP4a-changed-block-typing: unchanged blocks keep their ids; typing inside the CHANGED block is back', async () => {
    await restoreThenTypeThenUndoRedo(wholeKeepingUnchangedIds, 'B body, as restored', [
      'h1',
      'p1',
      'a',
      'pa',
      'b',
      'pb-restored',
    ]);
  });

  it('RP4b-unchanged-block-typing: unchanged blocks keep their ids; typing inside an UNCHANGED block is back', async () => {
    await restoreThenTypeThenUndoRedo(wholeKeepingUnchangedIds, 'A body', ['h1', 'p1', 'a', 'pa', 'b', 'pb-restored']);
  });

  it("RP4d-swift-ids-unchanged-block-typing: headings keep their ids, every paragraph is fresh (Swift's rule); typing inside an UNCHANGED paragraph is back", async () => {
    await restoreThenTypeThenUndoRedo(wholeWithSwiftsIds, 'A body', [
      'h1',
      'fresh-p1',
      'a',
      'fresh-pa',
      'b',
      'fresh-pb-restored',
    ]);
  });

  it("RP4e-swift-ids-changed-block-typing: headings keep their ids, every paragraph is fresh (Swift's rule); typing inside the CHANGED paragraph is back", async () => {
    await restoreThenTypeThenUndoRedo(wholeWithSwiftsIds, 'B body, as restored', [
      'h1',
      'fresh-p1',
      'a',
      'fresh-pa',
      'b',
      'fresh-pb-restored',
    ]);
  });

  it('RP4c-all-fresh-ids-unchanged-block-typing: every id is fresh; typing inside an UNCHANGED block is back', async () => {
    await restoreThenTypeThenUndoRedo(wholeWithEveryIdFresh, 'A body', [
      'fresh-h1',
      'fresh-p1',
      'fresh-a',
      'fresh-pa',
      'fresh-b',
      'fresh-pb-restored',
    ]);
  });
});

// ================================================================================================================
// RP5: Replace Current Section and Insert as New Section
// ================================================================================================================

describe('RP5: Replace Current Section / Insert as New Section, typing after it, Cmd-Z x2, Cmd-Shift-Z x2', () => {
  it('RP5a-replace-section-typing-in-replaced-body: typing inside the replaced section is back', async () => {
    const makePayload = () =>
      payloadOf('section', [heading('a', 2, 'Section A restored'), para('pa2', 'A restored body.')], {
        rootBlockId: 'a',
      });
    const { view } = await makeEditor();
    await load(DUP_DOC);
    const first = replaceRangeEditorFirst(OP, makePayload());
    expect(first.ok, `PREMISE: the replace: ${first.reason}`).toBe(true);

    typeInto(view, 'A restored body', TYPED);
    const afterTyping = snapshotWith(view, TYPED);

    expect(quickUndoOf(view), 'PREMISE: one text undo took the typing away').toBe(1);
    redoEverything(view, () => redoReplaceRangeEditorFirst(OP, makePayload()));

    expectDoc(view, afterTyping, 'the typing inside the replaced section must be back');
  });

  it('RP5b-insert-as-new-section-typing-in-inserted-body: typing inside the inserted section is back', async () => {
    const makePayload = () =>
      payloadOf('insertAfter', [heading('ins', 2, 'Inserted'), para('insp', 'Inserted body.')], {
        anchorBlockId: 'pa',
      });
    const { view } = await makeEditor();
    await load(DUP_DOC);
    const first = replaceRangeEditorFirst(OP, makePayload());
    expect(first.ok, `PREMISE: the insert: ${first.reason}`).toBe(true);

    typeInto(view, 'Inserted body', TYPED);
    const afterTyping = snapshotWith(view, TYPED);

    expect(quickUndoOf(view), 'PREMISE: one text undo took the typing away').toBe(1);
    redoEverything(view, () => redoReplaceRangeEditorFirst(OP, makePayload()));

    expectDoc(view, afterTyping, 'the typing inside the inserted section must be back');
  });
});

// ================================================================================================================
// RR: the redo of typing after a Duplicate / restore (t-14f908b4), the fix's own tests
// ================================================================================================================

/** The four keys of a full cycle on a quick-route operation: Cmd-Z until the typing and the operation are both undone, then
 * Cmd-Shift-Z until both are redone. `undone` is the document the user must see in the middle (the operation undone). */
function quickCycle(view: EditorView, rerun: () => Outcome, undone: string, what: string): void {
  expect(quickUndoOf(view), `PREMISE: one text undo took the typing away (${what})`).toBe(1);
  expectDoc(view, undone, `PREMISE: the operation is undone (${what})`);
  redoEverything(view, rerun);
}

describe('RR1: Duplicate, typing in the copy, Cmd-Z x2, Cmd-Shift-Z x2, twice over', () => {
  it('RR1: the typing inside the copy is back after each of two cycles, once, in the copy', async () => {
    const { view } = await makeEditor();
    await load(DUP_DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);

    typeIntoNth(view, 'A body.', 1, TYPED);
    const afterTyping = snapshotWith(view, TYPED);
    const rerun = () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies);

    for (const cycle of [1, 2]) {
      quickCycle(view, rerun, docTextOf(DUP_DOC), `cycle ${cycle}`);
      expectDoc(view, afterTyping, `copy typing not back after cycle ${cycle}`);
    }
  });
});

describe('RR2: Restore Entire Project with the ids Swift gives, typing in an unchanged paragraph, twice over', () => {
  it('RR2: the typing is back after each of two cycles', async () => {
    const { view } = await makeEditor();
    await load(DUP_DOC);
    const first = replaceRangeEditorFirst(OP, wholeWithSwiftsIds());
    expect(first.ok, `PREMISE: the restore: ${first.reason}`).toBe(true);

    typeInto(view, 'A body', TYPED); // an UNCHANGED paragraph, which still has a fresh id
    const afterTyping = snapshotWith(view, TYPED);
    const rerun = () => redoReplaceRangeEditorFirst(OP, wholeWithSwiftsIds());

    for (const cycle of [1, 2]) {
      quickCycle(view, rerun, docTextOf(DUP_DOC), `cycle ${cycle}`);
      expectDoc(view, afterTyping, `restore typing not back after cycle ${cycle}`);
    }
  });
});

// ================================================================================================================
// RR3 / RR3b: a chapter with a footnote. A Duplicate itself does NOT renumber footnotes: a copy repeats the labels the original
// already has, so the app creates no renumber and no new definition for it. The renumber and the Notes rebuild these tests play
// STAND IN for the ones a LATER footnote insertion causes: the app renumbers the references in text order (a RECORDED text-undo
// step, tagged `derivedCorrection`, kept across a redo branch by `dispatchDerivedCorrection`) and rebuilds the Notes
// (history-neutral). The tests guard that a renumber landing before or after the typing does not empty the redo list.
// ================================================================================================================

const NOTES_IDS = ['notes', 'n1', 'n2', 'n3'];
const FN_DOC: Spec[] = [
  heading('h1', 1, 'Chapter'),
  para('p1', 'Chapter body.[^1]'),
  heading('a', 2, 'Section A'),
  para('pa', 'A body.[^2]'),
  heading('b', 2, 'Section B'),
  para('pb', 'B body.[^3]'),
  heading('notes', 2, 'Notes'),
  para('n1', '[^1]: Note one.'),
  para('n2', '[^2]: Note two.'),
  para('n3', '[^3]: Note three.'),
];

/** `docText` with the footnote labels: a reference reads `[^2]`, a definition `[^2]:`. */
function docTextWithNotes(view: EditorView): string {
  const lines: string[] = [];
  view.state.doc.forEach((node) => {
    const prefix = node.type.name === 'heading' ? `${'#'.repeat(node.attrs.level)} ` : '';
    let text = '';
    node.forEach((child) => {
      if (child.isText) text += child.text;
      else if (child.type.name === 'footnote_ref') text += `[^${child.attrs.label}]`;
      else if (child.type.name === 'footnote_def') text += `[^${child.attrs.label}]:`;
      else text += child.textContent;
    });
    lines.push(prefix + text);
  });
  return lines.join('\n\n');
}

/** Two texts must be equal; the failure message carries both. */
function expectSameText(actual: string, expected: string, what: string): void {
  expect(actual, `${what}\n--- final document ---\n${actual}\n--- expected ---\n${expected}\n---`).toBe(expected);
}

const referenceLabels = (view: EditorView): string[] => {
  const labels: string[] = [];
  view.state.doc.descendants((node) => {
    if (node.type.name === 'footnote_ref') labels.push(String(node.attrs.label));
  });
  return labels;
};

const definitionLabels = (view: EditorView): string[] => {
  const labels: string[] = [];
  view.state.doc.descendants((node) => {
    if (node.type.name === 'footnote_def') labels.push(String(node.attrs.label));
  });
  return labels;
};

// Rewrites of the kind a LATER footnote insertion sets off (a Duplicate itself sets off none of them: the copy repeats the labels the
// original already has), played with the REAL functions where the editor has them (reorder-footnote-undo-routing.test.ts has the
// same pattern for a reorder). The tests use them to put a renumber and a Notes rebuild around the typing:
//   1. the copy's reference gets a label of its own, the next free one (the stand-in for the new reference of the insertion; a
//      history-neutral change);
//   2. Swift's footnote write: every reference is numbered in text order, through the real `renumberFootnotes(mapping)` with the
//      mapping `FootnoteSyncService.computeRenumberMapping` builds (a RECORDED text-undo step, `derivedCorrection`);
//   3. Swift's Notes rebuild: the database's document is pushed with `setContentWithBlockIds` and `preserveUserBlocks`, so the
//      user's own blocks stay as the editor has them and only the Notes run is taken from the push (history-neutral).

const FN_TAIL: Spec[] = [...FN_DOC, heading('after', 2, 'Afterword'), para('pafter', 'Closing words.')];

/** Step 1. */
function copyGetsItsOwnLabel(view: EditorView): void {
  const seen = new Set<string>();
  let max = 0;
  let target = -1;
  view.state.doc.descendants((node, pos) => {
    if (node.type.name !== 'footnote_ref') return;
    const label = String(node.attrs.label);
    max = Math.max(max, Number(label));
    if (seen.has(label) && target < 0) target = pos;
    seen.add(label);
  });
  expect(target, 'PREMISE: the copy repeats a label').toBeGreaterThan(-1);
  const node = view.state.doc.nodeAt(target) as NonNullable<ReturnType<EditorView['state']['doc']['nodeAt']>>;
  view.dispatch(
    view.state.tr
      .setNodeMarkup(target, undefined, { ...node.attrs, label: String(max + 1) })
      .setMeta('addToHistory', false)
  );
}

/** Step 2: the mapping Swift builds from the references in text order (`computeRenumberMapping`). */
function swiftRenumbersInTextOrder(view: EditorView): void {
  const mapping: Record<string, string> = {};
  referenceLabels(view).forEach((label, index) => {
    if (label !== String(index + 1)) mapping[label] = String(index + 1);
  });
  renumberFootnotes(mapping);
}

/** Step 3: the database's document after the duplicate and the renumber: the copy's blocks (the ids the click minted), the
 * Notes with one more definition (the stand-in for the new footnote's), and the tail section when the document has one. */
async function swiftPushesNotes(copies: Array<{ newId: string }>, withTail: boolean): Promise<void> {
  const db: Spec[] = [
    heading('h1', 1, 'Chapter'),
    para('p1', 'Chapter body.[^1]'),
    heading('a', 2, 'Section A'),
    para('pa', 'A body.[^2]'),
    heading(copies[0].newId, 2, 'Section A copy'),
    para(copies[1].newId, 'A body.[^3]'),
    heading('b', 2, 'Section B'),
    para('pb', 'B body.[^4]'),
    heading('notes', 2, 'Notes'),
    para('n1', '[^1]: Note one.'),
    para('n2', '[^2]: Note two.'),
    para('nc', '[^3]: Note two, in the copy.'),
    para('n3', '[^4]: Note three.'),
  ];
  if (withTail) db.push(heading('after', 2, 'Afterword'), para('pafter', 'Closing words.'));
  setContentWithBlockIds(
    markdownOf(db),
    db.map((s) => s.name),
    { managedBlockIds: ['notes', 'n1', 'n2', 'nc', 'n3'], preserveUserBlocks: true }
  );
  await waitForRAF();
  await sleep(150);
}

/** Steps 2 and 3 (the debounced part of the app's footnote work). */
async function swiftFootnoteWrite(view: EditorView, copies: Array<{ newId: string }>, withTail = false): Promise<void> {
  swiftRenumbersInTextOrder(view);
  await swiftPushesNotes(copies, withTail);
}

/** The editor with the footnote plugin (and the bibliography plugins the Notes push expects), as the reorder routing test builds it. */
const makeFootnoteEditor = () => makeEditor([footnotePlugin, bibliographyPlugin, bibliographyEndMarkerPlugin].flat());

describe('RR3: Duplicate of a chapter with a footnote, the renumber and the Notes rebuild before the typing and again after the redo', () => {
  it('RR3: the typing inside the copy is back, after the reference, and every label is the renumbered one', async () => {
    const { view } = await makeFootnoteEditor();
    await load(FN_DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', NOTES_IDS);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
    // All of the rewrites land before anything is typed (stand-in for a footnote inserted right after the click): the saved copy
    // takes them in.
    const rewrites = async () => {
      copyGetsItsOwnLabel(view);
      await swiftFootnoteWrite(view, first.copies);
    };
    await rewrites();
    expect(referenceLabels(view), 'PREMISE: the references are numbered in text order').toEqual(['1', '2', '3', '4']);
    expect(definitionLabels(view), 'PREMISE: the Notes have one definition per reference').toEqual([
      '1',
      '2',
      '3',
      '4',
    ]);

    typeIntoNth(view, 'A body.', 1, TYPED); // after the copy's footnote reference
    const afterTyping = docTextWithNotes(view);
    expect(afterTyping, 'PREMISE: the typing is in the document').toContain(TYPED);

    const textUndos = undoThroughOperation(
      view,
      () => undoSectionDeleteEditorFirst(OP),
      () => swiftFinishesUndo(OP, { redoTopOpId: OP })
    );
    expect(textUndos, 'PREMISE: one text undo took the typing away').toBe(1);
    expect(referenceLabels(view), 'PREMISE: the operation is undone, the first labels are back').toEqual([
      '1',
      '2',
      '3',
    ]);
    expect(docTextWithNotes(view), 'PREMISE: the typing is undone').not.toContain(TYPED);
    const { reached } = await redoAll(view, [
      {
        op: OP,
        rerun: () => redoSectionDuplicateEditorFirst(OP, 'a', NOTES_IDS, first.copies),
        afterRedo: { undoTopOpId: OP },
        rewrites, // the same rewrites land again after the redo
      },
    ]);

    expectSameText(docTextWithNotes(view), afterTyping, 'copy typing not back (footnote)');
    expect(reached, 'PREMISE: Cmd-Shift-Z reached the operation').toBe(1);
  });

  it('RR3b: the renumber lands AFTER the typing (its own Cmd-Z step): the typing is back with the renumbered labels', async () => {
    const { view } = await makeFootnoteEditor();
    await load(FN_DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', NOTES_IDS);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
    copyGetsItsOwnLabel(view); // the copy has its own label before the user has typed a word (stand-in for a footnote insertion)

    typeIntoNth(view, 'A body.', 1, TYPED); // typing starts at once ...
    await swiftFootnoteWrite(view, first.copies); // ... and Swift's footnote write and Notes rebuild land after it (3 s debounce)
    const afterTyping = docTextWithNotes(view);
    expect(afterTyping, 'PREMISE: the typing is in the document').toContain(TYPED);
    expect(referenceLabels(view), 'PREMISE: the renumber landed').toEqual(['1', '2', '3', '4']);
    expect(definitionLabels(view), 'PREMISE: the Notes were rebuilt').toEqual(['1', '2', '3', '4']);

    // Cmd-Z until the typing AND the copy are gone: the renumber is a step of its own, so it takes one press more than usual.
    const textUndos = undoThroughOperation(
      view,
      () => undoSectionDeleteEditorFirst(OP),
      () => swiftFinishesUndo(OP, { redoTopOpId: OP })
    );
    expect(textUndos, 'PREMISE: the renumber and the typing took one text undo each').toBe(2);
    const { reached } = await redoAll(view, [
      {
        op: OP,
        rerun: () => redoSectionDuplicateEditorFirst(OP, 'a', NOTES_IDS, first.copies),
        afterRedo: { undoTopOpId: OP },
      },
    ]);
    await swiftPushesNotes(first.copies, false); // the Notes are rebuilt again once the references are numbered again

    expectSameText(docTextWithNotes(view), afterTyping, 'copy typing not back (the renumber landed after the typing)');
    expect(reached, 'PREMISE: Cmd-Shift-Z reached the operation').toBe(1);
  });
});

// ================================================================================================================
// RR4: a twelve-chapter book
// ================================================================================================================

const SENTENCE =
  'The fieldwork continued through the monsoon season while the archive stayed closed to outside readers. ';
const PARAGRAPH = SENTENCE.repeat(6).trim();

/** Twelve chapters of sixteen sections of five paragraphs: about 1,200 top-level blocks (QU19i's book without the footnotes). */
function generateBook(): Spec[] {
  const specs: Spec[] = [];
  for (let c = 1; c <= 12; c++) {
    specs.push(heading(`ch${c}`, 1, `Chapter ${c}`));
    specs.push(para(`ch${c}-intro`, `Chapter ${c}. ${PARAGRAPH}`));
    for (let s = 1; s <= 16; s++) {
      specs.push(heading(`ch${c}-s${s}`, 2, `Section ${c}.${s}`));
      for (let k = 1; k <= 5; k++) specs.push(para(`ch${c}-s${s}-p${k}`, `Paragraph ${c}.${s}.${k}. ${PARAGRAPH}`));
    }
  }
  return specs;
}

const traceLines = (posted: Posted): string[] =>
  posted.filter((p) => p.handler === 'errorHandler').map((p) => String((p.body as { message?: string }).message));

/** The text of the `nth` (0-based) top-level paragraph starting with `startsWith`. */
function paragraphText(view: EditorView, startsWith: string, nth: number): string {
  let found: string | undefined;
  let seen = 0;
  view.state.doc.forEach((node) => {
    if (found === undefined && node.type.name === 'paragraph' && node.textContent.startsWith(startsWith)) {
      if (seen === nth) found = node.textContent;
      seen++;
    }
  });
  expect(found, `paragraph #${nth} starting with "${startsWith}" must exist`).toBeDefined();
  return found as string;
}

describe('RR4: a twelve-chapter book', () => {
  it('RR4: Duplicate of chapter 6, typing in the copy, one cycle: the typing is back, and the put-back says so', async () => {
    const { view, posted } = await makeEditor();
    const specs = generateBook();
    await load(specs);
    const first = duplicateSectionEditorFirst(OP, 'ch6', []);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);

    typeIntoNth(view, 'Chapter 6.', 1, TYPED); // the copy's first paragraph
    expect(paragraphText(view, 'Chapter 6.', 1), 'PREMISE: the typing is in the copy').toMatch(/TYPED-AFTER-THE-OP$/);
    const countBefore = view.state.doc.textContent.split(TYPED).length - 1;

    expect(quickUndoOf(view), 'PREMISE: one text undo took the typing away').toBe(1);
    expect(
      traceLines(posted).some((m) => m.includes('quick-undo opId') && m.includes('setAside=1')),
      'the quick undo says it set one redo event aside'
    ).toBe(true);
    redoEverything(view, () => redoSectionDuplicateEditorFirst(OP, 'ch6', [], first.copies));

    expect(paragraphText(view, 'Chapter 6.', 1).endsWith(TYPED), 'copy typing not back (big document)').toBe(true);
    expect(view.state.doc.textContent.split(TYPED).length - 1, 'the typing is in the document once, as before').toBe(
      countBefore
    );
    expect(
      traceLines(posted).some((m) => m.includes('duplicate-quick-redo') && m.includes('redoPutBack=1')),
      'the put-back says it restored the one redo event'
    ).toBe(true);
  }, 60_000);
});

// ================================================================================================================
// RR5a / RR5b: the fall-backs. When the put-back refuses, the operation is still redone, the typing that lay OUTSIDE the new text
// is still redone (the carried branch), the typing inside it is not, and nothing is misplaced.
// ================================================================================================================

const COPY_WORDS = ' TYPED-IN-THE-COPY';
const ORIGINAL_WORDS = ' TYPED-IN-THE-ORIGINAL';

/** Duplicate, type in the copy and then in the original, Cmd-Z until the operation is undone: leaves the view ready to redo. */
async function duplicateTypedTwiceThenUndone() {
  const { view, posted } = await makeEditor();
  await load(DUP_DOC);
  const first = duplicateSectionEditorFirst(OP, 'a', []);
  expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
  typeIntoNth(view, 'A body.', 1, COPY_WORDS);
  typeIntoNth(view, 'A body.', 0, ORIGINAL_WORDS);
  const afterTyping = snapshotWith(view, COPY_WORDS, ORIGINAL_WORDS);
  expect(quickUndoOf(view), 'PREMISE: two text undos took the typing away').toBe(2);
  expectDoc(view, docTextOf(DUP_DOC), 'PREMISE: the duplicate is undone');
  const record = setAsideRedoOf(OP);
  expect(record, 'PREMISE: the quick undo kept the redo list aside').toBeDefined();
  return { view, posted, first, afterTyping, record: record as NonNullable<typeof record> };
}

describe('RR5: when the put-back refuses', () => {
  it('RR5a: a redo list that changed since the undo is not replaced: the copy is back, the typing in the original is redone, the typing in the copy is not', async () => {
    const { view, posted, first, afterTyping, record } = await duplicateTypedTwiceThenUndone();
    record.depthAfterUndo += 1; // as if the redo list had gained an event since the undo

    redoEverything(view, () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies));

    expectDoc(
      view,
      afterTyping.replace(COPY_WORDS, ''),
      'put-back used a record whose redo list changed (the copy is back, the typing in the original is redone, the copy typing is not)'
    );
    expect(
      traceLines(posted).some(
        (m) => m.includes('duplicate-quick-redo') && m.includes('redo put-back skipped: the redo list changed')
      ),
      'the refusal leaves a trace line'
    ).toBe(true);
  });

  it('RR5b: a record for another document still puts back: the typing in a block with no match in the redone document is not redone, nothing is misplaced', async () => {
    const { view, posted, first, afterTyping, record } = await duplicateTypedTwiceThenUndone();
    // The record's document, as if the copy had held other words and another block id when the undo kept the list aside: the
    // documents differ, so the id-matched steps path runs, and the copy's paragraph has no match in the redone document.
    const other = ' OTHER-WORDS';
    let copyStart = -1;
    let copyEnd = -1;
    let seen = 0;
    record.doc.forEach((node, pos) => {
      if (node.type.name === 'paragraph' && node.textContent.startsWith('A body.')) {
        if (seen === 1) {
          copyStart = pos;
          copyEnd = pos + node.nodeSize - 1;
        }
        seen++;
      }
    });
    expect(copyStart, 'PREMISE: the copy paragraph is in the record').toBeGreaterThan(-1);
    record.doc = new Transform(record.doc).insert(copyEnd, record.doc.type.schema.text(other)).doc;
    const ids = new Map<number, string>();
    for (const [pos, id] of record.ids)
      ids.set(pos > copyStart ? pos + other.length : pos, pos === copyStart ? 'no-match' : id);
    record.ids = ids;

    redoEverything(view, () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies));

    expectDoc(
      view,
      afterTyping.replace(COPY_WORDS, ''),
      'the copy is back, the typing in the original is redone, the typing in the unmatched copy is not, nothing else differs'
    );
    expect(
      traceLines(posted).some((m) => m.includes('duplicate-quick-redo') && m.includes('redoPutBack=2')),
      'the put-back succeeded (both events were put back; the one inside the unmatched block maps away)'
    ).toBe(true);
  });
});

// ================================================================================================================
// RR6: Delete Section is left as it was (a control: no put-back happens)
// ================================================================================================================

describe('RR6 (control): Delete Section, typing elsewhere, Cmd-Z x2, Cmd-Shift-Z x2', () => {
  it('RR6: the typing is back and no put-back is made (Delete never lost typing and its redo is unchanged)', async () => {
    const { view, posted } = await makeEditor();
    await load(DUP_DOC);
    expect(deleteSectionEditorFirst(OP, 'a', []).ok, 'PREMISE: the delete').toBe(true);
    typeInto(view, 'B body', TYPED);
    const afterTyping = snapshotWith(view, TYPED);

    expect(quickUndoOf(view), 'PREMISE: one text undo took the typing away').toBe(1);
    redoEverything(view, () => redoSectionDeleteEditorFirst(OP, 'a', []));

    expectDoc(view, afterTyping, 'the typing after a delete is back');
    expect(
      traceLines(posted).filter((m) => m.includes('put-back') || m.includes('redoPutBack')),
      "Delete's redo does not put anything back"
    ).toEqual([]);
  });
});

// ================================================================================================================
// RR7 to RR10: other everyday sequences
// ================================================================================================================

describe('RR7: typing before the operation as well', () => {
  it('RR7: typing in chapter B, Duplicate A, typing in the copy, Cmd-Z x3, Cmd-Shift-Z x3: both sentences are back, in order', async () => {
    const { view } = await makeEditor();
    await load(DUP_DOC);
    typeIntoNth(view, 'B body.', 0, ' TYPED-BEFORE-THE-OP');
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
    typeIntoNth(view, 'A body.', 1, TYPED);
    const afterTyping = snapshotWith(view, ' TYPED-BEFORE-THE-OP', TYPED);

    // Cmd-Z 1: the typing in the copy. Cmd-Z 2: the duplicate. Cmd-Z 3: the typing made before it.
    expect(quickUndoOf(view, 1), 'PREMISE: one text undo took the typing in the copy away').toBe(1);
    expectDoc(view, docTextOf(DUP_DOC), 'PREMISE: both sentences and the duplicate are undone');
    redoEverything(view, () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies));

    expectDoc(view, afterTyping, 'typing inside the copy not back (typing before the operation as well)');
  });
});

describe('RR8: two operations in a row', () => {
  it('RR8: Duplicate A and type in its copy, Duplicate C and type in its copy, Cmd-Z x4, Cmd-Shift-Z x4: both sentences are back, each in its copy', async () => {
    const OP2 = 'eeeeeeee-2222-3333-4444-555555555555';
    const doc: Spec[] = [
      heading('h1', 1, 'Chapter'),
      para('p1', 'Chapter body.'),
      heading('a', 2, 'Section A'),
      para('pa', 'A body.'),
      heading('b', 2, 'Section B'),
      para('pb', 'B body.'),
      heading('c', 2, 'Section C'),
      para('pc', 'C body.'),
    ];
    const { view } = await makeEditor();
    await load(doc);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `PREMISE: the first duplicate: ${first.reason}`).toBe(true);
    typeIntoNth(view, 'A body.', 1, ' TYPED-IN-COPY-A');
    const second = duplicateSectionEditorFirst(OP2, 'c', []);
    expect(second.ok, `PREMISE: the second duplicate: ${second.reason}`).toBe(true);
    typeIntoNth(view, 'C body.', 1, ' TYPED-IN-COPY-C');
    const afterTyping = snapshotWith(view, ' TYPED-IN-COPY-A', ' TYPED-IN-COPY-C');

    // Cmd-Z 1 and 2: the typing in copy C and copy C. Cmd-Z 3 and 4: the typing in copy A and copy A.
    expect(
      undoThroughOperation(
        view,
        () => undoSectionDeleteEditorFirst(OP2),
        () => swiftFinishesUndo(OP2, { undoTopOpId: OP, redoTopOpId: OP2 }),
        0,
        OP2
      ),
      'PREMISE: one text undo took the typing in copy C away'
    ).toBe(1);
    expect(
      undoThroughOperation(
        view,
        () => undoSectionDeleteEditorFirst(OP),
        () => swiftFinishesUndo(OP, { redoTopOpId: OP }),
        0,
        OP
      ),
      'PREMISE: one text undo took the typing in copy A away'
    ).toBe(1);
    expectDoc(view, docTextOf(doc), 'PREMISE: everything is undone');
    const { reached } = await redoAll(view, [
      {
        op: OP,
        rerun: () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies),
        afterRedo: { undoTopOpId: OP, redoTopOpId: OP2 },
      },
      {
        op: OP2,
        rerun: () => redoSectionDuplicateEditorFirst(OP2, 'c', [], second.copies),
        afterRedo: { undoTopOpId: OP2 },
      },
    ]);

    expectDoc(view, afterTyping, 'typing inside the copies not back (two operations in a row)');
    expect(reached, 'PREMISE: Cmd-Shift-Z reached both operations').toBe(2);
  });
});

describe('RR9: typing in the copy, then in the original', () => {
  it('RR9: both sentences are back after each of two cycles, each where it was typed', async () => {
    const { view } = await makeEditor();
    await load(DUP_DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
    typeIntoNth(view, 'A body.', 1, COPY_WORDS);
    typeIntoNth(view, 'A body.', 0, ORIGINAL_WORDS);
    const afterTyping = snapshotWith(view, COPY_WORDS, ORIGINAL_WORDS);

    for (const cycle of [1, 2]) {
      expect(quickUndoOf(view), `PREMISE: two text undos took the typing away (cycle ${cycle})`).toBe(2);
      redoEverything(view, () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies));
      expectDoc(view, afterTyping, `typing in the copy and in the original not both back after cycle ${cycle}`);
    }
  });
});

describe('RR10: a plain undo and redo of the typing first', () => {
  it('RR10: Cmd-Z, Cmd-Shift-Z with no operation step leaves the redo list as it was, and a full cycle after it still brings the typing back', async () => {
    const { view } = await makeEditor();
    await load(DUP_DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
    typeIntoNth(view, 'A body.', 1, TYPED);
    const afterTyping = snapshotWith(view, TYPED);

    expect(undo(view.state, view.dispatch), 'PREMISE: Cmd-Z takes the typing back').toBe(true);
    expect(redoDepth(view.state), 'PREMISE: the typing is redoable').toBe(1);
    expect(redo(view.state, view.dispatch), 'PREMISE: Cmd-Shift-Z brings the typing back').toBe(true);
    expect(redoDepth(view.state), 'PREMISE: nothing left to redo').toBe(0);
    expectDoc(view, afterTyping, 'PREMISE: the plain undo and redo changed nothing');

    quickCycle(
      view,
      () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies),
      docTextOf(DUP_DOC),
      'after a plain undo and redo'
    );
    expectDoc(view, afterTyping, 'copy typing not back (after a plain undo and redo)');
  });
});

// ================================================================================================================
// RR11: a size change BEFORE the typed position. In Rich Text the differences between the document the redo produces and the one
// the set-aside list belongs to are, almost always, same-size swaps (a footnote reference with another label is one leaf for one
// leaf) or lie at the end of the document (the Notes), after anything the user types in a chapter. The one realistic case that
// shifts the typed position is user text AFTER the Notes (an Afterword) when the Notes at the undo hold one definition more than
// the document the redo produces, so the typed position differs by one paragraph. The test plays that with the definition a LATER
// footnote insertion would add (a Duplicate itself adds none). RR5b alone covers the mapping in the other cases.
// ================================================================================================================

const TAIL_WORDS = ' TYPED-IN-THE-AFTERWORD';

describe('RR11: user text after the Notes, which hold one definition more than the redone document', () => {
  it('RR11: typing in the copy and in the Afterword, one cycle: both are back, each where it was typed', async () => {
    const { view } = await makeFootnoteEditor();
    await load(FN_TAIL);
    const first = duplicateSectionEditorFirst(OP, 'a', NOTES_IDS);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
    const rewrites = async () => {
      copyGetsItsOwnLabel(view);
      await swiftFootnoteWrite(view, first.copies, true);
    };
    await rewrites();
    expect(definitionLabels(view), 'PREMISE: the Notes hold the extra definition').toEqual(['1', '2', '3', '4']);

    typeIntoNth(view, 'A body.', 1, COPY_WORDS);
    typeInto(view, 'Closing words', TAIL_WORDS); // after the Notes
    const afterTyping = docTextWithNotes(view);
    expect(afterTyping, 'PREMISE: both sentences are in the document').toContain(TAIL_WORDS);

    const textUndos = undoThroughOperation(
      view,
      () => undoSectionDeleteEditorFirst(OP),
      () => swiftFinishesUndo(OP, { redoTopOpId: OP })
    );
    expect(textUndos, 'PREMISE: two text undos took the typing away').toBe(2);
    expect(definitionLabels(view), 'PREMISE: the Notes are the ones before the duplicate').toEqual(['1', '2', '3']);
    const { reached } = await redoAll(view, [
      {
        op: OP,
        rerun: () => redoSectionDuplicateEditorFirst(OP, 'a', NOTES_IDS, first.copies),
        afterRedo: { undoTopOpId: OP },
        rewrites,
      },
    ]);

    expectSameText(
      docTextWithNotes(view),
      afterTyping,
      'typing not back where it was typed (the Notes differ in size before the typed position)'
    );
    expect(reached, 'PREMISE: Cmd-Shift-Z reached the operation').toBe(1);
  });
});

// ================================================================================================================
// RR18: typing in the footnote DEFINITION the copy shares with the original. A Duplicate adds no definition of its own (a copy
// repeats the labels the original already has), so the copy's footnote reference points at the original's definition. The user
// clicks the reference (the real click handler of the reference's node view), the caret goes into that definition in the Notes, and
// the sentence is typed there. Cmd-Z x2 undoes the sentence and the Duplicate, Cmd-Shift-Z x2 redoes both: the sentence is back in
// the definition. No renumber and no Notes rebuild lands in this flow.
// ================================================================================================================

const DEFINITION_WORDS = ' TYPED-IN-THE-NOTE';

/** The click on the footnote reference of the copy (the second paragraph starting "A body."), through its node view. */
function clickReferenceInCopy(view: EditorView): void {
  let refPos = -1;
  let seen = 0;
  view.state.doc.forEach((node, pos) => {
    if (node.type.name === 'paragraph' && node.textContent.startsWith('A body.')) {
      if (seen === 1) {
        node.forEach((child, offset) => {
          if (child.type.name === 'footnote_ref') refPos = pos + 1 + offset;
        });
      }
      seen++;
    }
  });
  expect(refPos, 'PREMISE: the copy has a footnote reference').toBeGreaterThan(-1);
  const dom = view.nodeDOM(refPos);
  expect(dom, 'PREMISE: the reference is rendered').not.toBeNull();
  (dom as HTMLElement).dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  const parent = view.state.selection.$from.parent;
  expect(parent.firstChild?.type.name, 'PREMISE: the click put the caret into a footnote definition').toBe(
    'footnote_def'
  );
}

describe('RR18: typing in the footnote definition the copy shares with the original, Cmd-Z x2, Cmd-Shift-Z x2', () => {
  it('RR18: the sentence typed in the shared definition is back', async () => {
    // jsdom has no layout: scrolling a TEXT selection into view (every undo and redo does it) asks the DOM Range for its rects.
    const rangeProto = Range.prototype as unknown as Record<string, unknown>;
    const rect = { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 };
    rangeProto.getClientRects ??= () => [rect];
    rangeProto.getBoundingClientRect ??= () => rect;
    const { view, posted } = await makeFootnoteEditor();
    await load(FN_DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', NOTES_IDS);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);

    clickReferenceInCopy(view);
    view.dispatch(view.state.tr.insertText(DEFINITION_WORDS)); // the footnote text, typed at the caret
    const afterTyping = docTextWithNotes(view);
    expect(afterTyping, 'PREMISE: the sentence is in the document').toContain(DEFINITION_WORDS);

    undoThroughOperation(
      view,
      () => undoSectionDeleteEditorFirst(OP),
      () => swiftFinishesUndo(OP, { redoTopOpId: OP })
    );
    expect(docTextWithNotes(view), 'PREMISE: the sentence is undone').not.toContain(DEFINITION_WORDS);
    const { reached } = await redoAll(view, [
      {
        op: OP,
        rerun: () => redoSectionDuplicateEditorFirst(OP, 'a', NOTES_IDS, first.copies),
        afterRedo: { undoTopOpId: OP },
      },
    ]);

    expectSameText(
      docTextWithNotes(view),
      afterTyping,
      `definition typing not back; ${traceLines(posted)
        .filter((m) => m.includes('put-back') || m.includes('redoPutBack'))
        .join(' | ')}`
    );
    expect(reached, 'PREMISE: Cmd-Shift-Z reached the operation').toBe(1);
  });
});

// ================================================================================================================
// RR13 / RR14: the other restores. RR13: Replace Current Section of a version whose section holds a footnote (the app renumbers the
// restored reference and rebuilds the Notes: the old definition goes, the restored one comes), both orderings. RR14: Insert as New
// Section, two cycles.
// ================================================================================================================

describe('RR13: Replace Current Section with a footnote in the section', () => {
  const restoredSection = () =>
    payloadOf('section', [heading('a', 2, 'Section A'), para('pa2', 'A restored body.[^9]')], {
      rootBlockId: 'a',
      managedIds: NOTES_IDS,
    });

  /** The database's document after the replace and the renumber: the restored section, the Notes with the restored definition. */
  const swiftPushesRestoredNotes = async () => {
    const db: Spec[] = [
      heading('h1', 1, 'Chapter'),
      para('p1', 'Chapter body.[^1]'),
      heading('a', 2, 'Section A'),
      para('pa2', 'A restored body.[^2]'),
      heading('b', 2, 'Section B'),
      para('pb', 'B body.[^3]'),
      heading('notes', 2, 'Notes'),
      para('n1', '[^1]: Note one.'),
      para('dr', '[^2]: Restored note.'),
      para('n3', '[^3]: Note three.'),
    ];
    setContentWithBlockIds(
      markdownOf(db),
      db.map((s) => s.name),
      { managedBlockIds: ['notes', 'n1', 'dr', 'n3'], preserveUserBlocks: true }
    );
    await waitForRAF();
    await sleep(150);
  };
  const swiftFootnoteWriteForRestore = async (view: EditorView) => {
    swiftRenumbersInTextOrder(view);
    await swiftPushesRestoredNotes();
  };

  async function restoreCycle(rewritesFirst: boolean): Promise<void> {
    const { view } = await makeFootnoteEditor();
    await load(FN_DOC);
    const first = replaceRangeEditorFirst(OP, restoredSection());
    expect(first.ok, `PREMISE: the replace: ${first.reason}`).toBe(true);
    expect(referenceLabels(view), 'PREMISE: the restored reference carries its own label').toEqual(['1', '9', '3']);
    const rewrites = () => swiftFootnoteWriteForRestore(view);
    if (rewritesFirst) await rewrites();

    typeInto(view, 'A restored body', TYPED); // after the restored footnote reference
    if (!rewritesFirst) await rewrites();
    const afterTyping = docTextWithNotes(view);
    expect(afterTyping, 'PREMISE: the typing is in the document').toContain(TYPED);
    expect(referenceLabels(view), 'PREMISE: the references are numbered in text order').toEqual(['1', '2', '3']);

    undoThroughOperation(
      view,
      () => undoSectionDeleteEditorFirst(OP),
      () => swiftFinishesUndo(OP, { redoTopOpId: OP })
    );
    expect(docTextWithNotes(view), 'PREMISE: the typing is undone').not.toContain(TYPED);
    const { reached } = await redoAll(view, [
      {
        op: OP,
        rerun: () => redoReplaceRangeEditorFirst(OP, restoredSection()),
        afterRedo: { undoTopOpId: OP },
        rewrites: rewritesFirst ? rewrites : undefined,
      },
    ]);
    if (!rewritesFirst) await swiftPushesRestoredNotes();

    expectSameText(
      docTextWithNotes(view),
      afterTyping,
      `restore typing not back (footnote, ${rewritesFirst ? 'the rewrites landed before the typing' : 'the rewrites landed after the typing'})`
    );
    expect(reached, 'PREMISE: Cmd-Shift-Z reached the operation').toBe(1);
  }

  it('RR13a: the renumber and the Notes rebuild land before the typing, and again after the redo', async () => {
    await restoreCycle(true);
  });

  it('RR13b: the renumber and the Notes rebuild land after the typing (a Cmd-Z step of their own)', async () => {
    await restoreCycle(false);
  });
});

describe('RR14: Insert as New Section, twice over', () => {
  it('RR14: the typing in the inserted section is back after each of two cycles', async () => {
    const makePayload = () =>
      payloadOf('insertAfter', [heading('ins', 2, 'Inserted'), para('insp', 'Inserted body.')], {
        anchorBlockId: 'pa',
      });
    const { view } = await makeEditor();
    await load(DUP_DOC);
    const first = replaceRangeEditorFirst(OP, makePayload());
    expect(first.ok, `PREMISE: the insert: ${first.reason}`).toBe(true);
    typeInto(view, 'Inserted body', TYPED);
    const afterTyping = snapshotWith(view, TYPED);

    for (const cycle of [1, 2]) {
      quickCycle(view, () => redoReplaceRangeEditorFirst(OP, makePayload()), docTextOf(DUP_DOC), `cycle ${cycle}`);
      expectDoc(view, afterTyping, `insert typing not back after cycle ${cycle}`);
    }
  });
});

// ================================================================================================================
// RR15: toggling. People undo and redo the operation back and forth to compare; the typing must still come back exactly once.
// ================================================================================================================

describe('RR15: Duplicate, typing, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z', () => {
  it('RR15: the copy is toggled off, on, off and on; the typing is back exactly once, in the copy', async () => {
    const { view } = await makeEditor();
    await load(DUP_DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
    typeIntoNth(view, 'A body.', 1, TYPED);
    const afterTyping = snapshotWith(view, TYPED);
    const rerun = () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies);

    expect(quickUndoOf(view), 'PREMISE: Cmd-Z, Cmd-Z: the typing, then the copy').toBe(1);
    expect(pressRedo(view, OP), 'PREMISE: the first Cmd-Shift-Z is the operation').toBe(true);
    expect(rerun().ok, 'PREMISE: the copy is back').toBe(true);
    swiftFinishesRedo(OP, { undoTopOpId: OP });
    // Cmd-Z again: the typing is not redone yet, so the document is the one right after the operation and this press is the operation's
    expect(
      undoThroughOperation(
        view,
        () => undoSectionDeleteEditorFirst(OP),
        () => swiftFinishesUndo(OP, { redoTopOpId: OP })
      ),
      'PREMISE: no text undo comes before the second undo of the operation'
    ).toBe(0);
    expectDoc(view, docTextOf(DUP_DOC), 'PREMISE: the copy is gone again');
    redoEverything(view, rerun);

    expectDoc(view, afterTyping, 'copy typing not back exactly once after toggling the operation');
  });
});

// ================================================================================================================
// RR16: the record of an EARLIER undo must not be put back after a later undo that had nothing to set aside (amendment C1: the
// store deletes the operation's record when the redo list is empty). The leftover here has depth 0, the case the depth check does
// not catch (it is what a record stored after a fallen-back carry looks like), so only the delete protects.
// ================================================================================================================

describe('RR16: a leftover record and a quick undo with an empty redo list', () => {
  it('RR16: nothing is put back at the quick redo: the typing of the earlier undo does not come back', async () => {
    const { view, posted } = await makeEditor();
    await load(DUP_DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
    const afterDuplicate = docText(view);

    // A record from an earlier undo: a redo branch with one typed sentence in the copy, in the coordinates of this document.
    typeIntoNth(view, 'A body.', 1, TYPED);
    expect(undo(view.state, view.dispatch), 'PREMISE: Cmd-Z took the typing back').toBe(true);
    const branch = redoBranchOf(view.state);
    expect(branch, 'PREMISE: the typing is redoable').not.toBeNull();
    const leftover = {
      branch: branch as NonNullable<typeof branch>,
      doc: view.state.doc,
      ids: getAllBlockIds(),
      depthAfterUndo: 0,
    };
    // The redo list is emptied again and the typing removed by an automatic rewrite: the document is the one right after the operation.
    expect(redo(view.state, view.dispatch), 'PREMISE: Cmd-Shift-Z brought the typing back').toBe(true);
    const end = endOfNthParagraph(view, 'A body.', 1);
    view.dispatch(view.state.tr.delete(end - TYPED.length, end).setMeta('addToHistory', false));
    expectDoc(view, afterDuplicate, 'PREMISE: the document is the one right after the duplicate');
    expect(redoDepth(view.state), 'PREMISE: nothing to redo').toBe(0);
    setAsideRedoBranch(OP, leftover, getRegistry().keys());

    // Cmd-Z: the quick undo, with an EMPTY redo list.
    expect(
      undoThroughOperation(
        view,
        () => undoSectionDeleteEditorFirst(OP),
        () => swiftFinishesUndo(OP, { redoTopOpId: OP })
      ),
      'PREMISE: the press is the operation'
    ).toBe(0);
    expect(setAsideRedoOf(OP), 'the undo had nothing to set aside and deleted the leftover').toBeUndefined();
    redoEverything(view, () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies));

    expectDoc(view, afterDuplicate, 'a leftover record was put back (typing of the earlier undo came back)');
    expect(
      traceLines(posted).filter((m) => m.includes('redoPutBack') || m.includes('put-back skipped')),
      'nothing was put back'
    ).toEqual([]);
  });
});

// ================================================================================================================
// RR17: the put-back changes nothing Swift hears about. It is one meta-only transaction: no document change (the document is the
// same object before and after), and no message to Swift (no contentChanged, no historyEdited) is posted by it.
// ================================================================================================================

describe('RR17: the put-back is invisible to Swift', () => {
  it('RR17: one meta-only transaction, the document object unchanged, nothing posted', async () => {
    const { view, posted } = await makeEditor();
    await load(DUP_DOC);
    const first = duplicateSectionEditorFirst(OP, 'a', []);
    expect(first.ok, `PREMISE: the duplicate: ${first.reason}`).toBe(true);
    typeIntoNth(view, 'A body.', 1, TYPED);
    expect(quickUndoOf(view), 'PREMISE: one text undo took the typing away').toBe(1);

    const historyKey = (view.state as any).config.pluginsByKey.history$;
    const putBacks: Array<{ sameDocument: boolean; postedByIt: number }> = [];
    const dispatchWas = view.dispatch;
    let postedAfterPutBack = -1;
    view.dispatch = (tr) => {
      const meta = tr.getMeta(historyKey);
      const isPutBack = meta?.redo === false && meta.historyState !== undefined && !tr.docChanged;
      const docBefore = view.state.doc;
      const postedBefore = posted.length;
      dispatchWas(tr);
      if (isPutBack) {
        putBacks.push({ sameDocument: view.state.doc === docBefore, postedByIt: posted.length - postedBefore });
        postedAfterPutBack = posted.length;
      }
    };
    redoEverything(view, () => redoSectionDuplicateEditorFirst(OP, 'a', [], first.copies));
    view.dispatch = dispatchWas;

    expect(putBacks, 'exactly one meta-only history transaction puts the list back').toEqual([
      { sameDocument: true, postedByIt: 0 },
    ]);
    expect(
      posted
        .slice(postedAfterPutBack)
        .filter((p) => p.handler === 'contentChanged' || p.handler === 'historyEdited')
        .map((p) => p.handler),
      'nothing the put-back did reaches Swift'
    ).toEqual([]);
  });
});
