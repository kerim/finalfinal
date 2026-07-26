// @vitest-environment jsdom
//
// Cross-language pin test for setBlockIdsForTopLevel's `expected` (3rd arg) alignment
// check. Every fixture below pairs a hand-built PM node (mirroring the essential shape
// the real schema produces — atom vs. content-bearing, same type names) with an
// `ExpectedBlockMeta.nonEmpty` value derived by READING the actual Swift extraction
// source (BlockParser.extractTextContent + MarkdownUtils.stripMarkdownSyntax) for the
// equivalent markdown fragment — not assumed or copied blindly. See those functions in
// final final/Services/BlockParser.swift and final final/Utils/MarkdownUtils.swift for
// the traced reasoning behind each nonEmpty value used here. The Swift-side pin test
// (BlockParserAlignmentTests.crossLanguagePin...) computes the SAME nonEmpty values from
// the real Swift code over the same markdown fragments, so a future drift in either
// side's extraction logic shows up as a failure on at least one side.
import { type Node, Schema } from '@milkdown/kit/prose/model';
import { beforeEach, describe, expect, it } from 'vitest';
import { getAllBlockIds, getBlockIdAtPos, resetBlockIdState, setBlockIdsForTopLevel } from '../block-id-plugin';
import type { ExpectedBlockMeta } from '../types';

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
    bullet_list: { group: 'block', content: 'list_item+', toDOM: () => ['ul', 0] },
    ordered_list: { group: 'block', content: 'list_item+', toDOM: () => ['ol', 0] },
    list_item: { content: 'paragraph block*', toDOM: () => ['li', 0] },
    blockquote: { group: 'block', content: 'paragraph+', toDOM: () => ['blockquote', 0] },
    code_block: { group: 'block', content: 'text*', marks: '', code: true, toDOM: () => ['pre', ['code', 0]] },
    hr: { group: 'block', toDOM: () => ['hr'] },
    section_break: { group: 'block', toDOM: () => ['div', { class: 'section-break' }] },
    table: { group: 'block', content: 'table_row+', toDOM: () => ['table', 0] },
    table_row: { content: 'table_cell+', toDOM: () => ['tr', 0] },
    table_cell: { content: 'inline*', toDOM: () => ['td', 0] },
    // Block atoms — mirror image-plugin.ts's figureNode / math-plugin.ts's mathDisplayNode:
    // both are `group: 'block', atom: true` with no content, payload entirely in attrs.
    figure: {
      group: 'block',
      atom: true,
      attrs: { src: { default: '' } },
      toDOM: () => ['div', { class: 'figure-stub' }],
    },
    math_display: {
      group: 'block',
      atom: true,
      attrs: { latex: { default: '' } },
      toDOM: () => ['div', { class: 'math-stub' }],
    },
    // Inline atoms — mirror citation-plugin.ts / footnote-plugin.ts exactly (group: 'inline',
    // inline: true, atom: true, no content, payload in attrs).
    citation: {
      group: 'inline',
      inline: true,
      atom: true,
      attrs: { citekeys: { default: '' } },
      toDOM: () => ['span', { class: 'citation-stub' }],
    },
    footnote_ref: {
      group: 'inline',
      inline: true,
      atom: true,
      attrs: { label: { default: '0' } },
      toDOM: () => ['sup', { class: 'footnote-ref-stub' }],
    },
    footnote_def: {
      group: 'inline',
      inline: true,
      atom: true,
      attrs: { label: { default: '0' } },
      toDOM: () => ['span', { class: 'footnote-def-stub' }],
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

function listItem(text: string): Node {
  return schema.nodes.list_item.create(null, [para(text)]);
}

function bulletList(...items: string[]): Node {
  return schema.nodes.bullet_list.create(
    null,
    items.map((t) => listItem(t))
  );
}

function orderedList(...items: string[]): Node {
  return schema.nodes.ordered_list.create(
    null,
    items.map((t) => listItem(t))
  );
}

function blockquote(text: string): Node {
  return schema.nodes.blockquote.create(null, [para(text)]);
}

function codeBlock(code: string): Node {
  return schema.nodes.code_block.create(null, code ? [schema.text(code)] : []);
}

function table(cellText: string): Node {
  const cell = schema.nodes.table_cell.create(null, cellText ? [schema.text(cellText)] : []);
  const row = schema.nodes.table_row.create(null, [cell]);
  return schema.nodes.table.create(null, [row]);
}

function figure(): Node {
  return schema.nodes.figure.create({ src: 'projectmedia://img.png' });
}

function mathDisplay(latex: string): Node {
  return schema.nodes.math_display.create({ latex });
}

function citation(citekeys: string): Node {
  return schema.nodes.citation.create({ citekeys });
}

function footnoteRef(label: string): Node {
  return schema.nodes.footnote_ref.create({ label });
}

function footnoteDef(label: string): Node {
  return schema.nodes.footnote_def.create({ label });
}

/** paragraph containing a lone inline atom (citation or footnote_ref) — no trailing text. */
function paraWithAtom(atom: Node): Node {
  return schema.nodes.paragraph.create(null, [atom]);
}

/** paragraph containing two inline atoms separated by a single whitespace text node —
 * the exact shape citation/footnote-ref pairs parse to (`[@a] [@b]`, `[^1] [^2]`). */
function paraWithTwoAtomsSeparatedBySpace(a: Node, b: Node): Node {
  return schema.nodes.paragraph.create(null, [a, schema.text(' '), b]);
}

describe('setBlockIdsForTopLevel — cross-language nonEmpty pin (every block type)', () => {
  beforeEach(() => {
    resetBlockIdState();
  });

  it('straightforward correct matches — zero mismatches for every ordinary block type', () => {
    // Each (node, expected) pair below models one real markdown fragment. See the
    // per-type reasoning in this file's header comment and the individual cases below.
    const cases: Array<{ node: Node; expected: ExpectedBlockMeta }> = [
      // "Plain paragraph text." → extractTextContent default branch, no stripping applies → nonEmpty.
      { node: para('Plain paragraph text.'), expected: { blockType: 'paragraph', nonEmpty: true } },
      // "# Heading Text" → heading-marker stripped, "Heading Text" remains → nonEmpty.
      { node: heading('Heading Text'), expected: { blockType: 'heading', nonEmpty: true } },
      // "- Item 1\n\n- Item 2" → alignmentPairs emits ONE id/meta for the merged run, using
      // the FIRST block's own nonEmpty ("Item 1" → nonEmpty true). PM merges both into one node.
      { node: bulletList('Item 1', 'Item 2'), expected: { blockType: 'bullet_list', nonEmpty: true } },
      // "1. Item" → list-marker stripped, "Item" remains → nonEmpty.
      { node: orderedList('Item'), expected: { blockType: 'ordered_list', nonEmpty: true } },
      // "> Quoted text" → '>' marker stripped per line, "Quoted text" remains → nonEmpty.
      { node: blockquote('Quoted text'), expected: { blockType: 'blockquote', nonEmpty: true } },
      // "```\ncode line\n```" → fence markers stripped, code content kept → nonEmpty.
      { node: codeBlock('code line'), expected: { blockType: 'code_block', nonEmpty: true } },
      // "---" → extractTextContent forces text="" for .horizontalRule → nonEmpty FALSE both sides.
      // Real schema node name is `hr`; `blockType` stays the Swift-side vocabulary word
      // `horizontal_rule` — pmTypeForBlockType('horizontal_rule') maps it to 'hr' for comparison.
      { node: schema.nodes.hr.create(), expected: { blockType: 'horizontal_rule', nonEmpty: false } },
      // "<!-- ::break:: -->" → extractTextContent forces text="" for .sectionBreak → nonEmpty FALSE both sides.
      { node: schema.nodes.section_break.create(), expected: { blockType: 'section_break', nonEmpty: false } },
      // "|1|2|" → default branch, no table-specific stripping → real cell text remains → nonEmpty.
      { node: table('Cell text'), expected: { blockType: 'table', nonEmpty: true } },
      // "![alt](img.png)" → stripMarkdownSyntax's image-removal regex strips the ENTIRE
      // fragment to "" → nonEmpty FALSE on the Swift side (irrespective of PM's own blank
      // atom textContent) — the ATOMIC_BLOCK_TYPES bypass means this never even reaches the
      // content check, but the true Swift value is still false, so this is a faithful pin.
      { node: figure(), expected: { blockType: 'image', nonEmpty: false } },
      // "$$x^2$$" → extractTextContent has NO case for .mathDisplay (falls to default) and
      // stripMarkdownSyntax has NO $$ handling (that's only in the separate, more aggressive
      // stripForWordCount) → the raw "$$x^2$$" survives → nonEmpty TRUE on the Swift side.
      // PM's math_display atom has blank textContent — this pair is only reconciled by the
      // ATOMIC_BLOCK_TYPES bypass (same mechanism as figure), exercised here with a REAL
      // (non-synthetic) Swift-derived nonEmpty value rather than a hand-picked one.
      { node: mathDisplay('x^2'), expected: { blockType: 'math_display', nonEmpty: true } },
    ];

    const doc = schema.nodes.doc.create(
      null,
      cases.map((c) => c.node)
    );
    const orderedIds = cases.map((_, i) => `id-${i}`);
    const expected = cases.map((c) => c.expected);

    setBlockIdsForTopLevel(orderedIds, doc, expected);

    const ids = getAllBlockIds();
    expect(ids.size).toBe(cases.length); // zero withheld — every id assigned

    let offset = 0;
    for (let i = 0; i < cases.length; i++) {
      expect(getBlockIdAtPos(offset)).toBe(orderedIds[i]);
      offset += cases[i].node.nodeSize;
    }
  });

  it('footnote_def with real text ("[^1]: real text") — nonEmpty true both sides, matches', () => {
    // Swift: "[^1]: real text" → footnote-def-prefix stripped → "real text" → nonEmpty true.
    // PM: paragraph > [footnote_def(atom), text(" real text")] → trimmed "real text" → nonEmpty true.
    const node = schema.nodes.paragraph.create(null, [footnoteDef('1'), schema.text(' real text')]);
    const doc = schema.nodes.doc.create(null, [node]);

    const expected: ExpectedBlockMeta[] = [{ blockType: 'paragraph', nonEmpty: true }];
    setBlockIdsForTopLevel(['def-id'], doc, expected);

    expect(getBlockIdAtPos(0)).toBe('def-id');
  });

  it('footnote_def blank ("[^2]: ") — nonEmpty false both sides, matches, no false positive', () => {
    // Swift: "[^2]:" → footnote-def-prefix regex consumes the whole thing → "" → nonEmpty false.
    // PM: paragraph > [footnote_def(atom), text(" ")] → trimmed "" → nonEmpty false.
    const node = schema.nodes.paragraph.create(null, [footnoteDef('2'), schema.text(' ')]);
    const doc = schema.nodes.doc.create(null, [node]);

    const expected: ExpectedBlockMeta[] = [{ blockType: 'paragraph', nonEmpty: false }];
    setBlockIdsForTopLevel(['def-id'], doc, expected);

    expect(getBlockIdAtPos(0)).toBe('def-id');
  });

  it('bare footnote_ref-only paragraph ("[^3]") — nonEmpty false both sides (Swift strips it), matches', () => {
    // Swift: "[^3]" → stripMarkdownSyntax's footnote-ref-removal regex strips it → "" → nonEmpty false.
    // PM: paragraph > [footnote_ref(atom)] → textContent "" → nonEmpty false.
    const doc = schema.nodes.doc.create(null, [paraWithAtom(footnoteRef('3'))]);

    const expected: ExpectedBlockMeta[] = [{ blockType: 'paragraph', nonEmpty: false }];
    setBlockIdsForTopLevel(['ref-id'], doc, expected);

    expect(getBlockIdAtPos(0)).toBe('ref-id');
  });

  it('citation-only paragraph ("[@smith2020]") — Swift nonEmpty true, PM blank → exemption fires, no mismatch, id assigned', () => {
    // Swift: stripMarkdownSyntax does NOT strip citations → "[@smith2020]" survives → nonEmpty true.
    // PM: paragraph > [citation(atom)] → textContent "" → blank, reconciled ONLY via
    // isBlankDueToExemptAtom (citation is in CONTENT_CHECK_ATOM_EXEMPTIONS).
    const doc = schema.nodes.doc.create(null, [paraWithAtom(citation('smith2020'))]);

    const expected: ExpectedBlockMeta[] = [{ blockType: 'paragraph', nonEmpty: true }];
    setBlockIdsForTopLevel(['cite-id'], doc, expected);

    expect(getBlockIdAtPos(0)).toBe('cite-id');
  });

  it('citation + real prose ("See prior work [@smith2020].") — both non-blank, matches normally, exemption not needed', () => {
    const node = schema.nodes.paragraph.create(null, [
      schema.text('See prior work '),
      citation('smith2020'),
      schema.text('.'),
    ]);
    const doc = schema.nodes.doc.create(null, [node]);

    const expected: ExpectedBlockMeta[] = [{ blockType: 'paragraph', nonEmpty: true }];
    setBlockIdsForTopLevel(['cite-id'], doc, expected);

    expect(getBlockIdAtPos(0)).toBe('cite-id');
  });

  it('two citations separated by whitespace ("[@smith2020] [@jones2021]") — regression case: no mismatch, id assigned', () => {
    // Swift: nonEmpty true (citations never stripped). PM: [citation, text(" "), citation] →
    // textContent " " → trimmed blank. This pins the any-match-not-all-match fix (the round-2
    // predicate required ALL children to be atoms, which the whitespace text child broke) —
    // NOT the descendants()-over-direct-children fix, since these citations are already direct
    // children of the paragraph; see the nested-atom test below for what actually requires
    // recursing into descendants.
    const doc = schema.nodes.doc.create(null, [
      paraWithTwoAtomsSeparatedBySpace(citation('smith2020'), citation('jones2021')),
    ]);

    const expected: ExpectedBlockMeta[] = [{ blockType: 'paragraph', nonEmpty: true }];
    setBlockIdsForTopLevel(['cite-id'], doc, expected);

    expect(getBlockIdAtPos(0)).toBe('cite-id');
  });

  it('citation nested inside a blockquote (not a direct child) — pins the descendants()-over-direct-children fix', () => {
    // The citation here is TWO levels down (blockquote > paragraph > citation), not a direct
    // child of the blockquote node being checked. A direct-children-only "any match" check
    // would see only a `paragraph` child (not an atom) and wrongly refuse the exemption,
    // false-positiving on this perfectly healthy, citation-only blockquote.
    const innerPara = schema.nodes.paragraph.create(null, [citation('smith2020')]);
    const blockquoteNode = schema.nodes.blockquote.create(null, [innerPara]);
    const doc = schema.nodes.doc.create(null, [blockquoteNode]);

    const expected: ExpectedBlockMeta[] = [{ blockType: 'blockquote', nonEmpty: true }];
    setBlockIdsForTopLevel(['quote-id'], doc, expected);

    expect(getBlockIdAtPos(0)).toBe('quote-id');
  });

  it('two footnote refs separated by whitespace ("[^1] [^2]") — no mismatch WITHOUT relying on the exemption', () => {
    // Swift: BOTH refs stripped by the whole-string regex replace → only the space between them
    // survives → nonEmpty false. PM: [footnote_ref, text(" "), footnote_ref] → textContent " " →
    // trimmed blank → nonEmpty false. Both sides independently agree blank — the content check
    // never fires (meta.nonEmpty is false), so isBlankDueToExemptAtom is never even consulted.
    const doc = schema.nodes.doc.create(null, [paraWithTwoAtomsSeparatedBySpace(footnoteRef('1'), footnoteRef('2'))]);

    const expected: ExpectedBlockMeta[] = [{ blockType: 'paragraph', nonEmpty: false }];
    setBlockIdsForTopLevel(['refs-id'], doc, expected);

    expect(getBlockIdAtPos(0)).toBe('refs-id');
  });

  it('regression guard: blank footnote_def with expected.nonEmpty=true IS flagged as a mismatch (id withheld)', () => {
    // Models "DB says this footnote definition has real text" against a doc where it's
    // genuinely blank — the exact historical corruption shape. The citation exemption must
    // NOT swallow this: footnote_def is deliberately excluded from CONTENT_CHECK_ATOM_EXEMPTIONS.
    const node = schema.nodes.paragraph.create(null, [footnoteDef('9'), schema.text(' ')]);
    const doc = schema.nodes.doc.create(null, [node]);

    const expected: ExpectedBlockMeta[] = [{ blockType: 'paragraph', nonEmpty: true }];
    setBlockIdsForTopLevel(['def-id'], doc, expected);

    expect(getBlockIdAtPos(0)).toBeUndefined(); // withheld, not aliased onto the blank node
  });
});
