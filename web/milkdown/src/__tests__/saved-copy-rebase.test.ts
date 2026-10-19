// Saved-copy rebase (saved-copy-rebase.ts), driven on bare ProseMirror documents of book size.
//
// The rule under test (file header): the automatic chain `before` -> `after` is applied to the saved copy `saved` for
// the blocks the user did not touch, so that once the user has undone their own typing the document equals the saved
// copy again. Round F3 of t-18b7fa48: on a book, the user's typing near the start and the chain's change in Notes near
// the end are far apart; the old single trimmed-middle cost check (50,000 cells) refused every such pair as `too-far`,
// so the "type before the Notes rebuild lands, then Cmd-Z" support never covered a book. These tests pin the REGION
// rule: unchanged blocks are lined up first (by identity, then by equality), each side's changes become small separate
// regions, the cost budget applies per region, and only a real overlap or a single over-budget region refuses.

import { type Node, Schema } from '@milkdown/kit/prose/model';
import { describe, expect, it } from 'vitest';
import { describeBlockDifferences, rebaseOntoSavedCopy, USER_DIFF_CELL_BUDGET } from '../saved-copy-rebase';

const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { group: 'block', content: 'text*' },
    heading: { group: 'block', content: 'text*', attrs: { level: { default: 1 } } },
    text: {},
  },
});

const para = (text: string): Node => schema.nodes.paragraph.create(null, text === '' ? undefined : schema.text(text));
const heading = (text: string): Node => schema.nodes.heading.create({ level: 1 }, schema.text(text));
const docOf = (blocks: Node[]): Node => schema.nodes.doc.create(null, blocks);
const childrenOf = (doc: Node): Node[] => {
  const out: Node[] = [];
  doc.forEach((n) => {
    out.push(n);
  });
  return out;
};
/** A copy of `doc` in which block `index` (and `count - 1` after it) is replaced; every other block is the SAME object. */
const withBlocks = (doc: Node, index: number, count: number, replacement: Node[]): Node => {
  const kids = childrenOf(doc);
  kids.splice(index, count, ...replacement);
  return docOf(kids);
};
/** A deep copy: every block is a new object that is `.eq` to the original (identity broken, as after a full content replace). */
const deepCopy = (doc: Node): Node => schema.nodeFromJSON(doc.toJSON());

/** A book-shaped document: `chapters` chapters of `perChapter` paragraphs, then a Notes heading, `notes` definitions, a
 * Bibliography heading and `entries` entries. Every block is distinct text. */
function makeBook(chapters: number, perChapter: number, notes: number, entries: number): Node {
  const blocks: Node[] = [];
  for (let c = 1; c <= chapters; c++) {
    blocks.push(heading(`Chapter ${c}`));
    for (let p = 1; p <= perChapter; p++) blocks.push(para(`Chapter ${c} paragraph ${p} text.`));
  }
  blocks.push(heading('Notes'));
  for (let n = 1; n <= notes; n++) blocks.push(para(`Note ${n}.`));
  blocks.push(heading('Bibliography'));
  for (let e = 1; e <= entries; e++) blocks.push(para(`Entry ${e}.`));
  return docOf(blocks);
}

