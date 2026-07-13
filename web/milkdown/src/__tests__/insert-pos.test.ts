import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import { Schema } from '@milkdown/kit/prose/model';
import { Transform } from '@milkdown/kit/prose/transform';
import { describe, expect, it } from 'vitest';
import { computeCursorAwareInsertPos } from '../api-content';

// Regression/design-verification suite for the "pasted image lands in the
// wrong position" fix (image-placement plan, item 1 of 5).
//
// This file is a committed, re-runnable replacement for the throwaway
// verification scripts used while drafting the fix plan. It pins down the
// exact position-selection algorithm that `computeCursorAwareInsertPos`
// (implemented in `web/milkdown/src/api-content.ts`, imported directly above
// — no parallel/duplicated copy here) must implement, against a minimal
// schema whose content expressions mirror the REAL installed schema —
// verified directly against `@milkdown/preset-commonmark@7.18.0` /
// `@milkdown/preset-gfm@7.18.0` source in node_modules:
//   - blockquote:          content "block+"
//   - bullet_list/ordered_list: content "listItem+"
//   - list_item (incl. task list items, which only add a `checked` attr):
//                          content "paragraph block*"
//   - table_cell:          content "paragraph" (exactly one, no block*)
//   - footnote_definition (preset-gfm): content "block+" — schema-equivalent
//                          to blockquote, covered by the same logic.
//
// `figure` here stands in for the app's real figure node (image-plugin.ts),
// which has `group: 'block'` and no content (an atom leaf) — the same shape
// that matters for all the `canReplaceWith`/content-match checks below.

const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { content: 'inline*', group: 'block' },
    text: { group: 'inline' },
    blockquote: { content: 'block+', group: 'block' },
    footnote_definition: { content: 'block+', group: 'block' },
    bullet_list: { content: 'list_item+', group: 'block' },
    ordered_list: { content: 'list_item+', group: 'block', attrs: { order: { default: 1 } } },
    list_item: { content: 'paragraph block*' },
    table: { content: 'table_row+', group: 'block' },
    table_row: { content: 'table_cell*' },
    table_cell: { content: 'paragraph' },
    figure: { group: 'block', atom: true, content: '' },
  },
});

const figureType = schema.nodes.figure;

