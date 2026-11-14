// @vitest-environment jsdom
// Every block's per-block save text must equal that block's piece of the whole-document save, and read back as the same node
// (t-4eb7bfa9). Real Editor, registered like main.ts, so the next serializer gap fails here.
//
// "The whole-document save" is `getContent()`'s text: the stock Milkdown serializer plus `cleanupSerializedMarkdown`. The per-block
// save is `blockMarkdownFragment` (block-sync-plugin.ts), the text a Rich Text block change reports to Swift. When the two agree the
// close-time check (LifecycleWholeDocumentWrite+Check.swift) finds nothing to rebuild after typing.
//
// Deliberate exceptions, each pinned by its own test below:
//   - an EMPTY paragraph row holds '' wherever it sits (the stock serializer writes `<br />` for a non-last empty paragraph, a fact
//     that depends on the live view); so empty paragraphs are not part of the whole-document join test.
//   - Shift-Return inside a table cell is lost by BOTH saves (a known limit of the GFM table format); the test pins that both agree.
// Whole-document gaps that parity inherits and that this task does not fix (the read-back checks leave them out; parity still holds):
// typed text starting with `# ` or `[^n]:` (the clean-up unescapes those on purpose), typed `==x==` (the highlight parse), and two
// typed backticks (the clean-up's backtick unescape).
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defaultValueCtx, Editor, editorViewCtx, parserCtx, rootCtx, serializerCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm, remarkGFMPlugin } from '@milkdown/kit/preset/gfm';
import { Fragment, type Node } from '@milkdown/kit/prose/model';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { annotationPlugin } from '../annotation-plugin';
import { cleanupSerializedMarkdown, setContentWithBlockIds } from '../api-content';
import {
  blockIdPlugin,
  clearBlockIds,
  getAllBlockIds,
  replaceTopLevelIds,
  resetBlockIdState,
} from '../block-id-plugin';
import {
  blockMarkdownFragment,
  blockSerializerStats,
  blockSyncPlugin,
  computeChangeOps,
  flushPendingBlockChanges,
  getBlockChanges,
  resetBlockSyncState,
  snapshotBlocks,
} from '../block-sync-plugin';
import { citationPlugin } from '../citation-plugin';
import { setEditorInstance } from '../editor-state';
import { footnotePlugin } from '../footnote-plugin';
import { highlightPlugin } from '../highlight-plugin';
import { imageNodeRewritePlugin } from '../image-node-rewrite-plugin';
import { imagePlugin } from '../image-plugin';
import { mathPlugin } from '../math-plugin';
import { minimalEscapePlugin, relaxSafeEscapes } from '../minimal-escape-plugin';
import { orderedListOrderPlugin } from '../ordered-list-order-plugin';
import { sectionBreakPlugin } from '../section-break-plugin';

/** The editor as main.ts builds it, as far as it decides how a document is written to Markdown. `withMinimalEscape: false` is the
 * editor WITHOUT the shared escaping change, used to prove each editor serializes through its own context. */
async function makeEditor(md = 'x', withMinimalEscape = true): Promise<Editor> {
  const div = document.createElement('div');
  document.body.appendChild(div);
  const editor = Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, md);
    })
    .use(blockIdPlugin)
    .use(blockSyncPlugin)
    .use(sectionBreakPlugin)
    .use(annotationPlugin)
    .use(citationPlugin)
    .use(mathPlugin)
    .use(footnotePlugin)
    .use(imagePlugin)
    .use(commonmark)
    .use(gfm)
    .config((ctx) => {
      ctx.update(remarkGFMPlugin.options.key, () => ({ tablePipeAlign: false }));
    })
    .use(orderedListOrderPlugin)
    .use(imageNodeRewritePlugin)
    .use(highlightPlugin);
  if (withMinimalEscape) editor.use(minimalEscapePlugin);
  return editor.use(history).create();
}

/** One case: a name, the top-level node, and whether the whole-document save's text for it also parses back to the same node. */
interface Entry {
  name: string;
  node: Node;
  readBack: boolean;
}

