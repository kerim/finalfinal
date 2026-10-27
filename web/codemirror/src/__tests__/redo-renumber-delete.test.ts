// @vitest-environment jsdom
//
// Redo steps that two other writers of the document must not wipe or misplace (t-14f908b4, Round B2):
//
//   T-R2 / T-R3 / T-R4   the footnote renumber OUTSIDE a structural settle (`renumberFootnotes` with the settle flag null). It is a
//                        RECORDED change (`derivedCorrection`), and @codemirror/commands empties the redo list on any recorded change.
//                        The user typed, took the typing back with Cmd-Z, and the app's renumber landed: Cmd-Shift-Z must still bring the
//                        typing back (T-R2, T-R4: several events, in order), and the renumber must be its own undo step that the next
//                        keystroke does not join (T-R3).
//   W-R22                the Markdown editor-first DELETE clicked while a redo event is already waiting. The click maps both history
//                        branches through the removal with addToHistory:false, and an insertion inside the removed section lands at the
//                        removal point, the start of the next chapter's heading line (the reorder's M6 twin, W-R21).
//
// These tests drive the REAL page: they import the real main.ts (the real extension set, update listeners, capture-phase Cmd-Z interceptor
// and window.FinalFinal) into jsdom, as structural-markdown.test.ts does. Cmd-Z / Cmd-Shift-Z are real KeyboardEvents.
//
// Break patches (one file per test in the run notes' patches folder, 1-5 changed lines): T-R2 / T-R4 "do not keep the list" (api.ts
// `renumberFootnotes`: `const keptRedo = null as ReturnType<typeof keepRedoList>;`), T-R3 "no isolateHistory on the renumber", W-R22
// "no trim in runDelete".

import { redoDepth, undoDepth } from '@codemirror/commands';
import { getSearchQuery, SearchQuery, setSearchQuery } from '@codemirror/search';
import { ChangeSet, Text } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MarkdownLeader, MarkdownStructuralRequest, MarkdownStructuralResult } from '../api-structural-markdown';

type FF = {
  setContent: (md: string, options?: unknown) => void;
  setUndoDescriptor: (d: { undoTopOpId?: string; redoTopOpId?: string }) => void;
  resetForProjectSwitch: () => void;
  clearStructuralUndoRegistry: () => void;
  renumberFootnotes: (mapping: Record<string, string>) => void;
  markdownStructuralEditorFirst: (request: string | object) => MarkdownStructuralResult;
  markdownStructuralSwap: (opId: string, direction: 'undo' | 'redo') => MarkdownStructuralResult;
};
const ff = (): FF => (window as any).FinalFinal as FF;

const OP = '11111111-2222-3333-4444-555555555555';

let structuralUndoRequested: ReturnType<typeof vi.fn>;
let structuralRedoRequested: ReturnType<typeof vi.fn>;
let traces: string[];
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

// --- Documents in the shape the Markdown editor shows (blocks separated by a blank line, an anchor in front of every heading) ---

type Block = { kind: 'leader'; id: string; level: number; title: string } | { kind: 'text'; text: string };

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

function build(blocks: Block[]): Built {
  const parts: string[] = [];
  const leaders: MarkdownLeader[] = [];
  for (const b of blocks) {
    if (b.kind === 'text') {
      parts.push(b.text);
    } else {
      const line = `${'#'.repeat(b.level)} ${b.title}`;
      parts.push(`<!-- @sid:${sid(b.id)} -->${line}`);
      leaders.push({ id: b.id, line, level: b.level });
    }
  }
  return { text: `${parts.join('\n\n')}\n`, leaders, blocks };
}

const ch = (n: number, body = `Text of chapter ${n}.`): Block[] => [
  { kind: 'leader', id: `h${n}`, level: 1, title: `Chapter ${n}` },
  { kind: 'text', text: body },
];

/** The request Swift would send for deleting `rootId` (a document without Notes or Bibliography: no stopLine). */
function requestFor(built: Built, rootId: string): MarkdownStructuralRequest {
  const rootIdx = built.leaders.findIndex((leader) => leader.id === rootId);
  const rootLevel = built.leaders[rootIdx].level;
  const endLeader = built.leaders.find((leader, i) => i > rootIdx && leader.level <= rootLevel);
  return {
    kind: 'delete',
    opId: OP,
    rootId,
    leaders: built.leaders,
    stopLine: null,
    endLeaderId: endLeader ? endLeader.id : null,
  };
}

