// @vitest-environment jsdom
import { defaultValueCtx, Editor, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { Schema } from '@milkdown/kit/prose/model';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { highlightPlugin } from '../highlight-plugin';
import {
  codeSpanFor,
  escapeHref,
  escapeInlineText,
  escapeTitle,
  nodeToMarkdownFragment,
  padCodeSpan,
} from '../block-sync-plugin';

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
