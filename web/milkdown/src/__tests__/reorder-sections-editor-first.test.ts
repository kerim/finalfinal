// @vitest-environment jsdom
//
// Phase 4b, reorder job (t-0b70d1e9): `reorderSectionsEditorFirst` (api-section-reorder.ts) -- the editor moves the dragged section
// (or, for the Option drag, a section with its sub-sections) first, as ONE range move in one synchronous JavaScript turn, and hands
// Swift the batch of pending edits it consumed.
//
// W1 the move itself (one tagged transaction, every id kept, the pending batch comes back), W2 level changes, W3 managed regions,
// the preamble, the end of the document and the bibliography marker, W4 ids the editor lacks, W5 the database's grouping rule and
// refused plans, W6 text undo around the move, W7 the caret and selection, W8 spellcheck marks, W9 typewriter mode, then the
// scroll position (W10), a failure after the move (W11) and a levels-only plan (W12).
//
// The tests named R-<finding> answer the code review's findings: C1 the Notes / Bibliography region found from the live document
// (a bibliography id the editor does not have), W3 typing after the drop, W6 the viewport anchor inside a block taller than the
// screen, W9 pending typing marks, W10 a selection the moved run separates, TD-d the posted undo request.
//
// The harness (editor-first-harness.ts) is the real thing: a real Milkdown editor with the block-id, block-sync and history plugins,
// `view.dispatch` wired through the production `runUndoTrackedDispatch`. Swift's side of the conversation is played by the test.

import { undo } from '@milkdown/kit/prose/history';
import { AllSelection, NodeSelection, TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  getTypewriterTestState,
  markDocumentReady,
  resetTypewriterForTests,
  setTypewriterEnabled,
  setTypewriterLineOffset,
} from '../../../shared/typewriter-scrolling';
import { getBlockChangesApi, setContentWithBlockIds } from '../api-content';
import { reorderSectionsEditorFirst, setTestAfterReorderHook } from '../api-section-reorder';
import { bibliographyEndMarkerPlugin } from '../bibliography-end-marker-plugin';
import { bibliographyPlugin } from '../bibliography-plugin';
import { getAllBlockIds } from '../block-id-plugin';
import { flushPendingBlockChanges } from '../block-sync-plugin';
import { imagePlugin } from '../image-plugin';
import { type SpellcheckResult, spellcheckPlugin, spellcheckPluginKey } from '../spellcheck-plugin';
import { __setTypewriterTestGeometry, typewriterPlugin, typewriterPluginKey } from '../typewriter-plugin';
import { getRegistry } from '../undo-coordinator';
import {
  EMPTY_BATCH,
  heading,
  idsInOrder,
  load,
  makeEditor,
  markdownOf,
  para,
  pressUndo,
  sectionBreak,
  sleep,
  typeInto,
  typeIntoNth,
  waitForRAF,
} from './editor-first-harness';

const OP = 'ffffffff-2222-3333-4444-555555555555';

/** Section leaders in order, no level changes: `ord('b', 'a')` is [{id:'b'}, {id:'a'}]. */
const ord = (...ids: string[]) => ids.map((id) => ({ id }));

// A preamble paragraph, three chapters, and a Notes chapter last (Swift flags its heading and body as managed).
const DOC = [
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
const MANAGED = ['notes', 'pn'];

afterEach(() => {
  setTestAfterReorderHook(null);
  __setTypewriterTestGeometry(null);
  resetTypewriterForTests();
  vi.restoreAllMocks();
});

/** Every top-level block as (its id, its text), in document order. */
function blocks(view: EditorView): Array<{ id: string | undefined; text: string }> {
  const ids = getAllBlockIds();
  const out: Array<{ id: string | undefined; text: string }> = [];
  view.state.doc.forEach((node, pos) => {
    out.push({ id: ids.get(pos), text: node.textContent });
  });
  return out;
}

function posOfId(id: string): number {
  for (const [pos, blockId] of getAllBlockIds()) if (blockId === id) return pos;
  throw new Error(`no block with id ${id}`);
}

function levelOf(view: EditorView, id: string): number | undefined {
  return view.state.doc.nodeAt(posOfId(id))?.attrs.level;
}

/** The caret's head as (id of the top-level block it sits in, offset from that block's start). */
function caretOf(view: EditorView): { id: string | undefined; offset: number } {
  const head = view.state.selection.head;
  const ids = getAllBlockIds();
  let found: { id: string | undefined; offset: number } = { id: undefined, offset: -1 };
  view.state.doc.forEach((node, pos) => {
    if (head > pos && head < pos + node.nodeSize) found = { id: ids.get(pos), offset: head - pos };
  });
  return found;
}

function selectText(view: EditorView, id: string, offset: number): void {
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, posOfId(id) + offset)));
}

