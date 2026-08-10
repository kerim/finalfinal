// @vitest-environment jsdom
//
// Investigation trail for a confirmed-in-production bug: a real document's
// stored markdown showed a single pasted Wikipedia-disambiguation URL split
// into two ADJACENT link marks —
//   <https://en.wikipedia.org/wiki/Example_(disambiguation>[)](https://en.wikipedia.org/wiki/Example_\(disambiguation\))
// — an autolink covering the URL minus its final ")" (with a truncated,
// broken href) immediately followed by a one-character link whose text is
// just ")" but whose href is the full, correctly-escaped URL.
//
// This suite drives the REAL Milkdown paste pipeline (the actual
// @milkdown/plugin-clipboard handlePaste, the actual autolinkPlugin, and the
// same plugin registration this app's main.ts uses for every link-adjacent
// plugin) with real ClipboardEvent-shaped paste data, across every
// realistic paste-content shape that could plausibly produce this split:
// plain-text-only paste (at a paragraph boundary and mid-sentence), an
// HTML clipboard payload wrapping the URL in a single <a>, pasting directly
// over an existing (already-linked) selection, a URL wrapped in an outer
// citation-style "(...)", and a URL immediately followed by a
// sentence-ending period. Every one of these produces a single, correctly
// bounded link mark — none reproduces the split. Calling Milkdown's
// `parserCtx` directly (the markdown-to-ProseMirror step the clipboard
// plugin's plain-text path uses before its DOM round-trip) also produces a
// single correct mark, ruling out remark-gfm's autolink-literal extension.
//
// What this DID establish with certainty: which serializer produced the
// exact corrupted string found in the user's database. `getContent()`
// (window.FinalFinal.getContent(), the function Swift's save path
// evaluates — see MilkdownCoordinator+Content.swift's "SAVE+NOTIFY" path
// and BlockSyncService.swift) calls Milkdown's own `getMarkdown()`
// (prosemirror-markdown-style serializer), NOT block-sync-plugin.ts's
// custom `nodeToMarkdownFragment` (which never emits `<url>` autolink
// syntax and percent-encodes parens instead of backslash-escaping them —
// its output for the same split-mark shape looks nothing like the observed
// bug). The "hand-construct the split doc" test below proves `getMarkdown()`
// reproduces the observed string byte-for-byte from a document that
// already contains two adjacent link marks shaped this way — so the
// mechanism that put the ProseMirror document into that state remains
// unidentified, but the serializer that exposes it in persisted content is
// now pinned down precisely, and this file also locks in (as passing
// regression tests) that every realistic paste shape currently produces the
// correct, unsplit result.
import { defaultValueCtx, Editor, editorViewCtx, parserCtx, rootCtx } from '@milkdown/kit/core';
import { clipboard } from '@milkdown/kit/plugin/clipboard';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm, remarkGFMPlugin } from '@milkdown/kit/preset/gfm';
import { TextSelection } from '@milkdown/kit/prose/state';
import { getMarkdown } from '@milkdown/kit/utils';
import { describe, expect, it } from 'vitest';
import { autolinkPlugin } from '../autolink-plugin';
import { blockIdPlugin } from '../block-id-plugin';
import { blockSyncPlugin, nodeToMarkdownFragment } from '../block-sync-plugin';
import { highlightPlugin } from '../highlight-plugin';
import { imageNodeRewritePlugin } from '../image-node-rewrite-plugin';
import { linkCursorPlugin } from '../link-cursor';
import { markdownLinkPlugin } from '../markdown-link-input-rule';
import { orderedListOrderPlugin } from '../ordered-list-order-plugin';
import { smartQuotesPlugin } from '../smart-quotes-plugin';
import { tablePastePlugin } from '../table-paste-plugin';

const URL_ = 'https://en.wikipedia.org/wiki/Example_(disambiguation)';

// Matches main.ts's real registration for every plugin that touches link
// marks or serialization, so this harness exercises the same paste pipeline
// production does — not a hand-rolled minimal schema.
async function makeEditor(markdown: string): Promise<Editor> {
  const div = document.createElement('div');
  document.body.appendChild(div);
  return Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, markdown);
    })
    .use(blockIdPlugin)
    .use(blockSyncPlugin)
    .use(commonmark)
    .use(gfm)
    .config((ctx) => {
      ctx.update(remarkGFMPlugin.options.key, () => ({ tablePipeAlign: false }));
    })
    .use(orderedListOrderPlugin)
    .use(imageNodeRewritePlugin)
    .use(autolinkPlugin)
    .use(markdownLinkPlugin)
    .use(smartQuotesPlugin)
    .use(highlightPlugin)
    .use(history)
    .use(tablePastePlugin)
    .use(clipboard)
    .use(linkCursorPlugin)
    .create();
}

function fakePaste(text: string, html?: string): ClipboardEvent {
  return {
    clipboardData: {
      getData: (type: string) => {
        if (type === 'text/plain') return text;
        if (type === 'text/html') return html ?? '';
        return '';
      },
    },
    preventDefault: () => {},
  } as unknown as ClipboardEvent;
}

