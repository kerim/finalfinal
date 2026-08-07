// @vitest-environment jsdom
import { type Node, Schema } from '@milkdown/kit/prose/model';
import { Transform } from '@milkdown/kit/prose/transform';
import { beforeEach, describe, expect, it } from 'vitest';
import { assignBlockIds, resetBlockIdState } from '../block-id-plugin';

// Pinning suite for the citation-atom-blindness gap in assignBlockIds's
// text-overlap matching.
//
// The gap: ProseMirror's Node.textContent silently strips inline atom nodes
// — a paragraph containing only a `citation` atom reports textContent ===
// '', identical to a genuinely empty paragraph. meaningfulTextOverlap alone
// cannot tell "citation-only paragraph" apart from "truly empty paragraph"
// by content — two required behaviors present as the IDENTICAL (oldText,
// newText) input pair to any content-only comparison function:
//   (b) a paragraph whose OWN citation was just added/removed must still
//       match its own earlier/later self (oldText==='' , newText==='' — a
//       true match, must succeed)
//   (c) an UNRELATED empty paragraph must NOT steal a citation paragraph's
//       identity (oldText==='', newText==='' — again, from a DIFFERENT
//       node — must NOT succeed, but looks identical to (b) at this layer)
//
// The fix: `assignBlockIds` now accepts the transaction's `tr.mapping` (5th
// param). `Mapping.mapResult(oldPos + 1).deletedAcross` supplies a signal
// content alone never could — whether the OLD node at a given position was
// itself structurally deleted by this transaction, as opposed to merely
// edited in place. That's exactly the missing piece: cases (b) above are
// in-place edits of a SURVIVING node (never deletedAcross at their own old
// position), while case (c)'s citation paragraph is deleted outright
// (deletedAcross === true at its old position). `canClaimUnderStructuralChange`
// (block-id-plugin.ts) refuses an oldText==='' claim exactly when the old
// position was structurally deleted, resolving the ambiguity that
// meaningfulTextOverlap alone could never resolve. All three cases below now
// run through a REAL `Transform` so `tr.mapping` reflects an actual
// ProseMirror step sequence, not a hand-built approximation.

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

    // Real transaction: delete the citation atom inside block 0 (leaving it
    // genuinely empty), then append an unrelated 4th paragraph — forcing
    // structureChanged = true (blockCount 4 !== existingIds.size 3), so this
    // exercises the structural content-check path, not the
    // `!structureChanged` early-out.
    let tr = new Transform(oldDoc);
    tr = tr.delete(1, 1 + schema.nodes.citation.create().nodeSize); // remove the citation atom itself
    tr = tr.insert(tr.doc.content.size, para('Four'));

    const [newIds] = assignBlockIds(tr.doc, existingIds, existingTypes, oldDoc, tr.mapping);

    // Keyed by POSITION (0 is always the first block's offset in both old
    // and new docs) — not by any text-based lookup, since '' is not a
    // distinguishing key here anyway.
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

    // Real transaction: insert a citation into block 0, then append an
    // unrelated 4th paragraph, again forcing structureChanged = true.
    let tr = new Transform(oldDoc);
    tr = tr.insert(1, schema.nodes.citation.create());
    tr = tr.insert(tr.doc.content.size, para('Four'));

    const [newIds] = assignBlockIds(tr.doc, existingIds, existingTypes, oldDoc, tr.mapping);

    expect(newIds.get(0)).toBe('blank-id');
  });

  it('(c, FIXED) an unrelated blank paragraph no longer steals a citation-only paragraph’s id when an earlier deletion brings it into closer proximity', () => {
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

    // Real transaction: delete the padding paragraph AND the citation-only
    // paragraph entirely (a single unrelated edit at the start of the
    // document). The genuinely-empty paragraph and the tail paragraph
    // survive untouched, just shifted forward. structureChanged fires
    // (blockCount 2 !== existingIds.size 4).
    let tr = new Transform(oldDoc);
    tr = tr.delete(0, blankOffset);

    const [newIds] = assignBlockIds(tr.doc, existingIds, existingTypes, oldDoc, tr.mapping);

    // Before the fix: because both 'cite-id' (citation-only, old textContent
    // stripped to '') and 'blank-id' (genuinely empty, old textContent '')
    // looked identical — '' === '' — to canClaimViaRecentSplitBypass /
    // meaningfulTextOverlap, BOTH were valid Phase-2 candidates for the
    // surviving empty paragraph at new offset 0, and raw offset distance
    // (cite-id's old offset is closer) silently handed it the wrong id.
    //
    // After the fix: `tr.mapping` tells `canClaimUnderStructuralChange` that
    // cite-id's old position was structurally deleted (deletedAcross ===
    // true), so an oldText==='' claim against it is refused outright. Only
    // blank-id — the paragraph's real prior identity, never deleted — is a
    // valid candidate at new offset 0. cite-id is retired along with the
    // citation paragraph, as it should be.
    expect(newIds.get(0)).toBe('blank-id');
    expect(newIds.get(0)).not.toBe('cite-id');
  });
});
