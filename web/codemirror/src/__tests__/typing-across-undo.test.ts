// @vitest-environment jsdom
//
// t-d2061b27, Phase 4c job 2, Markdown, first round: the PURE layer of "a Cmd-Z that waits keeps waiting when the user types, then runs on the
// document as it was when the key was pressed, with the typing put back on top" -- web/codemirror/src/typing-rebase.ts.
//
// Pure level on a REAL CodeMirror state: the registry entries (checkpoint, opChanges, moved) come from the real page (main.ts imported into
// jsdom, like structural-markdown-reorder.test.ts), the typing is real transactions with the userEvent a keystroke has, and the swap is
// `view.setState(entry.checkpoint)` followed by the replay `swapWithReplay` builds. Nothing is wired into undo-coordinator.ts or an api-*.ts
// yet, so these tests play the page's part themselves (record the typing, ask for the document at the press, build Over, swap and replay).
//
// Every placement test FIRST asserts its premise: at least one change was recorded and the one trace line carries steps>=1. Every test names
// its break patch (.claude/superdev/cmdz-waits-through-typing/break-patches/MD-<TestId>.patch, 1-5 lines in typing-rebase.ts) in a comment.
// Expected documents are written by hand from the rule (the builders below), never copied from what the code printed.

import { history, undo, undoDepth } from '@codemirror/commands';
import { EditorState, type Text, Transaction, type TransactionSpec } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { toggleBold } from '../api-formatting';
import type { MarkdownLeader } from '../api-structural-markdown';
import { derivedCorrection } from '../derived-correction';
import { clearRecentUserEditSpan } from '../recent-edit-span';
import { slashCommands } from '../slash-completions';
import { smartQuotesInputHandler } from '../smart-quotes-plugin';
import { insertTableCommand } from '../table-format';
import {
  buildOver,
  buildReplayDryRun,
  docAtPress,
  formatTypingSincePressLine,
  isTypingTransaction,
  type ReplayInput,
  swapWithReplay,
  TypingCollector,
  typingDispatch,
} from '../typing-rebase';
import {
  getInFlightPress,
  getRegistry,
  getTypingCollector,
  LATCH_TIMEOUT_MS,
  type UndoRegistryEntry,
} from '../undo-coordinator';

type FF = {
  setContent: (md: string, options?: unknown) => void;
  resetForProjectSwitch: () => void;
  clearStructuralUndoRegistry: () => void;
  markdownStructuralReorder: (request: string | object) => { ok: boolean; reason?: string; detail?: string };
  markdownStructuralDuplicate: (request: string | object) => { ok: boolean; reason?: string; detail?: string };
  markdownStructuralRestore: (request: string | object) => { ok: boolean; reason?: string; detail?: string };
  markdownStructuralEditorFirst: (request: string | object) => { ok: boolean; reason?: string; detail?: string };
  markdownStructuralSwap: (
    opId: string,
    direction: 'undo' | 'redo'
  ) => { ok: boolean; reason?: string; detail?: string; preRaw?: string; postRaw?: string; typingReplayed?: boolean };
  setUndoDescriptor: (descriptor: { undoTopOpId?: string; redoTopOpId?: string }) => void;
  renumberFootnotes: (mapping: Record<string, string>) => void;
  setStructuralSettleOpId: (opId: string | null) => void;
  receiveUndoOutcome: (opId: string, outcome: string) => void;
  receiveRedoOutcome: (opId: string, outcome: string) => void;
  heldUndoPressCount: () => number;
  find: (query: string) => unknown;
  replaceAll: (replacement: string) => number;
};
const ff = (): FF => (window as any).FinalFinal as FF;

const OP = '11111111-2222-3333-4444-555555555555';

let view: EditorView;
let resetUndoCoordinatorState: () => void;
let resetRecentUserEditSpan: () => void;
let collector: TypingCollector;
/** Every `errorHandler` message the page posted (the structural trace lines the UI tests read). */
const traceLines: string[] = [];

function currentView(): EditorView {
  const dom = document.querySelector('.cm-editor') as HTMLElement | null;
  const v = dom ? EditorView.findFromDOM(dom) : null;
  if (!v) throw new Error('no CodeMirror view mounted by main.ts');
  return v;
}

const docText = (): string => view.state.doc.toString();

// --- Documents in the shape the Markdown editor shows (blocks separated by a blank line, an anchor in front of every heading) ---

type Block =
  | { kind: 'leader'; id: string; level: number; title: string; anchorId?: string; managed?: 'notes' | 'bibliography' }
  | { kind: 'text'; text: string };

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

/** The request id of the leader tagged `tag`: a real UUID derived from the tag, so the tests stay readable. */
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

function build(blocks: Block[], trailing = '\n'): Built {
  const parts: string[] = [];
  const leaders: MarkdownLeader[] = [];
  for (const b of blocks) {
    if (b.kind === 'text') {
      parts.push(b.text);
    } else {
      const line = `${'#'.repeat(b.level)} ${b.title}`;
      parts.push(`<!-- @sid:${b.anchorId ?? sid(b.id)} -->${line}`);
      leaders.push({ id: uid(b.id), line, level: b.level, ...(b.managed ? { managed: b.managed } : {}) });
    }
  }
  return { text: `${parts.join('\n\n')}${trailing}`, leaders, blocks };
}

/** The text Swift sends for a restore: the blocks assembled the way the rows assemble, no trailing newline. */
const textOf = (blocks: Block[]): string => build(blocks, '').text;

const cid = (n: number): string => `c0c0c0c0-0000-4000-8000-${String(n).padStart(12, '0')}`;

/** A chapter: a level-1 heading tagged `a<n>` and one line of text. */
const ch = (
  n: number,
  body = `Text of chapter ${n}.`,
  extra: Partial<Extract<Block, { kind: 'leader' }>> = {}
): Block[] => [
  { kind: 'leader', id: `a${n}`, level: 1, title: `Chapter ${n}`, ...extra },
  { kind: 'text', text: body },
];

function load(text: string): void {
  resetUndoCoordinatorState();
  resetRecentUserEditSpan();
  ff().clearStructuralUndoRegistry();
  ff().resetForProjectSwitch();
  ff().setContent(text);
  ff().resetForProjectSwitch();
  view = currentView();
  expect(docText()).toBe(text);
  expect(undoDepth(view.state)).toBe(0);
}

// --- The commands, through the real page ---

type Plan = Array<{ id: string; level?: number }>;
const idsOf = (built: Built): string[] => built.leaders.map((leader) => leader.id);

function moveRun(ids: string[], run: string[], before: string | null): string[] {
  const rest = ids.filter((id) => !run.includes(id));
  const at = before === null ? rest.length : rest.indexOf(before);
  return [...rest.slice(0, at), ...run, ...rest.slice(at)];
}

/** Drags chapter `rootTag` in front of chapter `beforeTag` (null: to the end); `levels` gives the new heading level of dragged headings (by tag). */
function dragChapter(
  built: Built,
  rootTag: string,
  beforeTag: string | null,
  levels: Record<string, number> = {},
  opId = OP
): void {
  const order: Plan = moveRun(idsOf(built), [uid(rootTag)], beforeTag === null ? null : uid(beforeTag)).map((id) => {
    const tag = Object.keys(levels).find((k) => uid(k) === id);
    return tag === undefined ? { id } : { id, level: levels[tag] };
  });
  const result = ff().markdownStructuralReorder(
    JSON.stringify({ kind: 'reorder', opId, rootId: uid(rootTag), leaders: built.leaders, order, stopLine: null })
  );
  expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
}

/** Duplicates chapter `rootTag` (one leader): the copy follows it and its heading gets the id `cid(1)`. */
function duplicateChapter(built: Built, rootTag: string): void {
  const rootIdx = built.leaders.findIndex((leader) => leader.id === uid(rootTag));
  const endLeader = built.leaders.find((leader, i) => i > rootIdx && leader.level <= built.leaders[rootIdx].level);
  const result = ff().markdownStructuralDuplicate(
    JSON.stringify({
      kind: 'duplicate',
      opId: OP,
      rootId: uid(rootTag),
      leaders: built.leaders,
      stopLine: null,
      endLeaderId: endLeader ? endLeader.id : null,
      copyIds: [{ source: uid(rootTag), new: cid(1) }],
    })
  );
  expect(result.ok, `duplicate refused: ${JSON.stringify(result)}`).toBe(true);
}

/** Version History "Replace Current Section": the flat range of chapter `rootTag` is replaced by `text`. */
function restoreSection(built: Built, rootTag: string, text: string): void {
  const result = ff().markdownStructuralRestore(
    JSON.stringify({
      kind: 'restore',
      opId: OP,
      mode: 'section',
      rootId: uid(rootTag),
      leaders: built.leaders,
      stopLine: null,
      endLeaderId: null,
      text,
    })
  );
  expect(result.ok, `restore refused: ${JSON.stringify(result)}`).toBe(true);
}

// --- The page's part: record the typing done while the Cmd-Z waits, then ask for the document at the press, build Over, swap and replay ---

const PRESS = 1;

function startWait(press = PRESS): void {
  collector = new TypingCollector();
  collector.startPress(press);
}

/** Records the transaction the way the wired update listener will, then dispatches it. */
function typeInWait(spec: TransactionSpec): void {
  const tr = view.state.update(spec);
  collector.record(tr);
  view.dispatch(tr);
}

/** The user types `text` at `pos`; `time` pins the transaction time, which the history joins typing by. */
function typeAt(pos: number, text: string, time?: number): void {
  typeInWait({
    changes: { from: pos, insert: text },
    selection: { anchor: pos + text.length },
    userEvent: 'input.type',
    ...(time === undefined ? {} : { annotations: Transaction.time.of(time) }),
  });
}

/** Enter: CodeMirror's `insertNewlineAndIndent` tags its transaction `input`. */
function pressEnterAt(pos: number): void {
  typeInWait({ changes: { from: pos, insert: '\n' }, selection: { anchor: pos + 1 }, userEvent: 'input' });
}

/** Backspace over `[from, to)`: `delete.backward` (a selection: `delete.selection`). */
function deleteRange(from: number, to: number, userEvent = 'delete.backward'): void {
  typeInWait({ changes: { from, to }, selection: { anchor: from }, userEvent });
}

/** Right after the `nth` (0-based) occurrence of `marker`. */
function after(marker: string, nth = 0): number {
  let at = -1;
  for (let i = 0; i <= nth; i++) {
    at = docText().indexOf(marker, at + 1);
    if (at < 0) throw new Error(`marker #${nth} not in document: ${marker}`);
  }
  return at + marker.length;
}

function entryOf(): UndoRegistryEntry {
  const entry = getRegistry().get(OP);
  if (!entry) throw new Error('no registry entry');
  return entry;
}

/** What the premise of every placement test checks: changes were recorded, and the one trace line says so. */
function assertPremise(press = PRESS): string {
  const steps = collector.stepsSince(press);
  expect(steps.length, 'PREMISE: no change was recorded since the press').toBeGreaterThanOrEqual(1);
  const line = formatTypingSincePressLine(press, steps, 'rebased');
  expect(line, 'PREMISE: the helper line has no steps').toMatch(
    /^typing-since-press press=\d+ steps=[1-9]\d* decision=rebased$/
  );
  return line;
}

interface Pressed {
  input: ReplayInput;
  docAtPressText: string;
}

/** The re-check for an UNDO of the entry: the document at the press must be the saved copy; Over is built from it to the checkpoint. */
function prepareUndo(press = PRESS): Pressed {
  const entry = entryOf();
  const pd = docAtPress(view.state.doc, collector, press);
  expect(pd.decision, 'PREMISE: the document at the press cannot be built').toBe('rebased');
  expect(pd.doc.eq(entry.postOpDoc), 'PREMISE: the document at the press is not the saved copy').toBe(true);
  const over = buildOver({
    d0: pd.doc,
    target: entry.checkpoint.doc,
    checkpointDoc: entry.checkpoint.doc,
    opChanges: entry.markdown?.opChanges,
    moved: entry.markdown?.kind === 'reorder' ? entry.markdown.moved : null,
  });
  expect(over, 'PREMISE: Over could not be built').not.toBeNull();
  return {
    input: {
      targetState: entry.checkpoint,
      over: over as NonNullable<typeof over>,
      steps: pd.steps,
      liveSelection: view.state.selection,
    },
    docAtPressText: pd.doc.toString(),
  };
}

/** The swap the page does: install the target state, dispatch the replay (the page's `installState` stands behind `view.setState`). */
const install = (state: EditorState): void => {
  view.setState(state);
  // The page's `installState` forgets the span the user last typed in (its positions belong to the document just replaced); the replay then
  // dispatches against the new document and starts a span of its own.
  clearRecentUserEditSpan();
};

/** Chapter headings: the lines with `# Chapter`, the anchor in front included. */
const headingLines = (text: string): string[] => text.split('\n').filter((line) => line.includes('# Chapter'));

