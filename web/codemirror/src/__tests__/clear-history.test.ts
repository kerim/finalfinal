// @vitest-environment jsdom
// Proof-obligation tests for clearHistory() (api.ts) -- the CodeMirror analog of Milkdown's
// clearEditorHistory() fix. Uses the same real-EditorView harness pattern as
// set-content-selection.test.ts (which already covers this module's beforeAll jsdom
// Range.getBoundingClientRect polyfill needed by installLineHeightFix()).

import { history, undoDepth } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorState, type Extension } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterEach, beforeAll, describe, expect, it } from 'vitest';
import { clearHistory } from '../api';
import { setEditorExtensions, setEditorView } from '../editor-state';

// jsdom has no real layout engine and doesn't implement Range.prototype.getBoundingClientRect.
// clearHistory() calls installLineHeightFix(), which measures dummy elements via the Range API
// -- polyfill it to a zeroed DOMRect so that measurement path doesn't throw here (see
// set-content-selection.test.ts for the identical rationale).
beforeAll(() => {
  if (typeof Range !== 'undefined' && !Range.prototype.getBoundingClientRect) {
    Range.prototype.getBoundingClientRect = function (this: Range): DOMRect {
      return {
        x: 0,
        y: 0,
        width: 0,
        height: 0,
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        toJSON() {
          return {};
        },
      } as DOMRect;
    };
  }
});

describe('clearHistory()', () => {
  let view: EditorView | null = null;

  afterEach(() => {
    setEditorView(null);
    setEditorExtensions([]);
    if (view) {
      view.destroy();
      view = null;
    }
  });

  function makeEditor(doc: string, extraExtensions: Extension[] = []): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const extensions: Extension[] = [markdown({ base: markdownLanguage }), history(), ...extraExtensions];
    const v = new EditorView({
      state: EditorState.create({ doc, extensions }),
      parent: div,
    });
    view = v;
    setEditorView(v);
    // clearHistory() rebuilds via getEditorExtensions() -- mirrors main.ts's production wiring
    // where setEditorExtensions() is called once at init.
    setEditorExtensions(extensions);
    return v;
  }

  it('zeroes undo depth after a real tracked edit put it above zero', () => {
    const v = makeEditor('Paragraph one.\n\nParagraph two.');

    v.dispatch({ changes: { from: 0, insert: 'X' } });
    expect(undoDepth(v.state)).toBeGreaterThan(0);

    clearHistory();

    expect(undoDepth(v.state)).toBe(0);
  });

  it('negative control: undo depth stays above zero when the clear step is skipped', () => {
    const v = makeEditor('Paragraph one.\n\nParagraph two.');

    v.dispatch({ changes: { from: 0, insert: 'X' } });
    expect(undoDepth(v.state)).toBeGreaterThan(0);

    // clearHistory() deliberately NOT called here -- proves the zero result above is actually
    // caused by calling it, not an artifact of the harness that would make it vacuously true.
    expect(undoDepth(v.state)).toBeGreaterThan(0);
  });

  it('preserves document content and selection across the clear', () => {
    const v = makeEditor('Paragraph one.\n\nParagraph two.');
    v.dispatch({ changes: { from: 0, insert: 'X' } });
    const docAfterEdit = v.state.doc.toString();

    const cursorPos = docAfterEdit.indexOf('two');
    v.dispatch({ selection: { anchor: cursorPos } });
    expect(undoDepth(v.state)).toBeGreaterThan(0);

    clearHistory();

    expect(v.state.doc.toString()).toBe(docAfterEdit);
    expect(v.state.selection.main.head).toBe(cursorPos);
    expect(undoDepth(v.state)).toBe(0);
  });

  it('is a no-op (does not throw) when there is no active editor view', () => {
    setEditorView(null);
    expect(() => clearHistory()).not.toThrow();
  });
});
