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
import { EditorState } from '@codemirror/state';
import { EditorView, keymap, runScopeHandlers } from '@codemirror/view';
import { afterEach, describe, expect, it } from 'vitest';
import { anchorPlugin, bibliographyEndInsertionPoint } from '../anchor-plugin';

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