/** A heading line that does not start its own block, or an anchor in the middle of a line. */
function gluedHeadings(text: string): string[] {
  const lines = text.split('\n');
  const glued: string[] = [];
  lines.forEach((line, index) => {
    const isLeader = /^(?:<!-- @sid:[0-9a-f-]+ -->)?#{1,6}[ \t]/.test(line);
    if (isLeader && index > 0 && lines[index - 1] !== '') glued.push(line);
    else if (/\S<!-- @sid:/.test(line)) glued.push(line);
  });
  return glued;
}

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
          if (m?.message) traceLines.push(m.message);
        },
      },
    },
  };
  const root = document.createElement('div');
  root.id = 'editor';
  document.body.appendChild(root);
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
  startWait();
});

afterEach(() => {
  vi.useRealTimers();
});

const FIVE = (): Built => build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...ch(5)]);

// =============================================================================================================================
// What counts as typing (Step 0)
// =============================================================================================================================

describe('W1c what counts as the user typing', () => {
  // Break patch MD-W1c.patch: drop the `move` branch of `isTypingTransaction`.
  // Predicted failure: `move.line is typing` (expected false to be true).
  it('input*, delete*, move* and a dispatch marked typingDispatch are typing; pushes, derived corrections, undo and a bare dispatch are not', () => {
    load(build([...ch(1)]).text);
    const spec = (extra: TransactionSpec): TransactionSpec => ({ changes: { from: 0, insert: 'x' }, ...extra });
    const typing = (extra: TransactionSpec): boolean => isTypingTransaction(view.state.update(spec(extra)));
    expect(typing({ userEvent: 'input.type' }), 'input.type is typing').toBe(true);
    expect(typing({ userEvent: 'input' }), 'input (Enter) is typing').toBe(true);
    expect(typing({ userEvent: 'input.paste' }), 'input.paste is typing').toBe(true);
    expect(typing({ userEvent: 'delete.backward' }), 'delete.backward is typing').toBe(true);
    expect(typing({ userEvent: 'move.line' }), 'move.line is typing').toBe(true);
    expect(typing({ annotations: typingDispatch.of(true) }), 'a dispatch marked typingDispatch is typing').toBe(true);
    // Step 0: the app's smart-quote and spell-check replacement dispatches carry no userEvent today, so unmarked they do NOT count.
    expect(typing({}), 'a bare dispatch is not typing').toBe(false);
    expect(
      typing({ userEvent: 'input.type', annotations: Transaction.addToHistory.of(false) }),
      'a push is not typing'
    ).toBe(false);
    expect(typing({ userEvent: 'undo' }), 'a history replay is not typing').toBe(false);
    expect(
      isTypingTransaction(view.state.update({ selection: { anchor: 0 } })),
      'a selection change is not typing'
    ).toBe(false);
  });
});

// =============================================================================================================================
// W2: a drag, Cmd-Z, typing inside the moved chapter
// =============================================================================================================================

describe('W2 drag undo: typing inside the moved chapter moves back with it', () => {
  // Break patch MD-W2a.patch: in `Over.mapPos` skip the translation (`if (false && t && ...)`), so Over.changes alone maps the position.
  // Predicted failure: the typing is glued to the heading that follows the removal point: `don't stop` lands in front of
  // `<!-- @sid:...--># Chapter 2` (expected '...Text of chapter 4. don't stop\nmore words...' to be '...' -- see the diff).
  it('W2a Chapter 4 dragged above Chapter 2, Cmd-Z pressed, " don\'t stop", Return and "more words" typed at the end of Chapter 4: Chapter 4 is back with everything in one piece', () => {
    const start = FIVE();
    load(start.text);
    dragChapter(start, 'a4', 'a2');
    const dragged = docText();
    expect(dragged).not.toBe(start.text);

    startWait(); // the Cmd-Z is pressed here
    const p = after('Text of chapter 4.');
    typeAt(p, " don't stop");
    pressEnterAt(p + " don't stop".length);
    typeAt(p + " don't stop".length + 1, 'more words');
    assertPremise();

    const { input } = prepareUndo();
    const result = swapWithReplay(view, input, install);

    expect(result.ok, `replay refused: ${result.decision} ${result.reason ?? ''}`).toBe(true);
    expect(result.decision).toBe('rebased');
    expect(docText()).toBe(
      build([...ch(1), ...ch(2), ...ch(3), ...ch(4, "Text of chapter 4. don't stop\nmore words"), ...ch(5)]).text
    );
    expect(gluedHeadings(docText())).toEqual([]);
  });

  // Break patch MD-W2b.patch: the same as MD-W2a (skip the translation); the heading line is where it shows first.
  // Predicted failure: expected '...Chapter 4 (draft)...' ; the typing on the heading line and in the body is glued to the heading that follows.
  it('W2b the drop changed the level (Chapter 4 under Chapter 1 as a level-2 heading): typing on the heading line and in the body comes back with the chapter, the level is level 1 again', () => {
    const start = FIVE();
    load(start.text);
    dragChapter(start, 'a4', 'a2', { a4: 2 });
    expect(docText(), 'PREMISE: the drop rewrote the heading level').toContain('## Chapter 4');

    startWait();
    typeAt(after('## Chapter 4'), ' (draft)');
    typeAt(after('Text of chapter 4.'), ' more');
    assertPremise();

    const { input } = prepareUndo();
    const result = swapWithReplay(view, input, install);

    expect(result.ok, `replay refused: ${result.decision} ${result.reason ?? ''}`).toBe(true);
    expect(docText()).toBe(
      build([
        ...ch(1),
        ...ch(2),
        ...ch(3),
        ...ch(4, 'Text of chapter 4. more', { title: 'Chapter 4 (draft)' }),
        ...ch(5),
      ]).text
    );
    expect(headingLines(docText())).toHaveLength(5);
    expect(gluedHeadings(docText())).toEqual([]);
  });
});

describe('W2c drag undo in the two separator modes (the last chapter moves up, a chapter moves to the end)', () => {
  // Break patch MD-W2c.patch: the same as MD-W2a (skip the translation in `Over.mapPos`).
  // Predicted failure: expected '...' to be '...' (the typing lands at the removal point instead of inside the chapter).
  it('W2c-last Chapter 5 (the last) dragged above Chapter 2: typing at the end of Chapter 5 comes back with it', () => {
    const start = FIVE();
    load(start.text);
    dragChapter(start, 'a5', 'a2');

    startWait();
    typeAt(after('Text of chapter 5.'), ' tail');
    assertPremise();

    const { input } = prepareUndo();
    const result = swapWithReplay(view, input, install);

    expect(result.ok, `replay refused: ${result.decision} ${result.reason ?? ''}`).toBe(true);
    expect(docText()).toBe(build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...ch(5, 'Text of chapter 5. tail')]).text);
  });

  it('W2c-end Chapter 2 dragged to the end: typing at the end of Chapter 2 comes back with it', () => {
    const start = FIVE();
    load(start.text);
    dragChapter(start, 'a2', null);

    startWait();
    typeAt(after('Text of chapter 2.'), ' tail');
    assertPremise();

    const { input } = prepareUndo();
    const result = swapWithReplay(view, input, install);

    expect(result.ok, `replay refused: ${result.decision} ${result.reason ?? ''}`).toBe(true);
    expect(docText()).toBe(build([...ch(1), ...ch(2, 'Text of chapter 2. tail'), ...ch(3), ...ch(4), ...ch(5)]).text);
  });
});

// =============================================================================================================================
// W5: Duplicate, Cmd-Z, typing inside the copy
// =============================================================================================================================

describe('W5 duplicate undo: typing inside the copy', () => {
  // Break patch MD-W5.patch: in `ownLine` insert the bare text with no padding (`insert: core`, `padLeft: 0`).
  // Predicted failure: the letters are glued to the heading line after the removed copy: expected [heading titles] to deeply equal [...]
  // (`xyz<!-- @sid:...--># Chapter 3`).
  it('the copy goes; the letters typed at its end become their own paragraph at the gap, never joined to a heading; heading count and titles are unchanged', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    duplicateChapter(start, 'a2');
    expect(headingLines(docText()), 'PREMISE: the copy is there').toHaveLength(4);

    startWait();
    typeAt(after('Text of chapter 2.', 1), 'xyz'); // the end of the COPY's text
    assertPremise();

    const { input } = prepareUndo();
    const result = swapWithReplay(view, input, install);

    expect(result.ok, `replay refused: ${result.decision} ${result.reason ?? ''}`).toBe(true);
    expect(headingLines(docText())).toEqual(headingLines(start.text));
    expect(gluedHeadings(docText())).toEqual([]);
    expect(docText()).toBe(build([...ch(1), ...ch(2), { kind: 'text', text: 'xyz' }, ...ch(3)]).text);
  });
});

// =============================================================================================================================
// W6c: a restore, Cmd-Z, typing inside the replaced text
// =============================================================================================================================

describe('W6c restore undo: typing inside the replaced text', () => {
  // Break patch MD-W6c.patch: in `placeEdit` map a plain insertion with assoc -1 (`const at = chain.mapPos(from, -1)`), the START of the changed run.
  // Predicted failure: expected '...The XYcat sat on the mat...' to be '...The catXY sat on the mat...' (letters at the start of the changed run).
  it('Replace Current Section changed "cat" to "dog"; "XY" typed inside "dog": after Cmd-Z the old text is back and the letters sit at the end edge of the changed run (mid-sentence accepted)', () => {
    const start = build([...ch(1), ...ch(2, 'The cat sat on the mat.'), ...ch(3)]);
    load(start.text);
    restoreSection(start, 'a2', textOf(ch(2, 'The dog sat on the mat.')));
    expect(docText(), 'PREMISE: the restore replaced the word').toContain('The dog sat on the mat.');

    startWait();
    typeAt(after('The d'), 'XY');
    assertPremise();

    const { input } = prepareUndo();
    const result = swapWithReplay(view, input, install);

    expect(result.ok, `replay refused: ${result.decision} ${result.reason ?? ''}`).toBe(true);
    expect(docText()).toBe(build([...ch(1), ...ch(2, 'The catXY sat on the mat.'), ...ch(3)]).text);
  });
});

// =============================================================================================================================
// W7: what the user really types
// =============================================================================================================================

/** Feeds the smart-quote handler's own dispatch (marked `typingDispatch` by the handler itself since round 2a) to the test's collector. */
function asWiredDispatch(run: () => void): void {
  const own = view.dispatch;
  const original = own.bind(view) as (spec: TransactionSpec) => void;
  (view as { dispatch: unknown }).dispatch = (spec: TransactionSpec): void => {
    const tr = view.state.update(spec);
    collector.record(tr);
    original(tr as unknown as TransactionSpec);
  };
  try {
    run();
  } finally {
    (view as { dispatch: unknown }).dispatch = own;
  }
}

describe('W7 typing that is not a plain letter is placed', () => {
  // Break patch MD-W7a.patch: in `isTypingTransaction` drop the `typingDispatch` branch (the smart-quote dispatch is then not typing).
  // Predicted failure: `PREMISE: the document at the press cannot be built` (expected 'changed' to be 'rebased'). Step 0: the app's
  // smart-quote dispatch has no userEvent, so the wiring must mark it.
  it('W7a an apostrophe curled by the real smart-quote handler ("don" + \' + "t") is typed, undone with the drag, and comes back as don’t', () => {
    const start = FIVE();
    load(start.text);
    dragChapter(start, 'a4', 'a2');

    startWait();
    const p = after('Text of chapter 5.');
    typeAt(p, 'don');
    asWiredDispatch(() => {
      expect(smartQuotesInputHandler(view, p + 3, p + 3, "'"), 'the smart-quote handler took the apostrophe').toBe(
        true
      );
    });
    typeAt(p + 4, 't');
    expect(docText(), 'PREMISE: the apostrophe was curled').toContain('Text of chapter 5.don’t');
    assertPremise();

    const { input } = prepareUndo();
    const result = swapWithReplay(view, input, install);

    expect(result.ok, `replay refused: ${result.decision} ${result.reason ?? ''}`).toBe(true);
    expect(docText()).toBe(build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...ch(5, 'Text of chapter 5.don’t')]).text);
  });

  // Break patch MD-W7b.patch: in `isTypingTransaction` (typing-rebase.ts) accept only `input.type` instead of any `input` user event.
  // The Enter here is the user event `input` (the letters are `input.type`), so it stops counting as typing: it is then a change that
  // is not typing, which the replay cannot place, so the press is refused (`changed`) instead of replaying both keys.
  // Predicted failure: `replay refused: changed ...` (the `result.ok` check below). The failure itself is recorded in
  // mustfail-codemirror.json; the exact message was not re-run for this comment.
  it('W7b Enter in the middle of a line, then two letters on the new line: both come back, in order', () => {
    const start = FIVE();
    load(start.text);
    dragChapter(start, 'a4', 'a2');

    startWait();
    const p = after('Text of ', 3); // inside "Text of chapter 3." (the fourth "Text of " in the dragged document: 1, 4, 2, 3, 5)
    expect(docText().slice(p, p + 10), 'PREMISE: the caret is inside chapter 3').toBe('chapter 3.');
    pressEnterAt(p);
    typeAt(p + 1, 'ab');
    assertPremise();

    const { input } = prepareUndo();
    const result = swapWithReplay(view, input, install);

    expect(result.ok, `replay refused: ${result.decision} ${result.reason ?? ''}`).toBe(true);
    expect(docText()).toBe(build([...ch(1), ...ch(2), ...ch(3, 'Text of \nabchapter 3.'), ...ch(4), ...ch(5)]).text);
  });

  // Break patch MD-W7c.patch: in `Over.classify` let the END of a deletion touch the start of a removed range (`pos >= range.from`):
  // Over then marks the boundary between the original and its copy as deleted.
  // Predicted failure: expected 'unplaceable' to be 'rebased'.
  it("W7c a joining Backspace at the start of the copy's heading line (one newline of the blank line before it): placed, the blank line before the next chapter shrinks by one newline", () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    duplicateChapter(start, 'a2');

    startWait();
    const a = docText().indexOf(`<!-- @sid:${cid(1)} -->`);
    deleteRange(a - 1, a);
    assertPremise();

    const { input } = prepareUndo();
    const result = swapWithReplay(view, input, install);

    expect(result.decision).toBe('rebased');
    expect(result.ok, `replay refused: ${result.reason ?? ''}`).toBe(true);
    expect(docText()).toBe(start.text.replace('Text of chapter 2.\n\n', 'Text of chapter 2.\n'));
  });

  // Break patch MD-W7d.patch: in `placeEdit` skip the straddle check (delete the `throw new Unplaceable(\`a deletion starts in ...\`)`).
  // Predicted failure: expected true to be false (the cut across the boundary is placed, clipped, instead of refused).
  it('W7d the unplaceable variant: a selection from the original chapter into the copy deleted — the dry run says unplaceable', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    duplicateChapter(start, 'a2');

    startWait();
    const a = docText().indexOf(`<!-- @sid:${cid(1)} -->`);
    deleteRange(after('Text of chapter 2.') - 5, a + 10, 'delete.selection'); // from the original's text into the copy's heading
    assertPremise();

    const { input } = prepareUndo();
    const plan = buildReplayDryRun(input);

    expect(plan.ok).toBe(false);
    expect(plan.decision).toBe('unplaceable');
  });
});

