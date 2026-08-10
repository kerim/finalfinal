// @vitest-environment jsdom
//
// Follow-up investigation for the same confirmed-in-production split-link bug
// documented in paste-link-repro.test.ts. That suite tested pasting a URL
// into fresh, never-linked text and could not reproduce the bug. This suite
// tests the specific sequence the user actually reported: "I tried DELETING
// the link and RE-PASTING it in the document" -- i.e. an EXISTING (broken)
// link is selected and removed, then the corrected URL is pasted into that
// exact same spot, immediately afterward.
//
// The theory under test: ProseMirror's `storedMarks` can leak from one
// transaction into the next (this app's own link-cursor.ts exists to guard
// exactly this class of leak for the TYPING path), so maybe a stale
// storedMarks value survives a delete-selection transaction and corrupts the
// immediately-following paste.
//
// ProseMirror-internals tracing rules this out structurally:
//   - `Transaction.setSelection()` (called by `Selection.replace()`, which
//     both `deleteSelection()` and `replaceSelection()` use) explicitly sets
//     `this.storedMarks = null`.
//   - `Transaction.addStep()` also resets `storedMarks` to null on every
//     step.
//   - `EditorState`'s storedMarks field applies as
//     `state.selection.$cursor ? tr.storedMarks : null` -- so a delete or
//     paste transaction that ends in a plain cursor takes tr.storedMarks
//     (null, per above) as the new state's storedMarks, not some leftover
//     value from before the transaction.
//   - link-cursor.ts's own appendTransaction only ever REMOVES the link mark
//     from storedMarks (`effective.filter((m) => m.type !== link)`) -- it
//     has no code path that adds one.
// So a stale storedMarks value cannot itself carry an old link's mark from a
// delete transaction into a subsequent paste in this codebase.
//
// Empirically, every realistic delete-then-paste-in-place variant below
// (full-selection delete via the real deleteSelection command, delete of a
// link at paragraph start vs. mid-sentence, delete of markdown `[text](url)`
// form, and character-by-character Backspace) still produces a single,
// correctly-bounded link mark for the pasted URL, exercised through the real
// clipboard+autolink+link-cursor plugin pipeline (same registration as
// paste-link-repro.test.ts). Typing a trailing space immediately after the
// paste (a natural continuation of writing) was also tested, since the
// autolink InputRule re-scans doc text regardless of existing marks -- it
// does not misfire either.
//
// One related (but NOT matching) issue was found: if the OLD link's
// selection is imprecise and leaves a stray final character of the old,
// still-linked text behind (e.g. a double-click that stops one character
// short), pasting the new URL next to that leftover produces two ADJACENT
// but semantically DIFFERENT links (new correct URL + a 1-char remnant of
// the OLD href) -- visually confusing, but not the reported shape, whose two
// marks both derive from hrefs of the SAME newly-pasted URL (one truncated,
// one the full/escaped form). That mismatch is recorded here as a ruled-out
// shape, not fixed, since it is a distinct bug from the one under
// investigation.
//
// Conclusion: this investigation could not reproduce the split-link bug via
// delete-then-paste-in-place. See the investigation's final report for what
// remains untested.
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { clipboard } from '@milkdown/kit/plugin/clipboard';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm, remarkGFMPlugin } from '@milkdown/kit/preset/gfm';
import { deleteSelection } from '@milkdown/kit/prose/commands';
import { TextSelection } from '@milkdown/kit/prose/state';
import { getMarkdown } from '@milkdown/kit/utils';
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

const URL_ = 'https://en.wikipedia.org/wiki/Example_(disambiguation)';
const BROKEN = 'https://en.wikipedia.org/wiki/Example_BROKEN';

// Matches main.ts's real registration for every plugin that touches link
// marks or serialization -- same harness as paste-link-repro.test.ts.
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

function linkRuns(doc: any): { text: string; href: string }[] {
  const runs: { text: string; href: string }[] = [];
  doc.firstChild?.forEach((child: any) => {
    const mark = child.marks?.find((m: any) => m.type.name === 'link');
    if (mark) runs.push({ text: child.text, href: mark.attrs.href });
  });
  return runs;
}

function findLinkSpan(view: any): { from: number; to: number } {
  let from = -1;
  let to = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.isText && node.marks.some((m: any) => m.type.name === 'link')) {
      if (from === -1) from = pos;
      to = pos + node.nodeSize;
    }
    return true;
  });
  return { from, to };
}

function deleteRealSelection(view: any, from: number, to: number): void {
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from, to)));
  deleteSelection(view.state, view.dispatch.bind(view));
}

