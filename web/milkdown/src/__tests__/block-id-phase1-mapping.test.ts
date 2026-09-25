// @vitest-environment jsdom
// Phase 1 of assignBlockIds follows the transaction's own position mapping
// (tr.mapping) instead of bare numeric-offset equality. F1a (a multi-character
// edit or a pasted block shifting blocks exactly onto a neighbour's old offset)
// and t-e8d76487 (one keystroke before two back-to-back one-position blocks)
// both handed out a neighbour's id through that bare lookup. The last four
// tests pin the paths the new lookup reroutes to the old same-offset fallback
// or to Phase 2, so they keep their pre-existing behaviour.
import { type Node, Schema } from '@milkdown/kit/prose/model';
import { findWrapping, liftTarget, Transform } from '@milkdown/kit/prose/transform';
import { describe, expect, it } from 'vitest';
import { assignBlockIds, resetBlockIdState } from '../block-id-plugin';

const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { group: 'block', content: 'inline*', attrs: { tid: { default: '' } } },
    heading: { group: 'block', content: 'inline*', attrs: { tid: { default: '' } } },
    hr: { group: 'block', attrs: { tid: { default: '' } } },
    section_break: { group: 'block', attrs: { tid: { default: '' } } },
    figure: { group: 'block', atom: true, attrs: { tid: { default: '' } } },
    // Wrap-test-only node types (blockquote/bullet_list/list_item): needed
    // only by the "wrap" describe block below, which needs a real container
    // block type to wrap a paragraph INTO. Not used by any other test in
    // this file.
    blockquote: { group: 'block', content: 'block+', attrs: { tid: { default: '' } } },
    bullet_list: { group: 'block', content: 'list_item+', attrs: { tid: { default: '' } } },
    list_item: { content: 'paragraph block*', attrs: { tid: { default: '' } } },
    text: { group: 'inline' },
  },
});

type Kind = 'paragraph' | 'heading' | 'hr' | 'section_break' | 'figure';

function block(kind: Kind, tid: string, text = ''): Node {
  const type = schema.nodes[kind];
  if (type.isLeaf) return type.create({ tid });
  return type.create({ tid }, text ? [schema.text(text)] : []);
}

/** Seeds `id-<tid>` for every top-level block, runs `edit`, returns tid -> id after assignBlockIds. */
function run(
  blocks: Node[],
  edit: (tr: Transform) => void
): { byTid: Record<string, string>; all: string[]; tr: Transform; after: Map<number, string> } {
  resetBlockIdState();
  const doc0 = schema.nodes.doc.create(null, blocks);
  const ids = new Map<number, string>();
  const types = new Map<number, string>();
  doc0.forEach((n, off) => {
    ids.set(off, `id-${n.attrs.tid}`);
    types.set(off, n.type.name);
  });
  const tr = new Transform(doc0);
  edit(tr);
  const [after] = assignBlockIds(tr.doc, ids, types, doc0, tr.mapping);
  const byTid: Record<string, string> = {};
  tr.doc.forEach((n, off) => {
    byTid[n.attrs.tid] = after.get(off) ?? 'NONE';
  });
  return { byTid, all: [...after.values()], tr, after };
}

