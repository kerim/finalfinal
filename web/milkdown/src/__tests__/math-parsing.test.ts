// @vitest-environment jsdom
// Math equation parsing / serialization tests
// Uses a real Milkdown editor instance to verify the actual serializer path,
// including the 'html' node type used to avoid $ → \$ escaping.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { clipboard } from '@milkdown/kit/plugin/clipboard';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { TextSelection } from '@milkdown/kit/prose/state';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { blockIdPlugin, phase1CanClaim, resetBlockIdState } from '../block-id-plugin';
import { blockSyncPlugin, nodeToMarkdownFragment, resetBlockSyncState } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import { normalizeMathFences } from '../math-paste-normalize';
import { mathPlugin } from '../math-plugin';

// ============================================================
// Real round-trip tests (live Milkdown editor in jsdom)
// These guard the 'html' node path that prevents $ → \$ escaping.
// ============================================================

describe('math round-trip via real Milkdown serializer', () => {
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
      .use(mathPlugin)
      .create();
    editor = e;
    return e;
  }

  it('inline $x^2$ round-trips unchanged', async () => {
    const e = await makeEditor('See $x^2$ for proof.');
    const result = e.action(getMarkdown());
    // The dollar signs must survive serialization intact
    expect(result).toContain('$x^2$');
    // Regression: must NOT be escaped to \$x^2\$
    expect(result).not.toContain('\\$x^2\\$');
    expect(result).not.toMatch(/\\\$[^$]*\\\$/);
  });

  it('display $$\\int_0^1 x\\,dx$$ round-trips unchanged', async () => {
    // remark-math parses display math only when $$ is on its own paragraph line
    const e = await makeEditor('$$\n\\int_0^1 x\\,dx\n$$');
    const result = e.action(getMarkdown());
    // Must preserve the $$ delimiters and the LaTeX body
    expect(result).toContain('$$');
    expect(result).toContain('\\int_0^1');
    // Regression: $$ must NOT become \$\$
    expect(result).not.toContain('\\$\\$');
  });

  it('inline dollar signs are NOT escaped to \\$ (proves html node path)', async () => {
    // This test would REGRESS if math_inline used a 'text' node type instead of 'html'.
    // A 'text' node triggers the standard markdown-it escaper, which turns $ into \$.
    // The 'html' node type is a raw passthrough — it cannot escape anything.
    const e = await makeEditor('$a + b = c$');
    const result = e.action(getMarkdown());
    // Must contain unescaped $, not \$
    expect(result).toMatch(/\$[^\\]/); // $ followed by a non-backslash char
    expect(result).not.toContain('\\$');
  });

  it('display dollar signs are NOT escaped to \\$\\$ (proves html node path)', async () => {
    // Same regression guard for math_display: if it used 'text', $$ → \$\$
    // Use block-level syntax (own line) so remark-math creates a math node
    const e = await makeEditor('$$\nE = mc^2\n$$');
    const result = e.action(getMarkdown());
    expect(result).toContain('$$');
    expect(result).not.toContain('\\$\\$');
  });
});

// ============================================================
// block-ID stability guard (structural assertion, pure-logic)
// ============================================================

describe('block-ID stability guard (structural assertion)', () => {
  it('math_display is included in BLOCK_TYPES and ATOMIC_BLOCK_TYPES', () => {
    // If math_display is NOT in these sets, block IDs will not be assigned
    // → silent data loss on next sync. Verified by importing phase1CanClaim
    // which uses ATOMIC_BLOCK_TYPES internally.

    // math_display should be atomic: a cross-type claim (e.g., paragraph→math_display)
    // must be rejected.
    const canClaim = phase1CanClaim(
      'math_display', // newType
      'paragraph', // existingType (different)
      'some-id', // existingId
      new Set(), // claimed (empty)
      false, // structureChanged (irrelevant on this path)
      'irrelevant-old-text', // oldText (placeholder, unread when structureChanged is false)
      'irrelevant-new-text' // newText (placeholder, unread when structureChanged is false)
    );
    // atomic types reject cross-type claims
    expect(canClaim).toBe(false);
  });

  it('same-type math_display claim is allowed', () => {
    const canClaim = phase1CanClaim(
      'math_display',
      'math_display',
      'some-id',
      new Set(),
      false,
      'irrelevant-old-text',
      'irrelevant-new-text'
    );
    expect(canClaim).toBe(true);
  });
});