// =============================================================================================================================
// W9, W10: the caret and the history
// =============================================================================================================================

describe('W9 the caret after the replay', () => {
  // Break patch MD-W9.patch: in `buildReplayDryRun` leave the selection as the swap left it (`selection: undefined` on the last spec).
  // Predicted failure: expected '...abcxyz...' : the next letter lands where the swap left the caret, not right after the replayed text.
  it('a letter typed straight after the swap lands right after the replayed text', () => {
    const start = FIVE();
    load(start.text);
    dragChapter(start, 'a4', 'a2');

    startWait();
    typeAt(after('Text of chapter 5.'), 'abc');
    assertPremise();
    const { input } = prepareUndo();
    const result = swapWithReplay(view, input, install);
    expect(result.ok, `replay refused: ${result.decision} ${result.reason ?? ''}`).toBe(true);

    const caret = view.state.selection.main.head;
    view.dispatch({
      changes: { from: caret, insert: 'xyz' },
      selection: { anchor: caret + 3 },
      userEvent: 'input.type',
    });

    expect(docText()).toBe(build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...ch(5, 'Text of chapter 5.abcxyz')]).text);
  });
});

describe('W10 one history event per press segment', () => {
  // Break patch MD-W10.patch: in `buildReplayDryRun` drop the `isolateHistory.of('before')` from the replay annotations.
  // Predicted failure: expected '...5.abc...' : with no isolation the second segment joins the first (adjacent, same instant) and one undo takes both.
  it('typing after press 1 and typing after press 2, replayed as two segments: one undo() takes back exactly the second, the next the first', () => {
    const start = FIVE();
    load(start.text);
    dragChapter(start, 'a4', 'a2');

    startWait(1);
    const p = after('Text of chapter 5.');
    typeAt(p, 'abc', 1000);
    collector.startPress(2); // a second Cmd-Z was pressed (held) here
    typeAt(p + 3, 'def', 1001);
    expect(
      collector.stepsSince(1).map((step) => step.tag),
      'PREMISE: the two segments carry their press numbers'
    ).toEqual([1, 2]);
    assertPremise(1);

    const { input } = prepareUndo(1);
    const swapped = buildReplayDryRun(input);
    expect(swapped.ok && swapped.replaySpecs.length, 'PREMISE: one replay transaction per press segment').toBe(2);
    const result = swapWithReplay(view, input, install);
    expect(result.ok, `replay refused: ${result.decision} ${result.reason ?? ''}`).toBe(true);
    expect(docText()).toBe(build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...ch(5, 'Text of chapter 5.abcdef')]).text);

    expect(undo(view)).toBe(true);
    expect(docText(), 'one undo takes back the second segment only').toBe(
      build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...ch(5, 'Text of chapter 5.abc')]).text
    );
    expect(undo(view)).toBe(true);
    expect(docText(), 'the next takes back the first, and nothing of the swapped-in text').toBe(start.text);
  });
});

describe('W11c the next held press builds its document from the rebased records', () => {
  // Break patch MD-W11c.patch: in `TypingCollector.adoptReplay` keep the old records (`this.steps.filter((step) => step.tag > press)`).
  // Predicted failure: expected '...' to be '...' (the stale record inverts at the offsets of the dragged document, so the document at press 2 is not target+abc).
  it('after press 1 is replayed, the document at press 2 is the target plus the typing done before press 2', () => {
    const start = FIVE();
    load(start.text);
    dragChapter(start, 'a4', 'a2');

    startWait(1);
    const p = after('Text of chapter 3.'); // chapter 3 sits at other offsets in the dragged document than in the restored one
    typeAt(p, 'abc');
    collector.startPress(2);
    typeAt(p + 3, 'def');
    assertPremise(1);

    const { input } = prepareUndo(1);
    const result = swapWithReplay(view, input, install);
    expect(result.ok, `replay refused: ${result.decision} ${result.reason ?? ''}`).toBe(true);
    collector.adoptReplay(1, result.rebasedSteps ?? []);

    const second = docAtPress(view.state.doc, collector, 2);
    expect(second.decision).toBe('rebased');
    expect(second.doc.toString()).toBe(
      build([...ch(1), ...ch(2), ...ch(3, 'Text of chapter 3.abc'), ...ch(4), ...ch(5)]).text
    );
  });
});

// =============================================================================================================================
// W13: an unplaceable change leaves the live document alone
// =============================================================================================================================

describe('W13 a change that cannot be placed is refused before the swap', () => {
  // Break patch MD-W13.patch: in `swapWithReplay` install the target state before refusing (`install(input.targetState)` on the `!plan.ok` branch):
  // the swap without the dry run's verdict.
  // Predicted failure: expected '...' to be '...' : the document is the swapped-in checkpoint, not the live document.
  it('the dry run fails, nothing is touched: the document, the state and the typing are the live ones', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    duplicateChapter(start, 'a2');

    startWait();
    typeAt(after('Text of chapter 1.'), 'kept'); // typing that CAN be placed
    const a = docText().indexOf(`<!-- @sid:${cid(1)} -->`);
    deleteRange(after('Text of chapter 2.') - 5, a + 10, 'delete.selection'); // a cut that cannot
    assertPremise();
    const liveDoc = docText();
    const liveState = view.state;

    const { input } = prepareUndo();
    const result = swapWithReplay(view, input, install);

    expect(result.ok).toBe(false);
    expect(result.decision).toBe('unplaceable');
    expect(docText(), 'the document is the live document').toBe(liveDoc);
    expect(view.state === liveState, 'the state was not replaced').toBe(true);
    expect(docText()).toContain('Text of chapter 1.kept');
  });
});

// =============================================================================================================================
// W14: the one trace line
// =============================================================================================================================

describe('W14 the trace line is written for every outcome', () => {
  // Break patch MD-W14a.patch: in `buildReplayDryRun` answer a run with no typing as `rebased` (`decision: 'rebased'` in the zero-steps branch).
  // Predicted failure: expected 'typing-since-press press=1 steps=0 decision=rebased' to be 'typing-since-press press=1 steps=0 decision=matched'.
  it('W14a matched (nothing typed since the press) and rebased (typing put back)', () => {
    const start = FIVE();
    load(start.text);
    dragChapter(start, 'a4', 'a2');

    // matched: the press was recorded, nothing was typed
    startWait();
    expect(collector.recording, 'PREMISE: recording started with the press').toBe(true);
    const idle = prepareUndoNoSteps();
    const matched = swapWithReplay(view, idle, install);
    expect(formatTypingSincePressLine(PRESS, matched.steps, matched.decision)).toBe(
      'typing-since-press press=1 steps=0 decision=matched'
    );
    expect(docText(), 'matched: the swap alone').toBe(start.text);

    // rebased: the same command, typing in the wait
    load(start.text);
    dragChapter(start, 'a4', 'a2');
    startWait();
    typeAt(after('Text of chapter 5.'), 'q');
    const line = assertPremise();
    expect(line).toBe('typing-since-press press=1 steps=1 decision=rebased');
    const { input } = prepareUndo();
    const rebased = swapWithReplay(view, input, install);
    expect(formatTypingSincePressLine(PRESS, rebased.steps, rebased.decision)).toBe(line);
  });

  // Break patch MD-W14b.patch: in `docAtPress` let an automatic-only run go on (`if (typingSteps.length === 0) return ...` -> `if (false) return ...`).
  // Predicted failure: expected 'rebased' to be 'changed'.
  // (Round 3: typing MIXED with an automatic rewrite is no longer `changed`, it is commuted: see W15. What stays `changed` is an automatic
  // rewrite with no typing at all, which the swap handles as it always did.)
  it('W14b changed (an automatic rewrite alone in the wait): the document at the press is the live document, the line says changed, reset() forgets', () => {
    load(build([...ch(1), ...ch(2)]).text);
    startWait();
    typeInWait({ changes: { from: 0, insert: 'Z' }, annotations: Transaction.addToHistory.of(false) }); // an app push, not typing
    assertPremise();

    const pd = docAtPress(view.state.doc, collector, PRESS);

    expect(pd.decision).toBe('changed');
    expect(pd.doc === view.state.doc, 'the live document comes back, so the routing refuses as it does today').toBe(
      true
    );
    expect(formatTypingSincePressLine(PRESS, pd.steps, pd.decision)).toBe(
      'typing-since-press press=1 steps=1 decision=changed'
    );
    for (const decision of ['unplaceable', 'noEntry', 'midOp'] as const) {
      expect(formatTypingSincePressLine(7, 3, decision)).toBe(
        `typing-since-press press=7 steps=3 decision=${decision}`
      );
    }
    collector.reset();
    expect(collector.recording).toBe(false);
    expect(collector.stepsSince(PRESS)).toEqual([]);
  });
});

/** The re-check when nothing was typed: no steps, Over from the document at the press (the saved copy) to the checkpoint. */
function prepareUndoNoSteps(): ReplayInput {
  const entry = entryOf();
  const over = buildOver({
    d0: view.state.doc,
    target: entry.checkpoint.doc,
    checkpointDoc: entry.checkpoint.doc,
    opChanges: entry.markdown?.opChanges,
    moved: entry.markdown?.kind === 'reorder' ? entry.markdown.moved : null,
  });
  if (!over) throw new Error('Over could not be built');
  return { targetState: entry.checkpoint, over, steps: [], liveSelection: view.state.selection };
}

// =============================================================================================================================
// ROUND 2a: the REAL routes. The same page, driven the way Swift drives it: a real Cmd-Z keydown latches the press, typing is real
// transactions, `markdownStructuralSwap` is the page call, `receiveUndoOutcome` is Swift's reply. The collector, the typing-push hold and the
// trace line are the wired ones (undo-coordinator.ts, typing-push-hold.ts, api-structural-markdown.ts).
// =============================================================================================================================

const handler = (name: string): ReturnType<typeof vi.fn> =>
  (window as any).webkit.messageHandlers[name].postMessage as ReturnType<typeof vi.fn>;

function loadRoute(text: string): void {
  load(text);
  for (const name of [
    'structuralUndoRequested',
    'structuralRedoRequested',
    'structuralUndoRefused',
    'historyEdited',
    'contentChanged',
    'undoHeldPressSettled',
    'undoQueueDropped',
  ]) {
    handler(name).mockClear();
  }
  traceLines.length = 0;
}

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

/** The key press of the structural undo: routed structural, the latch is up, the press is numbered. */
function pressUndo(): void {
  const before = handler('structuralUndoRequested').mock.calls.length;
  press('undo');
  expect(handler('structuralUndoRequested').mock.calls.length, 'the Cmd-Z was not routed structural').toBe(before + 1);
}

/** The user types for real (a transaction with the userEvent a keystroke has); the wired listener records it. */
function userTypes(pos: number, text: string): void {
  view.dispatch({
    changes: { from: pos, insert: text },
    selection: { anchor: pos + text.length },
    userEvent: 'input.type',
  });
}

