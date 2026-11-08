// @vitest-environment jsdom
//
// Phase 5 job A8 (t-94369a83; design docs/architecture/write-queue-plan/phase5/a7-a10-design.md, sections 0 and 2): the Markdown page's
// half of the zoom transition, web/codemirror/src/api-transition.ts, on the REAL page (main.ts imported into jsdom, so the real update
// listeners record, hold and push). Each test names its break patch (a small edit of api-transition.ts) and the failure it predicts; the
// run record is docs/architecture/write-queue-plan/phase5/a8-notes.md.
//
// The documents are built by hand the way Swift builds them: chapters separated by a blank line, each heading preceded by its section anchor;
// a zoomed chapter is the chapter's own text (anchors included) plus, when it has footnote references, the mini-Notes after the separator.

import { undo } from '@codemirror/commands';
import { EditorView } from '@codemirror/view';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MarkdownSwapResult, MarkdownTransitionBeginResult } from '../api-transition';

type FF = {
  setContent: (md: string, options?: unknown) => void;
  getContentRaw: () => string;
  resetForProjectSwitch: () => void;
  clearStructuralUndoRegistry: () => void;
  beginTransition: () => MarkdownTransitionBeginResult;
  swapTransition: (
    token: number,
    options: { text: string; kind: 'in' | 'out'; scrollToStart?: boolean }
  ) => MarkdownSwapResult;
  endTransition: (token: number | null, mode?: 'send' | 'discard') => { ended: boolean };
};

const ff = (): FF => (window as unknown as { FinalFinal: FF }).FinalFinal;

let view: EditorView;
let contentChanged: ReturnType<typeof vi.fn>;
let resetUndoCoordinatorState: () => void;
let resetMarkdownTransitionForTests: () => void;

function currentView(): EditorView {
  const dom = document.querySelector('.cm-editor') as HTMLElement | null;
  const v = dom ? EditorView.findFromDOM(dom) : null;
  if (!v) throw new Error('no CodeMirror view mounted by main.ts');
  return v;
}

const docText = (): string => view.state.doc.toString();

function typeAt(pos: number, text: string): void {
  view.dispatch(
    view.state.update({
      changes: { from: pos, insert: text },
      selection: { anchor: pos + text.length },
      userEvent: 'input.type',
    })
  );
}

function typeAfter(marker: string, text: string): void {
  const at = docText().indexOf(marker);
  if (at < 0) throw new Error(`marker not in document: ${marker}`);
  typeAt(at + marker.length, text);
}

function deleteRange(from: number, to: number): void {
  view.dispatch(view.state.update({ changes: { from, to }, userEvent: 'delete.backward' }));
}

// === The documents ===

const anchor = (id: string): string => `<!-- @sid:${id} -->`;
const ID1 = '11111111-1111-1111-1111-111111111111';
const ID2 = '22222222-2222-2222-2222-222222222222';
const ID3 = '33333333-3333-3333-3333-333333333333';
const chapter1 = `${anchor(ID1)}# Chapter 1\n\nText of chapter 1.`;
const chapter2 = `${anchor(ID2)}# Chapter 2\n\nText of chapter 2.\n\nMore of chapter 2.`;
const chapter3 = `${anchor(ID3)}# Chapter 3\n\nText of chapter 3.`;
const fullText = [chapter1, chapter2, chapter3].join('\n\n');

const NOTES_SEPARATOR = '\n\n<!-- ::zoom-notes:: -->';
const chapter2Footnoted = `${anchor(ID2)}# Chapter 2\n\nText of chapter 2.[^1]`;
const fullFootnoted = [chapter1, chapter2Footnoted, chapter3, '# Notes\n\n[^1]: The note.'].join('\n\n');
const zoomedFootnoted = `${chapter2Footnoted}${NOTES_SEPARATOR}\n# Notes\n\n[^1]: The note.\n`;

function load(text: string): void {
  resetUndoCoordinatorState();
  resetMarkdownTransitionForTests();
  ff().clearStructuralUndoRegistry();
  ff().resetForProjectSwitch();
  ff().setContent(text);
  ff().resetForProjectSwitch();
  view = currentView();
  vi.advanceTimersByTime(200);
  contentChanged.mockClear();
}

