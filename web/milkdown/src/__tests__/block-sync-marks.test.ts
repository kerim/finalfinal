// @vitest-environment jsdom
import { defaultValueCtx, Editor, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm, remarkGFMPlugin } from '@milkdown/kit/preset/gfm';
import { Schema } from '@milkdown/kit/prose/model';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import type { Align, ParsedTable } from '../../../shared/format-table';
import { formatTable } from '../../../shared/format-table';
import {
  codeSpanFor,
  escapeHref,
  escapeInlineText,
  escapeTitle,
  nodeToMarkdownFragment,
  padCodeSpan,
} from '../block-sync-plugin';
import { highlightPlugin } from '../highlight-plugin';

// ----------------------------------------------------------------------------
// Pure-helper tests (no ProseMirror schema needed)
// ----------------------------------------------------------------------------

describe('escapeHref', () => {
  it('percent-encodes parens, spaces, angle brackets, quotes, backslash', () => {
    expect(escapeHref('https://en.wikipedia.org/wiki/C_(programming_language)')).toBe(
      'https://en.wikipedia.org/wiki/C_%28programming_language%29'
    );
    expect(escapeHref('http://host/path with space')).toBe('http://host/path%20with%20space');
    expect(escapeHref('http://<angle>')).toBe('http://%3Cangle%3E');
    expect(escapeHref('http://q"uote')).toBe('http://q%22uote');
    expect(escapeHref('path\\back')).toBe('path%5Cback');
  });

  it('leaves ordinary URLs alone', () => {
    expect(escapeHref('https://example.com/path?a=b&c=d#frag')).toBe('https://example.com/path?a=b&c=d#frag');
  });
});

describe('escapeTitle', () => {
  it('escapes backslashes and double-quotes only', () => {
    expect(escapeTitle('a "quoted" title')).toBe('a \\"quoted\\" title');
    expect(escapeTitle('back\\slash')).toBe('back\\\\slash');
  });
});

describe('padCodeSpan', () => {
  it('pads leading/trailing backticks with a space', () => {
    expect(padCodeSpan('`x')).toBe(' `x');
    expect(padCodeSpan('x`')).toBe('x` ');
    expect(padCodeSpan('`x`')).toBe(' `x` ');
  });

  it('leaves ordinary code text alone', () => {
    expect(padCodeSpan('hello')).toBe('hello');
  });
});

describe('codeSpanFor', () => {
  it('no backticks — single-tick delimiter, no padding', () => {
    expect(codeSpanFor('x = 1')).toBe('`x = 1`');
  });

  it('single internal backtick — doubled delimiter', () => {
    expect(codeSpanFor('foo`bar')).toBe('``foo`bar``');
  });

  it('double internal backtick run — triple delimiter', () => {
    expect(codeSpanFor('a``b')).toBe('```a``b```');
  });

  it('leading backtick — doubled delimiter with symmetric space padding', () => {
    expect(codeSpanFor('`code')).toBe('`` `code ``');
  });

  it('trailing backtick — doubled delimiter with symmetric space padding', () => {
    expect(codeSpanFor('code`')).toBe('`` code` ``');
  });

  it('both-ends backtick — doubled delimiter with symmetric space padding', () => {
    expect(codeSpanFor('`x`')).toBe('`` `x` ``');
  });
});

describe('escapeInlineText', () => {
  it('escapes backslashes always', () => {
    expect(escapeInlineText('a \\ b', { insideLink: false, applyLeadingEscape: false })).toBe('a \\\\ b');
  });

  it('escapes brackets only inside a link', () => {
    expect(escapeInlineText('[a]', { insideLink: true, applyLeadingEscape: false })).toBe('\\[a\\]');
    expect(escapeInlineText('[a]', { insideLink: false, applyLeadingEscape: false })).toBe('[a]');
  });

  it('escapes leading # only when applyLeadingEscape is true', () => {
    expect(escapeInlineText('# hello', { insideLink: false, applyLeadingEscape: true })).toBe('\\# hello');
    expect(escapeInlineText('# hello', { insideLink: false, applyLeadingEscape: false })).toBe('# hello');
  });

  it('escapes leading footnote-def only when applyLeadingEscape is true', () => {
    expect(escapeInlineText('[^1]: a', { insideLink: false, applyLeadingEscape: true })).toBe('\\[^1]: a');
    expect(escapeInlineText('[^1]: a', { insideLink: false, applyLeadingEscape: false })).toBe('[^1]: a');
  });

  it('does not double-escape the backslash it just produced', () => {
    // \ escape runs first: "\\" stays as double-escape output. Leading-# re-escape
    // operates on the already-escaped text.
    expect(escapeInlineText('\\# hi', { insideLink: false, applyLeadingEscape: true })).toBe('\\\\# hi');
  });
});