function p(text?: string): ProsemirrorNode {
  return schema.nodes.paragraph.create(null, text ? schema.text(text) : undefined);
}
function li(text: string): ProsemirrorNode {
  return schema.nodes.list_item.create(null, p(text));
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

function findParaPos(doc: ProsemirrorNode, text: string, offsetIntoText: number): number {
  let found: number | null = null;
  doc.descendants((node, pos) => {
    if (found !== null) return false;
    if (node.type.name === 'paragraph' && node.textContent === text) {
      found = pos + 1 + offsetIntoText;
    }
    return true;
  });
  if (found === null) throw new Error(`paragraph with text ${JSON.stringify(text)} not found`);
  return found;
}

function insertAndDescribe(
  doc: ProsemirrorNode,
  insertPos: number
): { top: string[]; emptyParagraphs: number; emptyListItems: number } {
  const step = new Transform(doc);
  step.insert(insertPos, figureType.create());
  const result: ProsemirrorNode = step.doc;

  let emptyParagraphs = 0;
  let emptyListItems = 0;
  result.descendants((node: ProsemirrorNode) => {
    if (node.type.name === 'paragraph' && node.content.size === 0) emptyParagraphs++;
    if (node.type.name === 'list_item' && node.childCount === 0) emptyListItems++;
    return true;
  });

  const top: string[] = [];
  result.forEach((node: ProsemirrorNode) => {
    top.push(describeNode(node));
  });
  return { top, emptyParagraphs, emptyListItems };
}

function describeNode(node: ProsemirrorNode): string {
  if (node.type.name === 'figure') return 'FIGURE';
  if (node.type.name === 'paragraph') return `p(${JSON.stringify(node.textContent)})`;
  if (node.type.name === 'list_item') {
    const children: string[] = [];
    node.forEach((c: ProsemirrorNode) => {
      children.push(describeNode(c));
    });
    return `li[${children.join(',')}]`;
  }
  if (node.type.name === 'bullet_list' || node.type.name === 'ordered_list') {
    const children: string[] = [];
    node.forEach((c: ProsemirrorNode) => {
      children.push(describeNode(c));
    });
    return `${node.type.name}(order=${node.attrs.order})[${children.join(',')}]`;
  }
  if (node.type.name === 'blockquote') {
    const children: string[] = [];
    node.forEach((c: ProsemirrorNode) => {
      children.push(describeNode(c));
    });
    return `blockquote[${children.join(',')}]`;
  }
  if (node.type.name === 'footnote_definition') {
    const children: string[] = [];
    node.forEach((c: ProsemirrorNode) => {
      children.push(describeNode(c));
    });
    return `footnote_definition[${children.join(',')}]`;
  }
  if (node.type.name === 'table') return 'table';
  return node.type.name;
}

function threeItemList(): ProsemirrorNode {
  return schema.nodes.doc.create(null, [
    schema.nodes.bullet_list.create(null, [li('Item 1'), li('Item 2'), li('Item 3')]),
  ]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('computeCursorAwareInsertPos — list start (flagship + regression)', () => {
  it('start of a non-first bullet cleanly splits the list, image between the two halves, no artifacts', () => {
    const doc = threeItemList();
    const pos = findParaPos(doc, 'Item 2', 0);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top, emptyParagraphs, emptyListItems } = insertAndDescribe(doc, insertPos);

    expect(emptyParagraphs).toBe(0);
    expect(emptyListItems).toBe(0);
    expect(top).toEqual([
      'bullet_list(order=undefined)[li[p("Item 1")]]',
      'FIGURE',
      'bullet_list(order=undefined)[li[p("Item 2")],li[p("Item 3")]]',
    ]);
  });

  it('start of the first bullet places the image before the entire list', () => {
    const doc = threeItemList();
    const pos = findParaPos(doc, 'Item 1', 0);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top } = insertAndDescribe(doc, insertPos);
    expect(top[0]).toBe('FIGURE');
  });
});

describe('computeCursorAwareInsertPos — list end (bug fix: no over-escalation)', () => {
  it('end of the MIDDLE item nests the image inside that item — does NOT split the list', () => {
    const doc = threeItemList();
    const pos = findParaPos(doc, 'Item 2', 'Item 2'.length);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top, emptyParagraphs, emptyListItems } = insertAndDescribe(doc, insertPos);

    expect(emptyParagraphs).toBe(0);
    expect(emptyListItems).toBe(0);
    // Exactly one top-level bullet_list — NOT split into two.
    expect(top).toHaveLength(1);
    expect(top[0]).toBe('bullet_list(order=undefined)[li[p("Item 1")],li[p("Item 2"),FIGURE],li[p("Item 3")]]');
  });

  it('end of the first item nests inside it (no escalation)', () => {
    const doc = threeItemList();
    const pos = findParaPos(doc, 'Item 1', 'Item 1'.length);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top } = insertAndDescribe(doc, insertPos);
    expect(top).toHaveLength(1);
    expect(top[0]).toBe('bullet_list(order=undefined)[li[p("Item 1"),FIGURE],li[p("Item 2")],li[p("Item 3")]]');
  });

  it('end of the LAST item nests inside it (corrected — does not escalate to after the whole list)', () => {
    const doc = threeItemList();
    const pos = findParaPos(doc, 'Item 3', 'Item 3'.length);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top } = insertAndDescribe(doc, insertPos);
    expect(top).toHaveLength(1);
    expect(top[0]).toBe('bullet_list(order=undefined)[li[p("Item 1")],li[p("Item 2")],li[p("Item 3"),FIGURE]]');
  });
});