describe('reorderSectionsEditorFirst', () => {
  it('W1: moves B before A in ONE tagged transaction; every node keeps its id, and the pending batch comes back', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    typeInto(view, 'A body', ' (pending)'); // an edit not yet polled when the drag lands
    const before = blocks(view);
    const seen: Array<{ structuralReorder: unknown; addToHistory: unknown; steps: number }> = [];
    const dispatch = view.dispatch;
    view.dispatch = (tr) => {
      if (tr.docChanged) {
        seen.push({
          structuralReorder: tr.getMeta('structuralReorder'),
          addToHistory: tr.getMeta('addToHistory'),
          steps: tr.steps.length,
        });
      }
      dispatch(tr);
    };

    const r = reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('b', 'a', 'c', 'notes'));

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['p0', 'b', 'pb', 'a', 'pa', 'c', 'pc', 'notes', 'pn']);
    const after = blocks(view);
    for (const block of before) {
      const same = after.find((b) => b.id === block.id);
      expect(same?.text, `block ${block.id} keeps its own text`).toBe(block.text);
    }
    expect(
      r.batch.updates.map((u) => u.id),
      'the edit pending before the drag is the batch Swift applies first'
    ).toEqual(['pa']);
    expect(r.batch.updates[0].textContent).toBe('A body. (pending)');
    expect(
      seen,
      'one document-changing transaction: the cut and the insertion together, kept out of the text history'
    ).toEqual([{ structuralReorder: true, addToHistory: false, steps: 2 }]);
    expect(r.moved).toBe(2);
    expect(r.levelChanges).toBe(0);
    expect(r.skippedIds).toEqual([]);
    // The move was re-baselined: it queues nothing, not even after block-sync's own debounce has run.
    await sleep(160);
    expect(getBlockChangesApi(), 'the moved blocks are never reported as inserts or deletes').toEqual(EMPTY_BATCH);
  });

  it('W1b: a block Swift has not confirmed yet keeps its temp id through the move', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    // A new empty paragraph at the end of B's body: the editor names it with a temp id until Swift confirms one.
    view.dispatch(view.state.tr.insert(posOfId('c'), view.state.schema.nodes.paragraph.create()));
    flushPendingBlockChanges();
    const tempId = idsInOrder()[5];
    expect(tempId.startsWith('temp-')).toBe(true);

    const r = reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('b', 'a', 'c', 'notes'));

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder(), 'the unconfirmed paragraph travels with B under the same temp id').toEqual([
      'p0',
      'b',
      'pb',
      tempId,
      'a',
      'pa',
      'c',
      'pc',
      'notes',
      'pn',
    ]);
  });

  it('W2: level changes ride the same transaction; a section break and a heading with no listed level are left alone', async () => {
    const { view } = await makeEditor();
    await load([
      heading('ch1', 1, 'Chapter 1'),
      para('p1', 'One.'),
      heading('a', 2, 'Sec A'),
      para('pa', 'A.'),
      heading('b', 2, 'Sec B'),
      para('pb', 'B.'),
      heading('u', 4, 'Typed a moment ago'), // a heading the sidebar does not list yet: part of B
      heading('b1', 3, 'Sub of B'),
      para('pb1', 'B1.'),
      heading('ch2', 1, 'Chapter 2'),
      para('p2', 'Two.'),
      sectionBreak('sb'),
      para('psb', 'After the break.'),
    ]);
    const seen: number[] = [];
    const dispatch = view.dispatch;
    view.dispatch = (tr) => {
      if (tr.docChanged) seen.push(tr.steps.length);
      dispatch(tr);
    };

    // Option drag of B (with its sub-section) to the end, as a chapter: B 2 -> 1, B1 3 -> 2. The section break is given a level too.
    const r = reorderSectionsEditorFirst(
      OP,
      'b',
      [],
      [{ id: 'ch1' }, { id: 'a' }, { id: 'ch2' }, { id: 'sb', level: 3 }, { id: 'b', level: 1 }, { id: 'b1', level: 2 }]
    );

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['ch1', 'p1', 'a', 'pa', 'ch2', 'p2', 'sb', 'psb', 'b', 'pb', 'u', 'b1', 'pb1']);
    expect(levelOf(view, 'b')).toBe(1);
    expect(levelOf(view, 'b1')).toBe(2);
    expect(levelOf(view, 'a'), 'a heading with no level in the plan keeps its own').toBe(2);
    expect(levelOf(view, 'u'), 'an unlisted heading keeps its level too').toBe(4);
    expect(view.state.doc.nodeAt(posOfId('sb'))?.type.name, 'a section break is never given a heading level').toBe(
      'section_break'
    );
    expect(r.levelChanges).toBe(2);
    expect(r.moved).toBe(5);
    expect(seen.length, 'the moves and the level changes are one transaction').toBe(1);
  });

  it('W3: the preamble stays first, and a chapter moved up leaves Notes last', async () => {
    const { view } = await makeEditor();
    await load(DOC);

    const toFront = reorderSectionsEditorFirst(OP, 'c', MANAGED, ord('c', 'a', 'b', 'notes'));

    expect(toFront.ok, `reason: ${toFront.reason}`).toBe(true);
    expect(idsInOrder(), 'the preamble paragraph is still the first block').toEqual([
      'p0',
      'c',
      'pc',
      'a',
      'pa',
      'b',
      'pb',
      'notes',
      'pn',
    ]);

    const lastUp = reorderSectionsEditorFirst(
      '11111111-2222-3333-4444-555555555555',
      'b',
      MANAGED,
      ord('c', 'b', 'a', 'notes')
    );

    expect(lastUp.ok, `reason: ${lastUp.reason}`).toBe(true);
    expect(idsInOrder().slice(-2), 'Notes stays last').toEqual(['notes', 'pn']);
    expect(
      blocks(view)
        .map((b) => b.text)
        .slice(0, 3)
    ).toEqual(['Preamble.', 'Section C', 'C body.']);
  });

  it('W3: a managed root is refused: nothing dispatched, no registry entry left, the batch still returned', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    typeInto(view, 'B body', ' (pending)');
    const docBefore = view.state.doc;

    const r = reorderSectionsEditorFirst(OP, 'notes', MANAGED, ord('notes', 'a', 'b', 'c'));

    expect(r.ok).toBe(false);
    expect(r.reason).toBe('managedMoved');
    expect(r.moved).toBe(0);
    expect(
      r.batch.updates.map((u) => u.id),
      'a refusal still returns the batch it consumed'
    ).toEqual(['pb']);
    expect(view.state.doc.textContent).toBe(`${docBefore.textContent}`);
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    expect(getRegistry().has(OP), 'no registry entry is left behind').toBe(false);
  });

  it('W3: an article with no Notes and no Bibliography: the last-but-one section moves to the END of the document', async () => {
    const { view } = await makeEditor();
    await load([
      para('p0', 'Lead.'),
      heading('a', 1, 'Section A'),
      para('pa', 'A body.'),
      heading('b', 1, 'Section B'),
      para('pb', 'B body.'),
      heading('c', 1, 'Section C'),
      para('pc', 'C body.'),
      heading('d', 1, 'Section D'),
      para('pd', 'D body.'),
    ]);

    const r = reorderSectionsEditorFirst(OP, 'c', [], ord('a', 'b', 'd', 'c'));

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['p0', 'a', 'pa', 'b', 'pb', 'd', 'pd', 'c', 'pc']);
    expect(blocks(view).at(-1)?.text).toBe('C body.');
  });

  it('W3: the Bibliography marker stays glued to the Bibliography heading, whether a section moves in front of it or leaves from in front of it', async () => {
    const { view } = await makeEditor([bibliographyPlugin, bibliographyEndMarkerPlugin].flat());
    const specs = [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      heading('z', 1, 'Final chapter'),
      para('z-p1', 'Last one.'),
    ];
    const markdown = `${markdownOf(specs)}\n\n<!-- ::auto-bibliography:: -->\n\n# Bibliography\n\nSmith 2020.\n\n<!-- ::auto-bibliography-end:: -->`;
    setContentWithBlockIds(markdown, ['a', 'a-p1', 'z', 'z-p1', 'bib-h', 'bib-p']);
    await waitForRAF();
    getBlockChangesApi();
    const types = () => {
      const out: string[] = [];
      view.state.doc.forEach((node) => {
        out.push(node.type.name);
      });
      return out;
    };
    const tail = ['auto_bibliography', 'heading', 'paragraph', 'auto_bibliography_end'];

    // The last chapter leaves from right in front of the marker, going up: the marker is not taken with it.
    const up = reorderSectionsEditorFirst(OP, 'z', ['bib-h', 'bib-p'], ord('z', 'a', 'bib-h'));
    expect(up.ok, `reason: ${up.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['z', 'z-p1', 'a', 'a-p1', 'bib-h', 'bib-p']);
    expect(types()).toEqual(['heading', 'paragraph', 'heading', 'paragraph', ...tail]);

    // A chapter moved down to the end of the chapters lands BEFORE the marker, not between the marker and its heading.
    const down = reorderSectionsEditorFirst(
      '11111111-2222-3333-4444-555555555555',
      'z',
      ['bib-h', 'bib-p'],
      ord('a', 'z', 'bib-h')
    );
    expect(down.ok, `reason: ${down.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['a', 'a-p1', 'z', 'z-p1', 'bib-h', 'bib-p']);
    expect(types()).toEqual(['heading', 'paragraph', 'heading', 'paragraph', ...tail]);
  });

  it('W4: an unknown root is refused; an unknown OTHER id is skipped and reported', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    typeInto(view, 'B body', ' (pending)');
    const docBefore = view.state.doc;

    const refused = reorderSectionsEditorFirst(OP, 'no-such-id', MANAGED, ord('no-such-id', 'a', 'b', 'c', 'notes'));

    expect(refused.ok).toBe(false);
    expect(refused.reason).toBe('rootNotFound');
    expect(refused.batch.updates.map((u) => u.id)).toEqual(['pb']);
    expect(view.state.doc.eq(docBefore), 'the document is as it was').toBe(true);
    expect(getRegistry().has(OP)).toBe(false);

    const skipped = reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('b', 'a', 'ghost', 'c', 'notes'));

    expect(skipped.ok, `reason: ${skipped.reason}`).toBe(true);
    expect(skipped.skippedIds).toEqual(['ghost']);
    expect(idsInOrder()).toEqual(['p0', 'b', 'pb', 'a', 'pa', 'c', 'pc', 'notes', 'pn']);
  });

  it('W5: a heading that is not in the list moves with the leader before it; a plan that is not one moved run is refused', async () => {
    const { view } = await makeEditor();
    await load([
      para('p0', 'Preamble.'),
      heading('a', 1, 'Section A'),
      para('pa', 'A body.'),
      heading('x', 2, 'Typed a moment ago'), // not in the sidebar yet
      para('px', 'X body.'),
      heading('b', 1, 'Section B'),
      para('pb', 'B body.'),
      heading('c', 1, 'Section C'),
      para('pc', 'C body.'),
    ]);

    const moved = reorderSectionsEditorFirst(OP, 'b', [], ord('b', 'a', 'c'));

    expect(moved.ok, `reason: ${moved.reason}`).toBe(true);
    expect(idsInOrder(), 'X travels with A, the leader before it, not with B').toEqual([
      'p0',
      'b',
      'pb',
      'a',
      'pa',
      'x',
      'px',
      'c',
      'pc',
    ]);

    const docBefore = view.state.doc;
    typeInto(view, 'C body', ' (pending)');
    // Dragging B but sending an order in which C moved too: not "one run moved", so the editor refuses and Swift falls back.
    const mismatch = reorderSectionsEditorFirst('11111111-2222-3333-4444-555555555555', 'a', [], ord('c', 'b', 'a'));
    expect(mismatch.ok).toBe(false);
    expect(mismatch.reason).toBe('planMismatch');
    expect(mismatch.batch.updates.map((u) => u.id)).toEqual(['pc']);
    expect(view.state.doc.textContent).toBe(`${docBefore.textContent} (pending)`);
    expect(idsInOrder()).toEqual(['p0', 'b', 'pb', 'a', 'pa', 'x', 'px', 'c', 'pc']);

    // A root the plan does not list at all is a plan the editor cannot read either.
    const notListed = reorderSectionsEditorFirst('22222222-2222-3333-4444-555555555555', 'a', [], ord('b', 'c'));
    expect(notListed.reason).toBe('planMismatch');
    expect(getRegistry().has('22222222-2222-3333-4444-555555555555')).toBe(false);
  });

  it('W6: typing outside the moved range stays undoable by text undo, and Cmd-Z right after the reorder targets the reorder', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    typeInto(view, 'A body', ' alpha'); // a text edit in A (unmoved)

    const r = reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('a', 'c', 'b', 'notes')); // B and C swap places
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['p0', 'a', 'pa', 'c', 'pc', 'b', 'pb', 'notes', 'pn']);
    expect(view.state.doc.textContent).toContain('alpha');

    // Cmd-Z with the reorder on top of Swift's undo stack routes to the reorder (the document still equals its post-op copy): the
    // editor asks Swift for the structural undo of THIS op. (The registry entry exists whatever the routing decides, so the message
    // is the proof.)
    expect(pressUndo(view, OP), 'Cmd-Z routes to the reorder').toBe(true);
    expect(posted.filter((p) => p.handler === 'structuralUndoRequested').map((p) => p.body)).toEqual([{ opId: OP }]);
  });

  it('R-TD-d: with typing after the reorder, Cmd-Z is a text undo and asks Swift for nothing', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    expect(reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('a', 'c', 'b', 'notes')).ok).toBe(true);
    typeInto(view, 'B body', ' beta'); // typed after the drop: the document no longer equals the reorder's post-op copy

    expect(pressUndo(view, OP), 'Cmd-Z is left to the text history').toBe(false);
    expect(posted.filter((p) => p.handler === 'structuralUndoRequested')).toEqual([]);
  });

  it('W6: the text undo of an edit made before the reorder takes that edit back and leaves the new order alone', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    typeInto(view, 'A body', ' alpha');
    const r = reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('a', 'c', 'b', 'notes')); // B and C swap places
    expect(r.ok, `reason: ${r.reason}`).toBe(true);

    expect(undo(view.state, view.dispatch), 'the history still holds the typing').toBe(true);

    expect(view.state.doc.textContent, 'the typed word is gone').not.toContain('alpha');
    expect(blocks(view).find((b) => b.id === 'pa')?.text).toBe('A body.');
    expect(idsInOrder(), 'and the moved order stands').toEqual(['p0', 'a', 'pa', 'c', 'pc', 'b', 'pb', 'notes', 'pn']);
  });

  it('W7: the caret keeps its block and offset, in a block that moved and in one that did not', async () => {
    const { view } = await makeEditor();
    await load(DOC);

    selectText(view, 'pa', 3);
    expect(reorderSectionsEditorFirst(OP, 'c', MANAGED, ord('c', 'a', 'b', 'notes')).ok).toBe(true);
    expect(caretOf(view), 'A did not move, but it shifted down').toEqual({ id: 'pa', offset: 3 });

    selectText(view, 'pb', 4);
    expect(
      reorderSectionsEditorFirst('11111111-2222-3333-4444-555555555555', 'b', MANAGED, ord('b', 'c', 'a', 'notes')).ok
    ).toBe(true);
    expect(caretOf(view), 'B moved with the caret inside it').toEqual({ id: 'pb', offset: 4 });
    expect(view.state.selection.empty).toBe(true);
  });

  // Changed by review finding W10 (the judge's ruling): this test used to select from B's body BACK to A's body and expect both ends
  // kept across the move of B. With one end inside the moved run and one outside, the two points would now enclose different blocks
  // than the user selected, so that selection is collapsed to its head (the R-W10 tests below). What stays true, and is pinned here:
  // a range whose two ends are BOTH inside the run moves with it, direction included.
  it('W7: a range selection with both ends inside the moved section keeps both ends and their direction', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    // Anchor in B's body, head in B's heading: a backwards selection inside the run.
    view.dispatch(
      view.state.tr.setSelection(TextSelection.create(view.state.doc, posOfId('pb') + 2, posOfId('b') + 3))
    );

    const r = reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('b', 'a', 'c', 'notes'));

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    const sel = view.state.selection;
    expect(sel instanceof TextSelection).toBe(true);
    expect(sel.anchor).toBe(posOfId('pb') + 2);
    expect(sel.head).toBe(posOfId('b') + 3);
  });

  it('W7: a node selection on a figure inside the moved section is kept, and so is Select All', async () => {
    const { view } = await makeEditor([imagePlugin]);
    await load([
      heading('a', 1, 'Section A'),
      para('pa', 'A body.'),
      heading('b', 1, 'Section B'),
      { name: 'fig', md: '![cap](media/photo.png)' },
      heading('c', 1, 'Section C'),
      para('pc', 'C body.'),
    ]);
    view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, posOfId('fig'))));
    expect(view.state.selection instanceof NodeSelection).toBe(true);

    const r = reorderSectionsEditorFirst(OP, 'b', [], ord('b', 'a', 'c'));

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(view.state.selection instanceof NodeSelection).toBe(true);
    expect((view.state.selection as NodeSelection).node.type.name).toBe('figure');
    expect(view.state.selection.from).toBe(posOfId('fig'));

    view.dispatch(view.state.tr.setSelection(new AllSelection(view.state.doc)));
    expect(reorderSectionsEditorFirst('11111111-2222-3333-4444-555555555555', 'a', [], ord('b', 'c', 'a')).ok).toBe(
      true
    );
    expect(view.state.selection instanceof AllSelection).toBe(true);
  });

  it('W8: spellcheck marks outside the moved range survive at their new positions; the moved range loses them and is rechecked by the ordinary check', async () => {
    const { view } = await makeEditor([spellcheckPlugin]);
    const checks: Array<{ action: string; segments: Array<{ text: string; from: number }> }> = [];
    (window as any).webkit.messageHandlers.spellcheck = { postMessage: (body: any) => checks.push(body) };
    await load(DOC);
    const wordIn = (id: string, word: string): SpellcheckResult => {
      const from = posOfId(id) + 1 + (view.state.doc.nodeAt(posOfId(id))?.textContent.indexOf(word) ?? 0);
      return { from, to: from + word.length, word, type: 'spelling', suggestions: [] };
    };
    view.dispatch(
      view.state.tr.setMeta(spellcheckPluginKey, [wordIn('pa', 'body'), wordIn('pb', 'body'), wordIn('pc', 'body')])
    );
    const marked = () =>
      (spellcheckPluginKey.getState(view.state) as { find(): Array<{ from: number; to: number }> }).find();
    expect(marked().length).toBe(3);

    // B moves above A: A's mark shifts, C's does not, B's is dropped with the cut.
    const r = reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('b', 'a', 'c', 'notes'));
    expect(r.ok, `reason: ${r.reason}`).toBe(true);

    const inA = wordIn('pa', 'body');
    const inC = wordIn('pc', 'body');
    expect(
      marked().map((d) => [d.from, d.to]),
      'one mark in A, one in C, none in B'
    ).toEqual([
      [inA.from, inA.to],
      [inC.from, inC.to],
    ]);

    // The ordinary check follows 400 ms after the change and covers the whole document, the moved section included.
    await sleep(450);
    const last = checks.filter((c) => c.action === 'check').at(-1);
    expect(last, 'a recheck was requested after the move').toBeDefined();
    const moved = last?.segments.find((s) => s.text === 'B body.');
    expect(moved?.from, 'and it covers B at its NEW position').toBe(posOfId('pb') + 1);
  });

  it('W9: the typewriter plugin does not treat the reorder as an edit to glide to', async () => {
    resetTypewriterForTests();
    __setTypewriterTestGeometry({
      caret: { top: 100, bottom: 124 },
      range: { maxScroll: 4000, visibleHeight: 480, lineHeight: 24 },
    });
    const { view } = await makeEditor([typewriterPlugin]);
    setTypewriterEnabled(true);
    setTypewriterLineOffset(0);
    markDocumentReady();
    await load(DOC);
    const triggersBefore = getTypewriterTestState().triggerCount;

    const r = reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('b', 'a', 'c', 'notes'));

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(typewriterPluginKey.getState(view.state)).toEqual({
      docChanged: false,
      reason: 'unclassified',
      triggeredFor: null,
    });
    expect(getTypewriterTestState().triggerCount, 'no glide was started').toBe(triggersBefore);
  });

  describe('the page stays where the reader was (W10)', () => {
    /** A fake layout: every top-level block is 100 px tall (`heights` overrides a block by its place in the document), stacked from
     * the page top, shifted up by the scroll offset. */
    function fakeLayout(view: EditorView, initialScroll: number, heights: Record<number, number> = {}) {
      let scrollY = initialScroll;
      const heightOf = (index: number) => heights[index] ?? 100;
      const offsetOf = (index: number) => {
        let y = 0;
        for (let i = 0; i < index; i++) y += heightOf(i);
        return y;
      };
      Object.defineProperty(window, 'scrollY', { configurable: true, get: () => scrollY });
      const scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation(((options: ScrollToOptions) => {
        scrollY = options.top ?? scrollY;
      }) as typeof window.scrollTo);
      vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function (this: Element) {
        const index = Array.from(view.dom.children).indexOf(this);
        const top = offsetOf(index) - scrollY;
        const height = heightOf(index);
        return { top, bottom: top + height, left: 0, right: 0, width: 0, height, x: 0, y: top, toJSON: () => ({}) };
      });
      view.coordsAtPos = (pos: number) => {
        const top = offsetOf(view.state.doc.resolve(pos).index(0)) - scrollY;
        return { top, bottom: top + 20, left: 0, right: 0 };
      };
      const topOf = (id: string) => (view.nodeDOM(posOfId(id)) as Element).getBoundingClientRect().top;
      return { scrollTo, topOf };
    }

    afterEach(() => {
      Object.defineProperty(window, 'scrollY', { configurable: true, value: 0, writable: true });
    });

    it('a visible caret line stays at the same screen height, even though its section moved', async () => {
      const { view } = await makeEditor();
      await load(DOC);
      const layout = fakeLayout(view, 500);
      selectText(view, 'pc', 2); // block 6: at 600 - 500 = 100 px from the top, on screen
      const before = layout.topOf('pc');

      const r = reorderSectionsEditorFirst(OP, 'c', MANAGED, ord('c', 'a', 'b', 'notes'));

      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(before).toBe(100);
      expect(layout.topOf('pc'), 'C is now the second section, and the page followed it').toBe(100);
      expect(layout.scrollTo).toHaveBeenCalledTimes(1);
    });

    it('with the caret off screen, the first visible block stays where it was', async () => {
      const { view } = await makeEditor();
      await load(DOC);
      const layout = fakeLayout(view, 500);
      selectText(view, 'pa', 1); // block 2: at -300 px, above the screen. The first block at or below the top is block 5, 'c'.
      expect(layout.topOf('c')).toBe(0);

      const r = reorderSectionsEditorFirst(OP, 'a', MANAGED, ord('b', 'c', 'a', 'notes'));

      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(layout.topOf('c'), 'the section that was at the top of the screen is still there').toBe(0);
    });

    // Review finding W6: the anchor is the block that CONTAINS the visible top, not the first block that starts below it. With the
    // reader inside a block taller than the screen, the run that moves starts right after that block: anchoring on the run would send
    // the page after it, and what the reader is looking at would jump.
    it('R-W6: inside a block taller than the screen, a run that starts right after it moves without the page jumping', async () => {
      const { view } = await makeEditor();
      await load(DOC);
      const layout = fakeLayout(view, 400, { 0: 1000 }); // the preamble is 1000 px tall; the page is scrolled 400 px into it
      selectText(view, 'p0', 2); // the caret's line is above the screen (-400 px), so the visible top decides the anchor
      expect(layout.topOf('p0')).toBe(-400);
      expect(layout.topOf('a')).toBe(600);

      // A, right after the tall block, goes to the end of the chapters (in front of Notes).
      const r = reorderSectionsEditorFirst(OP, 'a', MANAGED, ord('b', 'c', 'a', 'notes'));

      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(idsInOrder()).toEqual(['p0', 'b', 'pb', 'c', 'pc', 'a', 'pa', 'notes', 'pn']);
      expect(layout.scrollTo, 'the page was not scrolled after the moved run').not.toHaveBeenCalled();
      expect(layout.topOf('p0'), 'the reader still sees the same part of the tall block').toBe(-400);
    });

    it('does not touch the scroll position when nothing visible moved', async () => {
      const { view } = await makeEditor();
      await load(DOC);
      const layout = fakeLayout(view, 0);
      selectText(view, 'p0', 2);

      // B and C swap places, far below the caret in the preamble: nothing on screen moves.
      const r = reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('a', 'c', 'b', 'notes'));

      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(layout.scrollTo).not.toHaveBeenCalled();
    });
  });

  it('W11: a throw after the move puts the document, the ids and block-sync back, and the reply still carries the batch', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    typeInto(view, 'B body', ' (pending)');
    const docBefore = view.state.doc;
    setTestAfterReorderHook(() => {
      throw new Error('injected failure after the move');
    });

    const r = reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('b', 'a', 'c', 'notes'));

    expect(r.ok).toBe(false);
    expect(r.reason).toContain('injected failure after the move');
    expect(r.moved).toBe(0);
    expect(
      r.batch.updates.map((u) => u.id),
      'the batch the call consumed is returned'
    ).toEqual(['pb']);
    expect(view.state.doc.eq(docBefore), 'the document is as it was').toBe(true);
    expect(idsInOrder(), 'and so are the block ids').toEqual(DOC.map((s) => s.name));
    expect(getRegistry().has(OP), 'no registry entry is left behind').toBe(false);
    setTestAfterReorderHook(null);
    // Block-sync runs against the restored document: an edit is exactly one update of the ORIGINAL block.
    typeInto(view, 'A body', ' after');
    flushPendingBlockChanges();
    const diff = getBlockChangesApi();
    expect(diff.updates.map((u) => u.id)).toEqual(['pa']);
    expect(diff.inserts).toEqual([]);
    expect(diff.deletes).toEqual([]);
  });

  it('W12: a plan that changes only levels moves nothing and sets the level', async () => {
    const { view } = await makeEditor();
    await load(DOC);

    const r = reorderSectionsEditorFirst(OP, 'b', MANAGED, [
      { id: 'a' },
      { id: 'b', level: 2 },
      { id: 'c' },
      { id: 'notes' },
    ]);

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.moved).toBe(0);
    expect(r.levelChanges).toBe(1);
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    expect(levelOf(view, 'b')).toBe(2);
  });

  // === Review round: the findings the judge ruled on (named R-<finding>) ===

  /** Three chapters, then (optionally) a Notes chapter, then the bibliography marker atoms around the Bibliography heading. The
   * Bibliography heading's id is `bib-new`: the plans below name another one (`bib-old`), as after a bibliography rebuild that landed
   * between the plan and the click. */
  async function loadWithBibliography(withNotes: boolean): Promise<EditorView> {
    const { view } = await makeEditor([bibliographyPlugin, bibliographyEndMarkerPlugin].flat());
    const specs = [
      heading('a', 1, 'Chapter A'),
      para('a-p', 'Alpha.'),
      heading('b', 1, 'Chapter B'),
      para('b-p', 'Bravo.'),
      heading('c', 1, 'Chapter C'),
      para('c-p', 'Charlie.'),
      ...(withNotes ? [heading('notes', 1, 'Notes'), para('n-p', 'A note.')] : []),
    ];
    const markdown = `${markdownOf(specs)}\n\n<!-- ::auto-bibliography:: -->\n\n# Bibliography\n\nSmith 2020.\n\n<!-- ::auto-bibliography-end:: -->`;
    setContentWithBlockIds(markdown, [...specs.map((s) => s.name), 'bib-new', 'bib-p']);
    await waitForRAF();
    getBlockChangesApi();
    return view;
  }
  const liveManaged = (withNotes: boolean) => (withNotes ? ['notes', 'n-p', 'bib-new', 'bib-p'] : ['bib-new', 'bib-p']);
  const typeNames = (view: EditorView) => {
    const out: string[] = [];
    view.state.doc.forEach((node) => {
      out.push(node.type.name);
    });
    return out;
  };
  const BIB_TAIL = ['auto_bibliography', 'heading', 'paragraph', 'auto_bibliography_end'];

  // Review finding C1 (EVERYDAY): the editor's own Notes / Bibliography region is found from the live document. A plan that names a
  // Bibliography id the editor does not have must neither put a run after the bibliography nor drag the bibliography along.
  it('R-C1: with the Bibliography id unknown to the editor, a section moved to the end lands before the Bibliography', async () => {
    const view = await loadWithBibliography(false);

    const r = reorderSectionsEditorFirst(OP, 'a', liveManaged(false), ord('b', 'c', 'a', 'bib-old'));

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.skippedIds).toEqual(['bib-old']);
    expect(idsInOrder()).toEqual(['b', 'b-p', 'c', 'c-p', 'a', 'a-p', 'bib-new', 'bib-p']);
    expect(typeNames(view), 'the opening marker is still right in front of the Bibliography heading').toEqual([
      'heading',
      'paragraph',
      'heading',
      'paragraph',
      'heading',
      'paragraph',
      ...BIB_TAIL,
    ]);
  });

  it('R-C1: with the Bibliography id unknown to the editor, the last chapter moved up leaves the Bibliography where it is', async () => {
    const view = await loadWithBibliography(false);

    const r = reorderSectionsEditorFirst(OP, 'c', liveManaged(false), ord('c', 'a', 'b', 'bib-old'));

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.moved, 'only the chapter moved, not the bibliography behind it').toBe(2);
    expect(idsInOrder()).toEqual(['c', 'c-p', 'a', 'a-p', 'b', 'b-p', 'bib-new', 'bib-p']);
    expect(typeNames(view).slice(-4)).toEqual(BIB_TAIL);
  });

  it('R-C1: with Notes present and the Bibliography id unknown, a section moved to the end lands before Notes', async () => {
    const view = await loadWithBibliography(true);

    const r = reorderSectionsEditorFirst(OP, 'a', liveManaged(true), ord('b', 'c', 'a', 'notes', 'bib-old'));

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.skippedIds).toEqual(['bib-old']);
    expect(idsInOrder()).toEqual(['b', 'b-p', 'c', 'c-p', 'a', 'a-p', 'notes', 'n-p', 'bib-new', 'bib-p']);
    expect(typeNames(view).slice(-4)).toEqual(BIB_TAIL);
  });

  it('R-C1: with Notes present and neither Notes nor Bibliography in the plan, the run still lands before them, and a chapter leaves without them', async () => {
    const view = await loadWithBibliography(true);

    const toEnd = reorderSectionsEditorFirst(OP, 'a', liveManaged(true), ord('b', 'c', 'a'));
    expect(toEnd.ok, `reason: ${toEnd.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['b', 'b-p', 'c', 'c-p', 'a', 'a-p', 'notes', 'n-p', 'bib-new', 'bib-p']);

    const lastUp = reorderSectionsEditorFirst(
      '11111111-2222-3333-4444-555555555555',
      'a',
      liveManaged(true),
      ord('a', 'b', 'c')
    );
    expect(lastUp.ok, `reason: ${lastUp.reason}`).toBe(true);
    expect(lastUp.moved).toBe(2);
    expect(idsInOrder()).toEqual(['a', 'a-p', 'b', 'b-p', 'c', 'c-p', 'notes', 'n-p', 'bib-new', 'bib-p']);
    expect(typeNames(view).slice(-4)).toEqual(BIB_TAIL);
  });

  // Review finding W3 (EVERYDAY): typing in the moved section right after the drop is one update of that block's own id for
  // block-sync, never an insert or a delete (a wrong id after the move would make Swift delete a row and insert another).
  // The moved section holds two paragraphs with the same text: the block-id plugin settles ids by position and text, which cannot
  // tell such twins apart after a move, so the reorder puts every id back itself.
  it('R-W3: typing in the moved section and in a shifted one after the drop is one update each, under the original ids', async () => {
    const { view } = await makeEditor();
    await load([
      para('p0', 'Preamble.'),
      heading('a', 1, 'Section A'),
      para('pa', 'A body.'),
      heading('b', 1, 'Section B'),
      para('pb', 'Twin.'),
      para('pb2', 'Twin.'),
      heading('c', 1, 'Section C'),
      para('pc', 'C body.'),
      heading('notes', 1, 'Notes'),
      para('pn', 'Notes body.'),
    ]);
    expect(reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('b', 'a', 'c', 'notes')).ok).toBe(true);
    expect(idsInOrder()).toEqual(['p0', 'b', 'pb', 'pb2', 'a', 'pa', 'c', 'pc', 'notes', 'pn']);

    typeIntoNth(view, 'Twin.', 1, ' typed after the drop'); // the second twin
    flushPendingBlockChanges();
    const inMoved = getBlockChangesApi();
    expect(inMoved.updates.map((u) => u.id)).toEqual(['pb2']);
    expect(inMoved.updates[0].textContent).toBe('Twin. typed after the drop');
    expect(inMoved.inserts).toEqual([]);
    expect(inMoved.deletes).toEqual([]);

    typeInto(view, 'A body', ' typed too');
    flushPendingBlockChanges();
    const inShifted = getBlockChangesApi();
    expect(inShifted.updates.map((u) => u.id)).toEqual(['pa']);
    expect(inShifted.inserts).toEqual([]);
    expect(inShifted.deletes).toEqual([]);
  });

  // Review finding W9: a bold toggle pressed at an empty selection is "stored" on the state, and any document change clears it.
  it('R-W9: a pending bold toggle at the caret is still pending after the reorder, caret in an unmoved block or a moved one', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const strong = view.state.schema.marks.strong;
    const pendingBold = () => view.state.storedMarks?.map((m) => m.type.name);

    selectText(view, 'pa', 3);
    view.dispatch(view.state.tr.addStoredMark(strong.create()));
    expect(pendingBold()).toEqual(['strong']);
    expect(reorderSectionsEditorFirst(OP, 'c', MANAGED, ord('c', 'a', 'b', 'notes')).ok).toBe(true);
    expect(caretOf(view)).toEqual({ id: 'pa', offset: 3 });
    expect(pendingBold(), 'the toggle survived with the caret in an unmoved block').toEqual(['strong']);

    selectText(view, 'pb', 2);
    view.dispatch(view.state.tr.addStoredMark(strong.create()));
    expect(
      reorderSectionsEditorFirst('11111111-2222-3333-4444-555555555555', 'b', MANAGED, ord('b', 'c', 'a', 'notes')).ok
    ).toBe(true);
    expect(caretOf(view)).toEqual({ id: 'pb', offset: 2 });
    expect(pendingBold(), 'and with the caret inside the moved block').toEqual(['strong']);
  });

  // Review finding W10: a selection whose two ends the moved run separates (or cuts through) would, after the move, enclose other
  // blocks than the user selected, and the next keystroke would replace all of them. It is collapsed to its head.
  describe('a selection the moved run separates', () => {
    const select = (view: EditorView, from: [string, number], to: [string, number]) =>
      view.dispatch(
        view.state.tr.setSelection(
          TextSelection.create(view.state.doc, posOfId(from[0]) + from[1], posOfId(to[0]) + to[1])
        )
      );

    it('R-W10: the run was between the two ends: collapsed at the head, not a range over the blocks that are left', async () => {
      const { view } = await makeEditor();
      await load(DOC);
      select(view, ['pa', 2], ['pc', 3]); // A to C, with B between them

      const r = reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('b', 'a', 'c', 'notes')); // B goes to the front

      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(view.state.selection.empty, 'the selection is a caret').toBe(true);
      expect(caretOf(view), 'at the head').toEqual({ id: 'pc', offset: 3 });
    });

    it('R-W10: the run lands between the two ends: collapsed at the head', async () => {
      const { view } = await makeEditor();
      await load(DOC);
      select(view, ['pa', 2], ['pb', 3]); // A to B, side by side

      const r = reorderSectionsEditorFirst(OP, 'c', MANAGED, ord('a', 'c', 'b', 'notes')); // C lands between them

      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(view.state.selection.empty).toBe(true);
      expect(caretOf(view)).toEqual({ id: 'pb', offset: 3 });
    });

    it('R-W10: one end inside the run and one outside: collapsed at the head, wherever the head is', async () => {
      const { view } = await makeEditor();
      await load(DOC);
      select(view, ['pa', 2], ['pb', 3]); // the head is inside B, which moves

      expect(reorderSectionsEditorFirst(OP, 'b', MANAGED, ord('b', 'a', 'c', 'notes')).ok).toBe(true);
      expect(view.state.selection.empty).toBe(true);
      expect(caretOf(view)).toEqual({ id: 'pb', offset: 3 });

      select(view, ['pb', 3], ['pa', 2]); // now backwards: the head is outside the run, the anchor inside it
      expect(
        reorderSectionsEditorFirst('11111111-2222-3333-4444-555555555555', 'b', MANAGED, ord('a', 'b', 'c', 'notes')).ok
      ).toBe(true);
      expect(view.state.selection.empty).toBe(true);
      expect(caretOf(view)).toEqual({ id: 'pa', offset: 2 });
    });

    it('R-W10: both ends on the same side of the run before and after the move: the range is kept', async () => {
      const { view } = await makeEditor();
      await load(DOC);
      select(view, ['pa', 2], ['pb', 3]); // A to B; C moves to the front, out of their way

      const r = reorderSectionsEditorFirst(OP, 'c', MANAGED, ord('c', 'a', 'b', 'notes'));

      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(view.state.selection.empty).toBe(false);
      expect(view.state.selection.anchor).toBe(posOfId('pa') + 2);
      expect(view.state.selection.head).toBe(posOfId('pb') + 3);
    });
  });
});