// ----------------------------------------------------------------------------
// Integration tests — build a minimal ProseMirror schema resembling Milkdown's
// ----------------------------------------------------------------------------

// Minimal schema with all the inline marks `serializeInlineContent` recognizes
// plus paragraph/heading/blockquote/list blocks. Mark names match Milkdown's
// commonmark+gfm+highlight schemas: emphasis, strong, inlineCode, strike_through,
// link, highlight.
const testSchema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { group: 'block', content: 'inline*', toDOM: () => ['p', 0] },
    heading: {
      group: 'block',
      content: 'inline*',
      attrs: { level: { default: 1 } },
      toDOM: (node) => [`h${node.attrs.level}`, 0],
    },
    blockquote: { group: 'block', content: 'block+', toDOM: () => ['blockquote', 0] },
    bullet_list: { group: 'block', content: 'list_item+', toDOM: () => ['ul', 0] },
    ordered_list: { group: 'block', content: 'list_item+', toDOM: () => ['ol', 0] },
    list_item: { content: 'paragraph block*', toDOM: () => ['li', 0] },
    text: { group: 'inline' },
    table: {
      group: 'block',
      content: 'table_row+',
      toDOM: () => ['table', 0],
    },
    table_row: {
      content: '(table_header | table_cell)+',
      toDOM: () => ['tr', 0],
    },
    table_header: {
      content: 'block+',
      attrs: { align: { default: null } },
      toDOM: () => ['th', 0],
    },
    table_cell: {
      content: 'block+',
      attrs: { align: { default: null } },
      toDOM: () => ['td', 0],
    },
    hard_break: {
      group: 'inline',
      inline: true,
      isLeaf: true,
      toDOM: () => ['br'],
    },
    footnote_ref: {
      group: 'inline',
      inline: true,
      isLeaf: true,
      attrs: { label: { default: '' } },
      toDOM: (node: any) => ['span', {}, `[^${node.attrs.label}]`],
    },
    math_inline: {
      group: 'inline',
      inline: true,
      atom: true,
      attrs: { latex: { default: '' } },
      toDOM: (node: any) => ['span', { 'data-latex': node.attrs.latex }, `$${node.attrs.latex}$`],
    },
    image: {
      group: 'inline',
      inline: true,
      atom: true,
      attrs: { src: { default: '' }, alt: { default: '' }, title: { default: '' } },
      toDOM: (node: any) => ['img', { src: node.attrs.src, alt: node.attrs.alt }],
    },
  },
  marks: {
    link: {
      attrs: { href: { default: '' }, title: { default: '' } },
      toDOM: (mark) => ['a', { href: mark.attrs.href as string }, 0],
    },
    strong: { toDOM: () => ['strong', 0] },
    emphasis: { toDOM: () => ['em', 0] },
    inlineCode: { toDOM: () => ['code', 0] },
    strike_through: { toDOM: () => ['s', 0] },
    highlight: { toDOM: () => ['mark', 0] },
  },
});

// Helper to build a paragraph with child text nodes carrying marks.
function para(...children: Array<{ text: string; marks?: string[]; linkHref?: string; linkTitle?: string }>) {
  const texts = children.map((c) => {
    const marks = (c.marks ?? []).map((name) => {
      if (name === 'link') {
        return testSchema.marks.link!.create({ href: c.linkHref ?? '', title: c.linkTitle ?? '' });
      }
      const markType = testSchema.marks[name];
      if (!markType) throw new Error(`test setup: unknown mark name "${name}"`);
      return markType.create();
    });
    return testSchema.text(c.text, marks);
  });
  return testSchema.nodes.paragraph!.create({}, texts);
}

function heading(level: number, ...children: Parameters<typeof para>) {
  const p = para(...children);
  return testSchema.nodes.heading!.create({ level }, p.content);
}

function blockquote(...paragraphs: ReturnType<typeof para>[]) {
  return testSchema.nodes.blockquote!.create({}, paragraphs);
}

function bulletList(...items: Array<Parameters<typeof para>>) {
  const listItems = items.map((contents) => testSchema.nodes.list_item!.create({}, [para(...contents)]));
  return testSchema.nodes.bullet_list!.create({}, listItems);
}