/** Swift's part: the page call, then the reply (`performed` for an ok swap, `failed` for a refusal). */
function swiftAnswers(direction: 'undo' | 'redo' = 'undo'): ReturnType<FF['markdownStructuralSwap']> {
  const result = ff().markdownStructuralSwap(OP, direction);
  const reply = direction === 'undo' ? ff().receiveUndoOutcome : ff().receiveRedoOutcome;
  if (result.ok) ff().setUndoDescriptor(direction === 'undo' ? { redoTopOpId: OP } : { undoTopOpId: OP });
  reply(OP, result.ok ? 'performed' : 'failed');
  return result;
}

/** The premise of every route test: changes were recorded since the in-flight press, and the trace line will say so. */
function routePremise(): { press: number; steps: number } {
  const pressNo = getInFlightPress();
  const steps = getTypingCollector().stepsSince(pressNo).length;
  expect(pressNo, 'PREMISE: no press is in flight').toBeGreaterThan(0);
  expect(steps, 'PREMISE: no change was recorded since the press').toBeGreaterThanOrEqual(1);
  expect(formatTypingSincePressLine(pressNo, steps, 'rebased')).toMatch(/steps=[1-9]/);
  return { press: pressNo, steps };
}

const trailLines = (): string[] => traceLines.filter((line) => line.includes('typing-since-press'));
const expectTrail = (press: number, steps: number, decision: string): void => {
  expect(trailLines(), 'the one trace line').toEqual([
    `[STRUCT-TRACE] typing-since-press press=${press} steps=${steps} decision=${decision}`,
  ]);
};

/** The text of every contentChanged push Swift has been sent. */
const pushedTexts = (): string[] =>
  handler('contentChanged').mock.calls.map((call) => (call[0] as { content: string }).content);

function restoreRoute(
  built: Built,
  mode: 'whole' | 'section' | 'insertAfter',
  rootTag: string | null,
  text: string
): void {
  const result = ff().markdownStructuralRestore(
    JSON.stringify({
      kind: 'restore',
      opId: OP,
      mode,
      rootId: mode === 'whole' || rootTag === null ? null : uid(rootTag),
      leaders: built.leaders,
      stopLine: null,
      endLeaderId: null,
      text,
    })
  );
  expect(result.ok, `restore refused: ${JSON.stringify(result)}`).toBe(true);
}

/** An undone command with typing in the wait, answered through the real route. `type` runs after the key press. */
function undoWithTyping(typeIt: () => void): ReturnType<FF['markdownStructuralSwap']> {
  ff().setUndoDescriptor({ undoTopOpId: OP });
  pressUndo();
  typeIt();
  routePremise();
  return swiftAnswers('undo');
}

describe('R1 drag undo (the slow route), typing in another chapter', () => {
  // Break patch MD-route-main.patch: in `liveRoutingParams` (undo-coordinator.ts) compare the LIVE document (`currentDoc: view.state.doc`)
  // instead of the document at the press. Predicted failure: `expected 'changed' to be undefined` (the swap refuses the typed press).
  it('performed, the exact document, the caret right after the replayed text, one trace line, typingReplayed', () => {
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2');
    const draggedText = docText(); // the document at the press
    ff().setUndoDescriptor({ undoTopOpId: OP });
    pressUndo();
    userTypes(after('Text of chapter 5.'), ' end');
    const { press: pressNo, steps } = routePremise();

    const result = swiftAnswers('undo');

    expect(result.reason, 'the press was refused').toBeUndefined();
    expect(result.ok).toBe(true);
    expect((result as { typingReplayed?: boolean }).typingReplayed).toBe(true);
    const expected = build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...ch(5, 'Text of chapter 5. end')]).text;
    expect(docText()).toBe(expected);
    expect(view.state.selection.main.head, 'the caret is right after the replayed text').toBe(
      expected.indexOf('Text of chapter 5. end') + 'Text of chapter 5. end'.length
    );
    expectTrail(pressNo, steps, 'rebased');
    // The reply carries the document AT THE PRESS as preRaw and the swapped-in text BEFORE the replay as postRaw.
    expect(result.preRaw).toBe(draggedText);
    expect(result.postRaw).toBe(start.text);
  });
});

describe('R2 drag undo through the route, typing inside the moved chapter', () => {
  // Break patch MD-route-R2.patch: skip the translation (`false &&` in `Over.mapPos`, typing-rebase.ts), the same break as MD-W2a.
  // Predicted failure: doc mismatch, the typing glued to the heading that follows the removal point.
  it('the moved chapter goes back with its typing, Return included', () => {
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2');

    const result = undoWithTyping(() => {
      const p = after('Text of chapter 4.');
      userTypes(p, " don't stop");
      userTypes(p + " don't stop".length, '\n');
      userTypes(p + " don't stop".length + 1, 'more words');
    });

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(
      build([...ch(1), ...ch(2), ...ch(3), ...ch(4, "Text of chapter 4. don't stop\nmore words"), ...ch(5)]).text
    );
  });
});

describe('R3 duplicate undo, typing outside the copy', () => {
  // Break patch MD-route-main.patch (the same: the routing on the live document refuses the typed press).
  it('the copy goes, the typing in the original stays where it was typed', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    loadRoute(start.text);
    duplicateChapter(start, 'a2');

    const result = undoWithTyping(() => userTypes(after('Text of chapter 1.'), ' extra'));

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(build([...ch(1, 'Text of chapter 1. extra'), ...ch(2), ...ch(3)]).text);
  });
});

describe('R4 duplicate undo, typing inside the copy', () => {
  // Break patch MD-route-R4.patch: no padding in `ownLine` (the same break as MD-W5).
  // Predicted failure: the letters are glued to the heading line after the removed copy.
  it('the letters become their own paragraph at the gap, never joined to a heading', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    loadRoute(start.text);
    duplicateChapter(start, 'a2');

    const result = undoWithTyping(() => userTypes(after('Text of chapter 2.', 1), 'xyz'));

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(headingLines(docText())).toEqual(headingLines(start.text));
    expect(gluedHeadings(docText())).toEqual([]);
    expect(docText()).toBe(build([...ch(1), ...ch(2), { kind: 'text', text: 'xyz' }, ...ch(3)]).text);
  });
});

describe('R5 the three Version History restores, undo with typing outside and inside', () => {
  const before = (): Built => build([...ch(1), ...ch(2, 'The cat sat on the mat.'), ...ch(3)]);
  const restored = (): string => build([...ch(1), ...ch(2, 'The dog sat on the mat.'), ...ch(3)]).text;

  // Break patch MD-route-main.patch (the routing on the live document refuses the typed press).
  it('R5a Restore Entire Project: typing outside the changed text stays', () => {
    const start = before();
    loadRoute(start.text);
    restoreRoute(start, 'whole', null, restored());
    const result = undoWithTyping(() => userTypes(after('Text of chapter 3.'), ' tail'));
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(
      build([...ch(1), ...ch(2, 'The cat sat on the mat.'), ...ch(3, 'Text of chapter 3. tail')]).text
    );
  });

  it('R5b Replace Current Section: typing outside stays; typing inside the replaced word goes to the edge of the changed run', () => {
    const start = before();
    loadRoute(start.text);
    restoreRoute(start, 'section', 'a2', textOf(ch(2, 'The dog sat on the mat.')));
    const result = undoWithTyping(() => {
      userTypes(after('Text of chapter 3.'), ' tail');
      userTypes(after('The d'), 'XY');
    });
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(
      build([...ch(1), ...ch(2, 'The catXY sat on the mat.'), ...ch(3, 'Text of chapter 3. tail')]).text
    );
  });

  // Break patch MD-route-R5c.patch: no padding in `ownLine` (the same break as MD-W5).
  it('R5c Insert as New Section: typing outside stays; typing inside the inserted section becomes its own paragraph', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    loadRoute(start.text);
    const fresh: Block[] = [
      { kind: 'leader', id: 'fresh1', level: 1, title: 'Restored chapter', anchorId: cid(7) },
      { kind: 'text', text: 'Body of the restored chapter.' },
    ];
    restoreRoute(start, 'insertAfter', 'a2', textOf(fresh));
    expect(docText(), 'PREMISE: the section is in').toContain('Restored chapter');
    const result = undoWithTyping(() => {
      userTypes(after('Text of chapter 1.'), ' tail');
      userTypes(after('Body of the restored chapter.'), 'xyz');
    });
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(
      build([...ch(1, 'Text of chapter 1. tail'), ...ch(2), { kind: 'text', text: 'xyz' }, ...ch(3)]).text
    );
  });
});

describe('R6 the caret and the next letter, through the route', () => {
  // Break patch MD-route-R6.patch (leave the selection as the swap left it in `buildReplayDryRun`): predicted failure `expected 'xyz<!-- @sid:...' to be '<!-- @sid:...'`.
  it('a letter typed straight after the swap lands right after the replayed text', () => {
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2');
    const result = undoWithTyping(() => userTypes(after('Text of chapter 5.'), 'abc'));
    expect(result.ok, JSON.stringify(result)).toBe(true);

    const caret = view.state.selection.main.head;
    userTypes(caret, 'xyz');

    expect(docText()).toBe(build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...ch(5, 'Text of chapter 5.abcxyz')]).text);
  });
});

describe('R7 held presses: Cmd-Z, Cmd-Shift-Z held, then typing', () => {
  // Break patch MD-route-R7.patch: in `drainQueuedPresses` drop the ended-redo test (the three-line `if`).
  // Predicted failure: `expected "spy" to be called 1 times, but got 0 times` (no notice for the held redo).
  it('the held redo is ended by the typing: the existing notice, the press settled, nothing routed, the exact document', () => {
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2');
    ff().setUndoDescriptor({ undoTopOpId: OP });
    pressUndo();
    press('redo'); // held behind the undo
    expect(ff().heldUndoPressCount()).toBe(1);
    userTypes(after('Text of chapter 5.'), 'xyz'); // typed AFTER the redo was pressed
    routePremise();

    const result = swiftAnswers('undo');

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...ch(5, 'Text of chapter 5.xyz')]).text);
    expect(handler('undoQueueDropped')).toHaveBeenCalledTimes(1);
    expect(handler('undoQueueDropped')).toHaveBeenCalledWith({ count: 1 });
    expect(handler('undoHeldPressSettled')).toHaveBeenCalledWith({ count: 1 });
    expect(handler('structuralRedoRequested'), 'nothing is routed for the ended redo').not.toHaveBeenCalled();
    expect(ff().heldUndoPressCount()).toBe(0);
  });

  // CONTROL (no break patch): pins the other side of the tag rule. Typing done before the redo press does not end it; the break that
  // would is the same one MD-route-R7 makes visible from the other side.
  it('typing BEFORE the held redo was pressed does not end it: it is routed on the document at its own press (a plain, empty text redo)', () => {
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2');
    ff().setUndoDescriptor({ undoTopOpId: OP });
    pressUndo();
    userTypes(after('Text of chapter 5.'), 'abc'); // typed before the redo press
    press('redo');
    expect(ff().heldUndoPressCount()).toBe(1);
    routePremise();

    const result = swiftAnswers('undo');

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...ch(5, 'Text of chapter 5.abc')]).text);
    expect(
      handler('structuralRedoRequested'),
      'the redo is not routed structural: the typing has no redo of its own'
    ).not.toHaveBeenCalled();
    expect(handler('undoQueueDropped')).not.toHaveBeenCalled();
    expect(handler('undoHeldPressSettled')).toHaveBeenCalledWith({ count: 1 });
  });
});

describe('R7c a held Cmd-Z is routed on the document at ITS OWN press', () => {
  // Break patch MD-route-R7c.patch: in `drainQueuedPresses` route on the live document (`decideLiveRouting(view, press.direction)`).
  // Predicted failure: `expected "spy" to be called 2 times, but got 1 times` (the second press falls through to a text undo that takes
  // the typing back, instead of being sent as a held structural request).
  it('two commands, Cmd-Z twice, typing after the second press: both are undone, the typing stays', () => {
    const OP2 = '99999999-2222-3333-4444-555555555555';
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2'); // OP
    const afterFirst = build([...ch(1), ...ch(4), ...ch(2), ...ch(3), ...ch(5)]);
    dragChapter(afterFirst, 'a5', 'a3', {}, OP2); // OP2 is on top
    ff().setUndoDescriptor({ undoTopOpId: OP2 });
    pressUndo(); // P1: the undo of OP2
    press('undo'); // P2: held; will be the undo of OP
    expect(ff().heldUndoPressCount()).toBe(1);
    userTypes(after('Text of chapter 1.'), ' zz'); // typed after P2 was pressed
    routePremise();

    const first = ff().markdownStructuralSwap(OP2, 'undo');
    expect(first.ok, JSON.stringify(first)).toBe(true);
    ff().setUndoDescriptor({ undoTopOpId: OP, redoTopOpId: OP2 });
    ff().receiveUndoOutcome(OP2, 'performed'); // the drain routes P2

    expect(handler('structuralUndoRequested')).toHaveBeenCalledTimes(2);
    expect(handler('structuralUndoRequested')).toHaveBeenLastCalledWith({ opId: OP, held: true });
    const second = ff().markdownStructuralSwap(OP, 'undo');
    expect(second.ok, JSON.stringify(second)).toBe(true);
    ff().setUndoDescriptor({ redoTopOpId: OP });
    ff().receiveUndoOutcome(OP, 'performed');

    expect(docText()).toBe(build([...ch(1, 'Text of chapter 1. zz'), ...ch(2), ...ch(3), ...ch(4), ...ch(5)]).text);
    expect(ff().heldUndoPressCount()).toBe(0);
  });
});