function begin(): number {
  const began = ff().beginTransition();
  if (!began.ok) throw new Error(`begin refused: ${began.reason}`);
  return began.token;
}

const pushedTexts = (): string[] => contentChanged.mock.calls.map((call) => (call[0] as { content: string }).content);

beforeAll(async () => {
  if (typeof Range !== 'undefined' && !Range.prototype.getBoundingClientRect) {
    Range.prototype.getBoundingClientRect = function (this: Range): DOMRect {
      return { x: 0, y: 0, width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0, toJSON: () => ({}) } as DOMRect;
    };
  }
  if (typeof Range !== 'undefined' && !Range.prototype.getClientRects) {
    Range.prototype.getClientRects = function (this: Range): DOMRectList {
      return { length: 0, item: () => null, [Symbol.iterator]: function* () {} } as unknown as DOMRectList;
    };
  }
  contentChanged = vi.fn();
  (window as any).webkit = {
    messageHandlers: {
      contentChanged: { postMessage: contentChanged },
      sectionChanged: { postMessage: vi.fn() },
      historyEdited: { postMessage: vi.fn() },
      paintComplete: { postMessage: vi.fn() },
      errorHandler: { postMessage: vi.fn() },
    },
  };
  const root = document.createElement('div');
  root.id = 'editor';
  document.body.appendChild(root);
  await import('../main');
  ({ resetUndoCoordinatorState } = await import('../undo-coordinator'));
  ({ resetMarkdownTransitionForTests } = await import('../api-transition'));
});

afterAll(() => {
  delete (window as any).webkit;
  document.body.innerHTML = '';
});

beforeEach(() => {
  vi.useFakeTimers();
  view = currentView();
});

afterEach(() => {
  resetMarkdownTransitionForTests();
  resetUndoCoordinatorState();
  vi.useRealTimers();
});

describe('beginTransition: the live text, the hold and the recording in one turn', () => {
  // Break patch BP-Hold: delete `holdTypingPushes();` in beginTransition.
  // Predicted failure: `expected [ ... ] to have a length of 0` (the typing push reaches Swift during the hold).
  it('returns the live text and holds the typing push from then on', () => {
    load(fullText);
    typeAfter('Text of chapter 2.', ' before');
    const began = ff().beginTransition();
    expect(began.ok).toBe(true);
    if (!began.ok) return;
    expect(began.raw).toBe(docText());
    expect(began.raw).toContain('Text of chapter 2. before');
    contentChanged.mockClear();
    typeAfter('Text of chapter 2. before', ' during');
    vi.advanceTimersByTime(200);
    expect(pushedTexts()).toHaveLength(0);
  });

  it('replaces a hold Swift lost track of: the older token is refused as stale', () => {
    load(fullText);
    const first = begin();
    const second = begin();
    expect(second).toBeGreaterThan(first);
    const stale = ff().swapTransition(first, { text: chapter2, kind: 'in' });
    expect(stale.ok).toBe(false);
    if (!stale.ok) expect(stale.reason).toBe('staleToken');
  });
});

