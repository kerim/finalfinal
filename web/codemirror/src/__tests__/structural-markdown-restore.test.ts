// @vitest-environment jsdom
//
// t-4a8fd8af, Phase 4b, Markdown slice 4, round B: the PAGE half of the editor-first VERSION HISTORY RESTORES in Markdown mode:
// web/codemirror/src/api-structural-markdown-restore.ts, `markdownStructuralRestore` (the click: whole / section / insertAfter), and the
// undo / redo / redo-carry of a 'restore' entry in api-structural-markdown.ts (`markdownStructuralSwap`, `buildSwappedState`, `composedRedo`).
//
// These tests drive the REAL page, like structural-markdown-duplicate.test.ts (whose fixtures and helpers they reuse): they import the real
// main.ts (the real extension set, the real update listeners, the real window.FinalFinal) into jsdom. Cmd-Z / Cmd-Shift-Z are real
// KeyboardEvents; Swift's side of the bridge is played by the helpers below (setUndoDescriptor, receiveUndoOutcome). The entry point is
// reached through window.FinalFinal, so on code without the feature every test here fails with "markdownStructuralRestore is not a function".
//
// CONTROLS: none among WR1 to WR15. Every one of them must fail without the feature (and each one has a break patch that makes it fail on
// the new code; the patches are written in a later round, the plan's addendum section 11 names the line each one removes).
// WR16 (structural-markdown-restore.perf.test.ts) is a MEASUREMENT, not a test of behaviour. WR17 pins the golden request.

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { redoDepth, undoDepth } from '@codemirror/commands';
import { Transaction } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MarkdownLeader } from '../api-structural-markdown';
import type { MarkdownRestoreResult } from '../api-structural-markdown-restore';
import { resetSetAsideRedo } from '../redo-branch';
import { getRegistry, getUndoDescriptor } from '../undo-coordinator';

type FF = {
  setContent: (md: string, options?: unknown) => void;
  setUndoDescriptor: (d: { undoTopOpId?: string; redoTopOpId?: string }) => void;
  receiveUndoOutcome: (opId: string, outcome: string) => void;
  receiveRedoOutcome: (opId: string, outcome: string) => void;
  resetForProjectSwitch: () => void;
  clearStructuralUndoRegistry: () => void;
  markdownStructuralRestore: (request: string | object) => MarkdownRestoreResult;
  markdownStructuralSwap: (
    opId: string,
    direction: 'undo' | 'redo'
  ) => { ok: boolean; reason?: string; detail?: string };
};
const ff = (): FF => (window as any).FinalFinal as FF;

const OP = '11111111-2222-3333-4444-555555555555';

let errorHandlerMessages: string[];
let view: EditorView;
let resetUndoCoordinatorState: () => void;
let resetRecentUserEditSpan: () => void;

function currentView(): EditorView {
  const dom = document.querySelector('.cm-editor') as HTMLElement | null;
  const v = dom ? EditorView.findFromDOM(dom) : null;
  if (!v) throw new Error('no CodeMirror view mounted by main.ts');
  return v;
}

const docText = (): string => view.state.doc.toString();

/** The user types `text` at document position `pos` (a real transaction with the userEvent a keystroke has). */
function typeAt(pos: number, text: string): void {
  view.dispatch(
    view.state.update({
      changes: { from: pos, insert: text },
      selection: { anchor: pos + text.length },
      userEvent: 'input.type',
    })
  );
}

/** Types `text` right after the `nth` (0-based) occurrence of `marker` in the document. */
function typeAfterNth(marker: string, nth: number, text: string): void {
  let at = -1;
  for (let i = 0; i <= nth; i++) {
    at = docText().indexOf(marker, at + 1);
    if (at < 0) throw new Error(`marker #${nth} not in document: ${marker}`);
  }
  typeAt(at + marker.length, text);
}

const typeAfter = (marker: string, text: string): void => typeAfterNth(marker, 0, text);

/** `typeAt`, with the transaction time given: the history joins typing steps by that time (and adjacency), not by the machine's clock. */
function typeAtTime(pos: number, text: string, time: number): void {
  view.dispatch(
    view.state.update({
      changes: { from: pos, insert: text },
      selection: { anchor: pos + text.length },
      userEvent: 'input.type',
      annotations: Transaction.time.of(time),
    })
  );
}

function caretAt(pos: number): void {
  view.dispatch({ selection: { anchor: pos } });
}

// --- Documents in the shape the Markdown editor shows (blocks separated by a blank line, an anchor in front of every heading) ---

type Block =
  | {
      kind: 'leader';
      id: string;
      level: number;
      title: string;
      anchored?: boolean;
      /** The literal id written into the marker (a restored leader carries the id Swift's plan gave it); `sid(id)` when absent. */
      anchorId?: string;
      managed?: 'notes' | 'bibliography';
      glueMarker?: boolean;
    }
  | { kind: 'break'; id: string; anchored?: boolean; anchorId?: string }
  | { kind: 'text'; text: string; managedRow?: boolean };

interface Built {
  text: string;
  leaders: MarkdownLeader[];
  blocks: Block[];
}

const sid = (id: string): string => {
  let h = 0;
  for (const c of id) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return `${h.toString(16).padStart(8, '0')}-aaaa-bbbb-cccc-dddddddddddd`;
};

const UUID_SHAPE = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i;

/** The request id of the leader the blocks call `tag` (`a2`, `b1`): a real UUID in the uppercase form Swift's `UUID().uuidString` has,
 * derived from the tag so the tests stay readable. A tag that already is a UUID is its own id. */
function uid(tag: string): string {
  if (UUID_SHAPE.test(tag)) return tag;
  let h = 2166136261;
  let hex = '';
  for (let i = 0; i < 32; i++) {
    for (const c of `${tag}#${i}`) h = Math.imul(h ^ c.charCodeAt(0), 16777619) >>> 0;
    hex += (h & 15).toString(16);
  }
  const s = hex.toUpperCase();
  return `${s.slice(0, 8)}-${s.slice(8, 12)}-4${s.slice(12, 15)}-8${s.slice(15, 18)}-${s.slice(18, 30)}`;
}