// Markdown the user's document can hold, one top-level node each. Parsed one at a time (so two lists never merge into one loose
// list) and put in a fixed order with a different block between any two lists.
const PARSED: [name: string, md: string][] = [
  ['blockquote with two paragraphs', '> first\n>\n> second'],
  ['list item with two paragraphs', '* one\n\n  two\n\n* three'],
  ['heading with bold text', '# Heading **bold** *em*'],
  ['nested lists', '* a\n* b\n  1. c\n  2. d'],
  ['ordered list starting at 3', '3. x\n4. y'],
  ['inline atoms', 'text `code` [link](http://x.com/a_b) [@smith2020, p. 4] fn[^1] $x^2$ ==hi=='],
  ['heading containing #', '# Learning C\\# and F\\# and a \\#hash'],
  ['table', '| a | b |\n| - | - |\n| 1 | 2 |'],
  ['image', '![alt](media/pic.png)'],
  ['figure with width and caption', '![A caption](media/pic.png){alt="the alt text" width=50%}'],
  ['rule', '---'],
  ['code block', '```js\nconst a_b = 2 * 3;\n```'],
  ['footnote definition', '[^1]: The note'],
  ['section break', '<!-- ::break:: -->'],
  ['math display', '$$\nx^2 + y_1\n$$'],
  ['annotation', '<!-- ::task:: [ ] write the intro -->'],
  ['list item holding a code block', '* item\n\n  ```js\n  const a = 1;\n  ```\n\n* two'],
  ['list item holding a figure', '* ![alt](media/pic.png)\n\n* two'],
];

// Text the user TYPES (built as plain text nodes: parsing `__init__` would already make it bold).
const TYPED = [
  'snake_case_name',
  '__init__',
  '2 * 3 * 4',
  '*like this*',
  'a ~ = $ [ ] ` b',
  'costs $5 and $10',
  'a_b and _lead and trail_ and x * y',
  '1. not a list',
  '- not a list',
  '* star start',
  'a\\b backslash',
];

/** The top-level nodes of one parse (exactly one expected). */
function parseOne(editor: Editor, md: string): Node {
  const parsed = editor.ctx.get(parserCtx)(md);
  expect(parsed.childCount, `one top-level node for ${JSON.stringify(md)}`).toBe(1);
  return parsed.child(0);
}

function buildEntries(editor: Editor): Entry[] {
  const s = editor.ctx.get(editorViewCtx).state.schema;
  const para = (...content: (Node | string)[]) =>
    s.nodes.paragraph.create(null, content.map((c) => (typeof c === 'string' ? s.text(c) : c)).filter(Boolean));
  const separator = (n: number) => para(`separator ${n}`);
  const entries: Entry[] = [];
  const add = (name: string, node: Node, readBack = true) => entries.push({ name, node, readBack });

  PARSED.forEach(([name, md], i) => {
    add(name, parseOne(editor, md));
    add(`separator after ${name}`, separator(i));
  });
  TYPED.forEach((t) => {
    add(`typed ${t}`, para(t));
  });
  // A Markdown reader drops trailing whitespace at the end of a paragraph, so no read-back (both saves write it the same).
  add('trailing space', para('The cat '), false);
  add('text before a bold run', para('see ', s.text('bold', [s.marks.strong.create()])));
  add('typed line break', para('line one', s.nodes.hardbreak.create(), 'line two'));
  add('soft break', para('line one', s.nodes.hardbreak.create({ isInline: true }), 'line two'));
  // W6: a list-like line after a line break is a real list marker; the `*` there must stay escaped.
  add('hard break then star line', para('a', s.nodes.hardbreak.create(), ' * x'));
  add('soft break then star line', para('a', s.nodes.hardbreak.create({ isInline: true }), ' * x'));
  add('hard break then bare star line', para('a', s.nodes.hardbreak.create(), '* x'));
  add('hard break then star after text', para('a', s.nodes.hardbreak.create(), 'b * c'));
  add('inline code containing a backtick', para('a ', s.text('x`y', [s.marks.inlineCode.create()]), ' b'));

  // A table whose header cell holds a mark, a pipe and a line break. Shift-Return in a table cell is lost by both saves (a known
  // limit of the GFM table format); this pins that the two agree, so no read-back is asserted.
  const base = parseOne(editor, '| h1 | h2 |\n| - | - |\n| 1 | 2 |');
  const headerRow = base.child(0);
  const firstHeader = headerRow.child(0);
  const richCell = para('a ', s.text('b', [s.marks.strong.create()]), ' | c', s.nodes.hardbreak.create(), 'd');
  const newHeaderRow = headerRow.copy(
    Fragment.fromArray([firstHeader.copy(Fragment.from(richCell)), headerRow.child(1)])
  );
  add('table cell with a mark, a pipe and a line break', base.copy(base.content.replaceChild(0, newHeaderRow)), false);

  // A list as typing makes it (`- a`, Return, `b`): the schema's own defaults for the attributes, written tight.
  const item = (t: string) => s.nodes.list_item.create(null, [para(t)]);
  add('typed list', s.nodes.bullet_list.create(null, [item('a'), item('b')]));
  add('separator before two-paragraph item', separator(101));
  add(
    'typed two-paragraph list item',
    s.nodes.bullet_list.create(null, [s.nodes.list_item.create(null, [para('one'), para('two')])])
  );

  // Lists directly after lists: the one case whose whole-document text depends on the block before it.
  add('separator before typed list run', separator(102));
  add('typed list run: first', s.nodes.bullet_list.create(null, [item('a'), item('b')]));
  add('typed list run: second', s.nodes.bullet_list.create(null, [item('c'), item('d')]));
  add('separator before loaded list run', separator(103));
  add('list run: bullet list first', parseOne(editor, '* p\n* p2'));
  add('list run: bullet list second', parseOne(editor, '- q\n- q2'));
  add('list run: ordered list after bullet lists', parseOne(editor, '1. o'));
  add('separator before ordered run', separator(100));
  add('ordered run: first', parseOne(editor, '1. a\n2. b'));
  add('ordered run: second', parseOne(editor, '1. c\n2. d'));
  add('ordered run: third', parseOne(editor, '1. e'));
  return entries;
}