describe('R8 slow redo of a drag with typing in the wait', () => {
  // Break patch MD-route-main.patch (the routing on the live document refuses the typed redo).
  it('performed, the dragged chapter moves again, typing outside stays and typing inside the chapter moves with it', () => {
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2');
    ff().setUndoDescriptor({ undoTopOpId: OP });
    pressUndo();
    expect(swiftAnswers('undo').ok).toBe(true);
    expect(docText(), 'PREMISE: the undo put the order back').toBe(start.text);

    press('redo');
    expect(handler('structuralRedoRequested')).toHaveBeenCalledTimes(1);
    userTypes(after('Text of chapter 4.'), ' inside');
    userTypes(after('Text of chapter 5.'), ' outside');
    routePremise();

    const result = swiftAnswers('redo');

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect((result as { typingReplayed?: boolean }).typingReplayed).toBe(true);
    expect(docText()).toBe(
      build([
        ...ch(1),
        ...ch(4, 'Text of chapter 4. inside'),
        ...ch(2),
        ...ch(3),
        ...ch(5, 'Text of chapter 5. outside'),
      ]).text
    );
  });
});

describe('R9 a change that cannot be placed is refused before the swap', () => {
  // Break patch MD-route-R9.patch: in the refusal of `markdownStructuralSwap` (`refuse`) discard the held push instead of sending it (D2).
  // Predicted failure: `expected [] to deeply equal [ '...' ]` (the typed text never reaches the writer).
  it('reason unplaceable, the document is the live document, the typing reaches Swift exactly once', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    loadRoute(start.text);
    duplicateChapter(start, 'a2');
    ff().setUndoDescriptor({ undoTopOpId: OP });
    vi.useFakeTimers();
    pressUndo();
    userTypes(after('Text of chapter 1.'), 'kept');
    const a = docText().indexOf(`<!-- @sid:${cid(1)} -->`);
    view.dispatch({ changes: { from: after('Text of chapter 2.') - 5, to: a + 10 }, userEvent: 'delete.selection' }); // a cut across the boundary
    const { press: pressNo, steps } = routePremise();
    const liveState = view.state;
    vi.advanceTimersByTime(200);
    expect(handler('contentChanged'), 'the push is HELD while the press is latched').not.toHaveBeenCalled();

    const result = swiftAnswers('undo');

    expect(result).toMatchObject({ ok: false, reason: 'unplaceable' });
    expect(view.state === liveState, 'nothing on the screen changed').toBe(true);
    expectTrail(pressNo, steps, 'unplaceable');
    expect(pushedTexts(), 'the held typing is sent once, as the live text').toEqual([docText()]);
    vi.advanceTimersByTime(200);
    expect(handler('contentChanged'), 'and not again').toHaveBeenCalledTimes(1);
  });
});

describe('R10 the typing push is held while latched; every exit releases it exactly once, a replay does not send it', () => {
  function latchAndType(): string {
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2');
    ff().setUndoDescriptor({ undoTopOpId: OP });
    vi.useFakeTimers();
    pressUndo();
    userTypes(after('Text of chapter 5.'), 'hold');
    routePremise();
    vi.advanceTimersByTime(200);
    expect(handler('contentChanged'), 'HELD while latched').not.toHaveBeenCalled();
    return docText();
  }

  // Break patch MD-route-hold.patch: in `pushOrHoldContent` (typing-push-hold.ts) post at once (`if (true)` for `if (!held)`).
  // Predicted failure: `HELD while latched: expected "spy" to not be called` .
  it("a swap that put the typing back does not send the held push: nothing at the exit; the replay's own change notification is the one later push", () => {
    latchAndType();
    expect(swiftAnswers('undo').ok).toBe(true);
    expect(handler('contentChanged'), 'the held push is discarded at the exit').not.toHaveBeenCalled();
    vi.advanceTimersByTime(200);
    expect(pushedTexts(), 'the replay is an ordinary change of the page: one push, the text now on the screen').toEqual(
      [docText()]
    );
  });

  // Break patch MD-route-cancelled.patch: in `handleUndoReplyFromSwift` do not release on `cancelled`
  // (`reply.outcome !== 'performed' && reply.outcome !== 'cancelled'`). Predicted failure: `expected "spy" to be called 1 times, but got 0 times`.
  it('cancelled (the lifecycle barrier): released once, the document untouched', () => {
    const typed = latchAndType();
    ff().receiveUndoOutcome(OP, 'cancelled');
    expect(pushedTexts()).toEqual([typed]);
    vi.advanceTimersByTime(200);
    expect(handler('contentChanged')).toHaveBeenCalledTimes(1);
    expect(getTypingCollector().recording, 'the collector forgot').toBe(false);
  });

  // Break patch MD-route-failed.patch: do not release on `failed`. Predicted failure: `expected [] to deeply equal [ Array(1) ]`.
  it('failed reply: released once', () => {
    const typed = latchAndType();
    ff().receiveUndoOutcome(OP, 'failed');
    expect(pushedTexts()).toEqual([typed]);
  });

  // Break patch MD-route-fallback.patch: discard the held push on `fallback` (`releaseTypingPushes('discard')`). Predicted failure:
  // `expected undefined to be '<!-- @sid:...'` (the typed text never reaches the writer). Since F1 a fallback with typing after the press runs no
  // text undo (R15b), so the old break "do not release on fallback" is no longer observable: the drain ends the window straight after.
  it('fallback reply: the typed text is released (sent) once', () => {
    const typed = latchAndType();
    ff().receiveUndoOutcome(OP, 'fallback');
    expect(pushedTexts()[0]).toBe(typed);
    expect(handler('contentChanged').mock.calls.length).toBeGreaterThanOrEqual(1);
  });

  // Break patch MD-route-timeout.patch: drop the release in the latch-timeout callback. Predicted failure: `expected [] to deeply equal [ Array(1) ]`.
  it('the 30 second latch timeout: released once', () => {
    const typed = latchAndType();
    vi.advanceTimersByTime(LATCH_TIMEOUT_MS + 10);
    expect(pushedTexts()).toEqual([typed]);
    expect(getTypingCollector().recording).toBe(false);
  });

  // Break patch MD-route-barrier.patch: drop the release in `releaseLatchAndQueue`. Predicted failure: `expected [] to deeply equal [ Array(1) ]`.
  it('a barrier clear (clearStructuralUndoRegistry): released once', () => {
    const typed = latchAndType();
    ff().clearStructuralUndoRegistry();
    expect(pushedTexts()).toEqual([typed]);
  });
});

// =============================================================================================================================
// ROUND 2b: the Markdown QUICK routes (a Delete's quick undo and quick redo; the composed quick redo of a Duplicate and a restore). The page
// function is the same one the slow route calls; what is new here is the quick REDO of a Delete, which re-runs the delete on the LIVE
// document, so typing done in the wait is already in it and is not replayed.
// =============================================================================================================================

/** Delete Section on chapter `rootTag` (a request with no managed region), the descriptor set as Swift's push will. */
function deleteChapter(built: Built, rootTag: string, opId = OP): void {
  const rootIdx = built.leaders.findIndex((leader) => leader.id === uid(rootTag));
  const endLeader = built.leaders.find((leader, i) => i > rootIdx && leader.level <= built.leaders[rootIdx].level);
  const blockIdx = built.blocks.findIndex((b) => b.kind === 'leader' && b.id === rootTag);
  const managed = built.blocks.slice(blockIdx + 1).find((b) => b.kind === 'leader' && b.managed);
  const stopLine = managed && managed.kind === 'leader' ? `${'#'.repeat(managed.level)} ${managed.title}` : null;
  const result = ff().markdownStructuralEditorFirst(
    JSON.stringify({
      kind: 'delete',
      opId,
      rootId: uid(rootTag),
      leaders: built.leaders,
      stopLine,
      endLeaderId: endLeader ? endLeader.id : null,
    })
  );
  expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);
  ff().setUndoDescriptor({ undoTopOpId: opId });
}

/** A Delete that has been undone with no typing: the document is the start document again and the redo is on top. */
function deleteThenUndo(start: Built, rootTag: string): string {
  deleteChapter(start, rootTag);
  const deleted = docText();
  pressUndo();
  expect(swiftAnswers('undo').ok).toBe(true);
  expect(docText(), 'PREMISE: the undo put the chapter back').toBe(start.text);
  handler('structuralUndoRequested').mockClear();
  traceLines.length = 0; // the trace line of the undo is not the one under test
  return deleted;
}

const occurrences = (text: string, part: string): number => text.split(part).length - 1;