// ============================================================
// Fix B: math_display no longer glues `$$` onto the first latex line.
// Covers both emission sites that matter for persistence/round-trip:
// math-plugin.ts's toMarkdown (Milkdown's own getMarkdown()) AND
// block-sync-plugin.ts's nodeToMarkdownFragment (the fragment handed to
// Swift's BlockParser — confirmed as the actual persisted shape).
// ============================================================

describe('Fix B: unglued $$ fence serialization', () => {
  async function makeEditorWithSchema(): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    return Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, '');
      })
      .use(blockIdPlugin)
      .use(blockSyncPlugin)
      .use(mathPlugin)
      .use(commonmark)
      .use(gfm)
      .use(highlightPlugin)
      .create();
  }

  it("math-plugin.ts's toMarkdown emits $$ on its own line, not glued to the first latex line", async () => {
    const editor = await makeEditorWithSchema();
    const view = editor.ctx.get(editorViewCtx);
    const schema = view.state.schema;
    const mathNode = schema.nodes.math_display!.create({ latex: 'x &= y \\\\\nz &= w' });
    view.dispatch(view.state.tr.replaceWith(0, view.state.doc.content.size, mathNode));

    const md = getMarkdown()(editor.ctx);
    // Must NOT glue $$ onto the first latex line (the shape remark-math
    // misreads as YAML-ish metadata and drops).
    expect(md).not.toContain('$$x &= y');
    // Each $$ fence must sit on its own line.
    expect(md).toContain('$$\nx &= y \\\\\nz &= w\n$$');

    await editor.destroy();
  });

  it("block-sync-plugin.ts's nodeToMarkdownFragment (the fragment Swift's BlockParser actually parses) also emits the unglued shape", async () => {
    const editor = await makeEditorWithSchema();
    const view = editor.ctx.get(editorViewCtx);
    const schema = view.state.schema;
    const mathNode = schema.nodes.math_display!.create({ latex: 'E = mc^2' });

    const fragment = nodeToMarkdownFragment(mathNode);
    expect(fragment).toBe('$$\nE = mc^2\n$$');
    expect(fragment).not.toMatch(/^\$\$E/);

    await editor.destroy();
  });

  it('empty latex (attrs default) round-trips through $$\\n\\n$$ via toMarkdown and parseMarkdown', async () => {
    const editor = await makeEditorWithSchema();
    const view = editor.ctx.get(editorViewCtx);
    const schema = view.state.schema;
    const mathNode = schema.nodes.math_display!.create(); // latex defaults to ''
    view.dispatch(view.state.tr.replaceWith(0, view.state.doc.content.size, mathNode));

    const md = getMarkdown()(editor.ctx);
    expect(md.trim()).toBe('$$\n\n$$');

    // Reparse in a fresh editor: the empty-latex math_display node must survive.
    const div2 = document.createElement('div');
    document.body.appendChild(div2);
    const editor2 = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div2);
        ctx.set(defaultValueCtx, md);
      })
      .use(commonmark)
      .use(gfm)
      .use(mathPlugin)
      .create();
    const doc2 = editor2.ctx.get(editorViewCtx).state.doc;
    let found = false;
    doc2.forEach((node: any) => {
      if (node.type.name === 'math_display') {
        found = true;
        expect(node.attrs.latex).toBe('');
      }
    });
    expect(found).toBe(true);

    await editor.destroy();
    await editor2.destroy();
  });

  it('a pre-fix glued-open multi-line document self-repairs via node.meta recovery on next parse', async () => {
    // The OLD serializer emitted `$$${latex}$$` verbatim. For multi-line
    // latex that glues the open $$ to the FIRST latex line and the close $$
    // to the LAST — remark-math reads that shape as YAML-ish front matter:
    // the first line becomes `node.meta` and the rest becomes `node.value`,
    // silently dropping the first line unless recovered. This pins that an
    // already-saved document in the broken shape recovers its FULL latex
    // (not just the tail) the next time it's parsed.
    const oldGluedShape = '$$E = mc^2\nx = y$$';

    const div = document.createElement('div');
    document.body.appendChild(div);
    const editor = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, oldGluedShape);
      })
      .use(commonmark)
      .use(gfm)
      .use(mathPlugin)
      .create();

    const doc = editor.ctx.get(editorViewCtx).state.doc;
    let latex = '';
    doc.forEach((node: any) => {
      if (node.type.name === 'math_display') latex = node.attrs.latex;
    });
    // Both lines recovered — the first line (former `meta`) is not dropped.
    expect(latex).toBe('E = mc^2\nx = y');

    await editor.destroy();
  });
});