describe('Phase 1 claims by mapped position (F1a, t-e8d76487)', () => {
  for (const kind of ['hr', 'section_break', 'figure'] as const) {
    it(`one keystroke before two adjacent ${kind} blocks leaves every id in place`, () => {
      const { byTid } = run(
        [block('paragraph', 'A', 'ab'), block(kind, 'X1'), block(kind, 'X2'), block('paragraph', 'B', 'z')],
        (tr) => tr.insert(2, schema.text('Q'))
      );
      expect(byTid).toEqual({ A: 'id-A', X1: 'id-X1', X2: 'id-X2', B: 'id-B' });
    });
  }

  it('typing two characters before a run of empty paragraphs leaves every id in place (F1a, insert)', () => {
    const { byTid } = run(
      [
        block('paragraph', 'A', 'abc'),
        block('paragraph', 'E1'),
        block('paragraph', 'E2'),
        block('paragraph', 'B', 'x'),
        block('paragraph', 'C', 'y'),
      ],
      (tr) => tr.insert(2, schema.text('ZZ'))
    );
    expect(byTid).toEqual({ A: 'id-A', E1: 'id-E1', E2: 'id-E2', B: 'id-B', C: 'id-C' });
  });

  it('deleting two characters before a run of empty paragraphs leaves every id in place (F1a, delete)', () => {
    const { byTid } = run(
      [
        block('paragraph', 'A', 'abcd'),
        block('paragraph', 'E1'),
        block('paragraph', 'E2'),
        block('paragraph', 'B', 'x'),
      ],
      (tr) => tr.delete(2, 4)
    );
    expect(byTid).toEqual({ A: 'id-A', E1: 'id-E1', E2: 'id-E2', B: 'id-B' });
  });
});

describe('paths the mapped lookup reroutes keep their behaviour', () => {
  it('(a) converting a paragraph to a heading in place keeps its id (fallback: its start is replaced, so same-offset lookup)', () => {
    const { byTid, tr } = run(
      [block('paragraph', 'A', 'abc'), block('paragraph', 'P', 'hello'), block('paragraph', 'Q', 'x')],
      (t) => t.setNodeMarkup(5, schema.nodes.heading, { tid: 'P' })
    );
    expect(tr.doc.child(1).type.name).toBe('heading'); // setup: P really was converted
    expect(byTid).toEqual({ A: 'id-A', P: 'id-P', Q: 'id-Q' });
  });

  it('(b) replacing the whole document with the same content keeps every id (fallback: every start is replaced)', () => {
    const blocks = [
      block('paragraph', 'A', 'abc'),
      block('heading', 'H', 'title'),
      block('paragraph', 'E'),
      block('hr', 'R'),
    ];
    const { byTid } = run(blocks, (t) => t.replaceWith(0, t.doc.content.size, blocks));
    expect(byTid).toEqual({ A: 'id-A', H: 'id-H', E: 'id-E', R: 'id-R' });
  });

  it('(c) Enter at the start of a line: the text half keeps the id, the new empty line above gets a temp id', () => {
    const { tr, after } = run([block('paragraph', 'P', 'abc'), block('paragraph', 'Q', 'x')], (t) => t.split(1));
    const got: Array<[string, string]> = [];
    tr.doc.forEach((n, off) => {
      got.push([n.textContent, after.get(off) ?? 'NONE']);
    });
    expect(got.map(([text]) => text)).toEqual(['', 'abc', 'x']); // setup: empty line above, text pushed down
    expect(got[0][1].startsWith('temp-')).toBe(true);
    expect(got[1][1]).toBe('id-P');
    expect(got[2][1]).toBe('id-Q');
  });

  it('(d) deleting a whole block: the next block shifts onto its old offset and keeps its own id; the deleted id goes to no one', () => {
    const { byTid, all, tr } = run(
      [block('paragraph', 'A', 'a'), block('paragraph', 'B', 'bb'), block('paragraph', 'C', 'ccc')],
      (t) => t.delete(3, 7)
    );
    let cOffset = -1;
    tr.doc.forEach((n, off) => {
      if (n.attrs.tid === 'C') cOffset = off;
    });
    expect(cOffset).toBe(3); // setup: C now sits exactly where B was
    expect(byTid).toEqual({ A: 'id-A', C: 'id-C' });
    expect(all).not.toContain('id-B');
  });
});

