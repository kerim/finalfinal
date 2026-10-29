// @vitest-environment jsdom
//
// t-4a8fd8af, Phase 4b, Markdown slice 2, round 2a: the PAGE half of the editor-first section REORDER in Markdown mode (the sidebar
// drag): web/codemirror/src/api-structural-markdown-reorder.ts, `markdownStructuralReorder` (the click). Undo, redo and the redo carry
// are round 2b (W-R7, W-R8, W-R9, W-R12, W-R13, W-R16: the last describe blocks of this file).
//
// These tests drive the REAL page, like structural-markdown.test.ts: they import the real main.ts (the real extension set, the real
// update listeners, the real window.FinalFinal) into jsdom. Swift's side of the bridge is played by the helpers below.
//
// Each test names the break patch (1-5 changed lines in the new code) that must make it fail, and the failure it then shows. The
// patches are files, one per test or case, listed in the run notes (scratchpad/breaks-2a/index.md). A test labelled PIN passes with and
// without a deliberate break: it pins a behaviour that nothing else watches.

import { redoDepth, undoDepth } from '@codemirror/commands';
import { EditorView } from '@codemirror/view';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MarkdownLeader } from '../api-structural-markdown';
import type { MarkdownReorderRequest, MarkdownReorderResult } from '../api-structural-markdown-reorder';
import { setAsideRedoOf } from '../redo-branch';
import { decideLiveRouting, getRegistry, getUndoDescriptor } from '../undo-coordinator';

type FF = {
  setContent: (md: string, options?: unknown) => void;
  setUndoDescriptor: (d: { undoTopOpId?: string; redoTopOpId?: string }) => void;
  resetForProjectSwitch: () => void;
  clearStructuralUndoRegistry: () => void;
  markdownStructuralReorder: (request: string | object) => MarkdownReorderResult;
  markdownStructuralSwap: (opId: string, direction: 'undo' | 'redo') => { ok: boolean; reason?: string };
};
const ff = (): FF => (window as any).FinalFinal as FF;

const OP = '11111111-2222-3333-4444-555555555555';
const EARLIER_OP = '77777777-2222-3333-4444-555555555555';

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

/** Types `text` right after the first occurrence of `marker` in the document. */
function typeAfter(marker: string, text: string): void {
  const at = docText().indexOf(marker);
  if (at < 0) throw new Error(`marker not in document: ${marker}`);
  typeAt(at + marker.length, text);
}

/** Puts the caret right after the first occurrence of `marker`. */
function caretAfter(marker: string): void {
  const at = docText().indexOf(marker);
  if (at < 0) throw new Error(`marker not in document: ${marker}`);
  view.dispatch({ selection: { anchor: at + marker.length } });
}

// --- Documents in the shape the Markdown editor shows (blocks separated by a blank line, an anchor in front of every heading) ---

type Block =
  | {
      kind: 'leader';
      id: string;
      level: number;
      title: string;
      anchored?: boolean;
      managed?: 'notes' | 'bibliography';
      glueMarker?: boolean;
      /** The whole heading line, when it is not `#`x level + " " + title (a tab or a U+3000 after the `#` run). */
      rawLine?: string;
    }
  | { kind: 'break'; id: string; anchored?: boolean }
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

/** `trailing` is what the document ends with: the blocks are joined by a blank line and end with one newline by default. */
function build(blocks: Block[], trailing = '\n'): Built {
  const parts: string[] = [];
  const leaders: MarkdownLeader[] = [];
  for (const b of blocks) {
    if (b.kind === 'text') {
      parts.push(b.text);
    } else if (b.kind === 'break') {
      const anchor = b.anchored === false ? '' : `<!-- @sid:${sid(b.id)} -->`;
      parts.push(`${anchor}<!-- ::break:: -->`);
      leaders.push({ id: b.id, line: '<!-- ::break:: -->', level: 1 });
    } else {
      const line = b.rawLine ?? `${'#'.repeat(b.level)} ${b.title}`;
      const anchor = b.anchored === false ? '' : `<!-- @sid:${sid(b.id)} -->`;
      const glue = b.glueMarker ? '<!-- ::auto-bibliography:: -->' : '';
      parts.push(`${glue}${anchor}${line}`);
      leaders.push({ id: b.id, line, level: b.level, ...(b.managed ? { managed: b.managed } : {}) });
    }
  }
  return { text: `${parts.join('\n\n')}${trailing}`, leaders, blocks };
}

const ch = (
  n: number,
  body = `Text of chapter ${n}.`,
  extra: Partial<Extract<Block, { kind: 'leader' }>> = {}
): Block[] => [
  { kind: 'leader', id: `h${n}`, level: 1, title: `Chapter ${n}`, ...extra },
  { kind: 'text', text: body },
];

/** A sub-section: `sub('h2a', 'Part 2.1')` is a level-2 heading and its one line of text. */
const sub = (id: string, title: string, level = 2): Block[] => [
  { kind: 'leader', id, level, title },
  { kind: 'text', text: `Text of ${title.toLowerCase()}.` },
];

/** The Notes and Bibliography rows, as the Markdown editor shows them (the opening marker glued to the Bibliography heading line). */
const region = (notesId = 'hn', bibId = 'hb'): Block[] => [
  { kind: 'leader', id: notesId, level: 1, title: 'Notes', managed: 'notes' },
  { kind: 'text', text: '[^1]: A note.' },
  { kind: 'leader', id: bibId, level: 1, title: 'Bibliography', managed: 'bibliography', glueMarker: true },
  { kind: 'text', text: 'Smith, J. (2020). A book.' },
  { kind: 'text', text: '<!-- ::auto-bibliography-end:: -->' },
];

function load(text: string): void {
  // A fresh document with fresh text history, exactly as opening a project does, then the starting text; empty structural-undo state.
  resetUndoCoordinatorState();
  resetRecentUserEditSpan();
  ff().clearStructuralUndoRegistry();
  ff().resetForProjectSwitch();
  ff().setContent(text);
  ff().resetForProjectSwitch();
  view = currentView();
  errorHandlerMessages.length = 0;
  expect(docText()).toBe(text);
  expect(undoDepth(view.state)).toBe(0);
}

// --- The request Swift would send ---

type Plan = Array<{ id: string; level?: number }>;

const idsOf = (built: Built): string[] => built.leaders.map((leader) => leader.id);

/** The plan for `order`, with the levels `levels` (id to new level). */
const planOf = (order: string[], levels: Record<string, number> = {}): Plan =>
  order.map((id) => (levels[id] === undefined ? { id } : { id, level: levels[id] }));

/** `ids` with the run `run` taken out and put in front of `before` (at the end when `before` is null). */
function moveRun(ids: string[], run: string[], before: string | null): string[] {
  const rest = ids.filter((id) => !run.includes(id));
  const at = before === null ? rest.length : rest.indexOf(before);
  return [...rest.slice(0, at), ...run, ...rest.slice(at)];
}

/** The trimmed first line of the first Notes / Bibliography row of the document (leader or not), or null. */
function firstManagedLine(built: Built): string | null {
  for (const block of built.blocks) {
    if (block.kind === 'leader' && block.managed)
      return (block.rawLine ?? `${'#'.repeat(block.level)} ${block.title}`).trim();
    if (block.kind === 'text' && block.managedRow) return block.text.split('\n')[0].trim();
  }
  return null;
}

function reorderRequest(built: Built, rootId: string, order: Plan, opId = OP): MarkdownReorderRequest {
  return { kind: 'reorder', opId, rootId, leaders: built.leaders, order, stopLine: firstManagedLine(built) };
}

function clickReorder(built: Built, rootId: string, order: Plan, opId = OP): MarkdownReorderResult {
  return ff().markdownStructuralReorder(JSON.stringify(reorderRequest(built, rootId, order, opId)));
}