const isList = (n: Node) => n.type.name === 'bullet_list' || n.type.name === 'ordered_list';

/** A node's JSON without block ids, for comparing a node with the node its text reads back as. The `spread` attribute of lists and
 * list items is left out: Milkdown types it as a string ('false') on a parsed list and as a boolean on a list made by the schema's
 * own defaults, and the stock serializer reads only the boolean, so the whole-document save writes a list loaded from Markdown loose
 * (`* a`, blank line, `* b`) and a typed one tight, and a list reads back with the other value. That is the whole-document save's
 * own behaviour, which this test pins as the oracle; no other attribute is normalised. */
function comparableJson(node: Node): unknown {
  const LIST_TYPES = ['bullet_list', 'ordered_list', 'list_item'];
  const drop = (value: unknown, parentType?: string): unknown => {
    if (Array.isArray(value)) return value.map((v) => drop(v, parentType));
    if (value === null || typeof value !== 'object') return value;
    const record = value as Record<string, unknown>;
    const type = typeof record.type === 'string' ? record.type : parentType;
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(record)) {
      if (k === 'id' || k === 'blockId') continue;
      if (k === 'attrs' && v && typeof v === 'object' && LIST_TYPES.includes(type ?? '')) {
        const { spread: _spread, ...rest } = v as Record<string, unknown>;
        out[k] = rest;
        continue;
      }
      out[k] = drop(v, type);
    }
    return out;
  };
  return drop(node.toJSON());
}

/** The consecutive list nodes directly before child `i` (every top-level node counts: any other node ends a run). */
function runBefore(children: readonly Node[], i: number): Node[] {
  const run: Node[] = [];
  for (let j = i - 1; j >= 0 && isList(children[j]); j--) run.unshift(children[j]);
  return run;
}

/** The whole-document text, cut into one piece per top-level node by serializing every prefix of the document (an oracle that
 * shares nothing with `blockMarkdownFragment`'s own prefix handling). */
function wholeDocumentPieces(editor: Editor, children: readonly Node[]): { whole: string; pieces: string[] } {
  const ser = editor.ctx.get(serializerCtx);
  const top = editor.ctx.get(editorViewCtx).state.schema.topNodeType;
  const text = (nodes: readonly Node[]) => cleanupSerializedMarkdown(ser(top.create(null, nodes)), false);
  const pieces: string[] = [];
  let previous = '';
  for (let i = 0; i < children.length; i++) {
    const full = text(children.slice(0, i + 1));
    expect(full.startsWith(previous), `prefix ${i} is a prefix of prefix ${i + 1}`).toBe(true);
    pieces.push(full.slice(previous.length).replace(/^\n+/, '').replace(/\n+$/, ''));
    previous = full;
  }
  return { whole: text(children).replace(/\n+$/, ''), pieces };
}

afterEach(() => {
  resetBlockSyncState();
});

