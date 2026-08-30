// @vitest-environment jsdom
// Regression tests for the bibliography-end terminator's Enter-key insertion-boundary fix in
// anchor-plugin.ts (`bibliographyEndEnterKeymap` / `bibliographyEndInsertionPoint`) — the
// CodeMirror (Source Mode) analogue of
// web/milkdown/src/__tests__/bibliography-end-marker-plugin.test.ts's Enter-handler coverage
// for the Milkdown (WYSIWYG) side. See anchor-plugin.ts's own doc comment for the underlying
// bug: a cursor at the end of the last bibliography entry's line, followed by Enter, must
// land the new line AFTER the hidden terminator instead of before it, or the next
// full-document reparse (Source Mode's debounced re-parse, or the reparse that runs
// immediately before every PDF export) re-flags the user's new text as bibliography content —
// the exact orphan-flag bug this whole mechanism exists to close.
//
// Uses a real CodeMirror EditorView with anchorPlugin() registered as an extension (not a bare
// EditorState) and runScopeHandlers() to dispatch a real "Enter" keydown through CodeMirror's
// own keymap-resolution path (the same path production's internal `keydown` DOM handler uses —
// see @codemirror/view's `handleKeyEvents`) — the CM6 analogue of the Milkdown suite's
// `pressKey` helper, which uses ProseMirror's `someProp('handleKeyDown', ...)`.

import { defaultKeymap } from '@codemirror/commands';
import { EditorState, RangeSetBuilder } from '@codemirror/state';
import { Decoration, EditorView, keymap, runScopeHandlers } from '@codemirror/view';
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import {
  anchorPlugin,
  bibliographyEndInsertionPoint,
  isBibliographyEndMarkerAdjacent,
  isBibliographyEndMarkerLine,
} from '../anchor-plugin';

const TERMINATOR = '<!-- ::auto-bibliography-end:: -->';