/** A heading or section-break line that does not start its own block (a blank line before it), or an anchor in the middle of a line. */
function gluedHeadings(text: string): string[] {
  const lines = text.split('\n');
  const glued: string[] = [];
  lines.forEach((line, index) => {
    const isLeader = /^(?:<!-- @sid:[0-9a-f-]+ -->)?(?:#{1,6}[ \t　]|<!-- ::break:: -->)/.test(line);
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
// W-R1 .. W-R3: the move itself
// =============================================================================================================================

describe("W-R1 a plain drag moves the card's own section, not its sub-sections", () => {
  // The moved chapter has a `##` sub-heading that is in the order (a card of its own): a plain drag leaves it behind, exactly as the
  // database groups the rows (a group runs to the next leader IN THE ORDER).
  // Break patch (W-R1.patch): in api-structural-markdown-reorder.ts `endOfGroup` end a group at the next leader whose level is not deeper
  // than its own (findSectionRange's rule) instead of at the next group leader.
  // Predicted failure: `moved text differs` (the chapter took its sub-section along).
  const sections = (body2: string, body4: string, body1 = 'Text of chapter 1.') => ({
    c1: ch(1, body1),
    c2: ch(2, body2),
    c2a: sub('h2a', 'Part 2.1'),
    c3: ch(3),
    c4: ch(4, body4),
    c4a: sub('h4a', 'Part 4.1'),
  });
  const startDocument = (): Built => {
    const s0 = sections('Text of chapter 2.', 'Text of chapter 4.');
    return build([...s0.c1, ...s0.c2, ...s0.c2a, ...s0.c3, ...s0.c4, ...s0.c4a]);
  };

  it('down: chapter 2 goes below chapter 3, its sub-section stays where it was, and the typing in it goes along', () => {
    const start = startDocument();
    load(start.text);
    typeAfter('Text of chapter 1.', ' early'); // in a chapter that stays put
    typeAfter('Text of chapter 2.', ' typed'); // in the chapter that moves
    const typedPre = docText();

    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4')));

    expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
    expect(result.preRaw).toBe(typedPre);
    expect(result.postRaw).toBe(docText());
    expect(result.skippedIds).toEqual([]);
    const s = sections('Text of chapter 2. typed', 'Text of chapter 4.', 'Text of chapter 1. early');
    expect(docText(), 'moved text differs').toBe(build([...s.c1, ...s.c2a, ...s.c3, ...s.c2, ...s.c4, ...s.c4a]).text);
    // The move is not a text-history step (addToHistory:false). The typing outside the moved range is still one; the typing inside
    // it is mapped away with the range (parity with Rich Text), so it is no longer a step of its own.
    expect(undoDepth(view.state)).toBe(1);
  });

  it('up: chapter 4 goes above chapter 3, its sub-section stays behind', () => {
    const start = startDocument();
    load(start.text);
    typeAfter('Text of chapter 1.', ' early'); // in a chapter that stays put
    typeAfter('Text of chapter 4.', ' typed'); // in the chapter that moves

    const result = clickReorder(start, 'h4', planOf(moveRun(idsOf(start), ['h4'], 'h3')));

    expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
    const s = sections('Text of chapter 2.', 'Text of chapter 4. typed', 'Text of chapter 1. early');
    expect(docText(), 'moved text differs').toBe(build([...s.c1, ...s.c2, ...s.c2a, ...s.c4, ...s.c3, ...s.c4a]).text);
    expect(undoDepth(view.state)).toBe(1);
  });
});

describe('W-R2 an Option drag moves the card and its sub-sections', () => {
  // Break patch (W-R2.patch): in `planReorder` stop the run at one group (`oldAt + runLength < Math.min(oldOrder.length, oldAt + 1)`).
  // Predicted failure: `subsection left behind` (the plan is refused, or the sub-sections stay).
  const parts = () => ({
    c1: ch(1),
    c2: ch(2),
    c2a: sub('h2a', 'Part 2.1'),
    c2b: sub('h2b', 'Part 2.2'),
    c3: ch(3),
    c4: ch(4),
  });

  it.each([
    [
      'down, in front of chapter 4',
      'h4',
      (p: ReturnType<typeof parts>) => [...p.c1, ...p.c3, ...p.c2, ...p.c2a, ...p.c2b, ...p.c4],
    ],
    [
      'up, in front of chapter 1',
      'h1',
      (p: ReturnType<typeof parts>) => [...p.c2, ...p.c2a, ...p.c2b, ...p.c1, ...p.c3, ...p.c4],
    ],
  ] as Array<[string, string, (p: ReturnType<typeof parts>) => Block[]]>)('%s', (_label, before, expectedBlocks) => {
    const p = parts();
    const start = build([...p.c1, ...p.c2, ...p.c2a, ...p.c2b, ...p.c3, ...p.c4]);
    load(start.text);

    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2', 'h2a', 'h2b'], before)));

    expect(result.ok, `subsection left behind: the move was refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), 'subsection left behind').toBe(build(expectedBlocks(p)).text);
  });
});

describe('W-R3 Notes and Bibliography stay last and byte-identical', () => {
  // Break patch (W-R3a.patch): in `planReorder` the target is the end of the document (`target = end;`): fails a, b and c.
  // Break patch (W-R3b.patch): only a run with no follower, or one followed by Notes/Bibliography, goes to the end of the document
  // (the `Math.min(..., tailAt)` cap on the target is dropped): fails b and c.
  // Break patch (W-R3c.patch): in `endOfGroup` do not cap the last group at the region start (`return next;`): fails c.
  // Predicted failure: `managed region changed`.
  /** The text from the Notes heading line to the end of the document. */
  const regionText = (built: Built, notesId = 'hn'): string =>
    built.text.slice(built.text.indexOf(`<!-- @sid:${sid(notesId)} -->`));

  it('a: the last chapter moves up; the region is untouched', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...region()]);
    load(start.text);
    const result = clickReorder(start, 'h3', planOf(moveRun(idsOf(start), ['h3'], 'h2')));
    expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText().endsWith(regionText(start)), 'managed region changed').toBe(true);
    expect(docText()).toBe(build([...ch(1), ...ch(3), ...ch(2), ...region()]).text);
  });

  it('b: a chapter moves to last: it lands in front of Notes, which and the Bibliography stay last', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...region()]);
    load(start.text);
    const result = clickReorder(start, 'h1', planOf(moveRun(idsOf(start), ['h1'], 'hn')));
    expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText().endsWith(regionText(start)), 'managed region changed').toBe(true);
    expect(docText(), 'managed region changed').toBe(build([...ch(2), ...ch(3), ...ch(1), ...region()]).text);
  });

  it('c: the plan lists neither Notes nor Bibliography (their rows were re-created with new ids): the region still comes from the request', () => {
    // The order still names the old ids (no leader: skipped) and none of the new ones; the leaders carry the new managed rows.
    const start = build([...ch(1), ...ch(2), ...ch(3), ...region('hn2', 'hb2')]);
    load(start.text);
    const order = planOf(['h1', 'h3', 'h2', 'hn-old', 'hb-old']);
    const result = clickReorder(start, 'h3', order);
    expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
    expect(result.skippedIds).toEqual(['hn-old', 'hb-old']);
    expect(docText().endsWith(regionText(start, 'hn2')), 'managed region changed').toBe(true);
    expect(docText(), 'managed region changed').toBe(
      build([...ch(1), ...ch(3), ...ch(2), ...region('hn2', 'hb2')]).text
    );
  });
});

// =============================================================================================================================
// W-R4: the end of a document with no Notes and no Bibliography
// =============================================================================================================================

describe('W-R4 separators at the end of a document with no Notes or Bibliography', () => {
  // The last group of such a document ends with whatever the document ends with (one newline, none, two). A heading must never be glued to
  // the line before it, and the document keeps its original final characters.
  // Break patch (W-R4i.patch): in `planReorder` do not treat a run that reaches the end of the document specially (rule i):
  // `if (to === end) mode = 'last';` is removed.
  // Break patch (W-R4ii.patch): do not treat a run moved to the end specially (rule ii): `else if (target === end) mode = 'toEnd';` is removed.
  // Break patch (W-R4f.patch): the document's final newlines are capped at one (`Math.min(newlinesBefore(doc, end), 1)`): fails the
  // two-newline cases only.
  // Predicted failure: `heading glued to previous line` (W-R4i and W-R4ii, zero or one newline at the end; with two newlines at the end
  // the verbatim move is already right and only the final-characters check can fail): `document final characters changed` (W-R4f).
  const chapters = (): Block[][] => [ch(1), ch(2), ch(3), ch(4)];

  it.each([
    ['i: the last chapter moves up', '', 'h4', 'h3'],
    ['i: the last chapter moves up', '\n', 'h4', 'h3'],
    ['i: the last chapter moves up', '\n\n', 'h4', 'h3'],
    ['ii: a middle chapter moves to the end', '', 'h2', null],
    ['ii: a middle chapter moves to the end', '\n', 'h2', null],
    ['ii: a middle chapter moves to the end', '\n\n', 'h2', null],
  ] as Array<
    [string, string, string, string | null]
  >)('%s (the document ends with %j)', (_label, trailing, rootId, before) => {
    const [c1, c2, c3, c4] = chapters();
    const start = build([...c1, ...c2, ...c3, ...c4], trailing);
    load(start.text);

    const result = clickReorder(start, rootId, planOf(moveRun(idsOf(start), [rootId], before)));

    expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
    expect(gluedHeadings(docText()), 'heading glued to previous line').toEqual([]);
    const expectedBlocks = rootId === 'h4' ? [...c1, ...c2, ...c4, ...c3] : [...c1, ...c3, ...c4, ...c2];
    const expected = build(expectedBlocks, trailing).text;
    const finalChars = (text: string): string => text.slice(text.trimEnd().length);
    expect(finalChars(docText()), 'document final characters changed').toBe(finalChars(start.text));
    expect(docText()).toBe(expected);
  });

  it('i: several chapters move up together (an Option drag that reaches the end)', () => {
    const [c1, c2, c3, c4] = chapters();
    const start = build([...c1, ...c2, ...c3, ...c4], '');
    load(start.text);
    const result = clickReorder(start, 'h3', planOf(moveRun(idsOf(start), ['h3', 'h4'], 'h2')));
    expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
    expect(gluedHeadings(docText()), 'heading glued to previous line').toEqual([]);
    expect(docText()).toBe(build([...c1, ...c3, ...c4, ...c2], '').text);
  });
});

// =============================================================================================================================
// W-R5: level rewrites
// =============================================================================================================================

describe('W-R5 level rewrites match SectionSyncService.updateHeaderLevel byte for byte', () => {
  // updateHeaderLevel skips the `#` run and ONE ASCII space and keeps everything after as the title: `#`x n + " " + rest. A tab or a
  // U+3000 after the run is part of the rest. Only heading leaders are rewritten.
  // Break patch (W-R5.patch): in `levelRewrite` take every whitespace character after the `#` run into the replaced span
  // (`const spaceLength = /^\s*/.exec(rest.slice(hashes))?.[0].length ?? 0;`).
  // Break patch (W-R5b.patch): the leading hidden prefix is not skipped (`const prefix = '';`): fails every case behind an anchor.
  // Break patch (W-R5c.patch): the new prefix has no space (`insert: '#'.repeat(level)`): fails every case.
  // Break patch (W-R5d.patch): a section break is rewritten like a heading (the ATX guard line is removed): fails the section-break test.
  // Predicted failure: `level rewrite differs from updateHeaderLevel` (the U+3000 and tab cases for W-R5), `section break rewritten like a heading`.
  type Leader = Extract<Block, { kind: 'leader' }>;
  const cases: Array<{ label: string; leader: Leader; toLevel: number; expectedLine: string }> = [
    {
      label: 'plain, no anchor',
      leader: { kind: 'leader', id: 'h2', level: 1, title: 'Chapter 2', anchored: false },
      toLevel: 2,
      expectedLine: '## Chapter 2',
    },
    {
      label: 'behind a section anchor',
      leader: { kind: 'leader', id: 'h2', level: 1, title: 'Chapter 2' },
      toLevel: 3,
      expectedLine: `<!-- @sid:${sid('h2')} -->### Chapter 2`,
    },
    {
      label: 'a U+3000 after the # run',
      leader: { kind: 'leader', id: 'h2', level: 2, title: 'unused', rawLine: '##\u3000Chapter 2' },
      toLevel: 3,
      expectedLine: `<!-- @sid:${sid('h2')} -->### \u3000Chapter 2`,
    },
    {
      label: 'a tab after the # run',
      leader: { kind: 'leader', id: 'h2', level: 2, title: 'unused', rawLine: '##\tChapter 2' },
      toLevel: 3,
      expectedLine: `<!-- @sid:${sid('h2')} -->### \tChapter 2`,
    },
  ];

  it.each(cases)('chapter 2 moves down and changes level: $label', ({ leader, toLevel, expectedLine }) => {
    const start = build([...ch(1), leader, { kind: 'text', text: 'Text of chapter 2.' }, ...ch(3), ...ch(4)]);
    load(start.text);

    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4'), { h2: toLevel }));

    expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
    const line = docText()
      .split('\n')
      .find((l) => l.includes('Chapter 2'));
    expect(line, 'level rewrite differs from updateHeaderLevel').toBe(expectedLine);
    // Everything else is the moved text, byte for byte.
    const rewritten: Leader = { ...leader, rawLine: expectedLine.replace(/^<!-- @sid:[0-9a-f-]+ -->/, '') };
    const expected = build([
      ...ch(1),
      ...ch(3),
      rewritten,
      { kind: 'text', text: 'Text of chapter 2.' },
      ...ch(4),
    ]).text;
    expect(docText(), 'level rewrite differs from updateHeaderLevel').toBe(expected);
  });

  it('an Option drag into a deeper place: the root and its sub-sections are all rewritten inside the moved text', () => {
    const p = { c1: ch(1), c2: ch(2), c2a: sub('h2a', 'Part 2.1'), c2b: sub('h2b', 'Part 2.2'), c3: ch(3), c4: ch(4) };
    const start = build([...p.c1, ...p.c2, ...p.c2a, ...p.c2b, ...p.c3, ...p.c4]);
    load(start.text);

    const levels = { h2: 2, h2a: 3, h2b: 3 };
    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2', 'h2a', 'h2b'], 'h4'), levels));

    expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
    const expected = build([
      ...p.c1,
      ...p.c3,
      ...ch(2).map((b) => (b.kind === 'leader' ? { ...b, level: 2 } : b)),
      ...sub('h2a', 'Part 2.1', 3),
      ...sub('h2b', 'Part 2.2', 3),
      ...p.c4,
    ]).text;
    expect(docText(), 'level rewrite differs from updateHeaderLevel').toBe(expected);
  });

  it('a heading outside the moved run is rewritten in place too', () => {
    const p = { c1: ch(1), c2: ch(2), c3: ch(3), c3a: sub('h3a', 'Part 3.1'), c4: ch(4) };
    const start = build([...p.c1, ...p.c2, ...p.c3, ...p.c3a, ...p.c4]);
    load(start.text);

    // Chapter 2 moves to the end; Part 3.1 is promoted to a chapter on the same drop.
    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], null), { h3a: 1 }));

    expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), 'level rewrite differs from updateHeaderLevel').toBe(
      build([...p.c1, ...p.c3, ...sub('h3a', 'Part 3.1', 1), ...p.c4, ...p.c2]).text
    );
  });

  // A section break is not a heading; a level given for it changes nothing.
  it('a section break listed with a level is left alone', () => {
    const start = build([
      ...ch(1),
      { kind: 'break', id: 'br' },
      { kind: 'text', text: 'Text after the break.' },
      ...ch(3),
    ]);
    load(start.text);
    const result = clickReorder(start, 'h1', planOf(moveRun(idsOf(start), ['h1'], 'h3'), { br: 2 }));
    expect(result.ok, `reorder refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), 'section break rewritten like a heading').toBe(
      build([{ kind: 'break', id: 'br' }, { kind: 'text', text: 'Text after the break.' }, ...ch(1), ...ch(3)]).text
    );
  });
});

// =============================================================================================================================
// W-R6, W-R10: a refusal changes nothing
// =============================================================================================================================

describe('W-R6 a leader mismatch changes nothing', () => {
  // Break patch (W-R6.patch): in `runReorder` record a placeholder entry before the plan (before the leader match runs).
  // Predicted failure: `entry recorded on mismatch`.
  it.each([
    ['a heading renamed a moment ago', () => typeAfter('# Chapter 2', ' revised')],
    ['a heading typed a moment ago at the end of the document', () => typeAt(docText().length, '\n# Extra heading\n')],
  ] as Array<[string, () => void]>)('%s: ok:false leadersMismatch, no entry, no dispatch', (_label, mutate) => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);
    mutate();
    const docBefore = view.state.doc;
    const depthBefore = undoDepth(view.state);
    const dispatchSpy = vi.spyOn(view, 'dispatch');

    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4')));
    const dispatched = dispatchSpy.mock.calls.length;
    dispatchSpy.mockRestore();

    expect(view.state.doc, 'doc changed on mismatch').toBe(docBefore);
    expect(result.ok).toBe(false);
    expect(result.reason).toBe('leadersMismatch');
    expect(getRegistry().size, 'entry recorded on mismatch').toBe(0);
    expect(dispatched, 'a mismatch dispatched').toBe(0);
    expect(undoDepth(view.state)).toBe(depthBefore);
  });

  it('a stale stopLine (the rows have a Notes row the text does not) is a mismatch too', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3)]);
    load(start.text);
    const request = {
      ...reorderRequest(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h3'))),
      stopLine: '## Notes',
    };
    const result = ff().markdownStructuralReorder(JSON.stringify(request));
    expect(result).toMatchObject({ ok: false, reason: 'leadersMismatch' });
    expect(getRegistry().size, 'entry recorded on mismatch').toBe(0);
  });

  // The other refusals change nothing either (they also fail under the W-R6 and W-R10 patches, which put an entry or the descriptor in).
  it.each([
    ['rootNotFound', (b: Built) => reorderRequest(b, 'nope', planOf(idsOf(b)))],
    ['managedMoved', (b: Built) => reorderRequest(b, 'hn', planOf(moveRun(idsOf(b), ['hn'], 'h1')))],
    ['planMismatch', (b: Built) => reorderRequest(b, 'h1', planOf(['h2', 'h1', 'h4', 'h3', 'hn', 'hb']))],
    ['unsupportedKind', (b: Built) => ({ ...reorderRequest(b, 'h2', planOf(idsOf(b))), kind: 'delete' })],
    ['badRequest', (b: Built) => ({ ...reorderRequest(b, 'h2', planOf(idsOf(b))), order: 'no' })],
  ] as Array<
    [string, (b: Built) => object]
  >)('refusal %s: no entry, no dispatch, document and descriptor untouched', (reason, makeRequest) => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...region()]);
    load(start.text);
    ff().setUndoDescriptor({ undoTopOpId: EARLIER_OP });
    const descriptorBefore = getUndoDescriptor();
    const docBefore = view.state.doc;
    const dispatchSpy = vi.spyOn(view, 'dispatch');

    const result = ff().markdownStructuralReorder(JSON.stringify(makeRequest(start)));
    const dispatched = dispatchSpy.mock.calls.length;
    dispatchSpy.mockRestore();

    expect(result).toMatchObject({ ok: false, reason });
    expect(view.state.doc, 'doc changed on refusal').toBe(docBefore);
    expect(getRegistry().size, 'entry recorded on refusal').toBe(0);
    expect(dispatched, 'a refusal dispatched').toBe(0);
    expect(getUndoDescriptor()).toBe(descriptorBefore);
  });
});

describe('W-R10 the page sets the undo top itself, on success only', () => {
  // Break patch (W-R10.patch): in markdownStructuralReorder move `setUndoDescriptor({ undoTopOpId: parsed.request.opId });` above the call
  // of `runReorder` (set it before the result check). Predicted failure: `undoTopOpId set on refusal`.
  it('a refused click (leadersMismatch, planMismatch, managedMoved, rootNotFound) leaves the descriptor as it was', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4), ...region()]);
    const refusals: Array<[string, () => MarkdownReorderResult]> = [
      [
        'leadersMismatch',
        () => {
          typeAt(docText().length, '\n# Extra heading\n');
          return clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4')));
        },
      ],
      ['planMismatch', () => clickReorder(start, 'h1', planOf(['h2', 'h1', 'h4', 'h3', 'hn', 'hb']))],
      ['managedMoved', () => clickReorder(start, 'hn', planOf(moveRun(idsOf(start), ['hn'], 'h1')))],
      ['rootNotFound', () => clickReorder(start, 'nope', planOf(idsOf(start)))],
    ];
    for (const [reason, click] of refusals) {
      load(start.text);
      // Something is already on both stacks: the descriptor Swift pushed after earlier operations.
      ff().setUndoDescriptor({ undoTopOpId: EARLIER_OP, redoTopOpId: 'redo-top' });
      const before = getUndoDescriptor();

      const result = click();

      expect(result, reason).toMatchObject({ ok: false, reason });
      expect(getUndoDescriptor(), `undoTopOpId set on refusal (${reason})`).toBe(before);
      expect(getUndoDescriptor()).toEqual({ undoTopOpId: EARLIER_OP, redoTopOpId: 'redo-top' });
    }
  });

  // Break patch (W-R10b.patch): delete the line `if (result.ok) setUndoDescriptor(...)` in markdownStructuralReorder.
  // Predicted failure: `the Cmd-Z in the gap was not routed structural`.
  it('after the click and before any push from Swift, routing for Cmd-Z is structural for the opId of that click', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);

    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4')));
    expect(result.ok, JSON.stringify(result)).toBe(true);

    expect(decideLiveRouting(view, 'undo'), 'the Cmd-Z in the gap was not routed structural').toEqual({
      action: 'structural',
      opId: OP,
    });
    expect(getUndoDescriptor()).toEqual({ undoTopOpId: OP });
  });
});

// =============================================================================================================================
// W-R11: the caret
// =============================================================================================================================

describe('W-R11 the caret goes with the moved text', () => {
  // The selection is set in the same transaction. Break patch (W-R11.patch): in `runReorder` leave `selection: plan.selection,` out of
  // the dispatch (the editor then maps the caret through the changes, and a caret inside a moved range lands at the deletion point).
  // Predicted failure: `caret left behind at the deletion point`.
  const insertAtCaret = (text: string): void => typeAt(view.state.selection.main.head, text);

  it('a: a caret inside the moved chapter, dragged down: text typed at it lands in the chapter at its new place', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);
    caretAfter('Text of chapter 2.');
    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4')));
    expect(result.ok, JSON.stringify(result)).toBe(true);

    insertAtCaret(' typed');

    expect(docText(), 'caret left behind at the deletion point').toBe(
      build([...ch(1), ...ch(3), ...ch(2, 'Text of chapter 2. typed'), ...ch(4)]).text
    );
  });

  it('b: a caret inside the moved chapter, dragged up', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);
    caretAfter('Text of chapter 4.');
    const result = clickReorder(start, 'h4', planOf(moveRun(idsOf(start), ['h4'], 'h2')));
    expect(result.ok, JSON.stringify(result)).toBe(true);

    insertAtCaret(' typed');

    expect(docText(), 'caret left behind at the deletion point').toBe(
      build([...ch(1), ...ch(4, 'Text of chapter 4. typed'), ...ch(2), ...ch(3)]).text
    );
  });

  it('c: a level-changing drag DOWN, the caret below the rewritten heading: it keeps its column in the text', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);
    caretAfter('Text of chapter 2.');
    // Chapter 2 gets one more `#` (level 1 to 2): everything below the heading moves one character to the right in the new text.
    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4'), { h2: 2 }));
    expect(result.ok, JSON.stringify(result)).toBe(true);

    insertAtCaret(' typed');

    const movedChapter = ch(2, 'Text of chapter 2. typed').map((b) => (b.kind === 'leader' ? { ...b, level: 2 } : b));
    expect(docText(), 'caret left behind at the deletion point / caret column off by the level change').toBe(
      build([...ch(1), ...ch(3), ...movedChapter, ...ch(4)]).text
    );
  });

  it('PIN d: a chapter the move does not touch keeps the caret on its text', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);
    caretAfter('Text of chapter 3.');
    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], null)));
    expect(result.ok, JSON.stringify(result)).toBe(true);

    insertAtCaret(' typed');

    expect(docText(), 'caret moved off its text').toBe(
      build([...ch(1), ...ch(3, 'Text of chapter 3. typed'), ...ch(4), ...ch(2)]).text
    );
  });

  it('e: a selection the move cuts (anchor in the moved chapter, head outside it) collapses to its head', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);
    const anchor = docText().indexOf('Text of chapter 2.');
    const head = docText().indexOf('Text of chapter 4.') + 'Text of chapter 4.'.length;
    view.dispatch({ selection: { anchor, head } });
    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4')));
    expect(result.ok, JSON.stringify(result)).toBe(true);

    expect(view.state.selection.main.empty, 'a cut selection was not collapsed').toBe(true);
    insertAtCaret(' typed');
    expect(docText(), 'caret left behind at the deletion point').toBe(
      build([...ch(1), ...ch(3), ...ch(2), ...ch(4, 'Text of chapter 4. typed')]).text
    );
  });

  it('f: the last chapter of a document with no Notes moves up with its caret inside it (the separator rule changes its end)', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)], '');
    load(start.text);
    caretAfter('Text of chapter 4.');
    const result = clickReorder(start, 'h4', planOf(moveRun(idsOf(start), ['h4'], 'h3')));
    expect(result.ok, JSON.stringify(result)).toBe(true);

    insertAtCaret(' typed');

    expect(docText(), 'caret left behind at the deletion point').toBe(
      build([...ch(1), ...ch(2), ...ch(4, 'Text of chapter 4. typed'), ...ch(3)], '').text
    );
  });

  it('g: a caret in the trailing blank line of the last chapter stays inside the moved text', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]); // ends with one newline
    load(start.text);
    view.dispatch({ selection: { anchor: docText().length } });
    const result = clickReorder(start, 'h4', planOf(moveRun(idsOf(start), ['h4'], 'h3')));
    expect(result.ok, JSON.stringify(result)).toBe(true);

    const head = view.state.selection.main.head;
    const bodyEnd = docText().indexOf('Text of chapter 4.') + 'Text of chapter 4.'.length;
    expect(head, 'caret left behind at the deletion point').toBeGreaterThanOrEqual(bodyEnd);
    expect(head).toBeLessThanOrEqual(bodyEnd + 2);
  });
});

