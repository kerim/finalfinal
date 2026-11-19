// @vitest-environment jsdom
//
// Markdown (CodeMirror) side of the "heading-level correction lands in the middle of typing" check;
// the Rich Text twin is web/milkdown/src/__tests__/heading-correction-mid-typing.test.ts.
//
// The situation: the user starts a new heading by typing `### ` at the start of a new line and keeps
// typing the title. While they type, the app's automatic heading-level correction decides that a
// level-3 heading directly under a level-1 heading is one level too deep and demotes it to level 2.
// In Markdown mode that correction arrives as Swift's source-mode push: `setContent(<the document with
// the heading line's `### ` changed to `## `>, { origin: 'derived' })`. It can arrive between any two
// keystrokes. What the user must see, whenever it arrives:
//   * every character they typed is still there, in order, and none of them ended up inside the
//     correction (no lost, doubled or merged keystroke);
//   * Cmd-Z first takes back what they typed after the correction, then the correction on its own,
//     then their earlier typing; Cmd-Shift-Z walks the same path forward again.
//
// Harness: the real-EditorView harness of set-content-origin-overlap.test.ts (markdown, history, the
// `Range.getBoundingClientRect` polyfill). That file calls `noteTransactionForEditSpanTracking` by hand
// after the transaction it simulates; here the production wiring is mirrored instead: main.ts feeds
// EVERY transaction (typing, the correction's own dispatches, undo and redo) to the tracker from an
// `EditorView.updateListener`, so the same listener is installed. Date.now() is frozen (only Date is
// faked, and nothing advances it) so that history grouping is decided by adjacency alone and no test
// depends on how fast the machine types; the tests therefore do not assert how many keystrokes one
// undo takes back, only the order of the states.
// Cmd-Z and Cmd-Shift-Z are driven through @codemirror/commands' own `undo` and `redo`, not through the
// app's undo coordinator (undo-coordinator.ts).

import { history, redo, undo } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorState, type Extension } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { setContent } from '../api';
import { setEditorExtensions, setEditorView } from '../editor-state';
import { noteTransactionForEditSpanTracking, resetRecentUserEditSpanForTests } from '../recent-edit-span';

const START_DOC = '# Top\n\nIntro.';
const TITLE = 'Title more';
const TITLE_BEFORE_FIX = 'Ti';
/** The points in the title where the correction can land: after 0, 1, ... 10 typed characters. */
const POINTS = Array.from({ length: TITLE.length + 1 }, (_, k) => k);

beforeAll(() => {
  if (typeof Range !== 'undefined' && !Range.prototype.getBoundingClientRect) {
    Range.prototype.getBoundingClientRect = function (this: Range): DOMRect {
      return { x: 0, y: 0, width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0, toJSON: () => ({}) } as DOMRect;
    };
  }
});