// Review finding 8: a single transaction combining a text shift (changes
// offsets elsewhere in the doc) with a LATER setNodeMarkup on the shifted
// block. Verified by running it: C loses its id here and gets a fresh temp
// id instead -- a real, previously-undocumented gap, distinct from test (a)
// above (which converts a paragraph to a heading successfully, because
// there nothing shifted it first).
//
// Why: setNodeMarkup's own ReplaceStep touches the block's start position
// itself (oldSize 1, replaced in place), so `mapping.mapResult(oldPos,
// 1).deleted` is true for C's ORIGINAL (pre-shift) offset -- the tracked
// loop's `r.deleted` check skips it, same as any other "start was replaced"
// case. That defers C to the raw same-offset fallback, but the fallback
// tests the NEW offset (shifted +2 by the insert) against `existingIds`,
// whose keys are all OLD, un-shifted offsets -- no key matches, so C gets no
// `lookupPos` at all in Phase 1 and is deferred to Phase 2. structureChanged
// is false (block count unchanged), so Phase 2 uses the per-block "structure
// unchanged" branch (block-id-plugin.ts), which -- unlike phase1CanClaim --
// filters candidates by STRICT type match only, with no cross-type
// allowance for input-rule-style conversions. C is now a heading; every
// existing id is typed 'paragraph'; no candidate survives the type filter;
// C gets a temp id. Converting a block's type across the SAME transaction
// that also shifted it is therefore NOT equivalent to converting it in a
// transaction of its own (test (a)'s scenario) -- a real, narrow gap this
// fix does not close, pinned here rather than left undocumented.
describe('one transaction combining a text shift with a later setNodeMarkup (review finding 8)', () => {
  it('pins the actual outcome: the converted block loses its id to a fresh temp id', () => {
    const { byTid, tr } = run(
      [block('paragraph', 'A', 'aaa'), block('paragraph', 'B', 'bbb'), block('paragraph', 'C', 'ccc')],
      (t) => {
        t.insert(2, schema.text('QQ')); // shifts B and C two characters to the right
        let cOffset = -1;
        t.doc.forEach((n, off) => {
          if (n.attrs.tid === 'C') cOffset = off;
        });
        t.setNodeMarkup(cOffset, schema.nodes.heading, { tid: 'C' });
      }
    );
    expect(tr.doc.child(2).type.name).toBe('heading'); // setup: C really was converted, after the shift
    expect(byTid.A).toBe('id-A');
    expect(byTid.B).toBe('id-B');
    expect(byTid.C).not.toBe('id-C');
    expect(byTid.C.startsWith('temp-')).toBe(true);
  });
});

// Review finding 8: a "drag-move" -- delete a block, then insert a new one
// elsewhere, in ONE transaction, net block count unchanged. Verified by
// running it: structureChanged stays false (existingIds.size === new
// blockCount), so this is decided by the per-block "structure unchanged"
// proximity branch (block-id-plugin.ts), which has NO content-relatedness
// check -- unlike the structural (Phase 2 greedy) branch. B's start was
// itself deleted, so it is never `tracked`, leaving its id unclaimed and
// available; N (brand-new content, unrelated to B) lands close enough to
// B's old offset that the type-matching, no-content-check proximity search
// hands N that orphaned id-B outright. This is a known, pre-existing gap in
// that branch (see its own "No content-relatedness check here" comment) --
// not something this fix touches or is meant to close -- pinned here as the
// actual outcome rather than left undocumented.
describe('drag-move: delete one block and insert a new one elsewhere in the same transaction (review finding 8)', () => {
  it("pins the actual outcome: the new block inherits the deleted block's orphaned id by proximity", () => {
    const { byTid, tr } = run(
      [block('paragraph', 'A', 'aaa'), block('paragraph', 'B', 'bbb'), block('paragraph', 'C', 'ccc')],
      (t) => {
        let bStart = -1;
        let bEnd = -1;
        t.doc.forEach((n, off) => {
          if (n.attrs.tid === 'B') {
            bStart = off;
            bEnd = off + n.nodeSize;
          }
        });
        t.delete(bStart, bEnd); // B is gone entirely -- not moved, deleted
        let cOffset = -1;
        t.doc.forEach((n, off) => {
          if (n.attrs.tid === 'C') cOffset = off;
        });
        // A brand-new paragraph N, unrelated to B, lands in roughly B's old
        // slot -- e.g. the user deleted B, then typed a fresh paragraph in
        // about the same place (not a copy/paste of B's own content).
        t.insert(cOffset, block('paragraph', 'N', 'nnn'));
      }
    );
    let count = 0;
    tr.doc.forEach(() => {
      count++;
    });
    expect(count).toBe(3); // setup: block count really is unchanged (A, N, C)
    expect(byTid.A).toBe('id-A');
    expect(byTid.C).toBe('id-C');
    // N is brand-new content (text "nnn", not "bbb") landing near B's old
    // slot. The per-block proximity branch has no content-relatedness gate,
    // so it hands N the orphaned id-B by pure proximity -- see the describe
    // block's comment above for why this is a known, pre-existing gap, not
    // something this fix touches or closes.
    expect(byTid.N).toBe('id-B');
  });
});