// =============================================================================================================================
// W-R14, W-R15, W-R17: the plan
// =============================================================================================================================

describe('W-R14 a level-only drop moves nothing and records one entry', () => {
  // Break patch (W-R14.patch): in `planReorder` refuse a plan that needs no move: after `const needsMove = ...` add
  // `if (!needsMove) return refuse('planMismatch');`. Predicted failure: `planMismatch` (the drop was refused).
  it("the order is the document's own order and one level changed: the `#` count changes, nothing moves", () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);
    caretAfter('Text of chapter 3.');
    const caretBefore = view.state.selection.main.head;

    const result = clickReorder(start, 'h2', planOf(idsOf(start), { h2: 2 }));

    expect(result.ok, `the level-only drop was refused: ${JSON.stringify(result)}`).toBe(true);
    expect(result.skippedIds).toEqual([]);
    expect(docText()).toBe(
      build([...ch(1), ...ch(2).map((b) => (b.kind === 'leader' ? { ...b, level: 2 } : b)), ...ch(3), ...ch(4)]).text
    );
    expect(getRegistry().size).toBe(1);
    const entry = getRegistry().get(OP);
    expect(entry?.midOp).toBe(false);
    expect(entry?.markdown?.kind).toBe('reorder');
    expect(entry?.preOpDoc.toString()).toBe(start.text);
    expect(entry?.postOpDoc.eq(view.state.doc)).toBe(true);
    // The caret below the rewritten heading moved with its text (one `#` more above it).
    expect(view.state.selection.main.head).toBe(caretBefore + 1);
  });

  it('the dragged root and a neighbour both change level, no move', () => {
    const start = build([...ch(1), ...ch(2), ...sub('h2a', 'Part 2.1'), ...ch(3)]);
    load(start.text);
    const result = clickReorder(start, 'h2', planOf(idsOf(start), { h2: 2, h2a: 3 }));
    expect(result.ok, `the level-only drop was refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText()).toBe(
      build([
        ...ch(1),
        ...ch(2).map((b) => (b.kind === 'leader' ? { ...b, level: 2 } : b)),
        ...sub('h2a', 'Part 2.1', 3),
        ...ch(3),
      ]).text
    );
    expect(getRegistry().size).toBe(1);
  });
});

describe('W-R15 the plan and the text may disagree about which headings exist', () => {
  // Break patch (W-R15a.patch): in `planReorder` refuse an order id with no leader (`if (skippedIds.length > 0) return refuse('planMismatch');`).
  // Predicted failure: `skippedIds empty` (the move was refused).
  // Break patch (W-R15b.patch): in `planReorder` make every leader a group leader (`isGroupLeader` is true for any leader id).
  // Predicted failure: `unlisted heading did not move with its leader`.
  it('a: an order id with no leader is returned in skippedIds and the move still happens', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);
    const order = planOf(['h1', 'ghost', 'h3', 'h2', 'h4']); // `ghost` is a section deleted a moment ago

    const result = clickReorder(start, 'h2', order);

    expect(result, `skippedIds empty: ${JSON.stringify(result)}`).toMatchObject({ ok: true, skippedIds: ['ghost'] });
    expect(docText()).toBe(build([...ch(1), ...ch(3), ...ch(2), ...ch(4)]).text);
  });

  it('b: a heading line that is not in the order moves as body text of the leader above it', () => {
    const aside = sub('haside', 'Aside');
    const start = build([...ch(1), ...ch(2), ...aside, ...ch(3), ...ch(4)]);
    load(start.text);
    // The rows have the Aside heading (the leaders list it); the plan does not.
    const order = planOf(['h1', 'h3', 'h2', 'h4']);

    const result = clickReorder(start, 'h2', order);

    expect(
      result.ok,
      `unlisted heading did not move with its leader: the move was refused: ${JSON.stringify(result)}`
    ).toBe(true);
    expect(docText(), 'unlisted heading did not move with its leader').toBe(
      build([...ch(1), ...ch(3), ...ch(2), ...aside, ...ch(4)]).text
    );
  });
});

describe('W-R17 a plan that is more than one moved run is refused', () => {
  // Break patch (W-R17.patch): in `planReorder` skip the rest check (delete the line
  // `if (!sameSequence(oldRest, newRest)) return refuse('planMismatch', ...);`). Predicted failure: `plan accepted although`.
  it('chapters 1 and 3 each hop over a neighbour: planMismatch, nothing recorded, nothing dispatched', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);
    const docBefore = view.state.doc;
    const dispatchSpy = vi.spyOn(view, 'dispatch');

    const result = clickReorder(start, 'h1', planOf(['h2', 'h1', 'h4', 'h3']));
    const dispatched = dispatchSpy.mock.calls.length;
    dispatchSpy.mockRestore();

    expect(
      result,
      `plan accepted although the order differs by more than one run: ${JSON.stringify(result)}`
    ).toMatchObject({
      ok: false,
      reason: 'planMismatch',
    });
    expect(view.state.doc).toBe(docBefore);
    expect(getRegistry().size, 'entry recorded on planMismatch').toBe(0);
    expect(dispatched).toBe(0);
  });
});

// =============================================================================================================================
// What the click records
// =============================================================================================================================

describe('the entry and the transaction', () => {
  // Break patch (W-Rpin1.patch): the entry is recorded with `midOp: false`. Predicted failure: `entry not recorded mid-op before the dispatch`.
  it('records one entry (kind reorder) before the dispatch, dispatches once, and keeps the checkpoint isolated', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);
    typeAfter('Text of chapter 1.', ' typed before');
    const typedPre = docText();
    const dispatchSpy = vi.spyOn(view, 'dispatch');
    let entryAtDispatch: unknown;
    dispatchSpy.mockImplementation((...args: Parameters<EditorView['dispatch']>) => {
      entryAtDispatch = getRegistry().get(OP);
      dispatchSpy.mockRestore();
      return view.dispatch(...args);
    });

    const request = reorderRequest(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4')));
    const result = ff().markdownStructuralReorder(request);

    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(
      (entryAtDispatch as { midOp?: boolean } | undefined)?.midOp,
      'entry not recorded mid-op before the dispatch'
    ).toBe(true);
    const entry = getRegistry().get(OP);
    expect(entry?.midOp).toBe(false);
    expect(entry?.markdown?.kind).toBe('reorder');
    expect(entry?.markdown?.request.opId).toBe(OP);
    expect(entry?.preOpDoc.toString()).toBe(typedPre);
    expect(entry?.checkpoint.doc.toString()).toBe(typedPre);
    expect(entry?.postOpDoc.eq(view.state.doc)).toBe(true);
    // The ONE change set takes the checkpoint document to the new document.
    expect(entry?.markdown?.opChanges.apply(entry.checkpoint.doc).toString()).toBe(docText());
    expect(undoDepth(view.state)).toBe(1); // only the typing before the click
  });

  // Break patch (W-Rpin2.patch): the entry's postOpDoc is not set after the dispatch (the placeholder stays).
  // Predicted failure: `"reason":"changed"` (the undo routing no longer finds the document equal to postOpDoc).
  it('the quick undo of a reorder entry swaps the pre-op document back (the checkpoint swap is shared with the delete)', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    load(start.text);
    const result = clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4')));
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).not.toBe(start.text);

    const undone = ff().markdownStructuralSwap(OP, 'undo');

    expect(undone.ok, JSON.stringify(undone)).toBe(true);
    expect(docText()).toBe(start.text);
  });
});

// =============================================================================================================================
// Round 2b: the undo and the redo of a reorder entry, through the real Cmd-Z / Cmd-Shift-Z listeners
// =============================================================================================================================

type FFUndo = FF & {
  receiveUndoOutcome: (opId: string, outcome: string) => void;
  receiveRedoOutcome: (opId: string, outcome: string) => void;
  renumberFootnotes: (mapping: Record<string, string>) => void;
  setStructuralSettleOpId: (opId: string | null) => void;
};
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

/** One structural Cmd-Z: the press, Swift's swap of the entry, Swift's reply. */
function structuralUndo(opId = OP): { ok: boolean; reason?: string } {
  const before = undoRequested().mock.calls.length;
  press('undo');
  expect(undoRequested().mock.calls.length, 'the Cmd-Z was not routed structural').toBe(before + 1);
  const result = ff().markdownStructuralSwap(opId, 'undo');
  ff().setUndoDescriptor({ redoTopOpId: opId });
  ffu().receiveUndoOutcome(opId, 'performed');
  return result;
}

/** One structural Cmd-Shift-Z; `lostMessage` is the failure shown when the press is not routed structural. */
function structuralRedo(lostMessage: string, opId = OP): { ok: boolean; reason?: string } {
  const before = redoRequested().mock.calls.length;
  press('redo');
  expect(redoRequested().mock.calls.length, lostMessage).toBe(before + 1);
  const result = ff().markdownStructuralSwap(opId, 'redo');
  ff().setUndoDescriptor({ undoTopOpId: opId });
  ffu().receiveRedoOutcome(opId, 'performed');
  return result;
}

/** `load`, with the message counters of the structural presses cleared. */
function loadFresh(text: string): void {
  load(text);
  undoRequested().mockClear();
  redoRequested().mockClear();
}

/** The lines that are chapter headings (the section anchor in front of the `#` included). */
const headingLines = (text: string): string[] => text.split('\n').filter((line) => line.includes('# Chapter'));

/** Chapters one, two and three with a footnote reference each (the Notes are left out: the labels are all these tests look at). */
const footnoted = (): Built =>
  build([...ch(1, 'Chapter one.[^1]'), ...ch(2, 'Chapter two.[^2]'), ...ch(3, 'Chapter three.[^3]')]);

/** What Swift's settle does after chapter three was dragged in front of chapter two: the references are numbered again in text order. */
function settleRenumber(): void {
  ffu().setStructuralSettleOpId(OP);
  ffu().renumberFootnotes({ '3': '2', '2': '3' });
  ffu().setStructuralSettleOpId(null);
}

describe('W-R7 a reorder redo is not a delete: undo, redo, undo through the real listeners', () => {
  // Break patch (W-R7.patch): in `markdownStructuralSwap` run the quick re-run for EVERY entry that has `markdown` extras
  // (`direction === 'redo' && entry.markdown`), i.e. revert the narrowing to `kind === 'delete'`.
  // Predicted failure: `redo removed the section` (the redo ran the delete of the dragged chapter).
  it('Cmd-Z puts the order back, Cmd-Shift-Z moves the chapter again (nothing is removed), Cmd-Z puts it back once more', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    loadFresh(start.text);
    expect(clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4'))).ok).toBe(true);
    const post = docText();
    expect(post).not.toBe(start.text);

    const undone = structuralUndo();
    expect(undone.ok, JSON.stringify(undone)).toBe(true);
    expect(docText()).toBe(start.text);

    const redone = structuralRedo('the Cmd-Shift-Z was not routed structural');
    expect(redone.ok, JSON.stringify(redone)).toBe(true);
    expect(docText(), 'redo removed the section').toBe(post);
    expect(getRegistry().get(OP)?.midOp).toBe(false);

    const undoneAgain = structuralUndo();
    expect(undoneAgain.ok, JSON.stringify(undoneAgain)).toBe(true);
    expect(docText()).toBe(start.text);
    expect(getRegistry().size).toBe(1);
  });
});

describe('W-R8 typing in the hopped-over chapter comes back through the redo', () => {
  // The dragged chapter is LONG and the chapter it hops over is SHORT: a line diff between the two documents would keep the long
  // chapter's lines and treat the short one as removed and re-inserted, which misplaces the typing in it. The real move (opChanges) does not.
  // Break patch (W-R8.patch): in `buildSwappedState` pass `undefined` instead of the entry's `opChanges` to `carryRedoBranch` for a
  // reorder entry (the carry then falls back to the minimal diff, whose removed spans now also drop the redo events inside them: the
  // hopped-over chapter's typing lies inside the span the line diff removes). Predicted failure: `the redo branch was not carried
  // across the swap` (the check right after the structural undo; the carried list is empty).
  const longBody = Array.from({ length: 40 }, (_, i) => `Line ${i + 1} of the long chapter.`).join('\n\n');

  it('drag the long chapter 2 down over the short chapter 3, type in 3, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z', () => {
    const start = build([...ch(1), ...ch(2, longBody), ...ch(3), ...ch(4)]);
    loadFresh(start.text);
    expect(clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4'))).ok).toBe(true);
    const post = docText();
    typeAfter('Text of chapter 3.', ' abc');
    const typed = docText();

    press('undo'); // the typing (a text undo)
    expect(docText()).toBe(post);
    expect(undoRequested()).not.toHaveBeenCalled();
    const undone = structuralUndo(); // the drag
    expect(undone.ok, JSON.stringify(undone)).toBe(true);
    expect(docText()).toBe(start.text);
    expect(redoDepth(view.state), 'the redo branch was not carried across the swap').toBe(1);

    const redone = structuralRedo('the Cmd-Shift-Z was not routed structural'); // the drag again
    expect(redone.ok, JSON.stringify(redone)).toBe(true);
    expect(docText()).toBe(post);
    press('redo'); // the typing (a text redo)
    expect(docText(), 'typing not restored by redo').toBe(typed);
  });
});

describe('W-R9 the settle renumber after a reorder is not a history step of its own', () => {
  // Break patch (W-R9.patch): in api.ts `renumberFootnotes` always use the derivedCorrection annotation (replace
  // `structuralSettleOpId !== null ? Transaction.addToHistory.of(false) : derivedCorrection.of(true)` by `derivedCorrection.of(true)`).
  // Predicted failure: `renumber added an undo step`. (It exercises existing code in the reorder case; the delete case is W8 in
  // structural-markdown.test.ts.)
  it('after a drag that puts the references out of order, the renumber inside the settle leaves the undo depth alone, and Cmd-Z still reaches the drag', () => {
    const start = footnoted();
    loadFresh(start.text);
    typeAfter('Chapter one.[^1]', ' x'); // an ordinary text step before the drag
    const startTyped = docText();
    expect(clickReorder(start, 'h3', planOf(moveRun(idsOf(start), ['h3'], 'h2'))).ok).toBe(true);
    const depth = undoDepth(view.state);
    expect(docText()).toContain('Chapter three.[^3]');

    settleRenumber();

    expect(docText()).toContain('Chapter three.[^2]');
    expect(undoDepth(view.state), 'renumber added an undo step').toBe(depth);
    expect(getRegistry().get(OP)?.postOpDoc.eq(view.state.doc)).toBe(true);
    const undone = structuralUndo();
    expect(undone.ok, JSON.stringify(undone)).toBe(true);
    expect(docText()).toBe(startTyped);
  });
});

describe('W-R12 the redo lands on the settled post-op document, and works again and again', () => {
  // Break patch (W-R12a.patch): in `composedRedo` apply the recorded move alone (`const changes = extras.opChanges;`).
  // Predicted failure: `redo document differs from postOpDoc` (the references read out of order again until a later settle).
  // Break patch (W-R12b.patch): in `markdownStructuralSwap` run the composed redo in an early return before the midOp block
  // (`if (direction === 'redo') { const early = composedRedo(view, entry); if (early !== null) return early; }`).
  // Predicted failure: `second redo lost` (the redo's own dispatch advances preOpDoc, so the next Cmd-Shift-Z is not routed structural).
  it('drag, settle renumber, then two full Cmd-Z / Cmd-Shift-Z cycles: every redo document equals the renumbered post-op document', () => {
    const start = footnoted();
    loadFresh(start.text);
    expect(clickReorder(start, 'h3', planOf(moveRun(idsOf(start), ['h3'], 'h2'))).ok).toBe(true);
    const unsettled = docText();
    settleRenumber();
    const settled = docText();
    expect(settled).not.toBe(unsettled);
    expect(getRegistry().get(OP)?.postOpDoc.toString()).toBe(settled); // the renumber advanced the saved copy

    for (const cycle of [1, 2]) {
      const undone = structuralUndo();
      expect(undone.ok, `cycle ${cycle}: ${JSON.stringify(undone)}`).toBe(true);
      expect(docText()).toBe(start.text);

      const redone = structuralRedo(`second redo lost (cycle ${cycle}: the Cmd-Shift-Z was not routed structural)`);
      expect(redone.ok, `cycle ${cycle}: ${JSON.stringify(redone)}`).toBe(true);
      // Straight after the redo, before any settle:
      expect(docText(), `redo document differs from postOpDoc (cycle ${cycle})`).toBe(settled);
    }
    // The redo's own dispatch is not an automatic change: the entry's saved copies are where they were.
    expect(getRegistry().get(OP)?.postOpDoc.eq(view.state.doc)).toBe(true);
    expect(getRegistry().get(OP)?.preOpDoc.toString(), 'the redo moved preOpDoc').toBe(start.text);
    expect(getRegistry().get(OP)?.midOp).toBe(false);
  });
});

describe('W-R13 a redo after an automatic change moved preOpDoc takes the saved-copy swap', () => {
  // Break patch (W-R13.patch): in `composedRedo` guard on `entry.preOpDoc` instead of `entry.checkpoint.doc`.
  // Predicted failure: `swapThrew` (the change set was built on the checkpoint document and is applied to a longer one).
  it('after Cmd-Z the rebuild injects anchors (a sync-origin change); Cmd-Shift-Z still works and lands on postOpDoc', () => {
    const start = build([
      ...ch(1, 'Text of chapter 1.', { anchored: false }),
      ...ch(2),
      ...ch(3),
      ...ch(4, 'Text of chapter 4.', { anchored: false }),
    ]);
    loadFresh(start.text);
    expect(clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4'))).ok).toBe(true);
    const post = getRegistry().get(OP)?.postOpDoc.toString();

    expect(structuralUndo().ok).toBe(true);
    expect(docText()).toBe(start.text);
    const anchored = start.text
      .replace('# Chapter 1', `<!-- @sid:${sid('h1')} --># Chapter 1`)
      .replace('# Chapter 4', `<!-- @sid:${sid('h4')} --># Chapter 4`);
    ff().setContent(anchored, { origin: 'derived' });
    expect(docText()).toBe(anchored);
    expect(getRegistry().get(OP)?.preOpDoc.toString(), 'preOpDoc did not follow the derived change').toBe(anchored);

    const redone = structuralRedo('the Cmd-Shift-Z was not routed structural');
    expect(redone.ok, `redo failed: ${JSON.stringify(redone)}`).toBe(true);
    expect(redone.reason).not.toBe('swapThrew');
    expect(docText()).toBe(post);
  });
});

describe('W-R16 typing done inside the dragged chapter comes back through the redo, and never lands in another chapter', () => {
  // Typing done inside the dragged chapter is redone after Cmd-Z x2 and Cmd-Shift-Z x2 (t-14f908b4). The undo's carry still LEAVES OUT the
  // redo events that lie inside the moved text -- CodeMirror maps an insertion inside a removed range to the removal point, which is the
  // start of the hopped-over chapter's heading line -- but the undo also sets the full redo list aside and the structural redo puts it
  // back (redo-branch.ts `putBackRedo`). The drop alone is the FALL-BACK, pinned by MR7 below.
  // Break patch (W-R16.patch): in `buildSwappedState` pass `null` instead of `moved` to `carryRedoBranch` (the carry without its drop).
  // Break patch (putBack.patch): remove the `putBackSetAsideRedo(view, opId, depthBeforeRedo);` call in `markdownStructuralSwap`.
  const twoChapters = (): Built => build([...ch(4), ...ch(5)]);

  // Break patch: putBack.patch (remove the putBackRedo call). Predicted failure: `the dragged chapter typing is not back`.
  it('drag chapter 5 up, type inside it, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z: the typing comes back inside chapter 5, no heading line changes', () => {
    const start = twoChapters();
    loadFresh(start.text);
    expect(clickReorder(start, 'h5', planOf(moveRun(idsOf(start), ['h5'], 'h4'))).ok).toBe(true);
    const post = docText();
    typeAfter('Text of chapter 5.', ' And after.');
    const typed = docText();

    press('undo'); // the typing
    expect(docText()).toBe(post);
    expect(structuralUndo().ok).toBe(true); // the drag
    expect(docText()).toBe(start.text);
    const redone = structuralRedo('the Cmd-Shift-Z was not routed structural'); // the drag again
    expect(redone.ok, JSON.stringify(redone)).toBe(true);
    expect(docText()).toBe(post);
    press('redo'); // the typing: it lies inside the dragged chapter, set aside by the undo and put back by the redo

    expect(headingLines(docText()), 'heading line changed by a redo').toEqual(headingLines(post));
    expect(docText(), 'the dragged chapter typing is not back').toBe(typed);
  });

  // MR7: the fall-back. The old body of the test above: when the put-back is refused (here: the record is broken after the undo), the
  // carried list is what the redo finds, and that list must not hold the typing inside the dragged chapter: nothing is written into a
  // heading line, the typing is simply not redone.
  // Break patch (W-R16.patch): in `buildSwappedState` pass `null` instead of `moved` to `carryRedoBranch` (today's carry, unchanged).
  // Predicted failure: `heading line changed by a redo`.
  it('MR7 fall-back: the put-back is refused (record broken): the typing inside the dragged chapter is not redone and no heading line changes', () => {
    const start = twoChapters();
    loadFresh(start.text);
    expect(clickReorder(start, 'h5', planOf(moveRun(idsOf(start), ['h5'], 'h4'))).ok).toBe(true);
    const post = docText();
    typeAfter('Text of chapter 5.', ' And after.');

    press('undo'); // the typing
    expect(docText()).toBe(post);
    expect(structuralUndo().ok).toBe(true); // the drag
    expect(docText()).toBe(start.text);
    const record = setAsideRedoOf(OP);
    expect(record, 'PREMISE: the undo set the redo list aside').toBeDefined();
    if (record) record.depthAfterUndo += 1; // the put-back must now refuse
    const redone = structuralRedo('the Cmd-Shift-Z was not routed structural'); // the drag again
    expect(redone.ok, JSON.stringify(redone)).toBe(true);
    expect(docText()).toBe(post);
    press('redo'); // the typing: it lies inside the dragged chapter and was dropped by the carry

    expect(
      errorHandlerMessages.some((m) => m.includes('redo put-back skipped')),
      'PREMISE: the put-back was refused'
    ).toBe(true);
    expect(headingLines(docText()), 'heading line changed by a redo').toEqual(headingLines(post));
    expect(docText(), 'after the fall-back the document must be the post-op copy without the typing').toBe(post);
  });

  // Break patch (W-R16c.patch): in `carryRedoBranch` drop every redo event once a moved range is given (`kept = 0`).
  // Predicted failure: `the redo branch was not carried across the swap` (the carried list is empty right after the structural undo).
  it('typing in the HOPPED-OVER chapter is still redone (it lies outside the moved text)', () => {
    const start = twoChapters();
    loadFresh(start.text);
    expect(clickReorder(start, 'h5', planOf(moveRun(idsOf(start), ['h5'], 'h4'))).ok).toBe(true);
    const post = docText();
    typeAfter('Text of chapter 4.', ' hop');
    const typed = docText();

    press('undo');
    expect(structuralUndo().ok).toBe(true);
    // The carry kept the hopped-over event: the put-back would hide a carry that dropped it, so look at the carried list itself.
    expect(redoDepth(view.state), 'the redo branch was not carried across the swap').toBe(1);
    expect(structuralRedo('the Cmd-Shift-Z was not routed structural').ok).toBe(true);
    expect(docText()).toBe(post);
    press('redo');

    expect(docText(), 'typing in the hopped-over chapter not restored').toBe(typed);
  });

  // Break patch: putBack.patch (remove the putBackRedo call). Predicted failure: `the dragged chapter typing is not back`.
  it('typing in the hopped-over chapter THEN inside the dragged one: both are redone, in order', () => {
    const start = twoChapters();
    loadFresh(start.text);
    expect(clickReorder(start, 'h5', planOf(moveRun(idsOf(start), ['h5'], 'h4'))).ok).toBe(true);
    const post = docText();
    typeAfter('Text of chapter 4.', ' hop'); // outside the moved text, done first
    const hopped = docText();
    typeAfter('Text of chapter 5.', ' And after.'); // inside it, done second
    const typedBoth = docText();

    press('undo'); // " And after."
    press('undo'); // " hop"
    expect(docText()).toBe(post);
    expect(structuralUndo().ok).toBe(true);
    expect(docText()).toBe(start.text);
    expect(structuralRedo('the Cmd-Shift-Z was not routed structural').ok).toBe(true);
    expect(docText()).toBe(post);
    press('redo'); // " hop" comes back
    expect(docText(), 'typing in the hopped-over chapter not restored').toBe(hopped);
    press('redo'); // " And after." comes back too, inside the dragged chapter

    expect(headingLines(docText()), 'heading line changed by a redo').toEqual(headingLines(hopped));
    expect(docText(), 'the dragged chapter typing is not back').toBe(typedBoth);
  });

  // The live document at the Cmd-Z is NOT the one the command produced (the rebuild's anchors came in after it), so the moved range has
  // to be followed through that rewrite first. Both orders: the anchors land BEFORE the typing (the saved copy follows them, the put-back
  // difference is empty) and AFTER it (the saved copy stays where the click left it, so the redo lands on the document WITHOUT the
  // anchors and the put-back difference removes them). The typing is below the dragged chapter's heading; the anchors are in headings.
  // Break patch: putBack.patch (remove the putBackRedo call). Predicted failure: `the dragged chapter typing is not back`.
  it.each([
    ['BEFORE the typing', true],
    ['AFTER the typing', false],
  ])('the app rewrote the document after the drag (anchors injected %s): the dragged chapter typing comes back', (_when, anchorsFirst) => {
    const start = build([
      ...ch(4, 'Text of chapter 4.', { anchored: false }),
      ...ch(5, 'Text of chapter 5.', { anchored: false }),
    ]);
    loadFresh(start.text);
    expect(clickReorder(start, 'h5', planOf(moveRun(idsOf(start), ['h5'], 'h4'))).ok).toBe(true);
    const post = docText();
    const anchor = (text: string): string =>
      text
        .replace('# Chapter 5', `<!-- @sid:${sid('h5')} --># Chapter 5`)
        .replace('# Chapter 4', `<!-- @sid:${sid('h4')} --># Chapter 4`);
    let typed: string;
    let afterRedo: string; // the document the structural redo lands on
    if (anchorsFirst) {
      ff().setContent(anchor(post), { origin: 'derived' });
      expect(docText()).toBe(anchor(post));
      typeAfter('Text of chapter 5.', ' And after.');
      typed = docText();
      afterRedo = anchor(post); // the saved copy followed the anchors
    } else {
      typeAfter('Text of chapter 5.', ' And after.');
      typed = docText();
      ff().setContent(anchor(typed), { origin: 'derived' });
      expect(docText()).toBe(anchor(typed));
      afterRedo = post; // the saved copy never saw the anchors: after the redo they are gone again, the put-back difference removes them
    }

    press('undo'); // the typing
    expect(docText()).toBe(anchor(post));
    expect(structuralUndo().ok).toBe(true);
    expect(docText()).toBe(start.text);
    const redone = structuralRedo('the Cmd-Shift-Z was not routed structural');
    expect(redone.ok, JSON.stringify(redone)).toBe(true);
    expect(docText()).toBe(afterRedo);
    press('redo'); // the typing: inside the dragged chapter, put back

    expect(headingLines(docText()), 'heading line changed by a redo').toEqual(headingLines(afterRedo));
    expect(docText(), 'the dragged chapter typing is not back').toBe(typed);
  });

  // Break patch (W-R16d.patch): in `planReorder` leave `padLength` out of the recorded moved range.
  // Predicted failure: `recorded moved range differs` (the range starts in the blank line that belongs to the chapter before).
  it.each([
    ['a middle chapter moved down', 'h2', 'h4', '\n', (n: number) => ch(n)],
    ['the last chapter moved up (the separator rule changes its end)', 'h4', 'h3', '', (n: number) => ch(n)],
    ['a middle chapter moved to the end of a document without Notes', 'h2', null, '\n', (n: number) => ch(n)],
  ] as Array<
    [string, string, string | null, string, (n: number) => Block[]]
  >)('the recorded moved range is the moved chapter: %s', (_label, rootId, before, trailing, chapter) => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)], trailing);
    loadFresh(start.text);
    expect(clickReorder(start, rootId, planOf(moveRun(idsOf(start), [rootId], before))).ok).toBe(true);

    const entry = getRegistry().get(OP);
    expect(entry?.markdown?.kind).toBe('reorder');
    const moved = entry?.markdown?.kind === 'reorder' ? entry.markdown.moved : null;
    expect(moved).not.toBeNull();
    if (moved === null) return;
    const n = Number(rootId.slice(1));
    // The chapter, followed by one blank line, or by whatever the document ends with when it ends the document.
    const endsDocument = moved.to === docText().length;
    const expected = build(chapter(n), endsDocument ? trailing : '\n\n').text;
    expect(docText().slice(moved.from, moved.to), 'recorded moved range differs').toBe(expected);
  });
});

describe('MR8 / MR14 the drag, typing inside the dragged chapter, and TWO full Cmd-Z x2 / Cmd-Shift-Z x2 cycles', () => {
  // The second cycle needs a record stored by the SECOND undo (the first was taken by the first redo) and the entry the swap leaves behind.
  // Break patch: putBack.patch (remove the `putBackSetAsideRedo(view, opId, depthBeforeRedo);` call in `markdownStructuralSwap`).
  // Predicted failure: `dragged chapter typing not back after cycle 1`.
  function dragTypeTwoCycles(start: Built, typedAfter: string, headingsOf: (text: string) => string[]): void {
    loadFresh(start.text);
    expect(clickReorder(start, 'h5', planOf(moveRun(idsOf(start), ['h5'], 'h4'))).ok).toBe(true);
    const post = docText();
    typeAfter(typedAfter, ' And after.');
    const typed = docText();
    expect(typed, 'PREMISE: the typing is in the document').not.toBe(post);

    for (const cycle of [1, 2]) {
      press('undo'); // the typing
      expect(docText(), `PREMISE: cycle ${cycle}: Cmd-Z 1 was the typing`).toBe(post);
      expect(structuralUndo().ok, `cycle ${cycle}: the structural undo`).toBe(true); // the drag
      expect(docText(), `PREMISE: cycle ${cycle}: Cmd-Z 2 was the drag`).toBe(start.text);
      expect(
        structuralRedo('the Cmd-Shift-Z was not routed structural').ok,
        `cycle ${cycle}: the structural redo`
      ).toBe(true); // the drag again
      expect(docText(), `PREMISE: cycle ${cycle}: Cmd-Shift-Z 1 was the drag`).toBe(post);
      press('redo'); // the typing
      expect(headingsOf(docText()), `heading line changed by a redo (cycle ${cycle})`).toEqual(headingsOf(post));
      expect(docText(), `dragged chapter typing not back after cycle ${cycle}`).toBe(typed);
    }
  }

  it('MR14: three small chapters, chapter 5 dragged above chapter 4, two cycles: the typing comes back each time', () => {
    dragTypeTwoCycles(build([...ch(4), ...ch(5), ...ch(6)]), 'Text of chapter 5.', headingLines);
  });

  it('MR8: a book of 3,000+ lines (six chapters of 250 paragraphs), chapter 5 dragged above chapter 4, two cycles', () => {
    const body = (n: number): string =>
      Array.from({ length: 250 }, (_, i) => `Paragraph ${i + 1} of chapter ${n}.`).join('\n\n');
    const start = build([1, 2, 3, 4, 5, 6].flatMap((n) => ch(n, body(n))));
    expect(start.text.split('\n').length, 'PREMISE: a book-sized document').toBeGreaterThan(3000);
    dragTypeTwoCycles(start, 'Paragraph 120 of chapter 5.', headingLines);
  });
});

describe('W-R21 a redo event already pending when the drag is clicked never lands in a heading line', () => {
  // The reviewer's probe (M6, plan review): typing inside chapter 5 and taking it back with Cmd-Z leaves one event in the editor's redo
  // list. The drag is then clicked with addToHistory:false, which maps both history branches through the move, and an insertion inside
  // the moved (removed) range lands at the removal point -- the start of the line that follows the chapter's old place, here
  // chapter 6's heading line. Cmd-Shift-Z (no structural redo is on top: this is the editor's own text redo) would then type the
  // sentence into that heading line and split it.
  // Break patch (W-R21.patch): see the line the click's fix adds in api-structural-markdown-reorder.ts (`runReorder`).
  // Predicted failure: `heading line changed by a redo`.
  it('type in chapter 5, Cmd-Z, drag chapter 5 above chapter 4, Cmd-Shift-Z: every heading line reads as after the drag', () => {
    const start = build([...ch(4), ...ch(5), ...ch(6)]);
    loadFresh(start.text);
    typeAfter('Text of chapter 5.', ' X');
    press('undo'); // the typing: one event waits in the redo list
    expect(docText()).toBe(start.text);
    expect(redoDepth(view.state), 'PREMISE: the typing waits in the redo list').toBe(1);
    expect(clickReorder(start, 'h5', planOf(moveRun(idsOf(start), ['h5'], 'h4'))).ok).toBe(true);
    const post = docText();

    press('redo'); // not routed structural: the editor's own text redo

    expect(redoRequested(), 'PREMISE: the Cmd-Shift-Z was a text redo').not.toHaveBeenCalled();
    expect(headingLines(docText()), 'heading line changed by a redo').toEqual(headingLines(post));
    const typedOnHeading = docText()
      .split('\n')
      .filter((line) => line.includes(' X') && line.includes('# Chapter'));
    expect(typedOnHeading, 'the typing landed on a heading line').toEqual([]);
  });
});

describe('W-R18 the caret goes with the dragged text through Cmd-Z and Cmd-Shift-Z', () => {
  // Break patch (W-R18.patch): in `composedRedo` leave the recorded selection out of the dispatch (`selection: undefined`), so the
  // caret is mapped through the move like any position and, inside a removed range, ends at the removal point.
  // Predicted failure: `caret left behind after the redo`.
  const insertAtCaret = (text: string): void => typeAt(view.state.selection.main.head, text);

  it('a caret inside the dragged chapter: after undo and redo, text typed at it lands in the chapter at its new place', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    loadFresh(start.text);
    caretAfter('Text of chapter 2.');
    expect(clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4'))).ok).toBe(true);
    expect(structuralUndo().ok).toBe(true);
    expect(docText()).toBe(start.text);
    expect(structuralRedo('the Cmd-Shift-Z was not routed structural').ok).toBe(true);

    insertAtCaret(' typed');

    expect(docText(), 'caret left behind after the redo').toBe(
      build([...ch(1), ...ch(3), ...ch(2, 'Text of chapter 2. typed'), ...ch(4)]).text
    );
  });

  it('the caret was moved by the user between the Cmd-Z and the Cmd-Shift-Z: that caret is kept (mapped), not overwritten', () => {
    const start = build([...ch(1), ...ch(2), ...ch(3), ...ch(4)]);
    loadFresh(start.text);
    caretAfter('Text of chapter 2.');
    expect(clickReorder(start, 'h2', planOf(moveRun(idsOf(start), ['h2'], 'h4'))).ok).toBe(true);
    expect(structuralUndo().ok).toBe(true);
    caretAfter('Text of chapter 4.'); // the user clicked elsewhere
    expect(structuralRedo('the Cmd-Shift-Z was not routed structural').ok).toBe(true);

    insertAtCaret(' typed');

    expect(docText(), 'the caret the user set was overwritten').toBe(
      build([...ch(1), ...ch(3), ...ch(2), ...ch(4, 'Text of chapter 4. typed')]).text
    );
  });
});

// =============================================================================================================================
// Review round (V1): the settle's renumber sorts the Notes definitions in the same transaction
// =============================================================================================================================

/** The footnote labels of the `[^N]:` definition lines in `text`, in text order (numbers where the label is one). */
function definitionLabels(text: string): Array<number | string> {
  const labels: Array<number | string> = [];
  for (const line of text.split('\n')) {
    const match = /^\[\^([^\]\s]+)\]:/.exec(line);
    if (match) labels.push(/^\d+$/.test(match[1]) ? Number(match[1]) : match[1]);
  }
  return labels;
}

