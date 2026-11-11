// @vitest-environment jsdom
//
// t-4a8fd8af, Phase 4b, Markdown slice 3, round B: the PAGE half of the editor-first DUPLICATE SECTION in Markdown mode:
// web/codemirror/src/api-structural-markdown-duplicate.ts, `markdownStructuralDuplicate` (the click), and the undo / redo / redo-carry
// of a 'duplicate' entry in api-structural-markdown.ts (`markdownStructuralSwap`, `buildSwappedState`, `composedRedo`).
//
// These tests drive the REAL page, like structural-markdown.test.ts and structural-markdown-reorder.test.ts: they import the real main.ts
// (the real extension set, the real update listeners, the real window.FinalFinal) into jsdom. Cmd-Z / Cmd-Shift-Z are real KeyboardEvents;
// Swift's side of the bridge is played by the helpers below (setUndoDescriptor, receiveUndoOutcome).
//
// Every test names its break patch: a file under docs/architecture/write-queue-plan/phase4b-markdown/slice3-duplicate/break-patches/
// (web-<TEST ID>.patch, 1-5 changed lines in the new code) that disables exactly the behaviour the test claims, and the failure message the
// test then shows. A test labelled CONTROL passes with and without a deliberate break; it pins a behaviour that nothing else watches.

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { redoDepth, undoDepth } from '@codemirror/commands';
import { Transaction } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MarkdownLeader } from '../api-structural-markdown';
import type { MarkdownDuplicateResult } from '../api-structural-markdown-duplicate';
import { resetSetAsideRedo, setAsideRedoOf } from '../redo-branch';
import { getRegistry, getUndoDescriptor } from '../undo-coordinator';

