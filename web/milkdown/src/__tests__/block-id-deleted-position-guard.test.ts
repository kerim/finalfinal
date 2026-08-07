// @vitest-environment jsdom
import { type Node, Schema } from '@milkdown/kit/prose/model';
import { Transform } from '@milkdown/kit/prose/transform';
import { beforeEach, describe, expect, it } from 'vitest';
import { assignBlockIds, canClaimUnderStructuralChange, resetBlockIdState } from '../block-id-plugin';

// Companion suite to block-id-citation-blank-pin.test.ts, covering the
// structural-deletion guard (`canClaimUnderStructuralChange` /
// `deletedOldPositions` in assignBlockIds) beyond the core citation-vs-blank
// repro: the stale-coordinate guard, whole-document replace, and an
// empty-node type conversion that legitimately sits right at the position
// the guard inspects.

const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { group: 'block', content: 'inline*', toDOM: () => ['p', 0] },
    heading: { group: 'block', content: 'inline*', attrs: { level: { default: 1 } }, toDOM: () => ['h1', 0] },
    text: { group: 'inline' },
    citation: { group: 'inline', inline: true, atom: true, toDOM: () => ['span', {}, ''] },
  },
});

function para(text: string): Node {
  return schema.nodes.paragraph.create(null, text ? [schema.text(text)] : []);
}

function citationPara(): Node {
  return schema.nodes.paragraph.create(null, [schema.nodes.citation.create()]);
}

