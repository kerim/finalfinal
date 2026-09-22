// @vitest-environment jsdom
// Typewriter-scrolling trigger classification — Rich Text / Milkdown (plan §7).
//
// Runs the raw ProseMirror plugin (`createTypewriterPlugin`) on a bare `EditorView`, so the
// `state.apply` classification and the `view()` hook are exercised without standing up a
// whole Milkdown editor. Reason strings are asserted against the exported labels from the
// SHARED module.
//
// jsdom performs no layout, so `coordsAtPos` / `getBoundingClientRect` are zero and a real
// trigger would (correctly) abandon its write. `__setTypewriterTestGeometry` installs a
// non-degenerate line box so `triggerCount` / `lastReason` are observable. Production never
// calls it.
//
// Honest limits, recorded rather than papered over:
//  - `'delete'` has no public ProseMirror provenance on a transaction (Backspace and Delete
//    are indistinguishable from any other input-class edit at this layer), so that row is
//    asserted as a COUNT, not by name.
//  - `'correction'` is produced by the `derivedCorrection` meta, but every dispatch in this
//    app that sets that meta also runs inside a `withSettingContent` flag window (see
//    `api-content.ts`'s `updateHeadingLevels`), so it is suppressed in production. The test
//    asserts that suppression rather than pretending the reason is reachable.

import { history, redo, undo } from '@milkdown/kit/prose/history';
import { Schema } from '@milkdown/kit/prose/model';
import { EditorState } from '@milkdown/kit/prose/state';
import { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  getTypewriterTestState,
  markDocumentReady,
  REASON_COMMAND,
  REASON_HISTORY_REDO,
  REASON_HISTORY_UNDO,
  REASON_INPUT,
  REASON_PASTE,
  resetTypewriterForTests,
  setTypewriterEnabled,
  setTypewriterLineOffset,
} from '../../../shared/typewriter-scrolling';
import { setEditorInstance } from '../editor-state';
import { renumberFootnotes } from '../footnote-plugin';
import { __setTypewriterTestGeometry, createTypewriterPlugin, withSettingContent } from '../typewriter-plugin';

// Minimal schema, same shape as escape-passthrough-plugin.test.ts's harness, plus a
// `footnote_ref` node so the REAL `renumberFootnotes` dispatcher can be exercised.
const schema = new Schema({
  nodes: {
    doc: { content: 'paragraph+' },
    paragraph: { content: 'inline*', group: 'block', toDOM: () => ['p', 0] },
    footnote_ref: {
      attrs: { label: { default: '' } },
      inline: true,
      group: 'inline',
      toDOM: () => ['sup', 0],
    },
    text: { group: 'inline' },
  },
});

/** Five paragraphs, so a multi-LOGICAL-LINE move is actually expressible. */
const PARAGRAPHS = ['One.', 'Two.', 'Three.', 'Four.', 'Five.'];

function buildDoc(paras: string[] = PARAGRAPHS, footnoteLabel: string | null = null) {
  const nodes = paras.map((text, i) => {
    const content = [schema.text(text)];
    if (footnoteLabel !== null && i === 0) {
      content.push(schema.node('footnote_ref', { label: footnoteLabel }));
    }
    return schema.node('paragraph', null, content);
  });
  return schema.node('doc', null, nodes);
}

/** The ProseMirror position of the first character of paragraph `index` (0-based). */
function paragraphStart(view: EditorView, index: number): number {
  let pos = 0;
  for (let i = 0; i < index; i++) pos += view.state.doc.child(i).nodeSize;
  return pos + 1;
}

