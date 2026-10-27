// @vitest-environment jsdom
//
// Redo after a structural operation, Markdown mode (t-14f908b4). Permanent tests: each states the behaviour the user is owed and runs the
// everyday sequence, so a red test means the bug is back.
//
// The sequence, for Duplicate Section as Markdown mode does it TODAY: Swift opens the entry (`beginStructuralOp`), replaces the whole
// document (`setContent`), and records the post-op copy (`finalizeStructuralOpPostOpDoc`). The entry therefore has no `markdown`
// extras, so its Cmd-Z is `markdownStructuralSwap('undo')` (the checkpoint swap, with the live redo branch mapped through a LINE DIFF
// of the live document against the checkpoint, minus every event that lies inside a span that diff removes) and its Cmd-Shift-Z is
// `markdownStructuralSwap('redo')` (`swapRedoFromSavedCopy`, a minimal line diff to the saved post-op copy, outside the text history).
// The undo sets the full live redo branch aside and the redo puts it back (redo-branch.ts `putBackRedo`), so what the user typed
// inside the copy is redone. The user types, presses Cmd-Z twice (the typing, then the duplicate) and Cmd-Shift-Z twice (the
// duplicate, then the typing). The typed text must be back, where it was typed, and every heading line must read as it did right
// after the typing.
//
//   RP3a  typing inside the COPY        RP3b  typing inside the ORIGINAL, after the duplicate
//   RP3c  as RP3a on a book-sized document (chapters of 600 lines): the prefix/suffix trimming of the line diff already isolates exactly
//         the copy, so this is not a collapsed-span case; it still runs the old-body route on a book-sized document
//   RP3d  (control) typing BEFORE the duplicate
//   MR1   two full cycles                MR2   a restore (old-body whole-document replace) that changes a paragraph
//   MR3   anchors injected before / AFTER the typing                MR4   a footnote reference on the line that holds the typing
//   MR6   fall-back: the put-back is refused, the carried list is used: nothing lands in a heading line
//   MR10  undo past the operation into earlier typing, then redo everything          MR11  two operations in a row
//   MR12  typing in the copy THEN in the original (every later event goes with the first on the carry)
//   MR13  undo one step then redo with no structural step, then a full cycle         MR15  a book with the renumber more than 500 lines apart
//   M5b   a footnote renumber after the put-back (recorded: it empties CodeMirror's redo list)
//
// Break patches (one file per test, in the run notes' patches folder): "remove the putBackRedo call" is the one most tests name
// (`putBackSetAsideRedo(view, opId, depthBeforeRedo);` in `markdownStructuralSwap`); the others are named at the test.
//
// This is not structural-redo-branch-pin.test.ts's `oldBodyUndo` / `oldBodyRedo`, which replay the pre-t-4a8fd8af OLD undo with
// `setContent` and so test another route. Every failure message carries where the typed text ended up (line, heading above it) and the
// headings as they read; a long document is shown as an excerpt, not whole. Messages starting "PREMISE" mean the scenario itself did
// not run as written, not the redo bug.
//
// The page is the real one: main.ts is imported into jsdom (real extension set, update listeners, capture-phase Cmd-Z interceptor,
// window.FinalFinal), as in structural-redo-branch-pin.test.ts. Swift's side of the bridge is played by the helpers below.

import { redoDepth, undoDepth } from '@codemirror/commands';
import { Transaction } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { resetSetAsideRedo, setAsideRedoOf } from '../redo-branch';
import { computeMinimalChanges } from '../text-diff';
import { withAppOrigin } from '../typewriter-plugin';

type FF = {
  setContent: (md: string, options?: unknown) => void;
  beginStructuralOp: (opId: string) => boolean;
  finalizeStructuralOpPostOpDoc: (opId: string) => boolean;
  setUndoDescriptor: (d: { undoTopOpId?: string; redoTopOpId?: string }) => void;
  receiveUndoOutcome: (opId: string, outcome: string) => void;
  receiveRedoOutcome: (opId: string, outcome: string) => void;
  resetForProjectSwitch: () => void;
  clearStructuralUndoRegistry: () => void;
  renumberFootnotes: (mapping: Record<string, string>) => void;
  markdownStructuralSwap: (
    opId: string,
    direction: 'undo' | 'redo'
  ) => { ok: boolean; reason?: string; detail?: string };
};
const ff = (): FF => (window as any).FinalFinal as FF;

const OP = '11111111-2222-3333-4444-555555555555';
const OP2 = '66666666-2222-3333-4444-555555555555';
const TYPED = ' TYPED-AFTER-THE-OP';
const TYPED_MARK = 'TYPED-AFTER-THE-OP';
const TYPED_2 = ' SECOND-TYPING';

let structuralUndoRequested: ReturnType<typeof vi.fn>;
let structuralRedoRequested: ReturnType<typeof vi.fn>;
let contentChanged: ReturnType<typeof vi.fn>;
let historyEdited: ReturnType<typeof vi.fn>;
let selectionChanged: ReturnType<typeof vi.fn>;
/** The `[STRUCT-TRACE]` and other debug lines the page posted since the last `load`. */
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

/** Types `text` right after the `nth` (0-based) occurrence of `marker`: in a document holding a section and its copy, 0 is the original and 1 the copy. */
function typeAfterNth(marker: string, nth: number, text: string): void {
  let at = -1;
  for (let i = 0; i <= nth; i++) {
    at = docText().indexOf(marker, at + 1);
    if (at < 0) throw new Error(`occurrence ${i} of ${marker} is not in the document`);
  }
  typeAt(at + marker.length, text);
}

/**
 * The app's own rewrite landing after the user typed, outside the text history (what a structural settle does): exact changes, applied
 * as a sync-origin change. Not `setContent`: a content push whose changed line-run reaches the typing is classed as overlapping the
 * user's edit and becomes an undoable step of its own (api.ts), which is another scenario.
 */
function appRewrites(changes: Array<{ from: number; to?: number; insert: string }>): void {
  withAppOrigin(() => view.dispatch({ changes, annotations: Transaction.addToHistory.of(false) }));
}