/** Returns the single link-marked text run in the doc's first paragraph, or null if none/more than one. */
function soleLinkRun(doc: any): { text: string; href: string } | null {
  const runs: { text: string; href: string }[] = [];
  doc.firstChild?.forEach((child: any) => {
    const mark = child.marks?.find((m: any) => m.type.name === 'link');
    if (mark) runs.push({ text: child.text, href: mark.attrs.href });
  });
  return runs.length === 1 ? runs[0] : null;
}

function dispatchPasteAt(view: any, pos: number, text: string, html?: string): boolean {
  view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos))));
  return view.someProp('handlePaste', (f: any) => f(view, fakePaste(text, html), undefined));
}

/**
 * Simulate the user typing one character (or the triggering space) at the current cursor,
 * exactly the way the real EditorView does it: go through `handleTextInput` first (the real
 * autolinkPlugin's InputRule lives there, and -- per prosemirror-inputrules' own `run()` --
 * dispatches its own transaction internally when a rule matches and its handler returns
 * non-null). If no rule handled it, fall back to a plain `insertText` transaction, matching
 * what the browser's native contenteditable insertion would otherwise do.
 *
 * Calling `view.someProp('handleTextInput', ...)` and discarding the boolean result (as this
 * file used to) is a trap: when the rule declines, nothing is dispatched, the typed character
 * never lands, and an assertion right after silently checks the pre-keystroke document instead
 * of the post-keystroke one. See guard-removed-extend-repro.test.ts, where this helper was
 * introduced to fix exactly that.
 */
function typeText(view: any, text: string): void {
  const pos = view.state.selection.from;
  const handled = view.someProp('handleTextInput', (f: any) => f(view, pos, pos, text)) ?? false;
  if (!handled) {
    view.dispatch(view.state.tr.insertText(text, pos));
  }
}

describe('paste of a URL with a legitimately-part-of-the-URL trailing paren stays one link (regression suite for a confirmed split-into-two-marks bug)', () => {
  it('plain-text-only paste at a paragraph boundary', async () => {
    const editor = await makeEditor('Before sentence. ');
    const view = editor.ctx.get(editorViewCtx);
    const endPos = view.state.doc.content.size - 1;

    expect(dispatchPasteAt(view, endPos, URL_)).toBe(true);
    expect(soleLinkRun(view.state.doc)).toEqual({ text: URL_, href: URL_ });
    expect(getMarkdown()(editor.ctx)).toBe(`Before sentence.<${URL_}>\n`);
  });

  it('plain-text-only paste mid-sentence, surrounded by existing text on both sides', async () => {
    const editor = await makeEditor('processus dynamicus.  Est usus legentis.');
    const view = editor.ctx.get(editorViewCtx);
    const text = view.state.doc.textBetween(0, view.state.doc.content.size);
    const pos = 1 + text.indexOf('.  Est') + 2;

    expect(dispatchPasteAt(view, pos, URL_)).toBe(true);
    expect(soleLinkRun(view.state.doc)).toEqual({ text: URL_, href: URL_ });
    expect(getMarkdown()(editor.ctx)).toBe(`processus dynamicus. <${URL_}> Est usus legentis.\n`);
  });

  it('HTML-clipboard paste wrapping the URL in a single <a> (simulating copy from a rendered link)', async () => {
    const editor = await makeEditor('Before sentence. ');
    const view = editor.ctx.get(editorViewCtx);
    const endPos = view.state.doc.content.size - 1;
    const html = `<a href="${URL_}">${URL_}</a>`;

    expect(dispatchPasteAt(view, endPos, URL_, html)).toBe(true);
    expect(soleLinkRun(view.state.doc)).toEqual({ text: URL_, href: URL_ });
  });

  it('paste replaces a selection that IS the old (already-linked) URL text — select-and-paste-over', async () => {
    const escapedUrl = URL_.replace(/\(/g, '\\(').replace(/\)/g, '\\)');
    const editor = await makeEditor(`processus dynamicus. [${URL_}](${escapedUrl}) Est usus legentis.`);
    const view = editor.ctx.get(editorViewCtx);

    let from = -1;
    let to = -1;
    view.state.doc.descendants((node: any, pos: number) => {
      if (node.isText && node.text === URL_) {
        from = pos;
        to = pos + node.nodeSize;
      }
      return true;
    });
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from, to)));
    const handled = view.someProp('handlePaste', (f: any) => f(view, fakePaste(URL_), undefined));

    expect(handled).toBe(true);
    expect(soleLinkRun(view.state.doc)).toEqual({ text: URL_, href: URL_ });
  });

  it('URL wrapped in an outer citation-style "(...)" pastes with the outer parens excluded from the link', async () => {
    const editor = await makeEditor('processus dynamicus.  Est usus legentis.');
    const view = editor.ctx.get(editorViewCtx);
    const text = view.state.doc.textBetween(0, view.state.doc.content.size);
    const pos = 1 + text.indexOf('.  Est') + 2;

    expect(dispatchPasteAt(view, pos, `(${URL_})`)).toBe(true);
    expect(soleLinkRun(view.state.doc)).toEqual({ text: URL_, href: URL_ });
    expect(getMarkdown()(editor.ctx)).toBe(`processus dynamicus. (<${URL_}>) Est usus legentis.\n`);
  });

  it('URL immediately followed by a sentence-ending period pastes with the period excluded', async () => {
    const editor = await makeEditor('processus dynamicus.  Est usus legentis.');
    const view = editor.ctx.get(editorViewCtx);
    const text = view.state.doc.textBetween(0, view.state.doc.content.size);
    const pos = 1 + text.indexOf('.  Est') + 2;

    expect(dispatchPasteAt(view, pos, `${URL_}.`)).toBe(true);
    expect(soleLinkRun(view.state.doc)).toEqual({ text: URL_, href: URL_ });
    expect(getMarkdown()(editor.ctx)).toBe(`processus dynamicus. <${URL_}>. Est usus legentis.\n`);
  });

  it('paste of a URL followed immediately by typing a space right after it stays one link -- the exact user-reported scenario: an ordinary paste, then continuing to write', async () => {
    const editor = await makeEditor('Before sentence. ');
    const view = editor.ctx.get(editorViewCtx);
    const endPos = view.state.doc.content.size - 1;

    expect(dispatchPasteAt(view, endPos, URL_)).toBe(true);
    typeText(view, ' ');

    expect(soleLinkRun(view.state.doc)).toEqual({ text: URL_, href: URL_ });
  });

  it('paste of a URL immediately followed by a sentence-ending period, then typing a space right after -- the trailing period stays outside the link, and the InputRule re-firing on the typed space does not pull it back in', async () => {
    const editor = await makeEditor('processus dynamicus.  Est usus legentis.');
    const view = editor.ctx.get(editorViewCtx);
    const text = view.state.doc.textBetween(0, view.state.doc.content.size);
    const pos0 = 1 + text.indexOf('.  Est') + 2;
    const periodUrl = 'https://example.com/page';

    expect(dispatchPasteAt(view, pos0, `${periodUrl}.`)).toBe(true);
    typeText(view, ' ');

    expect(soleLinkRun(view.state.doc)).toEqual({ text: periodUrl, href: periodUrl });
  });

  it("Milkdown's own markdown parser (parserCtx), called directly on the bare URL, also produces a single correct link", async () => {
    const editor = await makeEditor('placeholder');
    const parser = editor.ctx.get(parserCtx);
    const slice: any = parser(URL_);
    const textNode = slice.content.firstChild.firstChild;

    expect(textNode.marks).toHaveLength(1);
    expect(textNode.marks[0].type.name).toBe('link');
    expect(textNode.marks[0].attrs.href).toBe(URL_);
    expect(textNode.text).toBe(URL_);
  });
});