describe('bibliography-end terminator Enter-key insertion-boundary fix', () => {
  let view: EditorView | null = null;

  afterEach(() => {
    if (view) {
      view.destroy();
      view = null;
    }
  });

  function makeEditor(doc: string): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const v = new EditorView({
      state: EditorState.create({ doc, extensions: [anchorPlugin()] }),
      parent: div,
    });
    view = v;
    return v;
  }

  /** Real key-resolution dispatch path — mirrors the Milkdown suite's `pressKey` helper. */
  function pressKey(v: EditorView, key: string): boolean {
    const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true });
    return runScopeHandlers(v, event, 'editor');
  }

  // ---- bibliographyEndInsertionPoint: the predicate behind the keymap binding ----
  // Exported specifically so it can be exercised directly, mirroring how the Milkdown
  // suite's `isBibliographyEndMarkerAdjacent` predicate is tested independently of the real
  // keymap dispatch.

  describe('bibliographyEndInsertionPoint', () => {
    it('returns the position right after the terminator line when the cursor is at the end of the entry line immediately before it', () => {
      const doc = `# References\n\nOnly entry.\n\n${TERMINATOR}\n\nTrailing paragraph.`;
      const state = EditorState.create({ doc });
      const cursorPos = doc.indexOf('Only entry.') + 'Only entry.'.length;
      const terminatorLineTo = doc.indexOf(TERMINATOR) + TERMINATOR.length;

      expect(bibliographyEndInsertionPoint(state, cursorPos)).toBe(terminatorLineTo);
    });

    it('still returns the insertion point when the terminator is the very last line (no trailing content)', () => {
      const doc = `# References\n\nOnly entry.\n\n${TERMINATOR}`;
      const state = EditorState.create({ doc });
      const cursorPos = doc.indexOf('Only entry.') + 'Only entry.'.length;

      expect(bibliographyEndInsertionPoint(state, cursorPos)).toBe(doc.length);
    });

    it('skips multiple consecutive blank lines between the entry and the terminator', () => {
      const doc = `Only entry.\n\n\n\n${TERMINATOR}\n\nTrailing paragraph.`;
      const state = EditorState.create({ doc });
      const cursorPos = doc.indexOf('Only entry.') + 'Only entry.'.length;
      const terminatorLineTo = doc.indexOf(TERMINATOR) + TERMINATOR.length;

      expect(bibliographyEndInsertionPoint(state, cursorPos)).toBe(terminatorLineTo);
    });

    it('returns null when the cursor is not at the end of its line', () => {
      const doc = `Only entry.\n\n${TERMINATOR}\n\nTrailing paragraph.`;
      const state = EditorState.create({ doc });
      const cursorPos = doc.indexOf('entry') + 2; // mid-word, well before end of line

      expect(bibliographyEndInsertionPoint(state, cursorPos)).toBeNull();
    });

    it('returns null when the cursor is not on the line immediately before the terminator', () => {
      const doc = `# References\n\nOnly entry.\n\n${TERMINATOR}\n\nTrailing paragraph.`;
      const state = EditorState.create({ doc });
      const cursorPos = doc.indexOf('# References') + '# References'.length;

      expect(bibliographyEndInsertionPoint(state, cursorPos)).toBeNull();
    });

    it('returns null when the document has no terminator at all', () => {
      const doc = 'First paragraph.\n\nSecond paragraph.';
      const state = EditorState.create({ doc });
      const cursorPos = doc.indexOf('First paragraph.') + 'First paragraph.'.length;

      expect(bibliographyEndInsertionPoint(state, cursorPos)).toBeNull();
    });
  });

  // ---- Real keymap dispatch: bibliographyEndEnterKeymap via anchorPlugin() ----

  it('Enter at the end of the last bibliography entry inserts the new line AFTER the terminator, not before, with a trailing paragraph following', () => {
    const doc = `# References\n\nOnly entry.\n\n${TERMINATOR}\n\nTrailing paragraph.`;
    const v = makeEditor(doc);
    const cursorPos = doc.indexOf('Only entry.') + 'Only entry.'.length;
    v.dispatch({ selection: { anchor: cursorPos } });

    const handled = pressKey(v, 'Enter');

    expect(handled).toBe(true);
    const text = v.state.doc.toString();
    expect(text).toBe(`# References\n\nOnly entry.\n\n${TERMINATOR}\n\n\n\nTrailing paragraph.`);

    // The terminator itself is untouched, and the cursor now sits on its own empty line —
    // strictly after the terminator, strictly before "Trailing paragraph.".
    const terminatorIndex = text.indexOf(TERMINATOR);
    const trailingIndex = text.indexOf('Trailing paragraph.');
    expect(v.state.selection.main.empty).toBe(true);
    expect(v.state.selection.main.head).toBeGreaterThan(terminatorIndex + TERMINATOR.length);
    expect(v.state.selection.main.head).toBeLessThan(trailingIndex);
  });

  it('Enter at the end of the last bibliography entry when the terminator is the very last line still lands the cursor after it, ready to type a new block', () => {
    const doc = `# References\n\nOnly entry.\n\n${TERMINATOR}`;
    const v = makeEditor(doc);
    const cursorPos = doc.indexOf('Only entry.') + 'Only entry.'.length;
    v.dispatch({ selection: { anchor: cursorPos } });

    const handled = pressKey(v, 'Enter');

    expect(handled).toBe(true);
    const text = v.state.doc.toString();
    expect(text).toBe(`# References\n\nOnly entry.\n\n${TERMINATOR}\n\n`);
    expect(v.state.selection.main.head).toBe(text.length);

    // Typing right after this Enter lands the new text in its own block, after the
    // terminator — exactly the scenario this fix exists for.
    v.dispatch({ changes: { from: v.state.selection.main.head, insert: 'New text.' } });
    expect(v.state.doc.toString()).toBe(`# References\n\nOnly entry.\n\n${TERMINATOR}\n\nNew text.`);
  });

  it('Prec.highest wins over an earlier-registered competing Enter binding, mirroring main.ts registration order', () => {
    // main.ts registers `keymap.of([...defaultKeymap, ...])` (unwrapped, no Prec wrapper) BEFORE
    // `anchorPlugin()` in its extension array. Without bibliographyEndEnterKeymap's Prec.highest
    // wrapper, plain array order would let defaultKeymap's earlier-registered
    // `insertNewlineAndIndent` win this Enter and split the line in place before the terminator —
    // reproducing the exact orphan-flag bug this whole mechanism exists to close. The other
    // dispatch tests above only register anchorPlugin() in isolation, so none of them prove
    // Prec.highest actually beats a competing binding registered earlier in the array — this one
    // does, by including that competing binding and matching production's registration order.
    const doc = `# References\n\nOnly entry.\n\n${TERMINATOR}\n\nTrailing paragraph.`;
    const div = document.createElement('div');
    document.body.appendChild(div);
    const v = new EditorView({
      state: EditorState.create({
        doc,
        // Order matches main.ts: the unwrapped default keymap registers first, anchorPlugin()
        // (which internally wraps its Enter binding in Prec.highest) registers second.
        extensions: [keymap.of([...defaultKeymap]), anchorPlugin()],
      }),
      parent: div,
    });
    view = v;

    const cursorPos = doc.indexOf('Only entry.') + 'Only entry.'.length;
    v.dispatch({ selection: { anchor: cursorPos } });

    const handled = pressKey(v, 'Enter');

    expect(handled).toBe(true);
    const text = v.state.doc.toString();
    expect(text).toBe(`# References\n\nOnly entry.\n\n${TERMINATOR}\n\n\n\nTrailing paragraph.`);

    // Same boundary assertions as the isolated dispatch test above: the terminator is untouched
    // and the cursor sits strictly after it, strictly before "Trailing paragraph." — proof the
    // bibliography-boundary binding won the precedence race, not defaultKeymap's default split.
    const terminatorIndex = text.indexOf(TERMINATOR);
    const trailingIndex = text.indexOf('Trailing paragraph.');
    expect(v.state.selection.main.empty).toBe(true);
    expect(v.state.selection.main.head).toBeGreaterThan(terminatorIndex + TERMINATOR.length);
    expect(v.state.selection.main.head).toBeLessThan(trailingIndex);
  });

  it('negative guard: Enter elsewhere in the document is not intercepted when there is no terminator nearby', () => {
    const doc = 'First paragraph.\n\nSecond paragraph.';
    const v = makeEditor(doc);
    const cursorPos = doc.indexOf('First paragraph.') + 'First paragraph.'.length;
    v.dispatch({ selection: { anchor: cursorPos } });

    // No other Enter-handling keymap is registered in this isolated extension set (main.ts's
    // defaultKeymap lives separately, outside anchorPlugin()), so an honest "not our concern"
    // result here is `false`, not a fallthrough insert — mirroring the Milkdown suite's
    // Alt-Backspace/Alt-Delete negative guards for the same reason.
    const handled = pressKey(v, 'Enter');

    expect(handled).toBe(false);
    expect(v.state.doc.toString()).toBe(doc);
  });
});