describe('computeCursorAwareInsertPos — nested list inside a blockquote', () => {
  function nestedDoc(): ProsemirrorNode {
    return schema.nodes.doc.create(null, [
      schema.nodes.blockquote.create(null, [
        schema.nodes.bullet_list.create(null, [li('Quoted 1'), li('Quoted 2'), li('Quoted 3')]),
      ]),
    ]);
  }

  it('start of a non-first item splits only the inner list; the blockquote stays intact', () => {
    const doc = nestedDoc();
    const pos = findParaPos(doc, 'Quoted 2', 0);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top, emptyParagraphs, emptyListItems } = insertAndDescribe(doc, insertPos);

    expect(emptyParagraphs).toBe(0);
    expect(emptyListItems).toBe(0);
    expect(top).toHaveLength(1); // still a single top-level blockquote
    expect(top[0]).toBe(
      'blockquote[bullet_list(order=undefined)[li[p("Quoted 1")]],FIGURE,bullet_list(order=undefined)[li[p("Quoted 2")],li[p("Quoted 3")]]]'
    );
  });

  it('end of a non-last item nests inside that item; the blockquote and list stay intact', () => {
    const doc = nestedDoc();
    const pos = findParaPos(doc, 'Quoted 2', 'Quoted 2'.length);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top } = insertAndDescribe(doc, insertPos);

    expect(top).toHaveLength(1);
    expect(top[0]).toBe(
      'blockquote[bullet_list(order=undefined)[li[p("Quoted 1")],li[p("Quoted 2"),FIGURE],li[p("Quoted 3")]]]'
    );
  });
});

describe('computeCursorAwareInsertPos — blockquote (no list)', () => {
  function doc(): ProsemirrorNode {
    return schema.nodes.doc.create(null, [
      p('Before paragraph'),
      schema.nodes.blockquote.create(null, [p('Quoted sentence here')]),
    ]);
  }

  it('start of the blockquote paragraph places the image before the entire blockquote (flagship specimen)', () => {
    const d = doc();
    const pos = findParaPos(d, 'Quoted sentence here', 0);
    const insertPos = computeCursorAwareInsertPos(d, pos, figureType);
    const { top } = insertAndDescribe(d, insertPos);
    expect(top).toEqual(['p("Before paragraph")', 'FIGURE', 'blockquote[p("Quoted sentence here")]']);
  });

  it('end of the blockquote paragraph places the image after the entire blockquote', () => {
    const d = doc();
    const pos = findParaPos(d, 'Quoted sentence here', 'Quoted sentence here'.length);
    const insertPos = computeCursorAwareInsertPos(d, pos, figureType);
    const { top } = insertAndDescribe(d, insertPos);
    expect(top).toEqual(['p("Before paragraph")', 'blockquote[p("Quoted sentence here")]', 'FIGURE']);
  });

  it('mid-sentence inside the blockquote nests the image inside the same blockquote, splitting the text', () => {
    const d = doc();
    const pos = findParaPos(d, 'Quoted sentence here', 7); // after "Quoted "
    const insertPos = computeCursorAwareInsertPos(d, pos, figureType);
    const { top, emptyParagraphs } = insertAndDescribe(d, insertPos);
    expect(emptyParagraphs).toBe(0);
    expect(top).toEqual(['p("Before paragraph")', 'blockquote[p("Quoted "),FIGURE,p("sentence here")]']);
  });
});

describe('computeCursorAwareInsertPos — footnote_definition (schema-equivalent to blockquote)', () => {
  it('start of a non-first paragraph inside a footnote_definition inserts directly between the two paragraphs — same "block+" symmetric handling as blockquote, no split, no nesting trick', () => {
    // footnote_definition (preset-gfm) has content "block+", identical in shape
    // to blockquote — no distinguished first-child slot, so (unlike list_item)
    // it never needs the asymmetric-container nesting-at-end trick, and a bare
    // figure is already a schema-valid direct child at any position, so no
    // escalation past the whole container is needed here either.
    const doc = schema.nodes.doc.create(null, [
      schema.nodes.footnote_definition.create(null, [p('First paragraph'), p('Second paragraph')]),
    ]);
    const pos = findParaPos(doc, 'Second paragraph', 0);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top, emptyParagraphs } = insertAndDescribe(doc, insertPos);

    expect(emptyParagraphs).toBe(0);
    expect(top).toHaveLength(1); // single footnote_definition — NOT split into two
    expect(top[0]).toBe('footnote_definition[p("First paragraph"),FIGURE,p("Second paragraph")]');
  });
});