describe('R11 the Markdown quick routes: Delete undo and redo with typing in the wait', () => {
  // Break patch MD-route-main.patch (the routing on the live document refuses the typed press).
  it('R11a W3-MD quick undo of a Delete, typing elsewhere with a Return in it: the chapter is back, the typing is in once', () => {
    const start = FIVE();
    loadRoute(start.text);
    deleteChapter(start, 'a3');
    const deleted = docText();
    pressUndo();
    const p = after('Text of chapter 1.');
    userTypes(p, ' keep');
    userTypes(p + ' keep'.length, '\n');
    userTypes(p + ' keep'.length + 1, 'more');
    const { press: pressNo, steps } = routePremise();

    const result = swiftAnswers('undo');

    expect(result.reason, 'the press was refused').toBeUndefined();
    expect(result.ok).toBe(true);
    expect(result.typingReplayed).toBe(true);
    expect(docText()).toBe(
      build([...ch(1, 'Text of chapter 1. keep\nmore'), ...ch(2), ...ch(3), ...ch(4), ...ch(5)]).text
    );
    expect(occurrences(docText(), 'keep')).toBe(1);
    expect(occurrences(docText(), 'more')).toBe(1);
    expect(result.preRaw, 'the typing is not a batch of its own').toBe(deleted);
    expect(result.postRaw, 'the baseline is the restored text before the replay').toBe(start.text);
    expectTrail(pressNo, steps, 'rebased');
    expect(handler('contentChanged'), 'the held push is discarded at the exit').not.toHaveBeenCalled();
  });

  // Break patch MD-route-Q2.patch: put the old refusal back in the redo-of-a-Delete branch (`if (typedSincePress) return refuse('changed', ...)`).
  // Predicted failure: `{"ok":false,"reason":"changed"}: expected false to be true`.
  it('R11b quick redo of a Delete, typing elsewhere with a Return in it: kept once, not replayed, the chapter goes again', () => {
    const start = FIVE();
    loadRoute(start.text);
    const deleted = deleteThenUndo(start, 'a3');
    press('redo');
    expect(handler('structuralRedoRequested')).toHaveBeenCalledTimes(1);
    const p = after('Text of chapter 1.');
    userTypes(p, ' keep');
    userTypes(p + ' keep'.length, '\n');
    userTypes(p + ' keep'.length + 1, 'more');
    const { press: pressNo, steps } = routePremise();

    const result = swiftAnswers('redo');

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(result.typingReplayed, 'Swift ends the rest of the redo branch').toBe(true);
    expect(docText()).toBe(build([...ch(1, 'Text of chapter 1. keep\nmore'), ...ch(2), ...ch(4), ...ch(5)]).text);
    expect(occurrences(docText(), 'keep'), 'kept once, not doubled').toBe(1);
    expect(occurrences(docText(), 'more')).toBe(1);
    expect(
      result.preRaw,
      'preRaw is the live text with the typing: Swift saves it as the batch up to the press'
    ).toContain('keep');
    expect(result.postRaw).toBe(docText());
    expect(deleted, 'PREMISE: the redo removed the same chapter the click did').not.toContain('Chapter 3');
    expectTrail(pressNo, steps, 'rebased');
  });

  // Break patch MD-route-Q3.patch: in `runDelete` skip the typing check (`if (false && typedRanges.length > 0 && ...)`).
  // Predicted failure: `{"ok":true,...}: expected 'reason' ...` (the redo removes the chapter together with the typing inside it).
  it('R11c quick redo of a Delete, typing INSIDE the chapter it removes: refused before anything changes, the typing stays, pushed once', () => {
    const start = FIVE();
    loadRoute(start.text);
    deleteThenUndo(start, 'a3');
    vi.useFakeTimers();
    press('redo');
    userTypes(after('Text of chapter 3.'), ' inside');
    const { press: pressNo, steps } = routePremise();
    const liveState = view.state;
    const entryBefore = getRegistry().get(OP);
    vi.advanceTimersByTime(200);
    expect(handler('contentChanged'), 'HELD while latched').not.toHaveBeenCalled();

    const result = swiftAnswers('redo');

    expect(result).toMatchObject({ ok: false, reason: 'unplaceable', detail: 'typingInRemovedSection' });
    expect(view.state === liveState, 'nothing on the screen changed').toBe(true);
    expect(getRegistry().get(OP), 'nothing was recorded: the entry is the one it was').toBe(entryBefore);
    expect(docText()).toContain('Text of chapter 3. inside');
    expectTrail(pressNo, steps, 'unplaceable');
    expect(pushedTexts(), 'the typing reaches Swift once').toEqual([docText()]);
    vi.advanceTimersByTime(200);
    expect(handler('contentChanged')).toHaveBeenCalledTimes(1);
  });

  // Break patch MD-route-Q5.patch: count a `derivedCorrection` change as typing in `isTypingTransaction`.
  // Predicted failure: `expected true to be false` (the undo goes ahead although an automatic rewrite met the typing).
  it('R11d a change that is NOT typing still refuses with the existing notice path: typing + an automatic rewrite, the typing stays', () => {
    const start = FIVE();
    loadRoute(start.text);
    deleteChapter(start, 'a3');
    pressUndo();
    userTypes(after('Text of chapter 1.'), ' keep');
    view.dispatch({ changes: { from: 0, insert: 'Q' }, annotations: derivedCorrection.of(true) });
    const { press: pressNo, steps } = routePremise();
    const liveState = view.state;

    const result = swiftAnswers('undo');

    expect(result.ok).toBe(false);
    expect(result.reason).toBe('changed');
    expect(view.state === liveState, 'nothing on the screen changed').toBe(true);
    expect(docText()).toContain('keep');
    expectTrail(pressNo, steps, 'changed');
  });

  // Break patches MD-route-cancelled.patch and MD-route-failed.patch (the same exits as R10, on a Delete's quick undo).
  it.each([
    'cancelled',
    'failed',
  ] as const)('R11e a Delete quick undo ends %s: the held typing is released exactly once', (outcome) => {
    const start = FIVE();
    loadRoute(start.text);
    deleteChapter(start, 'a3');
    vi.useFakeTimers();
    pressUndo();
    userTypes(after('Text of chapter 1.'), ' keep');
    routePremise();
    vi.advanceTimersByTime(200);
    expect(handler('contentChanged'), 'HELD while latched').not.toHaveBeenCalled();
    const typed = docText();

    ff().receiveUndoOutcome(OP, outcome);

    expect(pushedTexts()).toEqual([typed]);
    vi.advanceTimersByTime(200);
    expect(handler('contentChanged')).toHaveBeenCalledTimes(1);
    expect(getTypingCollector().recording).toBe(false);
  });

  // Break patch MD-route-main.patch (the routing on the live document refuses the typed press).
  it('R11f quick redo of a Duplicate (the composed redo) with typing in the wait: the copy comes back, the typing stays', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    loadRoute(start.text);
    duplicateChapter(start, 'a2');
    const duplicated = docText();
    ff().setUndoDescriptor({ undoTopOpId: OP });
    pressUndo();
    expect(swiftAnswers('undo').ok).toBe(true);
    handler('structuralUndoRequested').mockClear();
    press('redo');
    userTypes(after('Text of chapter 1.'), ' tail');
    routePremise();

    const result = swiftAnswers('redo');

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(duplicated.replace('Text of chapter 1.', 'Text of chapter 1. tail'));
  });

  // Break patch MD-route-main.patch (the routing on the live document refuses the typed press).
  it('R11g quick redo of a Version History restore (the composed redo) with typing in the wait', () => {
    const start = build([...ch(1), ...ch(2, 'The cat sat on the mat.'), ...ch(3)]);
    loadRoute(start.text);
    restoreRoute(start, 'section', 'a2', textOf(ch(2, 'The dog sat on the mat.')));
    const restored = docText();
    ff().setUndoDescriptor({ undoTopOpId: OP });
    pressUndo();
    expect(swiftAnswers('undo').ok).toBe(true);
    handler('structuralUndoRequested').mockClear();
    press('redo');
    userTypes(after('Text of chapter 3.'), ' tail');
    routePremise();

    const result = swiftAnswers('redo');

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(restored.replace('Text of chapter 3.', 'Text of chapter 3. tail'));
  });
});

// =============================================================================================================================
// ROUND 3: automatic changes in the wait are COMMUTED in front of the typing (Q1), the user commands are typing (Q3 v), a wrong base never swaps (Q3 iv)
// =============================================================================================================================

describe('W15 automatic changes made in the wait are commuted in front of the typing', () => {
  const DOC = 'Alpha beta gamma.\n\nTail text.[^1]\n\n[^1]: Note one.\n';
  const RENAMED = 'Alpha beta gamma.\n\nTail text.[^2]\n\n[^2]: Note one.\n';

  /** A bare editor state with a recording collector: `type` is a keystroke, `rename` the app's footnote renumber (two hunks, not typing). */
  function bare(doc = DOC) {
    let state = EditorState.create({ doc, extensions: [history()] });
    const recorder = new TypingCollector();
    recorder.startPress(1);
    const run = (spec: TransactionSpec): void => {
      const tr = state.update(spec);
      recorder.record(tr);
      state = tr.state;
    };
    return {
      recorder,
      doc: (): Text => state.doc,
      type: (pos: number, text: string): void =>
        run({
          changes: { from: pos, insert: text },
          selection: { anchor: pos + text.length },
          userEvent: 'input.type',
        }),
      rename: (): void => {
        const text = state.doc.toString();
        const first = text.indexOf('[^1]');
        const last = text.lastIndexOf('[^1]');
        run({
          changes: [
            { from: first, to: first + 4, insert: '[^2]' },
            { from: last, to: last + 4, insert: '[^2]' },
          ],
          annotations: Transaction.addToHistory.of(false),
        });
      },
      run,
    };
  }

  /** What every case checks: the base carries the automatic change and no typing, the rebased typing on top of it is the live document. */
  function expectCommuted(
    w: ReturnType<typeof bare>,
    base: string,
    live: string,
    typingSteps: number,
    automatic: number
  ): void {
    expect(w.doc().toString(), 'PREMISE: the live document').toBe(live);
    expect(w.recorder.stepsSince(1).length, 'PREMISE: changes were recorded').toBe(typingSteps + automatic);
    const pd = docAtPress(w.doc(), w.recorder, 1);
    expect(pd.decision).toBe('rebased');
    expect(pd.automatic).toBe(automatic);
    expect(pd.doc.toString()).toBe(base);
    expect(pd.steps).toHaveLength(typingSteps);
    let rebuilt = pd.doc;
    for (const step of pd.steps) rebuilt = step.changes.apply(rebuilt);
    expect(rebuilt.toString(), 'base + the rebased typing is the live document').toBe(live);
  }

  // Break patch MD-W15.patch: restore the old fall-back (an automatic change in the run: `changed`, the live document).
  // Predicted failure: expected 'changed' to be 'rebased'.
  it('W15a typing first, then the renumber lands (the dominant order): the base has the renumber and not the typing', () => {
    const w = bare();
    w.type(16, 'XY');
    w.rename();
    expectCommuted(w, RENAMED, 'Alpha beta gammaXY.\n\nTail text.[^2]\n\n[^2]: Note one.\n', 1, 1);
  });

  // Break patch MD-W15.patch (the same as above).
  it('W15a2 the renumber first, then the typing', () => {
    const w = bare();
    w.rename();
    w.type(16, 'XY');
    expectCommuted(w, RENAMED, 'Alpha beta gammaXY.\n\nTail text.[^2]\n\n[^2]: Note one.\n', 1, 1);
  });

  // Break patch MD-W15.patch (the same as above).
  it('W15a3 typing, the renumber, typing again (after the reference): both typing steps keep their place', () => {
    const w = bare();
    w.type(16, 'X');
    w.rename();
    w.type(w.doc().toString().indexOf('[^2]') + 4, 'Z');
    expectCommuted(w, RENAMED, 'Alpha beta gammaX.\n\nTail text.[^2]Z\n\n[^2]: Note one.\n', 2, 1);
  });

  // Break patch MD-W15a4.patch: in `docAtPress` do not retry the commute with the typing placed first (`?? commuteAutomatic(..., true)`).
  // Predicted failure: expected 'changed' to be 'rebased' (the typing and the insertion at the same place come out in the wrong order).
  it('W15a4 typing exactly in front of an automatic insertion at the same place keeps its order', () => {
    const w = bare();
    w.type(0, 'T');
    w.run({ changes: { from: 1, insert: '#' }, annotations: Transaction.addToHistory.of(false) });
    expectCommuted(w, `#${DOC}`, `T#${DOC}`, 1, 1);
  });

  // Break patch MD-W15b.patch: in `commuteAutomatic` skip the final check (`if (false && !check.eq(liveDoc)) return null`).
  // Predicted failure: expected 'rebased' to be 'changed' (the base is built although the typing lies inside text the rebuild replaced).
  it('W15b typing INSIDE text a later automatic change replaced: changed, the live document comes back', () => {
    const w = bare();
    const at = w.doc().toString().indexOf('one');
    w.type(at, 'Q');
    const line = w.doc().toString().indexOf('[^1]: Note');
    w.run({
      changes: { from: line, to: line + '[^1]: Note Qone.'.length, insert: '[^1]: Rebuilt.' },
      annotations: Transaction.addToHistory.of(false),
    });
    const live = w.doc();
    expect(w.recorder.stepsSince(1).length, 'PREMISE: changes were recorded').toBe(2);

    const pd = docAtPress(live, w.recorder, 1);

    expect(pd.decision).toBe('changed');
    expect(pd.doc === live, 'the live document, so the routing refuses').toBe(true);
  });
});

describe("R12 the dominant order through the route: typing, then the settle's rewrites, then the click", () => {
  const NOTES: Block[] = [
    { kind: 'leader', id: 'hn', level: 2, title: 'Notes', managed: 'notes' },
    { kind: 'text', text: '[^1]: Note one.' },
    { kind: 'text', text: '[^2]: Note two.' },
    { kind: 'text', text: '[^3]: Note three.' },
    { kind: 'text', text: '[^4]: Note four.' },
  ];
  const noted = (): Built =>
    build([...ch(1, 'One.[^1]'), ...ch(2, 'Two.[^2]'), ...ch(3, 'Three.[^3]'), ...ch(4, 'Four.[^4]'), ...NOTES]);

  /** The settle of the Delete: the references after the removed one are numbered again (not a text-history step). */
  function settleRenumber(mapping: Record<string, string>): void {
    ff().setStructuralSettleOpId(OP);
    ff().renumberFootnotes(mapping);
    ff().setStructuralSettleOpId(null);
  }

  // Break patch MD-route-W15.patch: the old fall-back in `docAtPress` (any automatic change: `changed`, the live document).
  // Predicted failure: `expected false to be true` / the trace line says `decision=changed` (the press is refused).
  it('R12a typing, then the settle renumbers the footnotes, then the Cmd-Z is carried out: rebased, the exact document, the typing once', () => {
    const start = noted();
    loadRoute(start.text);
    deleteChapter(start, 'a3');
    expect(docText(), 'PREMISE: the delete took its footnote with it').not.toContain('[^3]: Note three.');
    pressUndo();
    userTypes(after('One.[^1]'), ' kept');
    settleRenumber({ '4': '3' });
    expect(docText(), 'PREMISE: the settle renumbered').toContain('Four.[^3]');
    const { press: pressNo, steps } = routePremise();

    const result = swiftAnswers('undo');

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(result.typingReplayed).toBe(true);
    expect(docText()).toBe(start.text.replace('One.[^1]', 'One.[^1] kept'));
    expect(occurrences(docText(), 'kept')).toBe(1);
    expectTrail(pressNo, steps, 'rebased');
  });

  // Break patch MD-route-W15b.patch: the same as MD-W15b (skip the check at the end of `commuteAutomatic`).
  // Predicted failure: `expected true to be false` (the press goes ahead and the typing inside the rebuilt text is dropped).
  it('R12b typing inside the Notes region, then a rebuild replaces that text: changed, the live document untouched, the notice path', () => {
    const start = noted();
    loadRoute(start.text);
    deleteChapter(start, 'a3');
    vi.useFakeTimers();
    pressUndo();
    userTypes(after('[^2]: Note two'), ' mine');
    const line = docText().indexOf('[^2]: Note two mine.');
    view.dispatch({
      changes: { from: line, to: line + '[^2]: Note two mine.'.length, insert: '[^2]: Note two rebuilt.' },
      annotations: Transaction.addToHistory.of(false),
    });
    const { press: pressNo, steps } = routePremise();
    const liveState = view.state;
    vi.advanceTimersByTime(200);
    expect(handler('contentChanged'), 'HELD while latched').not.toHaveBeenCalled();

    const result = swiftAnswers('undo');

    expect(result.ok).toBe(false);
    expect(result.reason).toBe('changed');
    expect(view.state === liveState, 'nothing on the screen changed').toBe(true);
    expectTrail(pressNo, steps, 'changed');
    expect(pushedTexts(), 'the live text reaches Swift once').toEqual([docText()]);
  });
});