/** Four chapters with three footnote references each (labels 1 to 12 in text order) and a Notes region, one definition per label. */
const refsOf = (chapter: number): number[] => [1, 2, 3].map((k) => (chapter - 1) * 3 + k);
const chapterBody = (n: number, labels: number[]): string =>
  labels.map((label, k) => `Chapter ${n} sentence ${k + 1}.[^${label}]`).join(' ');
/** The definition of ORIGINAL label `orig`: label 5 has a second line and a second paragraph, label 8 a tab-indented line. */
function noteText(orig: number): string {
  const chapter = Math.ceil(orig / 3);
  const point = ((orig - 1) % 3) + 1;
  const first = `[^${orig}]: Note ${chapter}.${point}, first line.`;
  if (orig === 5)
    return `${first}\n    Its second line, indented four spaces.\n\n    A second paragraph of the same note.`;
  if (orig === 8) return `${first}\n\tIts tab-indented line.`;
  return first;
}
const notesHeading: Block = { kind: 'leader', id: 'hn', level: 1, title: 'Notes', managed: 'notes' };
const allLabels = Array.from({ length: 12 }, (_, i) => i + 1);

function notedBook(extraNotes: Block[] = [], before: Block[] = []): Built {
  const chapters = [1, 2, 3, 4].flatMap((n) => ch(n, chapterBody(n, refsOf(n))));
  const notes: Block[] = allLabels.map((label) => ({ kind: 'text', text: noteText(label) }));
  return build([...before, ...chapters, notesHeading, ...notes.slice(0, 6), ...extraNotes, ...notes.slice(6)]);
}