// Regression tests for the bibliography-end terminator's Delete/Backspace protection
// (`bibliographyEndDeleteKeymap` / `isBibliographyEndMarkerAdjacent`) — the CodeMirror
// (Source Mode) analogue of bibliography-end-marker-plugin.ts's `bibliographyEndDeleteKeymap`
// coverage for the Milkdown (WYSIWYG) side. See anchor-plugin.ts's own doc comment above that
// keymap for the underlying mechanism: @codemirror/commands' delete-family commands
// (deleteCharBackward/Forward, deleteGroupBackward/Forward, deleteLineBoundaryBackward/Forward,
// deleteToLineEnd) all snap a naive one-step deletion target to the far edge of any
// `EditorView.atomicRanges` region the step would otherwise land inside of — so, unguarded, a
// single Backspace/Delete press adjacent to the hidden terminator destroys the terminator's
// entire text in one keystroke.
describe('bibliography-end terminator Delete/Backspace protection', () => {
  const DOC = `Only entry.\n\n${TERMINATOR}\n\nTrailing paragraph.`;
  const TERM_FROM = DOC.indexOf(TERMINATOR);
  const TERM_TO = TERM_FROM + TERMINATOR.length;

  // ---- isBibliographyEndMarkerAdjacent: the shared predicate behind every guarded key ----

  describe('isBibliographyEndMarkerAdjacent', () => {
    it('is true for "after" (false for "before") when the cursor sits exactly where the terminator begins', () => {
      const state = EditorState.create({ doc: DOC, selection: { anchor: TERM_FROM } });

      expect(isBibliographyEndMarkerAdjacent(state, 'after')).toBe(true);
      expect(isBibliographyEndMarkerAdjacent(state, 'before')).toBe(false);
    });

    it('is true for "before" (false for "after") when the cursor sits exactly where the terminator ends', () => {
      const state = EditorState.create({ doc: DOC, selection: { anchor: TERM_TO } });

      expect(isBibliographyEndMarkerAdjacent(state, 'before')).toBe(true);
      expect(isBibliographyEndMarkerAdjacent(state, 'after')).toBe(false);
    });

    it('is false in both directions one character inside either boundary — not exactly adjacent', () => {
      const justInside = EditorState.create({ doc: DOC, selection: { anchor: TERM_FROM + 1 } });
      expect(isBibliographyEndMarkerAdjacent(justInside, 'after')).toBe(false);
      expect(isBibliographyEndMarkerAdjacent(justInside, 'before')).toBe(false);

      const justInsideEnd = EditorState.create({ doc: DOC, selection: { anchor: TERM_TO - 1 } });
      expect(isBibliographyEndMarkerAdjacent(justInsideEnd, 'after')).toBe(false);
      expect(isBibliographyEndMarkerAdjacent(justInsideEnd, 'before')).toBe(false);
    });

    it('is false in both directions for a non-empty selection, even one whose edge touches a boundary', () => {
      const state = EditorState.create({ doc: DOC, selection: { anchor: TERM_FROM, head: TERM_FROM + 3 } });

      expect(state.selection.main.empty).toBe(false);
      expect(isBibliographyEndMarkerAdjacent(state, 'after')).toBe(false);
      expect(isBibliographyEndMarkerAdjacent(state, 'before')).toBe(false);
    });

    it('is false in both directions when the document has no terminator at all', () => {
      const doc = 'First paragraph.\n\nSecond paragraph.';
      const state = EditorState.create({ doc, selection: { anchor: doc.indexOf('Second') } });

      expect(isBibliographyEndMarkerAdjacent(state, 'after')).toBe(false);
      expect(isBibliographyEndMarkerAdjacent(state, 'before')).toBe(false);
    });
  });

  // ---- CURRENT BUG reproduction: no bibliographyEndDeleteKeymap installed ----
  //
  // This block deliberately does NOT use anchorPlugin() — it wires up only the bare
  // EditorView.atomicRanges mechanism anchorDecorationPlugin/atomicAnchorRanges produce
  // internally (a Decoration.replace({}) range over the terminator's own span), plus
  // @codemirror/commands' real, unmodified defaultKeymap — to prove the danger described in
  // anchor-plugin.ts's doc comment exists independent of, and prior to,
  // bibliographyEndDeleteKeymap: without that keymap, a single Backspace/Delete press whose
  // naive one-character target lands inside the atomic (hidden) terminator gets silently
  // expanded by CodeMirror's own `skipAtomic` helper into a deletion of the ENTIRE terminator.
  describe('CURRENT BUG reproduction (no bibliographyEndDeleteKeymap installed)', () => {
    let bugView: EditorView | null = null;

    afterEach(() => {
      if (bugView) {
        bugView.destroy();
        bugView = null;
      }
    });

    function makeUnguardedEditor(doc: string, atomicFrom: number, atomicTo: number): EditorView {
      const div = document.createElement('div');
      document.body.appendChild(div);
      const atomicOnly = EditorView.atomicRanges.of(() => {
        const builder = new RangeSetBuilder<Decoration>();
        builder.add(atomicFrom, atomicTo, Decoration.replace({}));
        return builder.finish();
      });
      const v = new EditorView({
        state: EditorState.create({ doc, extensions: [keymap.of([...defaultKeymap]), atomicOnly] }),
        parent: div,
      });
      bugView = v;
      return v;
    }

    function pressKey(v: EditorView, key: string): boolean {
      const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true });
      return runScopeHandlers(v, event, 'editor');
    }

    it('Backspace immediately after the hidden terminator deletes the terminator entirely, in one keystroke', () => {
      const v = makeUnguardedEditor(DOC, TERM_FROM, TERM_TO);
      v.dispatch({ selection: { anchor: TERM_TO } });

      const handled = pressKey(v, 'Backspace');

      // deleteCharBackward DID run and reported itself as handled — that IS the bug: it ran
      // unguarded and silently destroyed the terminator, rather than refusing the keystroke.
      expect(handled).toBe(true);
      expect(v.state.doc.toString()).toBe('Only entry.\n\n\n\nTrailing paragraph.');
      expect(v.state.doc.toString()).not.toContain(TERMINATOR);
    });

    it('Delete immediately before the hidden terminator deletes the terminator entirely, in one keystroke', () => {
      const v = makeUnguardedEditor(DOC, TERM_FROM, TERM_TO);
      v.dispatch({ selection: { anchor: TERM_FROM } });

      const handled = pressKey(v, 'Delete');

      expect(handled).toBe(true);
      expect(v.state.doc.toString()).toBe('Only entry.\n\n\n\nTrailing paragraph.');
      expect(v.state.doc.toString()).not.toContain(TERMINATOR);
    });
  });

  // ---- Fixed: bibliographyEndDeleteKeymap via anchorPlugin() ----

  describe('bibliographyEndDeleteKeymap dispatch (fixed)', () => {
    let view: EditorView | null = null;

    afterEach(() => {
      if (view) {
        view.destroy();
        view = null;
      }
    });

    function makeEditor(doc: string): EditorView {
      const div = document.createElement('div');
      document.body.appendChild(div);
      const v = new EditorView({
        state: EditorState.create({ doc, extensions: [anchorPlugin()] }),
        parent: div,
      });
      view = v;
      return v;
    }

    /** Real key-resolution dispatch path, with optional modifier flags for Ctrl-/Alt- bindings. */
    function pressKey(v: EditorView, key: string, modifiers: Partial<KeyboardEventInit> = {}): boolean {
      const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...modifiers });
      return runScopeHandlers(v, event, 'editor');
    }

    // Forward-direction bindings — cursor placed exactly where the terminator BEGINS.
    it.each<[string, string, Partial<KeyboardEventInit>]>([
      ['Delete', 'Delete', {}],
      ['Ctrl-d', 'd', { ctrlKey: true }],
      ['Alt-Delete', 'Delete', { altKey: true }],
      // Mod-Delete: jsdom's navigator.platform resolves CodeMirror's "key"-fallback platform
      // (not "mac"), under which `Mod-` normalizes to `Ctrl-`, not `Meta-`/Cmd — dispatching
      // ctrlKey:true matches jsdom's OWN resolution of this binding, proving the registration is
      // real and reachable in this test environment (not a typo'd string nobody calls), the same
      // way the existing Enter-keymap suite's Mod-key caveats already establish for this file.
      // It does not directly exercise the Meta-key event macOS itself would dispatch.
      ['Mod-Delete (jsdom: Ctrl-Delete)', 'Delete', { ctrlKey: true }],
      ['Ctrl-k', 'k', { ctrlKey: true }],
    ])('%s at the terminator start is swallowed — document unchanged', (_name, key, modifiers) => {
      const v = makeEditor(DOC);
      v.dispatch({ selection: { anchor: TERM_FROM } });

      const handled = pressKey(v, key, modifiers);

      expect(handled).toBe(true);
      expect(v.state.doc.toString()).toBe(DOC);
    });

    // Backward-direction bindings — cursor placed exactly where the terminator ENDS.
    it.each<[string, string, Partial<KeyboardEventInit>]>([
      ['Backspace', 'Backspace', {}],
      ['Shift-Backspace', 'Backspace', { shiftKey: true }],
      ['Ctrl-h', 'h', { ctrlKey: true }],
      ['Alt-Backspace', 'Backspace', { altKey: true }],
      // Mod-Backspace: same jsdom Mod-→Ctrl- caveat as Mod-Delete above.
      ['Mod-Backspace (jsdom: Ctrl-Backspace)', 'Backspace', { ctrlKey: true }],
      ['Ctrl-Alt-h', 'h', { ctrlKey: true, altKey: true }],
    ])('%s at the terminator end is swallowed — document unchanged', (_name, key, modifiers) => {
      const v = makeEditor(DOC);
      v.dispatch({ selection: { anchor: TERM_TO } });

      const handled = pressKey(v, key, modifiers);

      expect(handled).toBe(true);
      expect(v.state.doc.toString()).toBe(DOC);
    });

    it('Prec.highest wins over an earlier-registered competing Backspace binding, mirroring main.ts registration order', () => {
      // main.ts registers `keymap.of([...defaultKeymap, ...])` (unwrapped) BEFORE anchorPlugin()
      // in its extension array — without bibliographyEndDeleteKeymap's Prec.highest wrapper,
      // plain array order would let defaultKeymap's earlier-registered deleteCharBackward win
      // this Backspace and destroy the terminator, reproducing the CURRENT BUG section above.
      const div = document.createElement('div');
      document.body.appendChild(div);
      const v = new EditorView({
        state: EditorState.create({
          doc: DOC,
          extensions: [keymap.of([...defaultKeymap]), anchorPlugin()],
        }),
        parent: div,
      });
      view = v;
      v.dispatch({ selection: { anchor: TERM_TO } });

      const handled = pressKey(v, 'Backspace');

      expect(handled).toBe(true);
      expect(v.state.doc.toString()).toBe(DOC);
    });

    it('negative guard: Backspace elsewhere in the document is not intercepted when the cursor is not adjacent to the terminator', () => {
      const v = makeEditor(DOC);
      const pos = DOC.indexOf('Only entry.') + 'Only entry.'.length;
      v.dispatch({ selection: { anchor: pos } });

      // No other Backspace-handling keymap is registered in this isolated extension set, so an
      // honest "not our concern" result here is `false`, not a fallthrough deletion — mirroring
      // this file's own Enter negative guard above.
      const handled = pressKey(v, 'Backspace');

      expect(handled).toBe(false);
      expect(v.state.doc.toString()).toBe(DOC);
    });

    it('negative guard: Delete elsewhere in the document is not intercepted when there is no terminator nearby', () => {
      const doc = 'First paragraph.\n\nSecond paragraph.';
      const v = makeEditor(doc);
      v.dispatch({ selection: { anchor: doc.indexOf('First paragraph.') } });

      const handled = pressKey(v, 'Delete');

      expect(handled).toBe(false);
      expect(v.state.doc.toString()).toBe(doc);
    });
  });
});