// ============================================================
// Must-fix 1 (required fix round): normalizeMathFences's glued-open
// predicate must match micromark's own math-flow "meta" state exactly — it
// bails (nok) the instant it sees ANY further `$` character while scanning
// the rest of the opening line, so a line only opens a display-math fence
// when there is NO other `$` anywhere after the leading `$$`, not merely
// "doesn't end with $$". A prior version of this predicate treated any line
// starting with `$$` and NOT ending with `$$` as a glued opener, which
// false-positived on ordinary prose containing a second `$` — actively
// CREATING a genuinely unclosed fence on input micromark itself would have
// safely parsed as an ordinary paragraph.
// ============================================================

describe("normalizeMathFences: glued-open predicate matches micromark's own bail rule", () => {
  it('a line starting with $$ that has a legitimate embedded closing $$ followed by trailing prose is left untouched (was previously misclassified as a glued opener)', () => {
    const input = '$$E = mc^2$$ is the famous equation.';
    expect(normalizeMathFences(input)).toBe(input);
  });

  it('a line with two separate $-delimited runs ($$a + $b$ c) is left untouched, not misclassified as an opener', () => {
    const input = '$$a + $b$ c';
    expect(normalizeMathFences(input)).toBe(input);
  });

  it('the genuine glued-open case ($$\\begin{aligned} with no further $ on that line) still opens correctly under the corrected predicate', () => {
    const input = '$$\\begin{aligned}\nx &= y \\\\\nz &= w\n\\end{aligned}$$';
    const result = normalizeMathFences(input);
    // Opening $$ is split onto its own line -- this is the real repair the
    // fix exists for, and must survive the corrected predicate.
    expect(result).toContain('$$\n\\begin{aligned}');
    expect(result).not.toContain('$$\\begin{aligned}');
  });
});

// ============================================================
// Fix A gating test: does an external (never-app-emitted) paste of the bug
// report's exact malformed/unbalanced math still corrupt trailing content
// after Fix B ships? This determines whether the paste-boundary
// normalization in math-paste-normalize.ts is required — it is: without it,
// this test fails (verified manually while building the fix; the trailing
// paragraph's text ends up absorbed into the math node's latex attribute).
// ============================================================