/** Chapter three dragged in front of chapter two: the references now read 1-3, 7-9, 4-6, 10-12 and the settle renumbers them. */
const SETTLE_MAPPING: Record<string, string> = { '7': '4', '8': '5', '9': '6', '4': '7', '5': '8', '6': '9' };
const oldLabelOf = (label: number): number =>
  Number(Object.entries(SETTLE_MAPPING).find(([, now]) => Number(now) === label)?.[0] ?? label);

/** The document the settle must leave: references renumbered in text order, the definitions sorted with their own text. */
function settledBook(): string {
  const notes: Block[] = allLabels.map((label) => ({
    kind: 'text',
    text: noteText(oldLabelOf(label)).replace(`[^${oldLabelOf(label)}]:`, `[^${label}]:`),
  }));
  return build([
    ...ch(1, chapterBody(1, [1, 2, 3])),
    ...ch(3, chapterBody(3, [4, 5, 6])),
    ...ch(2, chapterBody(2, [7, 8, 9])),
    ...ch(4, chapterBody(4, [10, 11, 12])),
    notesHeading,
    ...notes,
  ]).text;
}

function dragChapterThree(start: Built): void {
  expect(clickReorder(start, 'h3', planOf(moveRun(idsOf(start), ['h3'], 'h2'))).ok).toBe(true);
}