describe('heading-level correction in the middle of typing a new heading (Markdown)', () => {
  let view: EditorView | null = null;
  let host: HTMLElement | null = null;

  afterEach(() => {
    vi.useRealTimers();
    setEditorView(null);
    setEditorExtensions([]);
    resetRecentUserEditSpanForTests();
    if (view) {
      view.destroy();
      view = null;
    }
    if (host) {
      host.remove();
      host = null;
    }
  });

  /** A fresh editor on START_DOC with the caret at its end, a frozen clock, and the production edit-span wiring. */
  function startEditor(): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    host = div;
    const extensions: Extension[] = [
      markdown({ base: markdownLanguage }),
      history(),
      // Mirrors main.ts: every transaction goes to the edit-span tracker.
      EditorView.updateListener.of((update) => {
        for (const tr of update.transactions) noteTransactionForEditSpanTracking(tr);
      }),
    ];
    const v = new EditorView({
      state: EditorState.create({ doc: START_DOC, selection: { anchor: START_DOC.length }, extensions }),
      parent: div,
    });
    view = v;
    setEditorView(v);
    setEditorExtensions(extensions);
    vi.useFakeTimers({ toFake: ['Date'] });
    return v;
  }

  const docOf = (v: EditorView): string => v.state.doc.toString();

  /** The whole document with the title line at `hashes` (`##` or `###`) holding `text`. */
  const docWithTitle = (hashes: string, text: string): string => `${START_DOC}\n\n${hashes} ${text}`;

  /** One typed character at the caret, as the real editor receives it. */
  function typeChar(v: EditorView, ch: string): void {
    const pos = v.state.selection.main.head;
    v.dispatch(
      v.state.update({
        changes: { from: pos, insert: ch },
        selection: { anchor: pos + 1 },
        userEvent: 'input.type',
      })
    );
  }

  function pressEnter(v: EditorView): void {
    const pos = v.state.selection.main.head;
    v.dispatch(
      v.state.update({
        changes: { from: pos, insert: '\n' },
        selection: { anchor: pos + 1 },
        userEvent: 'input',
      })
    );
  }

  /** Enter twice at the end of "Intro." (a blank line, then the new line), then `### ` at the start of the new line. */
  function startNewHeading(v: EditorView, seen: Set<string>): void {
    pressEnter(v);
    seen.add(docOf(v));
    pressEnter(v);
    seen.add(docOf(v));
    expect(docOf(v)).toBe(`${START_DOC}\n\n`);
    for (const ch of '### ') {
      typeChar(v, ch);
      seen.add(docOf(v));
    }
    expect(docOf(v)).toBe(docWithTitle('###', ''));
  }

  function typeAll(v: EditorView, text: string, seen: Set<string>): void {
    for (const ch of text) {
      typeChar(v, ch);
      seen.add(docOf(v));
    }
  }

  /** Swift's source-mode push: the document with the heading line's leading `### ` changed to `## `. The line is
   * the last one (the heading being typed); the prefix is changed rather than a fixed string replaced, so the
   * push is the right one whatever has been typed after it (`### `, `### T`, `### Title more`). */
  function applyLevelFix(v: EditorView, seen: Set<string>): void {
    const before = docOf(v);
    const lineStart = before.lastIndexOf('\n') + 1;
    const line = before.slice(lineStart);
    expect(
      line.startsWith('### '),
      `the heading line should still be level 3 before the fix: ${JSON.stringify(line)}`
    ).toBe(true);
    const pushed = `${before.slice(0, lineStart)}## ${line.slice('### '.length)}`;
    expect(pushed).not.toBe(before);

    setContent(pushed, { origin: 'derived' });

    // The push really changed the level (and nothing else): no keystroke typed so far is gone.
    expect(docOf(v)).toBe(pushed);
    expect(docOf(v).slice(lineStart).startsWith('## ')).toBe(true);
    expect(docOf(v).slice(lineStart).startsWith('### ')).toBe(false);
    seen.add(docOf(v));
  }

  it('no keystroke lost when the level fix lands after "### Ti"', () => {
    const v = startEditor();
    const seen = new Set<string>();
    startNewHeading(v, seen);
    typeAll(v, TITLE_BEFORE_FIX, seen);
    expect(docOf(v)).toBe(docWithTitle('###', 'Ti'));

    applyLevelFix(v, seen);
    expect(docOf(v)).toBe(docWithTitle('##', 'Ti'));

    typeAll(v, 'tle more', seen);

    // Every character present and in order, in the one heading line; the rest of the document untouched.
    expect(docOf(v)).toBe('# Top\n\nIntro.\n\n## Title more');
  });

  it('Cmd-Z walks back in order, Cmd-Shift-Z walks forward', () => {
    const v = startEditor();
    const seen = new Set<string>();
    seen.add(docOf(v));
    startNewHeading(v, seen);
    typeAll(v, TITLE_BEFORE_FIX, seen);
    applyLevelFix(v, seen);
    typeAll(v, 'tle more', seen);
    const typedDoc = docOf(v);
    expect(typedDoc).toBe('# Top\n\nIntro.\n\n## Title more');

    // Undo 1: only what was typed after the correction goes; the correction stays and was not merged into it.
    expect(undo(v)).toBe(true);
    expect(docOf(v)).toBe('# Top\n\nIntro.\n\n## Ti');
    const undoPath: string[] = [docOf(v)];

    // Undo 2: the correction is its own step.
    expect(undo(v)).toBe(true);
    expect(docOf(v)).toBe('# Top\n\nIntro.\n\n### Ti');
    undoPath.push(docOf(v));

    // Keep undoing: every state on the way back is one the user has seen (never a mixed one), ending at the
    // document they started from.
    for (let i = 0; i < 100 && undo(v); i++) {
      expect(seen.has(docOf(v)), `undo reached a state nobody typed: ${JSON.stringify(docOf(v))}`).toBe(true);
      undoPath.push(docOf(v));
    }
    expect(docOf(v)).toBe(START_DOC);
    expect(undo(v)).toBe(false);

    // Redo walks the same path forward: each state is one seen before, in the reverse order of the undo path,
    // ending at the document as typed.
    const redoPath: string[] = [];
    for (let i = 0; i < 100 && redo(v); i++) {
      expect(seen.has(docOf(v)), `redo reached a state nobody typed: ${JSON.stringify(docOf(v))}`).toBe(true);
      redoPath.push(docOf(v));
    }
    expect(redoPath).toEqual([...undoPath.slice(0, -1)].reverse().concat([typedDoc]));
    expect(docOf(v)).toBe(typedDoc);
    expect(redo(v)).toBe(false);
  });

  it.each(POINTS)('fix landing at every point in the title loses nothing (after %i typed characters)', (k) => {
    const v = startEditor();
    const seen = new Set<string>();
    const prefix = TITLE.slice(0, k);
    startNewHeading(v, seen);
    typeAll(v, prefix, seen);
    expect(docOf(v), `before the fix, k=${k}`).toBe(docWithTitle('###', prefix));

    applyLevelFix(v, seen);
    expect(docOf(v), `after the fix, k=${k}`).toBe(docWithTitle('##', prefix));

    typeAll(v, TITLE.slice(k), seen);
    expect(docOf(v), `after all typing, k=${k}`).toBe(docWithTitle('##', TITLE));
    const typedDoc = docOf(v);

    // Undo: what came after the correction goes first (nothing, when the correction landed after the last
    // character), then the correction by itself.
    const undoStates =
      k < TITLE.length ? [docWithTitle('##', prefix), docWithTitle('###', prefix)] : [docWithTitle('###', prefix)];
    undoStates.forEach((expected, i) => {
      expect(undo(v), `undo ${i + 1}, k=${k}`).toBe(true);
      expect(docOf(v), `undo ${i + 1}, k=${k}`).toBe(expected);
    });

    // Redo goes forward through the same states in reverse, back to the typed document.
    const redoStates = [...undoStates.slice(0, -1).reverse(), typedDoc];
    redoStates.forEach((expected, i) => {
      expect(redo(v), `redo ${i + 1}, k=${k}`).toBe(true);
      expect(docOf(v), `redo ${i + 1}, k=${k}`).toBe(expected);
    });
    expect(redo(v), `nothing left to redo, k=${k}`).toBe(false);
  });
});
