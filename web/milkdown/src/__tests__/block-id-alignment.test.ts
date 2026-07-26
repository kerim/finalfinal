// @vitest-environment jsdom
import { type Node, Schema } from '@milkdown/kit/prose/model';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  getAllBlockIds,
  getBlockIdAtPos,
  pmTypeForBlockType,
  resetBlockIdState,
  setBlockIdsForTopLevel,
} from '../block-id-plugin';
import type { ExpectedBlockMeta } from '../types';

// Regression guard for docs/plans/single-source-splice.md.
//
// These document the positional contract that setBlockIdsForTopLevel relies on: when
// the doc's top-level node arrangement and the ID array agree — the invariant the
// Swift-side fix now guarantees by construction, pushing `result.markdown` paired
// with `result.blockIds` from the same single `fetchBlocksWithIds()` call — each ID
// lands on the node it was intended for. This is a supplement to, not proof of, the
// live-app verification protocol in that plan's Part 4; it cannot exercise the
// WKWebView content-push pipeline where the original corruption actually occurred.

const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { group: 'block', content: 'inline*', toDOM: () => ['p', 0] },
    heading: {
      group: 'block',
      content: 'inline*',
      attrs: { level: { default: 1 } },
      toDOM: (node) => [`h${node.attrs.level}`, 0],
    },
    // Mirrors the real figure node's essential shape (block atom, no content) — see image-plugin.ts.
    figure: {
      group: 'block',
      atom: true,
      attrs: { src: { default: '' } },
      toDOM: () => ['div', { class: 'figure-stub' }],
    },
    // Mirrors the real thematic-break node's essential shape (block, no content) — see
    // @milkdown/preset-commonmark's hrSchema. The real PM node name is `hr`, not
    // `horizontal_rule` (that's the Swift-facing BlockType.rawValue string only).
    hr: { group: 'block', toDOM: () => ['hr'] },
    text: { group: 'inline' },
  },
});

function para(text: string): Node {
  return schema.nodes.paragraph.create(null, text ? [schema.text(text)] : []);
}

function heading(text: string, level = 1): Node {
  return schema.nodes.heading.create({ level }, [schema.text(text)]);
}

function figure(): Node {
  return schema.nodes.figure.create();
}

function hr(): Node {
  return schema.nodes.hr.create();
}

describe('setBlockIdsForTopLevel (doc and ID array agree)', () => {
  beforeEach(() => {
    // currentBlockIds/currentBlockTypes/pendingConfirmations are module-level state,
    // not per-instance, and no existing test in this suite resets them between cases.
    // Clear before each case so this test can't leak into, or be polluted by, others.
    resetBlockIdState();
  });

  it('assigns each ID to the node it was intended for', () => {
    // Models the non-zoom footnote-insertion body: a body paragraph, a Notes
    // heading, an existing footnote definition, and a newly-inserted second
    // definition — i.e. a doc built from the SAME source the ID array describes,
    // exactly what handleFootnoteInsertedImmediate now guarantees by pushing
    // result.markdown paired with result.blockIds from one DB fetch.
    const body = para('Body text');
    const notesHeading = heading('Notes');
    const def1 = para('[^1]: real text');
    const def2 = para('[^2]: ');
    const nodesInOrder = [body, notesHeading, def1, def2];
    const doc = schema.nodes.doc.create(null, nodesInOrder);

    const orderedIds = ['body-id', 'notes-heading-id', 'def1-id', 'def2-id'];
    setBlockIdsForTopLevel(orderedIds, doc);

    const ids = getAllBlockIds();
    expect(ids.size).toBe(orderedIds.length);

    // Recompute each node's offset the same way doc.forEach does internally, and
    // assert the ID landed on the node it was intended for — not merely that the
    // counts matched (a same-count/different-arrangement mismatch is exactly the
    // hazard class this whole plan is about).
    let offset = 0;
    for (let i = 0; i < nodesInOrder.length; i++) {
      expect(getBlockIdAtPos(offset)).toBe(orderedIds[i]);
      offset += nodesInOrder[i].nodeSize;
    }
  });
});