describe('W-R20 the settle renumber also sorts the Notes definitions, in the same transaction', () => {
  // Break patch (W-R20.patch): in `renumberWithSortedNotes` (notes-region-sort.ts) return null at once (relabel only, as before the cure).
  // Predicted failure: `Notes definitions out of order: [1,2,3,7,8,9,4,5,6,10,11,12]`.
  it('flag set and the Notes heading line given: definitions in numeric order with their continuation lines, one transaction, no history step', () => {
    const start = notedBook();
    loadFresh(start.text);
    dragChapterThree(start);
    const depth = undoDepth(view.state);
    const dispatchSpy = vi.spyOn(view, 'dispatch');

    ffu().setStructuralSettleOpId(OP, '# Notes');
    ffu().renumberFootnotes(SETTLE_MAPPING);
    ffu().setStructuralSettleOpId(null, OP);
    const dispatched = dispatchSpy.mock.calls.length;
    dispatchSpy.mockRestore();

    const labels = definitionLabels(docText());
    expect(labels, `Notes definitions out of order: [${labels}]`).toEqual(allLabels);
    expect(docText()).toBe(settledBook()); // continuation lines stay with their definition; outside the region only labels changed
    expect(dispatched, 'the renumber was more than one transaction').toBe(1);
    expect(undoDepth(view.state), 'renumber added an undo step').toBe(depth);
    expect(getRegistry().get(OP)?.postOpDoc.eq(view.state.doc)).toBe(true);
  });

  it('the drag still undoes and redoes: Cmd-Z gives the original book, Cmd-Shift-Z the sorted, renumbered one', () => {
    const start = notedBook();
    loadFresh(start.text);
    dragChapterThree(start);
    ffu().setStructuralSettleOpId(OP, '# Notes');
    ffu().renumberFootnotes(SETTLE_MAPPING);
    ffu().setStructuralSettleOpId(null, OP);

    expect(structuralUndo().ok).toBe(true);
    expect(docText()).toBe(start.text);
    const redone = structuralRedo('the Cmd-Shift-Z was not routed structural');
    expect(redone.ok, JSON.stringify(redone)).toBe(true);
    expect(docText()).toBe(settledBook());
  });
});