type FF = {
  setContent: (md: string, options?: unknown) => void;
  setUndoDescriptor: (d: { undoTopOpId?: string; redoTopOpId?: string }) => void;
  receiveUndoOutcome: (opId: string, outcome: string) => void;
  receiveRedoOutcome: (opId: string, outcome: string) => void;
  resetForProjectSwitch: () => void;
  clearStructuralUndoRegistry: () => void;
  markdownStructuralDuplicate: (request: string | object) => MarkdownDuplicateResult;
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
      /** The literal id written into the marker (a copy's leader carries the id Swift minted for it); `sid(id)` when absent. */
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
 * derived from the tag so the tests stay readable. A tag that already is a UUID (a copy's id, `cid(n)`) is its own id. */
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

/** Ids of the hex alphabet, the way Swift's `UUID().uuidString` is: the id the copy's `n`-th leader gets. */
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

/** The blocks of a copy: every leader gets the next id of `newIds` (as its row id and as the literal marker id), the first heading
 * " copy" at the end of its title. A section break gets no suffix. */
function copyOf(blocks: Block[], newIds: string[]): Block[] {
  let k = 0;
  return blocks.map((b) => {
    if (b.kind === 'text') return b;
    const id = newIds[k];
    const first = k === 0;
    k++;
    if (b.kind === 'break') return { ...b, id, anchorId: id };
    return { ...b, id, anchorId: id, title: first ? `${b.title} copy` : b.title };
  });
}

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

/** The ids of the leaders of the subtree of `rootId`: the root and the leaders up to the first Notes/Bibliography or not-deeper one. */
function subtreeIds(built: Built, rootId: string): string[] {
  const rootIdx = built.leaders.findIndex((leader) => leader.id === rootId);
  const root = built.leaders[rootIdx];
  const ids = [root.id];
  for (const leader of built.leaders.slice(rootIdx + 1)) {
    if (leader.managed !== undefined || leader.level <= root.level) break;
    ids.push(leader.id);
  }
  return ids;
}

/** The request for duplicating the leader the blocks call `rootTag`: the copy of the subtree's k-th leader gets `cid(firstNew + k)`. stopLine and endLeaderId are
 * derived the way the database rule derives them. */
function requestFor(built: Built, rootTag: string, firstNew = 1, opId = OP): Record<string, unknown> {
  const rootId = uid(rootTag);
  const rootIdx = built.blocks.findIndex((b) => b.kind !== 'text' && b.id === rootTag);
  const root = built.blocks[rootIdx];
  const rootLevel = root.kind === 'leader' ? root.level : 1;
  let stopLine: string | null = null;
  for (const b of built.blocks.slice(rootIdx + 1)) {
    if (b.kind === 'leader' && b.managed) {
      stopLine = `${'#'.repeat(b.level)} ${b.title}`;
      break;
    }
    if (b.kind === 'text' && b.managedRow) {
      stopLine = b.text.split('\n')[0].trim();
      break;
    }
  }
  const endLeader = built.leaders.find(
    (leader, i) => i > built.leaders.findIndex((l) => l.id === rootId) && leader.level <= rootLevel
  );
  return {
    kind: 'duplicate',
    opId,
    rootId,
    leaders: built.leaders,
    stopLine,
    endLeaderId: endLeader ? endLeader.id : null,
    copyIds: subtreeIds(built, rootId).map((source, k) => ({ source, new: cid(firstNew + k) })),
  };
}

/** The click, then what Swift does once the entry is recorded: push the descriptor. */
function click(built: Built, rootId: string, firstNew = 1, opId = OP): MarkdownDuplicateResult {
  const result = ff().markdownStructuralDuplicate(JSON.stringify(requestFor(built, rootId, firstNew, opId)));
  if (result.ok) ff().setUndoDescriptor({ undoTopOpId: opId });
  return result;
}

// --- Cmd-Z / Cmd-Shift-Z through the real listeners, Swift's side played ---

type FFUndo = FF;
const ffu = (): FFUndo => (window as any).FinalFinal as FFUndo;

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

/** One structural Cmd-Z: the press (must be routed structural), Swift's swap of the entry, Swift's reply. */
function structuralUndo(opId = OP): void {
  const before = undoRequested().mock.calls.length;
  press('undo');
  expect(undoRequested().mock.calls.length, 'the Cmd-Z was not routed structural').toBe(before + 1);
  const result = ff().markdownStructuralSwap(opId, 'undo');
  expect(result.ok, `the undo swap failed: ${JSON.stringify(result)}`).toBe(true);
  ff().setUndoDescriptor({ redoTopOpId: opId });
  ffu().receiveUndoOutcome(opId, 'performed');
}

/** One structural Cmd-Shift-Z. */
function structuralRedo(opId = OP): void {
  const before = redoRequested().mock.calls.length;
  press('redo');
  expect(redoRequested().mock.calls.length, 'the Cmd-Shift-Z was not routed structural').toBe(before + 1);
  const result = ff().markdownStructuralSwap(opId, 'redo');
  expect(result.ok, `the redo swap failed: ${JSON.stringify(result)}`).toBe(true);
  ff().setUndoDescriptor({ undoTopOpId: opId });
  ffu().receiveRedoOutcome(opId, 'performed');
}

/** The lines that are chapter headings (the section anchor in front of the `#` included). */
const headingLines = (text: string): string[] => text.split('\n').filter((line) => line.includes('# Chapter'));

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
// WD1 .. WD4: the copy itself
// =============================================================================================================================

describe('WD1 the copy follows the section, and every copied leader line carries the id Swift minted for it', () => {
  // Break patch (web-WD1a.patch): in `planDuplicate` keep the leader line as it stands (`${line.text}` instead of the new marker plus `rest`).
  // Predicted failure: `marker ORIG != NEW` (the copy's heading still carries the original's marker, and has no " copy").
  it('WD1a a chapter: the copy is right after it, the root line is `<!-- @sid:NEW --># Chapter 2 copy`, the original is untouched', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);

    const result = click(start, 'a2');

    expect(result.ok, `duplicate refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), 'marker ORIG != NEW').toContain(`\n<!-- @sid:${cid(1)} --># Chapter 2 copy\n`);
    expect(docText()).toBe(build([...ch(1), ...ch(2), ...copyOf(ch(2), [cid(1)]), ...ch(3)]).text);
    // The original's own heading line is exactly what it was (marker included).
    expect(docText()).toContain(`<!-- @sid:${sid('a2')} --># Chapter 2\n`);
    expect(gluedHeadings(docText())).toEqual([]);
  });

  // Break patch (web-WD1b.patch): in `planDuplicate` rewrite only the ROOT line (`k === 0 ? the new marker plus rest : line.text`).
  // Predicted failure: `3.2 marker != NEW` (the sub-sections of the copy carry the originals' markers).
  it('WD1b a chapter with two sub-sections and an image line: every copied leader line gets its own marker, only the root gets " copy"', () => {
    const chapter = [
      ...ch(3),
      ...sub('b1', 'Part 3.1'),
      { kind: 'text', text: '![A figure](figure.png)' } as Block,
      ...sub('b2', 'Part 3.2'),
    ];
    const start = build([...ch(1), ...chapter, ...ch(4)]);
    load(start.text);

    const result = click(start, 'a3');

    expect(result.ok, `duplicate refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), '3.1 marker != NEW').toContain(`\n<!-- @sid:${cid(2)} -->## Part 3.1\n`);
    expect(docText(), '3.2 marker != NEW').toContain(`\n<!-- @sid:${cid(3)} -->## Part 3.2\n`);
    expect(docText(), 'root marker != NEW').toContain(`\n<!-- @sid:${cid(1)} --># Chapter 3 copy\n`);
    expect(docText()).toBe(build([...ch(1), ...chapter, ...copyOf(chapter, [cid(1), cid(2), cid(3)]), ...ch(4)]).text);
    expect(result.insertedLeaders?.map((leader) => leader.id)).toEqual([cid(1), cid(2), cid(3)]);
  });

  // Break patch (web-WD1c.patch): in `planDuplicate` end the section at a leader whose level is LESS than the root's
  // (`leaders[j].level < root.level`) instead of "not deeper", so the earlier copy (a sibling) is swallowed into the range.
  // Predicted failure: `first duplicate refused` (the range of the first duplicate swallows the chapter after it: copyIds count=1 range=2).
  it('WD1c two Duplicates of the same section in a row: the page order is the section, the second copy, the first copy', () => {
    const first = build([...ch(1), ...ch(2), ...ch(3)]);
    load(first.text);
    expect(click(first, 'a2', 1).ok, 'first duplicate refused').toBe(true);
    // Swift sends the leaders as the rows hold them once the first job has applied: the first copy's heading is among them.
    const second = build([...ch(1), ...ch(2), ...copyOf(ch(2), [cid(1)]), ...ch(3)]);
    expect(docText(), 'PREMISE: the page already reads as the rows').toBe(second.text);

    const result = click(second, 'a2', 2);

    expect(result.ok, `second duplicate refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText()).toBe(
      build([...ch(1), ...ch(2), ...copyOf(ch(2), [cid(2)]), ...copyOf(ch(2), [cid(1)]), ...ch(3)]).text
    );
  });

  // Break patch (web-WD1d.patch): in `planDuplicate` write the SOURCE id into the marker (`copyIds[k].source`) instead of the new one.
  // Predicted failure: `the copy of the copy kept the copy's marker` (the new copy's heading carries the marker of the copy it was made from).
  it('WD1d the Duplicate of a copy: its markers differ from the copy it was made from and the original, and the title says "copy copy"', () => {
    const first = build([...ch(1), ...ch(2), ...ch(3)]);
    load(first.text);
    expect(click(first, 'a2', 1).ok).toBe(true);
    const second = build([...ch(1), ...ch(2), ...copyOf(ch(2), [cid(1)]), ...ch(3)]);

    const result = click(second, cid(1), 2);

    expect(result.ok, `duplicate of the copy refused: ${JSON.stringify(result)}`).toBe(true);
    const text = docText();
    expect(text.split(`<!-- @sid:${cid(1)} -->`).length - 1, 'the copy of the copy kept the copy’s marker').toBe(1);
    expect(text).toContain(`\n<!-- @sid:${cid(2)} --># Chapter 2 copy copy\n`);
    expect(text).toBe(
      build([...ch(1), ...ch(2), ...copyOf(ch(2), [cid(1)]), ...copyOf(copyOf(ch(2), [cid(1)]), [cid(2)]), ...ch(3)])
        .text
    );
  });
});

describe('WD2 a section break as the root', () => {
  // Break patch (web-WD2.patch): in `planDuplicate` add " copy" to the root line whatever it is (drop `&& isHeading`).
  // Predicted failure: `break line got ' copy'`.
  it('the copy of a section break is a section break with its own marker and no " copy"', () => {
    const middle: Block[] = [
      { kind: 'break', id: 'a9' },
      { kind: 'text', text: 'After the break.' },
      ...sub('b1', 'Part under the break'),
    ];
    const start = build([...ch(1), ...middle, ...ch(3)]);
    load(start.text);

    const result = click(start, 'a9');

    expect(result.ok, `duplicate refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), "break line got ' copy'").not.toContain('::break:: --> copy');
    expect(docText()).toBe(build([...ch(1), ...middle, ...copyOf(middle, [cid(1), cid(2)]), ...ch(3)]).text);
    expect(result.insertedLeaders).toEqual([
      { id: cid(1), kind: 'section_break', level: 1, title: '' },
      { id: cid(2), kind: 'heading', level: 2, title: 'Part under the break' },
    ]);
  });
});

describe('WD3 the section ends where Notes and Bibliography begin', () => {
  // Break patch (web-WD3a.patch): in `planDuplicate` leave a Notes/Bibliography leader out of the stop rule (drop `leaders[j].managed !== undefined ||`).
  // Predicted failure: `duplicate refused ... "badRequest" ... copyIds count=1 range=2` (the range swallows the Notes heading, a deeper level).
  it('WD3a the last chapter before Notes and Bibliography: the copy goes in at the Notes heading, the Notes and Bibliography text is byte for byte the same', () => {
    const body = 'Text of chapter 2.[^1]';
    const start = build([...ch(1), ...ch(2, body), ...region()]);
    load(start.text);
    const notesFrom = (text: string): string => text.slice(text.indexOf(`<!-- @sid:${sid('hn')} -->`));
    const notesBefore = notesFrom(docText());

    const result = click(start, 'a2');

    expect(result.ok, `duplicate refused: ${JSON.stringify(result)}`).toBe(true);
    expect(notesFrom(docText()), 'Notes region changed').toBe(notesBefore);
    expect(docText()).toBe(build([...ch(1), ...ch(2, body), ...copyOf(ch(2, body), [cid(1)]), ...region()]).text);
  });

  // Break patch (web-WD3b.patch): in `planDuplicate` ignore the stopLine hit (replace `end = Math.min(end, hit);` by `void hit;`).
  // Predicted failure: `Notes region changed` (the copy took the standalone bibliography marker line along).
  it('WD3b the first Notes/Bibliography row is a standalone marker line in front of the Bibliography heading: the copy stops in front of it', () => {
    const tail: Block[] = [
      { kind: 'text', text: '<!-- ::auto-bibliography:: -->', managedRow: true },
      { kind: 'leader', id: 'hb', level: 2, title: 'Bibliography', managed: 'bibliography' },
      { kind: 'text', text: 'Smith, J. (2020). A book.' },
      { kind: 'text', text: '<!-- ::auto-bibliography-end:: -->' },
    ];
    const start = build([...ch(1), ...ch(2), ...tail]);
    load(start.text);
    const markerFrom = (text: string): string => text.slice(text.indexOf('<!-- ::auto-bibliography:: -->'));
    const regionBefore = markerFrom(docText());

    const result = click(start, 'a2');

    expect(result.ok, `duplicate refused: ${JSON.stringify(result)}`).toBe(true);
    expect(
      docText().split('<!-- ::auto-bibliography:: -->').length - 1,
      'Notes region changed (marker line copied)'
    ).toBe(1);
    expect(markerFrom(docText()), 'Notes region changed').toBe(regionBefore);
    expect(docText()).toBe(build([...ch(1), ...ch(2), ...copyOf(ch(2), [cid(1)]), ...tail]).text);
  });
});

describe('WD4 the end of the document', () => {
  // Break patch (web-WD4a.patch): in `planDuplicate` use an empty separator for a range that ends the document (`insert = copyText...` with `'\n\n'` -> `''`).
  // Predicted failure: `page != rows assembly` (the copy's marker is glued to the last line of the original).
  it('WD4a the section ends the document and the document has no trailing newline: a blank line is added, the text equals the rows assembled', () => {
    const start = build([...ch(1), ...ch(2)], '');
    load(start.text);

    const result = click(start, 'a2');

    expect(result.ok, `duplicate refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), 'page != rows assembly').toBe(build([...ch(1), ...ch(2), ...copyOf(ch(2), [cid(1)])], '').text);
    expect(gluedHeadings(docText())).toEqual([]);
  });

  // Break patch (web-WD4b.patch): in `planDuplicate` skip the end-of-document branch (`if (end === doc.length && at < 0)`), so the copy goes in at the end as it stands.
  // Predicted failure: `heading glued to the line before it`.
  it('WD4b the section ends the document and the document ends with a newline: the copy goes in before it, one blank line apart, and the ending is kept', () => {
    const start = build([...ch(1), ...ch(2)], '\n');
    load(start.text);

    const result = click(start, 'a2');

    expect(result.ok, `duplicate refused: ${JSON.stringify(result)}`).toBe(true);
    expect(gluedHeadings(docText()), 'heading glued to the line before it').toEqual([]);
    expect(docText()).toBe(build([...ch(1), ...ch(2), ...copyOf(ch(2), [cid(1)])], '\n').text);
  });
});

// =============================================================================================================================
// WD5, WD6: refusals change nothing
// =============================================================================================================================

describe('WD5 leaders that do not match the text change nothing', () => {
  const expectNothingHappened = (typedText: string): void => {
    expect(docText()).toBe(typedText);
    expect(undoDepth(view.state)).toBe(1); // only the typing
    expect(getRegistry().size, 'a refused duplicate left an entry').toBe(0);
    expect(getUndoDescriptor().undoTopOpId).toBeUndefined();
  };

  // Break patch (web-WD5.patch, shared by WD5a and WD5b): in `planDuplicate` do not refuse on a leader mismatch (`if (false && mismatchDetail !== null)`).
  // Predicted failure: `expected leadersMismatch` (the duplicate goes ahead on a text the rows do not describe).
  it('WD5a a heading typed since the rows were read: leadersMismatch (count), nothing dispatched, no entry', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    typeAfter('Text of chapter 2.', '\n\n## Typed heading');
    const typedText = docText();

    const result = ff().markdownStructuralDuplicate(JSON.stringify(requestFor(start, 'a2')));

    expect(result.reason, 'expected leadersMismatch').toBe('leadersMismatch');
    expect(result.ok).toBe(false);
    expect(result.detail).toMatch(/^leaderCount editor=4 database=3$/);
    expectNothingHappened(typedText);
  });

  // Break patch: web-WD5.patch (shared).  Predicted failure: `expected leadersMismatch`.
  it('WD5b a heading retitled since the rows were read: leadersMismatch (line), nothing dispatched, no entry', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    typeAfter('# Chapter 2', ' (retitled)');
    const typedText = docText();

    const result = ff().markdownStructuralDuplicate(JSON.stringify(requestFor(start, 'a2')));

    expect(result.reason, 'expected leadersMismatch').toBe('leadersMismatch');
    expect(result.detail).toBe('leaderLine index=1');
    expectNothingHappened(typedText);
  });
});

describe('WD6 copyIds that do not describe the range are a bad request', () => {
  const chapter = (): Block[] => [...ch(3), ...sub('b1', 'Part 3.1'), ...sub('b2', 'Part 3.2')];
  /** Sends the request with `mutate` applied; `untouched()` then checks that nothing changed, was recorded or dispatched. */
  const refuse = (mutate: (request: Record<string, any>) => void) => {
    const start = build([...ch(1), ...chapter(), ...ch(4)]);
    load(start.text);
    const request = requestFor(start, 'a3');
    mutate(request);
    const result = ff().markdownStructuralDuplicate(JSON.stringify(request));
    const untouched = (): void => {
      expect(docText(), 'a refused duplicate changed the document').toBe(start.text);
      expect(getRegistry().size, 'a refused duplicate left an entry').toBe(0);
      expect(undoDepth(view.state)).toBe(0);
    };
    return { result, untouched };
  };

  // Break patch (web-WD6a.patch): in `planDuplicate` skip the two `copyIds` checks (count and source).
  // Predicted failure: `expected badRequest/copyIds` (or, for a missing pair, the detail `planThrew`).
  it('WD6a one pair too few, or one too many: badRequest, nothing changed', () => {
    const fewer = refuse((request) => request.copyIds.pop());
    expect(fewer.result.reason, 'expected badRequest/copyIds').toBe('badRequest');
    expect(fewer.result.detail, 'expected badRequest/copyIds').toBe('copyIds count=2 range=3');
    fewer.untouched();
    const more = refuse((request) => request.copyIds.push({ source: uid('a4'), new: cid(9) }));
    expect(more.result.reason, 'expected badRequest/copyIds').toBe('badRequest');
    expect(more.result.detail, 'expected badRequest/copyIds').toBe('copyIds count=4 range=3');
    more.untouched();
  });

  // Break patch: web-WD6a.patch (shared by WD6a and WD6b).  Predicted failure: `expected badRequest/copyIds`.
  it('WD6b a pair whose source is not the k-th leader of the section: badRequest, nothing changed', () => {
    const swapped = refuse((request) => request.copyIds.reverse());
    expect(swapped.result.reason, 'expected badRequest/copyIds').toBe('badRequest');
    expect(swapped.result.detail, 'expected badRequest/copyIds').toBe('copyIds source 0');
    swapped.untouched();
  });

  // Break patch (web-WD6c.patch): in api-structural-markdown.ts `COPY_ID` accept any text (`/^[^]*$/`).
  // Predicted failure: `expected badRequest for a copy id that would end the comment` (the id is written into the text).
  it('WD6c a copy id outside hex digits and dashes (it goes into a comment in the text), or no copyIds at all: badRequest, nothing changed', () => {
    for (const bad of ['zz-not-hex', 'ab --> <b>', '', 'ab\ncd']) {
      const refused = refuse((request) => {
        request.copyIds[1].new = bad;
      });
      expect(refused.result.reason, 'expected badRequest for a copy id that would end the comment').toBe('badRequest');
      expect(refused.result.detail).toBe('copyIds 1');
      refused.untouched();
    }
    const missing = refuse((request) => {
      request.copyIds = undefined;
    });
    expect(missing.result.reason).toBe('badRequest');
    expect(missing.result.detail).toBe('copyIds');
    missing.untouched();
  });
});

// =============================================================================================================================
// WD7: the caret
// =============================================================================================================================

describe('WD7 the caret stays with the text it was in', () => {
  // Break patch (web-WD7a.patch): in `mapSelection` map a caret with assoc -1 for every range (`place(range.head, -1)`).
  // Predicted failure: `caret moved into copy heading` (it stays at the insertion point, which is now the start of the copy's heading line).
  it('WD7a a caret at the start of the next chapter’s heading stays at that heading', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    const nextHeading = `<!-- @sid:${sid('a3')} -->`;
    caretAt(docText().indexOf(nextHeading));

    expect(click(start, 'a2').ok).toBe(true);

    const head = view.state.selection.main.head;
    expect(head, 'caret moved into copy heading').toBe(docText().indexOf(nextHeading));
    expect(view.state.selection.main.empty).toBe(true);
  });

  // Break patch (web-WD7b.patch): in `runDuplicate` put the caret at the start of the copy (`const selection = EditorSelection.cursor(plan.inserted.from)`).
  // Predicted failure: `caret left the original`.
  it('WD7b a caret inside the section stays where it was, in the original', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    const at = start.text.indexOf('Text of chapter 2.') + 5;
    caretAt(at);

    expect(click(start, 'a2').ok).toBe(true);

    expect(view.state.selection.main.head, 'caret left the original').toBe(at);
  });

  // Break patch (web-WD7c.patch): in `planDuplicate` clamp only a caret BEYOND the end of the original (`pos > at`) and map a caret with assoc 1.
  // Predicted failure: `caret jumped into the copy` (it ends up behind the copy).
  it('WD7c a caret at the very end of the document, where the original ends, stays in the original', () => {
    const start = build([...ch(1), ...ch(2)], '');
    load(start.text);
    caretAt(docText().length);

    expect(click(start, 'a2').ok).toBe(true);

    const originalEnd = start.text.length;
    expect(view.state.selection.main.head, 'caret jumped into the copy').toBe(originalEnd);
  });
});