describe('assignBlockIds — structural-deletion guard', () => {
  beforeEach(() => {
    resetBlockIdState();
  });

  it('mirror-of-repro: a surviving blank paragraph keeps its own id instead of an adjacent deleted citation paragraph’s', () => {
    const padPara = para('Padding text here');
    const citePara = citationPara();
    const blankPara = para('');
    const tailPara = para('Tail');

    const padSize = padPara.nodeSize;
    const citeOffset = padSize;
    const citeSize = citePara.nodeSize;
    const blankOffset = citeOffset + citeSize;
    const blankSize = blankPara.nodeSize;
    const tailOffset = blankOffset + blankSize;

    const oldDoc = schema.nodes.doc.create(null, [padPara, citePara, blankPara, tailPara]);
    const existingIds = new Map<number, string>([
      [0, 'pad-id'],
      [citeOffset, 'cite-id'],
      [blankOffset, 'blank-id'],
      [tailOffset, 'tail-id'],
    ]);
    const existingTypes = new Map<number, string>([
      [0, 'paragraph'],
      [citeOffset, 'paragraph'],
      [blankOffset, 'paragraph'],
      [tailOffset, 'paragraph'],
    ]);

    let tr = new Transform(oldDoc);
    tr = tr.delete(0, blankOffset); // deletes padPara and citePara together

    const [newIds] = assignBlockIds(tr.doc, existingIds, existingTypes, oldDoc, tr.mapping);

    expect(newIds.get(0)).toBe('blank-id');
    expect(newIds.get(0)).not.toBe('cite-id');
  });

  it('content-only deletion: emptying a surviving paragraph’s text does NOT register as deletedAcross at its own content position', () => {
    // A paragraph that loses all its text but is never itself removed from
    // the document must not be mistaken, by the mapping alone, for a
    // structurally-deleted block — that distinction is exactly what
    // `deletedOldPositions` relies on `deletedAcross` to preserve.
    const firstPara = para('Hello');
    const secondPara = para('Two');
    const oldDoc = schema.nodes.doc.create(null, [firstPara, secondPara]);

    const tr = new Transform(oldDoc).delete(1, 1 + 'Hello'.length); // empties firstPara's text, node survives

    expect(tr.mapping.mapResult(0 + 1).deletedAcross).toBe(false);
  });

  it('no-mapping backward compat: omitting the 5th param preserves pre-fix behavior', () => {
    // Reuses the (b, removal) shape from the pin suite, but calls
    // assignBlockIds with NO mapping at all (as the plugin's `init` call
    // site does) — deletedOldPositions must stay empty, so the new guard
    // never fires and the pre-existing content-overlap behavior is
    // unaffected.
    const oldDoc = schema.nodes.doc.create(null, [citationPara(), para('Two'), para('Three')]);
    const existingIds = new Map<number, string>([
      [0, 'cite-id'],
      [citationPara().nodeSize, 'two-id'],
      [citationPara().nodeSize + para('Two').nodeSize, 'three-id'],
    ]);
    const existingTypes = new Map<number, string>([
      [0, 'paragraph'],
      [citationPara().nodeSize, 'paragraph'],
      [citationPara().nodeSize + para('Two').nodeSize, 'paragraph'],
    ]);
    const newDoc = schema.nodes.doc.create(null, [para(''), para('Two'), para('Three'), para('Four')]);

    const [newIds] = assignBlockIds(newDoc, existingIds, existingTypes, oldDoc); // no mapping arg

    expect(newIds.get(0)).toBe('cite-id');
  });

  it('stale-baseline guard: an existingIds offset beyond oldDoc.content.size must not throw and must not block a legitimate claim', () => {
    // `setBlockIdsForTopLevel` (called directly between transactions, e.g.
    // from `syncBlockIds`) only ever `.set()`s and never prunes, so
    // `currentBlockIds` can carry a stray offset left over from an older,
    // larger doc. That phantom entry alone is enough to make blockCount !==
    // existingIds.size (forcing structureChanged = true) even with no real
    // edit — exercising the deletedOldPositions precompute against an
    // out-of-range key.
    const oldDoc = schema.nodes.doc.create(null, [para('Hello')]);
    const staleOffset = oldDoc.content.size + 1000;
    const existingIds = new Map<number, string>([
      [0, 'real-id'],
      [staleOffset, 'stale-id'],
    ]);
    const existingTypes = new Map<number, string>([
      [0, 'paragraph'],
      [staleOffset, 'paragraph'],
    ]);

    const tr = new Transform(oldDoc); // no-op transaction, but a real Mapping

    // Single call: assignBlockIds mutates module-level state
    // (recentlySplitEmptyIds and friends), so asserting on a second,
    // separate invocation would check a polluted run instead of the one
    // actually exercised by the not-toThrow() check.
    let result: [Map<number, string>, Map<number, string>] | undefined;
    expect(() => {
      result = assignBlockIds(tr.doc, existingIds, existingTypes, oldDoc, tr.mapping);
    }).not.toThrow();

    const [newIds] = result!;
    expect(newIds.get(0)).toBe('real-id');
  });

  it('whole-document replace: an empty block at a whole-doc-replaced position does not inherit an unrelated empty block’s id', () => {
    // When the LCS diff in api-content.ts finds NO common top-level blocks
    // at all, it falls back to one tr.replace() spanning the entire
    // document — marking every old position deletedAcross. A blank
    // paragraph that happens to reappear at the same position in the new
    // doc gets a fresh identity via the normal (temp-id) path instead of
    // silently inheriting an unrelated old paragraph's id just because both
    // happen to be empty. Churn (the new block NOT keeping the old block's
    // id) is the expected, accepted outcome here — the guard's job is only
    // to refuse the false-match inheritance, not to preserve identity
    // through a whole-doc replace. See the next test for the case that
    // proves the guard's narrow (oldText === '' only) scoping is load-
    // bearing: a NON-empty survivor must keep its id under the same kind
    // of transaction.
    //
    // The old doc's block is itself empty (matching the new doc's first
    // block) — the sharpest exercise of the new gate, since oldText==='' is
    // exactly the band it inspects. A block count mismatch (1 old block, 2
    // new blocks) forces structureChanged = true so Phase 1's
    // `!structureChanged` early-out doesn't bypass the check entirely.
    const oldDoc = schema.nodes.doc.create(null, [para('')]);
    const existingIds = new Map<number, string>([[0, 'old-empty-id']]);
    const existingTypes = new Map<number, string>([[0, 'paragraph']]);

    // Whole-document replace: mirrors buildBlockLevelReplace's single-range
    // fallback in api-content.ts (the LCS finds no usable common prefix
    // given the block-count mismatch, so the entire old doc is replaced in
    // one step).
    const newContent = schema.nodes.doc.create(null, [para(''), para('Brand new')]).content;
    const realTr = new Transform(oldDoc).replaceWith(0, oldDoc.content.size, newContent);

    // Sanity-check the premise: the old (empty) block's position is indeed
    // deletedAcross under this whole-doc replace.
    expect(realTr.mapping.mapResult(0 + 1).deletedAcross).toBe(true);

    // Single call: assignBlockIds mutates module-level state, so asserting
    // on a second, separate invocation would check a polluted run instead
    // of the one actually exercised by the not-toThrow() check.
    let result: [Map<number, string>, Map<number, string>] | undefined;
    expect(() => {
      result = assignBlockIds(realTr.doc, existingIds, existingTypes, oldDoc, realTr.mapping);
    }).not.toThrow();

    const [newIds, newTypes] = result!;

    // The new empty paragraph at position 0 must NOT inherit 'old-empty-id'
    // — that would be exactly the citation/blank confusion this fix closes,
    // just reached via whole-document replace instead of proximity
    // matching. It gets a fresh id instead (still defined — every block
    // gets SOME id, just not this unrelated one).
    const newAId = newIds.get(0);
    expect(newAId).toBeDefined();
    expect(newAId).not.toBe('old-empty-id');
    expect(newTypes.get(0)).toBe('paragraph');

    // The second new block ('Brand new', no old counterpart at all) is
    // unaffected either way — confirms the whole-doc-replace path doesn't
    // throw or misbehave beyond the position the guard actually touches.
    const newBId = newIds.get(para('').nodeSize);
    expect(newBId).toBeDefined();
    expect(newBId).not.toBe('old-empty-id');
  });

  it('whole-document replace: a NON-EMPTY block whose text survives the replace keeps its own id', () => {
    // This is the case the guard's narrow (oldText === '' only) scoping
    // exists to protect, and nothing previously exercised it: a whole-doc
    // replace marks EVERY old position deletedAcross — including one whose
    // text genuinely carries over into the new doc unchanged. If the guard
    // refused claims at deleted positions in general (not just oldText===''
    // ones), this survivor would wrongly lose its identity too. A broad
    // refusal would strip every block's identity on whole-doc replace;
    // this test is what stands between that broad (wrong) behavior and the
    // current narrow one.
    const oldDoc = schema.nodes.doc.create(null, [para('Hello')]);
    const existingIds = new Map<number, string>([[0, 'hello-id']]);
    const existingTypes = new Map<number, string>([[0, 'paragraph']]);

    const newContent = schema.nodes.doc.create(null, [para('Hello'), para('Brand new')]).content;
    const realTr = new Transform(oldDoc).replaceWith(0, oldDoc.content.size, newContent);

    // Sanity-check the premise: the surviving block's own old position is
    // also deletedAcross under this whole-doc replace, same as the empty
    // case above — the guard must still let it through.
    expect(realTr.mapping.mapResult(0 + 1).deletedAcross).toBe(true);

    const [newIds] = assignBlockIds(realTr.doc, existingIds, existingTypes, oldDoc, realTr.mapping);

    expect(newIds.get(0)).toBe('hello-id');
  });

  it('empty-paragraph type conversion: converting an empty paragraph to a heading preserves its id even amid an unrelated structural change', () => {
    // setNodeMarkup on an empty node produces a ReplaceAroundStep whose
    // "gap" (preserved content) is zero-width, landing exactly at
    // oldPos + 1 — squarely in the band the new guard inspects. This proves
    // the guard does NOT mistake that for a structural deletion.
    const firstPara = para('');
    const secondPara = para('Two');
    const oldDoc = schema.nodes.doc.create(null, [firstPara, secondPara]);
    const existingIds = new Map<number, string>([
      [0, 'blank-id'],
      [firstPara.nodeSize, 'two-id'],
    ]);
    const existingTypes = new Map<number, string>([
      [0, 'paragraph'],
      [firstPara.nodeSize, 'paragraph'],
    ]);

    let tr = new Transform(oldDoc);
    tr = tr.setNodeMarkup(0, schema.nodes.heading, { level: 1 });
    // Unrelated structural change elsewhere, forcing structureChanged = true
    // (blockCount 3 !== existingIds.size 2) — otherwise phase1CanClaim's
    // `!structureChanged` early-out would return true before ever reaching
    // the guard, and this test wouldn't exercise it.
    tr = tr.insert(tr.doc.content.size, para('Three'));

    // Sanity-check the premise: the empty node's own content position is
    // NOT reported as deletedAcross by this conversion.
    expect(tr.mapping.mapResult(0 + 1).deletedAcross).toBe(false);

    const [newIds, newTypes] = assignBlockIds(tr.doc, existingIds, existingTypes, oldDoc, tr.mapping);

    expect(newIds.get(0)).toBe('blank-id');
    expect(newTypes.get(0)).toBe('heading');
  });
});