// Regression: review finding 1 (F1a fix follow-up). Wrapping a paragraph into
// a container block (blockquote, bullet_list — via Milkdown's wrapInBulletList/
// wrapInBlockquote input rules and toolbar toggles) used to keep the wrapped
// paragraph's id: the wrapper always starts at the exact numeric offset the
// wrapped block used to occupy, so the OLD bare-offset lookup found it
// directly. The mapped lookup above refuses that same lookup, because the
// wrapped block's OWN mapped position (tracked/oldByNewOffset) is NOT that
// offset -- it is nested one level deeper, strictly inside the wrapper -- so
// `tracked.has(offset)` was blocking the raw fallback with nothing to take
// its place. That is the regression this section pins.
describe('wrap: a paragraph pulled into a container block keeps its id (review finding 1)', () => {
  function fourParagraphDoc(): Node {
    return schema.nodes.doc.create(null, [
      block('paragraph', 'A', 'aaa'),
      block('paragraph', 'B', 'bbb'),
      block('paragraph', 'C', 'ccc'),
      block('paragraph', 'D', 'ddd'),
    ]);
  }

  function idsFor(doc0: Node): { ids: Map<number, string>; types: Map<number, string> } {
    const ids = new Map<number, string>();
    const types = new Map<number, string>();
    doc0.forEach((n, off) => {
      ids.set(off, `id-${n.attrs.tid}`);
      types.set(off, n.type.name);
    });
    return { ids, types };
  }

  function offsetOfType(doc: Node, typeName: string): number {
    let off = -1;
    doc.forEach((n, o) => {
      if (n.type.name === typeName) off = o;
    });
    return off;
  }

  function byTid(doc: Node): Map<string, number> {
    const m = new Map<string, number>();
    doc.forEach((n, off) => {
      m.set(n.attrs.tid, off);
    });
    return m;
  }

  for (const wrapperType of ['blockquote', 'bullet_list'] as const) {
    it(`single-block wrap into ${wrapperType} keeps the wrapped paragraph's id`, () => {
      resetBlockIdState();
      const doc0 = fourParagraphDoc();
      const { ids, types } = idsFor(doc0);
      const range = doc0.resolve(6).blockRange(doc0.resolve(6))!;
      const wrapping = findWrapping(range, schema.nodes[wrapperType])!;
      expect(wrapping).toBeTruthy(); // setup: a valid wrapping chain exists
      const tr = new Transform(doc0).wrap(range, wrapping);

      const wOffset = offsetOfType(tr.doc, wrapperType);
      expect(wOffset).toBeGreaterThanOrEqual(0); // setup: B really was wrapped into wrapperType
      expect(tr.doc.nodeAt(wOffset)!.textContent).toBe('bbb'); // setup: the wrapper's only content is B's text

      const [after] = assignBlockIds(tr.doc, ids, types, doc0, tr.mapping);
      expect(after.get(wOffset)).toBe('id-B');

      // A, C, D are untouched and keep their own ids.
      const tids = byTid(tr.doc);
      expect(after.get(tids.get('A')!)).toBe('id-A');
      expect(after.get(tids.get('C')!)).toBe('id-C');
      expect(after.get(tids.get('D')!)).toBe('id-D');
    });
  }

  it("multi-block wrap ($to = resolve(11)) keeps the first wrapped paragraph's id (pre-diff behaviour)", () => {
    resetBlockIdState();
    const doc0 = fourParagraphDoc();
    const { ids, types } = idsFor(doc0);
    const range = doc0.resolve(6).blockRange(doc0.resolve(11))!;
    const wrapping = findWrapping(range, schema.nodes.blockquote)!;
    expect(wrapping).toBeTruthy(); // setup: a valid wrapping chain exists
    const tr = new Transform(doc0).wrap(range, wrapping);

    const wOffset = offsetOfType(tr.doc, 'blockquote');
    expect(wOffset).toBeGreaterThanOrEqual(0);
    expect(tr.doc.nodeAt(wOffset)!.textContent).toBe('bbbccc'); // setup: B and C are both inside it

    const [after] = assignBlockIds(tr.doc, ids, types, doc0, tr.mapping);
    // Pre-diff behaviour: the first wrapped block's id wins the wrapper.
    expect(after.get(wOffset)).toBe('id-B');

    const tids = byTid(tr.doc);
    expect(after.get(tids.get('A')!)).toBe('id-A');
    expect(after.get(tids.get('D')!)).toBe('id-D');
    // C's own id is orphaned -- it was merged into the wrapper under id-B,
    // not preserved separately, matching pre-diff behaviour for a multi-block
    // merge (the same "first block wins" outcome as an ordinary join).
    expect([...after.values()]).not.toContain('id-C');
  });

  it('lift then rewrap in two transactions: the id survives both round-trips', () => {
    resetBlockIdState();
    const doc0 = fourParagraphDoc();
    const { ids: ids0, types: types0 } = idsFor(doc0);

    // Setup (not itself under test): wrap B into a blockquote first, so this
    // test starts from the "already wrapped, holds id-B" state the case
    // description assumes.
    const range0 = doc0.resolve(6).blockRange(doc0.resolve(6))!;
    const wrapping0 = findWrapping(range0, schema.nodes.blockquote)!;
    const t0 = new Transform(doc0).wrap(range0, wrapping0);
    const [ids1, types1] = assignBlockIds(t0.doc, ids0, types0, doc0, t0.mapping);
    const bqOffset0 = offsetOfType(t0.doc, 'blockquote');
    expect(ids1.get(bqOffset0)).toBe('id-B'); // setup precondition

    // Step 1: lift B back out of the blockquote (e.g. toggling the
    // blockquote off). Resolve to a position strictly inside B's own content,
    // one level deeper than the wrap tests above, mirroring their resolve(6).
    const liftRange = t0.doc.resolve(bqOffset0 + 2).blockRange()!;
    const target = liftTarget(liftRange);
    expect(target).not.toBeNull(); // setup: B really can be lifted back out
    const t1 = new Transform(t0.doc).lift(liftRange, target!);
    const [ids2, types2] = assignBlockIds(t1.doc, ids1, types1, t0.doc, t1.mapping);

    const tidsAfterLift = byTid(t1.doc);
    const bOffsetAfterLift = tidsAfterLift.get('B')!;
    expect(t1.doc.nodeAt(bOffsetAfterLift)!.type.name).toBe('paragraph'); // setup: B really is a plain paragraph again
    expect(ids2.get(bOffsetAfterLift)).toBe('id-B'); // the id survives the lift

    // Step 2: wrap B again (e.g. toggling the blockquote back on).
    const range2 = t1.doc.resolve(bOffsetAfterLift + 1).blockRange()!;
    const wrapping2 = findWrapping(range2, schema.nodes.blockquote)!;
    const t2 = new Transform(t1.doc).wrap(range2, wrapping2);
    const [ids3] = assignBlockIds(t2.doc, ids2, types2, t1.doc, t2.mapping);

    const bqOffset2 = offsetOfType(t2.doc, 'blockquote');
    expect(bqOffset2).toBeGreaterThanOrEqual(0);
    expect(ids3.get(bqOffset2)).toBe('id-B'); // the id survives the rewrap too
  });
});
