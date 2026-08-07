// @vitest-environment jsdom
// Regression test for insertEquation()'s display-math cursor-position handling in api.ts.
//
// The bug this hardens against: before this fix, a display-equation insert at a mid-line
// cursor position (not column 0) glued the opening `$$` directly onto whatever text
// preceded the cursor on that line -- e.g. "some text$$". Per micromark's own math-flow
// tokenizer rules (see math-paste-normalize.ts's doc comment for the confirmed mechanism),
// a bare `$$` ending a line with no OTHER `$` earlier on that line is a genuine fence
// opener with no matching close in sight, so it swallows every line after it -- including
// unrelated paragraphs -- all the way to the next `$$` or end of document. Before this
// round's changes, the same mid-line insert instead produced `some text$$latex$$` glued
// onto ONE line, which was safely contained as inline math -- so this is a corruption path
// introduced by the display-math insert shape itself, not a pre-existing bug.
//
// The fix forces the equation onto a fresh line (a blank line first, when real content
// precedes the cursor) so the opening `$$` always starts a well-formed, bounded fence.

import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterEach, describe, expect, it } from 'vitest';
import { insertEquation } from '../api';
import { setEditorView } from '../editor-state';

describe('insertEquation() display-math cursor positioning', () => {
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
    const v = new EditorView({
      state: EditorState.create({ doc, extensions: [markdown({ base: markdownLanguage })] }),
      parent: div,
    });
    view = v;
    setEditorView(v);
    return v;
  }

  it('mid-line cursor (real content precedes, nothing follows on the same line) starts the equation on a fresh line after a blank-line separator', () => {
    const v = makeEditor('Some text before the equation');
    // Cursor at the end of the line -- mid-line relative to column 0, not at doc start.
    v.dispatch({ selection: { anchor: v.state.doc.length } });

    insertEquation('E = mc^2', true);

    const text = v.state.doc.toString();
    expect(text).toBe('Some text before the equation\n\n$$\nE = mc^2\n$$\n');

    const lines = text.split('\n');
    // Every fence line is bare -- never glued onto adjacent content, matching
    // micromark's own opener/closer rule.
    expect(lines.filter((l) => l === '$$')).toHaveLength(2);
    // The original preceding text must survive intact, on its own line.
    expect(lines[0]).toBe('Some text before the equation');
  });

  it('mid-line cursor with trailing content on the same line keeps that content intact and off the fence lines', () => {
    const doc = 'beforeafter';
    const v = makeEditor(doc);
    const cursorPos = 'before'.length;
    v.dispatch({ selection: { anchor: cursorPos } });

    insertEquation('x = y', true);

    const text = v.state.doc.toString();
    // Trailing content is preserved, not swallowed into the equation body.
    expect(text).toContain('before');
    expect(text).toContain('after');
    // The closing fence line is bare $$, not glued to the trailing text.
    const lines = text.split('\n');
    const closingIdx = lines.lastIndexOf('$$');
    expect(closingIdx).toBeGreaterThan(-1);
    expect(lines[closingIdx]).toBe('$$');
  });

  it('cursor already at column 0 (start of an empty document) inserts the equation with no extra leading blank line', () => {
    const v = makeEditor('');
    insertEquation('a^2 + b^2', true);

    expect(v.state.doc.toString()).toBe('$$\na^2 + b^2\n$$\n');
  });

  it('cursor at column 0 of a non-empty line (start of an existing paragraph) inserts the equation with no extra leading blank line', () => {
    const v = makeEditor('Existing paragraph text.');
    v.dispatch({ selection: { anchor: 0 } });

    insertEquation('c^2', true);

    const text = v.state.doc.toString();
    expect(text.startsWith('$$\nc^2\n$$\n')).toBe(true);
    expect(text).toContain('Existing paragraph text.');
  });
});