/** `trailing` is what the document ends with: the blocks are joined by a blank line and end with one newline by default. */
function build(blocks: Block[], trailing = '\n'): Built {
  const parts: string[] = [];
  const leaders: MarkdownLeader[] = [];
  for (const b of blocks) {
    if (b.kind === 'text') {
      parts.push(b.text);
    } else if (b.kind === 'break') {
      const anchor = b.anchored === false ? '' : `<!-- @sid:${b.anchorId ?? sid(b.id)} -->`;
      parts.push(`${anchor}<!-- ::break:: -->`);
      leaders.push({ id: uid(b.id), line: '<!-- ::break:: -->', level: 1 });
    } else {
      const line = `${'#'.repeat(b.level)} ${b.title}`;
      const anchor = b.anchored === false ? '' : `<!-- @sid:${b.anchorId ?? sid(b.id)} -->`;
      const glue = b.glueMarker ? '<!-- ::auto-bibliography:: -->' : '';
      parts.push(`${glue}${anchor}${line}`);
      leaders.push({ id: uid(b.id), line, level: b.level, ...(b.managed ? { managed: b.managed } : {}) });
    }
  }
  return { text: `${parts.join('\n\n')}${trailing}`, leaders, blocks };
}

/** The text Swift sends for `blocks`: the blocks assembled the way the rows assemble, no trailing newline. */
const textOf = (blocks: Block[]): string => build(blocks, '').text;

/** Ids of the hex alphabet, the way Swift's `UUID().uuidString` is: the id the plan gives the `n`-th new leader of a restore. */
const cid = (n: number): string => `c0c0c0c0-0000-4000-8000-${String(n).padStart(12, '0')}`;

/** A chapter: a level-1 heading tagged `a<n>` (its request id is `uid('a<n>')`, a real UUID) and one line of text. */
const ch = (
  n: number,
  body = `Text of chapter ${n}.`,
  extra: Partial<Extract<Block, { kind: 'leader' }>> = {}
): Block[] => [
  { kind: 'leader', id: `a${n}`, level: 1, title: `Chapter ${n}`, ...extra },
  { kind: 'text', text: body },
];

/** A sub-section: a level-2 heading and one line of text. */
const sub = (id: string, title: string, level = 2): Block[] => [
  { kind: 'leader', id, level, title },
  { kind: 'text', text: `Text of ${title.toLowerCase()}.` },
];

/** A brand new section as a restore inserts it: its leader carries the id the plan gave it. */
const freshSection = (n = 1): Block[] => [
  { kind: 'leader', id: `fresh${n}`, level: 1, title: `Restored chapter ${n}`, anchorId: cid(n) },
  { kind: 'text', text: `Body of the restored chapter ${n}.` },
];

/** The Notes and Bibliography rows, as the Markdown editor shows them (the opening marker glued to the Bibliography heading line). */
const region = (notesLevel = 2): Block[] => [
  { kind: 'leader', id: 'hn', level: notesLevel, title: 'Notes', managed: 'notes' },
  { kind: 'text', text: '[^1]: A note.' },
  { kind: 'leader', id: 'hb', level: 1, title: 'Bibliography', managed: 'bibliography', glueMarker: true },
  { kind: 'text', text: 'Smith, J. (2020). A book.' },
  { kind: 'text', text: '<!-- ::auto-bibliography-end:: -->' },
];

function load(text: string): void {
  // A fresh document with fresh text history, exactly as opening a project does, then the starting text; empty structural-undo state.
  resetUndoCoordinatorState();
  resetRecentUserEditSpan();
  resetSetAsideRedo();
  ff().clearStructuralUndoRegistry();
  ff().resetForProjectSwitch();
  ff().setContent(text);
  ff().resetForProjectSwitch();
  view = currentView();
  undoRequested().mockClear();
  redoRequested().mockClear();
  errorHandlerMessages.length = 0;
  expect(docText()).toBe(text);
  expect(undoDepth(view.state)).toBe(0);
  expect(redoDepth(view.state)).toBe(0);
}

// --- The request Swift would send ---

type Mode = 'whole' | 'section' | 'insertAfter';

/** The trimmed first line of the first Notes/Bibliography row after the block tagged `rootTag` (from the start of the document when null). */
function stopLineAfter(built: Built, rootTag: string | null): string | null {
  const rootIdx = rootTag === null ? -1 : built.blocks.findIndex((b) => b.kind !== 'text' && b.id === rootTag);
  for (const b of built.blocks.slice(rootIdx + 1)) {
    if (b.kind === 'leader' && b.managed) return `${'#'.repeat(b.level)} ${b.title}`;
    if (b.kind === 'text' && b.managedRow) return b.text.split('\n')[0].trim();
  }
  return null;
}

/** The request for restoring with `text` in `mode`; `rootTag` names the target heading (section) or the anchor (insertAfter, null = none). */
function requestFor(
  built: Built,
  mode: Mode,
  rootTag: string | null,
  text: string,
  opId = OP
): Record<string, unknown> {
  return {
    kind: 'restore',
    opId,
    mode,
    rootId: mode === 'whole' || rootTag === null ? null : uid(rootTag),
    leaders: built.leaders,
    stopLine: mode === 'whole' ? null : stopLineAfter(built, rootTag),
    endLeaderId: null,
    text,
  };
}

/** The click, then what Swift does once the entry is recorded: push the descriptor. */
function click(built: Built, mode: Mode, rootTag: string | null, text: string, opId = OP): MarkdownRestoreResult {
  const result = ff().markdownStructuralRestore(JSON.stringify(requestFor(built, mode, rootTag, text, opId)));
  if (result.ok) ff().setUndoDescriptor({ undoTopOpId: opId });
  return result;
}

// --- Cmd-Z / Cmd-Shift-Z through the real listeners, Swift's side played ---

const messageHandler = (name: string): ReturnType<typeof vi.fn> =>
  (window as any).webkit.messageHandlers[name].postMessage as ReturnType<typeof vi.fn>;
const undoRequested = (): ReturnType<typeof vi.fn> => messageHandler('structuralUndoRequested');
const redoRequested = (): ReturnType<typeof vi.fn> => messageHandler('structuralRedoRequested');

/** A real Cmd-Z / Cmd-Shift-Z keydown on the editor. */
function press(direction: 'undo' | 'redo'): void {
  const isRedo = direction === 'redo';
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', {
      key: isRedo ? 'Z' : 'z',
      code: 'KeyZ',
      keyCode: 90,
      ctrlKey: true, // jsdom's navigator.platform is not a Mac, so CodeMirror's `Mod` is Ctrl; the page accepts meta or ctrl
      shiftKey: isRedo,
      bubbles: true,
      cancelable: true,
    })
  );
}

/** One structural Cmd-Z: the press (must be routed structural), Swift's swap of the entry, Swift's reply. This is what Swift's
 * performed undo does with the page. */