describe('R13 Q3(v): Bold, a slash insert and a table insert are typing', () => {
  /** The three commands, on the document as it stands (also used to build the expectation on the restored document). */
  function runCommands(): void {
    const bold = docText().indexOf('Text of chapter 1.') + 'Text of '.length;
    view.dispatch({ selection: { anchor: bold, head: bold + 'chapter'.length } });
    toggleBold();
    userTypes(after('Text of chapter 2.'), '\n\n/break');
    const slash = docText().indexOf('/break');
    const command = slashCommands.find((c) => c.label === '/break');
    if (!command) throw new Error('no /break command');
    command.apply(view, slash, slash + '/break'.length);
    view.dispatch({ selection: { anchor: after('chapter** 1.') } }); // the end of the bolded line
    insertTableCommand(2, 2);
  }

  // Break patch MD-route-W7b.patch: take the mark off in the shared helper (`dispatchAsTyping`: `annotations: marks`).
  // Predicted failure: `expected false to be true` (the commands are not typing) and the press is refused as `changed`.
  it('R13a during the wait: the document is the one the same commands make on the restored document, decision rebased', () => {
    const start = FIVE();
    loadRoute(start.text);
    runCommands();
    const expected = docText();
    expect(expected, 'PREMISE: the commands changed the text').not.toBe(start.text);

    loadRoute(start.text);
    deleteChapter(start, 'a3');
    pressUndo();
    runCommands();
    const { press: pressNo, steps } = routePremise();
    expect(
      getTypingCollector()
        .stepsSince(pressNo)
        .every((step) => step.typing),
      'every command is recorded as typing'
    ).toBe(true);

    const result = swiftAnswers('undo');

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(expected);
    expectTrail(pressNo, steps, 'rebased');
  });
});

describe('R14 Q3(iv): several held presses with typing between them: a wrong base never swaps', () => {
  const OP2 = '99999999-2222-3333-4444-555555555555';
  const OP3 = '88888888-2222-3333-4444-555555555555';

  /** Three drags: OP (4 before 2), OP2 (5 before 3), OP3 (3 before 4). The undo stack has OP3 on top. */
  function threeDrags(): { start: Built; afterFirst: Built } {
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2');
    const afterFirst = build([...ch(1), ...ch(4), ...ch(2), ...ch(3), ...ch(5)]);
    dragChapter(afterFirst, 'a5', 'a3', {}, OP2);
    const afterSecond = build([...ch(1), ...ch(4), ...ch(2), ...ch(5), ...ch(3)]);
    dragChapter(afterSecond, 'a3', 'a4', {}, OP3);
    ff().setUndoDescriptor({ undoTopOpId: OP3 });
    return { start, afterFirst };
  }
  const swapThenReply = (
    opId: string,
    top: { undoTopOpId?: string; redoTopOpId?: string }
  ): ReturnType<FF['markdownStructuralSwap']> => {
    const result = ff().markdownStructuralSwap(opId, 'undo');
    expect(result.ok, JSON.stringify(result)).toBe(true);
    ff().setUndoDescriptor(top);
    ff().receiveUndoOutcome(opId, 'performed');
    return result;
  };

  // Break patch MD-route-R7c.patch (the drain routes on the live document): predicted failure `expected "spy" to be called with ... { opId, held: true }`.
  it('R14a typing only after the LAST press: all three presses are structural, each puts the typing back, it ends up once', () => {
    threeDrags();
    pressUndo(); // P1: OP3
    press('undo'); // P2: OP2, held
    press('undo'); // P3: OP, held
    expect(ff().heldUndoPressCount()).toBe(2);
    userTypes(after('Text of chapter 5.'), ' t3'); // after P3 was pressed
    routePremise();

    swapThenReply(OP3, { undoTopOpId: OP2, redoTopOpId: OP3 });
    expect(handler('structuralUndoRequested')).toHaveBeenLastCalledWith({ opId: OP2, held: true });
    swapThenReply(OP2, { undoTopOpId: OP, redoTopOpId: OP2 });
    expect(handler('structuralUndoRequested')).toHaveBeenLastCalledWith({ opId: OP, held: true });
    swapThenReply(OP, { redoTopOpId: OP });

    expect(handler('structuralUndoRequested')).toHaveBeenCalledTimes(3);
    expect(docText()).toBe(build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...ch(5, 'Text of chapter 5. t3')]).text);
    expect(occurrences(docText(), 't3')).toBe(1);
    expect(ff().heldUndoPressCount()).toBe(0);
  });

  // Break patch MD-route-F1.patch (the text-undo check is removed; the held press then takes the newest typing back).
  // Predicted failure: `both typings stay: nothing was removed: expected '<!-- @sid:...' to be '<!-- @sid:...'`. (MD-route-R14c, the comparison always passing, fails the
  // `P3 must not be sent` line: `expected "spy" to be called 2 times, but got 3 times`.)
  it('R14b typing before AND after the held press: the press whose base has typing the saved copy lacks does not swap, is ended with the notice, and both typings stay', () => {
    threeDrags();
    pressUndo(); // P1: OP3
    press('undo'); // P2: OP2, held
    userTypes(after('Text of chapter 2.'), ' t2'); // after P2, before P3
    press('undo'); // P3: OP, held
    userTypes(after('Text of chapter 5.'), ' t3'); // after P3
    routePremise();

    swapThenReply(OP3, { undoTopOpId: OP2, redoTopOpId: OP3 }); // replays t2 and t3
    expect(handler('structuralUndoRequested')).toHaveBeenLastCalledWith({ opId: OP2, held: true }); // P2's base has no typing
    swapThenReply(OP2, { undoTopOpId: OP, redoTopOpId: OP2 }); // replays t2 and t3 again

    // P3's base is the document at ITS press: it still has t2, which the saved copy of OP lacks. The comparison fails, the press is not
    // routed structural. A plain text undo run now would take back the NEWEST typing (t3, typed after P3) and keep t2, the typing P3 was
    // meant to take back: the press is ended with the existing notice instead (F1).
    expect(handler('structuralUndoRequested'), 'P3 must not be sent').toHaveBeenCalledTimes(2);
    expect(docText(), 'both typings stay: nothing was removed').toBe(
      build([...ch(1), ...ch(4), ...ch(2, 'Text of chapter 2. t2'), ...ch(3), ...ch(5, 'Text of chapter 5. t3')]).text
    );
    expect(handler('undoQueueDropped'), 'the existing notice, once').toHaveBeenCalledTimes(1);
    expect(handler('undoQueueDropped')).toHaveBeenCalledWith({ count: 1 });
    expect(handler('undoHeldPressSettled')).toHaveBeenCalledWith({ count: 1 });
    expect(ff().heldUndoPressCount()).toBe(0);
  });

  // Break patch MD-route-R14c.patch: `docsEqual` answers true (the routing no longer compares the base with the saved copy).
  // Predicted failure: `expected true to be false` (the press swaps on a wrong base).
  it('R14c a record that does not fit the live document gives a base that fails the comparison: changed, nothing swaps, the typing stays', () => {
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2');
    ff().setUndoDescriptor({ undoTopOpId: OP });
    pressUndo();
    userTypes(after('Text of chapter 5.'), ' kept');
    // A stale record: written for a document that is not the live one (same length, other text), so its inverse puts the wrong text back.
    const liveText = docText();
    const other = EditorState.create({ doc: `${liveText.slice(0, 3)}Q${liveText.slice(4)}` });
    getTypingCollector().record(other.update({ changes: { from: 3, to: 4, insert: 'Z' }, userEvent: 'input.type' }));
    routePremise();
    const liveState = view.state;

    const result = swiftAnswers('undo');

    expect(result.ok).toBe(false);
    expect(result.reason).toBe('changed');
    expect(view.state === liveState, 'nothing swapped, the typing is where it was').toBe(true);
    expect(docText()).toContain('Text of chapter 5. kept');
  });
});

// =============================================================================================================================
// ROUND 5: review must-fixes F1 (no wrong text undo), F2 (a held quick redo runs), F5 (keys typed before the reply), F12 (find and replace),
// F21 (one trace line per press), and the tie order of the commute in both directions
// =============================================================================================================================

describe('W15c the commute order at a tie, both ways', () => {
  const DOC = 'Alpha beta gamma.\n\nTail text.[^1]\n\n[^1]: Note one.\n';

  function bareTie() {
    let state = EditorState.create({ doc: DOC, extensions: [history()] });
    const recorder = new TypingCollector();
    recorder.startPress(1);
    const run = (spec: TransactionSpec): void => {
      const tr = state.update(spec);
      recorder.record(tr);
      state = tr.state;
    };
    return { recorder, run, doc: (): Text => state.doc };
  }

  // Break patch MD-W15a5.patch: try only the typing-after order (`commuteAutomatic(liveDoc, steps, false)` only is MD-W15a4; this one tries only
  // `true`, the typing placed first). Predicted failure: expected 'changed' to be 'rebased'.
  it('W15a5 an automatic insertion exactly in front of typing at the same place: the typing stays after it', () => {
    const w = bareTie();
    w.run({
      changes: { from: 5, insert: 'T' },
      selection: { anchor: 6 },
      userEvent: 'input.type',
    }); // 'AlphaT beta gamma.'
    w.run({ changes: { from: 5, insert: '#' }, annotations: Transaction.addToHistory.of(false) }); // '#' lands in front of the T: 'Alpha#T beta'
    expect(w.doc().toString().slice(0, 8), 'PREMISE: the live text').toBe('Alpha#T ');
    expect(w.recorder.stepsSince(1)).toHaveLength(2);

    const pd = docAtPress(w.doc(), w.recorder, 1);

    expect(pd.decision).toBe('rebased');
    expect(pd.doc.toString().slice(0, 7), 'the base has the automatic insertion and not the typing').toBe('Alpha# ');
    let rebuilt = pd.doc;
    for (const step of pd.steps) rebuilt = step.changes.apply(rebuilt);
    expect(rebuilt.toString(), 'base + the typing is the live document').toBe(w.doc().toString());
  });
});

describe('R15 F1: a fallback reply that would run a plain text undo on top of newer typing', () => {
  // Break patch MD-route-F1fallback.patch: in `handleUndoReplyFromSwift` ignore the typing after the press (`typedAfterFallback` always false).
  // Predicted failure: `the text undo did not run: expected '<!-- @sid:...' to be '<!-- @sid:...'` (the fallback's text undo took the newest typing back).
  it('R15b a fallback reply with typing after the press: no text undo, the notice once, the typing stays', () => {
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2');
    ff().setUndoDescriptor({ undoTopOpId: OP });
    pressUndo();
    userTypes(after('Text of chapter 5.'), ' kept');
    routePremise();
    const typed = docText();

    ff().receiveUndoOutcome(OP, 'fallback');

    expect(docText(), 'the text undo did not run').toBe(typed);
    expect(handler('undoQueueDropped')).toHaveBeenCalledTimes(1);
    expect(handler('undoQueueDropped')).toHaveBeenCalledWith({ count: 1 });
    expect(getTypingCollector().recording, 'the window is over').toBe(false);
  });
});

describe('R16 F2: a held QUICK redo (a Delete re-run) runs when the typing is elsewhere', () => {
  const OP2 = '99999999-2222-3333-4444-555555555555';

  // Break patch MD-route-F2.patch: in `drainQueuedPresses` end every held redo that was typed after (`true &&` for the entry test).
  // Predicted failure: `the held quick redo is sent: expected last "spy" call to have been called with [ { …(2) } ]` (the held redo was ended with the notice).
  it('R16a Delete, Delete, Cmd-Z twice, Cmd-Shift-Z twice with typing elsewhere after the second: both run, the typing once, no notice', () => {
    const start = FIVE();
    loadRoute(start.text);
    deleteChapter(start, 'a3'); // OP
    deleteChapter(build([...ch(1), ...ch(2), ...ch(4), ...ch(5)]), 'a4', OP2);
    ff().setUndoDescriptor({ undoTopOpId: OP2 });
    pressUndo();
    expect(ff().markdownStructuralSwap(OP2, 'undo').ok).toBe(true);
    ff().setUndoDescriptor({ undoTopOpId: OP, redoTopOpId: OP2 });
    ff().receiveUndoOutcome(OP2, 'performed');
    pressUndo();
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    ff().setUndoDescriptor({ redoTopOpId: OP });
    ff().receiveUndoOutcome(OP, 'performed');
    expect(docText(), 'PREMISE: both deletes are undone').toBe(start.text);
    handler('structuralRedoRequested').mockClear();
    traceLines.length = 0;

    press('redo'); // P1: the redo of OP
    expect(handler('structuralRedoRequested')).toHaveBeenLastCalledWith({ opId: OP });
    press('redo'); // P2: held; the redo of OP2
    expect(ff().heldUndoPressCount()).toBe(1);
    userTypes(after('Text of chapter 1.'), ' keep'); // after P2, in a chapter neither delete touches
    routePremise();

    const first = ff().markdownStructuralSwap(OP, 'redo');
    expect(first.ok, JSON.stringify(first)).toBe(true);
    ff().setUndoDescriptor({ undoTopOpId: OP, redoTopOpId: OP2 });
    ff().receiveRedoOutcome(OP, 'performed'); // the drain routes the held redo

    expect(handler('structuralRedoRequested'), 'the held quick redo is sent').toHaveBeenLastCalledWith({
      opId: OP2,
      held: true,
    });
    const second = ff().markdownStructuralSwap(OP2, 'redo');
    expect(second.ok, JSON.stringify(second)).toBe(true);
    ff().setUndoDescriptor({ undoTopOpId: OP2 });
    ff().receiveRedoOutcome(OP2, 'performed');

    expect(docText()).toBe(build([...ch(1, 'Text of chapter 1. keep'), ...ch(2), ...ch(5)]).text);
    expect(occurrences(docText(), 'keep'), 'the typing once').toBe(1);
    expect(handler('undoQueueDropped'), 'no notice').not.toHaveBeenCalled();
    expect(ff().heldUndoPressCount()).toBe(0);
  });
});