// =============================================================================================================================
// WD8 .. WD10: undo, redo and the redo carry
// =============================================================================================================================

describe('WD8 typing done inside the copy comes back through the redo', () => {
  const threeChapters = (): Built => build([...ch(1), ...ch(2), ...ch(3)]);

  // Break patch (web-WD8a.patch): in `buildSwappedState` pass `moved` for a reorder only (`entry.markdown?.kind === 'reorder'`).
  // Predicted failure: `typing inside the copy was carried across the undo (it must be set aside)` (the carried list holds the event).
  it('WD8a Duplicate, type in the copy, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z: the typing is back inside the copy, no heading line changes', () => {
    const start = threeChapters();
    load(start.text);
    expect(click(start, 'a2').ok).toBe(true);
    const post = docText();
    typeAfterNth('Text of chapter 2.', 1, ' And after.'); // inside the copy
    const typed = docText();

    press('undo'); // the typing (a text undo)
    expect(docText()).toBe(post);
    expect(undoRequested()).not.toHaveBeenCalled();
    structuralUndo(); // the duplicate
    expect(docText()).toBe(start.text);
    expect(redoDepth(view.state), 'typing inside the copy was carried across the undo (it must be set aside)').toBe(0);
    structuralRedo(); // the duplicate again
    expect(docText()).toBe(post);
    press('redo'); // the typing: set aside by the undo, put back by the redo

    expect(headingLines(docText()), 'heading line changed by a redo').toEqual(headingLines(post));
    expect(docText(), 'typing not inside the copy').toBe(typed);
    expect(docText().indexOf(' And after.'), 'typing not inside the copy').toBeGreaterThan(
      post.indexOf('Chapter 2 copy')
    );
  });

  // The fall-back: when the put-back is refused (here: the record is broken after the undo) the carried list is what the redo finds, and
  // it must not hold the typing inside the copy: nothing is written into a heading line, the typing is simply not redone.
  // Break patch: web-WD8a.patch (shared by WD8a and WD8b).  Predicted failure: `heading line changed by a redo`.
  it('WD8b the put-back is refused (record broken): the typing inside the copy is not redone and no heading line changes', () => {
    const start = threeChapters();
    load(start.text);
    expect(click(start, 'a2').ok).toBe(true);
    const post = docText();
    typeAfterNth('Text of chapter 2.', 1, ' And after.');

    press('undo');
    expect(docText()).toBe(post);
    structuralUndo();
    expect(docText()).toBe(start.text);
    const record = setAsideRedoOf(OP);
    expect(record, 'PREMISE: the undo set the redo list aside').toBeDefined();
    if (record) record.depthAfterUndo += 1; // the put-back must now refuse
    structuralRedo();
    expect(docText()).toBe(post);
    press('redo'); // the typing: it lay inside the copy and was dropped by the carry

    expect(
      errorHandlerMessages.some((m) => m.includes('redo put-back skipped')),
      'PREMISE: the put-back was refused'
    ).toBe(true);
    expect(headingLines(docText()), 'heading line changed by a redo').toEqual(headingLines(post));
    expect(docText(), 'after the fall-back the document must be the post-op copy without the typing').toBe(post);
  });
});