/** Builds a paragraph with a plain (non-figure) inline `image` node mixed
 * into surrounding text — `para()` only accepts text/mark descriptors, with
 * no room for a non-text child, so this is a separate, direct construction
 * matching the file's existing direct-construction style (see `heading`/
 * `blockquote` above). */
function paraWithImage(before: string, attrs: { src: string; alt?: string; title?: string }, after: string) {
  // ProseMirror disallows empty TextNodes, so an empty before/after (the
  // bracket-escaping and title-only cases below have no surrounding text)
  // must be omitted from the child list entirely, not passed as ''.
  const children = [
    ...(before ? [testSchema.text(before)] : []),
    testSchema.nodes.image!.create(attrs),
    ...(after ? [testSchema.text(after)] : []),
  ];
  return testSchema.nodes.paragraph!.create({}, children);
}

// MARK: - Table builder helpers

function tableHeaderCell(align: Align | null, ...children: Parameters<typeof para>) {
  const paragraph = para(...children);
  return testSchema.nodes.table_header!.create({ align }, [paragraph]);
}

function tableDataCell(align: Align | null, ...children: Parameters<typeof para>) {
  if (children.length === 0) {
    // Empty cell: paragraph with no inline children (inline* allows zero children)
    const emptyPara = testSchema.nodes.paragraph!.create({});
    return testSchema.nodes.table_cell!.create({ align }, [emptyPara]);
  }
  const paragraph = para(...children);
  return testSchema.nodes.table_cell!.create({ align }, [paragraph]);
}

function tableRow(...cells: ReturnType<typeof tableHeaderCell | typeof tableDataCell>[]) {
  return testSchema.nodes.table_row!.create({}, cells);
}

function makeTable(headerCells: ReturnType<typeof tableHeaderCell>[], bodyRows: ReturnType<typeof tableDataCell>[][]) {
  const headerRow = tableRow(...headerCells);
  const dataRows = bodyRows.map((cells) => tableRow(...cells));
  return testSchema.nodes.table!.create({}, [headerRow, ...dataRows]);
}

describe('nodeToMarkdownFragment — single mark round-trips', () => {
  it('plain text', () => {
    expect(nodeToMarkdownFragment(para({ text: 'hello world' }))).toBe('hello world');
  });

  it('link', () => {
    expect(nodeToMarkdownFragment(para({ text: 'site', marks: ['link'], linkHref: 'https://x' }))).toBe(
      '[site](https://x)'
    );
  });

  it('link with title', () => {
    expect(
      nodeToMarkdownFragment(para({ text: 'site', marks: ['link'], linkHref: 'https://x', linkTitle: 'homepage' }))
    ).toBe('[site](https://x "homepage")');
  });

  it('link with parens in href is percent-encoded', () => {
    const output = nodeToMarkdownFragment(
      para({
        text: 'C',
        marks: ['link'],
        linkHref: 'https://en.wikipedia.org/wiki/C_(programming_language)',
      })
    );
    expect(output).toBe('[C](https://en.wikipedia.org/wiki/C_%28programming_language%29)');
  });

  it('link text with brackets is escaped', () => {
    const output = nodeToMarkdownFragment(para({ text: '[bracketed] text', marks: ['link'], linkHref: 'u' }));
    expect(output).toBe('[\\[bracketed\\] text](u)');
  });

  it('strong', () => {
    expect(nodeToMarkdownFragment(para({ text: 'bold', marks: ['strong'] }))).toBe('**bold**');
  });

  it('emphasis', () => {
    expect(nodeToMarkdownFragment(para({ text: 'italic', marks: ['emphasis'] }))).toBe('*italic*');
  });

  it('strike_through', () => {
    expect(nodeToMarkdownFragment(para({ text: 'gone', marks: ['strike_through'] }))).toBe('~~gone~~');
  });

  it('inlineCode', () => {
    expect(nodeToMarkdownFragment(para({ text: 'x = 1', marks: ['inlineCode'] }))).toBe('`x = 1`');
  });

  it('inlineCode with leading backtick uses doubled delimiter', () => {
    expect(nodeToMarkdownFragment(para({ text: '`code', marks: ['inlineCode'] }))).toBe('`` `code ``');
  });

  it('highlight', () => {
    expect(nodeToMarkdownFragment(para({ text: 'marked', marks: ['highlight'] }))).toBe('==marked==');
  });
});