describe('W-R20b PIN: without the heading line, or with the flag cleared, the renumber is exactly what it was', () => {
  // PIN: these behaviours are the old ones and pass with and without the cure.
  const relabelledOnly = [1, 2, 3, 7, 8, 9, 4, 5, 6, 10, 11, 12];

  it('flag set, no heading line: relabelled in place, no sort, not a history step', () => {
    const start = notedBook();
    loadFresh(start.text);
    dragChapterThree(start);
    const depth = undoDepth(view.state);

    ffu().setStructuralSettleOpId(OP);
    ffu().renumberFootnotes(SETTLE_MAPPING);
    ffu().setStructuralSettleOpId(null, OP);

    expect(definitionLabels(docText())).toEqual(relabelledOnly);
    expect(undoDepth(view.state)).toBe(depth);
  });

  it.each([
    ['the flag was never set', () => undefined],
    [
      'the flag (with its heading line) was cleared before the renumber',
      () => {
        ffu().setStructuralSettleOpId(OP, '# Notes');
        ffu().setStructuralSettleOpId(null, OP);
      },
    ],
  ] as Array<[string, () => void]>)('%s: relabelled in place, no sort, its own undo step', (_label, prepare) => {
    const start = notedBook();
    loadFresh(start.text);
    dragChapterThree(start);
    const depth = undoDepth(view.state);
    prepare();

    ffu().renumberFootnotes(SETTLE_MAPPING);

    expect(definitionLabels(docText())).toEqual(relabelledOnly);
    expect(undoDepth(view.state)).toBe(depth + 1);
  });
});