describe('WD9 which redo events the undo carries: the heading-line-safe drop rule for the copy', () => {
  // Break patch (web-WD9a.patch): in `planDuplicate` start `moved` one character late (`from: (endsDocument ? at + 2 : at) + 1`).
  // Predicted failure: `event at copy start kept` (the carried list holds the event typed at the start of the copy's heading line).
  it('WD9a an event waiting at the start of the copy’s heading line is dropped from the carried list, and comes back with the put-back', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    const result = click(start, 'a2');
    expect(result.ok).toBe(true);
    const post = docText();
    typeAt(result.inserted?.from ?? -1, 'X'); // at the very start of the copy's heading line
    const typed = docText();
    expect(
      typed.indexOf(`X<!-- @sid:${cid(1)} -->`),
      'PREMISE: X is at the start of the copy heading line'
    ).toBeGreaterThan(0);

    press('undo');
    expect(docText()).toBe(post);
    structuralUndo();
    expect(docText()).toBe(start.text);
    expect(redoDepth(view.state), 'event at copy start kept').toBe(0);
    structuralRedo();
    expect(docText()).toBe(post);
    press('redo');

    expect(docText(), 'typing at the start of the copy not back').toBe(typed);
  });

  // Break patch (web-WD9b.patch): in `planDuplicate` end `moved` one character late (`to: at + insert.length + 1`).
  // Predicted failure: `event at the next heading start dropped`.
  it('WD9b an event waiting at the start of the NEXT chapter’s heading line is kept, and comes back at that same heading start', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    const result = click(start, 'a2');
    expect(result.ok).toBe(true);
    const post = docText();
    typeAt(result.inserted?.to ?? -1, 'Y'); // at the start of the line of Chapter 3's heading
    const typed = docText();
    expect(
      typed.indexOf(`Y<!-- @sid:${sid('a3')} -->`),
      'PREMISE: Y is at the start of the next heading line'
    ).toBeGreaterThan(0);

    press('undo');
    expect(docText()).toBe(post);
    structuralUndo();
    expect(docText()).toBe(start.text);
    expect(redoDepth(view.state), 'event at the next heading start dropped').toBe(1);
    structuralRedo();
    expect(docText()).toBe(post);
    press('redo');

    expect(docText()).toBe(typed);
    expect(headingLines(docText()).filter((line) => line.startsWith('Y'))).toEqual([
      `Y<!-- @sid:${sid('a3')} --># Chapter 3`,
    ]);
  });
});