describe('nodeToMarkdownFragment — mark combinations', () => {
  it('bold wrapping a link (outer bold, inner link)', () => {
    // "start " [strong], "link" [strong, link], " end" [strong]
    const node = para(
      { text: 'start ', marks: ['strong'] },
      { text: 'link', marks: ['strong', 'link'], linkHref: 'u' },
      { text: ' end', marks: ['strong'] }
    );
    expect(nodeToMarkdownFragment(node)).toBe('**start [link](u) end**');
  });

  it('link wrapping a bold (outer link, inner bold)', () => {
    // "bold link" [strong, link]
    const node = para({ text: 'bold link', marks: ['strong', 'link'], linkHref: 'u' });
    // Canonical order puts link outermost when opening fresh.
    expect(nodeToMarkdownFragment(node)).toBe('[**bold link**](u)');
  });

  it('emphasis inside strong', () => {
    const node = para(
      { text: 'a ', marks: ['strong'] },
      { text: 'b', marks: ['strong', 'emphasis'] },
      { text: ' c', marks: ['strong'] }
    );
    expect(nodeToMarkdownFragment(node)).toBe('**a *b* c**');
  });

  it('adjacent independent marks do not bleed', () => {
    const node = para({ text: 'bold', marks: ['strong'] }, { text: ' ' }, { text: 'code', marks: ['inlineCode'] });
    expect(nodeToMarkdownFragment(node)).toBe('**bold** `code`');
  });

  it('code inside bold: close bold, emit code, reopen bold', () => {
    const node = para(
      { text: 'b ', marks: ['strong'] },
      { text: 'c', marks: ['strong', 'inlineCode'] },
      { text: ' b', marks: ['strong'] }
    );
    expect(nodeToMarkdownFragment(node)).toBe('**b **`c`** b**');
  });

  it('mark-only edit produces a different fragment (regression guard)', () => {
    const plain = para({ text: 'hello' });
    const bold = para({ text: 'hello', marks: ['strong'] });
    expect(nodeToMarkdownFragment(plain)).not.toBe(nodeToMarkdownFragment(bold));
  });
});

describe('nodeToMarkdownFragment — per-block-type', () => {
  it('heading with link', () => {
    const node = heading(1, { text: 'See ' }, { text: 'docs', marks: ['link'], linkHref: './README.md' });
    expect(nodeToMarkdownFragment(node)).toBe('# See [docs](./README.md)');
  });

  it('heading does not apply leading-# escape (the # is syntax, not text)', () => {
    // A heading whose text *contains* a literal # is allowed; but our guard only
    // applies the leading-# escape for paragraphs, not headings. So the text
    // "hello" inside an h1 becomes "# hello" with no extra escape.
    const node = heading(2, { text: 'section' });
    expect(nodeToMarkdownFragment(node)).toBe('## section');
  });

  it('blockquote with link (recursive path)', () => {
    const node = blockquote(para({ text: 'Visit ' }, { text: 'site', marks: ['link'], linkHref: 'x' }));
    expect(nodeToMarkdownFragment(node)).toBe('> Visit [site](x)');
  });

  it('bullet list item with link', () => {
    const node = bulletList([{ text: 'See ' }, { text: 'here', marks: ['link'], linkHref: 'u' }]);
    expect(nodeToMarkdownFragment(node)).toBe('- See [here](u)');
  });
});

// ----------------------------------------------------------------------------
// Nested sub-list serialization — regression guard for NESTED_BLOCK_ATOM_TYPES
// omitting bullet_list/ordered_list. Before the fix, a list_item's second
// child being itself a nested list took the plain container-recursion
// fallback (same path exercised by the plain-image-nesting case above) and
// lost its markers entirely, since only the top-level `case 'bullet_list'`/
// `case 'ordered_list'` in `nodeToMarkdownFragment` know how to generate
// them. These assert the exact marker/indentation output string, not just
// substring containment.
// ----------------------------------------------------------------------------
describe('nodeToMarkdownFragment — nested list as a list_item second child', () => {
  it('bullet list item containing a nested ordered list as its second child', () => {
    const nestedOrdered = testSchema.nodes.ordered_list!.create({}, [
      testSchema.nodes.list_item!.create({}, [para({ text: 'Nested 1' })]),
      testSchema.nodes.list_item!.create({}, [para({ text: 'Nested 2' })]),
    ]);
    const outerItem = testSchema.nodes.list_item!.create({}, [para({ text: 'Outer' }), nestedOrdered]);
    const node = testSchema.nodes.bullet_list!.create({}, [outerItem]);
    expect(nodeToMarkdownFragment(node)).toBe('- Outer\n  1. Nested 1\n  2. Nested 2');
  });

  it('ordered list item containing a nested bullet list as its second child', () => {
    const nestedBullet = testSchema.nodes.bullet_list!.create({}, [
      testSchema.nodes.list_item!.create({}, [para({ text: 'Nested A' })]),
      testSchema.nodes.list_item!.create({}, [para({ text: 'Nested B' })]),
    ]);
    const outerItem = testSchema.nodes.list_item!.create({}, [para({ text: 'Outer' }), nestedBullet]);
    const node = testSchema.nodes.ordered_list!.create({}, [outerItem]);
    expect(nodeToMarkdownFragment(node)).toBe('1. Outer\n   - Nested A\n   - Nested B');
  });
});