describe('computeCursorAwareInsertPos — mid-text inside a list item', () => {
  it('splits the item paragraph in two, both halves staying inside the same list item', () => {
    const doc = threeItemList();
    const pos = findParaPos(doc, 'Item 2', 2);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top, emptyParagraphs } = insertAndDescribe(doc, insertPos);
    expect(emptyParagraphs).toBe(0);
    expect(top).toHaveLength(1);
    expect(top[0]).toBe('bullet_list(order=undefined)[li[p("Item 1")],li[p("It"),FIGURE,p("em 2")],li[p("Item 3")]]');
  });
});

describe('computeCursorAwareInsertPos — empty-paragraph caret', () => {
  it('an empty bullet gets the figure appended into it, not a list split', () => {
    const doc = schema.nodes.doc.create(null, [
      schema.nodes.bullet_list.create(null, [li('Item 1'), li(''), li('Item 3')]),
    ]);
    const pos = findParaPos(doc, '', 0);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top } = insertAndDescribe(doc, insertPos);

    expect(top).toHaveLength(1); // NOT split into two lists
    expect(top[0]).toBe('bullet_list(order=undefined)[li[p("Item 1")],li[p(""),FIGURE],li[p("Item 3")]]');
  });
});

describe('computeCursorAwareInsertPos — ordered list (deliberate placement/numbering trade-off)', () => {
  it('splits exactly like a bullet list — image exactly at the clicked position — with a KNOWN, ACCEPTED numbering gap', () => {
    // Product decision (explicit, non-negotiable): ordered_list gets IDENTICAL
    // treatment to bullet_list — same content model ("listItem+"), same split
    // mechanism, no special-casing. Placement accuracy is not up for
    // compromise, even though the second half's displayed/exported numbering
    // will be wrong (restarts at 1) until a SEPARATE upstream bug is fixed:
    // @milkdown/preset-commonmark@7.18.0's ordered_list toDOM spreads a bare
    // number (`...node.attrs.order`) instead of `{ start: n }` — spreading a
    // JS number into an object contributes nothing, so `start` is never
    // rendered regardless of the `order` attr's value — and toMarkdown
    // hardcodes `start: 1` unconditionally. Both verified directly against
    // the installed package source. That bug is tracked as its own follow-up
    // task; it does NOT block this fix, and this test must NOT be "fixed" by
    // reintroducing a fallback guard for ordered_list — that was tried and
    // explicitly rejected: placement must match bullet_list exactly.
    const doc = schema.nodes.doc.create(null, [
      schema.nodes.ordered_list.create({ order: 1 }, [li('Item 1'), li('Item 2'), li('Item 3')]),
    ]);
    const pos = findParaPos(doc, 'Item 2', 0);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top, emptyParagraphs, emptyListItems } = insertAndDescribe(doc, insertPos);

    expect(emptyParagraphs).toBe(0);
    expect(emptyListItems).toBe(0);
    // The split happens, image lands exactly between the two halves — same
    // structural outcome as the bullet_list flagship case.
    expect(top).toEqual([
      'ordered_list(order=1)[li[p("Item 1")]]',
      'FIGURE',
      'ordered_list(order=1)[li[p("Item 2")],li[p("Item 3")]]',
    ]);
    // KNOWN, ACCEPTED GAP (not a bug in this fix — see comment above): the
    // second half's `order` is not renumbered, so it will visually/on-export
    // restart at 1 instead of continuing at 2 until the separate upstream
    // rendering bug is fixed. Asserted explicitly so nobody mistakes this for
    // already-correct behavior.
    expect(top[2]).toContain('order=1'); // would read "order=2" once the upstream bug is fixed
  });
});

