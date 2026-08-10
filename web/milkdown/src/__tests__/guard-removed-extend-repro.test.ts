// @vitest-environment jsdom
//
// Follow-up to the guard that was added, then rejected, in this same investigation trail
// (see paste-link-repro.test.ts and delete-then-paste-repro.test.ts for the earlier rounds).
// That guard declined to re-fire the autolink InputRule on any text already covered by a
// link mark -- but that also blocked the InputRule's only mechanism for fixing up a link's
// boundary/href when the user keeps typing right after a pasted link (the ordinary next
// action after pasting a URL). With the guard in place, a subsequent space never triggered
// recomputation, so a link that should have grown to cover newly typed text -- or a link
// whose paste-time boundary was one keystroke short of the full URL -- stayed
// stale/truncated forever. That is the same corruption class the guard was meant to prevent,
// which is why it was removed.
//
// This file asks the follow-up question directly: with the guard gone, is there any
// realistic paste-then-type-then-space sequence that still produces the ORIGINAL bug this
// whole investigation started from -- two adjacent link marks covering one visually
// continuous URL, with different hrefs (one truncated/stale, one correct)? Every scenario
// below drives the real Milkdown paste pipeline and the real autolinkPlugin InputRule
// through actually-dispatched transactions (not a discarded handleTextInput return value --
// see the note on typeText() below), matching how the app really behaves.
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { clipboard } from '@milkdown/kit/plugin/clipboard';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm, remarkGFMPlugin } from '@milkdown/kit/preset/gfm';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { describe, expect, it } from 'vitest';
import { autolinkPlugin } from '../autolink-plugin';
import { blockIdPlugin } from '../block-id-plugin';
import { blockSyncPlugin } from '../block-sync-plugin';
import { highlightPlugin } from '../highlight-plugin';
import { imageNodeRewritePlugin } from '../image-node-rewrite-plugin';
import { linkCursorPlugin } from '../link-cursor';
import { markdownLinkPlugin } from '../markdown-link-input-rule';
import { orderedListOrderPlugin } from '../ordered-list-order-plugin';
import { smartQuotesPlugin } from '../smart-quotes-plugin';
import { tablePastePlugin } from '../table-paste-plugin';

const WIKI_URL = 'https://en.wikipedia.org/wiki/Example_(disambiguation)';

// Base doc for every test below: two sentences separated by two spaces. Pasting/typing
// happens right after that internal double space -- unlike a paragraph's TRAILING space
// (which the markdown parser trims away, so a URL pasted "at the end" ends up butted right
// up against the preceding word with no separating whitespace), an internal space survives
// parsing intact, so the autolink InputRule's `(?:^|\s)` boundary requirement is satisfied
// exactly the way it would be for a real user who paused, then kept typing mid-document.
const BASE_TEXT = 'Start.  End.';

// Matches main.ts's real registration for every plugin that touches link marks or
// serialization -- same harness as paste-link-repro.test.ts and delete-then-paste-repro.test.ts.
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

function fakePaste(text: string): ClipboardEvent {
  return {
    clipboardData: {
      getData: (type: string) => (type === 'text/plain' ? text : ''),
    },
    preventDefault: () => {},
  } as unknown as ClipboardEvent;
}

/** Position right after the internal double space in BASE_TEXT ("Start.  |End."). */
function pasteInsertionPos(view: EditorView): number {
  const text = view.state.doc.textBetween(0, view.state.doc.content.size);
  return 1 + text.indexOf('.  End') + 2;
}

function dispatchPasteAt(view: EditorView, pos: number, text: string): boolean {
  view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos))));
  return view.someProp('handlePaste', (f: any) => f(view, fakePaste(text), undefined)) ?? false;
}

/** Every link-marked text run in the doc's first paragraph, in order. */
function linkRuns(view: EditorView): { text: string; href: string }[] {
  const runs: { text: string; href: string }[] = [];
  view.state.doc.firstChild?.forEach((child) => {
    const mark = child.marks.find((m) => m.type.name === 'link');
    if (mark) runs.push({ text: child.text ?? '', href: mark.attrs.href });
  });
  return runs;
}