describe('W-R20c PIN: a Notes region that is not just definitions is relabelled only', () => {
  const relabelledOnly = [1, 2, 3, 7, 8, 9, 4, 5, 6, 10, 11, 12];
  const labelsBlanked = (text: string): string => text.replace(/\[\^[^\]\s]+\]/g, '[^#]');
  const strayProse: Block = { kind: 'text', text: 'A stray line of prose.' };

  it.each([
    ['a prose line between two definitions', '# Notes', [strayProse], []],
    ['a heading line that is not in the document', '## Anmerkungen', [], []],
    [
      'a second heading with the same text as the Notes heading',
      '# Notes',
      [],
      ch(0, 'A chapter that is called Notes too.', { title: 'Notes' }),
    ],
  ] as Array<[string, string, Block[], Block[]]>)('%s', (_label, headingLine, extraNotes, before) => {
    const start = notedBook(extraNotes, before);
    loadFresh(start.text);
    dragChapterThree(start);
    const afterDrag = docText();

    ffu().setStructuralSettleOpId(OP, headingLine);
    ffu().renumberFootnotes(SETTLE_MAPPING);
    ffu().setStructuralSettleOpId(null, OP);

    expect(definitionLabels(docText())).toEqual(relabelledOnly);
    expect(labelsBlanked(docText()), 'text other than labels changed').toBe(labelsBlanked(afterDrag));
  });
});

// =============================================================================================================================
// Review round (R4): a dragged chapter whose body holds the real document shapes
// =============================================================================================================================

describe('R4 the dragged chapter holds real document shapes: nothing is cut inside a fence, a math block, a table or a definition', () => {
  // The leaders below are what BlockParser reports for these shapes (BlockParser+Splitting.swift, `RawBlockSplitter`): a "# x" line
  // inside a ``` fence or a `$$` block is part of that block, not a heading; `##` + U+3000 + text is a heading (ICU white space after the
  // run); a table, a `[^1]:` definition with its indented continuation lines, and a CJK heading are ordinary. A section break is a
  // level-1 leader of its own. The page reads the same text with its own line scan, and the click is refused (`leadersMismatch`) when the
  // two disagree on the count or on any heading line, so a scan that treated an in-fence line as a heading fails every case here.
  // Break patch (R4a.patch): in `scanDocument` (api-structural-markdown.ts) a ``` line no longer opens a fence (`fence = null;`).
  // Break patch (R4b.patch): in `scanDocument` a `$$` line no longer opens display math (`inMath = false;` where it is set).
  // Predicted failure: `the click was refused` (leadersMismatch) for every case whose chapter holds the fence / the math block.
  const fence: Block = { kind: 'text', text: '```\n# not a heading\n\nstill code\n## also not a heading\n```' };
  const math: Block = { kind: 'text', text: '$$\n# not a heading either\n\nx = y\n$$' };
  const table: Block = { kind: 'text', text: '| a | b |\n|---|---|\n| 1 | 2 |' };
  const definition: Block = {
    kind: 'text',
    text: '[^1]: A definition in the body.\n    Its continuation, indented four spaces.\n\n    And a second paragraph of the same definition.',
  };
  const subHeadings: Block[] = [
    { kind: 'leader', id: 'hdcjk', level: 2, title: '第二章 方法' },
    { kind: 'text', text: 'Text under the CJK heading.' },
    { kind: 'leader', id: 'hdwide', level: 2, title: 'unused', rawLine: '##　全角標題' },
    { kind: 'text', text: 'Text under the full-width heading.' },
  ];
  const shapeSets: Array<[string, Block[], string[]]> = [
    ['a fence holding # lines and a blank line', [fence], ['hd']],
    ['a $$ block holding a # line and a blank line', [math], ['hd']],
    ['a table', [table], ['hd']],
    ['a body definition with a four-space continuation and a second paragraph', [definition], ['hd']],
    ['a CJK heading and a ##+U+3000 heading (an Option drag takes them along)', subHeadings, ['hd', 'hdcjk', 'hdwide']],
    [
      'all of them together',
      [fence, math, ...subHeadings.slice(0, 2), table, ...subHeadings.slice(2), definition],
      ['hd', 'hdcjk', 'hdwide'],
    ],
  ];
  const placements: Array<[string, string | null, (a: Block[], br: Block[], d: Block[], b: Block[]) => Block[][]]> = [
    ['up, above the section break', 'br', (a, br, d, b) => [a, d, br, b]],
    ['up, above chapter 1', 'h1', (a, br, d, b) => [d, a, br, b]],
    ['down, below chapter 3 and in front of the Notes', 'hn', (a, br, d, b) => [a, br, b, d]],
  ];

  describe.each(shapeSets)('%s', (_shape, bodyBlocks, runIds) => {
    it.each(placements)('%s', (_placement, before, arrange) => {
      const chapter: Block[] = [
        { kind: 'leader', id: 'hd', level: 1, title: 'Chapter D' },
        { kind: 'text', text: 'Intro paragraph of the dragged chapter.' },
        ...bodyBlocks,
      ];
      const first = ch(1);
      const breakSection: Block[] = [
        { kind: 'break', id: 'br' },
        { kind: 'text', text: 'Text after the break.' },
      ];
      const last = ch(3);
      const start = build([...first, ...breakSection, ...chapter, ...last, ...region()]);
      loadFresh(start.text);

      const result = clickReorder(start, 'hd', planOf(moveRun(idsOf(start), runIds, before)));

      expect(result.ok, `the click was refused: ${JSON.stringify(result)}`).toBe(true);
      const expected = build([...arrange(first, breakSection, chapter, last).flat(), ...region()]).text;
      expect(docText(), 'the chapter was cut or reordered wrongly').toBe(expected);
    });
  });

  it('the chapter hopped over holds the shapes: a plain drag of chapter 3 above it leaves them intact', () => {
    const chapter: Block[] = [
      { kind: 'leader', id: 'hd', level: 1, title: 'Chapter D' },
      { kind: 'text', text: 'Intro paragraph.' },
      fence,
      math,
      table,
      definition,
    ];
    const start = build([...ch(1), ...chapter, ...ch(3), ...region()]);
    loadFresh(start.text);

    const result = clickReorder(start, 'h3', planOf(moveRun(idsOf(start), ['h3'], 'hd')));

    expect(result.ok, `the click was refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText(), 'the chapter was cut or reordered wrongly').toBe(
      build([...ch(1), ...ch(3), ...chapter, ...region()]).text
    );
  });
});

describe('W-R20d the heading line lives and dies with its flag', () => {
  // Break patch (W-R20d1.patch): in `setStructuralSettleOpId` a set without a heading line keeps the earlier settle's heading line.
  // Predicted failure: `a later settle inherited the earlier heading line`.
  // Break patch (W-R20d2.patch): in `setStructuralSettleOpId` a compare-and-clear that does not match still forgets the heading line.
  // Predicted failure: `the earlier settle's clear dropped the later settle's heading line`.
  const relabelledOnly = [1, 2, 3, 7, 8, 9, 4, 5, 6, 10, 11, 12];

  it('a settle that gives no heading line does not inherit the one a settle before it gave', () => {
    const start = notedBook();
    loadFresh(start.text);
    dragChapterThree(start);
    ffu().setStructuralSettleOpId(OP, '# Notes');
    ffu().setStructuralSettleOpId(EARLIER_OP); // the next settle starts before the first one cleared, and names no heading line

    ffu().renumberFootnotes(SETTLE_MAPPING);

    expect(definitionLabels(docText()), 'a later settle inherited the earlier heading line').toEqual(relabelledOnly);
  });

  it("an earlier settle's compare-and-clear leaves the later settle's flag and heading line in place", () => {
    const start = notedBook();
    loadFresh(start.text);
    dragChapterThree(start);
    ffu().setStructuralSettleOpId(OP, '# Notes');
    ffu().setStructuralSettleOpId(EARLIER_OP, '# Notes');
    ffu().setStructuralSettleOpId(null, OP); // the first settle ends: the flag now belongs to the second

    ffu().renumberFootnotes(SETTLE_MAPPING);

    expect(definitionLabels(docText()), "the earlier settle's clear dropped the later settle's heading line").toEqual(
      allLabels
    );
  });
});
