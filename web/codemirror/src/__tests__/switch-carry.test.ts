// @vitest-environment jsdom
//
// Phase 5 jobs A9 and A10 (t-94369a83; design docs/architecture/write-queue-plan/phase5/a7-a10-design.md, sections 3 and 4; run record
// docs/architecture/write-queue-plan/phase5/a9-notes.md): the Markdown page's calls in a switch between Rich Text and Markdown, on the REAL
// page (main.ts imported into jsdom, so the real update listeners track, hold and push).
//   A9, the INCOMING page (api-switch.ts): `prepareIncomingSwitch` (TransIncomingReady), `applySwitchCarry` (TransSwap's carry, mapped over
//   typing done on this page since), `finishIncomingSwitch`.
//   A10, the OUTGOING page (api-transition.ts): `takeTransitionText` reads the held text without ending the hold.
// Each test names the break patch (a small edit of the module) that makes it fail; the results are in a9-notes.md.

import { undo } from '@codemirror/commands';
import { EditorView } from '@codemirror/view';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { SwitchCarryResult } from '../api-switch';
import type { MarkdownTransitionBeginResult, MarkdownTransitionTakeResult } from '../api-transition';

type FF = {
  setContent: (md: string, options?: unknown) => void;
  resetForProjectSwitch: () => void;
  clearStructuralUndoRegistry: () => void;
  prepareIncomingSwitch: () => { ok: boolean; chars: number };
  applySwitchCarry: (options: {
    from: string;
    to: string;
    cursor?: { line: number; column: number } | null;
  }) => SwitchCarryResult;
  finishIncomingSwitch: (mode?: 'send' | 'discard') => { ended: boolean };
  beginTransition: () => MarkdownTransitionBeginResult;
  takeTransitionText: (token: number) => MarkdownTransitionTakeResult;
  endTransition: (token: number | null, mode?: 'send' | 'discard') => { ended: boolean };
};

const ff = (): FF => (window as unknown as { FinalFinal: FF }).FinalFinal;

let view: EditorView;
let contentChanged: ReturnType<typeof vi.fn>;
let resetUndoCoordinatorState: () => void;
let resetMarkdownTransitionForTests: () => void;
let resetIncomingSwitchForTests: () => void;

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

const anchor = (id: string): string => `<!-- @sid:${id} -->`;
const ID1 = '11111111-1111-1111-1111-111111111111';
const ID2 = '22222222-2222-2222-2222-222222222222';
const S0 = `${anchor(ID1)}# Chapter 1\n\nText of chapter 1.\n\n${anchor(ID2)}# Chapter 2\n\nText of chapter 2.`;

function load(text: string): void {
  resetUndoCoordinatorState();
  resetMarkdownTransitionForTests();
  resetIncomingSwitchForTests();
  ff().clearStructuralUndoRegistry();
  ff().resetForProjectSwitch();
  ff().setContent(text);
  ff().resetForProjectSwitch();
  view = currentView();
  vi.advanceTimersByTime(200);
  contentChanged.mockClear();
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
  ({ resetIncomingSwitchForTests } = await import('../api-switch'));
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
  resetIncomingSwitchForTests();
  resetMarkdownTransitionForTests();
  resetUndoCoordinatorState();
  ff().finishIncomingSwitch('discard');
  vi.useRealTimers();
});