describe('getMarkdown() vs. nodeToMarkdownFragment() on an ALREADY-split doc (diagnostic: which serializer produced the observed corruption)', () => {
  // These two marks are hand-constructed, not produced by any paste/typing
  // code path found in this investigation — they pin down which serializer
  // is responsible for turning that in-memory state into the exact
  // corrupted markdown string found in the user's database, given that such
  // a state exists. See the file header for what this does and does not
  // establish.
  function buildSplitMarkDoc(view: any) {
    const schema = view.state.schema;
    const link = schema.marks.link!;
    const truncated = URL_.slice(0, -1); // "...disambiguation" (missing the final ")")
    const para = schema.nodes.paragraph!.create({}, [
      schema.text(truncated, [link.create({ href: truncated })]),
      schema.text(')', [link.create({ href: URL_ })]),
    ]);
    view.dispatch(view.state.tr.replaceWith(0, view.state.doc.content.size, para));
  }

  it("getMarkdown() — the serializer window.FinalFinal.getContent() uses for Swift's save path — reproduces the observed corrupted string exactly", async () => {
    const editor = await makeEditor('placeholder');
    const view = editor.ctx.get(editorViewCtx);
    buildSplitMarkDoc(view);

    expect(getMarkdown()(editor.ctx)).toBe(
      '<https://en.wikipedia.org/wiki/Example_(disambiguation>[)](https://en.wikipedia.org/wiki/Example_\\(disambiguation\\))\n'
    );
  });

  it('nodeToMarkdownFragment() — the incremental block-sync serializer — never emits the observed shape (no autolink form, percent-encodes parens instead)', async () => {
    const editor = await makeEditor('placeholder');
    const view = editor.ctx.get(editorViewCtx);
    buildSplitMarkDoc(view);

    const frag = nodeToMarkdownFragment(view.state.doc.firstChild!);
    expect(frag).not.toContain('<https://');
    expect(frag).not.toContain('\\(');
    expect(frag).not.toContain('\\)');
  });
});