describe('saved-copy rebase on a book (round F3, region splitting)', () => {
  // 6 chapters x 150 paragraphs + 6 headings = 906, Notes heading + 60 = 61, Bibliography heading + 20 = 21: 988 blocks.
  const saved = makeBook(6, 150, 60, 20);
  const TYPED = 'ZZTYPEDWORDZZ';

  it('F3-0 (baseline): the user typed at block 5 only, the Notes rebuild changes blocks near the end: rebased, the typed word never enters the saved copy', () => {
    expect(saved.childCount).toBeGreaterThan(950);
    const before = withBlocks(saved, 5, 1, [para(`Chapter 1 paragraph 5 text. ${TYPED}`)]);
    const notesStart = 906 + 1;
    // The rebuild drops two Notes definitions and rewrites a third (a chain that left no text-history step).
    const after = withBlocks(before, notesStart + 10, 3, [para('Note 11, rewritten.')]);
    const out = rebaseOntoSavedCopy(saved, before, after);
    expect(out.result).toBe('rebased');
    expect(out.userRanges).toBe(1);
    expect(out.chainRanges).toBe(1);
    const rebased = out.doc as Node;
    expect(rebased, 'a rebased copy is returned').not.toBeNull();
    expect(rebased.textContent, 'the typed word never enters the saved copy').not.toContain(TYPED);
    // The saved copy now holds the chain's change and nothing else: it is the saved copy with the same blocks swapped.
    expect(rebased.eq(withBlocks(saved, notesStart + 10, 3, [para('Note 11, rewritten.')]))).toBe(true);
    // The user's block is exactly the saved copy's block (the very same object, untouched).
    expect(rebased.child(5)).toBe(saved.child(5));
    // So once the user undoes the typing the live document equals the saved copy again.
    const afterUndoOfTyping = withBlocks(after, 5, 1, [saved.child(5)]);
    expect(afterUndoOfTyping.eq(rebased)).toBe(true);
  });

  it('F3-1 (the real-app shape, FAILS on the single trimmed-middle check): the saved copy and the live document differ at block 5 (typing) AND near the end of Notes (an earlier automatic change the saved copy never followed); the chain changes Notes elsewhere: rebased', () => {
    const notesStart = 906 + 1;
    let before = withBlocks(saved, 5, 1, [para(`Chapter 1 paragraph 5 text. ${TYPED}`)]);
    // Two spots far apart: the old check saw ONE middle of about 950 blocks on each side (~900,000 cells > 50,000) and refused.
    before = withBlocks(before, notesStart + 52, 1, [para('Note 53, relabelled.')]);
    const after = withBlocks(before, notesStart + 10, 3, [para('Note 11, rewritten.')]);
    const out = rebaseOntoSavedCopy(saved, before, after);
    expect(out.result).toBe('rebased');
    expect(out.userRanges, 'the typing and the earlier change are two separate regions').toBe(2);
    expect(out.chainRanges).toBe(1);
    expect(out.cells, 'the cost is per region: two single-block regions').toBe(1);
    const rebased = out.doc as Node;
    expect(rebased.textContent, 'the typed word never enters the saved copy').not.toContain(TYPED);
    expect(rebased.textContent, 'nor does the earlier change the user side holds').not.toContain('relabelled');
    expect(rebased.eq(withBlocks(saved, notesStart + 10, 3, [para('Note 11, rewritten.')]))).toBe(true);
    expect(rebased.child(5), "the user's block is untouched").toBe(saved.child(5));
    expect(out.userSummary).toBe(
      '2 ranges: a[5,6)b[5,6) paragraph>paragraph ; a[' +
        (notesStart + 52) +
        ',' +
        (notesStart + 53) +
        ')b[' +
        (notesStart + 52) +
        ',' +
        (notesStart + 53) +
        ') paragraph>paragraph'
    );
    expect(out.userSummary + out.chainSummary).not.toContain(TYPED);
  });

  it('F3-1b (the limit, unchanged by regions): when the chain rewrites the very block the earlier automatic change touched, that is a real overlap and nothing is applied', () => {
    const notesStart = 906 + 1;
    let before = withBlocks(saved, 5, 1, [para(`Chapter 1 paragraph 5 text. ${TYPED}`)]);
    before = withBlocks(before, notesStart + 52, 1, [para('Note 53, relabelled.')]);
    const after = withBlocks(before, notesStart + 50, 4, [para('Note 51, rewritten.')]);
    const out = rebaseOntoSavedCopy(saved, before, after);
    expect(out.result).toBe('overlap');
    expect(out.doc).toBeNull();
  });

  it('F3-2: the user edited in three places far apart and the chain changed two others between them: one rebase, every region small', () => {
    let before = withBlocks(saved, 5, 1, [para(`edit one ${TYPED}`)]);
    before = withBlocks(before, 400, 1, [para(`edit two ${TYPED}`)]);
    before = withBlocks(before, 800, 1, [para(`edit three ${TYPED}`)]);
    let after = withBlocks(before, 200, 1, [para('chain change one')]);
    after = withBlocks(after, 960, 2, [para('chain change two')]);
    const out = rebaseOntoSavedCopy(saved, before, after);
    expect(out.result).toBe('rebased');
    expect(out.userRanges).toBe(3);
    expect(out.chainRanges).toBe(2);
    const rebased = out.doc as Node;
    expect(rebased.textContent).not.toContain(TYPED);
    expect(rebased.childCount).toBe(saved.childCount - 1);
    expect(rebased.child(200).textContent).toBe('chain change one');
    expect(rebased.child(960).textContent, 'blocks 960-961 became one block at 960').toBe('chain change two');
    for (const i of [5, 400, 800]) expect(rebased.child(i)).toBe(saved.child(i));
  });

  it('F3-3: the user added two paragraphs near the start and the chain inserted a block near the end: the insertion lands at the shifted place', () => {
    const before = withBlocks(saved, 6, 0, [para(`added one ${TYPED}`), para(`added two ${TYPED}`)]);
    const endOfNotes = before.childCount - 21; // just before the Bibliography heading, in `before`'s numbering
    const after = withBlocks(before, endOfNotes, 0, [para('Note 61.')]);
    const out = rebaseOntoSavedCopy(saved, before, after);
    expect(out.result).toBe('rebased');
    const rebased = out.doc as Node;
    expect(rebased.textContent).not.toContain(TYPED);
    expect(rebased.childCount).toBe(saved.childCount + 1);
    // Inserted in front of the Bibliography heading, exactly where the chain put it (two fewer blocks before it than in `before`).
    expect(rebased.child(endOfNotes - 2).textContent).toBe('Note 61.');
    expect(rebased.child(endOfNotes - 1).textContent).toBe('Bibliography');
  });

  it('F3-4: an unchanged-but-new-objects document (identity broken, as after a full content replace) is lined up by equality and still rebases', () => {
    const before = deepCopy(withBlocks(saved, 5, 1, [para(`typed ${TYPED}`)]));
    const rewritten = para('Note 5, rewritten.');
    const after = deepCopy(withBlocks(before, 907 + 4, 1, [rewritten]));
    const out = rebaseOntoSavedCopy(saved, before, after);
    expect(out.result).toBe('rebased');
    expect(out.userRanges).toBe(1);
    expect(out.chainRanges).toBe(1);
    const rebased = out.doc as Node;
    expect(rebased.textContent).not.toContain(TYPED);
    expect(rebased.child(907 + 4).textContent).toBe('Note 5, rewritten.');
  });

  it('F3-5 (overlap rule unchanged): a chain that rewrites a block the user changed is refused, and nothing is applied', () => {
    const before = withBlocks(saved, 5, 1, [para(`typed ${TYPED}`)]);
    const after = withBlocks(before, 5, 1, [para(`typed ${TYPED}, rewritten`)]);
    const out = rebaseOntoSavedCopy(saved, before, after);
    expect(out.result).toBe('overlap');
    expect(out.doc).toBeNull();
  });

  it('F3-6 (overlap rule unchanged): an insertion inside a run of blocks the user added is refused', () => {
    const before = withBlocks(saved, 6, 0, [para('user one'), para('user two')]);
    const after = withBlocks(before, 7, 0, [para('automatic')]);
    const out = rebaseOntoSavedCopy(saved, before, after);
    expect(out.result).toBe('overlap');
    expect(out.doc).toBeNull();
  });

  it('F3-7 (cost bound per region): ONE region larger than the budget is still refused as too-far, without running the diff', () => {
    // The user replaced 300 blocks in a row with 300 different ones: 300 x 300 = 90,000 cells in a single region.
    const replacement = Array.from({ length: 300 }, (_, i) => para(`rewritten ${i} ${TYPED}`));
    const before = withBlocks(saved, 100, 300, replacement);
    const after = withBlocks(before, 960, 1, [para('chain change')]);
    const out = rebaseOntoSavedCopy(saved, before, after);
    expect(300 * 300).toBeGreaterThan(USER_DIFF_CELL_BUDGET);
    expect(out.result).toBe('too-far');
    expect(out.doc).toBeNull();
    expect(out.cells).toBe(300 * 300);
    expect(out.userRanges).toBe(-1);
  });

  it('F3-8 (cost bound per region): several regions that are each under the budget but together far over it are NOT refused', () => {
    // Five regions of 200 x 200 = 40,000 cells each (200,000 together, four times the budget); one region is within it.
    let before = saved;
    for (let k = 0; k < 4; k++) {
      before = withBlocks(
        before,
        20 + k * 220,
        200,
        Array.from({ length: 200 }, (_, i) => para(`region ${k} block ${i} ${TYPED}`))
      );
    }
    const after = withBlocks(before, 960, 1, [para('chain change')]);
    const out = rebaseOntoSavedCopy(saved, before, after);
    expect(out.result).toBe('rebased');
    expect(out.userRanges).toBe(4);
    expect((out.doc as Node).textContent).not.toContain(TYPED);
  });

  it('F3-9: a chain that changed no block is no-change', () => {
    const before = withBlocks(saved, 5, 1, [para(`typed ${TYPED}`)]);
    const out = rebaseOntoSavedCopy(saved, before, deepCopy(before));
    expect(out.result).toBe('no-change');
    expect(out.doc).toBeNull();
  });

  it('F3-10: the user deleted a block near the start and the chain changed one near the end: indices shift by one and the saved copy keeps the block', () => {
    const before = withBlocks(saved, 7, 1, []);
    const after = withBlocks(before, 950, 1, [para('chain change')]);
    const out = rebaseOntoSavedCopy(saved, before, after);
    expect(out.result).toBe('rebased');
    const rebased = out.doc as Node;
    expect(rebased.childCount).toBe(saved.childCount);
    expect(rebased.child(7)).toBe(saved.child(7));
    expect(rebased.child(951).textContent).toBe('chain change');
  });
});

