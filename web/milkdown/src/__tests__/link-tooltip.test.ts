// @vitest-environment jsdom
// Regression tests for the `RangeError: Index N out of range for <text>` crash in
// findLinkMarkRange (link-tooltip.ts). ProseMirror's ResolvedPos.index() legitimately
// returns parent.childCount whenever pos sits exactly at the end of its parent's text
// content — ProseMirror's own `nodeAfter` getter guards this before indexing into the
// parent's Fragment; findLinkMarkRange previously didn't, so `parent.child(index)` threw.
//
// Uses a real Milkdown Editor (commonmark + gfm), not a hand-built minimal Schema, so
// heading/paragraph/list-item text blocks are parsed exactly as they are in production —
// matching the varied real-world trigger content (long paragraph, plain heading, list
// item's text) described in the bug report.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { Node } from '@milkdown/kit/prose/model';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { findLinkMarkRange } from '../link-tooltip';

describe('findLinkMarkRange', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
  });

  async function makeEditor(markdown: string): Promise<EditorView> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(commonmark)
      .use(gfm)
      .create();
    editor = e;
    return e.ctx.get(editorViewCtx);
  }

  /** Position at the end of the first textblock node (of the given type, if given) in the doc. */
  function textblockEndPos(doc: Node, typeName?: string): number {
    let result = -1;
    doc.descendants((node, pos) => {
      if (result !== -1) return false;
      if (node.isTextblock && (typeName === undefined || node.type.name === typeName)) {
        result = pos + node.nodeSize - 1; // one past the last content offset, before the closing token
        return false;
      }
      return true;
    });
    if (result === -1) throw new Error(`no ${typeName ?? 'textblock'} node found in doc`);
    return result;
  }

  it('returns null instead of throwing at the end of a paragraph (no nodeAfter)', async () => {
    const view = await makeEditor('This is a plain paragraph with no link in it at all.');
    const endPos = textblockEndPos(view.state.doc, 'paragraph');
    const $pos = view.state.doc.resolve(endPos);

    // Sanity check: this is genuinely the out-of-range case the guard targets.
    expect($pos.index()).toBe($pos.parent.childCount);

    expect(() => findLinkMarkRange(view, endPos)).not.toThrow();
    expect(findLinkMarkRange(view, endPos)).toBeNull();
  });

  it('returns null instead of throwing at the end of a heading', async () => {
    const view = await makeEditor('## A Plain Heading');
    const endPos = textblockEndPos(view.state.doc, 'heading');
    const $pos = view.state.doc.resolve(endPos);

    expect($pos.index()).toBe($pos.parent.childCount);

    expect(() => findLinkMarkRange(view, endPos)).not.toThrow();
    expect(findLinkMarkRange(view, endPos)).toBeNull();
  });

  it('returns null instead of throwing at the end of a list item paragraph', async () => {
    const view = await makeEditor('- A list item with plain text');
    const endPos = textblockEndPos(view.state.doc, 'paragraph');
    const $pos = view.state.doc.resolve(endPos);

    expect($pos.index()).toBe($pos.parent.childCount);

    expect(() => findLinkMarkRange(view, endPos)).not.toThrow();
    expect(findLinkMarkRange(view, endPos)).toBeNull();
  });

  it('still finds the real link range for a position strictly inside a link mark', async () => {
    const view = await makeEditor('See [my link](https://example.com) for more.');

    let linkFrom = -1;
    let linkTo = -1;
    view.state.doc.descendants((node, pos) => {
      if (node.isText && node.marks.some((m) => m.type.name === 'link')) {
        linkFrom = pos;
        linkTo = pos + node.nodeSize;
      }
      return true;
    });
    expect(linkFrom).toBeGreaterThan(-1);

    const midPos = linkFrom + 1; // strictly inside "my link", not at either edge
    const range = findLinkMarkRange(view, midPos);

    expect(range).not.toBeNull();
    expect(range?.href).toBe('https://example.com');
    expect(range?.from).toBe(linkFrom);
    expect(range?.to).toBe(linkTo);
  });

  it('returns null at the end of a paragraph even when the paragraph ends in a link (no nodeAfter there)', async () => {
    const view = await makeEditor('See [my link](https://example.com)');
    const endPos = textblockEndPos(view.state.doc, 'paragraph');
    const $pos = view.state.doc.resolve(endPos);

    // This is the same out-of-range case as above — the guard fires regardless of
    // whether the preceding content happened to carry a link mark, since the function
    // only ever looks at the node *after* pos (matching its pre-existing convention).
    expect($pos.index()).toBe($pos.parent.childCount);
    expect(() => findLinkMarkRange(view, endPos)).not.toThrow();
    expect(findLinkMarkRange(view, endPos)).toBeNull();
  });
});