describe('canClaimUnderStructuralChange — direct unit tests', () => {
  it('refuses an oldText==="" claim when oldPos is a structurally-deleted position', () => {
    const deleted = new Set<number>([5]);
    expect(canClaimUnderStructuralChange('', '', 'some-id', new Set(), 5, deleted)).toBe(false);
  });

  it('allows an oldText==="" claim when oldPos is NOT a structurally-deleted position', () => {
    const deleted = new Set<number>([5]);
    expect(canClaimUnderStructuralChange('', '', 'some-id', new Set(), 7, deleted)).toBe(true);
  });

  it('never refuses a non-empty oldText claim, even at a deleted position', () => {
    const deleted = new Set<number>([5]);
    // meaningfulTextOverlap('Hello', 'Hello') === true, so this must succeed
    // regardless of deletion status — the guard is scoped to oldText==='' only.
    expect(canClaimUnderStructuralChange('Hello', 'Hello', 'some-id', new Set(), 5, deleted)).toBe(true);
  });

  it('ignores deletedOldPositions when oldPos is undefined (no position context)', () => {
    const deleted = new Set<number>([5]);
    expect(canClaimUnderStructuralChange('', '', 'some-id', new Set(), undefined, deleted)).toBe(true);
  });

  it('still allows the recently-split-empty bypass when the position is not marked deleted', () => {
    const recentlySplit = new Set<string>(['split-id']);
    expect(canClaimUnderStructuralChange('', 'newly typed text', 'split-id', recentlySplit, 7, new Set([5]))).toBe(
      true
    );
  });

  it('refuses a deleted-position empty-text claim even when the id also carries a recently-split-empty marker', () => {
    // The deleted-position refusal is unconditional for oldText==='' — it
    // takes precedence over the split bypass, since a position that was
    // itself structurally deleted has no legitimate "split-then-fill" story
    // to tell about THIS id's old slot.
    const recentlySplit = new Set<string>(['split-id']);
    const deleted = new Set<number>([5]);
    expect(canClaimUnderStructuralChange('', 'newly typed text', 'split-id', recentlySplit, 5, deleted)).toBe(false);
  });

  it('falls through to plain meaningfulTextOverlap when oldText is undefined (no old node at that position)', () => {
    expect(canClaimUnderStructuralChange(undefined, 'anything', 'some-id', new Set(), 5, new Set([5]))).toBe(false);
  });
});