// ----------------------------------------------------------------------------
// image (plain inline node) persistence serializer — guards the BLOCKING
// data-loss finding from plan review: a plain (non-figure) `image` node has
// no explicit case in serializeInlineContent()'s dispatch chain before the
// async-image-corruption fix, so it fell through to the generic fallback
// (`child.textContent`, which returns '' for any leaf atom — see the
// footnote_def comment in block-sync-plugin.ts), silently dropping the
// image's `![alt](media/...)` reference from the block's persisted
// markdownFragment. These assertions prove the persisted fragment is the
// CANONICAL, un-rewritten `media/...` value by construction — this
// hand-rolled testSchema's `toDOM` is never touched by any display rewrite
// (that mechanism only exists in the real Milkdown schema from
// image-node-rewrite-plugin.ts, absent here) — exactly what the BLOCKING
// finding requires coverage for.
// ----------------------------------------------------------------------------
describe('nodeToMarkdownFragment — image (plain inline node)', () => {
  it('plain paragraph: a mid-text image retains its canonical media/... url', () => {
    const node = paraWithImage('before ', { src: 'media/x.png', alt: 'a' }, ' after');
    expect(nodeToMarkdownFragment(node)).toBe('before ![a](media/x.png) after');
  });

  it('list item: the same, nested — survives the list-item recursion path', () => {
    const node = testSchema.nodes.bullet_list!.create({}, [
      testSchema.nodes.list_item!.create({}, [paraWithImage('before ', { src: 'media/x.png', alt: 'a' }, ' after')]),
    ]);
    expect(nodeToMarkdownFragment(node)).toBe('- before ![a](media/x.png) after');
  });

  it('alt text containing [ ] is escaped (mirrors link text bracket-escaping)', () => {
    const node = paraWithImage('', { src: 'media/x.png', alt: '[bracketed]' }, '');
    expect(nodeToMarkdownFragment(node)).toBe('![\\[bracketed\\]](media/x.png)');
  });

  it('a title attribute is preserved in the emitted markdown when present', () => {
    const node = paraWithImage('', { src: 'media/x.png', alt: 'a', title: 'a title' }, '');
    expect(nodeToMarkdownFragment(node)).toBe('![a](media/x.png "a title")');
  });

  it('no title attribute produces no trailing quoted-title segment', () => {
    const node = paraWithImage('', { src: 'media/x.png', alt: 'a' }, '');
    expect(nodeToMarkdownFragment(node)).toBe('![a](media/x.png)');
  });
});

describe('nodeToMarkdownFragment — code span round-trip fixes', () => {
  it('[strong]+[inlineCode]+[] asymmetric shape — no stray delimiters', () => {
    const node = para({ text: 'hello', marks: ['strong'] }, { text: 'code', marks: ['inlineCode'] }, { text: 'world' });
    expect(nodeToMarkdownFragment(node)).toBe('**hello**`code`world');
  });

  it('inline code with internal backtick uses doubled delimiter', () => {
    const node = para({ text: 'foo`bar', marks: ['inlineCode'] });
    expect(nodeToMarkdownFragment(node)).toBe('``foo`bar``');
  });

  it('inline code with trailing backtick uses doubled delimiter', () => {
    const node = para({ text: 'code`', marks: ['inlineCode'] });
    expect(nodeToMarkdownFragment(node)).toBe('`` code` ``');
  });
});

describe('nodeToMarkdownFragment — structural escapes', () => {
  it('paragraph starting with literal # gets \\# escape', () => {
    expect(nodeToMarkdownFragment(para({ text: '# not a heading' }))).toBe('\\# not a heading');
  });

  it('paragraph starting with literal [^1]: gets \\[ escape', () => {
    expect(nodeToMarkdownFragment(para({ text: '[^1]: not a footnote' }))).toBe('\\[^1]: not a footnote');
  });

  it('leading # in a heading body is NOT escaped', () => {
    // The heading's outer "# " is syntax; if the body also starts with "# "
    // that's a user's literal text — but the leading-escape guard is paragraph-only,
    // so it stays as-is. (Not common in practice.)
    const node = heading(1, { text: '# child' });
    expect(nodeToMarkdownFragment(node)).toBe('# # child');
  });
});