/** The click, then what Swift does once the entry is recorded: push the descriptor. */
function clickDelete(built: Built, rootId: string): MarkdownStructuralResult {
  const result = ff().markdownStructuralEditorFirst(JSON.stringify(requestFor(built, rootId)));
  if (result.ok) ff().setUndoDescriptor({ undoTopOpId: OP });
  return result;
}

/** Every heading line: `# ...` at the start of the line or right behind the section anchor comment. */
const headingLines = (text: string): string[] => text.split('\n').filter((line) => /(?:^|-->)#{1,6} /.test(line));

function load(text: string): void {
  // A fresh document with fresh text history, exactly as opening a project does, then the starting text; empty structural-undo state.
  resetUndoCoordinatorState();
  resetRecentUserEditSpan();
  ff().clearStructuralUndoRegistry();
  ff().resetForProjectSwitch();
  ff().setContent(text);
  ff().resetForProjectSwitch();
  view = currentView();
  structuralUndoRequested.mockClear();
  structuralRedoRequested.mockClear();
  traces.length = 0;
  expect(docText()).toBe(text);
  expect(undoDepth(view.state)).toBe(0);
  expect(redoDepth(view.state)).toBe(0);
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

  structuralUndoRequested = vi.fn();
  structuralRedoRequested = vi.fn();
  traces = [];
  (window as any).webkit = {
    messageHandlers: {
      structuralUndoRequested: { postMessage: structuralUndoRequested },
      structuralRedoRequested: { postMessage: structuralRedoRequested },
      structuralUndoRefused: { postMessage: vi.fn() },
      historyEdited: { postMessage: vi.fn() },
      contentChanged: { postMessage: vi.fn() },
      sectionChanged: { postMessage: vi.fn() },
      undoHeldPressSettled: { postMessage: vi.fn() },
      undoQueueDropped: { postMessage: vi.fn() },
      errorHandler: {
        postMessage: (m: { message?: string }) => {
          if (m?.message) traces.push(m.message);
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

// =============================================================================================================================
// The footnote renumber outside a structural settle
// =============================================================================================================================

/** Three paragraphs, two footnote references and their Notes definitions, in the shape the Markdown editor shows. */
const FOOTNOTED = [
  '# Title',
  'First paragraph.[^1]',
  'Second paragraph.[^2]',
  'Third paragraph.',
  '[^1]: Note one.',
  '[^2]: Note two.',
].join('\n\n');

/** `text` with the labels the renumber {1 -> 11, 2 -> 12} gives. Longer labels, so every position after a reference shifts. */
const relabelled = (text: string): string => text.replaceAll('[^1]', '[^11]').replaceAll('[^2]', '[^12]');
const RENUMBER = { '1': '11', '2': '12' };

describe('T-R2 a recorded footnote renumber keeps the redo list', () => {
  // Break patch (T-R2.patch): in `renumberFootnotes` (api.ts) replace `const keptRedo = recorded ? keepRedoList(view.state) : null;` by
  // `const keptRedo = null as ReturnType<typeof keepRedoList>;` (the list the renumber emptied is not put back).
  // Predicted failure: `the renumber emptied the redo list: expected +0 to be 1` (the first case; the second:
  // `the typing is not back in front of its reference`).
  it('type, Cmd-Z, the renumber lands (flag null), Cmd-Shift-Z: the typing is back and the labels are renumbered', () => {
    load(FOOTNOTED);
    typeAfter('Third paragraph.', ' TYPED');
    const typed = docText();
    press('undo');
    expect(docText(), 'PREMISE: Cmd-Z took the typing back').toBe(FOOTNOTED);
    expect(redoDepth(view.state), 'PREMISE: the typing waits in the redo list').toBe(1);

    ff().renumberFootnotes(RENUMBER); // the app's footnote resync, outside a settle: a recorded change
    expect(docText(), 'PREMISE: the labels are renumbered').toBe(relabelled(FOOTNOTED));
    expect(redoDepth(view.state), 'the renumber emptied the redo list').toBe(1);

    press('redo');
    expect(structuralRedoRequested, 'PREMISE: the Cmd-Shift-Z was a text redo').not.toHaveBeenCalled();
    expect(docText(), 'the typing is not back after the renumber').toBe(relabelled(typed));
    expect(
      traces.some((m) => m.includes('redo list was not kept')),
      'the redo list was refused'
    ).toBe(false);
  });

  it('typing right in front of a reference, Cmd-Z, the renumber, Cmd-Shift-Z: the typing is back where it was, in front of the reference', () => {
    // An insertion at the START of a relabelled marker must not be mapped behind the new marker.
    load(FOOTNOTED);
    const at = docText().indexOf('[^1]');
    typeAt(at, ' TYPED');
    const typed = docText();
    press('undo');
    expect(docText()).toBe(FOOTNOTED);

    ff().renumberFootnotes(RENUMBER);
    press('redo');

    expect(docText(), 'the typing is not back in front of its reference').toBe(relabelled(typed));
  });

  it('control: with nothing to redo the renumber is just its own undo step (Cmd-Z takes the renumber, the next one the typing)', () => {
    load(FOOTNOTED);
    typeAfter('Third paragraph.', ' TYPED');
    const typed = docText();
    ff().renumberFootnotes(RENUMBER);
    expect(undoDepth(view.state)).toBe(2);
    expect(traces.some((m) => m.includes('redo list was not kept'))).toBe(false);
    press('undo');
    expect(docText()).toBe(typed);
    press('undo');
    expect(docText()).toBe(FOOTNOTED);
  });
});

describe('T-R3 the renumber is its own undo step: the next keystroke does not join it', () => {
  // Break patch (T-R3.patch): in `renumberFootnotes` (api.ts) drop `isolateHistory.of('full')` from the recorded annotations.
  // Predicted failure: `Cmd-Z took the renumber back with the typing`.
  it('the renumber, then one character typed right behind a renumbered marker, then Cmd-Z once: only the character goes', () => {
    load(FOOTNOTED);
    ff().renumberFootnotes(RENUMBER);
    const renumbered = docText();
    expect(renumbered).toBe(relabelled(FOOTNOTED));

    typeAfter('Second paragraph.[^12]', 'x'); // adjacent to the marker the renumber just wrote, well inside the 500 ms joining window
    press('undo');

    expect(docText(), 'Cmd-Z took the renumber back with the typing').toBe(renumbered);
  });

  it('one character typed right behind a marker, then the renumber lands, then Cmd-Z once: only the renumber goes', () => {
    load(FOOTNOTED);
    typeAfter('Second paragraph.[^2]', 'x');
    const typed = docText();
    ff().renumberFootnotes(RENUMBER);

    press('undo');

    expect(docText(), 'Cmd-Z took the typing back with the renumber').toBe(typed);
  });
});

describe('T-R4 several redo events survive the renumber, in order', () => {
  // Break patch (T-R4.patch): as T-R2.
  // Predicted failure: `the renumber emptied the redo list: expected +0 to be 2`.
  it('type two sentences, Cmd-Z twice, the renumber lands, Cmd-Shift-Z twice: both are back, the first typed first', () => {
    load(FOOTNOTED);
    typeAfter('Second paragraph.[^2]', ' ONE');
    typeAfter('Third paragraph.', ' TWO');
    expect(undoDepth(view.state), 'PREMISE: two separate history events').toBe(2);
    const typedBoth = docText();
    press('undo');
    press('undo');
    expect(docText(), 'PREMISE: both sentences are taken back').toBe(FOOTNOTED);
    expect(redoDepth(view.state), 'PREMISE: both wait in the redo list').toBe(2);

    ff().renumberFootnotes(RENUMBER);
    expect(redoDepth(view.state), 'the renumber emptied the redo list').toBe(2);

    press('redo');
    expect(docText(), 'the first sentence is not back').toBe(relabelled(FOOTNOTED).replace('[^12]', '[^12] ONE'));
    press('redo');
    expect(docText(), 'the second sentence is not back').toBe(relabelled(typedBoth));
    expect(redoDepth(view.state)).toBe(0);
  });
});

// =============================================================================================================================
// The Delete click with a redo event already waiting
// =============================================================================================================================

describe('W-R22 a redo event already pending when the Delete is clicked never lands in a heading line', () => {
  // The reviewer's probe twin of W-R21: typing inside chapter 2 and taking it back with Cmd-Z leaves one event in the editor's redo list.
  // The Delete is then clicked with addToHistory:false, which maps both history branches through the removal, and an insertion inside
  // the removed section lands at the removal point -- the start of the line that follows it, chapter 3's heading line (in front of its
  // anchor). Cmd-Shift-Z (no structural redo is on top: this is the editor's own text redo) would type the sentence into that heading line.
  // Break patch (W-R22.patch): in `runDelete` (api-structural-markdown.ts) replace the `withoutRedoEventsTouching(...)` call by `null`.
  // Predicted failure: `heading line changed by a redo`.
  it('type in chapter 2, Cmd-Z, delete chapter 2, Cmd-Shift-Z: every heading line reads as after the delete, the typing is on none', () => {
    const built = build([...ch(1), ...ch(2), ...ch(3)]);
    load(built.text);
    typeAfter('Text of chapter 2.', ' X');
    press('undo'); // the typing: one event waits in the redo list
    expect(docText()).toBe(built.text);
    expect(redoDepth(view.state), 'PREMISE: the typing waits in the redo list').toBe(1);
    expect(clickDelete(built, 'h2').ok, 'PREMISE: the Delete went through').toBe(true);
    const post = docText();
    expect(headingLines(post), 'PREMISE: chapter 2 is gone').toHaveLength(2);

    press('redo'); // not routed structural: the editor's own text redo

    expect(structuralRedoRequested, 'PREMISE: the Cmd-Shift-Z was a text redo').not.toHaveBeenCalled();
    expect(headingLines(docText()), 'heading line changed by a redo').toEqual(headingLines(post));
    const typedOnHeading = docText()
      .split('\n')
      .filter((line) => line.includes(' X') && /(?:^|-->)#{1,6} /.test(line));
    expect(typedOnHeading, 'the typing landed on a heading line').toEqual([]);
  });

  it('control: an event typed OUTSIDE the deleted section is still redone after the Delete', () => {
    const built = build([...ch(1), ...ch(2), ...ch(3)]);
    load(built.text);
    typeAfter('Text of chapter 1.', ' X');
    press('undo');
    expect(redoDepth(view.state)).toBe(1);
    expect(clickDelete(built, 'h2').ok).toBe(true);
    const post = docText();

    press('redo');

    expect(docText(), 'the typing outside the deleted section is not back').toBe(
      post.replace('Text of chapter 1.', 'Text of chapter 1. X')
    );
  });
});

// =============================================================================================================================
// What every state install keeps: the scroll position (P1) and the search query (P2)
// =============================================================================================================================

describe('P1 an install that keeps the document keeps the scroll position', () => {
  // Code review BR-F1: `view.setState` rebuilds the DocView and loses the scroll position; a scroll-to-caret afterwards would pull the
  // page back to the caret when Swift's timer lands a renumber while the user is looking elsewhere. jsdom has no layout, so the test pins
  // the mechanism: the installs that keep the document take `scrollSnapshot()` before the swap, the structural undo swap does not.
  // Break patch (P1.patch): in `installState` (api-structural-markdown.ts) make `if (keepScroll)` read `if (keepScroll && false)`.
  // Predicted failure: `the renumber-keep took no scroll snapshot`.
  it('the renumber-keep and the Delete click trim take a scroll snapshot; the structural undo swap does not', () => {
    load(FOOTNOTED);
    typeAfter('Third paragraph.', ' TYPED');
    press('undo');
    const keepSnapshot = vi.spyOn(view, 'scrollSnapshot');
    ff().renumberFootnotes(RENUMBER);
    expect(keepSnapshot, 'the renumber-keep took no scroll snapshot').toHaveBeenCalledTimes(1);
    keepSnapshot.mockRestore();

    const built = build([...ch(1), ...ch(2), ...ch(3)]);
    load(built.text);
    typeAfter('Text of chapter 2.', ' X');
    press('undo'); // one event waits in the redo list, inside the section the click removes
    const trimSnapshot = vi.spyOn(view, 'scrollSnapshot');
    expect(clickDelete(built, 'h2').ok).toBe(true);
    expect(trimSnapshot, 'the Delete click trim took no scroll snapshot').toHaveBeenCalledTimes(1);
    trimSnapshot.mockClear();

    press('undo'); // routed structural
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    expect(trimSnapshot, 'the structural undo swap must scroll the caret into view instead').not.toHaveBeenCalled();
    trimSnapshot.mockRestore();
  });
});

describe('P4b the two forms of a renumber give one document', () => {
  // The renumber dispatches whole-marker replacements, and a waiting redo list is mapped through the SAME edits cut down to the label
  // characters that differ (`relabelChange`). That is only sound while both forms produce exactly the same document, so this pins it:
  // applied to the old text, the dispatched edits, the label-only edits and the document the real renumber leaves must all equal the
  // text the mapping describes (derived here by a plain regex replace, not from the code under test). Cases cover a label whose digit
  // count grows ([^9] -> [^10]), one that stays ([^3] -> [^4]), one that shrinks, shared prefix and suffix, several labels at once,
  // and definitions.
  // Break patch (P4b.patch): in `relabelChange` (api.ts) make `from` read `labelStart + head + 1` (a label-only range that is off by one).
  // Predicted failure: `the label-only edits do not give the renumbered text`.
  let renumberEdits: (
    content: string,
    mapping: Record<string, string>
  ) => {
    changes: Array<{ from: number; to: number; insert: string }>;
    relabels: Array<{ from: number; to: number; insert: string }>;
  };
  beforeAll(async () => {
    ({ renumberEdits } = await import('../api'));
  });

  const applyEdits = (text: string, edits: Array<{ from: number; to: number; insert: string }>): string =>
    ChangeSet.of(edits, text.length)
      .apply(Text.of(text.split('\n')))
      .toString();
  /** What a renumber means: every `[^label]` marker whose label is in the mapping gets its new label, simultaneously. */
  const renumbered = (text: string, mapping: Record<string, string>): string =>
    text.replace(/\[\^([^\]]+)\]/g, (marker, label: string) => (label in mapping ? `[^${mapping[label]}]` : marker));

  it.each([
    ['the digit count grows', 'One.[^9] two.[^9]\n\n[^9]: Note nine.\n', { '9': '10' }],
    ['the digit count stays', 'One.[^3] two.[^3] and [^30].\n\n[^3]: Note three.\n', { '3': '4' }],
    ['the digit count shrinks', 'One.[^10] two.\n\n[^10]: Note ten.\n', { '10': '9' }],
    ['shared prefix and suffix', 'A.[^12] B.[^1] C.[^21]\n\n[^12]: x\n', { '12': '112', '1': '11', '21': '221' }],
    [
      'several labels at once, both ways',
      'A.[^1] B.[^2] C.[^3]\n\n[^1]: a\n\n[^2]: b\n\n[^3]: c\n',
      { '1': '2', '2': '3', '3': '1' },
    ],
    ['a name label', 'A.[^note] B.[^2]\n', { note: 'notes', '2': '5' }],
  ] as Array<[string, string, Record<string, string>]>)('P4b: %s', (_name, text, mapping) => {
    const expected = renumbered(text, mapping);
    const { changes, relabels } = renumberEdits(text, mapping);
    expect(expected, 'PREMISE: the mapping changes something').not.toBe(text);

    expect(applyEdits(text, changes), 'the dispatched whole-marker edits do not give the renumbered text').toBe(
      expected
    );
    expect(applyEdits(text, relabels), 'the label-only edits do not give the renumbered text').toBe(expected);

    load(text);
    ff().renumberFootnotes(mapping); // the real dispatch (the settle flag is null)
    expect(docText(), 'the document the real renumber leaves is not the renumbered text').toBe(expected);
    expect(docText(), 'the real renumber and the label-only edits disagree').toBe(applyEdits(text, relabels));
  });
});

describe('P2 the search query survives a state install', () => {
  // Code review BR-F2: the new state initialises the CodeMirror search field empty while api.ts keeps its own module copy of the query,
  // so Find Next / Find Previous found nothing after any install. The query is carried across through `CARRIED_STATE`.
  // Break patch (P2.patch): in `CARRIED_STATE` (api-structural-markdown.ts) make `if (query.search !== '')` read
  // `if (query.search !== '' && false)`. Predicted failure: `the search query was lost by the install`.
  it('a query set before the renumber-keep is still the query afterwards', () => {
    load(FOOTNOTED);
    typeAfter('Third paragraph.', ' TYPED');
    press('undo');
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: 'paragraph' })) });
    expect(getSearchQuery(view.state).search, 'PREMISE: the query is set').toBe('paragraph');

    ff().renumberFootnotes(RENUMBER); // a recorded change with a waiting list: the list is kept through a state install

    expect(redoDepth(view.state), 'PREMISE: the install happened').toBe(1);
    expect(getSearchQuery(view.state).search, 'the search query was lost by the install').toBe('paragraph');
  });
});