describe('swapTransition, zoom in', () => {
  // Break patch BP-NoReplay: delete `if (replaySpec) dispatchAsTyping(view, replaySpec);` in swapTransition.
  // Predicted failure: `expected '<chapter 2>' to be '<chapter 2 with " during">'` (the typing is gone after the swap).
  it('swaps the chapter in and puts the typing done inside it back where it was typed', () => {
    load(fullText);
    const token = begin();
    typeAfter('Text of chapter 2.', ' during');
    const result = ff().swapTransition(token, { text: chapter2, kind: 'in', scrollToStart: true });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const expected = chapter2.replace('Text of chapter 2.', 'Text of chapter 2. during');
    expect(docText()).toBe(expected);
    expect(result.raw).toBe(expected);
    expect(result.replayed).toBe(1);
    expect(result.outside).toBeNull();
    expect(view.state.selection.main.head).toBe(expected.indexOf(' during') + ' during'.length);
  });

  // Break patch BP-NoDiscard: in swapTransition replace `releaseTypingPushes('discard')` by `releaseTypingPushes('send')`.
  // Predicted failure: the first push carries the pre-swap whole document (`expected [...] to equal [ '<chapter 2 with during>' ]`).
  it('drops the push owed for the held typing: the only push after the swap is the replayed text', () => {
    load(fullText);
    const token = begin();
    typeAfter('Text of chapter 2.', ' during');
    vi.advanceTimersByTime(200);
    expect(pushedTexts()).toHaveLength(0);
    ff().swapTransition(token, { text: chapter2, kind: 'in', scrollToStart: true });
    vi.advanceTimersByTime(200);
    expect(pushedTexts()).toEqual([chapter2.replace('Text of chapter 2.', 'Text of chapter 2. during')]);
  });

  it('makes the replay one undo step: Cmd-Z takes the carried typing out and leaves the chapter as the rows have it', () => {
    load(fullText);
    const token = begin();
    typeAfter('Text of chapter 2.', ' one');
    typeAfter('Text of chapter 2. one', ' two');
    const result = ff().swapTransition(token, { text: chapter2, kind: 'in' });
    expect(result.ok && result.replayed).toBe(2);
    expect(docText()).toContain('Text of chapter 2. one two');
    undo(view);
    expect(docText()).toBe(chapter2);
  });

  // Break patch BP-NoOutside: in planCarry replace the `const outside = ...` expression by `null`.
  // Predicted failure: `expected null to be '<full text with " outside" in chapter 3>'`.
  it('hands back typing outside the zoomed chapter as the step-1 text with only that typing in it', () => {
    load(fullText);
    const token = begin();
    typeAfter('Text of chapter 3.', ' outside');
    typeAfter('Text of chapter 2.', ' inside');
    const result = ff().swapTransition(token, { text: chapter2, kind: 'in', scrollToStart: true });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.outside).toBe(fullText.replace('Text of chapter 3.', 'Text of chapter 3. outside'));
    expect(docText()).toBe(chapter2.replace('Text of chapter 2.', 'Text of chapter 2. inside'));
    expect(result.replayed).toBe(1);
  });

  it('carries a typed paragraph break (Enter) inside the chapter', () => {
    load(fullText);
    const token = begin();
    typeAfter('More of chapter 2.', '\n\nA new paragraph.');
    const result = ff().swapTransition(token, { text: chapter2, kind: 'in' });
    expect(result.ok).toBe(true);
    expect(docText()).toBe(`${chapter2}\n\nA new paragraph.`);
  });

  // Break patch BP-Straddle: in planCarry replace `refusal = 'straddle';` by `outsideTouched = true;`.
  // Predicted failure: `expected true to be false` (a delete across the chapter's edge is swapped, half of it lost).
  it('refuses a deletion across the chapter edge and leaves the live text as the user had it, sending the held typing once', () => {
    load(fullText);
    const token = begin();
    const edge = docText().indexOf(anchor(ID2));
    deleteRange(edge - 5, edge + 4);
    const before = docText();
    vi.advanceTimersByTime(200);
    expect(pushedTexts()).toHaveLength(0);
    const result = ff().swapTransition(token, { text: chapter2, kind: 'in' });
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe('straddle');
    expect(result.raw).toBe(before);
    expect(docText()).toBe(before);
    // Break patch BP-RefuseDiscard: in swapTransition's `refuse` replace `endHold('send')` by `endHold('discard')`.
    // Predicted failure: `expected [] to equal [ '<live text>' ]`.
    expect(pushedTexts()).toEqual([before]);
  });

  // Break patch BP-NoSlice: in planCarry replace `bFrom = body.length > 0 ? unique(base, body) : -1;` by `bFrom = 0;`.
  // Predicted failure: `expected true to be false` (a target whose chapter is not in the step-1 text is swapped with the typing misplaced).
  it('refuses when the target chapter is not exactly in the step-1 text and typing was recorded', () => {
    load(fullText);
    const token = begin();
    typeAfter('Text of chapter 2.', ' during');
    const normalised = chapter2.replace('More of chapter 2.', 'More of chapter 2 (as the rows have it).');
    const result = ff().swapTransition(token, { text: normalised, kind: 'in' });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toBe('slice');
  });

  it('needs no match at all when nothing was typed: the swap is the old push', () => {
    load(fullText);
    const token = begin();
    const other = `${anchor(ID2)}# Chapter 2\n\nSomething else entirely.`;
    const result = ff().swapTransition(token, { text: other, kind: 'in', scrollToStart: true });
    expect(result.ok).toBe(true);
    expect(docText()).toBe(other);
    expect(result.ok && result.replayed).toBe(0);
  });

  // Break patch BP-NotTyping: delete `if (changes.some((change) => !change.carriable)) return { ok: false, reason: 'changed' };`.
  // Predicted failure: `expected true to be false` (a Swift push recorded in the hold is replayed on top of rows that already hold it).
  it('refuses when a change that is not typing landed during the hold (the rows already hold it)', () => {
    load(fullText);
    const token = begin();
    ff().setContent(fullText.replace('Text of chapter 2.', 'Text of chapter 2. pushed'));
    const result = ff().swapTransition(token, {
      text: chapter2.replace('Text of chapter 2.', 'Text of chapter 2. pushed'),
      kind: 'in',
    });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toBe('changed');
  });
});

