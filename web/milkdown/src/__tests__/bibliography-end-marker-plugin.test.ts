// @vitest-environment jsdom
// Regression tests for the bibliography-end terminator (bibliography-end-marker-plugin.ts):
// the parse/serialize round-trip for the `auto_bibliography_end` atom node, and the delete-key
// protection this file's must-fix rounds added (see the file's own doc comments for why bare
// Backspace was already safe but the other ten reachable delete-family bindings were not —
// prosemirror-commands' `joinBackward`/`joinForward` both have an unconditional "delete the
// adjacent atom" fallback that ignores `selectable: false`, and macOS's `macBaseKeymap` reaches
// that same unguarded chain via Delete/Mod-Delete/Ctrl-d/Mod-Backspace/Shift-Backspace (round 1)
// plus Alt-Backspace/Ctrl-h/Ctrl-Alt-Backspace/Alt-Delete/Alt-d (round 2 — most notably
// Alt-Backspace, macOS's everyday word-delete-backward gesture, which `Mod-Backspace` does NOT
// cover: `Mod-` never normalizes to `Alt-` on any platform)).
//
// Uses a real Milkdown Editor instance (commonmark + gfm + bibliographyEndMarkerPlugin +
// history), not a hand-built minimal Schema — mirrors citation-delete.test.ts's approach so
// `<!-- ::auto-bibliography-end:: -->` really parses through the plugin's actual remark
// visitor end-to-end.
//
// Modifier-key note: `isBibliographyEndMarkerAdjacent` is exported specifically so the SHARED
// logic behind all ten guarded key bindings (each one a one-line delegation to this same
// predicate, see the plugin file) can be tested directly and exhaustively, without depending on
// prosemirror-keymap's platform-specific `Mod-` → `Meta-`/`Ctrl-` resolution (which reads
// `navigator.platform`; jsdom reports `""`, so `Mod-` resolves to `Ctrl-` here but `Meta-`
// (Cmd) in the real macOS app — verified directly against this test environment, not assumed).
// The real `handleKeyDown`-driven tests below (mirroring citation-delete.test.ts's `pressKey`
// technique) dispatch every one of the ten bindings, not just the platform-independent ones:
// the `Mod-Delete`/`Mod-Backspace` dispatches use `ctrlKey: true` to match jsdom's own `Mod-`
// resolution specifically (proving the registration is real and reachable in THIS environment,
// not proving the Cmd-key case on real macOS — the exhaustive direct predicate tests above are
// what cover platform-independent correctness), while the other eight (Delete, Ctrl-d,
// Shift-Backspace, Alt-Backspace, Ctrl-h, Ctrl-Alt-Backspace, Alt-Delete, Alt-d) are literal,
// non-`Mod-` bindings dispatched with the exact modifier flags macOS itself would report.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { Node } from '@milkdown/kit/prose/model';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { bibliographyEndMarkerPlugin, isBibliographyEndMarkerAdjacent } from '../bibliography-end-marker-plugin';

const TERMINATOR = '<!-- ::auto-bibliography-end:: -->';
const NODE_NAME = 'auto_bibliography_end';