/** The offset just after the `nth` (0-based) occurrence of `marker` in the document. */
function offsetAfterNth(marker: string, nth: number): number {
  let at = -1;
  for (let i = 0; i <= nth; i++) {
    at = docText().indexOf(marker, at + 1);
    if (at < 0) throw new Error(`occurrence ${i} of ${marker} is not in the document`);
  }
  return at + marker.length;
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

// === Documents: four chapters, Chapter 3 is the one duplicated ===

/** One chapter as the editor shows it: a heading, blank-line separated paragraphs, one final newline. */
const chapter = (title: string, paragraphs: string[]): string => `# ${title}\n\n${paragraphs.join('\n\n')}\n`;
/** Chapters joined with a blank line between them. */
const documentOf = (chapters: string[]): string => chapters.join('\n');

interface Book {
  /** The document before Duplicate Section on Chapter 3. */
  pre: string;
  /** The document after it: the copy ("Chapter 3 copy") sits directly after Chapter 3. */
  post: string;
  /** A paragraph of Chapter 3 that exists in both the original and the copy: where the tests type. */
  marker: string;
}

function bookOf(paragraphsOf: (title: string) => string[], marker: string): Book {
  const ch3 = paragraphsOf('Third');
  const chapters = (withCopy: boolean) => [
    chapter('Chapter 1', paragraphsOf('First')),
    chapter('Chapter 2', paragraphsOf('Second')),
    chapter('Chapter 3', ch3),
    ...(withCopy ? [chapter('Chapter 3 copy', ch3)] : []),
    chapter('Chapter 4', paragraphsOf('Fourth')),
  ];
  return { pre: documentOf(chapters(false)), post: documentOf(chapters(true)), marker };
}

/** The small document of structural-redo-branch-pin.test.ts. */
const smallBook = (): Book => bookOf((ordinal) => [`${ordinal} chapter text.`], 'Third chapter text.');

/** Each chapter 300 paragraphs (600 lines with the blank lines): the copy alone is far over text-diff.ts's 500-line bound. */
const bigBook = (): Book =>
  bookOf(
    (ordinal) => Array.from({ length: 300 }, (_, i) => `${ordinal} chapter paragraph ${i + 1}.`),
    'Third chapter paragraph 150.'
  );

// === Reading the result ===

const headingLines = (text: string): string[] => text.split('\n').filter((line) => line.startsWith('#'));

/** Where the typed text is: line number, the line, and the heading above it. */
function whereTyped(text: string): string {
  const lines = text.split('\n');
  const hits: string[] = [];
  let heading = '(before any heading)';
  lines.forEach((line, i) => {
    if (line.startsWith('#')) heading = line;
    if (line.includes(TYPED_MARK))
      hits.push(`line ${i + 1} "${line.slice(0, 120)}" under heading "${heading.slice(0, 60)}"`);
  });
  return hits.length === 0 ? 'the typed text is NOT in the document' : hits.join('; ');
}

/** What every assertion message shows: the whole document when it is small, an excerpt when it is a book. */
function describeDoc(text: string): string {
  const where = whereTyped(text);
  if (text.length <= 3000) return `${where}\n--- document ---\n${text}\n---`;
  const lines = text.split('\n').length;
  return `${where}\n--- ${text.length} characters, ${lines} lines; headings: ${JSON.stringify(headingLines(text))} ---`;
}

/** The two things the user is owed, both reported when both fail: the whole document as it was right after typing, and its headings. */
function expectBackAsTyped(typedDoc: string, what: string): void {
  const actual = docText();
  expect
    .soft(headingLines(actual), `${what}: every heading line must be intact\nfinal: ${describeDoc(actual)}`)
    .toEqual(headingLines(typedDoc));
  expect
    .soft(
      actual === typedDoc,
      `${what}: the document must read as it did right after typing\nfinal: ${describeDoc(actual)}\nexpected: ${describeDoc(typedDoc)}`
    )
    .toBe(true);
}

// === Swift's side ===

type Descriptor = { undoTopOpId?: string; redoTopOpId?: string };
function swiftPerformedUndo(op = OP, descriptor: Descriptor = { redoTopOpId: op }): void {
  ff().setUndoDescriptor(descriptor);
  ff().receiveUndoOutcome(op, 'performed');
}
function swiftPerformedRedo(op = OP, descriptor: Descriptor = { undoTopOpId: op }): void {
  ff().setUndoDescriptor(descriptor);
  ff().receiveRedoOutcome(op, 'performed');
}

/** Duplicate Section as Markdown mode does it today: the entry is opened, the whole document replaced, the post-op copy recorded. */
function oldBodyDuplicate(post: string, op = OP): void {
  expect(ff().beginStructuralOp(op), 'PREMISE: the entry opened').toBe(true);
  ff().setContent(post);
  expect(ff().finalizeStructuralOpPostOpDoc(op), 'PREMISE: the post-op copy was recorded').toBe(true);
  ff().setUndoDescriptor({ undoTopOpId: op });
  expect(docText() === post, 'PREMISE: the duplicate is on the screen').toBe(true);
}

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
  structuralUndoRequested.mockClear();
  structuralRedoRequested.mockClear();
  contentChanged.mockClear();
  historyEdited.mockClear();
  selectionChanged.mockClear();
  traces.length = 0;
  expect(docText() === text, 'PREMISE: the document loaded').toBe(true);
  expect(undoDepth(view.state)).toBe(0);
  expect(redoDepth(view.state)).toBe(0);
}

/** Cmd-Z that the editor's own history handles: the routing sends nothing to Swift, and the document becomes `expected`. */
function textUndo(expected: string, label: string): void {
  press('undo');
  expect(structuralUndoRequested, `PREMISE: ${label} is a text undo`).not.toHaveBeenCalled();
  expect(docText() === expected, `PREMISE: ${label} gave the expected document\nnow: ${describeDoc(docText())}`).toBe(
    true
  );
}

/** Cmd-Shift-Z that the editor's own history handles (nothing structural is routed); the document becomes `expected`. */
function textRedo(expected: string, label: string): void {
  press('redo');
  expect(structuralRedoRequested, `PREMISE: ${label} is a text redo`).not.toHaveBeenCalled();
  expect(docText() === expected, `${label}\nnow: ${describeDoc(docText())}\nexpected: ${describeDoc(expected)}`).toBe(
    true
  );
}

/** Cmd-Z routed structural, then Swift's `markdownStructuralSwap('undo')`; the document becomes `expected`. */
function structuralUndo(expected: string, op = OP, descriptor?: Descriptor): void {
  press('undo');
  expect(structuralUndoRequested, 'PREMISE: the press was routed to the structural undo').toHaveBeenCalledTimes(1);
  structuralUndoRequested.mockClear();
  const swapped = ff().markdownStructuralSwap(op, 'undo');
  expect(swapped.ok, `PREMISE: the structural undo: ${swapped.reason} ${swapped.detail ?? ''}`).toBe(true);
  swiftPerformedUndo(op, descriptor);
  expect(
    docText() === expected,
    `PREMISE: the structural undo gave the pre-op document\nnow: ${describeDoc(docText())}`
  ).toBe(true);
}