// Regression suite for the `expected` (3rd argument) alignment-check hardening.
// See docs/plans (setBlockIdsForTopLevel hardening plan) for full motivation: a
// mismatched (markdown, blockIds) pair once let an existing footnote's real
// definition text get silently replaced by blankness, because the id landed on
// the wrong (blank) node — same PM node TYPE, wrong content. These tests guard
// that a future mismatch of that shape gets its id WITHHELD instead of aliased.
describe('setBlockIdsForTopLevel — expected (3rd arg) alignment check', () => {
  beforeEach(() => {
    resetBlockIdState();
  });

  it('type mismatch at one slot: that id is withheld, other correctly-matching slots still assigned', () => {
    const p1 = para('First');
    const h1 = heading('A Heading');
    const p2 = para('Third');
    const doc = schema.nodes.doc.create(null, [p1, h1, p2]);
    const orderedIds = ['id-1', 'id-2', 'id-3'];
    // Slot 1 (offset after p1) is actually a heading, but expected says paragraph.
    const expected: ExpectedBlockMeta[] = [
      { blockType: 'paragraph', nonEmpty: true },
      { blockType: 'paragraph', nonEmpty: true }, // MISMATCH: actual node is a heading
      { blockType: 'paragraph', nonEmpty: true },
    ];

    setBlockIdsForTopLevel(orderedIds, doc, expected);

    const p1Offset = 0;
    const h1Offset = p1.nodeSize;
    const p2Offset = h1Offset + h1.nodeSize;

    expect(getBlockIdAtPos(p1Offset)).toBe('id-1');
    expect(getBlockIdAtPos(h1Offset)).toBeUndefined(); // withheld, not aliased
    expect(getBlockIdAtPos(p2Offset)).toBe('id-3');
  });

  it('content mismatch reproducing the historical bug shape: expected non-blank but node is blank → id NOT assigned', () => {
    const blank = para(''); // models an existing footnote definition that lost its text
    const doc = schema.nodes.doc.create(null, [blank]);
    const orderedIds = ['def-id'];
    const expected: ExpectedBlockMeta[] = [{ blockType: 'paragraph', nonEmpty: true }];

    setBlockIdsForTopLevel(orderedIds, doc, expected);

    expect(getBlockIdAtPos(0)).toBeUndefined();
  });

  it('atomic-type exemption: a figure-like atom with no textContent and expected.nonEmpty=true still gets its id assigned', () => {
    const fig = figure();
    const doc = schema.nodes.doc.create(null, [fig]);
    const orderedIds = ['fig-id'];
    // BlockType.rawValue for image blocks is "image"; pmTypeForBlockType maps it to "figure".
    const expected: ExpectedBlockMeta[] = [{ blockType: 'image', nonEmpty: true }];

    setBlockIdsForTopLevel(orderedIds, doc, expected);

    expect(getBlockIdAtPos(0)).toBe('fig-id');
  });

  // Pins the hr (thematic-break) type-name fix: BlockType.rawValue for a
  // horizontal-rule block is "horizontal_rule", but the real ProseMirror node
  // name is "hr". Before the fix, BLOCK_TYPES (the set isBlockType() checks)
  // listed 'horizontal_rule' instead of 'hr', so a real hr node never
  // satisfied isBlockType() at all — it failed the
  // `if (isBlockType(node) && index < orderedIds.length)` guard in
  // setBlockIdsForTopLevel's doc.forEach and was skipped outright.
  // `index++` lives INSIDE that same guarded block, so a fully-skipped node
  // also skips the increment — unlike an ordinary withheld/mismatched id
  // (type or content check fails but isBlockType() still passed), where
  // index++ still runs and positional accounting stays in lockstep. Because
  // the hr node's slot never advanced the counter, every id after it in the
  // ordered array was consumed by the WRONG node — a genuine off-by-one
  // shift — corrupting block identity for the rest of the document. (A mere
  // withheld id, by contrast, never causes a shift: the id is dropped but
  // index still ticks, so later nodes stay aligned with their own ids.)
  // pmTypeForBlockType('horizontal_rule') also needed its own fix (see the
  // next test) since it gates a *second*, independent type-name comparison
  // once a node has already passed isBlockType(). This test documents that
  // pmTypeForBlockType now returns 'hr' and reproduces the exact
  // [paragraph, hr, paragraph] shape end-to-end: no id should be withheld.
  it('pmTypeForBlockType maps "horizontal_rule" (Swift BlockType.rawValue) to the real PM node name "hr"', () => {
    expect(pmTypeForBlockType('horizontal_rule')).toBe('hr');
  });

  it('hr sitting between two paragraphs: none of the three ids are withheld (regression guard for the off-by-one shift)', () => {
    const p1 = para('Before the rule.');
    const rule = hr();
    const p2 = para('After the rule.');
    const doc = schema.nodes.doc.create(null, [p1, rule, p2]);
    const orderedIds = ['id-before', 'id-rule', 'id-after'];
    const expected: ExpectedBlockMeta[] = [
      { blockType: 'paragraph', nonEmpty: true },
      { blockType: 'horizontal_rule', nonEmpty: false },
      { blockType: 'paragraph', nonEmpty: true },
    ];

    setBlockIdsForTopLevel(orderedIds, doc, expected);

    const ids = getAllBlockIds();
    expect(ids.size).toBe(3); // zero withheld

    const p1Offset = 0;
    const ruleOffset = p1.nodeSize;
    const p2Offset = ruleOffset + rule.nodeSize;
    expect(getBlockIdAtPos(p1Offset)).toBe('id-before');
    expect(getBlockIdAtPos(ruleOffset)).toBe('id-rule');
    expect(getBlockIdAtPos(p2Offset)).toBe('id-after');
  });

  it('directionality: expected.nonEmpty=false but actual node is non-blank → NO mismatch (one-directional by design)', () => {
    const p = para('Not blank at all');
    const doc = schema.nodes.doc.create(null, [p]);
    const orderedIds = ['p-id'];
    const expected: ExpectedBlockMeta[] = [{ blockType: 'paragraph', nonEmpty: false }];

    setBlockIdsForTopLevel(orderedIds, doc, expected);

    expect(getBlockIdAtPos(0)).toBe('p-id');
  });

  it('unmapped blockType (bibliography, list_item) never produces a false-positive type mismatch', () => {
    const p1 = para('Body');
    const p2 = para('More body');
    const doc = schema.nodes.doc.create(null, [p1, p2]);
    const orderedIds = ['id-1', 'id-2'];
    const expected: ExpectedBlockMeta[] = [
      { blockType: 'bibliography', nonEmpty: false },
      { blockType: 'list_item', nonEmpty: false },
    ];

    setBlockIdsForTopLevel(orderedIds, doc, expected);

    expect(getBlockIdAtPos(0)).toBe('id-1');
    expect(getBlockIdAtPos(p1.nodeSize)).toBe('id-2');
  });

  it('wholesale-shift escalation: ≥3 mismatches at >30% of slots fires the louder WIDESPREAD tag', () => {
    const nodes = [para('a'), para('b'), para('c'), para('d')];
    const doc = schema.nodes.doc.create(null, nodes);
    const orderedIds = ['id-1', 'id-2', 'id-3', 'id-4'];
    // All 4 slots type-mismatched (expect heading, actual paragraph) — 4/4 = 100% > 30%, count >= 3.
    const expected: ExpectedBlockMeta[] = nodes.map(() => ({ blockType: 'heading', nonEmpty: false }));

    const postMessages: unknown[] = [];
    (window as any).webkit = {
      messageHandlers: { errorHandler: { postMessage: (msg: unknown) => postMessages.push(msg) } },
    };
    try {
      setBlockIdsForTopLevel(orderedIds, doc, expected);
    } finally {
      delete (window as any).webkit;
    }

    expect(postMessages.length).toBeGreaterThan(0);
    const messages = postMessages.map((m) => (m as { message: string }).message);
    expect(messages.some((m) => m.includes('WIDESPREAD ALIGNMENT MISMATCH'))).toBe(true);
  });

  it('backward compatibility: explicit 2-arg call and 3-arg call with expected=undefined behave identically', () => {
    const body = para('Body text');
    const notesHeading = heading('Notes');
    const nodesInOrder = [body, notesHeading];
    const orderedIds = ['body-id', 'heading-id'];

    const doc1 = schema.nodes.doc.create(null, nodesInOrder);
    setBlockIdsForTopLevel(orderedIds, doc1);
    const idsFrom2Arg = getAllBlockIds();

    resetBlockIdState();

    const doc2 = schema.nodes.doc.create(null, nodesInOrder);
    setBlockIdsForTopLevel(orderedIds, doc2, undefined);
    const idsFrom3ArgUndefined = getAllBlockIds();

    expect(idsFrom3ArgUndefined).toEqual(idsFrom2Arg);
  });
});