describe('A9: the incoming Markdown page (api-switch.ts)', () => {
  // Break patch A9-BP-Hold: delete `holdTypingPushes();` in prepareIncomingSwitch.
  // Predicted failure: a push reaches Swift while the switch is still writing the carry (`expected [...] to have length 0`).
  it('holds the typing push from the prepare until the finish, then sends it once', () => {
    load(S0);
    expect(ff().prepareIncomingSwitch().ok).toBe(true);
    typeAt(docText().length, ' typed');
    vi.advanceTimersByTime(200);
    expect(pushedTexts()).toHaveLength(0);
    ff().finishIncomingSwitch('send');
    expect(pushedTexts()).toEqual([`${S0} typed`]);
  });

  // Break patch A9-BP-NoCarry: return before the dispatch in applySwitchCarry (`return {ok: true, spans: 0, ...}` first thing).
  // Predicted failure: the carried words are missing from the page.
  it('puts the carried typing in, with the caret after it, when nothing was typed here', () => {
    load(S0);
    ff().prepareIncomingSwitch();
    const to = S0.replace('Text of chapter 1.', 'Text of chapter 1. carried');
    // The outgoing editor's caret at the take: after the words typed there.
    const end = 'Text of chapter 1. carried'.length;
    const reply = ff().applySwitchCarry({ from: S0, to, cursor: { line: 3, column: end } });
    expect(reply.ok).toBe(true);
    expect(docText()).toBe(to);
    typeAt(view.state.selection.main.head, '!');
    expect(docText()).toBe(to.replace('carried', 'carried!'));
  });

  // Break patch A9-BP-NoMap: use `carry` instead of `carry.map(incoming.since, true)` (no mapping over typing done here).
  // Predicted failure: the words typed here are moved or overwritten (the document is not the expected merge).
  it('maps the carry over typing done on this page since the flip; nothing is lost or reordered', () => {
    load(S0);
    ff().prepareIncomingSwitch();
    // After the flip the user goes on typing on the new page (in chapter 2), before the carry arrives.
    typeAt(docText().indexOf('Text of chapter 2.') + 'Text of chapter 2.'.length, ' here');
    const to = S0.replace('Text of chapter 1.', 'Text of chapter 1. carried');
    expect(ff().applySwitchCarry({ from: S0, to }).ok).toBe(true);
    expect(docText()).toBe(to.replace('Text of chapter 2.', 'Text of chapter 2. here'));
  });

  // Break patch A9-BP-Order: `carry.map(incoming.since, false)` (the carry placed after typing done here at the same place).
  // Predicted failure: `abcd` comes out as `dabc` (the later keys before the earlier ones).
  it('puts the carried keys before keys typed here at the same place (they were typed first)', () => {
    load(S0);
    ff().prepareIncomingSwitch();
    const at = docText().indexOf('Text of chapter 2.') + 'Text of chapter 2.'.length;
    typeAt(at, 'd');
    const to = S0.replace('Text of chapter 2.', 'Text of chapter 2.abc');
    expect(ff().applySwitchCarry({ from: S0, to }).ok).toBe(true);
    expect(docText()).toBe(S0.replace('Text of chapter 2.', 'Text of chapter 2.abcd'));
    // The caret stays after the key typed here.
    typeAt(view.state.selection.main.head, 'e');
    expect(docText()).toBe(S0.replace('Text of chapter 2.', 'Text of chapter 2.abcde'));
  });

  // Hand test 2026-11-06 (a9-notes.md, "Cursor fix and switch notice"): the carry " box" was typed in the middle of a paragraph, right
  // before a space; the diff finds it one character later ("box " after the space). Break patch A9-BP-Slide (`slideToLocalTyping`
  // returns `spec` unchanged). Predicted failure: `Text of ive box chapter 2.` (the keys typed here before the carried ones).
  it('puts keys typed here after a carry whose diff slid past a repeated character', () => {
    load(S0);
    ff().prepareIncomingSwitch();
    const at = docText().indexOf('Text of chapter 2.') + 'Text of'.length;
    typeAt(at, 'ive');
    const to = S0.replace('Text of chapter 2.', 'Text of box chapter 2.');
    expect(ff().applySwitchCarry({ from: S0, to }).ok).toBe(true);
    expect(docText()).toBe(S0.replace('Text of chapter 2.', 'Text of boxive chapter 2.'));
  });

  // Break patch A9-BP-NoRebase: keep `incoming.since` unchanged after a carry (not re-expressed over it).
  // Predicted failure: the second carry (the catch-up) is applied at the wrong place or throws.
  it('takes a second carry (the catch-up) on top of the first and of typing done in between', () => {
    load(S0);
    ff().prepareIncomingSwitch();
    const s1 = S0.replace('Text of chapter 1.', 'Text of chapter 1. one');
    expect(ff().applySwitchCarry({ from: S0, to: s1 }).ok).toBe(true);
    typeAt(docText().length, ' here');
    const s2 = s1.replace('chapter 1. one', 'chapter 1. one two');
    expect(ff().applySwitchCarry({ from: s1, to: s2 }).ok).toBe(true);
    expect(docText()).toBe(`${s2} here`);
  });

  it('maps the catch-up over typing done here before the first carry, too', () => {
    load(S0);
    ff().prepareIncomingSwitch();
    typeAt(docText().indexOf('Text of chapter 1.') + 'Text of chapter 1.'.length, ' here');
    const s1 = S0.replace('Text of chapter 2.', 'Text of chapter 2. one');
    expect(ff().applySwitchCarry({ from: S0, to: s1 }).ok).toBe(true);
    const s2 = s1.replace('chapter 2. one', 'chapter 2. one two');
    expect(ff().applySwitchCarry({ from: s1, to: s2 }).ok).toBe(true);
    expect(docText()).toBe(s2.replace('Text of chapter 1.', 'Text of chapter 1. here'));
  });

  it('refuses a carry whose base is not the text the page was given, and changes nothing', () => {
    load(S0);
    ff().prepareIncomingSwitch();
    const reply = ff().applySwitchCarry({ from: `${S0}x`, to: `${S0}xy` });
    expect(reply.ok).toBe(false);
    expect(docText()).toBe(S0);
  });

  it('makes the carry one undo step that leaves typing done here alone', () => {
    load(S0);
    ff().prepareIncomingSwitch();
    const to = S0.replace('Text of chapter 1.', 'Text of chapter 1. carried');
    ff().applySwitchCarry({ from: S0, to });
    expect(docText()).toBe(to);
    undo(view);
    expect(docText()).toBe(S0);
  });
});

describe('A10: the outgoing Markdown page (takeTransitionText)', () => {
  // Break patch A10-BP-TakeEnds: call `endHold('send')` inside takeTransitionText.
  // Predicted failure: the second take is refused (`staleToken`) and the push reaches Swift before the switch has carried the text.
  it('reads the base and the live text without ending the hold; a second take sees later typing', () => {
    load(S0);
    const began = ff().beginTransition();
    if (!began.ok) throw new Error('begin refused');
    typeAt(docText().length, ' one');
    const first = ff().takeTransitionText(began.token);
    expect(first.ok && first.base).toBe(S0);
    expect(first.ok && first.raw).toBe(`${S0} one`);
    typeAt(docText().length, ' two');
    vi.advanceTimersByTime(200);
    expect(pushedTexts()).toHaveLength(0);
    const second = ff().takeTransitionText(began.token);
    expect(second.ok && second.raw).toBe(`${S0} one two`);
    expect(second.ok && second.cursor.line).toBe(S0.split('\n').length);
    ff().endTransition(began.token, 'discard');
    vi.advanceTimersByTime(200);
    expect(pushedTexts()).toHaveLength(0);
  });

  it('refuses a stale token', () => {
    load(S0);
    expect(ff().takeTransitionText(9999).ok).toBe(false);
  });
});