// ----------------------------------------------------------------------------
// Stock Milkdown serializer — highlight preservation
// Integration tests that mount a real Milkdown editor (jsdom) and verify that
// editor.action(getMarkdown()) no longer throws and correctly round-trips
// ==highlight== delimiters.
// ----------------------------------------------------------------------------

describe('stock Milkdown serializer — highlight preservation', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
  });

  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(commonmark)
      .use(gfm)
      .use(highlightPlugin)
      .create();
    editor = e;
    return e;
  }

  it('==marked== round-trips through parse → serialize', async () => {
    const e = await makeEditor('==marked==');
    const result = e.action(getMarkdown());
    expect(result).toContain('==marked==');
  });

  it('**bold ==marked== bold** preserves highlight delimiters (mark-priority agnostic)', async () => {
    const e = await makeEditor('**bold ==marked== bold**');
    const result = e.action(getMarkdown());
    expect(result).toContain('==marked==');
  });

  it('==a== ==b== round-trips both highlights without merging', async () => {
    const e = await makeEditor('==a== ==b==');
    const result = e.action(getMarkdown());
    expect(result).toContain('==a==');
    expect(result).toContain('==b==');
  });
});

// ----------------------------------------------------------------------------
// Fix 2a: stock Milkdown serializer produces compact table output
// Verifies that tablePipeAlign: false propagates through the remarkGFMPlugin
// options slice so getMarkdown() emits compact (unpadded) table source.
// ----------------------------------------------------------------------------

describe('stock Milkdown serializer — compact table output (Fix 2a)', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
  });

  async function makeEditorCompact(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .config((ctx) => {
        ctx.update(remarkGFMPlugin.options.key, () => ({ tablePipeAlign: false }));
      })
      .use(commonmark)
      .use(gfm)
      .use(highlightPlugin)
      .create();
    editor = e;
    return e;
  }

  it('table with varied-length cells serializes without column padding', async () => {
    const shortCell = 'x';
    const longCell = 'a'.repeat(80);
    const markdown = `| Short | Long |\n| --- | --- |\n| ${shortCell} | ${longCell} |`;
    const e = await makeEditorCompact(markdown);
    const result = e.action(getMarkdown());
    // With tablePipeAlign: false, the short cell must not be padded to 80 chars.
    // lines[0]=header, lines[1]=separator, lines[2]=body row
    const tableLines = result.split('\n').filter((l) => l.includes('|'));
    expect(tableLines.length).toBeGreaterThanOrEqual(3);
    const bodyLine = tableLines[2];
    const cols = bodyLine
      .split('|')
      .map((s) => s.trim())
      .filter(Boolean);
    // Short cell must be exactly 'x', not padded to the width of 'a'.repeat(80)
    expect(cols[0]).toBe(shortCell);
  });
});

// ----------------------------------------------------------------------------
// Table serializer — Layer 1 regression guard
// Pure ProseMirror schema manipulation + nodeToMarkdownFragment(), no WebView.
// ----------------------------------------------------------------------------