describe('per-block text equals the whole-document piece', () => {
  let editor: Editor;
  let entries: Entry[];
  let children: Node[];
  let pieces: string[];
  let whole: string;

  beforeAll(async () => {
    editor = await makeEditor();
    entries = buildEntries(editor);
    children = entries.map((e) => e.node);
    ({ whole, pieces } = wholeDocumentPieces(editor, children));
  });

  it('the cases are the real document children, in order', () => {
    const s = editor.ctx.get(editorViewCtx).state.schema;
    const doc = s.topNodeType.create(null, children);
    expect(doc.childCount).toBe(entries.length);
    entries.forEach((e, i) => {
      expect(doc.child(i), e.name).toBe(e.node);
    });
    // Two lists never meet by accident: the only adjacent lists are the ones built on purpose below.
    const adjacent = entries
      .filter((e, i) => i > 0 && isList(e.node) && isList(entries[i - 1].node))
      .map((e) => e.name);
    expect(adjacent).toEqual([
      'typed list run: second',
      'list run: bullet list second',
      'list run: ordered list after bullet lists',
      'ordered run: second',
      'ordered run: third',
    ]);
  });

  it('whole document = per-block pieces joined by a blank line', () => {
    const perBlock = children.map((n, i) => blockMarkdownFragment(n, runBefore(children, i)));
    expect(perBlock.join('\n\n')).toBe(whole);
    expect(pieces.join('\n\n')).toBe(whole);
  });

  it('each case: the per-block text is the whole-document piece, and (where the whole-document save allows it) reads back', () => {
    const parse = editor.ctx.get(parserCtx);
    entries.forEach((e, i) => {
      const piece = blockMarkdownFragment(e.node, runBefore(children, i));
      expect(piece, e.name).toBe(pieces[i]);
      if (!e.readBack) return;
      const back = parse(piece);
      expect(back.childCount, `${e.name}: one node back`).toBe(1);
      expect(comparableJson(back.child(0)), `${e.name}: reads back as the same node`).toEqual(comparableJson(e.node));
    });
  });

  // One named test per case, so a failure names the shape (and the reproducing tests have stable IDs).
  describe('cases', () => {
    const names = [
      ...PARSED.map(([n]) => n),
      ...TYPED.map((t) => `typed ${t}`),
      'trailing space',
      'text before a bold run',
      'typed line break',
      'soft break',
      'hard break then star line',
      'soft break then star line',
      'hard break then bare star line',
      'hard break then star after text',
      'inline code containing a backtick',
      'table cell with a mark, a pipe and a line break',
      'typed list',
      'typed two-paragraph list item',
      'typed list run: first',
      'typed list run: second',
      'list run: bullet list first',
      'list run: bullet list second',
      'list run: ordered list after bullet lists',
      'ordered run: first',
      'ordered run: second',
      'ordered run: third',
    ];
    it.each(names)('%s', (name) => {
      const i = entries.findIndex((e) => e.name === name);
      expect(i, `a case named ${name}`).toBeGreaterThanOrEqual(0);
      const piece = blockMarkdownFragment(children[i], runBefore(children, i));
      expect(piece).toBe(pieces[i]);
      if (entries[i].readBack) {
        const back = editor.ctx.get(parserCtx)(piece);
        expect(back.childCount).toBe(1);
        expect(comparableJson(back.child(0))).toEqual(comparableJson(entries[i].node));
      }
    });
  });

  it('the shapes the hand converter used to get wrong are written the way the whole-document save writes them', () => {
    const at = (name: string) => entries.findIndex((e) => e.name === name);
    expect(pieces[at('blockquote with two paragraphs')]).toBe('> first\n>\n> second');
    expect(pieces[at('typed line break')]).toBe('line one\\\nline two');
    expect(pieces[at('list item with two paragraphs')]).toBe('* one\n\n  two\n\n* three');
    expect(pieces[at('rule')]).toBe('***');
  });

  it('a list after a list takes the other bullet, and the per-block text knows it', () => {
    const at = (name: string) => entries.findIndex((e) => e.name === name);
    // Lists as typing makes them are written tight; lists loaded from Markdown are written loose (see `comparableJson`).
    const typedFirst = at('typed list run: first');
    const typedSecond = at('typed list run: second');
    expect(blockMarkdownFragment(children[typedFirst], runBefore(children, typedFirst))).toBe('* a\n* b');
    expect(blockMarkdownFragment(children[typedSecond], runBefore(children, typedSecond))).toBe('- c\n- d');
    // Without the run the second list would be written alone, with the first list's bullet: the case the run exists for.
    expect(blockMarkdownFragment(children[typedSecond])).toBe('* c\n* d');
    const first = at('list run: bullet list first');
    const second = at('list run: bullet list second');
    expect(blockMarkdownFragment(children[first], runBefore(children, first))).toBe('* p\n\n* p2');
    expect(blockMarkdownFragment(children[second], runBefore(children, second))).toBe('- q\n\n- q2');
    expect(blockMarkdownFragment(children[second])).toBe('* q\n\n* q2');
  });
});