function structuralUndo(opId = OP): void {
  const before = undoRequested().mock.calls.length;
  press('undo');
  expect(undoRequested().mock.calls.length, 'the Cmd-Z was not routed structural').toBe(before + 1);
  const result = ff().markdownStructuralSwap(opId, 'undo');
  expect(result.ok, `the undo swap failed: ${JSON.stringify(result)}`).toBe(true);
  ff().setUndoDescriptor({ redoTopOpId: opId });
  ff().receiveUndoOutcome(opId, 'performed');
}

/** One structural Cmd-Shift-Z. */
function structuralRedo(opId = OP): void {
  const before = redoRequested().mock.calls.length;
  press('redo');
  expect(redoRequested().mock.calls.length, 'the Cmd-Shift-Z was not routed structural').toBe(before + 1);
  const result = ff().markdownStructuralSwap(opId, 'redo');
  expect(result.ok, `the redo swap failed: ${JSON.stringify(result)}`).toBe(true);
  ff().setUndoDescriptor({ undoTopOpId: opId });
  ff().receiveRedoOutcome(opId, 'performed');
}

/** Whether `text` has a heading or section break that does not start its own block (no blank line before it), or an anchor in the middle of a line. */
function gluedHeadings(text: string): string[] {
  const lines = text.split('\n');
  const glued: string[] = [];
  lines.forEach((line, index) => {
    const isLeader = /^(?:<!-- @sid:[0-9a-f-]+ -->)?(?:#{1,6}[ \t]|<!-- ::break:: -->)/.test(line);
    if (isLeader && index > 0 && lines[index - 1] !== '') glued.push(line);
    else if (/\S<!-- @sid:/.test(line)) glued.push(line);
  });
  return glued;
}

beforeAll(async () => {
  // jsdom has no layout engine; installLineHeightFix (run by main.ts and by resetForProjectSwitch) measures with Range.
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

  errorHandlerMessages = [];
  (window as any).webkit = {
    messageHandlers: {
      structuralUndoRequested: { postMessage: vi.fn() },
      structuralRedoRequested: { postMessage: vi.fn() },
      structuralUndoRefused: { postMessage: vi.fn() },
      historyEdited: { postMessage: vi.fn() },
      contentChanged: { postMessage: vi.fn() },
      sectionChanged: { postMessage: vi.fn() },
      undoHeldPressSettled: { postMessage: vi.fn() },
      undoQueueDropped: { postMessage: vi.fn() },
      errorHandler: {
        postMessage: (m: { message?: string }) => {
          if (m?.message) errorHandlerMessages.push(m.message);
        },
      },
    },
  };

  const root = document.createElement('div');
  root.id = 'editor';
  document.body.appendChild(root);

  // main.ts builds the real extension set, mounts the real editor into #editor at import time, and registers the real window.FinalFinal.
  await import('../main');
  ({ resetUndoCoordinatorState } = await import('../undo-coordinator'));
  ({ resetRecentUserEditSpanForTests: resetRecentUserEditSpan } = await import('../recent-edit-span'));
});

afterAll(() => {
  delete (window as any).webkit;
  document.body.innerHTML = '';
});

beforeEach(() => {
  view = currentView();
});

afterEach(() => {
  vi.useRealTimers();
});

// =============================================================================================================================
// WR1 .. WR5: the ranges and the separators
// =============================================================================================================================

describe('WR1 Replace Current Section replaces the FLAT range of the section', () => {
  // Break patch (round D): in `planRestore` end the section at the next leader whose level is not deeper than the root's, instead of
  // at the next leader of any level.
  // Predicted failure on the new code: the sub-sections `Part 3.1` and `Part 3.2` are gone (the range swallowed them).
  it('WR1 a chapter with two sub-sections: only its own heading and text are replaced, the sub-sections and the next heading are intact', () => {
    const subs = [...sub('b1', 'Part 3.1'), ...sub('b2', 'Part 3.2')];
    const start = build([...ch(1), ...ch(2), ...ch(3), ...subs, ...ch(4)]);
    load(start.text);
    const restored = ch(3, 'Restored text of chapter 3.');

    const result = click(start, 'section', 'a3', textOf(restored));

    expect(result.ok, `restore refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), 'sub-sections or next heading changed').toBe(
      build([...ch(1), ...ch(2), ...restored, ...subs, ...ch(4)]).text
    );
    const firstSub = `<!-- @sid:${sid('b1')} -->`;
    expect(
      docText().slice(docText().indexOf(firstSub)),
      'sub-sections or next heading not byte for byte the same'
    ).toBe(start.text.slice(start.text.indexOf(firstSub)));
    expect(result.preRaw).toBe(start.text);
    expect(result.postRaw).toBe(docText());
    expect(result.insertedLeaderIds).toEqual([sid('a3')]);
    const rootAt = docText().indexOf(`<!-- @sid:${sid('a3')} -->`);
    expect(result.replaced?.from ?? -1).toBeGreaterThanOrEqual(rootAt);
    expect(result.replaced?.to ?? Number.POSITIVE_INFINITY).toBeLessThanOrEqual(docText().indexOf(firstSub));
    expect(gluedHeadings(docText())).toEqual([]);
  });
});

describe('WR2 a section that ends the document keeps the document ending', () => {
  // Break patch (round D): in `planRestore` replace to `doc.length` (drop the trailing-newline handling).
  // Predicted failure on the new code: the document lost its trailing newline(s).
  it('WR2 the last chapter is replaced: no trailing newline, one, or a blank line at the end are all kept', () => {
    for (const trailing of ['', '\n', '\n\n']) {
      const start = build([...ch(1), ...ch(2)], trailing);
      load(start.text);
      const restored = ch(2, 'Restored text of chapter 2.');

      const result = click(start, 'section', 'a2', textOf(restored));

      expect(result.ok, `restore refused: ${JSON.stringify(result)}`).toBe(true);
      expect(docText(), `the document ending changed (trailing ${JSON.stringify(trailing)})`).toBe(
        build([...ch(1), ...restored], trailing).text
      );
    }
  });
});

describe('WR3 Insert as New Section without an anchor goes in before Notes and Bibliography', () => {
  const notesFrom = (text: string): string => text.slice(text.indexOf(`<!-- @sid:${sid('hn')} -->`));

  // Break patch (round D): in `planRestore` leave the managed Notes/Bibliography leader out of the end search (no anchor).
  // Predicted failure on the new code: the new section went in after the Bibliography (case 2 below, where only the managed rule applies).
  it('WR3 the new section is inserted at the Notes heading, and the Notes and Bibliography text is byte for byte the same', () => {
    const body = 'Text of chapter 2.[^1]';
    const start = build([...ch(1), ...ch(2, body), ...region()]);
    const fresh = freshSection();
    const expected = build([...ch(1), ...ch(2, body), ...fresh, ...region()]).text;

    // 1. The request a real click sends: the stop line names the Notes heading.
    load(start.text);
    const notesBefore = notesFrom(docText());
    const result = click(start, 'insertAfter', null, textOf(fresh));
    expect(result.ok, `restore refused: ${JSON.stringify(result)}`).toBe(true);
    expect(notesFrom(docText()), 'Notes region changed').toBe(notesBefore);
    expect(docText()).toBe(expected);
    expect(result.insertedLeaderIds).toEqual([cid(1)]);

    // 2. No stop line at all: the managed leader alone ends the search.
    load(start.text);
    const bare = { ...requestFor(start, 'insertAfter', null, textOf(fresh)), stopLine: null };
    const bareResult = ff().markdownStructuralRestore(JSON.stringify(bare));
    expect(bareResult.ok, `restore refused: ${JSON.stringify(bareResult)}`).toBe(true);
    expect(docText(), 'the new section went in behind Notes and Bibliography').toBe(expected);
  });

  // Break patch (round D): in `planRestore` ignore the stop line hit.
  // Predicted failure on the new code: the new section went in between the standalone bibliography marker line and the Bibliography heading.
  it('WR3 the first Notes/Bibliography row is a standalone marker line in front of the Bibliography heading: the insertion stops in front of it', () => {
    const tail: Block[] = [
      { kind: 'text', text: '<!-- ::auto-bibliography:: -->', managedRow: true },
      { kind: 'leader', id: 'hb', level: 2, title: 'Bibliography', managed: 'bibliography' },
      { kind: 'text', text: 'Smith, J. (2020). A book.' },
      { kind: 'text', text: '<!-- ::auto-bibliography-end:: -->' },
    ];
    const start = build([...ch(1), ...ch(2), ...tail]);
    load(start.text);
    const fresh = freshSection();

    const result = click(start, 'insertAfter', null, textOf(fresh));

    expect(result.ok, `restore refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), 'Notes region changed').toBe(build([...ch(1), ...ch(2), ...fresh, ...tail]).text);
  });
});

