// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx, serializerCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { cleanupSerializedMarkdown, getContent, resetForProjectSwitch } from '../api-content';
import { getCursorPosition } from '../api-modes';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';

// Step 4b of plan-book-length-switch.md: the switch to Markdown reads the Rich Text document twice
// in a row, `getContent()` for the text and `getCursorPosition()` for the caret line. Each used to
// serialise the whole document; on a book that is hundreds of milliseconds, twice. Now the raw
// serialisation is remembered together with the (immutable) ProseMirror document it was made from,
// so the second read of an unchanged document reuses it.
//
// What these tests pin:
//   - the document is serialised once for the pair of reads, in either order;
//   - an edit makes the next read serialise again; a caret move alone does not;
//   - what both functions return is exactly what they returned before the change: `getContent()`
//     still applies its own cleanup to the raw text, `getCursorPosition()` still works from the raw text.

// A paragraph that starts with an escaped "#" is what the serializer writes back as `\#`; getContent()'s
// cleanup turns that into `#`, getCursorPosition() works with the raw text. So the two functions see
// different strings for this document, and a cache that stored the cleaned text would break one of them.
const DOCUMENT = [
  '# Chapter one',
  '',
  'First paragraph with *emphasis* and `code`.',
  '',
  '\\# not a heading',
  '',
  '- item one',
  '- item two',
  '',
  '## Section',
  '',
  'Second paragraph, a little longer, so the caret has somewhere to be.',
].join('\n');

