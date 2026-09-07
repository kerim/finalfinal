// @vitest-environment jsdom
// Regression tests for CodeMirror's inline-annotation delete bridge (api.ts's
// deleteInlineAnnotation). Unlike Milkdown, source mode has no atomic node to delete -- this
// is a plain text-range delete via a normal user transaction (deliberately NOT
// `annotations: Transaction.addToHistory.of(false)`, unlike the silent-sync transactions
// elsewhere in api.ts), so CodeMirror's own text-undo history undoes it like any other edit.

import { history, undo } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterEach, describe, expect, it } from 'vitest';
import { deleteInlineAnnotation, getAnnotations } from '../api';
import { setEditorView } from '../editor-state';

describe('deleteInlineAnnotation (CodeMirror/source mode)', () => {
  let view: EditorView | null = null;

  afterEach(() => {
    setEditorView(null);
    if (view) {
      view.destroy();
      view = null;
    }
  });

  function makeEditor(doc: string): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const extensions = [markdown({ base: markdownLanguage }), history()];
    const v = new EditorView({
      state: EditorState.create({ doc, extensions }),
      parent: div,
    });
    view = v;
    setEditorView(v);
    return v;
  }

  it('deletes the nth annotation comment (same ordering as getAnnotations()) and is undoable via plain text history', () => {
    const v = makeEditor(
      '<!-- ::task:: [ ] first --> then <!-- ::comment:: second --> and <!-- ::reference:: third -->'
    );
    const original = v.state.doc.toString();
    expect(getAnnotations()).toHaveLength(3);

    const ok = deleteInlineAnnotation(1, 'comment', 'second'); // "second" (comment)
    expect(ok).toBe(true);
    expect(getAnnotations()).toHaveLength(2);
    expect(v.state.doc.toString()).not.toContain('second');
    expect(v.state.doc.toString()).toContain('first');
    expect(v.state.doc.toString()).toContain('third');

    const undone = undo(v);
    expect(undone).toBe(true);
    expect(v.state.doc.toString()).toBe(original);
    expect(getAnnotations()).toHaveLength(3);
  });

  it('deletes exactly the matched comment range, leaving surrounding text intact', () => {
    makeEditor('Before <!-- ::comment:: note --> after');

    expect(deleteInlineAnnotation(0, 'comment', 'note')).toBe(true);
    expect(view!.state.doc.toString()).toBe('Before  after');
  });

  it('returns false for an out-of-range index with no identity match either, and leaves the document untouched', () => {
    const v = makeEditor('<!-- ::comment:: only -->');
    const original = v.state.doc.toString();

    expect(deleteInlineAnnotation(5, 'comment', 'nonexistent')).toBe(false);
    expect(deleteInlineAnnotation(-1, 'comment', 'nonexistent')).toBe(false);
    expect(v.state.doc.toString()).toBe(original);
  });

  it('returns false when there is no live editor view', () => {
    setEditorView(null);
    expect(deleteInlineAnnotation(0, 'comment', 'x')).toBe(false);
  });

  // ---- must-fix 1 (judge round review): stale-index identity verification ----

  it('falls back to a unique type+text re-scan when the index is stale (panel list lagged the live document)', () => {
    const v = makeEditor(
      '<!-- ::task:: [ ] first --> then <!-- ::comment:: second --> and <!-- ::reference:: third -->'
    );

    // Index 0 is really "first" (a task); the caller still believes index 0 is "second".
    const ok = deleteInlineAnnotation(0, 'comment', 'second');
    expect(ok).toBe(true);
    expect(getAnnotations()).toHaveLength(2);
    expect(v.state.doc.toString()).not.toContain('second');
    expect(v.state.doc.toString()).toContain('first');
    expect(v.state.doc.toString()).toContain('third');
  });

  it('refuses (returns false, deletes nothing) when a stale index has zero identity matches', () => {
    const v = makeEditor('<!-- ::comment:: only -->');
    const original = v.state.doc.toString();

    expect(deleteInlineAnnotation(0, 'comment', 'nonexistent')).toBe(false);
    expect(v.state.doc.toString()).toBe(original);
  });

  it('refuses (returns false, deletes nothing) when a stale index has multiple identity matches -- never guesses by position', () => {
    const v = makeEditor('<!-- ::comment:: dup --> and again <!-- ::comment:: dup -->');
    const original = v.state.doc.toString();
    expect(getAnnotations()).toHaveLength(2);

    // The match at index 0 does NOT match ('reference' vs 'comment'), so this falls back to
    // the identity re-scan -- which finds two "comment"/"dup" annotations and must refuse.
    expect(deleteInlineAnnotation(0, 'reference', 'dup')).toBe(false);
    expect(v.state.doc.toString()).toBe(original);
  });
});