describe('typewriter scrolling: Milkdown trigger classification', () => {
  let view: EditorView | null = null;

  beforeEach(() => {
    resetTypewriterForTests();
    document.documentElement.style.removeProperty('--typewriter-reserve');
    __setTypewriterTestGeometry({
      caret: { top: 100, bottom: 124 },
      range: { maxScroll: 4000, visibleHeight: 480, lineHeight: 24 },
    });
  });

  afterEach(() => {
    __setTypewriterTestGeometry(null);
    resetTypewriterForTests();
    setEditorInstance(null);
    if (view) {
      view.destroy();
      view = null;
    }
  });

  function makeEditor(options: { paras?: string[]; footnoteLabel?: string | null } = {}): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const state = EditorState.create({
      doc: buildDoc(options.paras ?? PARAGRAPHS, options.footnoteLabel ?? null),
      plugins: [history(), createTypewriterPlugin()],
    });
    const v = new EditorView(div, { state });
    view = v;
    setTypewriterEnabled(true);
    setTypewriterLineOffset(0);
    markDocumentReady();
    return v;
  }

  /** A plain user edit: an insertion with no app marker. */
  /** A plain user edit AT THE CURRENT SELECTION, so a caret move decides the line. */
  function type(v: EditorView): void {
    const pos = v.state.selection.head;
    v.dispatch(v.state.tr.insertText('x', pos));
  }

  it("a plain edit is 'input'", () => {
    const v = makeEditor();
    type(v);
    const state = getTypewriterTestState();
    expect(state.triggerCount).toBeGreaterThan(0);
    expect(state.lastReason).toBe(REASON_INPUT);
  });

  it('two edits in a row count twice (the delete row is asserted as a count)', () => {
    const v = makeEditor();
    type(v);
    const first = getTypewriterTestState().triggerCount;
    v.dispatch(v.state.tr.delete(Math.min(2, v.state.doc.content.size), Math.min(3, v.state.doc.content.size)));
    expect(getTypewriterTestState().triggerCount).toBeGreaterThan(first);
  });

  it("a paste (uiEvent meta) is 'paste'", () => {
    const v = makeEditor();
    const pos = Math.min(2, v.state.doc.content.size);
    v.dispatch(v.state.tr.insertText('pasted', pos).setMeta('uiEvent', 'paste'));
    expect(getTypewriterTestState().lastReason).toBe(REASON_PASTE);
  });

  it("a drop (uiEvent meta) is 'paste'", () => {
    const v = makeEditor();
    const pos = Math.min(2, v.state.doc.content.size);
    v.dispatch(v.state.tr.insertText('dropped', pos).setMeta('uiEvent', 'drop'));
    expect(getTypewriterTestState().lastReason).toBe(REASON_PASTE);
  });

  it("an addToHistory: false change with no flag window is 'command'", () => {
    const v = makeEditor();
    const pos = Math.min(2, v.state.doc.content.size);
    v.dispatch(v.state.tr.insertText('programmatic', pos).setMeta('addToHistory', false));
    expect(getTypewriterTestState().lastReason).toBe(REASON_COMMAND);
  });

  it("undo is 'history-undo'", () => {
    const v = makeEditor();
    type(v);
    expect(undo(v.state, v.dispatch)).toBe(true);
    expect(getTypewriterTestState().lastReason).toBe(REASON_HISTORY_UNDO);
  });

  it("redo is 'history-redo'", () => {
    const v = makeEditor();
    type(v);
    undo(v.state, v.dispatch);
    expect(redo(v.state, v.dispatch)).toBe(true);
    expect(getTypewriterTestState().lastReason).toBe(REASON_HISTORY_REDO);
  });

  it('the flag window suppresses a change', () => {
    const v = makeEditor();
    type(v);
    const before = getTypewriterTestState().triggerCount;
    const pos = Math.min(2, v.state.doc.content.size);
    withSettingContent(() => v.dispatch(v.state.tr.insertText('app push', pos)));
    expect(getTypewriterTestState().triggerCount).toBe(before);
  });

  it('the flag window is cleared after a suppressed dispatch, so the next edit triggers', () => {
    const v = makeEditor();
    const pos = Math.min(2, v.state.doc.content.size);
    withSettingContent(() => v.dispatch(v.state.tr.insertText('app push', pos)));
    const before = getTypewriterTestState().triggerCount;
    type(v);
    expect(getTypewriterTestState().triggerCount).toBe(before + 1);
    expect(getTypewriterTestState().lastReason).toBe(REASON_INPUT);
  });

  it('a derivedCorrection-meta change inside the flag window is suppressed', () => {
    const v = makeEditor();
    type(v);
    const before = getTypewriterTestState().triggerCount;
    const pos = Math.min(2, v.state.doc.content.size);
    withSettingContent(() => v.dispatch(v.state.tr.insertText('corrected', pos).setMeta('derivedCorrection', true)));
    expect(getTypewriterTestState().triggerCount).toBe(before);
  });

  it('a selection-only transaction does not trigger', () => {
    const v = makeEditor();
    type(v);
    const before = getTypewriterTestState().triggerCount;
    v.dispatch(v.state.tr.setSelection(v.state.selection.constructor.near(v.state.doc.resolve(1))));
    expect(getTypewriterTestState().triggerCount).toBe(before);
  });

  it('a one-logical-line edit is instant and a multi-line move glides', () => {
    const v = makeEditor();
    // First trigger is always instant (lastLine null).
    v.dispatch(v.state.tr.setSelection(v.state.selection.constructor.near(v.state.doc.resolve(paragraphStart(v, 0)))));
    type(v);
    expect(getTypewriterTestState().lastLine).toBe(1);

    // One logical line of delta: INSTANT — observable via the shared module's glide flag.
    v.dispatch(v.state.tr.setSelection(v.state.selection.constructor.near(v.state.doc.resolve(paragraphStart(v, 1)))));
    type(v);
    expect(getTypewriterTestState().lastLine).toBe(2);
    expect(getTypewriterTestState().gliding).toBe(false);

    // Four logical lines of delta: GLIDES. This is the assertion the old version of this
    // test claimed but could not make, in a document where the move did not exist.
    v.dispatch(v.state.tr.setSelection(v.state.selection.constructor.near(v.state.doc.resolve(paragraphStart(v, 4)))));
    type(v);
    expect(getTypewriterTestState().lastLine).toBe(5);
    expect(getTypewriterTestState().gliding).toBe(true);
    expect(getTypewriterTestState().lastReason).toBe(REASON_INPUT);
  });

  it('the flag window is a DEPTH counter, so a nested window cannot clear an outer one', () => {
    // M1's note: with a boolean set/clear, the inner `finally` would clear the flag and the
    // OUTER dispatch would then be classified as a user edit and trigger.
    const v = makeEditor();
    type(v);
    const before = getTypewriterTestState().triggerCount;
    const pos = Math.min(2, v.state.doc.content.size);
    withSettingContent(() => {
      withSettingContent(() => v.dispatch(v.state.tr.insertText('inner', pos)));
      // Still inside the outer window: this dispatch must ALSO be suppressed.
      v.dispatch(v.state.tr.insertText('outer', pos));
    });
    expect(getTypewriterTestState().triggerCount).toBe(before);

    // And the flag is fully cleared afterwards: the next real edit triggers again.
    type(v);
    expect(getTypewriterTestState().triggerCount).toBe(before + 1);
  });

  it('the REAL renumberFootnotes dispatcher is suppressed (M2)', () => {
    const v = makeEditor({ footnoteLabel: '1' });
    // `renumberFootnotes` reads the editor instance off editor-state; the context only has
    // to hand back this view.
    setEditorInstance({ ctx: { get: () => v } } as never);
    type(v);
    const before = getTypewriterTestState().triggerCount;
    const labelBefore = v.state.doc.child(0).child(1).attrs.label;
    expect(labelBefore).toBe('1');

    renumberFootnotes({ '1': '2' });

    // The document DID change (proof the dispatcher ran), yet no trigger fired.
    expect(v.state.doc.child(0).child(1).attrs.label).toBe('2');
    expect(getTypewriterTestState().triggerCount).toBe(before);
  });
});