describe('Fix A: external paste of malformed math (paste-boundary normalization)', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
  });

  async function makeFullEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    return Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(blockIdPlugin)
      .use(blockSyncPlugin)
      .use(mathPlugin)
      .use(commonmark)
      .use(gfm)
      .use(highlightPlugin)
      .use(clipboard)
      .create();
  }

  function fakeTextPasteEvent(text: string): ClipboardEvent {
    return {
      clipboardData: {
        getData: (type: string) => (type === 'text/plain' ? text : ''),
      },
      preventDefault: () => {},
    } as unknown as ClipboardEvent;
  }

  it('a malformed/unbalanced $$ block pasted from OUTSIDE the app does not swallow the trailing paragraph', async () => {
    const editor = await makeFullEditor('Intro paragraph.');
    const view = editor.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.setSelection(TextSelection.atEnd(view.state.doc)));

    // Exact repro from the bug report: unbalanced/glued $$ display math,
    // followed by a trailing paragraph — arriving as a plain-text paste, i.e.
    // never emitted by this app's own serializer. Goes through the REAL
    // handlePaste code path (@milkdown/plugin-clipboard's plain-text branch),
    // not the app's own serializer.
    const pasteText = '$$x &= y \\\\\nz &= w\n\\end{aligned}$$\n\nTrailing paragraph.';
    const handled = view.someProp('handlePaste', (f) => f(view, fakeTextPasteEvent(pasteText), undefined as any));
    expect(handled).toBe(true);

    const doc = view.state.doc;
    const topLevelTypes: string[] = [];
    doc.forEach((node: any) => {
      topLevelTypes.push(node.type.name);
    });

    // The trailing paragraph must survive as its OWN node, not get absorbed
    // into the math_display node's latex.
    expect(topLevelTypes).toEqual(['paragraph', 'math_display', 'paragraph']);

    let trailingText = '';
    let mathLatex = '';
    doc.forEach((node: any) => {
      if (node.type.name === 'math_display') mathLatex = node.attrs.latex;
      if (node.type.name === 'paragraph' && node.textContent === 'Trailing paragraph.') {
        trailingText = node.textContent;
      }
    });
    expect(trailingText).toBe('Trailing paragraph.');
    // The math node's latex must be bounded to the equation body — must NOT
    // contain the trailing paragraph's text (the swallow-to-EOF symptom).
    expect(mathLatex).not.toContain('Trailing paragraph');

    await editor.destroy();
  });

  // Must-fix 1 regression: the glued-open false positive must not corrupt
  // ordinary prose that merely starts with $$ and contains a second, later $.

  it('a line with a legitimate embedded closing $$ followed by trailing prose does not get corrupted into an unclosed math block', async () => {
    const editor = await makeFullEditor('Intro paragraph.');
    const view = editor.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.setSelection(TextSelection.atEnd(view.state.doc)));

    // Starts with $$, has a legitimate closing $$ partway through, then
    // trailing prose. Per micromark's math-flow "meta" state, ANY further $
    // on the opening line bails the fence attempt immediately -- this parses
    // as an ordinary paragraph with inline math, and must NOT be rewritten
    // into a genuinely unclosed fence that swallows to EOF.
    const pasteText = '$$E = mc^2$$ is the famous equation.';
    const handled = view.someProp('handlePaste', (f) => f(view, fakeTextPasteEvent(pasteText), undefined as any));
    expect(handled).toBe(true);

    const doc = view.state.doc;
    let mathDisplayCount = 0;
    doc.descendants((node: any) => {
      if (node.type.name === 'math_display') mathDisplayCount++;
    });
    // No math_display block was created -- the trailing prose was never
    // swallowed into a math node's latex attribute.
    expect(mathDisplayCount).toBe(0);
    expect(doc.textContent).toContain('Intro paragraph.');
    expect(doc.textContent).toContain('is the famous equation.');

    await editor.destroy();
  });

  it('a line with two separate $-delimited runs ($$a + $b$ c) does not get corrupted into an unclosed math block', async () => {
    const editor = await makeFullEditor('Intro paragraph.');
    const view = editor.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.setSelection(TextSelection.atEnd(view.state.doc)));

    const pasteText = '$$a + $b$ c';
    const handled = view.someProp('handlePaste', (f) => f(view, fakeTextPasteEvent(pasteText), undefined as any));
    expect(handled).toBe(true);

    const doc = view.state.doc;
    let mathDisplayCount = 0;
    doc.descendants((node: any) => {
      if (node.type.name === 'math_display') mathDisplayCount++;
    });
    expect(mathDisplayCount).toBe(0);
    expect(doc.textContent).toContain('Intro paragraph.');

    await editor.destroy();
  });
});