describe('WD10 the redo is the composed redo: it puts the document and the caret back exactly', () => {
  // Break patch (web-WD10a.patch): in `composedRedo` refuse the 'duplicate' kind (`if (extras?.kind !== 'reorder') return null;`), so the redo takes the saved-copy swap.
  // Predicted failure: `caret did not go back with its text` (the saved-copy swap leaves the caret at the insertion point, in front of the copy).
  it('WD10a a caret at the start of the next chapter’s heading: after Cmd-Z and Cmd-Shift-Z it is at that heading again, not at the copy’s', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    const nextHeading = `<!-- @sid:${sid('a3')} -->`;
    caretAt(docText().indexOf(nextHeading));
    expect(click(start, 'a2').ok).toBe(true);
    const post = docText();

    structuralUndo();
    expect(docText()).toBe(start.text);
    expect(view.state.selection.main.head, 'PREMISE: the undo put the caret back').toBe(
      start.text.indexOf(nextHeading)
    );
    structuralRedo();

    expect(docText()).toBe(post);
    expect(view.state.selection.main.head, 'caret did not go back with its text').toBe(post.indexOf(nextHeading));
  });

  // The copy repeats the original's lines, so a line diff between the two documents (the saved-copy swap) could place the insertion at the
  // wrong one of two identical texts. This is the scenario that argued for the composed redo: typing done in the original before the
  // Duplicate, then undo and redo of the Duplicate, then typing next to it. Measured: the history is the same on both routes (the undo
  // swaps in the checkpoint, which carries its own history), so this is a CONTROL: it passes with and without the break of WD10a.
  it('WD10b (CONTROL) typing in the original before the Duplicate: undo, redo, type, then Cmd-Z x2 and Cmd-Z undo the typing, the Duplicate, then the earlier typing there', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    typeAfter('Text of chapter 2.', ' abc'); // in the original, before the Duplicate
    const typedFirst = docText();
    expect(click(build([...ch(1), ...ch(2, 'Text of chapter 2. abc'), ...ch(3)]), 'a2').ok).toBe(true);
    const post = docText();

    structuralUndo();
    expect(docText()).toBe(typedFirst);
    structuralRedo();
    expect(docText()).toBe(post);
    typeAfter('Text of chapter 2. abc', ' def'); // in the original, after the redo
    press('undo'); // ' def'
    expect(docText()).toBe(post);
    structuralUndo(); // the Duplicate
    expect(docText()).toBe(typedFirst);
    press('undo'); // ' abc', in the only text there is
    expect(docText()).toBe(start.text);
  });
});

// =============================================================================================================================
// WD11 .. WD14: the descriptor, the reply, the entry, the history
// =============================================================================================================================

describe('WD11 the undo-top descriptor is set by a successful click and by nothing else', () => {
  // Break patch (web-WD11.patch): in `markdownStructuralDuplicate` set the descriptor whatever the result (drop `if (result.ok)`).
  // Predicted failure: `descriptor on failure`.
  it('a refused click leaves the descriptor alone, an accepted one sets undoTopOpId before Swift pushes anything', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    typeAfter('Text of chapter 2.', '\n\n## Typed heading');
    const before = { ...getUndoDescriptor() };

    const refused = ff().markdownStructuralDuplicate(JSON.stringify(requestFor(start, 'a2')));
    expect(refused.ok).toBe(false);
    expect({ ...getUndoDescriptor() }, 'descriptor on failure').toEqual(before);

    const fresh = build([...ch(1), ...ch(2), ...ch(3)]);
    load(fresh.text);
    const accepted = ff().markdownStructuralDuplicate(JSON.stringify(requestFor(fresh, 'a2')));
    expect(accepted.ok, JSON.stringify(accepted)).toBe(true);
    expect(getUndoDescriptor().undoTopOpId, 'descriptor not set by an accepted click').toBe(OP);
  });
});

