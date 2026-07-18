// @vitest-environment jsdom
import { type Node, Schema } from '@milkdown/kit/prose/model';
import { beforeEach, describe, expect, it } from 'vitest';
import { assignBlockIds, resetBlockIdState } from '../block-id-plugin';

// Pinning suite for the citation-atom-blindness gap in assignBlockIds's
// text-overlap matching.
//
// The gap: ProseMirror's Node.textContent silently strips inline atom nodes
// — a paragraph containing only a `citation` atom reports textContent ===
// '', identical to a genuinely empty paragraph. meaningfulTextOverlap (and
// therefore phase1CanClaim / Phase 2's proximity matching) only ever sees
// that stripped string, so it cannot tell "citation-only paragraph" apart
// from "truly empty paragraph" by content alone.
//
// This was analyzed in detail during citation-insertion race-condition work
// (see cayw.ts) and DELIBERATELY NOT FIXED at the comparison layer, because
// two required behaviors present as the IDENTICAL (oldText, newText) input
// pair to any content-only comparison function:
//   (b) a paragraph whose OWN citation was just added/removed must still
//       match its own earlier/later self (oldText==='' , newText==='' — a
//       true match, must succeed)
//   (c) an UNRELATED empty paragraph must NOT steal a citation paragraph's
//       identity (oldText==='', newText==='' — again, from a DIFFERENT
//      node — must NOT succeed, but looks identical to (b) at this layer)
// There is no signal in (old-text, new-text) alone that distinguishes "same
// node, content changed" from "different node, coincidental collision." A
// real fix would need creation-time identity marking (e.g. tagging citation
// atoms or their host paragraphs at insertion time) — more invasive, out of
// scope for now. Tests 1 and 2 below pin the correct (b) behavior so it
// can't regress; Test 3 pins today's actual (c) outcome as a known, accepted
// gap.

const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { group: 'block', content: 'inline*', toDOM: () => ['p', 0] },
    text: { group: 'inline' },
    // Minimal stand-in for the real citation node (citation-plugin.ts) —
    // pure-function testing of assignBlockIds only needs the type name
    // ('citation') that isBlankDueToExemptAtom/CONTENT_CHECK_ATOM_EXEMPTIONS
    // checks for; no attrs or real citation machinery required.
    citation: { group: 'inline', inline: true, atom: true, toDOM: () => ['span', {}, ''] },
  },
});

function para(text: string): Node {
  return schema.nodes.paragraph.create(null, text ? [schema.text(text)] : []);
}

function citationPara(): Node {
  return schema.nodes.paragraph.create(null, [schema.nodes.citation.create()]);
}