describe('nodeToMarkdownFragment — table serializer', () => {
  // Case 1: Bold in a cell
  it('bold in a cell', () => {
    const table = makeTable(
      [tableHeaderCell(null, { text: 'A' })],
      [[tableDataCell(null, { text: 'bold', marks: ['strong'] })]]
    );
    const output = nodeToMarkdownFragment(table);
    expect(output).toContain('**bold**');
  });

  // Case 2: Italic in a cell
  it('italic in a cell', () => {
    const table = makeTable(
      [tableHeaderCell(null, { text: 'A' })],
      [[tableDataCell(null, { text: 'italic', marks: ['emphasis'] })]]
    );
    const output = nodeToMarkdownFragment(table);
    expect(output).toContain('*italic*');
  });

  // Case 3: Inline code in a cell
  it('inline code in a cell', () => {
    const table = makeTable(
      [tableHeaderCell(null, { text: 'A' })],
      [[tableDataCell(null, { text: 'x = 1', marks: ['inlineCode'] })]]
    );
    const output = nodeToMarkdownFragment(table);
    expect(output).toContain('`x = 1`');
  });

  // Case 4: Link in a cell
  it('link in a cell', () => {
    const table = makeTable(
      [tableHeaderCell(null, { text: 'A' })],
      [[tableDataCell(null, { text: 'site', marks: ['link'], linkHref: 'https://x' })]]
    );
    const output = nodeToMarkdownFragment(table);
    expect(output).toContain('[site](https://x)');
  });

  // Case 5: Highlight in a cell
  it('highlight in a cell', () => {
    const table = makeTable(
      [tableHeaderCell(null, { text: 'A' })],
      [[tableDataCell(null, { text: 'marked', marks: ['highlight'] })]]
    );
    const output = nodeToMarkdownFragment(table);
    expect(output).toContain('==marked==');
  });

  // Case 6: Footnote ref in a cell
  it('footnote ref in a cell', () => {
    const fnRef = testSchema.nodes.footnote_ref!.create({ label: '1' });
    const cell = testSchema.nodes.table_cell!.create({ align: null }, [
      testSchema.nodes.paragraph!.create({}, [fnRef]),
    ]);
    const row = tableRow(tableHeaderCell(null, { text: 'H' }));
    const bodyRow = testSchema.nodes.table_row!.create({}, [cell]);
    const table = testSchema.nodes.table!.create({}, [row, bodyRow]);
    const output = nodeToMarkdownFragment(table);
    expect(output).toContain('[^1]');
  });

  // Case 7: Pipe in plain text is escaped (but not double-escaped)
  it('pipe in plain cell text is escaped once', () => {
    const table = makeTable([tableHeaderCell(null, { text: 'H' })], [[tableDataCell(null, { text: 'a|b' })]]);
    const output = nodeToMarkdownFragment(table);
    expect(output).toContain('a\\|b');
    expect(output).not.toContain('a\\\\|b');
  });

  // Case 8: Pipe inside inline code is NOT escaped
  it('pipe inside inline code is not escaped', () => {
    const table = makeTable(
      [tableHeaderCell(null, { text: 'H' })],
      [[tableDataCell(null, { text: 'a|b', marks: ['inlineCode'] })]]
    );
    const output = nodeToMarkdownFragment(table);
    expect(output).toContain('`a|b`');
    expect(output).not.toContain('`a\\|b`');
  });

  // Case 9: hard_break becomes <br> in cell output
  it('hard_break in a cell becomes <br>', () => {
    const hardBreak = testSchema.nodes.hard_break!.create();
    const cell = testSchema.nodes.table_cell!.create({ align: null }, [
      testSchema.nodes.paragraph!.create({}, [testSchema.text('line1'), hardBreak, testSchema.text('line2')]),
    ]);
    const headerRow = tableRow(tableHeaderCell(null, { text: 'H' }));
    const bodyRow = testSchema.nodes.table_row!.create({}, [cell]);
    const table = testSchema.nodes.table!.create({}, [headerRow, bodyRow]);
    const output = nodeToMarkdownFragment(table);
    expect(output).toContain('<br>');
    expect(output).toContain('line1<br>line2');
  });

  // Case 10: Header row preserved — output has exactly 3 lines (header, separator, data)
  it('header row is preserved and output has header/separator/data lines', () => {
    const table = makeTable([tableHeaderCell(null, { text: 'Name' })], [[tableDataCell(null, { text: 'Alice' })]]);
    const output = nodeToMarkdownFragment(table);
    const lines = output.split('\n');
    expect(lines).toHaveLength(3);
    // Separator line contains at least one dash (compact format: single-dash forms)
    expect(lines[1]).toMatch(/-/);
  });

  // Case 11: Per-column alignment preserved in separator row
  it('per-column alignment is reflected in the separator row', () => {
    const table = makeTable(
      [
        tableHeaderCell('left', { text: 'L' }),
        tableHeaderCell('center', { text: 'C' }),
        tableHeaderCell('right', { text: 'R' }),
        tableHeaderCell(null, { text: 'N' }),
      ],
      [
        [
          tableDataCell(null, { text: 'a' }),
          tableDataCell(null, { text: 'b' }),
          tableDataCell(null, { text: 'c' }),
          tableDataCell(null, { text: 'd' }),
        ],
      ]
    );
    const output = nodeToMarkdownFragment(table);
    const lines = output.split('\n');
    const sep = lines[1];
    // Split on | and trim; filter out leading/trailing empty strings
    const cols = sep
      .split('|')
      .map((s) => s.trim())
      .filter(Boolean);
    expect(cols[0]).toMatch(/^:-+$/); // left: colon prefix only
    expect(cols[1]).toMatch(/^:-+:$/); // center: colon on both ends
    expect(cols[2]).toMatch(/^-+:$/); // right: colon suffix only
    expect(cols[3]).toMatch(/^-+$/); // null: just dashes
  });

  // Case 12: Empty cell is not collapsed to ||
  it('empty cell does not produce ||', () => {
    const table = makeTable([tableHeaderCell(null, { text: 'H' })], [[tableDataCell(null)]]);
    const output = nodeToMarkdownFragment(table);
    const lines = output.split('\n');
    const bodyLine = lines[2];
    // The body row must not collapse cell content to || — spaces around the cell content
    expect(bodyLine).toMatch(/\|[\s]*\|/);
    expect(bodyLine).not.toContain('||');
  });

  // Case 13a: math_inline in a cell
  it('math_inline in a cell', () => {
    const mathNode = testSchema.nodes.math_inline!.create({ latex: 'a_n' });
    const cell = testSchema.nodes.table_cell!.create({ align: null }, [
      testSchema.nodes.paragraph!.create({}, [mathNode]),
    ]);
    const headerRow = tableRow(tableHeaderCell(null, { text: 'H' }));
    const bodyRow = testSchema.nodes.table_row!.create({}, [cell]);
    const table = testSchema.nodes.table!.create({}, [headerRow, bodyRow]);
    const output = nodeToMarkdownFragment(table);
    expect(output).toContain('$a_n$');
  });

  // Case 13: Compact format is idempotent (parse → format → parse → format produces same output)
  it('compact format is idempotent (accumulation guard)', () => {
    // Simple GFM table row parser for the test
    function parseFormattedTable(md: string): ParsedTable {
      const lines = md.split('\n');
      const splitRow = (line: string) =>
        line
          .split('|')
          .slice(1, -1)
          .map((s) => s.trim());
      const headerCells = splitRow(lines[0]);
      const sepCells = splitRow(lines[1]);
      const separator: Align[] = sepCells.map((s): Align => {
        if (s.startsWith(':') && s.endsWith(':')) return 'center';
        if (s.startsWith(':')) return 'left';
        if (s.endsWith(':')) return 'right';
        return null;
      });
      const rows = lines.slice(2).filter(Boolean).map(splitRow);
      return { header: headerCells, separator, rows };
    }

    const table: ParsedTable = {
      header: ['Name', 'Score', 'Notes'],
      separator: [null, 'right', 'center'],
      rows: [
        ['Alice', '100', 'excellent'],
        ['Bob', '50', 'ok'],
      ],
    };
    const m1 = formatTable(table);
    const table2 = parseFormattedTable(m1);
    const m2 = formatTable(table2);
    expect(m2).toBe(m1);
  });
});