describe('WD12 the reply and the registry entry', () => {
  // Break patch (web-WD12a.patch): in `planDuplicate` leave " copy" out of the reported title of the root (`title` instead of `${title} copy`).
  // Predicted failure: `insertedLeaders title`.
  it('WD12a the reply names the inserted text and the copy’s leaders as the rows will hold them', () => {
    const chapter = [...ch(3), ...sub('b1', 'Part 3.1')];
    const start = build([...ch(1), ...chapter, ...ch(4)]);
    load(start.text);

    const result = click(start, 'a3');

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(result.preRaw).toBe(start.text);
    expect(result.postRaw).toBe(docText());
    const inserted = result.inserted;
    expect(inserted).toBeDefined();
    // The inserted range is exactly the inserted text: taking it out gives the pre-op document back.
    expect((result.postRaw ?? '').slice(0, inserted?.from) + (result.postRaw ?? '').slice(inserted?.to)).toBe(
      start.text
    );
    expect(
      (result.postRaw ?? '').slice(inserted?.from, inserted?.to).startsWith(`<!-- @sid:${cid(1)} --># Chapter 3 copy\n`)
    ).toBe(true);
    expect(result.insertedLeaders, 'insertedLeaders title').toEqual([
      { id: cid(1), kind: 'heading', level: 1, title: 'Chapter 3 copy' },
      { id: cid(2), kind: 'heading', level: 2, title: 'Part 3.1' },
    ]);
  });

  // Break patch (web-WD12b.patch): in `runDuplicate` record the entry's postOpDoc as the placeholder (`postOpDoc: dispatched ? doc : entry.postOpDoc`).
  // Predicted failure: `postOpDoc is not the document on the screen`.
  it('WD12b the entry is recorded for the undo: the checkpoint is the pre-op state, postOpDoc the document on the screen, mid-op cleared', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    typeAfter('Text of chapter 1.', ' typed'); // one text-history step before the click
    const typedStart = docText();
    const depth = undoDepth(view.state);

    const result = click(build([...ch(1, 'Text of chapter 1. typed'), ...ch(2), ...ch(3)]), 'a2');

    expect(result.ok, JSON.stringify(result)).toBe(true);
    const entry = getRegistry().get(OP);
    expect(entry?.midOp).toBe(false);
    expect(entry?.postOpDoc.eq(view.state.doc), 'postOpDoc is not the document on the screen').toBe(true);
    expect(entry?.preOpDoc.toString()).toBe(typedStart);
    expect(entry?.checkpoint.doc.toString()).toBe(typedStart);
    expect(entry?.markdown?.kind).toBe('duplicate');
    expect(entry?.markdown?.opChanges.apply(entry.checkpoint.doc).toString()).toBe(docText());
    expect(undoDepth(view.state), 'the duplicate is a text-history step').toBe(depth);
  });
});

describe('WD13 the click is outside the text history and closes the typing group on both sides', () => {
  // Break patch (web-WD13.patch): in `runDuplicate` drop `isolateHistory.of('full')` from the dispatch's annotations.
  // Predicted failure: `typing before and after the duplicate merged into one undo step`.
  it('typing right before the click and right after it (next to each other) are two undo steps', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    // Two typing steps next to each other 100 ms apart: inside the history's 500 ms group delay, so only the click between them keeps
    // them apart. The time is given to the transactions, so the result does not depend on how fast the machine runs this test.
    const firstAt = start.text.indexOf('Text of chapter 2.') + 'Text of chapter 2.'.length;
    typeAtTime(firstAt, ' abc', 1_000_000);
    const afterFirst = build([...ch(1), ...ch(2, 'Text of chapter 2. abc'), ...ch(3)]);
    expect(undoDepth(view.state)).toBe(1);

    expect(click(afterFirst, 'a2').ok).toBe(true);
    typeAtTime(firstAt + ' abc'.length, ' def', 1_000_100); // next to the earlier typing, 100 ms later

    expect(undoDepth(view.state), 'typing before and after the duplicate merged into one undo step').toBe(2);
  });
});

describe('WD14 one transaction', () => {
  // Break patch (web-WD14.patch): in `runDuplicate` dispatch the selection separately after the change (`view.dispatch({ selection });` added after the main dispatch).
  // Predicted failure: `the click dispatched 2 transactions`.
  it('the click dispatches exactly once: the insertion and the selection are one transaction', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    const dispatch = vi.spyOn(view, 'dispatch');

    const result = click(start, 'a2');

    expect(result.ok).toBe(true);
    expect(dispatch.mock.calls.length, `the click dispatched ${dispatch.mock.calls.length} transactions`).toBe(1);
    dispatch.mockRestore();
  });
});

// =============================================================================================================================
// WD16 .. WD18: the end of the document, and the typing that ends at the insertion point (round B2)
// =============================================================================================================================

describe('WD16 a caret on the trailing newlines of the last chapter stays at the end of the original', () => {
  // The document ends with the usual newline(s). The copy goes in at the end of the original's last LINE, in front of those newlines, so a
  // caret that sat on them (the blank line a writer clicks into below the last paragraph) must not be carried after the copy: the next
  // typing would land in the copy.
  const check = (trailing: string): void => {
    const start = build([...ch(1), ...ch(2)], trailing);
    const at = start.text.length - trailing.length; // the end of the original's last line
    for (let pos = at + 1; pos <= start.text.length; pos++) {
      load(start.text);
      caretAt(pos);

      const result = click(start, 'a2');

      expect(result.ok, `duplicate refused: ${JSON.stringify(result)}`).toBe(true);
      expect(
        view.state.selection.main.head,
        `caret on the trailing line went into the copy (caret was ${pos - at} after the end of the last line)`
      ).toBe(at);
      typeAt(view.state.selection.main.head, 'Z');
      expect(docText(), 'the typing did not land in the original').toBe(
        build([...ch(1), ...ch(2, 'Text of chapter 2.Z'), ...copyOf(ch(2), [cid(1)])], trailing).text
      );
    }
  };

  // Break patch (web-WD16.patch): in `planDuplicate` keep only a caret exactly at the end of the original there (`pos === at` instead of `pos >= at`).
  // Predicted failure: `caret on the trailing line went into the copy`.
  it('WD16a the document ends with one newline', () => check('\n'));

  // Break patch: web-WD16.patch (shared).  Predicted failure: `caret on the trailing line went into the copy`.
  it('WD16b the document ends with a blank line (two newlines): a caret on either of them', () => check('\n\n'));
});

describe('WD17 typing appended to the end of the original stays in the undo carry', () => {
  // The insertion point of a copy at the end of the document is where the original ends, so a redo event that types at the end of the
  // original sits AT the insertion point. It belongs to the original: the carry must keep it (the `moved` span starts behind the `\n\n`
  // in front of the copy), not drop it as if it were inside the copy.
  const check = (trailing: string): void => {
    const start = build([...ch(1), ...ch(2)], trailing);
    load(start.text);
    const result = click(start, 'a2');
    expect(result.ok, `duplicate refused: ${JSON.stringify(result)}`).toBe(true);
    const post = docText();
    typeAt(result.inserted?.from ?? -1, 'Z'); // at the end of the original's last line
    const typed = docText();
    expect(typed, 'PREMISE: Z is in the original').toContain('Text of chapter 2.Z\n');

    press('undo'); // the typing (a text undo)
    expect(docText()).toBe(post);
    structuralUndo(); // the duplicate
    expect(docText()).toBe(start.text);
    expect(redoDepth(view.state), 'typing at the end of the original was dropped from the carry').toBe(1);
    structuralRedo();
    expect(docText()).toBe(post);
    press('redo');
    expect(docText(), 'typing at the end of the original not back').toBe(typed);
  };

  // Break patch (web-WD17.patch): in `planDuplicate` start `moved` at the insertion point also at the end of the document (`from: at`).
  // Predicted failure: `typing at the end of the original was dropped from the carry`.
  it('WD17a the document ends with one newline', () => check('\n'));

  // Break patch: web-WD17.patch (shared).  Predicted failure: `typing at the end of the original was dropped from the carry`.
  it('WD17b the document ends with a blank line (two newlines)', () => check('\n\n'));
});