describe('escaping: only where the text would otherwise read back as formatting', () => {
  it('writes ordinary underscores and stars bare, and keeps the escapes that matter', async () => {
    const editor = await makeEditor();
    const s = editor.ctx.get(editorViewCtx).state.schema;
    const frag = (...content: (Node | string)[]) =>
      blockMarkdownFragment(
        s.nodes.paragraph.create(
          null,
          content.map((c) => (typeof c === 'string' ? s.text(c) : c))
        )
      );
    expect(frag('snake_case_name')).toBe('snake_case_name');
    expect(frag('2 * 3 * 4')).toBe('2 * 3 * 4');
    // Bare, `__init__` would read back bold.
    expect(frag('__init__')).toBe('\\_\\_init\\_\\_');
    expect(frag('*like this*')).toBe('\\*like this\\*');
    expect(frag('line one')).toBe('line one');
    expect(frag('costs $5')).toBe('costs \\$5');
    expect(frag('a ~ b')).toBe('a \\~ b');
    expect(frag('a [ b')).toBe('a \\[ b');
    expect(frag('1. not a list')).toBe('1\\. not a list');
    expect(frag('- not a list')).toBe('\\- not a list');
    expect(frag('* star start')).toBe('\\* star start');
    // W1: the stock handling of a trailing space is kept (the handler wraps the stock one, it does not replace it).
    expect(frag('The cat ')).toBe('The cat ');
    expect(frag('see ', s.text('bold', [s.marks.strong.create()]))).toBe('see **bold**');
  });

  it('keeps the star escaped when it starts a line, also after a line break inside one paragraph (W6)', async () => {
    const editor = await makeEditor();
    const s = editor.ctx.get(editorViewCtx).state.schema;
    const hard = s.nodes.paragraph.create(null, [s.text('a'), s.nodes.hardbreak.create(), s.text(' * x')]);
    const soft = s.nodes.paragraph.create(null, [
      s.text('a'),
      s.nodes.hardbreak.create({ isInline: true }),
      s.text(' * x'),
    ]);
    // The stock serializer writes the space that starts the second line as `&#x20;`, and the star stays escaped: bare, ` * x` on a
    // line of its own would be a bullet list item.
    expect(blockMarkdownFragment(hard)).toBe('a\\\n&#x20;\\* x');
    expect(blockMarkdownFragment(soft)).toBe('a\n&#x20;\\* x');
    const star = (...content: (Node | string)[]) =>
      blockMarkdownFragment(
        s.nodes.paragraph.create(
          null,
          content.map((c) => (typeof c === 'string' ? s.text(c) : c))
        )
      );
    // A star at the start of the second line keeps its backslash; a star between spaces after text on that line is written bare.
    expect(star('a', s.nodes.hardbreak.create(), '* x')).toBe('a\\\n\\* x');
    expect(star('a', s.nodes.hardbreak.create(), 'b * c')).toBe('a\\\nb * c');
  });

  it('relaxSafeEscapes: the two rules and nothing else', () => {
    // 1. `\_` with a letter or digit directly on both sides.
    expect(relaxSafeEscapes('snake\\_case')).toBe('snake_case');
    expect(relaxSafeEscapes('v2\\_3')).toBe('v2_3');
    expect(relaxSafeEscapes('\\_lead')).toBe('\\_lead');
    expect(relaxSafeEscapes('trail\\_')).toBe('trail\\_');
    expect(relaxSafeEscapes('\\_\\_init\\_\\_')).toBe('\\_\\_init\\_\\_');
    // A star between letters is not exempt (`a*b*c` is emphasis).
    expect(relaxSafeEscapes('a\\*b')).toBe('a\\*b');
    // 2. `\*` or `\_` with a space on both sides, after text on the same line.
    expect(relaxSafeEscapes('2 \\* 3')).toBe('2 * 3');
    expect(relaxSafeEscapes('a \\_ b')).toBe('a _ b');
    expect(relaxSafeEscapes('\\* x')).toBe('\\* x');
    expect(relaxSafeEscapes(' \\* x')).toBe(' \\* x');
    expect(relaxSafeEscapes('x \\*')).toBe('x \\*');
    // Per line (W6): text on an earlier line does not count.
    expect(relaxSafeEscapes('a\n \\* x')).toBe('a\n \\* x');
    expect(relaxSafeEscapes('a\nb \\* x')).toBe('a\nb * x');
    // Every other escape stays, and an escaped backslash is not an escape of what follows.
    expect(relaxSafeEscapes('\\$5 \\~ \\[ 1\\. \\-')).toBe('\\$5 \\~ \\[ 1\\. \\-');
    expect(relaxSafeEscapes('a\\\\\\_b')).toBe('a\\\\\\_b');
    expect(relaxSafeEscapes('The cat&#x20;')).toBe('The cat&#x20;');
  });

  it('each editor serializes through its own context (an editor without the shared escaping keeps its backslashes)', async () => {
    const plain = await makeEditor('x', false);
    const relaxed = await makeEditor('x', true);
    const text = (e: Editor, t: string) => {
      const s = e.ctx.get(editorViewCtx).state.schema;
      return s.nodes.paragraph.create(null, s.text(t));
    };
    // Created in this order, so a single module-wide serializer (the last editor's) would write both bare.
    expect(blockMarkdownFragment(text(plain, 'snake_case_name'))).toBe('snake\\_case\\_name');
    expect(blockMarkdownFragment(text(relaxed, 'snake_case_name'))).toBe('snake_case_name');
  });

  it('main.ts registers the shared escaping change, so the real editor writes the same text as these editors', () => {
    const main = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'main.ts'), 'utf8');
    // (A boolean, not `toMatch`: a failing `toMatch` would print the whole of main.ts.)
    expect(/\.use\(highlightPlugin\)[^\n]*\n\s*\.use\(minimalEscapePlugin\)/.test(main)).toBe(true);
  });
});

