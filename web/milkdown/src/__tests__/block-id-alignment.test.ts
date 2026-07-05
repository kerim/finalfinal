// @vitest-environment jsdom
import { type Node, Schema } from '@milkdown/kit/prose/model';
import { beforeEach, describe, expect, it } from 'vitest';
import { getAllBlockIds, getBlockIdAtPos, resetBlockIdState, setBlockIdsForTopLevel } from '../block-id-plugin';

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
    text: { group: 'inline' },
  },
});

function para(text: string): Node {
  return schema.nodes.paragraph.create(null, text ? [schema.text(text)] : []);
}

function heading(text: string, level = 1): Node {
  return schema.nodes.heading.create({ level }, [schema.text(text)]);
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