/**
 * Simulate the user typing one character (or the triggering space) at the current cursor,
 * exactly the way the real EditorView does it: go through `handleTextInput` first (the real
 * autolinkPlugin's InputRule lives there, and -- per prosemirror-inputrules' own `run()` --
 * dispatches its own transaction internally when a rule matches and its handler returns
 * non-null). If no rule handled it, fall back to a plain `insertText` transaction, matching
 * what the browser's native contenteditable insertion would otherwise do.
 *
 * This is the fix for the bug this investigation found in the two earlier repro files: they
 * called `view.someProp('handleTextInput', ...)` and discarded the boolean result, so when a
 * rule declined (returned null/false), NOTHING was dispatched -- the typed character never
 * actually landed in the document, and assertions afterward were silently checking the
 * unchanged pre-keystroke doc.
 */
function typeText(view: EditorView, text: string): void {
  const pos = view.state.selection.from;
  const handled = view.someProp('handleTextInput', (f: any) => f(view, pos, pos, text)) ?? false;
  if (!handled) {
    view.dispatch(view.state.tr.insertText(text, pos));
  }
}

describe('guard removed: paste-then-extend-then-space must not split one URL into two adjacent link marks with different hrefs', () => {
  it('paste the URL missing its final ")", then type ")" and a space -- the literal split point from the original production bug -- stays a single link with the full, correct href', async () => {
    const editor = await makeEditor(BASE_TEXT);
    const view = editor.ctx.get(editorViewCtx);
    const pos = pasteInsertionPos(view);
    const truncated = WIKI_URL.slice(0, -1); // "...Example_(disambiguation" -- missing the final ")"

    expect(dispatchPasteAt(view, pos, truncated)).toBe(true);
    expect(linkRuns(view)).toEqual([{ text: truncated, href: truncated }]);

    typeText(view, ')');
    typeText(view, ' ');

    expect(linkRuns(view)).toEqual([{ text: WIKI_URL, href: WIKI_URL }]);
  });

  it('paste the full user-reported Wikipedia disambiguation URL, then type a trailing space -- stays a single link with the unchanged, correct href', async () => {
    const editor = await makeEditor(BASE_TEXT);
    const view = editor.ctx.get(editorViewCtx);
    const pos = pasteInsertionPos(view);

    expect(dispatchPasteAt(view, pos, WIKI_URL)).toBe(true);
    expect(linkRuns(view)).toEqual([{ text: WIKI_URL, href: WIKI_URL }]);

    typeText(view, ' ');

    expect(linkRuns(view)).toEqual([{ text: WIKI_URL, href: WIKI_URL }]);
  });

  it('paste a URL, then extend it with unrelated trailing characters and a space -- the href updates to the full extended URL, no stale/truncated mark left behind', async () => {
    const editor = await makeEditor(BASE_TEXT);
    const view = editor.ctx.get(editorViewCtx);
    const pos = pasteInsertionPos(view);
    const pasted = 'https://example.com/foo';

    expect(dispatchPasteAt(view, pos, pasted)).toBe(true);
    expect(linkRuns(view)).toEqual([{ text: pasted, href: pasted }]);

    for (const ch of '/bar') typeText(view, ch);
    typeText(view, ' ');

    const extended = 'https://example.com/foo/bar';
    expect(linkRuns(view)).toEqual([{ text: extended, href: extended }]);
  });

  it('paste a URL with a trailing period, then type a space right after -- stays a single link, period excluded from the href', async () => {
    const editor = await makeEditor(BASE_TEXT);
    const view = editor.ctx.get(editorViewCtx);
    const pos = pasteInsertionPos(view);
    const url = 'https://example.com/page';

    expect(dispatchPasteAt(view, pos, `${url}.`)).toBe(true);
    expect(linkRuns(view)).toEqual([{ text: url, href: url }]);

    typeText(view, ' ');

    expect(linkRuns(view)).toEqual([{ text: url, href: url }]);
  });

  it('paste a partial URL, then type the rest of the SAME url plus the closing paren and a space -- reconstructing the disambiguation URL by hand stays a single link', async () => {
    const editor = await makeEditor(BASE_TEXT);
    const view = editor.ctx.get(editorViewCtx);
    const pos = pasteInsertionPos(view);
    const pastedPrefix = 'https://en.wikipedia.org/wiki/Example';
    const rest = '_(disambiguation)';

    expect(dispatchPasteAt(view, pos, pastedPrefix)).toBe(true);
    expect(linkRuns(view)).toEqual([{ text: pastedPrefix, href: pastedPrefix }]);

    for (const ch of rest) typeText(view, ch);
    typeText(view, ' ');

    expect(linkRuns(view)).toEqual([{ text: WIKI_URL, href: WIKI_URL }]);
  });
});