describe('an empty paragraph row is empty wherever it sits (W3)', () => {
  it('writes nothing for an empty paragraph in the middle and at the end of a live document', async () => {
    const editor = await makeEditor();
    const view = editor.ctx.get(editorViewCtx);
    const s = view.state.schema;
    const text = (t: string) => s.nodes.paragraph.create(null, s.text(t));
    const doc = s.topNodeType.create(null, [
      text('before'),
      s.nodes.paragraph.create(),
      text('between'),
      s.nodes.paragraph.create(),
    ]);
    view.dispatch(view.state.tr.replaceWith(0, view.state.doc.content.size, doc.content));
    const live = view.state.doc;
    expect(live.childCount).toBe(4);
    const middle = live.child(1);
    const last = live.child(3);
    expect(last).toBe(live.lastChild);
    expect(blockMarkdownFragment(middle)).toBe('');
    expect(blockMarkdownFragment(last)).toBe('');
    // Why the special case: the stock serializer writes `<br />` for a non-last empty paragraph, a fact that depends on the live view.
    const ser = editor.ctx.get(serializerCtx);
    expect(ser(s.topNodeType.create(null, middle))).toContain('<br />');
  });
});

describe('the per-block text a real block change reports', () => {
  /** A live editor holding `nodes` as its document, with block ids assigned the way a restore assigns them. */
  async function liveWith(nodes: (editor: Editor) => Node[]): Promise<{ editor: Editor; doc: Node }> {
    const editor = await makeEditor();
    const view = editor.ctx.get(editorViewCtx);
    const s = view.state.schema;
    const children = nodes(editor);
    view.dispatch(view.state.tr.replaceWith(0, view.state.doc.content.size, children));
    clearBlockIds();
    replaceTopLevelIds(
      children.map((_, i) => `id-${i}`),
      view.state.doc
    );
    expect(s).toBe(view.state.schema);
    return { editor, doc: view.state.doc };
  }

  it('an inserted block carries the whole-document piece, a list after a list included', async () => {
    const { editor, doc } = await liveWith((e) => {
      const s = e.ctx.get(editorViewCtx).state.schema;
      return [
        parseOne(e, '> first\n>\n> second'),
        parseOne(e, '* a\n* b'),
        parseOne(e, '- c\n- d'),
        s.nodes.paragraph.create(null, s.text('snake_case_name')),
        parseOne(e, '1. x'),
        parseOne(e, '1. y'),
      ];
    });
    const kids: Node[] = [];
    doc.forEach((n) => {
      kids.push(n);
    });
    const { pieces } = wholeDocumentPieces(editor, kids);
    const snapshot = snapshotBlocks(doc);
    // Every block is new, so each one is an insert carrying its text.
    const ops = computeChangeOps(
      new Map(),
      new Map([...snapshot].map(([id, b]) => [`temp-${id}`, { ...b, id: `temp-${id}` }]))
    );
    const inserts = ops
      .filter((o) => o.kind === 'insert')
      .map((o) => (o as { insert: { markdownFragment: string } }).insert);
    expect(inserts.map((i) => i.markdownFragment)).toEqual(pieces);
  });

  it('a list whose preceding list run changes is reported again, even though its own node is the same object (W4)', async () => {
    const { doc } = await liveWith((e) => {
      const s = e.ctx.get(editorViewCtx).state.schema;
      return [parseOne(e, '* a\n* b'), s.nodes.paragraph.create(null, s.text('between')), parseOne(e, '* c\n* d')];
    });
    const before = snapshotBlocks(doc);
    // Delete the paragraph between the two lists: the second list is the same node, now directly after the first.
    const kids: Node[] = [];
    doc.forEach((n) => {
      kids.push(n);
    });
    const afterDoc = doc.type.create(null, [kids[0], kids[2]]);
    clearBlockIds();
    replaceTopLevelIds(['id-0', 'id-2'], afterDoc);
    const after = snapshotBlocks(afterDoc);
    expect(after.get('id-2')?.node).toBe(before.get('id-2')?.node);
    const ops = computeChangeOps(before, after);
    const update = ops.find((o) => o.kind === 'update' && o.id === 'id-2') as
      | { update: { markdownFragment: string } }
      | undefined;
    // Before: after a paragraph, the list takes the first bullet. After: directly after another list, it takes the other one.
    expect(before.get('id-2')?.listRunSignature).toBe('');
    expect(after.get('id-2')?.listRunSignature).toBe('bullet_list');
    // The list's own node is the same object (asserted above), so only the changed run can make it reported: this is the assertion
    // that fails if the same-reference fast path in `computeChangeOps` stops looking at `listRunSignature`.
    expect(update, 'the list whose preceding run changed is reported').toBeDefined();
    expect(update?.update.markdownFragment).toBe('- c\n\n- d');
  });
});