describe('WD18 typing that ended at the insertion point does not make the app’s rewrite of the copy an undo step', () => {
  // The user types at the end of the last chapter and chooses Duplicate within 2.5 s. The tracked "recent edit" span ends exactly at the
  // insertion point and the insertion would push its end past the copy. The settle's footnote renumber of the copy (a derived push
  // inside the copy) would then overlap the span and become an undo step of its own: the next Cmd-Z undoes it instead of the Duplicate.
  // Break patch (web-WD18.patch): in `runDuplicate` remove the `clearRecentUserEditSpan();` call after the dispatch.
  // Predicted failure: `the app's rewrite of the copy became an undo step`.
  it('type at the end of the section, Duplicate at once, the footnote in the copy is renumbered: Cmd-Z is the structural undo', () => {
    const body = 'Text of chapter 2.[^1]';
    const start = build([...ch(1), ...ch(2, body)], '');
    load(start.text);
    typeAfter(body, ' tail'); // the typing ends at the insertion point
    const typedStart = docText();
    expect(undoDepth(view.state)).toBe(1);

    expect(click(build([...ch(1), ...ch(2, `${body} tail`)], ''), 'a2').ok).toBe(true);
    const post = docText();
    const inCopy = post.lastIndexOf('[^1]');
    ff().setContent(`${post.slice(0, inCopy)}[^2]${post.slice(inCopy + 4)}`, { origin: 'derived' }); // the settle's renumber of the copy

    expect(undoDepth(view.state), 'the app’s rewrite of the copy became an undo step').toBe(1);
    structuralUndo(); // must be routed structural: the rewrite is not a typing step
    expect(docText()).toBe(typedStart);
  });
});

// =============================================================================================================================
// WD19: a book of more than 500 lines with automatic rewrites far from the copy (round B2)
// =============================================================================================================================

describe('WD19 a long book: the app’s own rewrites far from the copy do not disturb undo, redo and the redo carry', () => {
  // Forty chapters of fifteen lines (720 lines), chapter 20 is duplicated. Two automatic rewrites far apart, both outside the
  // copy and more than 650 lines from each other: the anchor of chapter 1 and the footnote label in chapter 40 (each a derived push of its own).
  // `computeMinimalChanges` collapses a difference that spans more than 500 lines into ONE replaced span, which swallows the copy, the
  // caret and every history event between the two rewrites; `computeRefinedChanges` follows the two places.
  const marker = 'Line 7 of chapter 20.';
  const book = (): Built => {
    const chapters: Block[] = [];
    for (let n = 1; n <= 40; n++) {
      const lines = Array.from({ length: 15 }, (_, i) => `Line ${i + 1} of chapter ${n}.`);
      if (n === 40) lines[2] += '[^1]';
      chapters.push(...ch(n, lines.join('\n'), n === 1 ? { anchored: false } : {}));
    }
    return build(chapters);
  };
  const anchorChapterOne = (): void => {
    ff().setContent(docText().replace('# Chapter 1\n', `<!-- @sid:${sid('a1')} --># Chapter 1\n`), {
      origin: 'derived',
    });
  };
  const relabelChapterForty = (): void => {
    ff().setContent(docText().replace('[^1]', '[^2]'), { origin: 'derived' });
  };
  /** The caret after the original's `marker` line, and the Duplicate of chapter 20. */
  const startWithCopy = (): Built => {
    const start = book();
    expect(start.text.split('\n').length, 'PREMISE: the book is longer than 500 lines').toBeGreaterThan(600);
    load(start.text);
    caretAt(docText().indexOf(marker) + marker.length);
    expect(click(start, 'a20').ok).toBe(true);
    return start;
  };
  const caretAfterOriginalMarker = (text: string): number => text.indexOf(marker) + marker.length;

  // Break patch (web-WD19a.patch): in redo-branch.ts `carryRedoBranch` use `computeMinimalChanges` for the churn.
  // Predicted failure: `typing inside the copy was carried across the undo` (the moved span is lost in the one big replaced span).
  it('WD19a typing inside the copy is still left out of the carry after two far-apart rewrites', () => {
    const start = startWithCopy();
    typeAfterNth(marker, 1, ' X'); // inside the copy
    press('undo'); // the typing
    anchorChapterOne();
    relabelChapterForty();

    structuralUndo();

    expect(docText()).toBe(start.text);
    expect(redoDepth(view.state), 'typing inside the copy was carried across the undo').toBe(0);
  });

  // Break patch (web-WD19b.patch): in `composedRedo` use `computeMinimalChanges` for the settle (and import it).
  // Predicted failure: `caret did not go back with its text` (the settle is one span that takes the caret to its start).
  it('WD19b the composed redo lands on the settled document with the caret at the same text, and every earlier typing step is still undone', () => {
    const start = book();
    load(start.text);
    typeAfter('Line 3 of chapter 5.', ' E'); // an earlier typing step, far from the copy
    const typedStart = docText();
    caretAt(docText().indexOf(marker) + marker.length);
    expect(click(start, 'a20').ok).toBe(true);
    anchorChapterOne();
    relabelChapterForty();
    const settled = docText();

    structuralUndo();
    expect(docText()).toBe(typedStart);
    structuralRedo();

    expect(docText()).toBe(settled);
    expect(view.state.selection.main.head, 'caret did not go back with its text').toBe(
      caretAfterOriginalMarker(settled)
    );
    // The earlier typing step is still there to undo: Cmd-Z undoes the Duplicate (structural), the next one the typing.
    structuralUndo();
    expect(docText()).toBe(typedStart);
    press('undo');
    expect(docText(), 'the earlier typing step was lost').toBe(start.text);
  });

  // Break patch (web-WD19c.patch): in `swapRedoFromSavedCopy` use `computeMinimalChanges` (and import it).
  // Predicted failure: `caret did not go back with its text (saved-copy swap)`.
  it('WD19c the saved-copy swap (an automatic rewrite while undone) keeps the caret at the same text', () => {
    startWithCopy();
    relabelChapterForty(); // after the click: the saved post-op copy follows it
    const settled = docText();
    structuralUndo();
    anchorChapterOne(); // while undone: the document is no longer the checkpoint's, so the redo takes the saved-copy swap

    structuralRedo();

    expect(
      errorHandlerMessages.some((m) => m.includes('saved-copy swap')),
      'PREMISE: the saved-copy swap ran'
    ).toBe(true);
    expect(docText()).toBe(settled);
    expect(view.state.selection.main.head, 'caret did not go back with its text (saved-copy swap)').toBe(
      caretAfterOriginalMarker(settled)
    );
  });
});