describe("R17 F5: keys typed after the swap and before Swift's reply reach Swift once, without another keystroke", () => {
  // Break patch MD-route-F5.patch: discard every owed push at the exit of a performed press (`discardOwedTypingPush()` before `inFlightPress = 0`).
  // Predicted failure: `one push, the live text with the keys typed after the swap: expected [] to deeply equal [ Array(1) ]` (the keys typed after the swap never reach Swift).
  it('the push owed from the wait is dropped at the swap, the push owed after it is sent when the press ends', () => {
    const start = FIVE();
    loadRoute(start.text);
    dragChapter(start, 'a4', 'a2');
    ff().setUndoDescriptor({ undoTopOpId: OP });
    vi.useFakeTimers();
    pressUndo();
    userTypes(after('Text of chapter 5.'), 'hold');
    routePremise();
    vi.advanceTimersByTime(200); // the wait's push is owed
    expect(handler('contentChanged'), 'HELD while latched').not.toHaveBeenCalled();

    const result = ff().markdownStructuralSwap(OP, 'undo'); // the replay carries 'hold': the owed push is dropped
    expect(result.ok, JSON.stringify(result)).toBe(true);
    userTypes(after('Text of chapter 5.hold'), 'after'); // typed after the swap, before Swift's reply
    vi.advanceTimersByTime(200); // its push is owed now
    expect(handler('contentChanged'), 'still held').not.toHaveBeenCalled();
    ff().setUndoDescriptor({ redoTopOpId: OP });
    ff().receiveUndoOutcome(OP, 'performed');

    expect(pushedTexts(), 'one push, the live text with the keys typed after the swap').toEqual([docText()]);
    expect(docText()).toContain('Text of chapter 5.holdafter');
    vi.advanceTimersByTime(200);
    expect(handler('contentChanged'), 'and not again').toHaveBeenCalledTimes(1);
  });
});

describe('R18 F12: a find and replace during the wait is typing', () => {
  // Break patch: none needed beyond MD-route-main (the routing on the live document refuses any typed press). If the replace were not
  // recognised as typing the press would be refused: the decision below would be `changed`.
  it('decision rebased, the exact document', () => {
    const start = FIVE();
    loadRoute(start.text);
    deleteChapter(start, 'a3');
    pressUndo();
    ff().find('Text of chapter 4');
    expect(ff().replaceAll('Fourth chapter')).toBe(1);
    const { press: pressNo, steps } = routePremise();
    expect(
      getTypingCollector()
        .stepsSince(pressNo)
        .every((step) => step.typing),
      'the replace is recorded as typing (its own input.replace.all event)'
    ).toBe(true);

    const result = swiftAnswers('undo');

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(start.text.replace('Text of chapter 4', 'Fourth chapter'));
    expectTrail(pressNo, steps, 'rebased');
  });
});

describe('R19 F21: one trace line per press, at the final decision', () => {
  // Break patch MD-route-F21.patch: write the line for a retriable refusal too (`!(retriedMismatch ...)` -> `false`).
  // Predicted failure: `the retriable refusal writes no line: expected [ Array(1) ] to deeply equal []`.
  it('a leadersMismatch on the redo of a Delete that Swift retries writes no line; the retry writes the one line', () => {
    const start = FIVE();
    loadRoute(start.text);
    deleteChapter(start, 'a3');
    pressUndo();
    expect(swiftAnswers('undo').ok).toBe(true);
    handler('structuralUndoRequested').mockClear();
    traceLines.length = 0;
    press('redo');
    userTypes(after('Text of chapter 1.'), ' keep');
    const { press: pressNo, steps } = routePremise();
    const stale = {
      kind: 'delete',
      opId: OP,
      rootId: uid('a3'),
      // a heading Swift thinks differently of: the page cannot match the leaders
      leaders: start.leaders.map((leader, i) => (i === 2 ? { ...leader, line: '# Chapter 3 renamed' } : leader)),
      stopLine: null,
      endLeaderId: uid('a4'),
    };

    const first = ff().markdownStructuralSwap(OP, 'redo', JSON.stringify(stale));
    expect(first).toMatchObject({ ok: false, reason: 'leadersMismatch' });
    expect(trailLines(), 'the retriable refusal writes no line').toEqual([]);
    const retry = ff().markdownStructuralSwap(OP, 'redo'); // the stored request: Swift flushed and asks again
    expect(retry.ok, JSON.stringify(retry)).toBe(true);
    ff().setUndoDescriptor({ undoTopOpId: OP });
    ff().receiveRedoOutcome(OP, 'performed');

    expectTrail(pressNo, steps, 'rebased');
    expect(docText()).toBe(build([...ch(1, 'Text of chapter 1. keep'), ...ch(2), ...ch(4), ...ch(5)]).text);
  });
});

// =============================================================================================================================
// ROUND 7: typing in a region the saved-copy comparison ignores (a bibliography entry) must not be lost by the swap
// =============================================================================================================================

describe('R20 typing inside a bibliography entry (a region the saved-copy comparison ignores)', () => {
  /** Four chapters and a managed bibliography region after them, the way Swift assembles it: the opening marker glued in front of the
   * bibliography heading's anchor, the entries as paragraphs, the end marker as the last block. `derived-equivalence.ts` cuts the whole region. */
  function withBibliography(): Built {
    const built = build([
      ...ch(1),
      ...ch(2),
      ...ch(3),
      ...ch(4),
      { kind: 'leader', id: 'bib', level: 1, title: 'Bibliography', managed: 'bibliography' },
      { kind: 'text', text: 'Reference one.' },
      { kind: 'text', text: 'Reference two.' },
      { kind: 'text', text: '<!-- ::auto-bibliography-end:: -->' },
    ]);
    const heading = `<!-- @sid:${sid('bib')} -->`;
    expect(built.text.split(heading).length - 1, 'PREMISE: the bibliography heading is in the text once').toBe(1);
    return { ...built, text: built.text.replace(heading, `<!-- ::auto-bibliography:: -->${heading}`) };
  }

  // Break patch MD-R7-R2b-v2-managed-region.patch: in `isTypingTransaction` (typing-rebase.ts) a change inside the bibliography region is not
  // typing. The press then looks like one with no typing at all, the swap goes ahead and puts the saved copy in, and the entry is gone.
  // Predicted failure: `the typing is still in the editor: expected '<!-- @sid:...' to contain 'Reference one. LATE'`.
  it('R2b-v2-MD: typing inside a bibliography entry during the wait, then the swap: the typed text is in the editor and reaches the writer exactly once; never a swap that drops it', () => {
    const start = withBibliography();
    loadRoute(start.text);
    deleteChapter(start, 'a4'); // the last chapter: its section ends at the bibliography
    expect(docText(), 'PREMISE: the delete took chapter 4 out').not.toContain('Chapter 4');
    vi.useFakeTimers();
    pressUndo();
    userTypes(after('Reference one.'), ' LATE');
    expect(docText(), 'PREMISE: the entry holds the typing').toContain('Reference one. LATE');
    const { press: pressNo } = routePremise(); // at least one change since the press
    vi.advanceTimersByTime(200);
    expect(handler('contentChanged'), 'PREMISE: the push is HELD while the press is latched').not.toHaveBeenCalled();

    const result = swiftAnswers('undo');

    const lines = trailLines();
    expect(lines, 'PREMISE: the route wrote its one trace line, with the change counted').toHaveLength(1);
    expect(lines[0]).toMatch(
      new RegExp(`^\\[STRUCT-TRACE\\] typing-since-press press=${pressNo} steps=[1-9]\\d* decision=\\w+$`)
    );
    // Whichever way the press ended, the user's words are in the editor, once.
    expect(docText(), 'the typing is still in the editor').toContain('Reference one. LATE');
    expect(occurrences(docText(), 'LATE'), 'once').toBe(1);
    if (result.ok) {
      // The swap went ahead: the chapter is back, the typing rode the replay.
      expect(lines[0]).toMatch(/decision=rebased$/);
      expect((result as { typingReplayed?: boolean }).typingReplayed).toBe(true);
      expect(docText()).toBe(start.text.replace('Reference one.', 'Reference one. LATE'));
    } else {
      // The press was refused with the notice: the delete stands, the typing is live.
      expect(lines[0]).toMatch(/decision=changed$/);
      expect(docText()).not.toContain('Chapter 4');
    }
    // The writer has the typed text exactly once: one push, the text now on the screen (the replay is an ordinary change of the page; a
    // refusal sends the held push), and not again.
    vi.advanceTimersByTime(200);
    expect(pushedTexts(), 'one push, the live text').toEqual([docText()]);
    vi.advanceTimersByTime(400);
    expect(handler('contentChanged'), 'and not again').toHaveBeenCalledTimes(1);
  });
});

// =============================================================================================================================
// ROUND 6 (K-1, N2): a pure deletion is not a refusal of the quick redo of a Delete
// =============================================================================================================================

describe('R21 N2: a pure deletion inside the chapter a waiting quick redo removes does not refuse it', () => {
  // Break patch MD-R8-N2-pure-deletion-refuses.patch: in `typedRangesInLive` (api-structural-markdown.ts) count collapsed ranges again (drop the
  // `toB > fromB` filter). Predicted failure: `the redo is performed, not refused: {"ok":false,"reason":"unplaceable","detail":"typingInRemovedSection"}:
  // expected false to be true`.
  it('Backspace inside Chapter 3 while Cmd-Shift-Z waits: the redo is performed, the chapter is gone, no notice', () => {
    const start = FIVE();
    loadRoute(start.text);
    deleteThenUndo(start, 'a3');
    press('redo'); // the redo of the Delete: sent to Swift, the press waits
    expect(handler('structuralRedoRequested')).toHaveBeenCalledTimes(1);
    const end = after('Text of chapter 3.');
    view.dispatch({
      changes: { from: end - 1, to: end },
      selection: { anchor: end - 1 },
      userEvent: 'delete.backward',
    }); // Backspace over the full stop
    expect(docText(), 'PREMISE: the Backspace took a character out of the chapter the redo removes').toContain(
      'Text of chapter 3\n\n'
    );
    expect(docText(), 'PREMISE: and put nothing in').not.toContain('Text of chapter 3.');
    const { press: pressNo, steps } = routePremise();

    const result = swiftAnswers('redo');

    expect(result.ok, `the redo is performed, not refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), 'the chapter is gone').toBe(build([...ch(1), ...ch(2), ...ch(4), ...ch(5)]).text);
    expect(handler('undoQueueDropped'), 'no notice').not.toHaveBeenCalled();
    expect(handler('structuralUndoRefused'), 'no refusal').not.toHaveBeenCalled();
    expectTrail(pressNo, steps, 'rebased');
  });

  // The other half of the rule: text typed (or typed over a selection) INSIDE the chapter still refuses, so it is never taken out with it.
  // Not broken by the patch above (it keeps a range that inserted text); it fails if the filter is made too wide (e.g. any replaced range).
  it('a selection inside Chapter 3 typed over while Cmd-Shift-Z waits: still refused before anything changes, the typing stays', () => {
    const start = FIVE();
    loadRoute(start.text);
    deleteThenUndo(start, 'a3');
    press('redo');
    const from = docText().indexOf('of chapter 3.');
    view.dispatch({
      changes: { from, to: from + 'of chapter'.length, insert: 'X' },
      selection: { anchor: from + 1 },
      userEvent: 'input.type',
    });
    const { press: pressNo, steps } = routePremise();
    const liveState = view.state;

    const result = swiftAnswers('redo');

    expect(result).toMatchObject({ ok: false, reason: 'unplaceable', detail: 'typingInRemovedSection' });
    expect(view.state === liveState, 'nothing on the screen changed').toBe(true);
    expect(docText()).toContain('Text X 3.');
    expectTrail(pressNo, steps, 'unplaceable');
  });
});