describe('describeBlockDifferences (the counts-only trace summary)', () => {
  const saved = makeBook(2, 10, 5, 3);

  it('names the top-level indices and node types that differ, and never any text', () => {
    const before = withBlocks(saved, 3, 1, [para('SECRETWORD typed')]);
    const text = describeBlockDifferences(saved, before);
    expect(text).toBe('1 range: a[3,4)b[3,4) paragraph>paragraph');
    expect(text).not.toContain('SECRETWORD');
  });

  it('lists several ranges, an insertion and a deletion', () => {
    let before = withBlocks(saved, 2, 0, [para('x'), heading('y')]);
    before = withBlocks(before, 20, 1, []);
    const text = describeBlockDifferences(saved, before);
    expect(text).toBe('2 ranges: a[2,2)b[2,4) ->paragraph,heading ; a[18,19)b[20,20) paragraph>-');
  });

  it('is equal documents: no ranges', () => {
    expect(describeBlockDifferences(saved, deepCopy(saved))).toBe('0 ranges');
  });

  it('caps a long list', () => {
    let before = saved;
    for (let i = 0; i < 8; i++) before = withBlocks(before, 1 + i * 2, 1, [para(`changed ${i}`)]);
    const text = describeBlockDifferences(saved, before);
    expect(text.startsWith('8 ranges: ')).toBe(true);
    expect(text.endsWith(' ; +2 more')).toBe(true);
  });
});