// ----------------------------------------------------------------------------
// math_inline serialization — persistence path (serializeInlineContent)
// These tests guard Bug A: math_inline was silently dropped (child.textContent
// returns '' for atom nodes) before the explicit branch was added.
// ----------------------------------------------------------------------------

describe('nodeToMarkdownFragment — math_inline persistence serializer', () => {
  // Test 1: pure math paragraph is NOT empty — emits $...$ delimiters
  it('paragraph containing only math_inline emits $...$', () => {
    const mathNode = testSchema.nodes.math_inline!.create({ latex: '(a_n, d)' });
    const node = testSchema.nodes.paragraph!.create({}, [mathNode]);
    const result = nodeToMarkdownFragment(node);
    expect(result).toBe('$(a_n, d)$');
  });

  // Test 2: pure math paragraph is NOT treated as empty (persistence guard)
  it('pure math_inline paragraph is non-empty — not dropped', () => {
    const mathNode = testSchema.nodes.math_inline!.create({ latex: '(a_n, d)' });
    const node = testSchema.nodes.paragraph!.create({}, [mathNode]);
    const result = nodeToMarkdownFragment(node);
    expect(result.length).toBeGreaterThan(0);
    expect(result).not.toBe('');
  });

  // Test 3: text + math_inline + text preserves all three parts in order
  it('paragraph mixing text + math_inline + text preserves all content', () => {
    const mathNode = testSchema.nodes.math_inline!.create({ latex: 'a_n' });
    const node = testSchema.nodes.paragraph!.create({}, [
      testSchema.text('where '),
      mathNode,
      testSchema.text(' is the start'),
    ]);
    const result = nodeToMarkdownFragment(node);
    expect(result).toBe('where $a_n$ is the start');
  });
});