/** Cmd-Shift-Z routed structural, then Swift's `markdownStructuralSwap('redo')`; the document becomes `expected`. */
function structuralRedo(expected: string, op = OP, descriptor?: Descriptor): void {
  press('redo');
  expect(structuralRedoRequested, 'PREMISE: the press was routed to the structural redo').toHaveBeenCalledTimes(1);
  structuralRedoRequested.mockClear();
  const swapped = ff().markdownStructuralSwap(op, 'redo');
  expect(swapped.ok, `PREMISE: the structural redo: ${swapped.reason} ${swapped.detail ?? ''}`).toBe(true);
  swiftPerformedRedo(op, descriptor);
  expect(
    docText() === expected,
    `PREMISE: the structural redo gave the post-op document\nnow: ${describeDoc(docText())}`
  ).toBe(true);
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
  contentChanged = vi.fn();
  historyEdited = vi.fn();
  selectionChanged = vi.fn();
  traces = [];
  (window as any).webkit = {
    messageHandlers: {
      structuralUndoRequested: { postMessage: structuralUndoRequested },
      structuralRedoRequested: { postMessage: structuralRedoRequested },
      structuralUndoRefused: { postMessage: vi.fn() },
      historyEdited: { postMessage: historyEdited },
      selectionChanged: { postMessage: selectionChanged },
      contentChanged: { postMessage: contentChanged },
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

  // main.ts builds the real extension set and mounts the real editor into #editor at import time, and registers the real window.FinalFinal.
  await import('../main');
  ({ resetUndoCoordinatorState } = await import('../undo-coordinator'));
  ({ resetRecentUserEditSpanForTests: resetRecentUserEditSpan } = await import('../recent-edit-span'));
});

afterAll(() => {
  delete (window as any).webkit;
  document.body.innerHTML = '';
});

/**
 * Duplicate Chapter 3, type somewhere (`typeNth`: 0 is the original, 1 the copy), Cmd-Z (the typing), Cmd-Z (the duplicate),
 * Cmd-Shift-Z (the duplicate), Cmd-Shift-Z (the typing).
 */
function duplicateTypeUndoUndoRedoRedo(book: Book, typeNth: 0 | 1): void {
  load(book.pre);
  oldBodyDuplicate(book.post);
  typeAfterNth(book.marker, typeNth, TYPED);
  const typedDoc = docText();
  expect(typedDoc.includes(TYPED_MARK), 'PREMISE: the typing is in the document').toBe(true);

  textUndo(book.post, 'Cmd-Z 1 (the typing)');
  structuralUndo(book.pre); // Cmd-Z 2: the duplicate
  structuralRedo(book.post); // Cmd-Shift-Z 1: the duplicate
  press('redo'); // Cmd-Shift-Z 2: nothing structural is left, so this is the editor's own text redo
  expect(structuralRedoRequested, 'PREMISE: the last Cmd-Shift-Z was not routed structural').not.toHaveBeenCalled();

  expectBackAsTyped(typedDoc, typeNth === 1 ? 'typing inside the copy' : 'typing inside the original');
}

describe('RP3: Markdown Duplicate Section (the old body: setContent + markdownStructuralSwap), typing, Cmd-Z x2, Cmd-Shift-Z x2', () => {
  it('RP3a: typing INSIDE THE COPY is back, in the copy, with every heading line intact', () => {
    duplicateTypeUndoUndoRedoRedo(smallBook(), 1);
  });

  it('RP3b: typing inside the ORIGINAL Chapter 3, after the duplicate, is back too', () => {
    duplicateTypeUndoUndoRedoRedo(smallBook(), 0);
  });

  it('RP3c: as RP3a on a book-sized document (chapters of 600 lines; the old-body route on a book)', () => {
    duplicateTypeUndoUndoRedoRedo(bigBook(), 1);
  });

  it('RP3d (control): typing BEFORE the duplicate is back too', () => {
    const book = smallBook();
    load(book.pre);
    typeAfterNth(book.marker, 0, TYPED); // in Chapter 3, which the duplicate then copies
    const preTyped = docText();
    // The duplicate of the document as it stands: the original and the copy both hold the typing.
    const postTyped = book.post.split(book.marker).join(book.marker + TYPED);
    oldBodyDuplicate(postTyped);

    // Cmd-Z 1: the duplicate; Cmd-Z 2: the typing made before it. Cmd-Shift-Z 1: that typing; Cmd-Shift-Z 2: the duplicate.
    structuralUndo(preTyped);
    textUndo(book.pre, 'Cmd-Z 2 (the typing made before the duplicate)');
    press('redo');
    expect(
      structuralRedoRequested,
      'PREMISE: Cmd-Shift-Z 1 is the text redo of the earlier typing'
    ).not.toHaveBeenCalled();
    expect(docText() === preTyped, `PREMISE: the earlier typing is back\nnow: ${describeDoc(docText())}`).toBe(true);
    structuralRedo(postTyped);

    expectBackAsTyped(postTyped, 'typing made before the duplicate');
  });
});

// === The new tests: anchors, footnotes, restores, several operations, the fall-back ===

/** `text` with an app-injected section anchor glued in front of every `# ` heading line (a pure insertion, as the rebuild writes it). */
const anchorOf = (heading: string): string => {
  let h = 0;
  for (const c of heading) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return `<!-- @sid:${h.toString(16).padStart(8, '0')}-aaaa-bbbb-cccc-dddddddddddd -->`;
};
const withAnchors = (text: string): string =>
  text
    .split('\n')
    .map((line) => (line.startsWith('# ') ? anchorOf(line) + line : line))
    .join('\n');

// Break patch used by most tests below (putBack.patch): remove the `putBackSetAsideRedo(view, opId, depthBeforeRedo);` call in
// `markdownStructuralSwap` (api-structural-markdown.ts). Without it the carry's drop rule keeps the typing out of the heading line (nothing
// is corrupted), but the typing inside the copy is not redone: the messages say "not back".
describe('MR1 two full cycles', () => {
  it('MR1: Duplicate, type inside the copy, Cmd-Z x2 and Cmd-Shift-Z x2, twice: the typing is back after each cycle, headings intact', () => {
    const book = smallBook();
    load(book.pre);
    oldBodyDuplicate(book.post);
    typeAfterNth(book.marker, 1, TYPED);
    const typedDoc = docText();

    for (const cycle of [1, 2]) {
      textUndo(book.post, `Cmd-Z 1 of cycle ${cycle} (the typing)`);
      structuralUndo(book.pre); // Cmd-Z 2: the duplicate
      structuralRedo(book.post); // Cmd-Shift-Z 1: the duplicate
      press('redo'); // Cmd-Shift-Z 2: the typing
      expect(structuralRedoRequested, 'PREMISE: the last Cmd-Shift-Z was not routed structural').not.toHaveBeenCalled();
      expectBackAsTyped(typedDoc, `copy typing not back after cycle ${cycle}`);
    }
  });
});

describe('MR2 a restore (the old body: a whole-document replace) that changes a paragraph', () => {
  // The restored version changes paragraph two of Chapter 2. The user types inside that changed paragraph (inside the text the line diff
  // removes at the undo) and then inside an unchanged paragraph of Chapter 4 (outside it, but done LATER, so the carry drops it with the
  // first). Break patch: putBack.patch. Predicted failure: `restore typing not back`.
  const paragraphs = (ordinal: string): string[] => [
    `${ordinal} chapter paragraph one.`,
    `${ordinal} chapter paragraph two.`,
    `${ordinal} chapter paragraph three.`,
  ];
  const version = (secondParagraphOfChapter2: string): string =>
    documentOf([
      chapter('Chapter 1', paragraphs('First')),
      chapter('Chapter 2', [
        'Second chapter paragraph one.',
        secondParagraphOfChapter2,
        'Second chapter paragraph three.',
      ]),
      chapter('Chapter 3', paragraphs('Third')),
      chapter('Chapter 4', paragraphs('Fourth')),
    ]);

  it('MR2: Restore, type in the changed paragraph and in an unchanged one, Cmd-Z x3, Cmd-Shift-Z x3: both are back, headings intact', () => {
    const pre = version('Second chapter paragraph two.');
    const restored = version('Second chapter paragraph two, as restored.');
    load(pre);
    oldBodyDuplicate(restored); // the old body replaces the whole document: a restore and a duplicate are the same entry shape
    typeAfterNth('paragraph two, as', 0, TYPED); // in the middle of the text the restore changed (inside the span the line diff removes)
    const afterFirst = docText();
    typeAfterNth('Fourth chapter paragraph one.', 0, TYPED_2);
    const typedDoc = docText();
    expect(afterFirst !== restored && typedDoc !== afterFirst, 'PREMISE: two typing steps').toBe(true);

    textUndo(afterFirst, 'Cmd-Z 1 (the typing in Chapter 4)');
    textUndo(restored, 'Cmd-Z 2 (the typing in the changed paragraph)');
    structuralUndo(pre); // Cmd-Z 3: the restore
    structuralRedo(restored); // Cmd-Shift-Z 1: the restore
    textRedo(afterFirst, 'restore typing not back: Cmd-Shift-Z 2 (the changed paragraph)');
    textRedo(typedDoc, 'restore typing not back: Cmd-Shift-Z 3 (Chapter 4)');

    expectBackAsTyped(typedDoc, 'restore typing not back');
  });
});

describe('MR3 the app injects section anchors (a pure insertion in front of each heading) before or after the typing', () => {
  // BEFORE the typing the saved copy follows the anchors and the redo lands on the anchored document (the put-back difference is empty).
  // AFTER the typing the saved copy stays where the click left it: the undo is routed by equivalence, the redo lands on the document
  // WITHOUT anchors, and the put-back difference (record document -> live) deletes the anchors.
  // Break patch: putBack.patch. Predicted failure: `copy typing not back (anchors`.
  it('MR3 (anchors BEFORE the typing): the typing inside the copy is back, anchors as they were', () => {
    const book = smallBook();
    load(book.pre);
    oldBodyDuplicate(book.post);
    const anchoredPost = withAnchors(book.post);
    ff().setContent(anchoredPost, { origin: 'derived' });
    expect(docText() === anchoredPost, 'PREMISE: the anchors are in').toBe(true);
    typeAfterNth(book.marker, 1, TYPED);
    const typedDoc = docText();

    textUndo(anchoredPost, 'Cmd-Z 1 (the typing)');
    structuralUndo(book.pre);
    structuralRedo(anchoredPost); // the saved copy followed the anchors
    press('redo');
    expect(structuralRedoRequested, 'PREMISE: the last Cmd-Shift-Z was not routed structural').not.toHaveBeenCalled();

    expectBackAsTyped(typedDoc, 'copy typing not back (anchors before the typing)');
  });

  it('MR3 (anchors AFTER the typing): the typing inside the copy is back; the redo lands on the document without anchors', () => {
    const book = smallBook();
    load(book.pre);
    oldBodyDuplicate(book.post);
    typeAfterNth(book.marker, 1, TYPED);
    const typedDoc = docText();
    ff().setContent(withAnchors(typedDoc), { origin: 'derived' });
    expect(docText() === withAnchors(typedDoc), 'PREMISE: the anchors are in').toBe(true);

    textUndo(withAnchors(book.post), 'Cmd-Z 1 (the typing)');
    structuralUndo(book.pre); // routed by equivalence: the live text is the saved text plus anchors
    structuralRedo(book.post); // the saved copy never saw the anchors
    press('redo');
    expect(structuralRedoRequested, 'PREMISE: the last Cmd-Shift-Z was not routed structural').not.toHaveBeenCalled();

    expectBackAsTyped(typedDoc, 'copy typing not back (anchors after the typing)');
  });
});

describe('MR4 a footnote reference on the line that holds the typing; a renumber relabels the copy and the chapters after it', () => {
  // The copy of Chapter 3 carries the same label as the original. A Duplicate itself renumbers nothing (the copy repeats a label the
  // original already has); the test plays the renumber a LATER footnote insertion would cause: the copy's reference 3 -> 4 and the next
  // chapter's 4 -> 5. The user types right after the copy's reference. BEFORE the typing the redo lands on the renumbered saved copy
  // (empty put-back difference). AFTER the typing the saved copy keeps the old labels, so the put-back difference is two one-character
  // label changes and the typing sits on the line of one of them: a plain line diff would make that whole line a removed span.
  // Break patch (MR4.patch), AFTER case: in `putBackRedo` use `computeMinimalChanges` instead of `computeRefinedChanges`.
  // Predicted failure: `copy typing not back (footnote line, renumber after the typing)`. The BEFORE case fails with putBack.patch.
  const chapters = (copyLabel: number, fourthLabel: number, copyTyping = ''): string =>
    documentOf([
      chapter('Chapter 1', ['First chapter text.[^1]']),
      chapter('Chapter 2', ['Second chapter text.[^2]']),
      chapter('Chapter 3', ['Third chapter text.[^3]']),
      chapter('Chapter 3 copy', [`Third chapter text.[^${copyLabel}]${copyTyping}`]),
      chapter('Chapter 4', [`Fourth chapter text.[^${fourthLabel}]`]),
    ]);
  const pre = documentOf([
    chapter('Chapter 1', ['First chapter text.[^1]']),
    chapter('Chapter 2', ['Second chapter text.[^2]']),
    chapter('Chapter 3', ['Third chapter text.[^3]']),
    chapter('Chapter 4', ['Fourth chapter text.[^4]']),
  ]);
  const post = chapters(3, 4); // right after the click: the copy still has the original's label
  const renumbered = chapters(4, 5);

  it('MR4 (renumber BEFORE the typing): the typing right after the copy reference is back', () => {
    load(pre);
    oldBodyDuplicate(post);
    ff().setContent(renumbered, { origin: 'derived' });
    expect(docText() === renumbered, 'PREMISE: the renumber is in').toBe(true);
    typeAfterNth('Third chapter text.[^4]', 0, TYPED);
    const typedDoc = docText();
    expect(typedDoc === chapters(4, 5, TYPED), 'PREMISE: the typing is right after the copy reference').toBe(true);

    textUndo(renumbered, 'Cmd-Z 1 (the typing)');
    structuralUndo(pre);
    structuralRedo(renumbered);
    press('redo');

    expectBackAsTyped(typedDoc, 'copy typing not back (footnote line, renumber before the typing)');
  });

  it('MR4 (renumber AFTER the typing): the typing right after the copy reference is back, at its place', () => {
    load(pre);
    oldBodyDuplicate(post);
    typeAfterNth('Third chapter text.[^3]', 1, TYPED);
    const typedPost = docText();
    expect(typedPost === chapters(3, 4, TYPED), 'PREMISE: the typing is right after the copy reference').toBe(true);
    // The resync: the copy's reference 3 -> 4 (on the line that holds the typing) and the next chapter's 4 -> 5.
    const copyDigit = offsetAfterNth('Third chapter text.[^', 1);
    const fourthDigit = offsetAfterNth('Fourth chapter text.[^', 0);
    appRewrites([
      { from: copyDigit, to: copyDigit + 1, insert: '4' },
      { from: fourthDigit, to: fourthDigit + 1, insert: '5' },
    ]);
    expect(docText() === chapters(4, 5, TYPED), 'PREMISE: the renumber is in').toBe(true);

    textUndo(renumbered, 'Cmd-Z 1 (the typing)');
    structuralUndo(pre); // routed by equivalence
    structuralRedo(post); // the saved copy never saw the renumber
    press('redo');

    expectBackAsTyped(typedPost, 'copy typing not back (footnote line, renumber after the typing)');
  });
});

describe('MR6 fall-back: the put-back is refused, the carried list is what the redo finds', () => {
  // Break patch (MR6.patch): in `carryRedoBranch` compute no spans for an old-body entry (`spans = removedSpans(toCheckpoint);` -> `spans = [];`).
  // Predicted failure: `heading line changed by a redo` (the typing is redone into the next chapter's heading line).
  it('MR6: Duplicate, type in the copy, Cmd-Z x2, break the record, Cmd-Shift-Z x2: the copy is back, the copy typing is not redone, no heading line changes', () => {
    const book = smallBook();
    load(book.pre);
    oldBodyDuplicate(book.post);
    typeAfterNth(book.marker, 1, TYPED);

    textUndo(book.post, 'Cmd-Z 1 (the typing)');
    structuralUndo(book.pre);
    const record = setAsideRedoOf(OP);
    expect(record, 'PREMISE: the undo set the redo list aside').toBeDefined();
    if (record) record.depthAfterUndo += 1; // the put-back must now refuse
    structuralRedo(book.post);
    press('redo'); // a text redo of whatever the carried list holds

    expect(
      traces.some((t) => t.includes('redo put-back skipped')),
      'PREMISE: the put-back was refused'
    ).toBe(true);
    expect(headingLines(docText()), 'heading line changed by a redo').toEqual(headingLines(book.post));
    expect(docText(), 'after the fall-back the document must be the post-op copy without the typing').toBe(book.post);
  });
});

describe('MR10 undo past the operation into earlier typing, then redo everything', () => {
  // Break patch: putBack.patch. Predicted failure: `copy typing not back: Cmd-Shift-Z 3`.
  it('MR10: type in Chapter 3, Duplicate, type in the copy, Cmd-Z x3, Cmd-Shift-Z x3: both typings and the copy are back, in order', () => {
    const book = smallBook();
    load(book.pre);
    typeAfterNth(book.marker, 0, TYPED); // before the operation, in the chapter the duplicate copies
    const preTyped = docText();
    const postTyped = book.post.split(book.marker).join(book.marker + TYPED);
    oldBodyDuplicate(postTyped);
    typeAfterNth(book.marker + TYPED, 1, TYPED_2); // inside the copy
    const typedAll = docText();

    textUndo(postTyped, 'Cmd-Z 1 (the typing in the copy)');
    structuralUndo(preTyped); // Cmd-Z 2: the duplicate
    textUndo(book.pre, 'Cmd-Z 3 (the typing made before the duplicate)');
    textRedo(preTyped, 'Cmd-Shift-Z 1 (the typing made before the duplicate)');
    structuralRedo(postTyped); // Cmd-Shift-Z 2: the duplicate
    textRedo(typedAll, 'copy typing not back: Cmd-Shift-Z 3');

    expectBackAsTyped(typedAll, 'copy typing not back');
  });
});

describe('MR11 two operations in a row', () => {
  // Duplicate Chapter 3 and type in its copy; Duplicate Chapter 5 and type in its copy; Cmd-Z x4 (copy 5 typing, the second duplicate, copy
  // 3 typing, the first duplicate), Cmd-Shift-Z x4. Each operation keeps its own record, so both typings come back in their own copies.
  // Break patch: putBack.patch. Predicted failure: `copy typing not back: Cmd-Shift-Z 2` (and 4).
  const chapterText = (title: string, n: number): string => chapter(title, [`Text of chapter ${n}.`]);
  const chaptersOf = (extra: Record<number, string>): string =>
    documentOf(
      [1, 2, 3, 4, 5, 6].flatMap((n) =>
        extra[n] ? [chapterText(`Chapter ${n}`, n), extra[n]] : [chapterText(`Chapter ${n}`, n)]
      )
    );

  it('MR11: both typings are back in their own copies', () => {
    const pre0 = chaptersOf({});
    const post1 = chaptersOf({ 3: chapterText('Chapter 3 copy', 3) });
    const post2Untyped = chaptersOf({ 3: chapterText('Chapter 3 copy', 3), 5: chapterText('Chapter 5 copy', 5) });
    load(pre0);
    oldBodyDuplicate(post1, OP);
    typeAfterNth('Text of chapter 3.', 1, TYPED); // inside the first copy
    const doc1T = docText();
    // The second duplicate is made of the document as it stands (it holds the first copy's typing).
    const post2 = post2Untyped.replace(
      'Text of chapter 3.\n\n# Chapter 3 copy\n\nText of chapter 3.',
      `Text of chapter 3.\n\n# Chapter 3 copy\n\nText of chapter 3.${TYPED}`
    );
    expect(post2 !== post2Untyped, 'PREMISE: the second duplicate holds the first typing').toBe(true);
    oldBodyDuplicate(post2, OP2);
    typeAfterNth('Text of chapter 5.', 1, TYPED_2); // inside the second copy
    const doc2T = docText();

    textUndo(post2, 'Cmd-Z 1 (the typing in the second copy)');
    structuralUndo(doc1T, OP2, { undoTopOpId: OP, redoTopOpId: OP2 }); // Cmd-Z 2: the second duplicate
    textUndo(post1, 'Cmd-Z 3 (the typing in the first copy)');
    structuralUndo(pre0, OP, { redoTopOpId: OP }); // Cmd-Z 4: the first duplicate
    structuralRedo(post1, OP, { undoTopOpId: OP, redoTopOpId: OP2 }); // Cmd-Shift-Z 1: the first duplicate
    textRedo(doc1T, 'copy typing not back: Cmd-Shift-Z 2 (the first copy)');
    structuralRedo(post2, OP2, { undoTopOpId: OP2 }); // Cmd-Shift-Z 3: the second duplicate
    textRedo(doc2T, 'copy typing not back: Cmd-Shift-Z 4 (the second copy)');

    expectBackAsTyped(doc2T, 'copy typing not back');
  });
});

describe('MR12 typing in the copy THEN in the original', () => {
  // The carry drops the first redo event that touches the copy AND every later one, so the typing in the original goes with it; the
  // put-back brings the whole list back, in order. (Removing only the carry's drop would NOT fail this test: the put-back replaces the
  // list. Removing the put-back does.) Break patch: putBack.patch. Predicted failure: `copy typing not back: Cmd-Shift-Z 1`.
  it('MR12: Duplicate, type in the copy, type in the original, Cmd-Z x3, Cmd-Shift-Z x3: both typings are back, in order', () => {
    const book = smallBook();
    load(book.pre);
    oldBodyDuplicate(book.post);
    typeAfterNth(book.marker, 1, TYPED); // inside the copy
    const afterCopy = docText();
    typeAfterNth(book.marker, 0, TYPED_2); // inside the original, after
    const typedBoth = docText();

    textUndo(afterCopy, 'Cmd-Z 1 (the typing in the original)');
    textUndo(book.post, 'Cmd-Z 2 (the typing in the copy)');
    structuralUndo(book.pre); // Cmd-Z 3: the duplicate
    structuralRedo(book.post); // Cmd-Shift-Z 1: the duplicate
    textRedo(afterCopy, 'copy typing not back: Cmd-Shift-Z 2');
    textRedo(typedBoth, 'original typing not back: Cmd-Shift-Z 3');

    expectBackAsTyped(typedBoth, 'both typings not back');
  });
});

describe('MR13 undo one step then redo it, with no structural step in between', () => {
  // Nothing is set aside by a plain Cmd-Z / Cmd-Shift-Z, and a later full cycle still brings the typing back.
  // Break patch: putBack.patch. Predicted failure: `copy typing not back after the full cycle`.
  it('MR13: Duplicate, type in the copy, Cmd-Z, Cmd-Shift-Z (typing back), then Cmd-Z x2 and Cmd-Shift-Z x2: the typing is back', () => {
    const book = smallBook();
    load(book.pre);
    oldBodyDuplicate(book.post);
    typeAfterNth(book.marker, 1, TYPED);
    const typedDoc = docText();

    textUndo(book.post, 'Cmd-Z 1 (the typing)');
    textRedo(typedDoc, 'Cmd-Shift-Z 1 (the same typing, no structural step)');
    expect(setAsideRedoOf(OP), 'a plain undo and redo set something aside').toBeUndefined();

    textUndo(book.post, 'Cmd-Z 2 (the typing again)');
    structuralUndo(book.pre);
    structuralRedo(book.post);
    press('redo');
    expect(structuralRedoRequested, 'PREMISE: the last Cmd-Shift-Z was not routed structural').not.toHaveBeenCalled();

    expectBackAsTyped(typedDoc, 'copy typing not back after the full cycle');
  });
});

describe('MR15 a book-sized document: the renumber and the Notes definition are more than 500 lines apart', () => {
  // A line diff bounded at 500 lines (computeMinimalChanges) turns "the label in the copy changed, the Notes definition added 1,500 lines
  // later" into ONE span from the label to the end of the Notes; the typing right after the label is inside it and is dropped. The put-back's
  // difference has no such bound. The renumber and its Notes definition are injected AFTER the typing (derived, history-neutral), so the
  // undo is routed by equivalence and the redo lands on the stale saved copy (labels as the click left them).
  // Break patch (MR15.patch): in `putBackRedo` use `computeMinimalChanges` instead of `computeRefinedChanges`.
  // Predicted failure: `copy typing not back (book)`.
  const paragraphsOf = (ordinal: string, withReference: boolean, label: number): string[] =>
    Array.from({ length: 300 }, (_, i) =>
      i === 1 && withReference ? `${ordinal} chapter paragraph 2.[^${label}]` : `${ordinal} chapter paragraph ${i + 1}.`
    );
  const bookWith = (copyLabel: number | null, notes: string[], copyTyping = ''): string => {
    const copy =
      copyLabel === null
        ? []
        : [
            chapter(
              'Chapter 3 copy',
              paragraphsOf('Third', true, copyLabel).map((p, i) => (i === 1 ? p + copyTyping : p))
            ),
          ];
    return documentOf([
      chapter('Chapter 1', paragraphsOf('First', false, 0)),
      chapter('Chapter 2', paragraphsOf('Second', false, 0)),
      chapter('Chapter 3', paragraphsOf('Third', true, 3)),
      ...copy,
      chapter('Chapter 4', paragraphsOf('Fourth', false, 0)),
      chapter('Notes', notes),
    ]);
  };

  it('MR15: type right after the copy reference, a renumber relabels it and a new Notes definition appears far below, Cmd-Z x2, Cmd-Shift-Z x2: the typing is back', () => {
    const pre = bookWith(null, ['[^3]: A note.']);
    const post = bookWith(3, ['[^3]: A note.']);
    load(pre);
    oldBodyDuplicate(post);
    expect(post.split('\n').length, 'PREMISE: a book-sized document').toBeGreaterThan(3000);
    typeAfterNth('Third chapter paragraph 2.[^3]', 1, TYPED);
    const typedPost = docText();
    // The renumber a later footnote insertion would cause (a Duplicate itself causes none): the copy's reference 3 -> 4 (right in front of
    // the typing) and the new Notes definition at the very end, 1,500+ lines below.
    const copyDigit = offsetAfterNth('Third chapter paragraph 2.[^', 1);
    appRewrites([
      { from: copyDigit, to: copyDigit + 1, insert: '4' },
      { from: docText().length, insert: '\n[^4]: A note.\n' },
    ]);
    expect(
      docText() === bookWith(4, ['[^3]: A note.', '[^4]: A note.'], TYPED),
      'PREMISE: the renumber and the new definition are in'
    ).toBe(true);

    textUndo(bookWith(4, ['[^3]: A note.', '[^4]: A note.']), 'Cmd-Z 1 (the typing)');
    structuralUndo(pre); // routed by equivalence
    structuralRedo(post); // the saved copy never saw the renumber
    press('redo');
    expect(structuralRedoRequested, 'PREMISE: the last Cmd-Shift-Z was not routed structural').not.toHaveBeenCalled();

    expectBackAsTyped(typedPost, 'copy typing not back (book)');
  });

  // P5 (code review BR-F4, a PROBE that came back GREEN on today's code, so `swapRedoFromSavedCopy` is unchanged): it maps BOTH history
  // branches through the 500-line-bounded `computeMinimalChanges`, and with a saved copy of two far-apart changes (the copy, and its new
  // Notes definition more than 500 lines below) that makes ONE span over everything between, which would map away the DONE events inside
  // it (typing made BEFORE the Duplicate, in a chapter after the copy). It does not show: after the full cycle the next Cmd-Z is routed
  // structural and swaps the checkpoint in, with its own history, where that earlier typing is intact; the live done branch the redo
  // mapped is never what Cmd-Z walks. The test stays as a pin of that walk.
  it('P5: Duplicate (with typing made before it in a later chapter), a full cycle, then Cmd-Z through everything: the earlier typing is undone too', () => {
    const EARLY = ' EARLY-TYPING';
    const earlyIn = (text: string): string =>
      text.replace('Fourth chapter paragraph 150.', `Fourth chapter paragraph 150.${EARLY}`);
    const notes = ['[^3]: A note.', '[^4]: A note.'];
    const pre = bookWith(null, ['[^3]: A note.']);
    load(pre);
    typeAfterNth('Fourth chapter paragraph 150.', 0, EARLY); // BEFORE the Duplicate, in Chapter 4, which lies after the copy
    const preEarly = docText();
    expect(preEarly === earlyIn(pre), 'PREMISE: the early typing is in').toBe(true);
    oldBodyDuplicate(earlyIn(bookWith(3, ['[^3]: A note.'])));
    // The renumber a later footnote insertion would cause, BEFORE the user types in the copy (a Duplicate itself causes none): the copy's
    // label and a new Notes definition 1,500+ lines below (history-neutral; the saved post-op copy follows it).
    const copyDigit = offsetAfterNth('Third chapter paragraph 2.[^', 1);
    appRewrites([
      { from: copyDigit, to: copyDigit + 1, insert: '4' },
      { from: docText().length, insert: '\n[^4]: A note.\n' },
    ]);
    const settled = earlyIn(bookWith(4, notes));
    expect(docText() === settled, 'PREMISE: the settled book is in').toBe(true);
    typeAfterNth('Third chapter paragraph 2.[^4]', 0, TYPED); // the only [^4] is the copy's
    const cycleTyped = docText();

    textUndo(settled, 'Cmd-Z 1 (the typing in the copy)');
    structuralUndo(preEarly);
    structuralRedo(settled);
    press('redo');
    expect(docText() === cycleTyped, 'PREMISE: the full cycle brought the copy typing back').toBe(true);

    // Now Cmd-Z until the typing made before the Duplicate is gone (a structural press is carried out as Swift would).
    let presses = 0;
    while (docText().includes(EARLY) && presses < 8) {
      press('undo');
      presses++;
      if (structuralUndoRequested.mock.calls.length > 0) {
        structuralUndoRequested.mockClear();
        const swapped = ff().markdownStructuralSwap(OP, 'undo');
        expect(swapped.ok, `PREMISE: the structural undo: ${swapped.reason} ${swapped.detail ?? ''}`).toBe(true);
        swiftPerformedUndo(OP);
      }
    }
    expect(
      docText().includes(EARLY),
      `the typing made before the Duplicate is no longer undoable (${presses} presses)`
    ).toBe(false);
    expect(docText() === pre, 'the book is back as it was before any typing').toBe(true);
  });
});

describe('BR-F4 a footnoted book: Duplicate, Cmd-Z, Cmd-Shift-Z, then Cmd-Z through the typing made BEFORE the Duplicate', () => {
  // Code review BR-F4 (read from the library source, then run here): `swapRedoFromSavedCopy` dispatches `computeMinimalChanges(live,
  // saved copy)` with `addToHistory: false`, and @codemirror/commands maps BOTH history branches through that change set. When the
  // changed middle is longer than text-diff.ts's 500 lines (the copy, plus the relabelled reference of the chapter after it and the
  // relabelled Notes definitions far below) the diff is ONE replaced span, and a history event whose change lies inside it (typing made
  // BEFORE the Duplicate, in a chapter AFTER the copy) is mapped away (`addMappingToBranch` drops an event whose changes all vanish).
  //
  // RESULT: GREEN on today's code, so these are CONTROLS, not an open finding. The mapping does drop the event (measured with a temporary
  // `undoDepth(view.state)` read right after the structural redo: 0 in the long book, 1 in the short one), but the live done branch is
  // never what Cmd-Z walks across the Duplicate. After the redo the live document equals the saved copy again, so the next Cmd-Z is
  // routed structural (`decideLiveRouting`) and `swapUndo` installs the entry's CHECKPOINT state, which carries its own, unmapped text
  // history with the earlier typing in it; the Cmd-Z after that removes the typing. Either test would go red only if the structural
  // undo stopped installing the checkpoint's history (or the live document drifted from the saved copy beyond what the routing's
  // equivalence check accepts, so that Cmd-Z fell through to the lossy live branch).
  // Not P5 (above): P5 types inside the copy too and walks with a bounded loop; this is the plain Duplicate / undo / redo with the exact
  // press-by-press result asserted, a premise that the redo's diff really is one collapsed span over the typing (long book) or is not (short
  // book, the control for the 500-line bound), and the same footnote shift in both (the copy's label, Chapter 4's label, a new definition).
  const EARLY = ' EARLY-TYPING-BEFORE-THE-DUPLICATE';
  const NOTES_BEFORE = ['[^1]: Note one.', '[^2]: Note two.', '[^3]: Note three.', '[^4]: Note four.'];
  const NOTES_AFTER = [
    '[^1]: Note one.',
    '[^2]: Note two.',
    '[^3]: Note three.',
    '[^4]: Note three, copied.',
    '[^5]: Note four.',
  ];

  /**
   * Four chapters of `paragraphs` paragraphs (two lines each, with the blank line) and a Notes chapter; `early` puts the earlier typing at
   * the end of the middle paragraph of Chapter 4. `copyLabel` null: no copy of Chapter 3 yet. Chapter 4's reference and the Notes follow
   * the labels the way the app's footnote renumber leaves them.
   */
  function footnotedBook(paragraphs: number) {
    const earlyParagraph = Math.floor(paragraphs / 2);
    const marker = `Fourth chapter paragraph ${earlyParagraph}.`;
    const paragraphsOf = (ordinal: string, label: number, early: boolean): string[] =>
      Array.from({ length: paragraphs }, (_, i) => {
        if (i === 1) return `${ordinal} chapter paragraph 2.[^${label}]`; // a footnote reference near the top of every chapter
        if (early && ordinal === 'Fourth' && i === earlyParagraph - 1) return `${marker}${EARLY}`;
        return `${ordinal} chapter paragraph ${i + 1}.`;
      });
    const bookWith = (copyLabel: number | null, fourthLabel: number, notes: string[], early: boolean): string =>
      documentOf([
        chapter('Chapter 1', paragraphsOf('First', 1, false)),
        chapter('Chapter 2', paragraphsOf('Second', 2, false)),
        chapter('Chapter 3', paragraphsOf('Third', 3, false)),
        ...(copyLabel === null ? [] : [chapter('Chapter 3 copy', paragraphsOf('Third', copyLabel, false))]),
        chapter('Chapter 4', paragraphsOf('Fourth', fourthLabel, early)),
        chapter('Notes', notes),
      ]);
    return {
      marker,
      pre: bookWith(null, 4, NOTES_BEFORE, false),
      preEarly: bookWith(null, 4, NOTES_BEFORE, true),
      justDuplicated: bookWith(3, 4, NOTES_BEFORE, true), // right after the click: the copy repeats the original's label
      settled: bookWith(4, 5, NOTES_AFTER, true), // after the renumber: the copy is 4, Chapter 4's reference 5, a new definition
    };
  }

  /**
   * Type (before the Duplicate, in Chapter 4), Duplicate Chapter 3 (old body), the footnote renumber settles, Cmd-Z (the Duplicate),
   * Cmd-Shift-Z (the Duplicate), Cmd-Z (the Duplicate again), Cmd-Z (the typing made before the Duplicate: the book is as it was).
   * `collapsed` is the premise about the redo's line diff: one span over the typing (a long book) or not (a short one).
   */
  function typeDuplicateUndoRedoThenUndoTheTyping(paragraphs: number, collapsed: boolean): void {
    const book = footnotedBook(paragraphs);
    load(book.pre);
    typeAfterNth(book.marker, 0, EARLY); // BEFORE the Duplicate, in Chapter 4, which lies after the copy
    expect(docText() === book.preEarly, 'PREMISE: the earlier typing is in').toBe(true);
    oldBodyDuplicate(book.justDuplicated);
    // The renumber the copy's label causes (history-neutral; the saved post-op copy follows it): the copy's reference 3 -> 4, Chapter 4's
    // reference 4 -> 5, and the definition of the copy inserted in the Notes, far below the first change.
    const copyDigit = offsetAfterNth('Third chapter paragraph 2.[^', 1);
    const fourthDigit = offsetAfterNth('Fourth chapter paragraph 2.[^', 0);
    const lastNote = docText().indexOf('[^4]: Note four.');
    appRewrites([
      { from: copyDigit, to: copyDigit + 1, insert: '4' },
      { from: fourthDigit, to: fourthDigit + 1, insert: '5' },
      {
        from: lastNote,
        to: lastNote + '[^4]: Note four.'.length,
        insert: '[^4]: Note three, copied.\n\n[^5]: Note four.',
      },
    ]);
    expect(docText() === book.settled, 'PREMISE: the settled book is in').toBe(true);
    expect(book.settled.split('\n').length > 3000, 'PREMISE: the document is book-sized (long) or small (short)').toBe(
      collapsed
    );

    // PREMISE: the redo's line diff (live pre-op document -> saved copy). In a long book it is ONE span covering the earlier typing, so a
    // mapping through it drops that history event of the live done branch; in a short book it is several separate spans around the typing.
    const earlyAt = book.preEarly.indexOf(EARLY);
    const redoDiff = computeMinimalChanges(book.preEarly, book.settled);
    const coversTyping = redoDiff.some((c) => c.from < earlyAt && c.to > earlyAt + EARLY.length);
    expect(
      redoDiff.length === 1 && coversTyping,
      `PREMISE: the redo's diff is ${collapsed ? 'one collapsed span over the earlier typing' : 'not one span over the typing'}: ${JSON.stringify(redoDiff.map((c) => [c.from, c.to, c.insert.length]))}, typing at ${earlyAt}`
    ).toBe(collapsed);

    structuralUndo(book.preEarly); // Cmd-Z 1: the Duplicate
    structuralRedo(book.settled); // Cmd-Shift-Z 1: the Duplicate (swapRedoFromSavedCopy)
    structuralUndo(book.preEarly); // Cmd-Z 2: the Duplicate again (the live document is the saved copy, so the press is routed structural)
    press('undo'); // Cmd-Z 3: the typing made before the Duplicate
    expect(structuralUndoRequested, "PREMISE: Cmd-Z 3 is the editor's own text undo").not.toHaveBeenCalled();
    expect(
      docText() === book.pre,
      `the typing made before the Duplicate is no longer undoable after Duplicate, undo, redo: Cmd-Z 3 left ${docText().includes(EARLY) ? 'it in the document' : 'a different document'} (undo depth ${undoDepth(view.state)})`
    ).toBe(true);
  }

  it('BR-F4: the typing made before a Duplicate in a long book is still undoable after Duplicate, undo, redo', () => {
    typeDuplicateUndoRedoThenUndoTheTyping(300, true); // 600 lines a chapter: the copy alone is far over the 500-line bound
  });

  it('BR-F4 (short-book control): the same sequence in a book whose redo diff is under the 500-line bound', () => {
    typeDuplicateUndoRedoThenUndoTheTyping(20, false);
  });
});

describe('M5b the put-back, then a footnote renumber outside a structural settle (a recorded change)', () => {
  // The renumber the app runs OUTSIDE a settle (`structuralSettleOpId` null) is `derivedCorrection`, a recorded change, and CodeMirror
  // empties the redo branch on a recorded change. Written to see whether the put-back list survives it (plan review M5). If this is red
  // the put-back is wiped by that renumber; the driver traces in Swift whether a settle always sets the flag.
  it('Duplicate a chapter with a footnote, type in the copy, Cmd-Z x2, Cmd-Shift-Z (structural), renumber, Cmd-Shift-Z: the typing is back', () => {
    const base = bookOf(
      (ordinal) => [`${ordinal} chapter text.[^${ordinal === 'Fourth' ? 4 : 3}]`],
      'Third chapter text.[^3]'
    );
    load(base.pre);
    oldBodyDuplicate(base.post);
    typeAfterNth(base.marker, 1, TYPED);
    const typedDoc = docText();

    textUndo(base.post, 'Cmd-Z 1 (the typing)');
    structuralUndo(base.pre); // Cmd-Z 2: the duplicate
    structuralRedo(base.post); // Cmd-Shift-Z 1: the duplicate, and the put-back
    expect(redoDepth(view.state), 'PREMISE: the put-back installed the typing').toBe(1);
    ff().renumberFootnotes({ '4': '5' }); // the app's footnote resync, outside a settle: a recorded change
    expect(redoDepth(view.state), 'the renumber emptied the redo list').toBe(1); // asserted BEFORE the press, which would pop it
    press('redo'); // Cmd-Shift-Z 2

    expect(docText(), 'typing not back after the renumber').toBe(typedDoc.replace('[^4]', '[^5]'));
  });

  // T2 (code review MD-T1, EVERYDAY): a renumber (the kind a later footnote insertion causes; a Duplicate itself causes none) relabels
  // the COPY's own reference, the one the typing sits right behind (M5b relabels a chapter far from the typing). The original's
  // reference has another label, so `{3 -> 4}` touches only the copy.
  // Break patch (T2.patch): in `renumberFootnotes` (api.ts) do not keep the list (`const keptRedo = null as ...`).
  // Predicted failure: `the renumber emptied the redo list`.
  it('T2: the renumber relabels only the copy reference right in front of the typing: Cmd-Shift-Z brings the typing back behind the new label', () => {
    const chapters = (copy: string | null, copyTyping = ''): string =>
      documentOf([
        chapter('Chapter 1', ['First chapter text.']),
        chapter('Chapter 2', ['Second chapter text.']),
        chapter('Chapter 3', ['Third chapter text.[^2]']),
        ...(copy === null ? [] : [chapter('Chapter 3 copy', [`Third chapter text.[^${copy}]${copyTyping}`])]),
        chapter('Chapter 4', ['Fourth chapter text.']),
      ]);
    const pre = chapters(null);
    const post = chapters('3');
    load(pre);
    oldBodyDuplicate(post);
    typeAfterNth('Third chapter text.[^3]', 0, TYPED); // the only [^3] is the copy's
    expect(docText() === chapters('3', TYPED), 'PREMISE: the typing is right behind the copy reference').toBe(true);

    textUndo(post, 'Cmd-Z 1 (the typing)');
    structuralUndo(pre);
    structuralRedo(post);
    expect(redoDepth(view.state), 'PREMISE: the put-back installed the typing').toBe(1);
    ff().renumberFootnotes({ '3': '4' }); // flag null: a recorded change
    expect(docText() === chapters('4'), 'PREMISE: the copy reference is relabelled').toBe(true);
    expect(redoDepth(view.state), 'the renumber emptied the redo list').toBe(1);
    press('redo');

    expectBackAsTyped(chapters('4', TYPED), 'typing not back behind the relabelled reference');
  });
});

describe('T5 (control) typing inside the copy footnote DEFINITION, in the Notes region', () => {
  // Typing inside a footnote definition of the Notes region (code review): the definition is part of the text in the saved post-op
  // document, so the typing inside it is redone. Expected green before and after.
  it('T5: Duplicate a footnoted chapter, type behind the copy definition in the Notes, Cmd-Z x2, Cmd-Shift-Z x2: the typing is back', () => {
    const documentWith = (withCopy: boolean, typing = ''): string =>
      documentOf([
        chapter('Chapter 1', ['First chapter text.']),
        chapter('Chapter 3', ['Third chapter text.[^1]']),
        ...(withCopy ? [chapter('Chapter 3 copy', ['Third chapter text.[^2]'])] : []),
        chapter('Notes', ['[^1]: Note one.', ...(withCopy ? [`[^2]: Note two.${typing}`] : [])]),
      ]);
    const pre = documentWith(false);
    const post = documentWith(true);
    load(pre);
    oldBodyDuplicate(post);
    typeAfterNth('[^2]: Note two.', 0, TYPED);
    const typedDoc = docText();
    expect(typedDoc === documentWith(true, TYPED), 'PREMISE: the typing is in the copy definition').toBe(true);

    textUndo(post, 'Cmd-Z 1 (the typing)');
    structuralUndo(pre);
    structuralRedo(post);
    press('redo');
    expect(structuralRedoRequested, 'PREMISE: the last Cmd-Shift-Z was not routed structural').not.toHaveBeenCalled();

    expectBackAsTyped(typedDoc, 'typing inside the copy definition not back');
  });
});

describe('T4 what the put-back and the renumber-keep send to Swift', () => {
  // Code review BR-F7: the claim "nothing sent to Swift changes" is pinned here. A state install is no transaction: it posts no
  // contentChanged / historyEdited of its own; the redo's own change posts one debounced contentChanged (50 ms) with the live text and
  // wasUndo=false; the only selection message a teardown can send is the empty one that clears the status bar's count.
  // The message assertions are PINS (they pass with and without the fix). The first test also pins the new trace lines (code review
  // BR-F13 / BR-F3): the undo's carry line says how many events were set aside, the put-back line how long it took.
  // Break patch (T4.patch): in api-structural-markdown.ts drop ` setAside=${setAsideCount}` from the carry trace line.
  // Predicted failure: `the undo trace does not say how many events were set aside`.
  const messagesAreOnlyTheRedosOwn = (what: string): void => {
    expect(contentChanged, `${what}: contentChanged posts`).toHaveBeenCalledTimes(1);
    expect(contentChanged, `${what}: contentChanged payload`).toHaveBeenCalledWith({
      content: docText(),
      wasUndo: false,
    });
    expect(historyEdited, `${what}: historyEdited was posted`).not.toHaveBeenCalled();
    for (const [text] of selectionChanged.mock.calls) expect(text, `${what}: a selection text was posted`).toBe('');
  };

  it('after a Markdown put-back: one contentChanged with the live text and wasUndo=false, no historyEdited, selectionChanged only ""; the trace lines carry setAside= and ms=', () => {
    vi.useFakeTimers();
    try {
      const book = smallBook();
      load(book.pre);
      oldBodyDuplicate(book.post);
      typeAfterNth(book.marker, 1, TYPED);
      textUndo(book.post, 'Cmd-Z 1 (the typing)');
      structuralUndo(book.pre);
      expect(
        traces.some((t) => /redo carry events=\d+ dropped=\d+ setAside=1\b/.test(t)),
        'the undo trace does not say how many events were set aside'
      ).toBe(true);
      vi.advanceTimersByTime(500); // everything the steps so far scheduled has fired
      contentChanged.mockClear();
      historyEdited.mockClear();
      selectionChanged.mockClear();

      structuralRedo(book.post); // the redo, and as its last step the put-back
      vi.advanceTimersByTime(60);

      expect(redoDepth(view.state), 'PREMISE: the put-back installed the typing').toBe(1);
      messagesAreOnlyTheRedosOwn('put-back');
      expect(
        traces.some((t) => /redo put-back events=1 dropped=0 ms=\d+/.test(t)),
        'the put-back trace does not carry events, dropped and ms'
      ).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it('after a renumber-keep: one contentChanged with the live text and wasUndo=false, no historyEdited, selectionChanged only ""', () => {
    vi.useFakeTimers();
    try {
      const base = bookOf(
        (ordinal) => [`${ordinal} chapter text.[^${ordinal === 'Fourth' ? 4 : 3}]`],
        'Third chapter text.[^3]'
      );
      load(base.pre);
      oldBodyDuplicate(base.post);
      typeAfterNth(base.marker, 1, TYPED);
      textUndo(base.post, 'Cmd-Z 1 (the typing)');
      structuralUndo(base.pre);
      structuralRedo(base.post);
      expect(redoDepth(view.state), 'PREMISE: the put-back installed the typing').toBe(1);
      vi.advanceTimersByTime(500);
      contentChanged.mockClear();
      historyEdited.mockClear();
      selectionChanged.mockClear();

      ff().renumberFootnotes({ '4': '5' }); // a recorded change with a redo list waiting: the list is kept through a state install
      vi.advanceTimersByTime(60);

      expect(redoDepth(view.state), 'PREMISE: the renumber kept the list').toBe(1);
      messagesAreOnlyTheRedosOwn('renumber-keep');
    } finally {
      vi.useRealTimers();
    }
  });
});