function dispatchPaste(view: any, text: string): boolean {
  return view.someProp('handlePaste', (f: any) => f(view, fakePaste(text), undefined));
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

describe('delete an existing (broken) link, then paste the corrected URL into that exact spot -- regression suite for a reported split-into-two-marks bug that could not be reproduced this way', () => {
  it('link at paragraph start: select the full broken-link span via the real deleteSelection command, then paste', async () => {
    const editor = await makeEditor(`<${BROKEN}> rest of sentence.`);
    const view = editor.ctx.get(editorViewCtx);
    const { from, to } = findLinkSpan(view);

    deleteRealSelection(view, from, to);
    expect(dispatchPaste(view, URL_)).toBe(true);
    expect(linkRuns(view.state.doc)).toEqual([{ text: URL_, href: URL_ }]);
    expect(getMarkdown()(editor.ctx)).toBe(`<${URL_}> rest of sentence.\n`);
  });

  it('link mid-sentence with plain text on both sides: select full span, delete, paste', async () => {
    const editor = await makeEditor(`Before text <${BROKEN}> after text.`);
    const view = editor.ctx.get(editorViewCtx);
    const { from, to } = findLinkSpan(view);

    deleteRealSelection(view, from, to);
    expect(dispatchPaste(view, URL_)).toBe(true);
    expect(linkRuns(view.state.doc)).toEqual([{ text: URL_, href: URL_ }]);
    expect(getMarkdown()(editor.ctx)).toBe(`Before text <${URL_}> after text.\n`);
  });

  it('markdown [text](url) form broken link: select whole span, delete, paste', async () => {
    const escapedBroken = BROKEN.replace(/\(/g, '\\(').replace(/\)/g, '\\)');
    const editor = await makeEditor(`Before text [old label](${escapedBroken}) after text.`);
    const view = editor.ctx.get(editorViewCtx);
    const { from, to } = findLinkSpan(view);

    deleteRealSelection(view, from, to);
    expect(dispatchPaste(view, URL_)).toBe(true);
    expect(linkRuns(view.state.doc)).toEqual([{ text: URL_, href: URL_ }]);
  });

  it('paste directly replaces the old-link selection in one step (select + paste, no separate delete)', async () => {
    const editor = await makeEditor(`Before text <${BROKEN}> after text.`);
    const view = editor.ctx.get(editorViewCtx);
    const { from, to } = findLinkSpan(view);

    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from, to)));
    expect(dispatchPaste(view, URL_)).toBe(true);
    expect(linkRuns(view.state.doc)).toEqual([{ text: URL_, href: URL_ }]);
  });

  it('character-by-character Backspace over the whole link (holding the key), then paste', async () => {
    const editor = await makeEditor(`Before text <${BROKEN}> after text.`);
    const view = editor.ctx.get(editorViewCtx);
    const { from, to } = findLinkSpan(view);

    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, to, to)));
    for (let i = 0; i < to - from; i++) {
      const pos = view.state.selection.from;
      view.dispatch(view.state.tr.delete(pos - 1, pos));
    }
    expect(dispatchPaste(view, URL_)).toBe(true);
    expect(linkRuns(view.state.doc)).toEqual([{ text: URL_, href: URL_ }]);
  });

  it('paste at doc end, then continue typing a space right after (autolink InputRule re-scans doc text but does not re-split an already-correct link)', async () => {
    const editor = await makeEditor('Before sentence. ');
    const view = editor.ctx.get(editorViewCtx);
    view.dispatch(
      view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(view.state.doc.content.size - 1)))
    );
    expect(dispatchPaste(view, URL_)).toBe(true);

    typeText(view, ' ');
    expect(linkRuns(view.state.doc)).toEqual([{ text: URL_, href: URL_ }]);
  });

  it('delete a full-span broken link at doc end, paste the correction, then continue typing a space right after', async () => {
    const editor = await makeEditor(`Before sentence. <${BROKEN}>`);
    const view = editor.ctx.get(editorViewCtx);
    const { from, to } = findLinkSpan(view);

    deleteRealSelection(view, from, to);
    expect(dispatchPaste(view, URL_)).toBe(true);

    typeText(view, ' ');
    expect(linkRuns(view.state.doc)).toEqual([{ text: URL_, href: URL_ }]);
  });

  it("RULED-OUT SHAPE (does not match the reported bug): an imprecise deletion that leaves the old link's trailing char behind produces two links with DIFFERENT hrefs (new correct + old remnant), not the reported truncated+full split of the SAME url", async () => {
    const editor = await makeEditor(`<${BROKEN}> rest of sentence.`);
    const view = editor.ctx.get(editorViewCtx);
    const { from, to } = findLinkSpan(view);

    // Delete everything except the link's final character (simulating an
    // imprecise selection, e.g. a double-click that stops one char short).
    deleteRealSelection(view, from, to - 1);
    expect(dispatchPaste(view, URL_)).toBe(true);

    const runs = linkRuns(view.state.doc);
    expect(runs).toHaveLength(2);
    expect(runs[0]).toEqual({ text: URL_, href: URL_ }); // the new paste: correct and whole
    expect(runs[1]).toEqual({ text: 'N', href: BROKEN }); // leftover remnant of the OLD link, untouched
    // Confirms this is NOT the reported shape: the reported bug's second mark's href is the
    // FULL new URL (escaped), not an unrelated old href, and its text is the new URL's own
    // trailing character, not an arbitrary leftover character from the old link.
  });
});