describe('mapping a captured paste position through a preceding ghost-image deletion', () => {
  // Regression test for the "ghost image before pastePos" bug: insertImage()
  // (api-content.ts) first deletes WebKit-inserted blob:/data: ghost image
  // nodes via tr.delete(...), THEN resolves the captured pastePos against the
  // resulting tr.doc. If a ghost node existed BEFORE pastePos, the deletion
  // shifts everything after it, so the raw (pre-deletion) pastePos no longer
  // points at the same logical spot — it must be mapped via
  // `tr.mapping.map(pastePos)` first. This doesn't exercise insertImage()
  // itself (which needs a live editor instance to test), but it pins down —
  // against the exact `computeCursorAwareInsertPos` the fix calls into — that
  // mapping vs. not mapping produces different (and only the mapped one
  // correct) results.
  it('mapped pastePos lands the image at the same logical spot; the raw unmapped pastePos does not', () => {
    const doc = schema.nodes.doc.create(null, [
      figureType.create(), // stand-in for a WebKit-inserted blob:/data: ghost image node
      p('Some paragraph text'),
    ]);

    // Captured (pre-deletion) caret position: right after "Some " in the paragraph.
    const pastePos = findParaPos(doc, 'Some paragraph text', 'Some '.length);

    // Simulate insertImage()'s ghost-deletion transform: remove the leading ghost node.
    const tr = new Transform(doc);
    const ghost = doc.firstChild!;
    tr.delete(0, ghost.nodeSize);

    // Fixed behavior: map pastePos through the transform before resolving it.
    const mappedPastePos = tr.mapping.map(pastePos);
    const insertPosMapped = computeCursorAwareInsertPos(tr.doc, mappedPastePos, figureType);
    const { top: topMapped } = insertAndDescribe(tr.doc, insertPosMapped);
    expect(topMapped).toEqual(['p("Some ")', 'FIGURE', 'p("paragraph text")']);

    // Buggy behavior (what this fix prevents): resolving the RAW, unmapped
    // pastePos against the post-deletion tr.doc lands one character later,
    // splitting "Some p" / "aragraph text" instead — a silently wrong spot.
    const insertPosUnmapped = computeCursorAwareInsertPos(tr.doc, pastePos, figureType);
    const { top: topUnmapped } = insertAndDescribe(tr.doc, insertPosUnmapped);
    expect(insertPosUnmapped).not.toBe(insertPosMapped);
    expect(topUnmapped).toEqual(['p("Some p")', 'FIGURE', 'p("aragraph text")']);
  });
});

describe('computeCursorAwareInsertPos — table cells never split', () => {
  function tableDoc(): ProsemirrorNode {
    return schema.nodes.doc.create(null, [
      schema.nodes.table.create(null, [
        schema.nodes.table_row.create(null, [
          schema.nodes.table_cell.create(null, p('Cell A')),
          schema.nodes.table_cell.create(null, p('Cell B')),
        ]),
        schema.nodes.table_row.create(null, [
          schema.nodes.table_cell.create(null, p('Cell C')),
          schema.nodes.table_cell.create(null, p('Cell D')),
        ]),
      ]),
    ]);
  }

  it.each([
    ['start', 0],
    ['mid', 2],
    ['end', 'Cell A'.length],
  ])('%s of a cell places the image after the whole table, never splitting it', (_label, offset) => {
    const doc = tableDoc();
    const pos = findParaPos(doc, 'Cell A', offset as number);
    const insertPos = computeCursorAwareInsertPos(doc, pos, figureType);
    const { top } = insertAndDescribe(doc, insertPos);
    expect(top).toEqual(['table', 'FIGURE']);
  });
});

describe('computeCursorAwareInsertPos — depth-0 gap between top-level siblings (drop-position fix)', () => {
  // Regression test for the "image drag-and-drop lands at the bottom of the
  // document" bug (image-drag-drop-position plan, §1): the whitespace gap
  // BETWEEN two top-level blocks resolves at depth 0 — it is already an
  // unambiguous, valid top-level insertion point and must be used directly,
  // not discarded in favor of doc-end (the pre-fix `handleDrop` behavior).
  it('a raw position resolving at depth 0 is returned unchanged, not escalated to doc-end', () => {
    const doc = schema.nodes.doc.create(null, [p('First paragraph'), p('Second paragraph')]);
    const gapPos = doc.firstChild!.nodeSize; // gap immediately after the first paragraph's closing tag
    const $pos = doc.resolve(gapPos);
    expect($pos.depth).toBe(0); // sanity check: this really is the depth-0 case the fix targets

    const insertPos = computeCursorAwareInsertPos(doc, gapPos, figureType);
    expect(insertPos).toBe(gapPos);

    const { top } = insertAndDescribe(doc, insertPos);
    expect(top).toEqual(['p("First paragraph")', 'FIGURE', 'p("Second paragraph")']);
  });
});
