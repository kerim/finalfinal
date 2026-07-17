// @vitest-environment jsdom
// Regression tests for citation deletion: the shared transaction builder
// (citation-delete.ts), its Backspace/Delete keymap wiring (citation-plugin.ts),
// and the popup's Delete button (citation-edit-popup.ts).
//
// Uses a real Milkdown Editor instance (commonmark + gfm + citationPlugin +
// history), not a hand-built minimal Schema, so `[@key]` really parses through
// the actual remark-based citation plugin end-to-end, exactly like block-id-
// header-delete-merge.test.ts does for its own subsystem.

import { defaultValueCtx, Editor, editorViewCtx, parserCtx, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { undo } from '@milkdown/kit/prose/history';
import type { Node } from '@milkdown/kit/prose/model';
import { Slice } from '@milkdown/kit/prose/model';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { buildCitationDeleteTransaction } from '../citation-delete';
import { showCitationEditPopup } from '../citation-edit-popup';
import { citationPlugin } from '../citation-plugin';
import type { CitationAttrs } from '../citation-types';

describe('citation deletion', () => {
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
      // citationPlugin MUST be registered before commonmark/gfm to parse [@citekey]
      // syntax — mirrors the ordering comment/rule in main.ts.
      .use(citationPlugin)
      .use(commonmark)
      .use(gfm)
      .use(history)
      .create();
    editor = e;
    return e;
  }

  /** All citation node positions in the document, in document order. */
  function citationPositions(doc: Node): number[] {
    const positions: number[] = [];
    doc.descendants((node, pos) => {
      if (node.type.name === 'citation') positions.push(pos);
    });
    return positions;
  }

  // getMarkdown() always appends a trailing newline; strip only that (never
  // leading/trailing spaces, which some assertions below check deliberately).
  function markdownOf(e: Editor): string {
    return e.action(getMarkdown()).replace(/\n+$/, '');
  }

  function placeCursor(view: EditorView, pos: number): void {
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)));
  }

  // Invokes the real handleKeyDown dispatch path — view.someProp('handleKeyDown', ...)
  // is exactly what ProseMirror's own native DOM keydown listener calls internally
  // (see prosemirror-view's input.ts), so this exercises every registered plugin's
  // handleKeyDown (base keymap, heading's keymap, ours) in real registration order,
  // stopping at the first one that returns true — the same precedence a real
  // keypress would hit. Chosen over dispatching a raw DOM KeyboardEvent on view.dom:
  // that would funnel through this exact same internal call, but adds jsdom
  // event-dispatch and IME/composition-guard variables with no added fidelity.
  // Also chosen over inline-code-cursor.test.ts's technique of grabbing one
  // specific Plugin instance directly — with multiple registered keymaps here
  // (base keymap, heading, ours), someProp's real precedence order matters and a
  // single hand-picked plugin reference can't reproduce it.
  function pressKey(view: EditorView, key: string): boolean {
    const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true });
    return !!view.someProp('handleKeyDown', (f) => f(view, event));
  }

  // ---- 1-4: shared buildCitationDeleteTransaction() ----

  it('mid-paragraph citation: deletion collapses the doubled space (single space survives)', async () => {
    const e = await makeEditor('See [@smith2023] for details.');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = citationPositions(view.state.doc);

    const tr = buildCitationDeleteTransaction(view.state, pos);
    expect(tr).not.toBeNull();
    view.dispatch(tr!);

    expect(citationPositions(view.state.doc)).toHaveLength(0);
    expect(markdownOf(e)).toBe('See for details.');
  });

  it('citation at start of paragraph: no cleanup, exactly one leading space preserved', async () => {
    const e = await makeEditor('[@smith2023] for details.');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = citationPositions(view.state.doc);

    const tr = buildCitationDeleteTransaction(view.state, pos);
    expect(tr).not.toBeNull();
    view.dispatch(tr!);

    expect(citationPositions(view.state.doc)).toHaveLength(0);
    // Check the actual document text (semantic, exact-character check) rather than
    // the raw markdown string: remark-stringify escapes a paragraph-leading space
    // as the HTML entity `&#x20;` (still exactly one space's worth of content, just
    // not a literal space byte in the serialized source) so a literal-string
    // equality check against getMarkdown() would be asserting on that escaping
    // quirk rather than on the actual leading-space-preserved behavior under test.
    expect(view.state.doc.textContent).toBe(' for details.');
    expect(markdownOf(e)).toBe('&#x20;for details.');
  });

  it('citation at end of paragraph: no doubled/missing space', async () => {
    const e = await makeEditor('See [@smith2023].');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = citationPositions(view.state.doc);

    const tr = buildCitationDeleteTransaction(view.state, pos);
    expect(tr).not.toBeNull();
    view.dispatch(tr!);

    expect(citationPositions(view.state.doc)).toHaveLength(0);
    expect(markdownOf(e)).toBe('See .');
  });

  it('stale position (not actually a citation) returns null', async () => {
    const e = await makeEditor('See [@smith2023] for details.');
    const view = e.ctx.get(editorViewCtx);

    // Position 0 is the document boundary itself, never a citation node.
    const tr = buildCitationDeleteTransaction(view.state, 0);
    expect(tr).toBeNull();
  });

  // ---- 5-7: Backspace/Delete keymap ----

  it('Backspace immediately after a mid-paragraph citation removes it in one press and collapses the space', async () => {
    const e = await makeEditor('See [@smith2023] for details.');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = citationPositions(view.state.doc);
    const node = view.state.doc.nodeAt(pos)!;
    placeCursor(view, pos + node.nodeSize); // cursor right after the citation

    const handled = pressKey(view, 'Backspace');

    expect(handled).toBe(true);
    expect(citationPositions(view.state.doc)).toHaveLength(0);
    expect(markdownOf(e)).toBe('See for details.');
  });

  it('Delete immediately before a mid-paragraph citation removes it in one press and collapses the space', async () => {
    const e = await makeEditor('See [@smith2023] for details.');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = citationPositions(view.state.doc);
    placeCursor(view, pos); // cursor right before the citation

    const handled = pressKey(view, 'Delete');

    expect(handled).toBe(true);
    expect(citationPositions(view.state.doc)).toHaveLength(0);
    expect(markdownOf(e)).toBe('See for details.');
  });

  it('keymap is inert when the cursor is not adjacent to a citation (negative guard)', async () => {
    const e = await makeEditor('See [@smith2023] for details.');
    const view = e.ctx.get(editorViewCtx);
    // Cursor inside "details." — nowhere near the citation on either side.
    placeCursor(view, view.state.doc.content.size - 2);

    const handled = pressKey(view, 'Backspace');

    // Also prove the keystroke actually fell through instead of being silently
    // swallowed: at this cursor, no plugin in the handleKeyDown chain — not the
    // citation keymap, not the base keymap (deleteSelection/joinBackward/
    // selectNodeBackward, none of which apply to a mid-text empty selection) —
    // should claim to have handled it. (Plain single-character deletion for an
    // empty mid-text selection isn't itself a ProseMirror keymap command; real
    // browsers do it via native contenteditable editing, which is out of scope
    // for this handleKeyDown-only harness.) If the citation keymap ever
    // regressed to treating this position as citation-adjacent, it would
    // dispatch a transaction and return true here instead.
    expect(handled).toBe(false);
    expect(citationPositions(view.state.doc)).toHaveLength(1);
  });

  // ---- 8: popup Delete button ----

  it('popup Delete button removes the citation and hides the popup', async () => {
    const e = await makeEditor('See [@smith2023] for details.');
    const view = e.ctx.get(editorViewCtx);
    const [pos] = citationPositions(view.state.doc);
    const attrs = view.state.doc.nodeAt(pos)!.attrs as CitationAttrs;

    // showCitationEditPopup takes a live getPos closure (matching the NodeView
    // contract), not a one-time position snapshot. `() => pos` here is a fixed
    // closure because this specific test doesn't move the document afterward —
    // the position-drift scenario is exercised by the dedicated tests below.
    showCitationEditPopup(() => pos, view, attrs);

    const popup = document.querySelector('.ff-citation-edit-popup') as HTMLElement | null;
    expect(popup).toBeTruthy();
    expect(popup!.style.display).toBe('block');

    const deleteButton = document.querySelector('.ff-citation-delete-button') as HTMLElement | null;
    expect(deleteButton).toBeTruthy();
    deleteButton!.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));

    expect(citationPositions(view.state.doc)).toHaveLength(0);
    expect(popup!.style.display).toBe('none');
  });

  // ---- 8b-8e: position drift from a REAL background resync ----
  //
  // These are the regression tests for the actual bug this fix addresses.
  // citation-edit-popup.ts used to cache the citation's document position as a
  // one-time captured integer (`editingNodePos: number | null`). Any full-document
  // replace between popup-open and the user's action — exactly what
  // setContentWithBlockIds performs in the background (bibliography resync,
  // LanguageTool, block realignment) via `view.state.tr.replace(0, docSize, new
  // Slice(doc.content, 0, 0))` — shifts every position after the point where
  // earlier content changed length. The popup's stale cached integer would then
  // point at the wrong node (or nothing), silently no-op'ing Delete/commit.
  //
  // Each test below opens the popup via a REAL click on the citation NodeView's
  // mounted DOM element (exercising citation-plugin.ts's actual click handler,
  // which passes the NodeView's live getPos() closure — not a snapshot — into
  // showCitationEditPopup), then performs a real setContentWithBlockIds-style
  // full-document replace: re-parse a brand-new markdown string (fresh Node
  // objects, not shared references with the old doc — exactly like
  // api-content.ts's `parser(markdown)`) and dispatch
  // `tr.replace(0, docSize, new Slice(newDoc.content, 0, 0))`.
  //
  // Empirically verified against this exact schema/plugin stack (not assumed):
  // ProseMirror's view-reconciliation reuses a paragraph's own NodeViewDesc
  // whenever the *count* of top-level siblings is unchanged (content growing
  // *within* an existing paragraph, or an earlier sibling paragraph simply
  // growing longer) — and it's specifically THIS reuse that lets the
  // citation's own NodeView (nested inside that paragraph) survive with its
  // getPos() closure intact, now reporting the new, shifted position. Reuse
  // does NOT happen when a brand-new whole paragraph is inserted ahead of it
  // (changing the top-level sibling count) — that cascades into recreating
  // downstream paragraphs (and the citation's NodeView with them) from
  // scratch, which is covered separately below as its own case.
  const RESYNC_BASE_MARKDOWN = 'See [@smith2023] for details.';
  // Same paragraph, same citation, but with substantially more text BEFORE the
  // citation — this is what genuinely drifts the citation's position while
  // letting ProseMirror reuse its NodeView (see comment above).
  const RESYNC_GROWN_MARKDOWN = 'See right here, in a lot more detail than before, [@smith2023] for details.';

  /** Mirrors api-content.ts's setContentWithBlockIds: parse new markdown and
   *  dispatch a real tr.replace(0, docSize, new Slice(newDoc.content, 0, 0)). */
  function simulateBackgroundResync(e: Editor, newMarkdown: string): void {
    const view = e.ctx.get(editorViewCtx);
    const parser = e.ctx.get(parserCtx);
    const newDoc = parser(newMarkdown);
    expect(newDoc).toBeTruthy();
    const docSize = view.state.doc.content.size;
    view.dispatch(view.state.tr.replace(0, docSize, new Slice(newDoc!.content, 0, 0)));
  }

  function clickCitationDom(): void {
    const citeDom = document.querySelector('.ff-citation') as HTMLElement | null;
    expect(citeDom).toBeTruthy();
    citeDom!.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  }

  it('popup Delete button removes the citation at its NEW position after a background resync shifts it', async () => {
    const e = await makeEditor(RESYNC_BASE_MARKDOWN);
    const view = e.ctx.get(editorViewCtx);
    const posBefore = citationPositions(view.state.doc)[0];
    expect(posBefore).toBeDefined();

    clickCitationDom();
    const popup = document.querySelector('.ff-citation-edit-popup') as HTMLElement | null;
    expect(popup).toBeTruthy();
    expect(popup!.style.display).toBe('block');

    simulateBackgroundResync(e, RESYNC_GROWN_MARKDOWN);

    const posAfter = citationPositions(view.state.doc)[0];
    expect(posAfter).toBeDefined();
    // Prove the resync actually moved the citation — otherwise this test would
    // not be distinguishing the fix from the old stale-integer behavior at all.
    expect(posAfter).not.toBe(posBefore);
    expect(posAfter!).toBeGreaterThan(posBefore!);

    // Popup is still open; clicking Delete now must act on the CURRENT
    // (shifted) position, not the one captured when the popup opened.
    expect(popup!.style.display).toBe('block');
    const deleteButton = document.querySelector('.ff-citation-delete-button') as HTMLElement | null;
    expect(deleteButton).toBeTruthy();
    deleteButton!.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));

    expect(citationPositions(view.state.doc)).toHaveLength(0);
    expect(popup!.style.display).toBe('none');
    const md = markdownOf(e);
    expect(md).toContain('a lot more detail than before');
    expect(md).not.toContain('smith2023');
  });

  it('popup commit (Enter) edits the citation at its NEW position after a background resync shifts it', async () => {
    const e = await makeEditor(RESYNC_BASE_MARKDOWN);

    clickCitationDom();
    const popup = document.querySelector('.ff-citation-edit-popup') as HTMLElement | null;
    const input = document.querySelector('.ff-citation-edit-input') as HTMLInputElement | null;
    expect(popup).toBeTruthy();
    expect(input).toBeTruthy();
    expect(popup!.style.display).toBe('block');

    simulateBackgroundResync(e, RESYNC_GROWN_MARKDOWN);

    // Edit the citekey and commit via Enter — exercises commitEdit()'s live re-resolve.
    input!.value = '[@jones2024]';
    input!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));

    expect(popup!.style.display).toBe('none');
    const md = markdownOf(e);
    expect(md).toContain('jones2024');
    expect(md).not.toContain('smith2023');
  });

  it('popup closes gracefully (no throw, no corruption) when the incoming resync removes the citation entirely', async () => {
    const e = await makeEditor(RESYNC_BASE_MARKDOWN);
    const view = e.ctx.get(editorViewCtx);

    clickCitationDom();
    const popup = document.querySelector('.ff-citation-edit-popup') as HTMLElement | null;
    expect(popup).toBeTruthy();
    expect(popup!.style.display).toBe('block');

    // Incoming resync content has no citation at all (e.g. removed by whatever
    // produced this replace) — the NodeView is genuinely destroyed, not reused,
    // so its getPos() closure returns undefined (prosemirror-view's documented
    // contract for a removed node view).
    simulateBackgroundResync(e, 'A completely different document with no citations left in it at all.');
    expect(citationPositions(view.state.doc)).toHaveLength(0);

    const deleteButton = document.querySelector('.ff-citation-delete-button') as HTMLElement | null;
    expect(deleteButton).toBeTruthy();
    expect(() => {
      deleteButton!.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    }).not.toThrow();

    expect(popup!.style.display).toBe('none');
    expect(markdownOf(e)).toBe('A completely different document with no citations left in it at all.');
  });

  it('popup closes gracefully (no throw, no corruption) when an unrelated structural change invalidates the NodeView even though the citation logically still exists', async () => {
    // Distinct from the previous case: here the citation ITSELF is untouched
    // (same citekey, still present in the new document) but a brand-new
    // paragraph is inserted ahead of its paragraph, changing the top-level
    // sibling count. Empirically, ProseMirror's reconciliation does NOT reuse
    // the citation's NodeView across that shape of change (unlike the
    // same-paragraph-growth case above) — it gets destroyed and a fresh
    // NodeView is created for the citation at its new position. The old
    // getPos() closure the popup is still holding is therefore invalidated
    // (returns undefined) even though the citation still exists. The fix must
    // still close gracefully rather than throwing or corrupting anything —
    // and, crucially, must NOT delete the (still-present, just differently-
    // instanced) citation out of the document.
    const e = await makeEditor(`Padding paragraph here.\n\n${RESYNC_BASE_MARKDOWN}`);
    const view = e.ctx.get(editorViewCtx);

    clickCitationDom();
    const popup = document.querySelector('.ff-citation-edit-popup') as HTMLElement | null;
    expect(popup).toBeTruthy();
    expect(popup!.style.display).toBe('block');

    simulateBackgroundResync(e, `Brand new inserted paragraph.\n\nPadding paragraph here.\n\n${RESYNC_BASE_MARKDOWN}`);

    const deleteButton = document.querySelector('.ff-citation-delete-button') as HTMLElement | null;
    expect(deleteButton).toBeTruthy();
    expect(() => {
      deleteButton!.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    }).not.toThrow();

    expect(popup!.style.display).toBe('none');
    // The citation must still be intact — the stale-getPos guard must not
    // have corrupted or deleted an unrelated node in the new document.
    expect(citationPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toContain('smith2023');
  });

  // ---- 8f-8g: identity guard — a DIFFERENT citation occupying the SAME position ----
  //
  // Distinct from the position-drift cases above (8b/8c: the SAME citation moves
  // to a NEW position) and from the "genuinely gone" cases (8d/8e: NO citation is
  // left at all). Here, citation A is opened, then something (e.g. a concurrent
  // edit) rewrites the node at that EXACT position into a DIFFERENT citation B —
  // same slot, same type, different citekey/attrs, NO position drift whatsoever.
  // A type-only guard (`node.type.name === 'citation'`, what buildCitationDelete
  // Transaction's own check and the pre-fix commitEdit() check both were) would
  // wrongly treat this as "the citation is still here, proceed" and act on B as if
  // it were A. The fix's identity guard (resolveLiveCitation()'s Node.sameMarkup()
  // check against the node captured at popup-open time) must catch this and close
  // gracefully instead of touching B.
  const CITATION_B_ATTRS = {
    citekeys: 'jones2024',
    locators: '[]',
    prefix: '',
    suffix: '',
    suppressAuthor: false,
    rawSyntax: '[@jones2024]',
  };

  it('Delete button: leaves a DIFFERENT citation untouched when it now occupies the originally-opened citation’s exact position', async () => {
    const e = await makeEditor(RESYNC_BASE_MARKDOWN);
    const view = e.ctx.get(editorViewCtx);

    clickCitationDom(); // opens popup on citation A (smith2023)
    const popup = document.querySelector('.ff-citation-edit-popup') as HTMLElement | null;
    expect(popup).toBeTruthy();
    expect(popup!.style.display).toBe('block');

    const [pos] = citationPositions(view.state.doc);
    // Citation B lands at the EXACT SAME position (no drift at all) — the
    // popup's live getPos() closure still resolves to this same pos, and the
    // node there is still type 'citation'. Exactly the case a type-only guard
    // would wrongly wave through.
    view.dispatch(view.state.tr.setNodeMarkup(pos, undefined, CITATION_B_ATTRS));
    expect(citationPositions(view.state.doc)).toEqual([pos]);

    const deleteButton = document.querySelector('.ff-citation-delete-button') as HTMLElement | null;
    expect(deleteButton).toBeTruthy();
    deleteButton!.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));

    // Citation B must survive, completely untouched, and the popup must simply close.
    expect(citationPositions(view.state.doc)).toHaveLength(1);
    expect(popup!.style.display).toBe('none');
    const md = markdownOf(e);
    expect(md).toContain('jones2024');
    expect(md).not.toContain('smith2023');
  });

  it('commitEdit() (Enter): leaves a DIFFERENT citation untouched, applying no edit, when it now occupies the originally-opened citation’s exact position', async () => {
    const e = await makeEditor(RESYNC_BASE_MARKDOWN);
    const view = e.ctx.get(editorViewCtx);

    clickCitationDom(); // opens popup on citation A (smith2023)
    const popup = document.querySelector('.ff-citation-edit-popup') as HTMLElement | null;
    const input = document.querySelector('.ff-citation-edit-input') as HTMLInputElement | null;
    expect(popup).toBeTruthy();
    expect(input).toBeTruthy();
    expect(popup!.style.display).toBe('block');

    const [pos] = citationPositions(view.state.doc);
    view.dispatch(view.state.tr.setNodeMarkup(pos, undefined, CITATION_B_ATTRS));
    expect(citationPositions(view.state.doc)).toEqual([pos]);

    // The user's in-flight edit was typed against citation A, before B took its
    // slot. Committing it must NOT be applied to B.
    input!.value = '[@johnson2025]';
    input!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));

    expect(popup!.style.display).toBe('none');
    const md = markdownOf(e);
    expect(md).toContain('jones2024');
    expect(md).not.toContain('johnson2025');
    expect(md).not.toContain('smith2023');
  });

  // ---- 9: undo ----

  it('undo restores the citation AND the collapsed space in one step (proves one atomic transaction)', async () => {
    const e = await makeEditor('See [@smith2023] for details.');
    const view = e.ctx.get(editorViewCtx);
    const original = markdownOf(e);
    const [pos] = citationPositions(view.state.doc);

    const tr = buildCitationDeleteTransaction(view.state, pos);
    expect(tr).not.toBeNull();
    view.dispatch(tr!);
    expect(citationPositions(view.state.doc)).toHaveLength(0);

    const undone = undo(view.state, view.dispatch);
    expect(undone).toBe(true);
    expect(citationPositions(view.state.doc)).toHaveLength(1);
    expect(markdownOf(e)).toBe(original);
  });
});