describe('swapTransition, zoom out', () => {
  it('puts the typing done in the zoomed chapter back at its place in the whole text', () => {
    load(chapter2);
    const token = begin();
    typeAfter('More of chapter 2.', ' later');
    typeAt(docText().indexOf('Text of chapter 2.'), 'Early ');
    const result = ff().swapTransition(token, { text: fullText, kind: 'out' });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const expected = fullText
      .replace('More of chapter 2.', 'More of chapter 2. later')
      .replace('Text of chapter 2.', 'Early Text of chapter 2.');
    expect(docText()).toBe(expected);
    expect(result.replayed).toBe(2);
    expect(result.outside).toBeNull();
  });

  it('finds the zoomed chapter in the whole text past its mini-Notes, and carries typing in the chapter', () => {
    load(zoomedFootnoted);
    const token = begin();
    typeAfter('Text of chapter 2.[^1]', ' And more.');
    const result = ff().swapTransition(token, { text: fullFootnoted, kind: 'out' });
    expect(result.ok).toBe(true);
    expect(docText()).toBe(fullFootnoted.replace('Text of chapter 2.[^1]', 'Text of chapter 2.[^1] And more.'));
  });

  // Break patch BP-NotesOut: in planCarry replace `if (kind === 'out') refusal = 'outside';` by `outsideTouched = true;`.
  // Predicted failure: `expected true to be false` (typing in the mini-Notes is dropped by the zoom out without a word).
  it('refuses typing in the mini-Notes (it has no place in the whole text: the catch-up saves it)', () => {
    load(zoomedFootnoted);
    const token = begin();
    typeAfter('[^1]: The note.', ' Edited.');
    const result = ff().swapTransition(token, { text: fullFootnoted, kind: 'out' });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.reason).toBe('outside');
      expect(result.raw).toContain('The note. Edited.');
    }
  });
});

describe('endTransition', () => {
  it('ends a hold whose swap never came and sends the held typing push once', () => {
    load(fullText);
    begin();
    typeAfter('Text of chapter 1.', ' held');
    vi.advanceTimersByTime(200);
    expect(pushedTexts()).toHaveLength(0);
    expect(ff().endTransition(null).ended).toBe(true);
    expect(pushedTexts()).toEqual([docText()]);
    typeAfter('Text of chapter 1. held', ' after');
    vi.advanceTimersByTime(200);
    expect(pushedTexts()).toHaveLength(2);
  });

  it('ignores a stale token', () => {
    load(fullText);
    const token = begin();
    expect(ff().endTransition(token + 1).ended).toBe(false);
    expect(ff().endTransition(token).ended).toBe(true);
  });
});