describe('WR4 Insert as New Section at the end of the document', () => {
  // Break patch (round D): in `planRestore` drop the "\n\n" in front of the text at the end of the document.
  // Predicted failure on the new code: the new heading is glued to the last line of the section before it.
  //
  // Break patch (C21, code review): in `insertionPlan` give `moved` the start `at` instead of `endsDocument && at > 0 ? at + 2 : at` (the
  // Duplicate's rule: `moved` starts BEHIND the `\n\n` in front of the text, so typing appended to the end of the section before the
  // insertion, at `at`, is not counted as typing inside the inserted text). Predicted failure on the new code: `moved starts in front of
  // the blank line`.
  it('WR4 a blank line is put in front of the new section and the document ending is kept, whatever the ending was', () => {
    for (const trailing of ['', '\n', '\n\n']) {
      const start = build([...ch(1), ...ch(2)], trailing);
      load(start.text);
      const fresh = freshSection();
      const at = start.text.length - trailing.length; // where the text goes in: the end of the last line, before the trailing newlines

      const result = click(start, 'insertAfter', 'a2', textOf(fresh));

      expect(result.ok, `restore refused: ${JSON.stringify(result)}`).toBe(true);
      expect(gluedHeadings(docText()), `heading glued (trailing ${JSON.stringify(trailing)})`).toEqual([]);
      expect(docText(), `the document ending changed (trailing ${JSON.stringify(trailing)})`).toBe(
        build([...ch(1), ...ch(2), ...fresh], trailing).text
      );
      const extras = getRegistry().get(OP)?.markdown;
      expect(
        extras?.kind === 'restore' ? (extras.moved?.from ?? -1) : -1,
        `moved starts in front of the blank line (trailing ${JSON.stringify(trailing)})`
      ).toBe(at + 2);
    }
  });
});

