// @vitest-environment jsdom
// The caret's Markdown column across the Rich Text / Markdown switch, with citations and a footnote reference before it
// (hand test 2026-11-06, docs/architecture/write-queue-plan/phase5/a9-notes.md, "Cursor fix and switch notice").
//
// `getCursorPosition()` gives the Rich Text caret to the Markdown page as a line and a column. A citation or a footnote reference is ONE
// ProseMirror position but many Markdown characters (`[@key, p. 12; @other]`, `[^3]`); the column used to be computed as if each were one
// character, so a caret at the end of such a paragraph came over many characters too early: the owner's typing on the new Markdown page
// landed in the middle of a word earlier in the paragraph. `setCursorPosition()` (Markdown back to Rich Text) had the mirror fault: the
// citation's characters were counted as text, so a caret after a citation went too far.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { getRawSerialisedMarkdown, resetForProjectSwitch } from '../api-content';
import { getCursorPosition, setCursorPosition } from '../api-modes';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState } from '../block-sync-plugin';
import { citationPlugin } from '../citation-plugin';
import { setEditorInstance } from '../editor-state';
import { footnotePlugin } from '../footnote-plugin';
import { highlightPlugin } from '../highlight-plugin';

const PARAGRAPH = 'Caret01 ledger [@smith2019, p. 12; @jones2020, p. 40] harbour [@lee2018] note[^1] closes.';
const DOCUMENT = [
  '# Chapter one',
  '',
  PARAGRAPH,
  '',
  '- item [@lee2018] tail',
  '',
  'After.',
  '',
  '[^1]: The note.',
].join('\n');

describe('the caret column with citations and footnote references before it', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    resetForProjectSwitch();
    resetBlockIdState();
    resetBlockSyncState();
  });

  async function makeEditor(markdown: string): Promise<EditorView> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    editor = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(blockIdPlugin)
      .use(blockSyncPlugin)
      .use(citationPlugin)
      .use(footnotePlugin)
      .use(commonmark)
      .use(gfm)
      .use(highlightPlugin)
      .create();
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    view.coordsAtPos = () => ({ left: 0, right: 0, top: 10, bottom: 20 });
    return view;
  }

  /** The textblock whose text starts with `prefix`: its content start and end positions. */
  function block(view: EditorView, prefix: string): { start: number; end: number } {
    let found: { start: number; end: number } | null = null;
    view.state.doc.descendants((node, pos) => {
      if (found) return false;
      if (node.isTextblock && node.textContent.startsWith(prefix))
        found = { start: pos + 1, end: pos + 1 + node.content.size };
      return true;
    });
    if (!found) throw new Error(`no block starting with ${prefix}`);
    return found;
  }

  /** The Rich Text position just before the first occurrence of `text` inside the block starting with `prefix`. */
  function positionBefore(view: EditorView, prefix: string, text: string): number {
    const { start, end } = block(view, prefix);
    for (let pos = start; pos < end; pos++) {
      if (view.state.doc.textBetween(pos, Math.min(end, pos + text.length)) === text) return pos;
    }
    throw new Error(`no ${text} in ${prefix}`);
  }

  function caretAt(view: EditorView, pos: number): void {
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)));
  }

  /** The Markdown line and what comes before the column `getCursorPosition()` reports. */
  function markdownBeforeCaret(): { line: string; before: string } {
    const caret = getCursorPosition();
    const lines = getRawSerialisedMarkdown(editor as Editor).split('\n');
    const line = lines[caret.line - 1] ?? '';
    return { line, before: line.slice(0, caret.column) };
  }

  it('puts the caret at the end of the Markdown line when it is at the end of a paragraph with citations and a note', async () => {
    const view = await makeEditor(DOCUMENT);
    caretAt(view, block(view, 'Caret01').end);
    const { line, before } = markdownBeforeCaret();
    expect(line.startsWith('Caret01')).toBe(true);
    expect(before).toBe(line);
  });

  it('puts the caret right before the same word in the middle of the paragraph', async () => {
    const view = await makeEditor(DOCUMENT);
    caretAt(view, positionBefore(view, 'Caret01', 'closes'));
    const { line, before } = markdownBeforeCaret();
    expect(line.slice(before.length).startsWith('closes.')).toBe(true);
    caretAt(view, positionBefore(view, 'Caret01', 'harbour'));
    const second = markdownBeforeCaret();
    expect(second.line.slice(second.before.length).startsWith('harbour')).toBe(true);
  });

  it('counts the list marker and the citation in a list item', async () => {
    const view = await makeEditor(DOCUMENT);
    caretAt(view, positionBefore(view, 'item', 'tail'));
    const { line, before } = markdownBeforeCaret();
    expect(line.startsWith('- item') || line.startsWith('* item')).toBe(true);
    expect(line.slice(before.length)).toBe('tail');
  });

  it('back to Rich Text: a Markdown column after the citations lands before the same word', async () => {
    const view = await makeEditor(DOCUMENT);
    const lines = getRawSerialisedMarkdown(editor as Editor).split('\n');
    const index = lines.findIndex((l) => l.startsWith('Caret01'));
    const line = lines[index];
    setCursorPosition({ line: index + 1, column: line.indexOf('closes') });
    const head = view.state.selection.head;
    expect(view.state.doc.textBetween(head, head + 6)).toBe('closes');
    setCursorPosition({ line: index + 1, column: line.indexOf('harbour') });
    const head2 = view.state.selection.head;
    expect(view.state.doc.textBetween(head2, head2 + 7)).toBe('harbour');
    setCursorPosition({ line: index + 1, column: line.length });
    expect(view.state.selection.head).toBe(block(view, 'Caret01').end);
  });

  it('round-trips: Rich Text caret to Markdown column and back is the same position', async () => {
    const view = await makeEditor(DOCUMENT);
    const { start, end } = block(view, 'Caret01');
    for (let pos = start; pos <= end; pos++) {
      caretAt(view, pos);
      const caret = getCursorPosition();
      caretAt(view, start);
      setCursorPosition({ line: caret.line, column: caret.column });
      expect(view.state.selection.head).toBe(pos);
    }
  });
});