describe('one serialisation for the outgoing Rich Text read', () => {
  let editor: Editor | null = null;
  let serialisations = 0;
  // The serializer as the editor built it, outside the counting wrapper: what "no cache" means.
  let uncountedSerializer: ((doc: ProsemirrorNode) => string) | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    uncountedSerializer = null;
    setEditorInstance(null);
    resetBlockIdState();
    resetBlockSyncState();
  });

  // Same plugin order as set-cursor-at-block.test.ts / main.ts. The serializer is wrapped after
  // creation so the test can count how often the document is actually turned into text.
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
      .use(commonmark)
      .use(gfm)
      .use(highlightPlugin)
      .create();
    setEditorInstance(editor);

    serialisations = 0;
    editor.action((ctx) => {
      const original = ctx.get(serializerCtx);
      uncountedSerializer = original;
      ctx.set(serializerCtx, (doc) => {
        serialisations++;
        return original(doc);
      });
    });

    const view = editor.ctx.get(editorViewCtx);
    // jsdom has no layout, so ProseMirror cannot report where the caret is on screen; getCursorPosition()
    // asks for it. A fixed answer keeps the rest of its logic (the line and column) under test.
    view.coordsAtPos = () => ({ left: 0, right: 0, top: 10, bottom: 20 });
    return view;
  }

  function placeCaret(view: EditorView, pos: number): void {
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)));
  }

  function typeAt(view: EditorView, pos: number, text: string): void {
    view.dispatch(view.state.tr.insertText(text, pos));
  }

  // Position just inside the last paragraph, to put the caret a few characters in.
  function lastParagraphStart(view: EditorView): number {
    let pos = 0;
    for (let i = 0; i < view.state.doc.childCount - 1; i++) pos += view.state.doc.child(i).nodeSize;
    return pos + 1;
  }

  /** What the serializer writes for the current document, without going through the cache or the counter. */
  function freshRaw(): string {
    const view = editor?.ctx.get(editorViewCtx) as EditorView;
    return (uncountedSerializer as (doc: ProsemirrorNode) => string)(view.state.doc);
  }

  it('serialises the document once for getContent() followed by getCursorPosition()', async () => {
    const view = await makeEditor(DOCUMENT);
    placeCaret(view, lastParagraphStart(view) + 6);

    getContent();
    getCursorPosition();

    expect(serialisations).toBe(1);
  });

  it('serialises the document once for getCursorPosition() followed by getContent()', async () => {
    const view = await makeEditor(DOCUMENT);
    placeCaret(view, lastParagraphStart(view) + 6);

    getCursorPosition();
    getContent();

    expect(serialisations).toBe(1);
  });

  it('serialises once for repeated reads of an unchanged document', async () => {
    const view = await makeEditor(DOCUMENT);
    placeCaret(view, lastParagraphStart(view) + 2);

    getContent();
    getContent();
    getCursorPosition();
    getContent();
    getCursorPosition();

    expect(serialisations).toBe(1);
  });

  it('does not serialise again when only the caret moved', async () => {
    const view = await makeEditor(DOCUMENT);
    const start = lastParagraphStart(view);
    placeCaret(view, start + 2);
    getContent();
    expect(serialisations).toBe(1);

    placeCaret(view, start + 9);
    const moved = getCursorPosition();
    placeCaret(view, start + 2);
    const before = getCursorPosition();

    expect(serialisations).toBe(1);
    // The caret really moved: the column is measured from the new position.
    expect(moved.column).toBeGreaterThan(before.column);
  });

  it('serialises again after an edit, and the new text is what both reads return', async () => {
    const view = await makeEditor(DOCUMENT);
    const start = lastParagraphStart(view);
    placeCaret(view, start + 2);
    const before = getContent();
    const cursorBefore = getCursorPosition();
    expect(serialisations).toBe(1);

    typeAt(view, start, 'abc');
    const after = getContent();
    expect(serialisations).toBe(2);
    expect(after).not.toBe(before);
    expect(after).toContain('abcSecond paragraph');
    expect(after).toBe(cleanupSerializedMarkdown(freshRaw(), false));

    // The cursor read after the edit reuses the post-edit serialisation, not the stale one, and sees the
    // three typed characters in front of the caret.
    const cursorAfter = getCursorPosition();
    expect(serialisations).toBe(2);
    expect(cursorAfter.line).toBe(cursorBefore.line);
    expect(cursorAfter.column).toBe(cursorBefore.column + 3);
  });

  it('serialises again when the first read after an edit is getCursorPosition()', async () => {
    const view = await makeEditor(DOCUMENT);
    const start = lastParagraphStart(view);
    placeCaret(view, start + 2);
    getContent();
    getCursorPosition();
    expect(serialisations).toBe(1);

    typeAt(view, start, 'abc');
    getCursorPosition();
    expect(serialisations).toBe(2);
    expect(getContent()).toContain('abcSecond paragraph');
    expect(serialisations).toBe(2);
  });

  it('returns the same text and the same caret position with a remembered serialisation as without one', async () => {
    const view = await makeEditor(DOCUMENT);
    placeCaret(view, lastParagraphStart(view) + 6);

    // Cold: nothing remembered yet, exactly the work the code did before the cache existed.
    const coldCursor = getCursorPosition();
    const coldContent = getContent(); // warm, but also the first look at the text
    // Warm: both again, from the remembered serialisation.
    const warmCursor = getCursorPosition();
    const warmContent = getContent();
    expect(serialisations).toBe(1);

    // The text the old implementation produced: serialize the document, then clean it up.
    const expectedContent = cleanupSerializedMarkdown(freshRaw(), false);
    expect(coldContent).toBe(expectedContent);
    expect(warmContent).toBe(expectedContent);
    expect(warmCursor).toEqual(coldCursor);

    // The other way round, after an edit has emptied the memory: content first, cursor second.
    typeAt(view, lastParagraphStart(view), 'Z');
    const contentFirst = getContent();
    const cursorSecond = getCursorPosition();
    expect(serialisations).toBe(2);
    expect(contentFirst).toBe(cleanupSerializedMarkdown(freshRaw(), false));
    // The same document read cursor-first (after another edit and its undo-equivalent) gives the same
    // numbers: ask again on a cold memory by editing and removing the same character.
    typeAt(view, lastParagraphStart(view), 'Y');
    view.dispatch(view.state.tr.delete(lastParagraphStart(view), lastParagraphStart(view) + 1));
    const cursorFirst = getCursorPosition();
    expect(cursorFirst).toEqual(cursorSecond);
  });

  it('caches the raw text only: getContent() still cleans it up and getCursorPosition() still sees the escape', async () => {
    const view = await makeEditor(DOCUMENT);
    placeCaret(view, lastParagraphStart(view) + 1);

    const raw = freshRaw();
    // The fixture does exercise the cleanup: the serializer writes the escape, the cleanup removes it.
    expect(raw).toContain('\\# not a heading');

    // Fill the memory through the cursor read first, then read the content.
    getCursorPosition();
    const content = getContent();

    expect(content).toContain('\n# not a heading\n');
    expect(content).not.toContain('\\# not a heading');
    expect(content).toBe(cleanupSerializedMarkdown(raw, false));

    // Reading again gives the cleaned text again: the remembered text was not replaced by the cleaned one.
    expect(getContent()).toBe(content);
    expect(serialisations).toBe(1);
  });

  it('does not hand out the previous project text after a project switch', async () => {
    const view = await makeEditor(DOCUMENT);
    placeCaret(view, lastParagraphStart(view) + 1);
    expect(getContent()).toContain('Second paragraph');

    resetForProjectSwitch();

    expect(getContent()).toBe('');
  });
});