describe('assignBlockIds — citation-atom blindness in text-overlap matching', () => {
  beforeEach(() => {
    resetBlockIdState();
  });

  it('(b, removal) a paragraph keeps its own id when its own citation is removed, even amid an unrelated structural change elsewhere', () => {
    // Old doc: block 0 is citation-only. Blocks 1-2 have real, distinguishing text.
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

    // New doc: block 0's citation is gone (genuinely empty now). Blocks 1-2
    // unchanged in content. A 4th paragraph is appended — an unrelated
    // structural change elsewhere that forces structureChanged = true
    // (blockCount 4 !== existingIds.size 3), so this exercises the
    // structural content-check path, not the `!structureChanged` early-out.
    const newDoc = schema.nodes.doc.create(null, [para(''), para('Two'), para('Three'), para('Four')]);

    const [newIds] = assignBlockIds(newDoc, existingIds, existingTypes, oldDoc);

    // Keyed by POSITION (0 is always the first block's offset in both old
    // and new docs, regardless of how later blocks' offsets shift when the
    // citation-only paragraph's size changes) — not by any text-based
    // lookup, since '' is not a distinguishing key here anyway.
    expect(newIds.get(0)).toBe('cite-id');
  });

  it('(b, addition) a paragraph keeps its own id when a citation is inserted into it, even amid an unrelated structural change elsewhere', () => {
    // Symmetric to the removal case: old doc's block 0 is genuinely empty.
    const oldDoc = schema.nodes.doc.create(null, [para(''), para('Two'), para('Three')]);
    const existingIds = new Map<number, string>([
      [0, 'blank-id'],
      [para('').nodeSize, 'two-id'],
      [para('').nodeSize + para('Two').nodeSize, 'three-id'],
    ]);
    const existingTypes = new Map<number, string>([
      [0, 'paragraph'],
      [para('').nodeSize, 'paragraph'],
      [para('').nodeSize + para('Two').nodeSize, 'paragraph'],
    ]);

    // New doc: a citation is now inserted into block 0. Blocks 1-2 unchanged.
    // A 4th paragraph is appended, again forcing structureChanged = true.
    const newDoc = schema.nodes.doc.create(null, [citationPara(), para('Two'), para('Three'), para('Four')]);

    const [newIds] = assignBlockIds(newDoc, existingIds, existingTypes, oldDoc);

    expect(newIds.get(0)).toBe('blank-id');
  });

  it("(c, KNOWN GAP) an unrelated blank paragraph can steal a citation-only paragraph's id when an earlier deletion brings it into closer proximity", () => {
    // Old doc: 4 blocks. Block 0 is ordinary padding text (will be deleted
    // along with block 1 below — an edit entirely unrelated to blocks 2-3).
    // Block 1 is citation-only. Block 2 is genuinely empty. Block 3 is
    // ordinary tail text.
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

    // New doc: the padding paragraph AND the citation-only paragraph are
    // both deleted entirely (a single unrelated edit at the start of the
    // document). The genuinely-empty paragraph and the tail paragraph
    // survive untouched, just shifted forward to offsets 0 and blankSize.
    // structureChanged fires (blockCount 2 !== existingIds.size 4).
    const newDoc = schema.nodes.doc.create(null, [blankPara, tailPara]);

    const [newIds] = assignBlockIds(newDoc, existingIds, existingTypes, oldDoc);

    // What SHOULD happen, if the matcher could see through citation
    // blindness: the surviving empty paragraph (truly the same node as old
    // 'blank-id') keeps 'blank-id', and 'cite-id' is retired along with the
    // deleted citation paragraph.
    //
    // What ACTUALLY happens: because both 'cite-id' (citation-only, old
    // textContent stripped to '') and 'blank-id' (genuinely empty, old
    // textContent '') look identical — '' === '' — to
    // canClaimViaRecentSplitBypass/meaningfulTextOverlap, BOTH become valid
    // Phase-2 candidates for the surviving empty paragraph at new offset 0.
    // Phase 2's closest-first greedy matching picks by raw offset distance:
    // cite-id's old offset (citeOffset) is closer to new offset 0 than
    // blank-id's own old offset (blankOffset) is (citeOffset < blankOffset
    // by construction — cite-id sits directly after the deleted padding,
    // blank-id sits one paragraph further in) — so cite-id wins, and the
    // paragraph's real prior identity, blank-id, is silently dropped.
    //
    // This pins a KNOWN, ACCEPTED gap: citation-atom blindness in
    // meaningfulTextOverlap can let an unrelated blank paragraph and a
    // citation-only paragraph be confused for each other under
    // structureChanged. It is deliberately not fixed because no proposed
    // comparison-only fix could distinguish this case from the correct
    // cases pinned in the two tests above (see the two-case impossibility
    // argument in this file's header comment). If this test's asserted
    // outcome ever needs to change because a real fix (e.g. creation-time
    // identity marking) lands, that's expected — update this comment and
    // assertion together with that fix; a change here alone is not a
    // regression signal.
    expect(newIds.get(0)).toBe('cite-id');
    expect(newIds.get(0)).not.toBe('blank-id');
  });
});