describe('WD20 a selection is kept, or collapsed, sensibly', () => {
  const threeChapters = (): Built => build([...ch(1), ...ch(2), ...ch(3)]);
  const withCopy = (): string => build([...ch(1), ...ch(2), ...copyOf(ch(2), [cid(1)]), ...ch(3)]).text;

  // Break patch (web-WD20a.patch): in `mapSelection` build a non-empty range forward whatever its direction (`range.anchor <= range.head` -> `true`).
  // Predicted failure: `selection direction changed`.
  it('WD20a a selection inside the original keeps both ends and its direction', () => {
    for (const backward of [false, true]) {
      const start = threeChapters();
      load(start.text);
      const from = start.text.indexOf('Text of chapter 2.') + 3;
      const to = from + 8;
      view.dispatch({ selection: backward ? { anchor: to, head: from } : { anchor: from, head: to } });

      expect(click(start, 'a2').ok).toBe(true);

      const main = view.state.selection.main;
      expect([main.anchor, main.head], 'selection direction changed').toEqual(backward ? [to, from] : [from, to]);
      expect(docText()).toBe(withCopy());
    }
  });

  // Break patch (web-WD20b.patch): in `mapSelection` leave out the collapse of a straddling selection (`if (false && !endsDocument && ...)`).
  // Predicted failure: `the selection swelled to hold the copy`.
  it('WD20b a selection that runs from the original into the next chapter collapses to its head, which stays at its text', () => {
    const start = threeChapters();
    load(start.text);
    const from = start.text.indexOf('Text of chapter 2.') + 5;
    const headInThree = start.text.indexOf('# Chapter 3') + 4;
    view.dispatch({ selection: { anchor: from, head: headInThree } });

    expect(click(start, 'a2').ok).toBe(true);

    const main = view.state.selection.main;
    expect(main.empty, 'the selection swelled to hold the copy').toBe(true);
    expect(main.head).toBe(docText().indexOf('# Chapter 3') + 4);
    expect(docText()).toBe(withCopy());
  });

  // Break patch: web-WD16.patch (shared: `pos === at` instead of `pos >= at`).  Predicted failure: `the selection swelled to hold the copy`.
  it('WD20c at the end of the document a selection from the original to the very end stops at the end of the original', () => {
    const start = build([...ch(1), ...ch(2)], '\n');
    load(start.text);
    const at = start.text.length - 1;
    const from = start.text.indexOf('Text of chapter 2.') + 5;
    view.dispatch({ selection: { anchor: from, head: start.text.length } });

    expect(click(start, 'a2').ok).toBe(true);

    const main = view.state.selection.main;
    expect([main.from, main.to], 'the selection swelled to hold the copy').toEqual([from, at]);
    expect(docText()).toBe(build([...ch(1), ...ch(2), ...copyOf(ch(2), [cid(1)])], '\n').text);
  });
});

describe('WD21 the golden request', () => {
  // The same file is the Swift side's pin (docs/architecture/golden-requests/markdown-duplicate-request-golden.json): real uppercase UUIDs as `UUID().uuidString`
  // writes them, keys sorted, compact. The page must accept exactly this text.
  // (Vitest runs from web/, as `pnpm test` does; jsdom gives `import.meta.url` no file scheme, so the path starts at the working directory.)
  const goldenPath = resolve(
    process.cwd(),
    '../docs/architecture/golden-requests/markdown-duplicate-request-golden.json'
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

  // Break patch (web-WD21.patch): in api-structural-markdown.ts `COPY_ID` accept lower-case hex only (`/^[0-9a-f-]+$/`).
  // Predicted failure: `the golden request was refused`.
  it('the request in request-golden.json is in the canonical form and the page runs it on the document its rows describe', () => {
    const golden = readFileSync(goldenPath, 'utf8').trim();
    const request = JSON.parse(golden);
    expect(JSON.stringify(sortKeys(request)), 'the golden file is not canonical (sorted keys, compact)').toBe(golden);
    expect(request.leaders.every((leader: { id: string }) => UUID_SHAPE.test(leader.id))).toBe(true);
    const body = (line: string): string => `Body of ${line.replace(/^#+ /, '')}.`;
    const text = `${request.leaders
      .map((leader: { id: string; line: string }) => `<!-- @sid:${leader.id} -->${leader.line}\n\n${body(leader.line)}`)
      .join('\n\n')}\n`;
    load(text);

    const result = ff().markdownStructuralDuplicate(golden);

    expect(result.ok, `the golden request was refused: ${JSON.stringify(result)}`).toBe(true);
    const [newRoot, newPart] = request.copyIds.map((pair: { new: string }) => pair.new);
    const insertAt = text.indexOf(`<!-- @sid:${request.endLeaderId} -->`);
    const copy = `<!-- @sid:${newRoot} --># Chapter 2 copy\n\n${body('# Chapter 2')}\n\n<!-- @sid:${newPart} -->## Part 2.1\n\n${body('## Part 2.1')}\n\n`;
    expect(docText()).toBe(text.slice(0, insertAt) + copy + text.slice(insertAt));
    expect(result.insertedLeaders?.map((leader) => leader.id)).toEqual([newRoot, newPart]);
  });
});

describe('WD15 (CONTROL) undo and redo again and again land on the settled document with the same copy ids', () => {
  // A CONTROL: the saved-copy swap lands on the same document, so it passes with and without the break of WD10a. It pins the cycle the
  // real app runs (M4): the markers of the click come back every time, and the settle's rewrite of the document is not lost.
  it('Duplicate, a derived rewrite (anchors injected), then two Cmd-Z / Cmd-Shift-Z cycles: every redo reads as the settled post-op document', () => {
    const start = build([...ch(1, 'Text of chapter 1.', { anchored: false }), ...ch(2), ...ch(3)]);
    load(start.text);
    expect(click(start, 'a2').ok).toBe(true);
    const unsettled = docText();
    const settled = unsettled.replace('# Chapter 1', `<!-- @sid:${sid('a1')} --># Chapter 1`);
    ff().setContent(settled, { origin: 'derived' }); // the rebuild's anchors
    expect(docText()).toBe(settled);
    expect(getRegistry().get(OP)?.postOpDoc.toString(), 'PREMISE: the saved copy followed the rewrite').toBe(settled);

    for (const cycle of [1, 2]) {
      structuralUndo();
      expect(docText(), `cycle ${cycle}: undo`).toBe(start.text);
      structuralRedo();
      expect(docText(), `cycle ${cycle}: redo`).toBe(settled);
      expect(docText().split(`<!-- @sid:${cid(1)} -->`).length - 1).toBe(1);
    }
    expect(getRegistry().get(OP)?.midOp).toBe(false);
    expect(getRegistry().get(OP)?.preOpDoc.toString()).toBe(start.text);
  });
});