describe('adjacent lists keep one block id each through a push and typing (F1)', () => {
  // The Swift side sends ONE id per list node: a list row merges into the row before it only when the marker matches, so `* a` and
  // `- b` (and `1. a` and `1) b`) are two rows with two ids. This pushes such ids the way the app does (`setContentWithBlockIds`),
  // then types into each block and reads what the editor reports.
  const logs: string[] = [];
  // The push schedules its un-pause (and the new baseline snapshot) in an animation frame. The test runs those callbacks itself:
  // fake timers do not fake the frame a second time in one file, and nothing here needs a clock.
  const frames: FrameRequestCallback[] = [];

  beforeEach(() => {
    logs.length = 0;
    frames.length = 0;
    vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => frames.push(cb));
    (window as unknown as { webkit?: unknown }).webkit = {
      messageHandlers: {
        errorHandler: {
          postMessage: (m: { message: string }) => {
            logs.push(m.message);
          },
        },
      },
    };
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    delete (window as unknown as { webkit?: unknown }).webkit;
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
  });

  it.each([
    ['bullets `*` then `-`', '* a\n\n- b\n\nparagraph', ['bullet_list', 'bullet_list', 'paragraph'], ['* a!', '- b!']],
    [
      'ordered `1.` then `1)`',
      '1. a\n\n1) b\n\nparagraph',
      ['ordered_list', 'ordered_list', 'paragraph'],
      ['1. a!', '1) b!'],
    ],
  ])('%s: every node gets its own id, and each edit is reported under its own id', async (_name, markdown, types, fragments) => {
    const editor = await makeEditor();
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const ids = ['id-first', 'id-second', 'id-paragraph'];
    setContentWithBlockIds(markdown, ids);
    for (const frame of frames.splice(0)) frame(0);

    // Three top-level nodes, one id each, in order, and nothing in the log about a slot that did not line up.
    expect(Array.from({ length: view.state.doc.childCount }, (_, i) => view.state.doc.child(i).type.name)).toEqual(
      types
    );
    const idsInOrder = Array.from(getAllBlockIds())
      .sort((a, b) => a[0] - b[0])
      .map(([, id]) => id);
    expect(idsInOrder).toEqual(ids);
    expect(logs.some((l) => l.includes('API:setContentWithBlockIds'))).toBe(true); // the log is being captured
    expect(logs.filter((l) => /PARITY MISMATCH|ALIGNMENT MISMATCH/.test(l))).toEqual([]);

    /** Types `!` at the end of top-level block `index` and returns what the editor reports for it. */
    const typeInto = (index: number) => {
      let end = 0;
      view.state.doc.forEach((node, offset, i) => {
        if (i === index) end = offset + node.nodeSize - (node.type.name === 'paragraph' ? 1 : 3);
      });
      view.dispatch(view.state.tr.insertText('!', end));
      flushPendingBlockChanges();
      return getBlockChanges();
    };
    const reported = (changes: ReturnType<typeof getBlockChanges>) => {
      expect(changes.inserts).toEqual([]);
      expect(changes.deletes).toEqual([]);
      return changes.updates.map((u) => [u.id, u.markdownFragment]);
    };

    // The paragraph's edit carries the paragraph's own id, not a list's.
    expect(reported(typeInto(2))).toEqual([['id-paragraph', 'paragraph!']]);
    // The second list's edit carries its own id and the bullet (or ordered marker) it has after the first list.
    expect(reported(typeInto(1))).toEqual([['id-second', fragments[1]]]);
    // The first list keeps its id and its own marker.
    expect(reported(typeInto(0))).toEqual([['id-first', fragments[0]]]);
    expect(logs.filter((l) => /PARITY MISMATCH|ALIGNMENT MISMATCH/.test(l))).toEqual([]);
  });
});