describe('bibliography end marker plugin', () => {
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
      // bibliographyEndMarkerPlugin MUST be registered before commonmark/gfm so its remark
      // visitor sees the raw HTML comment before HTML-comment filtering strips it — mirrors
      // the same ordering rule citation-plugin.ts and bibliography-plugin.ts both use.
      .use(bibliographyEndMarkerPlugin)
      .use(commonmark)
      .use(gfm)
      .use(history)
      .create();
    editor = e;
    return e;
  }

  /** All `auto_bibliography_end` node positions in the document, in document order. */
  function markerPositions(doc: Node): number[] {
    const positions: number[] = [];
    doc.descendants((node, pos) => {
      if (node.type.name === NODE_NAME) positions.push(pos);
    });
    return positions;
  }

  /** The content range [start, end) of the first textblock whose full text equals `text`. */
  function textblockRange(doc: Node, text: string): { start: number; end: number } {
    let found: { start: number; end: number } | null = null;
    doc.descendants((node, pos) => {
      if (found || !node.isTextblock || node.textContent !== text) return true;
      found = { start: pos + 1, end: pos + 1 + node.content.size };
      return false;
    });
    if (!found) throw new Error(`No textblock found with text: ${text}`);
    return found;
  }

  // getMarkdown() always appends a trailing newline; strip only that.
  function markdownOf(e: Editor): string {
    return e.action(getMarkdown()).replace(/\n+$/, '');
  }

  function placeCursor(view: EditorView, pos: number): void {
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)));
  }

  // Real handleKeyDown dispatch path — see citation-delete.test.ts's identical helper for why
  // this (not a raw DOM KeyboardEvent dispatch on view.dom) is the right level to test at.
  function pressKey(view: EditorView, key: string, modifiers: Partial<KeyboardEventInit> = {}): boolean {
    const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...modifiers });
    return !!view.someProp('handleKeyDown', (f) => f(view, event));
  }

  const MARKDOWN = `# References\n\nOnly entry.\n\n${TERMINATOR}\n\nTrailing paragraph.`;

  // ---- Parse -> serialize round-trip for the marker node itself ----

  it('parses the terminator into a single atom node and serializes it back to the identical HTML comment', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);

    expect(markerPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(MARKDOWN);
  });

  it('the marker node is a zero-content atom (produces no visible text)', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const [pos] = markerPositions(view.state.doc);
    const node = view.state.doc.nodeAt(pos)!;

    expect(node.isAtom).toBe(true);
    expect(node.content.size).toBe(0);
    expect(node.type.spec.selectable).toBe(false);
  });

  // ---- Enter-key insertion-boundary fix (bibliographyEndEnterKeymap) ----
  // The plugin's own doc comment calls Enter-then-type "the single most natural way a user
  // would type" -- covered here for the first time; the delete-key tests below cover the
  // OTHER ten reachable bindings, none of which is Enter.

  it('Enter at the end of the last bibliography entry places the new paragraph AFTER the terminator, not before', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'Only entry.');
    placeCursor(view, end);

    const handled = pressKey(view, 'Enter');

    expect(handled).toBe(true);

    // Top-level node sequence must be: heading, "Only entry." paragraph, terminator atom,
    // a NEW empty paragraph, then "Trailing paragraph." -- proving the new paragraph landed
    // after the terminator rather than splitting "Only entry." in place ahead of it (which is
    // what ProseMirror's default splitBlock would have done).
    const topLevelNodes: { type: string; pos: number }[] = [];
    view.state.doc.forEach((node, pos) => {
      topLevelNodes.push({ type: node.type.name, pos });
    });
    expect(topLevelNodes.map((n) => n.type)).toEqual(['heading', 'paragraph', NODE_NAME, 'paragraph', 'paragraph']);

    expect(markerPositions(view.state.doc)).toHaveLength(1);

    // The newly inserted paragraph (the 4th top-level node) is empty, and the cursor sits
    // inside it -- exactly where a user who then starts typing would land.
    const newParagraphPos = topLevelNodes[3].pos;
    const newParagraph = view.state.doc.nodeAt(newParagraphPos)!;
    expect(newParagraph.type.name).toBe('paragraph');
    expect(newParagraph.content.size).toBe(0);
    expect(view.state.selection.empty).toBe(true);
    expect(view.state.selection.from).toBe(newParagraphPos + 1);

    // Original content on both sides of the terminator survives untouched.
    expect(textblockRange(view.state.doc, 'Only entry.')).toBeTruthy();
    expect(textblockRange(view.state.doc, 'Trailing paragraph.')).toBeTruthy();
  });

  it('negative guard: Enter falls through to normal splitBlock when the cursor is not adjacent to the terminator', async () => {
    const e = await makeEditor('First paragraph.\n\nSecond paragraph.');
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'First paragraph.');
    placeCursor(view, end);

    const handled = pressKey(view, 'Enter');

    // Handled by commonmark's own splitBlock, not swallowed/redirected by us -- a real split
    // inserts a new empty paragraph right after "First paragraph.", proving genuine
    // fallthrough rather than a lucky `false`.
    expect(handled).toBe(true);
    const topLevelTypes: string[] = [];
    view.state.doc.forEach((node) => {
      topLevelTypes.push(node.type.name);
    });
    expect(topLevelTypes).toEqual(['paragraph', 'paragraph', 'paragraph']);
    expect(textblockRange(view.state.doc, 'First paragraph.')).toBeTruthy();
    expect(textblockRange(view.state.doc, 'Second paragraph.')).toBeTruthy();
  });

  // ---- isBibliographyEndMarkerAdjacent: the shared predicate behind every guarded key ----

  it('reports "after" adjacency true, "before" adjacency false, at the end of the paragraph immediately before the terminator', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'Only entry.');
    placeCursor(view, end);

    expect(isBibliographyEndMarkerAdjacent(view.state, 'after')).toBe(true);
    expect(isBibliographyEndMarkerAdjacent(view.state, 'before')).toBe(false);
  });

  it('reports "before" adjacency true, "after" adjacency false, at the start of the paragraph immediately after the terminator', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { start } = textblockRange(view.state.doc, 'Trailing paragraph.');
    placeCursor(view, start);

    expect(isBibliographyEndMarkerAdjacent(view.state, 'before')).toBe(true);
    expect(isBibliographyEndMarkerAdjacent(view.state, 'after')).toBe(false);
  });

  it('reports both directions false at the very end of the document (no node follows at all)', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    placeCursor(view, view.state.doc.content.size - 1);

    expect(isBibliographyEndMarkerAdjacent(view.state, 'after')).toBe(false);
    expect(isBibliographyEndMarkerAdjacent(view.state, 'before')).toBe(false);
  });

  it('reports both directions false mid-text, nowhere near either paragraph boundary', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { start } = textblockRange(view.state.doc, 'Only entry.');
    placeCursor(view, start + 2); // inside "Only entry.", not at either edge

    expect(isBibliographyEndMarkerAdjacent(view.state, 'after')).toBe(false);
    expect(isBibliographyEndMarkerAdjacent(view.state, 'before')).toBe(false);
  });

  it('reports both directions false for a non-empty selection, even one spanning across the terminator', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'Only entry.');
    const { start } = textblockRange(view.state.doc, 'Trailing paragraph.');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, end, start)));

    expect(view.state.selection.empty).toBe(false);
    expect(isBibliographyEndMarkerAdjacent(view.state, 'after')).toBe(false);
    expect(isBibliographyEndMarkerAdjacent(view.state, 'before')).toBe(false);
  });

  // ---- Real handleKeyDown-driven coverage of the guarded key bindings ----

  it('Delete at the end of the paragraph immediately before the terminator is swallowed — terminator and content survive untouched', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'Only entry.');
    placeCursor(view, end);

    const handled = pressKey(view, 'Delete');

    expect(handled).toBe(true);
    expect(markerPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(MARKDOWN);
  });

  it('Shift-Backspace at the start of the paragraph immediately after the terminator is swallowed — terminator and content survive untouched', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { start } = textblockRange(view.state.doc, 'Trailing paragraph.');
    placeCursor(view, start);

    const handled = pressKey(view, 'Backspace', { shiftKey: true });

    expect(handled).toBe(true);
    expect(markerPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(MARKDOWN);
  });

  it('negative guard: Delete falls through to normal joining when the cursor is not adjacent to the terminator', async () => {
    // No terminator anywhere in this document — proves the plugin doesn't swallow Delete
    // unconditionally, only when genuinely adjacent to the marker atom.
    const e = await makeEditor('First paragraph.\n\nSecond paragraph.');
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'First paragraph.');
    placeCursor(view, end);

    const handled = pressKey(view, 'Delete');

    // Handled by the BASE keymap's own join behavior (joinForward), not swallowed by us —
    // the two paragraphs actually merge, proving real fallthrough rather than a lucky `false`.
    expect(handled).toBe(true);
    expect(markdownOf(e)).toBe('First paragraph.Second paragraph.');
  });

  it('negative guard: Shift-Backspace falls through to normal joining when the cursor is not adjacent to the terminator', async () => {
    const e = await makeEditor('First paragraph.\n\nSecond paragraph.');
    const view = e.ctx.get(editorViewCtx);
    const { start } = textblockRange(view.state.doc, 'Second paragraph.');
    placeCursor(view, start);

    const handled = pressKey(view, 'Backspace', { shiftKey: true });

    expect(handled).toBe(true);
    expect(markdownOf(e)).toBe('First paragraph.Second paragraph.');
  });

  // ---- Real handleKeyDown-driven coverage of the 3 bindings above that were previously
  // predicate-only (Mod-Delete, Ctrl-d, Mod-Backspace) ----
  //
  // `Mod-Delete` and `Mod-Backspace` normalize through prosemirror-keymap's platform check —
  // `navigator.platform` is `""` in jsdom, so `Mod-` resolves to `Ctrl-` here (verified via the
  // same platform-check code this file's top comment already documents), NOT `Meta-`/Cmd as on
  // real macOS. Dispatching `ctrlKey: true` below matches jsdom's own resolution — it does not
  // prove the Cmd-key case on real macOS, only that the binding fires for whatever key name this
  // test environment actually resolves `Mod-` to, i.e. that the keymap registration itself is
  // real and reachable, not a typo'd string nobody ever calls.

  it('Mod-Delete (jsdom: Ctrl-Delete) at the end of the paragraph before the terminator is swallowed', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'Only entry.');
    placeCursor(view, end);

    const handled = pressKey(view, 'Delete', { ctrlKey: true });

    expect(handled).toBe(true);
    expect(markerPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(MARKDOWN);
  });

  it('Ctrl-d at the end of the paragraph before the terminator is swallowed', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'Only entry.');
    placeCursor(view, end);

    const handled = pressKey(view, 'd', { ctrlKey: true });

    expect(handled).toBe(true);
    expect(markerPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(MARKDOWN);
  });

  it('Mod-Backspace (jsdom: Ctrl-Backspace) at the start of the paragraph after the terminator is swallowed', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { start } = textblockRange(view.state.doc, 'Trailing paragraph.');
    placeCursor(view, start);

    const handled = pressKey(view, 'Backspace', { ctrlKey: true });

    expect(handled).toBe(true);
    expect(markerPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(MARKDOWN);
  });

  // ---- Real handleKeyDown-driven coverage of the 5 macOS bindings this round added
  // (Alt-Backspace, Ctrl-h, Ctrl-Alt-Backspace, Alt-Delete, Alt-d) ----
  //
  // Unlike Mod-Delete/Mod-Backspace above, none of these five use `Mod-` normalization — they
  // are literal Alt-/Ctrl- combinations in the keymap table, so dispatching them here exercises
  // the EXACT same key name macOS's own `macBaseKeymap` resolves to (Option key => `altKey`,
  // Control key => `ctrlKey`), with no jsdom-vs-real-platform gap to caveat.
  //
  // Cursor placement must match each binding's registered `direction` in the plugin
  // (`isBibliographyEndMarkerAdjacent`'s 'before'/'after'): Alt-Backspace and Ctrl-h are
  // 'before' (same as Mod-Backspace/Shift-Backspace — cursor at the START of the paragraph
  // AFTER the terminator, deleting backward INTO it); Ctrl-Alt-Backspace, Alt-Delete and
  // Alt-d are 'after' (same as Delete/Mod-Delete/Ctrl-d — cursor at the END of the paragraph
  // BEFORE the terminator, deleting forward INTO it).

  it('Alt-Backspace (Option+Backspace, macOS word-delete-backward) at the start of the paragraph after the terminator is swallowed', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { start } = textblockRange(view.state.doc, 'Trailing paragraph.');
    placeCursor(view, start);

    const handled = pressKey(view, 'Backspace', { altKey: true });

    expect(handled).toBe(true);
    expect(markerPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(MARKDOWN);
  });

  it('Ctrl-h at the start of the paragraph after the terminator is swallowed', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { start } = textblockRange(view.state.doc, 'Trailing paragraph.');
    placeCursor(view, start);

    const handled = pressKey(view, 'h', { ctrlKey: true });

    expect(handled).toBe(true);
    expect(markerPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(MARKDOWN);
  });

  it('Ctrl-Alt-Backspace at the end of the paragraph before the terminator is swallowed', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'Only entry.');
    placeCursor(view, end);

    const handled = pressKey(view, 'Backspace', { ctrlKey: true, altKey: true });

    expect(handled).toBe(true);
    expect(markerPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(MARKDOWN);
  });

  it('Alt-Delete at the end of the paragraph before the terminator is swallowed', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'Only entry.');
    placeCursor(view, end);

    const handled = pressKey(view, 'Delete', { altKey: true });

    expect(handled).toBe(true);
    expect(markerPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(MARKDOWN);
  });

  it('Alt-d at the end of the paragraph before the terminator is swallowed', async () => {
    const e = await makeEditor(MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'Only entry.');
    placeCursor(view, end);

    const handled = pressKey(view, 'd', { altKey: true });

    expect(handled).toBe(true);
    expect(markerPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(MARKDOWN);
  });

  // Negative guard, adapted for these two specifically: `pcBaseKeymap` (what
  // prosemirror-commands resolves to in jsdom — non-mac `navigator.platform`, see this file's
  // top comment) does NOT define Alt-Backspace or Alt-Delete at all; only `macBaseKeymap` does.
  // So unlike the Delete/Ctrl-d/Shift-Backspace negative guards above, there is no base-keymap
  // join to fall through TO here — the correct, honest expectation in this environment is that
  // the keystroke goes fully unhandled (`false`) once our own predicate declines, not that it
  // gets picked up by some other plugin. This still proves what a negative guard needs to prove:
  // our own binding doesn't unconditionally swallow the key regardless of adjacency.
  it('negative guard: Alt-Backspace does not swallow the keystroke when the cursor is not adjacent to the terminator', async () => {
    const e = await makeEditor('First paragraph.\n\nSecond paragraph.');
    const view = e.ctx.get(editorViewCtx);
    const { start } = textblockRange(view.state.doc, 'Second paragraph.');
    placeCursor(view, start);

    const handled = pressKey(view, 'Backspace', { altKey: true });

    expect(handled).toBe(false);
    expect(markdownOf(e)).toBe('First paragraph.\n\nSecond paragraph.');
  });

  it('negative guard: Alt-Delete does not swallow the keystroke when the cursor is not adjacent to the terminator', async () => {
    const e = await makeEditor('First paragraph.\n\nSecond paragraph.');
    const view = e.ctx.get(editorViewCtx);
    const { end } = textblockRange(view.state.doc, 'First paragraph.');
    placeCursor(view, end);

    const handled = pressKey(view, 'Delete', { altKey: true });

    expect(handled).toBe(false);
    expect(markdownOf(e)).toBe('First paragraph.\n\nSecond paragraph.');
  });
});