// Regression tests for the bibliography-end terminator's line-relocation / whole-line-delete
// protection (`bibliographyEndLineRelocationKeymap` / `isBibliographyEndMarkerLine`). The
// `deleteLine`/`Shift-Mod-k` guard that used to live alongside these in
// `bibliographyEndDeleteKeymap` was removed 2026-08-22 — see anchor-plugin.ts's "REMOVED"
// comment above `bibliographyEndLineRelocationKeymap` for why, and the "guarded dispatch
// (fixed)" describe block below for the coverage of that removal. See anchor-plugin.ts's own
// "Whole-line danger" section comment for the underlying mechanism: `deleteLine`, `moveLineUp`/
// `moveLineDown`, and `copyLineUp`/`copyLineDown` all build their changes straight from
// `selectedLineBlocks(state)` — the document line(s) under the selection — with no
// `EditorView.atomicRanges` awareness anywhere in that path, unlike every command guarded in the
// describe block above. `moveLine`/`copyLine` are the more severe failure mode: they don't
// delete anything, they silently relocate or duplicate the terminator instead, which re-scopes
// bibliography content without an obviously-destructive edit having happened.
describe('bibliography-end terminator line-relocation / whole-line-delete protection', () => {
  const DOC = `Only entry.\n\n${TERMINATOR}\n\nTrailing paragraph.`;
  const TERM_FROM = DOC.indexOf(TERMINATOR);
  const TERM_TO = TERM_FROM + TERMINATOR.length;
  const TERMINATOR_LINE = 3; // 1: "Only entry.", 2: "", 3: TERMINATOR, 4: "", 5: "Trailing paragraph."

  // ---- isBibliographyEndMarkerLine: the shared predicate behind all 5 guarded bindings ----

  describe('isBibliographyEndMarkerLine', () => {
    it("is true when the cursor sits anywhere on the terminator's own line — start, middle, or end", () => {
      const atStart = EditorState.create({ doc: DOC, selection: { anchor: TERM_FROM } });
      expect(isBibliographyEndMarkerLine(atStart)).toBe(true);

      const midLine = EditorState.create({ doc: DOC, selection: { anchor: TERM_FROM + 5 } });
      expect(isBibliographyEndMarkerLine(midLine)).toBe(true);

      const atEnd = EditorState.create({ doc: DOC, selection: { anchor: TERM_TO } });
      expect(isBibliographyEndMarkerLine(atEnd)).toBe(true);
    });

    it('is false when the cursor is on a different line entirely', () => {
      const state = EditorState.create({ doc: DOC, selection: { anchor: DOC.indexOf('Only entry.') } });
      expect(isBibliographyEndMarkerLine(state)).toBe(false);
    });

    it("is false for a non-empty selection, even one entirely confined to the terminator's own line", () => {
      const state = EditorState.create({ doc: DOC, selection: { anchor: TERM_FROM, head: TERM_FROM + 3 } });
      expect(state.selection.main.empty).toBe(false);
      expect(isBibliographyEndMarkerLine(state)).toBe(false);
    });

    it('is false when the document has no terminator at all', () => {
      const doc = 'First paragraph.\n\nSecond paragraph.';
      const state = EditorState.create({ doc, selection: { anchor: doc.indexOf('Second') } });
      expect(isBibliographyEndMarkerLine(state)).toBe(false);
    });
  });

  // ---- CURRENT BUG reproduction: no line-based guard installed ----
  //
  // Deliberately does NOT use anchorPlugin() — just @codemirror/commands' real, unmodified
  // defaultKeymap. deleteLine/moveLine/copyLine don't consult EditorView.atomicRanges at all
  // (see anchor-plugin.ts's doc comment), so no atomic-range setup is even needed to reproduce
  // the danger — a bare keymap is enough.
  describe('CURRENT BUG reproduction (no line-based guard installed)', () => {
    let bugView: EditorView | null = null;
    // jsdom has no real text-layout engine, so `Range.prototype.getClientRects` doesn't exist at
    // all. The real (unguarded) deleteLine command calls view.moveVertically() unconditionally,
    // after deleting, to reposition the cursor — CodeMirror's own coordsIn() already handles a
    // client rect list coming back EMPTY (`if (!rects.length) return null`), but crashes outright
    // if the method is simply missing. Polyfilled with an empty-array stub for this describe
    // block only, restored afterward — this only unblocks the real deleteLine's post-delete
    // cursor placement in a headless test environment, it isn't something this diff's own guard
    // logic depends on (the guarded dispatch tests below never reach deleteLine at all, so they
    // never needed this).
    let originalGetClientRects: typeof Range.prototype.getClientRects | undefined;

    beforeAll(() => {
      originalGetClientRects = Range.prototype.getClientRects;
      Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
    });

    afterAll(() => {
      if (originalGetClientRects) {
        Range.prototype.getClientRects = originalGetClientRects;
      } else {
        // @ts-expect-error — restoring to "absent", mirroring jsdom's actual default
        delete Range.prototype.getClientRects;
      }
    });

    afterEach(() => {
      if (bugView) {
        bugView.destroy();
        bugView = null;
      }
    });

    function makeUnguardedEditor(doc: string): EditorView {
      const div = document.createElement('div');
      document.body.appendChild(div);
      const v = new EditorView({
        state: EditorState.create({ doc, extensions: [keymap.of([...defaultKeymap])] }),
        parent: div,
      });
      bugView = v;
      return v;
    }

    function pressKey(v: EditorView, key: string, modifiers: Partial<KeyboardEventInit> = {}): boolean {
      const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...modifiers });
      return runScopeHandlers(v, event, 'editor');
    }

    it('Shift-Mod-k (deleteLine) with the cursor on the terminator line deletes the entire line, terminator included', () => {
      const v = makeUnguardedEditor(DOC);
      // Cursor at TERM_TO (not TERM_FROM) deliberately — avoids colliding with this file's
      // separate Ctrl-k coverage in the describe block above, since jsdom's char-key resolution
      // tries the no-shift "Ctrl-k" binding before the shift-inclusive "Shift-Ctrl-k" one for
      // any single-letter key (see that block's own Mod-key caveats for the platform-resolution
      // background). This harness has no Ctrl-k binding at all, so it isn't strictly necessary
      // here, but the fixed-dispatch tests below reuse this same cursor position for that reason.
      v.dispatch({ selection: { anchor: TERM_TO } });

      // jsdom's "key"-fallback platform normalizes CodeMirror's `Mod-` to `Ctrl-`, not `Meta-`/
      // Cmd — dispatching ctrlKey:true matches jsdom's own resolution of `Shift-Mod-k`, the same
      // caveat this file's existing Mod-Delete/Mod-Backspace tests already document.
      const handled = pressKey(v, 'k', { ctrlKey: true, shiftKey: true });

      expect(handled).toBe(true);
      expect(v.state.doc.toString()).not.toContain(TERMINATOR);
      // deleteLine consumes the line's own text PLUS one adjacent line break (the one before it,
      // since the terminator isn't the document's first line) — exactly what @codemirror/
      // commands' deleteLine implementation does, confirmed by reading its bundled source.
      expect(v.state.doc.toString()).toBe(DOC.slice(0, TERM_FROM - 1) + DOC.slice(TERM_TO));
    });

    it('Alt-ArrowUp (moveLineUp) with the cursor on the terminator line silently relocates it to the line above', () => {
      const v = makeUnguardedEditor(DOC);
      v.dispatch({ selection: { anchor: TERM_FROM } });

      const handled = pressKey(v, 'ArrowUp', { altKey: true });

      expect(handled).toBe(true);
      // Nothing was deleted -- doc length is unchanged -- but the terminator moved up a line.
      expect(v.state.doc.toString().length).toBe(DOC.length);
      expect(v.state.doc.line(TERMINATOR_LINE).text).not.toBe(TERMINATOR);
      expect(v.state.doc.line(TERMINATOR_LINE - 1).text).toBe(TERMINATOR);
    });

    it('Alt-ArrowDown (moveLineDown) with the cursor on the terminator line silently relocates it to the line below', () => {
      const v = makeUnguardedEditor(DOC);
      v.dispatch({ selection: { anchor: TERM_FROM } });

      const handled = pressKey(v, 'ArrowDown', { altKey: true });

      expect(handled).toBe(true);
      expect(v.state.doc.toString().length).toBe(DOC.length);
      expect(v.state.doc.line(TERMINATOR_LINE).text).not.toBe(TERMINATOR);
      expect(v.state.doc.line(TERMINATOR_LINE + 1).text).toBe(TERMINATOR);
    });

    it('Shift-Alt-ArrowDown (copyLineDown) with the cursor on the terminator line duplicates it onto a second line', () => {
      const v = makeUnguardedEditor(DOC);
      v.dispatch({ selection: { anchor: TERM_FROM } });

      const handled = pressKey(v, 'ArrowDown', { altKey: true, shiftKey: true });

      expect(handled).toBe(true);
      const text = v.state.doc.toString();
      const occurrences = text.split(TERMINATOR).length - 1;
      expect(occurrences).toBe(2); // two terminators now exist on two separate lines
    });
  });

  // ---- Fixed: bibliographyEndLineRelocationKeymap, via anchorPlugin() ----

  describe('guarded dispatch (fixed)', () => {
    let view: EditorView | null = null;

    afterEach(() => {
      if (view) {
        view.destroy();
        view = null;
      }
    });

    function makeEditor(doc: string): EditorView {
      const div = document.createElement('div');
      document.body.appendChild(div);
      const v = new EditorView({
        state: EditorState.create({ doc, extensions: [anchorPlugin()] }),
        parent: div,
      });
      view = v;
      return v;
    }

    function pressKey(v: EditorView, key: string, modifiers: Partial<KeyboardEventInit> = {}): boolean {
      const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...modifiers });
      return runScopeHandlers(v, event, 'editor');
    }

    it('Shift-Mod-k at the terminator line is NOT intercepted — that guard was removed once deleteLine stopped owning the chord', () => {
      // As of 2026-08-22, anchorPlugin() no longer binds Shift-Mod-k at all (see the "REMOVED"
      // comment above bibliographyEndLineRelocationKeymap in anchor-plugin.ts): main.ts now
      // filters `Shift-Mod-k` out of `defaultKeymap` entirely, because that chord is this app's
      // native "Insert Citation" menu shortcut, and CodeMirror's own `deleteLine` binding was
      // silently winning the race against it. With `deleteLine` unreachable on this key, there is
      // no more whole-line danger left for this plugin to guard against — and swallowing the
      // keystroke anyway (the old behavior this test used to assert) would silently block Insert
      // Citation whenever the cursor happened to sit on the terminator's own line, reproducing
      // the exact bug that removal fixed. The document staying unchanged below reflects that
      // *nothing* in this isolated extension set has a handler for the chord anymore, not a
      // deliberate no-op swallow.
      const v = makeEditor(DOC);
      v.dispatch({ selection: { anchor: TERM_TO } });

      const handled = pressKey(v, 'k', { ctrlKey: true, shiftKey: true });

      expect(handled).toBe(false);
      expect(v.state.doc.toString()).toBe(DOC);
    });

    it('Alt-ArrowUp at the terminator line is swallowed — terminator stays on its own line', () => {
      const v = makeEditor(DOC);
      v.dispatch({ selection: { anchor: TERM_FROM } });

      const handled = pressKey(v, 'ArrowUp', { altKey: true });

      expect(handled).toBe(true);
      expect(v.state.doc.toString()).toBe(DOC);
      expect(v.state.doc.line(TERMINATOR_LINE).text).toBe(TERMINATOR);
    });

    it('Alt-ArrowDown at the terminator line is swallowed — terminator stays on its own line', () => {
      const v = makeEditor(DOC);
      v.dispatch({ selection: { anchor: TERM_FROM } });

      const handled = pressKey(v, 'ArrowDown', { altKey: true });

      expect(handled).toBe(true);
      expect(v.state.doc.toString()).toBe(DOC);
      expect(v.state.doc.line(TERMINATOR_LINE).text).toBe(TERMINATOR);
    });

    it('Shift-Alt-ArrowUp at the terminator line is swallowed — no duplicate terminator created', () => {
      const v = makeEditor(DOC);
      v.dispatch({ selection: { anchor: TERM_FROM } });

      const handled = pressKey(v, 'ArrowUp', { altKey: true, shiftKey: true });

      expect(handled).toBe(true);
      expect(v.state.doc.toString()).toBe(DOC);
    });

    it('Shift-Alt-ArrowDown at the terminator line is swallowed — no duplicate terminator created', () => {
      const v = makeEditor(DOC);
      v.dispatch({ selection: { anchor: TERM_FROM } });

      const handled = pressKey(v, 'ArrowDown', { altKey: true, shiftKey: true });

      expect(handled).toBe(true);
      expect(v.state.doc.toString()).toBe(DOC);
    });

    it('Prec.highest wins over an earlier-registered competing Alt-ArrowUp binding, mirroring main.ts registration order', () => {
      const div = document.createElement('div');
      document.body.appendChild(div);
      const v = new EditorView({
        state: EditorState.create({
          doc: DOC,
          extensions: [keymap.of([...defaultKeymap]), anchorPlugin()],
        }),
        parent: div,
      });
      view = v;
      v.dispatch({ selection: { anchor: TERM_FROM } });

      const handled = pressKey(v, 'ArrowUp', { altKey: true });

      expect(handled).toBe(true);
      expect(v.state.doc.toString()).toBe(DOC);
    });

    it('negative guard: Alt-ArrowUp elsewhere in the document is not intercepted when the cursor is not on the terminator line', () => {
      const v = makeEditor(DOC);
      v.dispatch({ selection: { anchor: DOC.indexOf('Only entry.') } });

      const handled = pressKey(v, 'ArrowUp', { altKey: true });

      // No other Alt-ArrowUp-handling keymap is registered in this isolated extension set, so
      // an honest "not our concern" result here is `false`, not a fallthrough move — mirroring
      // this file's other negative guards.
      expect(handled).toBe(false);
      expect(v.state.doc.toString()).toBe(DOC);
    });

    it('negative guard: Shift-Mod-k elsewhere in the document is not intercepted when there is no terminator nearby', () => {
      const doc = 'First paragraph.\n\nSecond paragraph.';
      const v = makeEditor(doc);
      v.dispatch({ selection: { anchor: doc.indexOf('First paragraph.') } });

      const handled = pressKey(v, 'k', { ctrlKey: true, shiftKey: true });

      expect(handled).toBe(false);
      expect(v.state.doc.toString()).toBe(doc);
    });
  });
});