describe('WR5 Restore Entire Project is a refined difference, not one big replace', () => {
  // Break patch (round D): in `planRestore` replace the refined diff by `{ from: 0, to: doc.length, insert: text }`.
  // Predicted failure on the new code: `unchanged text is inside a changed range` (and the caret moved).
  it('WR5 the document equals the text exactly, a caret in an unchanged paragraph stays at its text, and unchanged text is outside every changed range', () => {
    const chapters = [1, 2, 3, 4, 5, 6];
    const start = build(chapters.flatMap((n) => ch(n)));
    load(start.text);
    const caretOffset = 5;
    const unchangedFrom = start.text.indexOf('Text of chapter 3.');
    const unchangedTo = unchangedFrom + 'Text of chapter 3.'.length;
    caretAt(unchangedFrom + caretOffset);
    const restored = build(
      chapters.flatMap((n) => ch(n, n === 2 || n === 5 ? `Restored text of chapter ${n}.` : undefined))
    );

    const result = click(start, 'whole', null, restored.text);

    expect(result.ok, `restore refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), 'post-op text is not `text` exactly').toBe(restored.text);
    expect(result.postRaw).toBe(restored.text);
    expect(view.state.selection.main.head, 'the caret left its text').toBe(
      docText().indexOf('Text of chapter 3.') + caretOffset
    );
    const entry = getRegistry().get(OP);
    expect(entry?.markdown?.kind).toBe('restore');
    const ranges: Array<{ fromA: number; toA: number }> = [];
    entry?.markdown?.opChanges.iterChangedRanges((fromA, toA) => {
      ranges.push({ fromA, toA });
    });
    expect(ranges.length, 'the change is not the refined diff').toBeGreaterThanOrEqual(2);
    for (const range of ranges) {
      expect(
        range.toA <= unchangedFrom || range.fromA >= unchangedTo,
        `unchanged text is inside a changed range (${range.fromA}..${range.toA})`
      ).toBe(true);
    }
    const changedLength = ranges.reduce((sum, range) => sum + (range.toA - range.fromA), 0);
    expect(changedLength, 'the change is not the refined diff').toBeLessThan(start.text.length / 2);
  });
});

// =============================================================================================================================
// WR6, WR7: refusals change nothing
// =============================================================================================================================

describe('WR6 leaders that do not match the text change nothing', () => {
  // Break patch (round D): in `planRestore` do not refuse on a leader mismatch (comment out the `mismatchDetail !== null` return).
  // Predicted failure on the new code: `expected leadersMismatch` (the restore goes ahead on a text the rows do not describe).
  it('WR6 a leader line retitled since the rows were read: leadersMismatch, nothing dispatched, no entry, the document unchanged', () => {
    for (const mode of ['section', 'insertAfter'] as const) {
      const start = build([...ch(1), ...ch(2), ...ch(3)]);
      load(start.text);
      typeAfter('# Chapter 2', ' (retitled)');
      const typedText = docText();
      const depth = undoDepth(view.state);
      const descriptor = { ...getUndoDescriptor() };
      const dispatch = vi.spyOn(view, 'dispatch');

      const result = ff().markdownStructuralRestore(
        JSON.stringify(requestFor(start, mode, 'a2', textOf(ch(2, 'Restored text of chapter 2.'))))
      );

      expect(result.reason, 'expected leadersMismatch').toBe('leadersMismatch');
      expect(result.ok).toBe(false);
      expect(result.detail).toBe('leaderLine index=1');
      expect(dispatch.mock.calls.length, 'a refused restore dispatched').toBe(0);
      dispatch.mockRestore();
      expect(docText(), 'a refused restore changed the document').toBe(typedText);
      expect(undoDepth(view.state)).toBe(depth);
      expect(getRegistry().size, 'a refused restore left an entry').toBe(0);
      expect({ ...getUndoDescriptor() }).toEqual(descriptor);
    }
  });
});

describe('WR7 requests that are no restore are a bad request', () => {
  const chapters = (): Built => build([...ch(1), ...ch(2), ...region()]);
  /** Sends `request` (an object, or a ready JSON text) and checks that nothing changed, was recorded or dispatched. */
  const refuse = (request: Record<string, unknown> | string): MarkdownRestoreResult => {
    const start = chapters();
    load(start.text);
    const dispatch = vi.spyOn(view, 'dispatch');
    const result = ff().markdownStructuralRestore(typeof request === 'string' ? request : JSON.stringify(request));
    expect(dispatch.mock.calls.length, 'a refused restore dispatched').toBe(0);
    dispatch.mockRestore();
    expect(docText(), 'a refused restore changed the document').toBe(start.text);
    expect(getRegistry().size, 'a refused restore left an entry').toBe(0);
    expect(undoDepth(view.state)).toBe(0);
    expect(getUndoDescriptor().undoTopOpId).toBeUndefined();
    expect(result.ok).toBe(false);
    return result;
  };
  const good = (): Record<string, unknown> =>
    requestFor(chapters(), 'section', 'a2', textOf(ch(2, 'Restored text of chapter 2.')));

  // Break patch (round D): in api-structural-markdown.ts `parseRequest` drop the check of the restore `mode`.
  // Predicted failure on the new code: `expected badRequest/mode` (an unknown mode is run as an insertion).
  it('WR7 an unknown mode, a missing or non-string text, a section without a root, a malformed JSON and another kind are refused', () => {
    const unknownMode = refuse({ ...good(), mode: 'swap' });
    expect(unknownMode.reason, 'expected badRequest/mode').toBe('badRequest');
    expect(unknownMode.detail, 'expected badRequest/mode').toBe('mode');

    const missingText = good();
    missingText.text = undefined;
    expect(refuse(missingText).detail, 'expected badRequest/text').toBe('text');
    expect(refuse({ ...good(), text: 5 }).detail, 'expected badRequest/text').toBe('text');

    const noRoot = refuse({ ...good(), rootId: null });
    expect(noRoot.reason).toBe('badRequest');
    expect(noRoot.detail).toBe('rootId');

    const malformed = refuse('{"kind":"restore"');
    expect(malformed.reason).toBe('badRequest');
    expect(malformed.detail).toBe('unparsable json');

    const wrongKind = refuse({ ...good(), kind: 'duplicate' });
    expect(wrongKind.reason).toBe('unsupportedKind');
  });

  // Break patch (round D): in `planRestore` drop the `managed` check of the root.
  // Predicted failure on the new code: `expected badRequest/rootIsManaged` (the Notes heading is replaced).
  it('WR7 the Notes heading as the target of a Replace, or as the anchor of an insertion, is refused (rootIsManaged)', () => {
    const start = chapters();
    for (const mode of ['section', 'insertAfter'] as const) {
      const request = { ...requestFor(start, mode, 'hn', textOf(freshSection())) };
      const result = refuse(request);
      expect(result.reason, 'expected badRequest/rootIsManaged').toBe('badRequest');
      expect(result.detail, 'expected badRequest/rootIsManaged').toBe('rootIsManaged');
    }
  });
});

// =============================================================================================================================
// WR8, WR13: one dispatch, the history, the descriptor
// =============================================================================================================================

describe('WR8 one transaction, outside the text history, closing the typing group on both sides', () => {
  // Break patch (round D): in `runRestore` drop `isolateHistory.of('full')` from the dispatch's annotations.
  // Predicted failure on the new code: `typing before and after the restore merged into one undo step`.
  it('WR8 typing right before the click and right after it (next to each other) are two undo steps', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    // Two typing steps next to each other 100 ms apart: inside the history's 500 ms group delay, so only the click between them keeps
    // them apart. The time is given to the transactions, so the result does not depend on how fast the machine runs this test.
    const firstAt = start.text.indexOf('Text of chapter 1.') + 'Text of chapter 1.'.length;
    typeAtTime(firstAt, ' abc', 1_000_000);
    const afterFirst = build([...ch(1, 'Text of chapter 1. abc'), ...ch(2), ...ch(3)]);
    expect(undoDepth(view.state)).toBe(1);

    expect(click(afterFirst, 'section', 'a2', textOf(ch(2, 'Restored text of chapter 2.'))).ok).toBe(true);
    typeAtTime(firstAt + ' abc'.length, ' def', 1_000_100); // next to the earlier typing, 100 ms later

    expect(undoDepth(view.state), 'typing before and after the restore merged into one undo step').toBe(2);
  });

  // Break patch (round D): in `runRestore` dispatch the selection separately after the change (`view.dispatch({ selection });` added).
  // Predicted failure on the new code: `the click dispatched 2 transactions`.
  it('WR8 the click dispatches exactly once in every mode: the change and the selection are one transaction', () => {
    const cases: Array<{ mode: Mode; root: string | null; text: string; start: Built }> = [
      {
        mode: 'section',
        root: 'a2',
        text: textOf(ch(2, 'Restored text of chapter 2.')),
        start: build([...ch(1), ...ch(2), ...ch(3)]),
      },
      { mode: 'insertAfter', root: 'a2', text: textOf(freshSection()), start: build([...ch(1), ...ch(2), ...ch(3)]) },
      {
        mode: 'whole',
        root: null,
        text: build([...ch(1, 'Whole new one.'), ...ch(2), ...ch(3)]).text,
        start: build([...ch(1), ...ch(2), ...ch(3)]),
      },
    ];
    for (const { mode, root, text, start } of cases) {
      load(start.text);
      const dispatch = vi.spyOn(view, 'dispatch');

      const result = click(start, mode, root, text);

      expect(result.ok, `${mode}: ${JSON.stringify(result)}`).toBe(true);
      expect(
        dispatch.mock.calls.length,
        `the ${mode} click dispatched ${dispatch.mock.calls.length} transactions`
      ).toBe(1);
      dispatch.mockRestore();
    }
  });
});

describe('WR13 the undo-top descriptor is set by a successful click and by nothing else', () => {
  // Break patch (round D): in `markdownStructuralRestore` set the descriptor whatever the result (drop `if (result.ok)`).
  // Predicted failure on the new code: `descriptor on failure`.
  it('WR13 a refused click leaves the descriptor alone, an accepted one sets undoTopOpId before Swift pushes anything', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    typeAfter('Text of chapter 2.', '\n\n## Typed heading');
    const before = { ...getUndoDescriptor() };

    const refused = ff().markdownStructuralRestore(
      JSON.stringify(requestFor(start, 'section', 'a2', textOf(ch(2, 'Restored text of chapter 2.'))))
    );
    expect(refused.ok).toBe(false);
    expect({ ...getUndoDescriptor() }, 'descriptor on failure').toEqual(before);

    const fresh = build([...ch(1), ...ch(2), ...ch(3)]);
    load(fresh.text);
    const accepted = ff().markdownStructuralRestore(
      JSON.stringify(requestFor(fresh, 'section', 'a2', textOf(ch(2, 'Restored text of chapter 2.'))))
    );
    expect(accepted.ok, JSON.stringify(accepted)).toBe(true);
    expect(getUndoDescriptor().undoTopOpId, 'descriptor not set by an accepted click').toBe(OP);
  });
});

// =============================================================================================================================
// WR9 .. WR12: undo, redo and the redo carry
// =============================================================================================================================

/** The two scenarios whose typing-inside tests run for the Whole and for the Section restore. `inside` is a text inside the restored part
 * (inside the hull of the change, which is what the redo carry watches). */
function scenario(mode: 'whole' | 'section'): {
  start: Built;
  mode: Mode;
  root: string | null;
  text: string;
  inside: string;
} {
  const start = build([...ch(1), ...ch(2), ...ch(3)]);
  if (mode === 'section') {
    return {
      start,
      mode,
      root: 'a2',
      text: textOf(ch(2, 'Brand new paragraph for the restore.')),
      inside: 'Brand new',
    };
  }
  const restored = build([
    ...ch(1, 'Whole new one.'),
    ...ch(2, 'Entirely different text two.'),
    ...ch(3, 'Third restored.'),
  ]);
  return { start, mode, root: null, text: restored.text, inside: 'Entirely different' };
}

describe('WR9 the redo is the composed redo: it lands on the settled document, the same markers come back', () => {
  // Break patch (round D): in `composedRedo` use `const changes = extras.opChanges;` (skip the settle compose).
  // Predicted failure on the new code: `redo did not land on the settled document` (it lands on the document of the click).
  it('WR9 Replace, an automatic rewrite far away (sync origin), Cmd-Z, Cmd-Shift-Z: doc.eq(postOpDoc), every restored marker once', () => {
    const start = build([...ch(1, 'Text of chapter 1.', { anchored: false }), ...ch(2), ...ch(3)]);
    load(start.text);
    const restored = [
      { kind: 'leader', id: 'a2', level: 1, title: 'Chapter 2', anchorId: cid(7) } as Block,
      { kind: 'text', text: 'Restored text of chapter 2.' } as Block,
    ];
    expect(click(start, 'section', 'a2', textOf(restored)).ok).toBe(true);
    const unsettled = docText();
    const settled = unsettled.replace('# Chapter 1', `<!-- @sid:${sid('a1')} --># Chapter 1`);
    ff().setContent(settled, { origin: 'derived' }); // the rebuild's anchors / the footnote renumber, after the click
    expect(docText()).toBe(settled);
    expect(getRegistry().get(OP)?.postOpDoc.toString(), 'PREMISE: the saved copy followed the rewrite').toBe(settled);

    structuralUndo();
    expect(docText()).toBe(start.text);
    structuralRedo();

    expect(docText(), 'redo did not land on the settled document').toBe(settled);
    const entry = getRegistry().get(OP);
    expect(entry?.postOpDoc.eq(view.state.doc), 'redo did not land on postOpDoc').toBe(true);
    expect(docText().split(`<!-- @sid:${cid(7)} -->`).length - 1, 'the restored marker is not there exactly once').toBe(
      1
    );
    expect(entry?.midOp).toBe(false);
  });
});

describe('WR10 typing done inside the restored text comes back through the redo', () => {
  // Break patch (round D): in `markdownStructuralSwap` delete the `putBackSetAsideRedo(view, opId, depthBeforeRedo);` call.
  // Predicted failure on the new code: `typing inside the restored text did not come back`.
  for (const mode of ['whole', 'section'] as const) {
    it(`WR10 ${mode}: restore, type inside, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z: the typing is back inside the restored text`, () => {
      const { start, root, text, inside } = scenario(mode);
      load(start.text);
      expect(click(start, mode, root, text).ok).toBe(true);
      const post = docText();
      typeAfter(inside, ' TYPED');
      const typed = docText();

      press('undo'); // the typing (a text undo)
      expect(docText()).toBe(post);
      expect(undoRequested()).not.toHaveBeenCalled();
      structuralUndo(); // the restore (Swift performed the undo)
      expect(docText()).toBe(start.text);
      expect(
        redoDepth(view.state),
        'typing inside the restored text was carried across the undo (it must be set aside)'
      ).toBe(0);
      structuralRedo(); // the restore again
      expect(docText()).toBe(post);
      press('redo'); // the typing: set aside by the undo, put back by the redo

      expect(docText(), 'typing inside the restored text did not come back').toBe(typed);
    });
  }
});

describe('WR11 the redo depth is read before the redo, whatever text steps came in between', () => {
  // Break patch (round D): in `swapUndo` record `depthAfterUndo: redoDepth(live)` instead of `redoDepth(view.state)`.
  // Predicted failure on the new code: `typing inside the restored text did not come back` (the put-back is refused).
  for (const mode of ['whole', 'section'] as const) {
    it(`WR11 ${mode}: typing before the restore, type "x" inside it, Cmd-Z, structural Cmd-Z, Cmd-Z, Cmd-Shift-Z, structural Cmd-Shift-Z, Cmd-Shift-Z: "x" is back at its place`, () => {
      const { start, root, text, inside } = scenario(mode);
      load(start.text);
      typeAfter('Text of chapter 1.', ' EARLIER'); // typing before the restore
      const preOp = docText();
      expect(click(start, mode, root, text).ok).toBe(true);
      const post = docText();
      typeAfter(inside, ' x');
      const typed = docText();

      press('undo'); // text: the "x"
      expect(docText()).toBe(post);
      structuralUndo(); // the restore
      expect(docText()).toBe(preOp);
      press('undo'); // text: the earlier typing
      expect(docText()).toBe(start.text);
      press('redo'); // text: the earlier typing again
      expect(docText()).toBe(preOp);
      structuralRedo(); // the restore again
      expect(docText()).toBe(post);
      press('redo'); // text: the "x"

      expect(docText(), 'typing inside the restored text did not come back').toBe(typed);
    });
  }
});

describe('WR12 which redo events the undo carries: the ones inside the changed text are set aside, the others are kept', () => {
  // Break patch (round D): in `buildSwappedState` leave 'restore' out of the `moved` ternary.
  // Predicted failure on the new code: `event at the start of the restored text kept` (the carried list holds it).
  it('WR12 an event at the start of the changed text (moved.from) is dropped from the carried list and comes back with the put-back; one outside is kept', () => {
    const fixture = (): Built => build([...ch(1), ...ch(2), ...ch(3)]);
    const text = textOf(ch(2, 'Brand new paragraph for the restore.'));

    // The event at `moved.from`: typed at the very start of the first changed hunk.
    const start = fixture();
    load(start.text);
    const result = click(start, 'section', 'a2', text);
    expect(result.ok).toBe(true);
    const post = docText();
    typeAt(result.replaced?.from ?? -1, 'X');
    const typed = docText();
    expect(typed.indexOf('XBrand new'), 'PREMISE: X is at the start of the restored text').toBeGreaterThan(0);
    press('undo');
    expect(docText()).toBe(post);
    structuralUndo();
    expect(docText()).toBe(start.text);
    expect(redoDepth(view.state), 'event at the start of the restored text kept').toBe(0);
    structuralRedo();
    expect(docText()).toBe(post);
    press('redo');
    expect(docText(), 'typing at the start of the restored text not back').toBe(typed);

    // The event outside: typed in the next chapter, after the changed text.
    const second = fixture();
    load(second.text);
    expect(click(second, 'section', 'a2', text).ok).toBe(true);
    const secondPost = docText();
    typeAfter('Text of chapter 3.', ' Y');
    const secondTyped = docText();
    press('undo');
    expect(docText()).toBe(secondPost);
    structuralUndo();
    expect(docText()).toBe(second.text);
    expect(redoDepth(view.state), 'event outside the restored text dropped').toBe(1);
    structuralRedo();
    expect(docText()).toBe(secondPost);
    press('redo');
    expect(docText()).toBe(secondTyped);
  });
});

describe('WR14 a redo event inside the replaced text does not survive the Replace', () => {
  // Break patch (round D): in `runRestore` delete the `withoutRedoEventsTouching` line and its `if` (step 1b).
  // Predicted failure on the new code: `redo event inside the replaced section kept` (and the redo types " hello" in front of the next heading).
  it('WR14 type " hello", Cmd-Z, Replace the section with text lacking " hello": the redo list is empty and a redo changes nothing', () => {
    const middle: Block[] = [
      { kind: 'leader', id: 'b0', level: 2, title: 'Section 3.1' },
      { kind: 'text', text: 'First paragraph.' },
      { kind: 'text', text: 'Second paragraph.' },
    ];
    const start = build([...ch(1), ...ch(2), ...middle, ...sub('b1', 'Section 3.2'), ...ch(4)]);
    load(start.text);
    typeAfter('Second paragraph.', ' hello');
    press('undo'); // text: " hello" goes, and waits in the redo list
    expect(docText()).toBe(start.text);
    expect(redoDepth(view.state), 'PREMISE: the typing waits in the redo list').toBe(1);

    const restored: Block[] = [middle[0], middle[1]]; // the version has no second paragraph
    const result = click(start, 'section', 'b0', textOf(restored));

    expect(result.ok, `restore refused: ${JSON.stringify(result)}`).toBe(true);
    expect(redoDepth(view.state), 'redo event inside the replaced section kept').toBe(0);
    const post = docText();
    expect(post).toBe(build([...ch(1), ...ch(2), ...restored, ...sub('b1', 'Section 3.2'), ...ch(4)]).text);
    press('redo');
    expect(docText(), 'a redo changed the document after the Replace').toBe(post);
    expect(docText()).not.toContain(' hello');
  });
});

// =============================================================================================================================
// WR15: the caret and the scroll
// =============================================================================================================================

describe('WR15 the caret stays with its text and the page does not scroll', () => {
  const lastCall = (spy: { mock: { calls: unknown[][] } }): unknown => spy.mock.calls[spy.mock.calls.length - 1]?.[0];

  // Break patch (round D): in `runRestore` delete `selection,` from the dispatch.
  // Predicted failure on the new code: `caret left the Notes heading` (the default mapping keeps a caret at the insertion point in front of the new text).
  it('WR15 Insert as New Section before Notes: the text is `...last section text\\n\\n<new text>\\n\\n<Notes heading>` and a caret at the Notes heading is still there', () => {
    const body = 'Text of chapter 2.';
    const start = build([...ch(1), ...ch(2, body), ...region()]);
    load(start.text);
    const notesMarker = `<!-- @sid:${sid('hn')} -->`;
    caretAt(start.text.indexOf(notesMarker));
    const fresh = freshSection();
    const dispatch = vi.spyOn(view, 'dispatch');

    const result = click(start, 'insertAfter', 'a2', textOf(fresh));

    expect(result.ok, `restore refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText()).toContain(`${body}\n\n${textOf(fresh)}\n\n${notesMarker}## Notes`);
    expect(view.state.selection.main.head, 'caret left the Notes heading').toBe(docText().indexOf(notesMarker));
    expect(view.state.selection.main.empty).toBe(true);
    expect(dispatch.mock.calls.length).toBe(1);
    const spec = lastCall(dispatch) as { scrollIntoView?: boolean; effects?: unknown };
    expect(spec.scrollIntoView, 'the restore scrolls').toBeFalsy();
    expect(spec.effects, 'the restore carries an effect (scrollIntoView)').toBeUndefined();
    dispatch.mockRestore();
  });

  // Break patch (round D): in `runRestore` delete `selection,` from the dispatch (a straddling selection then swells with the change).
  // Predicted failure on the new code: `the selection did not collapse to the start of the changed hunk`.
  it('WR15 Replace Current Section: a caret in an unchanged paragraph keeps its text, a selection over a changed hunk collapses to the hunk start, no scrollIntoView', () => {
    const section = (second: string): Block[] => [
      { kind: 'leader', id: 'a2', level: 1, title: 'Chapter 2' },
      { kind: 'text', text: 'Kept paragraph.' },
      { kind: 'text', text: second },
    ];
    const start = build([...ch(1), ...section('Old second paragraph.'), ...ch(3)]);
    const text = textOf(section('New second paragraph with more words.'));

    // A caret inside the paragraph the version leaves as it is.
    load(start.text);
    const keptAt = start.text.indexOf('Kept paragraph.');
    caretAt(keptAt + 5);
    const dispatch = vi.spyOn(view, 'dispatch');
    expect(click(start, 'section', 'a2', text).ok).toBe(true);
    expect(docText()).toBe(build([...ch(1), ...section('New second paragraph with more words.'), ...ch(3)]).text);
    expect(view.state.selection.main.head, 'caret left its text').toBe(docText().indexOf('Kept paragraph.') + 5);
    expect(dispatch.mock.calls.length).toBe(1);
    const spec = lastCall(dispatch) as { scrollIntoView?: boolean; effects?: unknown };
    expect(spec.scrollIntoView, 'the restore scrolls').toBeFalsy();
    expect(spec.effects, 'the restore carries an effect (scrollIntoView)').toBeUndefined();
    dispatch.mockRestore();

    // A selection from the unchanged paragraph into the changed one collapses to its head, which goes to the start of the hunk.
    load(start.text);
    const oldAt = start.text.indexOf('Old second paragraph.');
    view.dispatch({ selection: { anchor: keptAt + 3, head: oldAt + 2 } });
    expect(click(start, 'section', 'a2', text).ok).toBe(true);
    const main = view.state.selection.main;
    expect(main.empty, 'the selection did not collapse to the start of the changed hunk').toBe(true);
    expect(main.head, 'the selection did not collapse to the start of the changed hunk').toBe(
      docText().indexOf('New second paragraph')
    );
  });

  // Break patch (code review T4): REMOVE THE CARET CLAMP OUTRIGHT in `insertionPlan`, i.e. `place = (pos, assoc) => changes.mapPos(pos, assoc)`
  // with no `endsDocument && pos >= at ? at` case. (The earlier patch "clamp only a caret beyond `at` (`pos > at`)" was a no-op: a caret AT
  // `at` maps to `at` by itself.) Without the clamp the second position below, a caret after the document's trailing newline (`pos` =
  // `start.text.length`, beyond `at`), maps to the end of the INSERTED text, so the loop's second pass fails.
  // Predicted failure on the new code: `caret jumped into the inserted section`.
  it('WR15 Insert as New Section at the end of the document: a caret at the very end stays at the end of the section before it', () => {
    const start = build([...ch(1), ...ch(2)], '\n');
    load(start.text);
    const originalEnd = start.text.length - 1; // the end of the last line
    for (const pos of [originalEnd, start.text.length]) {
      load(start.text);
      caretAt(pos);

      expect(click(start, 'insertAfter', 'a2', textOf(freshSection())).ok).toBe(true);

      expect(view.state.selection.main.head, 'caret jumped into the inserted section').toBe(originalEnd);
    }
  });
});

// =============================================================================================================================
// WR17: the golden request
// =============================================================================================================================

describe('WR17 the golden request', () => {
  // The same file is the Swift side's pin (request-golden.json in the slice4-restores folder): real uppercase UUIDs as `UUID().uuidString`
  // writes them, keys sorted, compact, explicit nulls. The page must accept exactly this text.
  // (Vitest runs from web/, as `pnpm test` does; jsdom gives `import.meta.url` no file scheme, so the path starts at the working directory.)
  const goldenPath = resolve(
    process.cwd(),
    '../docs/architecture/write-queue-plan/phase4b-markdown/slice4-restores/request-golden.json'
  );
  const sortKeys = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(sortKeys);
    if (value !== null && typeof value === 'object') {
      const record = value as Record<string, unknown>;
      return Object.fromEntries(
        Object.keys(record)
          .sort()
          .map((key) => [key, sortKeys(record[key])])
      );
    }
    return value;
  };

  // Break patch (round D): in api-structural-markdown.ts `parseRestoreFields` refuse a null `endLeaderId`.
  // Predicted failure on the new code: `the golden request was refused`.
  it('WR17 the request in request-golden.json is in the canonical form and the page runs it on the document its rows describe', () => {
    const golden = readFileSync(goldenPath, 'utf8').trim();
    const request = JSON.parse(golden);
    expect(JSON.stringify(sortKeys(request)), 'the golden file is not canonical (sorted keys, compact)').toBe(golden);
    expect(request.leaders.every((leader: { id: string }) => UUID_SHAPE.test(leader.id))).toBe(true);
    expect(request.endLeaderId).toBeNull();
    const body = (line: string): string => `Body of ${line.replace(/^#+ /, '')}.`;
    const text = `${request.leaders
      .map((leader: { id: string; line: string }) => `<!-- @sid:${leader.id} -->${leader.line}\n\n${body(leader.line)}`)
      .join('\n\n')}\n`;
    load(text);

    const result = ff().markdownStructuralRestore(golden);

    expect(result.ok, `the golden request was refused: ${JSON.stringify(result)}`).toBe(true);
    const rootAt = text.indexOf(`<!-- @sid:${request.rootId} -->`);
    const nextAt = text.indexOf(`<!-- @sid:${request.leaders[2].id} -->`); // Part 2.1, the leader after Chapter 2
    expect(docText()).toBe(`${text.slice(0, rootAt)}${request.text}\n\n${text.slice(nextAt)}`);
    expect(result.insertedLeaderIds).toEqual([request.rootId]);
  });
});