describe('only a changed block is serialized (T1, W8)', () => {
  /** Markdown for `n` blocks of mixed kinds; `tag` makes the text differ between two documents. */
  function bigBlocks(n: number, tag: string): string[] {
    const out: string[] = [];
    for (let i = 0; i < n; i++) {
      switch (i % 5) {
        case 0:
          out.push(`## Section ${tag} ${i}`);
          break;
        case 1:
          out.push(`Paragraph ${tag} ${i} with **bold**, *italic*, a [link](http://x.com/${i}) and snake_case_${i}.`);
          break;
        case 2:
          out.push(`* item ${tag} ${i} one\n* item two\n* item three with \`code\``);
          break;
        case 3:
          out.push(`> quoted ${tag} ${i}\n>\n> second paragraph`);
          break;
        default:
          out.push(
            `Plain paragraph ${tag} ${i} that is somewhat longer so it is a realistic line of prose in a long book.`
          );
      }
    }
    return out;
  }

  async function setup(blockCount: number) {
    const editor = await makeEditor();
    const parse = editor.ctx.get(parserCtx);
    const ids = Array.from({ length: blockCount }, (_, i) => `blk-${i}`);
    const snapshotOf = (doc: Node) => {
      clearBlockIds();
      replaceTopLevelIds(ids, doc);
      return snapshotBlocks(doc);
    };
    return { parse, ids, snapshotOf };
  }

  it('a one-character edit in a 70-block document serializes the changed block once and no other block', async () => {
    const { parse, ids, snapshotOf } = await setup(70);
    const blocks = bigBlocks(70, 'a');
    // Two lists in a row (the case where a list's text depends on the list before it), and one edited paragraph.
    blocks[20] = '* run first\n* run first two';
    blocks[21] = '- run second\n- run second two';
    const edited = blocks.slice();
    expect(edited[31]).toContain('Paragraph');
    edited[31] = edited[31].replace('Paragraph', 'Paragrapx');

    const oldDoc = parse(blocks.join('\n\n'));
    expect(oldDoc.childCount).toBe(70);
    const oldSnapshot = snapshotOf(oldDoc);
    expect(Array.from(oldSnapshot.values()).filter((b) => b.blockType === 'bullet_list').length).toBeGreaterThanOrEqual(
      10
    );

    // Replaced by a new parse of the text with one character changed: every unchanged block is an EQUAL node in a NEW object, as
    // after a restore or a whole-document push. Only the structural comparison (`Node.eq`) may decide those are unchanged.
    const newDoc = parse(edited.join('\n\n'));
    const newSnapshot = snapshotOf(newDoc);
    blockSerializerStats.runs = 0;
    const ops = computeChangeOps(oldSnapshot, newSnapshot);
    expect(ops.map((o) => o.kind)).toEqual(['update']);
    const update = (ops[0] as { update: { id: string; markdownFragment: string } }).update;
    expect(update.id).toBe(ids[31]);
    expect(update.markdownFragment).toContain('Paragrapx');
    // One run of the stock serializer: the changed block's new text (its changed text already says it differs; no old text needed).
    expect(blockSerializerStats.runs).toBe(1);

    // The same edit as a live transaction makes it: unchanged blocks are the SAME node objects.
    const liveDoc = oldDoc.copy(oldDoc.content.replaceChild(31, newDoc.child(31)));
    const liveSnapshot = snapshotOf(liveDoc);
    blockSerializerStats.runs = 0;
    expect(computeChangeOps(oldSnapshot, liveSnapshot).map((o) => o.kind)).toEqual(['update']);
    expect(blockSerializerStats.runs).toBe(1);

    // Replaced by the same text in new objects (a restore of an unchanged book): nothing is reported and nothing is serialized.
    const sameSnapshot = snapshotOf(parse(blocks.join('\n\n')));
    blockSerializerStats.runs = 0;
    expect(computeChangeOps(oldSnapshot, sameSnapshot)).toEqual([]);
    expect(blockSerializerStats.runs).toBe(0);
  });

  it('a 2,000-block document replaced by a different one serializes each block once; replaced by an equal one, none', async () => {
    const { parse, snapshotOf } = await setup(2000);
    const oldDoc = parse(bigBlocks(2000, 'a').join('\n\n'));
    expect(oldDoc.childCount).toBe(2000);
    const oldSnapshot = snapshotOf(oldDoc);

    // Replaced by different text (a Restore Entire Project, a large paste): one serializer run per block.
    const differentSnapshot = snapshotOf(parse(bigBlocks(2000, 'b').join('\n\n')));
    blockSerializerStats.runs = 0;
    let t0 = performance.now();
    const differentOps = computeChangeOps(oldSnapshot, differentSnapshot);
    const differentMs = performance.now() - t0;
    expect(differentOps.filter((o) => o.kind === 'update').length).toBe(2000);
    expect(blockSerializerStats.runs).toBe(2000);

    // Replaced by the same text in new node objects: no block is serialized at all.
    const equalSnapshot = snapshotOf(parse(bigBlocks(2000, 'a').join('\n\n')));
    blockSerializerStats.runs = 0;
    t0 = performance.now();
    const equalOps = computeChangeOps(oldSnapshot, equalSnapshot);
    const equalMs = performance.now() - t0;
    expect(equalOps).toEqual([]);
    expect(blockSerializerStats.runs).toBe(0);

    // The timing is logged, not asserted: jsdom timing says little. The outcome counts above are the assertions.
    console.log(
      `[W8 timing] computeChangeOps over 2,000 blocks: different text ${differentMs.toFixed(1)} ms, equal text in new nodes ${equalMs.toFixed(1)} ms`
    );
  }, 60_000);
});
