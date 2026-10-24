// @vitest-environment jsdom
//
// t-4a8fd8af, slice 1, round 2a: the PAGE half of the editor-first structural commands in Markdown mode (Delete Section only).
// web/codemirror/src/api-structural-markdown.ts: `markdownStructuralEditorFirst` (the click) and `markdownStructuralSwap` (the undo and
// redo turn).
//
// These tests drive the REAL page: they import the real main.ts (the real extension set via `buildExtensions()`, the real update
// listeners -- the registry advancement, the debounced contentChanged / sectionChanged posts --, the real capture-phase Cmd-Z
// interceptor, the real window.FinalFinal) into jsdom, as structural-redo-branch-pin.test.ts does. Cmd-Z / Cmd-Shift-Z are real
// KeyboardEvents; Swift's side of the bridge is played by the helpers below (setUndoDescriptor, receiveUndoOutcome).
//
// Each test names the break patch (a 1-5 line change in the new code) that must make it fail, and the failure it then shows. The
// driver applies the break, runs the test, and restores the code.

import { redoDepth, undoDepth } from '@codemirror/commands';
import { ChangeSet } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MarkdownManagedRegionResult } from '../api-managed-region';
import type { MarkdownLeader, MarkdownStructuralRequest, MarkdownStructuralResult } from '../api-structural-markdown';
import { readImageMeta } from '../image-preview-plugin';
import {
  decideLiveRouting,
  decideUndoRouting,
  getRegistry,
  getUndoDescriptor,
  isLatched,
  LATCH_TIMEOUT_MS,
} from '../undo-coordinator';

type FF = {
  setContent: (md: string, options?: unknown) => void;
  getContentRaw: () => string;
  setUndoDescriptor: (d: { undoTopOpId?: string; redoTopOpId?: string }) => void;
  receiveUndoOutcome: (opId: string, outcome: string) => void;
  receiveRedoOutcome: (opId: string, outcome: string) => void;
  resetForProjectSwitch: () => void;
  clearStructuralUndoRegistry: () => void;
  renumberFootnotes: (mapping: Record<string, string>) => void;
  setImageMeta: (meta: Array<{ src: string; width?: number | null }>) => void;
  markdownStructuralEditorFirst: (request: string | object) => MarkdownStructuralResult;
  markdownStructuralSwap: (
    opId: string,
    direction: 'undo' | 'redo',
    requestJson?: string | object
  ) => MarkdownStructuralResult;
  heldUndoPressCount: () => number;
  setStructuralSettleOpId: (opId: string | null) => void;
  markdownReplaceManagedRegion: (request: string | object) => MarkdownManagedRegionResult;
};
const ff = (): FF => (window as any).FinalFinal as FF;

const OP = '11111111-2222-3333-4444-555555555555';
const EARLIER_OP = '77777777-2222-3333-4444-555555555555';

let structuralUndoRequested: ReturnType<typeof vi.fn>;
let structuralRedoRequested: ReturnType<typeof vi.fn>;
let contentChanged: ReturnType<typeof vi.fn>;
let sectionChanged: ReturnType<typeof vi.fn>;
let undoHeldPressSettled: ReturnType<typeof vi.fn>;
let undoQueueDropped: ReturnType<typeof vi.fn>;
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

/** A real Cmd-Z / Cmd-Shift-Z keydown on the editor. */
function press(direction: 'undo' | 'redo', repeat = false): void {
  const isRedo = direction === 'redo';
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', {
      key: isRedo ? 'Z' : 'z',
      code: 'KeyZ',
      keyCode: 90,
      ctrlKey: true, // jsdom's navigator.platform is not a Mac, so CodeMirror's `Mod` is Ctrl; the page accepts meta or ctrl
      shiftKey: isRedo,
      repeat,
      bubbles: true,
      cancelable: true,
    })
  );
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

function build(blocks: Block[]): Built {
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
      const line = `${'#'.repeat(b.level)} ${b.title}`;
      const anchor = b.anchored === false ? '' : `<!-- @sid:${sid(b.id)} -->`;
      const glue = b.glueMarker ? '<!-- ::auto-bibliography:: -->' : '';
      parts.push(`${glue}${anchor}${line}`);
      leaders.push({ id: b.id, line, level: b.level, ...(b.managed ? { managed: b.managed } : {}) });
    }
  }
  return { text: `${parts.join('\n\n')}\n`, leaders, blocks };
}

/** The request Swift would send for deleting `rootId` (stopLine and endLeaderId derived the way the database rule derives them). */
function requestFor(built: Built, rootId: string, opId = OP): MarkdownStructuralRequest {
  const rootIdx = built.blocks.findIndex((b) => b.kind !== 'text' && b.id === rootId);
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
    kind: 'delete',
    opId,
    rootId,
    leaders: built.leaders,
    stopLine,
    endLeaderId: endLeader ? endLeader.id : null,
  };
}

const ch = (
  n: number,
  body = `Text of chapter ${n}.`,
  extra: Partial<Extract<Block, { kind: 'leader' }>> = {}
): Block[] => [
  { kind: 'leader', id: `h${n}`, level: 1, title: `Chapter ${n}`, ...extra },
  { kind: 'text', text: body },
];

/** Four chapters; chapter 3 has a sub-section. */
const docA = (): Built =>
  build([
    ...ch(1),
    ...ch(2),
    ...ch(3),
    { kind: 'leader', id: 'h3a', level: 2, title: 'Part 3.1' },
    { kind: 'text', text: 'Text of part 3.1.' },
    ...ch(4),
  ]);

/** `text` without the span from the start of the line holding `fromMarker` to the start of the line holding `toMarker` (end of text when absent). */
function without(text: string, fromMarker: string, toMarker?: string): string {
  const lineStart = (marker: string): number => text.lastIndexOf('\n', text.indexOf(marker)) + 1;
  const from = lineStart(fromMarker);
  const to = toMarker === undefined ? text.length : lineStart(toMarker);
  return text.slice(0, from) + text.slice(to);
}

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
  contentChanged.mockClear();
  sectionChanged.mockClear();
  undoHeldPressSettled.mockClear();
  undoQueueDropped.mockClear();
  errorHandlerMessages.length = 0;
  expect(docText()).toBe(text);
  expect(undoDepth(view.state)).toBe(0);
  expect(redoDepth(view.state)).toBe(0);
}

/** The click, then what Swift does once the entry is recorded: push the descriptor. */
function clickDelete(built: Built, rootId: string, opId = OP): MarkdownStructuralResult {
  const result = ff().markdownStructuralEditorFirst(JSON.stringify(requestFor(built, rootId, opId)));
  if (result.ok) ff().setUndoDescriptor({ undoTopOpId: opId });
  return result;
}

/** Swift's reply once a swap has been carried out: the descriptor moves, the latch is released. */
function swiftPerformedUndo(opId = OP): void {
  ff().setUndoDescriptor({ redoTopOpId: opId });
  ff().receiveUndoOutcome(opId, 'performed');
}
function swiftPerformedRedo(opId = OP): void {
  ff().setUndoDescriptor({ undoTopOpId: opId });
  ff().receiveRedoOutcome(opId, 'performed');
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
  structuralUndoRequested = vi.fn();
  structuralRedoRequested = vi.fn();
  contentChanged = vi.fn();
  sectionChanged = vi.fn();
  undoHeldPressSettled = vi.fn();
  undoQueueDropped = vi.fn();
  (window as any).webkit = {
    messageHandlers: {
      structuralUndoRequested: { postMessage: structuralUndoRequested },
      structuralRedoRequested: { postMessage: structuralRedoRequested },
      structuralUndoRefused: { postMessage: vi.fn() },
      historyEdited: { postMessage: vi.fn() },
      contentChanged: { postMessage: contentChanged },
      sectionChanged: { postMessage: sectionChanged },
      undoHeldPressSettled: { postMessage: undoHeldPressSettled },
      undoQueueDropped: { postMessage: undoQueueDropped },
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

  // main.ts builds the real extension set (`buildExtensions()`), mounts the real editor into #editor at import time, and registers the
  // real window.FinalFinal.
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
// The click
// =============================================================================================================================

describe('W1 the click: Delete with typing before it', () => {
  // Break patch: in planDelete (api-structural-markdown.ts) replace `let end = stopIdx >= 0 ? scan.candidates[stopIdx].from : doc.length;`
  // by `let end = doc.length;` (drop the range end computation).
  // Predicted failure: `the section ran on into chapter 4: expected '...' to contain 'Text of chapter 4.'`.
  it('removes the section and its sub-section, keeps the typing, and the entry holds the pre-op document with the typing in it', () => {
    const built = docA();
    load(built.text);
    typeAfter('Text of chapter 2.', ' hello there');
    expect(undoDepth(view.state)).toBe(1);

    const typedPre = docText();
    const result = clickDelete(built, 'h3');

    expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);
    expect(result.preRaw).toBe(typedPre);
    expect(result.postRaw).toBe(docText());
    expect(docText()).not.toContain('Chapter 3');
    expect(docText()).not.toContain('Part 3.1');
    expect(docText()).toContain('Text of chapter 2. hello there');
    expect(docText(), 'the section ran on into chapter 4').toContain('Text of chapter 4.');
    expect(docText()).toBe(without(typedPre, 'Chapter 3', 'Chapter 4'));

    const entry = getRegistry().get(OP);
    expect(entry).toBeDefined();
    expect(entry?.preOpDoc.toString()).toBe(typedPre);
    expect(entry?.preOpDoc.toString()).toContain('hello there');
    expect(entry?.postOpDoc.eq(view.state.doc)).toBe(true);
    expect(entry?.midOp).toBe(false);
    expect(entry?.checkpoint.doc.toString()).toBe(typedPre);

    // The delete is not a text-history step (addToHistory:false); the typing before it still is.
    expect(undoDepth(view.state)).toBe(1);
  });

  it('a second command under another opId does not touch the first entry', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3', OP).ok).toBe(true);
    const first = getRegistry().get(OP);
    const OP2 = '99999999-2222-3333-4444-555555555555';
    const built2 = build([...ch(1), ...ch(2), ...ch(4)]); // the document as it is now
    expect(docText()).toBe(without(built.text, 'Chapter 3', 'Chapter 4'));
    const second = ff().markdownStructuralEditorFirst(JSON.stringify(requestFor(built2, 'h2', OP2)));
    expect(second.ok, JSON.stringify(second)).toBe(true);
    expect(getRegistry().get(OP)).toBe(first);
    expect(getRegistry().get(OP2)?.midOp).toBe(false);
  });
});

describe('W1b the click sets the undo top itself: a Cmd-Z before Swift pushes the descriptor still brings the section back', () => {
  // On a long book Swift's `pushDescriptor()` reaches the page only after the writer's last write has finished and the delete's job has
  // reserved its place (more than a second), while the page removed the section at once. These tests play that gap: the click is made
  // and Swift's push has NOT arrived (no `setUndoDescriptor` call; the `clickDelete` helper above pushes it, so these call the page
  // directly).
  //
  // Break patch (cases a1, a2, b): in markdownStructuralEditorFirst (api-structural-markdown.ts) delete the line
  // `if (result.ok) setUndoDescriptor({ undoTopOpId: parsed.request.opId });` (leave the descriptor to Swift's later push).
  // Predicted failures: a1 `the Cmd-Z in the gap was not routed structural: expected { action: 'fallthrough' } to deeply equal ...`;
  // a2 `the Cmd-Z in the gap did not ask Swift for the structural undo`; b `the Cmd-Z in the gap beeped`.
  it('a1: after the click and before any push from Swift, routing for Cmd-Z is structural for the opId of that click', () => {
    const built = docA();
    load(built.text);

    const result = ff().markdownStructuralEditorFirst(JSON.stringify(requestFor(built, 'h3')));
    expect(result.ok, JSON.stringify(result)).toBe(true);

    expect(
      decideLiveRouting(view, 'undo'),
      'the Cmd-Z in the gap was not routed structural: the page waited for the descriptor from Swift'
    ).toEqual({ action: 'structural', opId: OP });
    // The page sets the undo top and nothing else: there is no redo entry for a fresh delete.
    expect(getUndoDescriptor()).toEqual({ undoTopOpId: OP });
  });

  it('a2: typing came before the click; Cmd-Z in the gap asks Swift for the structural undo and leaves the typing alone', () => {
    const built = docA();
    load(built.text);
    typeAfter('Text of chapter 2.', ' kept typing');
    const typedPre = docText();
    expect(undoDepth(view.state)).toBe(1);

    expect(ff().markdownStructuralEditorFirst(JSON.stringify(requestFor(built, 'h3'))).ok).toBe(true);
    const postDoc = view.state.doc;

    press('undo'); // Swift's push has not arrived
    expect(
      structuralUndoRequested,
      'the Cmd-Z in the gap did not ask Swift for the structural undo'
    ).toHaveBeenCalledTimes(1);
    expect(structuralUndoRequested).toHaveBeenCalledWith({ opId: OP });
    expect(isLatched()).toBe(true);
    // The editor's own text undo did not run: the typed words are still there and the text history is untouched.
    expect(view.state.doc).toBe(postDoc);
    expect(docText()).toContain('Text of chapter 2. kept typing');
    expect(undoDepth(view.state)).toBe(1);

    // Swift then carries the undo out through the existing turn: the section is back, with the typing before the delete.
    const undone = ff().markdownStructuralSwap(OP, 'undo');
    expect(undone.ok, JSON.stringify(undone)).toBe(true);
    expect(docText()).toBe(typedPre);
  });

  it('b: with no text history at all, the Cmd-Z in the gap does not beep', () => {
    const built = docA();
    load(built.text); // a fresh document: nothing typed, nothing to undo as text
    expect(undoDepth(view.state)).toBe(0);
    const handlers = (window as any).webkit.messageHandlers;
    const original = handlers.structuralUndoRefused;
    const refused = vi.fn();
    handlers.structuralUndoRefused = { postMessage: refused };
    try {
      expect(ff().markdownStructuralEditorFirst(JSON.stringify(requestFor(built, 'h3'))).ok).toBe(true);

      press('undo'); // Swift's push has not arrived

      expect(refused, 'the Cmd-Z in the gap beeped (structuralUndoRefused)').not.toHaveBeenCalled();
      expect(errorHandlerMessages.some((m) => m.includes('refusal beep'))).toBe(false);
      expect(structuralUndoRequested).toHaveBeenCalledWith({ opId: OP });
    } finally {
      handlers.structuralUndoRefused = original;
    }
  });

  // Guard (passes with and without the page-side set): a refused click changes nothing, the descriptor included.
  // Break patch: in markdownStructuralEditorFirst replace the guarded line by an unconditional `setUndoDescriptor({ undoTopOpId: parsed.request.opId });`
  // (or move it above `runDelete`). Predicted failure: `a refused click changed the descriptor`.
  it.each([
    [
      'leadersMismatch',
      (built: Built): MarkdownStructuralResult => {
        typeAt(docText().length, '\n# Extra heading\n'); // a heading typed a moment ago: the leaders no longer match the rows
        return ff().markdownStructuralEditorFirst(JSON.stringify(requestFor(built, 'h3')));
      },
    ],
    ['badRequest', (): MarkdownStructuralResult => ff().markdownStructuralEditorFirst('{not json')],
  ] as Array<
    [string, (built: Built) => MarkdownStructuralResult]
  >)('c: a refused click (%s) leaves the descriptor as it was', (reason, click) => {
    const built = docA();
    load(built.text);
    // Something is already on both stacks: the descriptor Swift pushed after earlier operations.
    ff().setUndoDescriptor({ undoTopOpId: EARLIER_OP, redoTopOpId: 'redo-top' });
    const before = getUndoDescriptor();

    const result = click(built);

    expect(result).toMatchObject({ ok: false, reason });
    expect(getUndoDescriptor(), 'a refused click changed the descriptor').toBe(before);
    expect(getUndoDescriptor()).toEqual({ undoTopOpId: EARLIER_OP, redoTopOpId: 'redo-top' });
  });

  // Guard (passes with and without the page-side set): the quick redo re-runs the delete through the same internal function but must NOT
  // set the descriptor: the redo stack beneath may hold more entries, and clearing `redoTopOpId` would switch `historyEdited` off.
  // Break patch: move the `setUndoDescriptor` call from markdownStructuralEditorFirst into runDelete (after the `finally`, before
  // `return { ok: true, ... }`). Predicted failure: `the quick redo changed the descriptor`.
  it('d: the quick redo (markdownStructuralSwap redo) leaves the descriptor alone', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    press('undo');
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    swiftPerformedUndo(); // descriptor: { redoTopOpId: OP }, latch released
    expect(getUndoDescriptor()).toEqual({ redoTopOpId: OP });
    const before = getUndoDescriptor();

    press('redo'); // routed structural: the latch goes up for the redo
    expect(structuralRedoRequested).toHaveBeenCalledWith({ opId: OP });
    const redone = ff().markdownStructuralSwap(OP, 'redo', requestFor(built, 'h3'));
    expect(redone.ok, JSON.stringify(redone)).toBe(true);
    expect(docText()).toBe(without(built.text, 'Chapter 3', 'Chapter 4'));

    expect(getUndoDescriptor(), 'the quick redo changed the descriptor').toBe(before);
    expect(getUndoDescriptor()).toEqual({ redoTopOpId: OP });
  });
});

describe('W2 a leader mismatch changes nothing', () => {
  // Break patch (second case): in planDelete delete the whole `if (scan.candidates.length !== leaders.length) { return mismatch(...) }`
  // block (accept the count mismatch).
  // Predicted failure: `doc changed on mismatch` (the delete ran on stale leaders and removed chapter 3).
  it.each([
    ['a heading renamed a moment ago', () => typeAfter('# Chapter 2', ' revised')],
    ['a heading typed a moment ago at the end of the document', () => typeAt(docText().length, '\n# Extra heading\n')],
  ] as Array<[string, () => void]>)('%s: ok:false leadersMismatch, no entry, no dispatch', (_label, mutate) => {
    const built = docA();
    load(built.text);
    mutate();
    const docBefore = view.state.doc;
    const depthBefore = undoDepth(view.state);
    const dispatchSpy = vi.spyOn(view, 'dispatch');

    const result = ff().markdownStructuralEditorFirst(JSON.stringify(requestFor(built, 'h3')));
    const dispatched = dispatchSpy.mock.calls.length;
    dispatchSpy.mockRestore();

    expect(view.state.doc, 'doc changed on mismatch').toBe(docBefore);
    expect(result.ok).toBe(false);
    expect(result.reason).toBe('leadersMismatch');
    expect(getRegistry().size, 'a mismatch recorded an entry').toBe(0);
    expect(dispatched, 'a mismatch dispatched').toBe(0);
    expect(undoDepth(view.state)).toBe(depthBefore);
  });

  it('a stale stopLine (the database has a Notes row the text does not) is a mismatch too', () => {
    const built = docA();
    load(built.text);
    const request = { ...requestFor(built, 'h3'), stopLine: '## Notes' };
    const docBefore = view.state.doc;
    const result = ff().markdownStructuralEditorFirst(JSON.stringify(request));
    expect(result).toMatchObject({ ok: false, reason: 'leadersMismatch' });
    expect(view.state.doc).toBe(docBefore);
    expect(getRegistry().size).toBe(0);
  });

  it('answers unsupportedKind for any other kind and badRequest for junk, changing nothing', () => {
    const built = docA();
    load(built.text);
    const docBefore = view.state.doc;
    expect(
      ff().markdownStructuralEditorFirst(JSON.stringify({ ...requestFor(built, 'h3'), kind: 'duplicate' }))
    ).toMatchObject({
      ok: false,
      reason: 'unsupportedKind',
    });
    expect(ff().markdownStructuralEditorFirst('{not json')).toMatchObject({ ok: false, reason: 'badRequest' });
    expect(
      ff().markdownStructuralEditorFirst(JSON.stringify({ kind: 'delete', opId: OP, rootId: 'h3', leaders: 'no' }))
    ).toMatchObject({
      ok: false,
      reason: 'badRequest',
    });
    // A managed (Notes/Bibliography) row is never a deletable root.
    const withNotes = build([...ch(1), { kind: 'leader', id: 'hn', level: 1, title: 'Notes', managed: 'notes' }]);
    load(withNotes.text);
    expect(ff().markdownStructuralEditorFirst(JSON.stringify(requestFor(withNotes, 'hn')))).toMatchObject({
      ok: false,
      reason: 'badRequest',
    });
    expect(view.state.doc.toString()).toBe(withNotes.text);
    expect(getRegistry().size).toBe(0);
    void docBefore;
  });
});

describe('W3 end rules', () => {
  // Break patch: in api-structural-markdown.ts shrink LEADING_HIDDEN to anchors only, i.e. remove the two bibliography alternatives
  // (`|<!-- ::auto-bibliography:: -->|<!-- ::auto-bibliography-end:: -->`): the managed-marker strip.
  // Predicted failure (first case): `delete refused: {"ok":false,"reason":"leadersMismatch","detail":"leaderCount editor=3 database=4"}`
  // (the bibliography heading line, glued to its opening marker, is no longer recognised as a leader).
  const bibEntry: Block[] = [
    { kind: 'text', text: 'Smith, J. (2020). A book.' },
    { kind: 'text', text: '<!-- ::auto-bibliography-end:: -->' },
  ];

  it('the last chapter before the Bibliography (marker glued to the heading line) ends at the Bibliography', () => {
    const built = build([
      ...ch(1),
      ...ch(2),
      ...ch(3),
      { kind: 'leader', id: 'hb', level: 1, title: 'Bibliography', managed: 'bibliography', glueMarker: true },
      ...bibEntry,
    ]);
    load(built.text);
    const result = clickDelete(built, 'h3');
    expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText()).toBe(without(built.text, 'Chapter 3', '# Bibliography'));
    expect(docText()).toContain('<!-- ::auto-bibliography:: --><!-- @sid:');
    expect(docText()).toContain('<!-- ::auto-bibliography-end:: -->');
    expect(docText()).not.toContain('Chapter 3');
  });

  it('the last chapter before a standalone bibliography opening marker row ends at that row (stopLine)', () => {
    const built = build([
      ...ch(1),
      ...ch(2),
      ...ch(3),
      { kind: 'text', text: '<!-- ::auto-bibliography:: -->', managedRow: true },
      { kind: 'leader', id: 'hb', level: 1, title: 'Bibliography', managed: 'bibliography' },
      ...bibEntry,
    ]);
    load(built.text);
    const request = requestFor(built, 'h3');
    expect(request.stopLine).toBe('<!-- ::auto-bibliography:: -->');
    const result = ff().markdownStructuralEditorFirst(JSON.stringify(request));
    expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText()).toBe(without(built.text, 'Chapter 3', '<!-- ::auto-bibliography:: -->'));
    expect(docText()).toContain('<!-- ::auto-bibliography:: -->\n\n<!-- @sid:');
  });

  it('a section break behind an anchor is level 1: it ends a chapter and its sub-section, and is itself a section that ends at the next chapter', () => {
    const built = build([
      ...ch(1),
      { kind: 'leader', id: 'h1a', level: 2, title: 'Part 1.1' },
      { kind: 'text', text: 'Text of part 1.1.' },
      { kind: 'break', id: 'br' },
      { kind: 'text', text: 'Text after the break.' },
      ...ch(2),
    ]);
    load(built.text);
    expect(built.text).toContain('<!-- @sid:');
    expect(built.text).toMatch(/<!-- @sid:[0-9a-f-]+ --><!-- ::break:: -->/);
    expect(clickDelete(built, 'h1').ok).toBe(true);
    expect(docText()).toBe(without(built.text, 'Chapter 1', '<!-- ::break:: -->'));
    expect(docText()).toContain('<!-- ::break:: -->');
    expect(docText()).not.toContain('Part 1.1');

    load(built.text);
    expect(clickDelete(built, 'br').ok).toBe(true);
    expect(docText()).toBe(without(built.text, '<!-- ::break:: -->', '# Chapter 2'));
    expect(docText()).toContain('Text of part 1.1.');
    expect(docText()).not.toContain('Text after the break.');
    expect(docText()).toContain('# Chapter 2');
  });

  it('a Notes H2 after an H1 chapter is not part of the chapter', () => {
    const built = build([
      ...ch(1),
      ...ch(2),
      { kind: 'leader', id: 'hn', level: 2, title: 'Notes', managed: 'notes' },
      { kind: 'text', text: '[^1]: A note.' },
    ]);
    load(built.text);
    const result = clickDelete(built, 'h2');
    expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText()).toBe(without(built.text, 'Chapter 2', '## Notes'));
    expect(docText()).toContain('## Notes');
    expect(docText()).toContain('[^1]: A note.');
  });

  it('fenced code and display math are skipped by the line rule: a "# comment" inside a fence is not a leader', () => {
    const built = build([...ch(1, 'Intro.\n\n```sh\n# not a heading\n```\n\n$$\n# nor this\n$$\n\nOutro.'), ...ch(2)]);
    load(built.text);
    const result = clickDelete(built, 'h1');
    expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText()).toBe(without(built.text, 'Chapter 1', 'Chapter 2'));
    expect(docText()).not.toContain('not a heading');
  });
});

describe('W4 footnote definitions that only the removed section used go with it', () => {
  // Break patch: in planDelete pass an empty set to the definition ranges, i.e. replace
  // `const definitionRanges = orphanDefinitionRanges(doc, scan, notesIdx, orphans, end);` by `const definitionRanges: Array<{ from: number; to: number }> = [];`.
  // Predicted failure: `duplicate [^4]: after renumber` (the orphan definition stays; the resync's renumber 6 -> 4 makes a second one).
  const notesDoc = (): Built =>
    build([
      ...ch(1, 'Chapter one cites a note.[^1]'),
      ...ch(2, 'Chapter two cites two.[^2] Again.[^3]'),
      ...ch(3, 'Chapter three cites three.[^3][^4][^5]'),
      ...ch(4, 'Chapter four cites one.[^6]'),
      { kind: 'leader', id: 'hn', level: 1, title: 'Notes', managed: 'notes' },
      { kind: 'text', text: '[^1]: Note one.' },
      { kind: 'text', text: '[^2]: Note two.' },
      { kind: 'text', text: '[^3]: Note three, shared with chapter two.' },
      { kind: 'text', text: '[^4]: Note four, only in chapter three,\n    which continues here.' },
      { kind: 'text', text: '[^5]: Note five, only in chapter three.' },
      { kind: 'text', text: '[^6]: Note six.' },
    ]);

  it('removes the orphan definitions (with their continuation lines), keeps the shared one, and the resync renumber leaves no duplicate label', () => {
    const built = notesDoc();
    load(built.text);
    const result = clickDelete(built, 'h3');
    expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);

    const post = docText();

    // The footnote resync then renumbers 6 to 4 (labels 4 and 5 are gone): every label is defined exactly once.
    ff().renumberFootnotes({ '6': '4' });
    const defined = [...docText().matchAll(/^\[\^(\d+)\]:/gm)].map((m) => m[1]);
    const duplicates = defined.filter((label, i) => defined.indexOf(label) !== i);
    expect(duplicates, `duplicate [^${duplicates[0]}]: after renumber`).toEqual([]);
    expect(defined).toEqual(['1', '2', '3', '4']);

    expect(post).not.toContain('Chapter three');
    expect(post).not.toContain('Note four');
    expect(post).not.toContain('which continues here');
    expect(post).not.toContain('Note five');
    expect(post).toContain('[^1]: Note one.');
    expect(post).toContain('[^2]: Note two.');
    expect(post).toContain('[^3]: Note three, shared with chapter two.');
    expect(post).toContain('[^6]: Note six.');
    // Exactly what the section's range and its two definition blocks come to:
    const expected = without(
      without(without(built.text, 'Chapter 3', 'Chapter 4'), '[^4]: Note four', '[^5]: Note five'),
      '[^5]: Note five',
      '[^6]: Note six'
    );
    expect(post).toBe(expected);
  });
});

describe('W4b the Notes region cannot be found', () => {
  // Break patch: in orphanDefinitionRanges replace `if (notesIdx < 0 || orphans.size === 0) return [];` by
  // `if (notesIdx < 0) throw new Error('delete refused without Notes');`.
  // Predicted failure: `delete refused without Notes: {"ok":false,"reason":"badRequest","detail":"planThrew"}`.
  it('a document with footnote definitions but no Notes heading: the delete goes ahead and the definitions stay', () => {
    const built = build([
      ...ch(1, 'Chapter one.[^1]'),
      ...ch(2, 'Chapter two.[^2]'),
      { kind: 'text', text: '[^1]: Note one.', managedRow: true },
      { kind: 'text', text: '[^2]: Note two.' },
    ]);
    load(built.text);
    const result = clickDelete(built, 'h2');
    expect(result.ok, `delete refused without Notes: ${JSON.stringify(result)}`).toBe(true);
    expect(docText()).toBe(without(built.text, 'Chapter 2', '[^1]: Note one.'));
    expect(docText()).toContain('[^1]: Note one.');
    expect(
      docText(),
      'the definition of a label only the removed chapter used was removed although no Notes region was found'
    ).toContain('[^2]: Note two.');
  });
});

// =============================================================================================================================
// The swap
// =============================================================================================================================

describe('W5 the swap re-checks the document', () => {
  // Break patch: in decideRouting (undo-coordinator.ts) insert, right after the `isOwnRequest` line,
  // `if (isOwnRequest) return { action: 'structural', opId: params.ownRequestOpId as string };` (answer "yes" for the in-flight request
  // without comparing the documents).
  // Predicted failure: `typing "kp4" gone after refused swap`.
  it('refuses when the user typed between the key press and the swap, and changes nothing', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    const postDoc = view.state.doc;
    const entry = getRegistry().get(OP);

    press('undo');
    expect(structuralUndoRequested).toHaveBeenCalledTimes(1);
    expect(structuralUndoRequested).toHaveBeenCalledWith({ opId: OP });
    expect(isLatched()).toBe(true);

    typeAfter('Text of chapter 2.', ' kp4'); // Swift reserves its writer ticket in between; the user keeps typing
    const typedDoc = view.state.doc;
    const depth = undoDepth(view.state);

    const result = ff().markdownStructuralSwap(OP, 'undo');

    expect(docText(), 'typing "kp4" gone after refused swap').toContain('kp4');
    expect(view.state.doc).toBe(typedDoc);
    expect(result).toMatchObject({ ok: false, reason: 'changed' });
    expect(undoDepth(view.state)).toBe(depth);
    expect(getRegistry().get(OP)?.midOp).toBe(false);
    expect(getRegistry().get(OP)?.postOpDoc).toBe(entry?.postOpDoc);
    expect(getRegistry().get(OP)?.postOpDoc).toBe(postDoc);
    expect(getRegistry().get(OP)?.checkpoint).toBe(entry?.checkpoint);
  });

  it('a press while a DIFFERENT request is in flight is consumed and HELD (keydown and menu pass no ownRequestOpId)', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    press('undo');
    expect(structuralUndoRequested).toHaveBeenCalledTimes(1);
    press('undo'); // the second press during the latch: consumed (no text undo), not routed again, kept for the reply
    expect(structuralUndoRequested).toHaveBeenCalledTimes(1);
    expect(undoDepth(view.state)).toBe(0);
    expect(ff().heldUndoPressCount()).toBe(1);
    // and the swap for some other opId cannot use the latch
    expect(ff().markdownStructuralSwap('0000-other', 'undo')).toMatchObject({ ok: false, reason: 'noEntry' });
  });

  it('the pure routing function: latched + own request compares documents; latched + anyone else is swallowed', () => {
    const registry = new Map([['a', { postOpDoc: 'POST', preOpDoc: 'PRE' }]]);
    const base = {
      descriptor: { undoTopOpId: 'a' },
      registry,
      pendingMapsEmpty: true,
      latched: true,
      docsEqual: (x: string, y: string) => x === y,
    };
    expect(decideUndoRouting({ ...base, currentDoc: 'POST', ownRequestOpId: 'a', inFlightOpId: 'a' })).toEqual({
      action: 'structural',
      opId: 'a',
    });
    expect(decideUndoRouting({ ...base, currentDoc: 'POST+typing', ownRequestOpId: 'a', inFlightOpId: 'a' })).toEqual({
      action: 'fallthrough',
    });
    expect(decideUndoRouting({ ...base, currentDoc: 'POST', ownRequestOpId: 'b', inFlightOpId: 'a' })).toEqual({
      action: 'swallow',
    });
    expect(decideUndoRouting({ ...base, currentDoc: 'POST', inFlightOpId: 'a' })).toEqual({ action: 'swallow' });
    expect(decideUndoRouting({ ...base, currentDoc: 'POST', ownRequestOpId: 'a', inFlightOpId: null })).toEqual({
      action: 'swallow',
    });
    expect(decideUndoRouting({ ...base, latched: false, currentDoc: 'POST' })).toEqual({
      action: 'structural',
      opId: 'a',
    });
  });
});

describe('W6 undo, redo, undo on one entry, through the real listeners', () => {
  // Break patch: in runDelete (api-structural-markdown.ts) record the entry with `midOp: false` instead of `midOp: true` (v1's bug: the
  // page's own change moves the saved copies).
  // Predicted failure: `the page's own change moved a saved copy (preOpDoc)` (the delete's own dispatch advanced preOpDoc to the post-op
  // document; later, the redo press would not be routed structural: `redo did not change the doc`).
  it('text asserted at every step; no saved copy advances; the latch is released each time', () => {
    const built = docA();
    load(built.text);
    const PRE = built.text;
    const POST = without(PRE, 'Chapter 3', 'Chapter 4');

    expect(clickDelete(built, 'h3').ok).toBe(true);
    expect(docText()).toBe(POST);
    const saved = getRegistry().get(OP);
    const savedPost = saved?.postOpDoc;
    const savedPre = saved?.preOpDoc;
    expect(savedPost?.toString(), "the page's own change moved a saved copy (postOpDoc)").toBe(POST);
    expect(savedPre?.toString(), "the page's own change moved a saved copy (preOpDoc)").toBe(PRE);

    // Cmd-Z -> structural -> Swift's swap
    press('undo');
    expect(structuralUndoRequested).toHaveBeenCalledTimes(1);
    const undone = ff().markdownStructuralSwap(OP, 'undo');
    expect(undone.ok, JSON.stringify(undone)).toBe(true);
    expect(undone.preRaw).toBe(POST);
    expect(undone.postRaw).toBe(PRE);
    expect(docText()).toBe(PRE);
    expect(getRegistry().get(OP)?.postOpDoc, 'a saved copy advanced during the undo').toBe(savedPost);
    expect(getRegistry().get(OP)?.preOpDoc, 'a saved copy advanced during the undo').toBe(savedPre);
    expect(getRegistry().get(OP)?.midOp).toBe(false);
    swiftPerformedUndo();
    expect(isLatched()).toBe(false);

    // Cmd-Shift-Z -> structural -> Swift's swap (the quick redo re-runs the delete under the same opId)
    press('redo');
    expect(
      structuralRedoRequested,
      'redo did not change the doc: the press was not routed structural'
    ).toHaveBeenCalledTimes(1);
    expect(structuralRedoRequested).toHaveBeenCalledWith({ opId: OP });
    const redone = ff().markdownStructuralSwap(OP, 'redo');
    expect(redone.ok, JSON.stringify(redone)).toBe(true);
    expect(redone.preRaw).toBe(PRE);
    expect(redone.postRaw).toBe(POST);
    expect(docText(), 'redo did not change the doc').toBe(POST);
    expect(getRegistry().get(OP)?.postOpDoc.eq(view.state.doc)).toBe(true);
    expect(getRegistry().get(OP)?.preOpDoc.toString()).toBe(PRE);
    expect(getRegistry().get(OP)?.midOp).toBe(false);
    swiftPerformedRedo();
    expect(isLatched()).toBe(false);

    // Cmd-Z again
    press('undo');
    expect(structuralUndoRequested).toHaveBeenCalledTimes(2);
    const undoneAgain = ff().markdownStructuralSwap(OP, 'undo');
    expect(undoneAgain.ok, JSON.stringify(undoneAgain)).toBe(true);
    expect(docText()).toBe(PRE);
    swiftPerformedUndo();
    expect(isLatched()).toBe(false);
    expect(getRegistry().size).toBe(1);
  });

  it('setState dispatches no transaction: the swap posts no contentChanged and no sectionChanged of its own', () => {
    vi.useFakeTimers();
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    vi.advanceTimersByTime(500); // the click's own debounced posts
    press('undo');
    contentChanged.mockClear();
    sectionChanged.mockClear();
    const result = ff().markdownStructuralSwap(OP, 'undo');
    expect(result.ok).toBe(true);
    vi.advanceTimersByTime(1000);
    expect(contentChanged).not.toHaveBeenCalled();
    expect(sectionChanged).not.toHaveBeenCalled();
  });

  it('a slow redo of an entry the OLD body recorded swaps the saved post-op text in, outside the text history, inside midOp', () => {
    const built = docA();
    load(built.text);
    const PRE = built.text;
    const POST = without(PRE, 'Chapter 3', 'Chapter 4');
    // The old body: beginStructuralOp -> setContent(post) -> finalizeStructuralOpPostOpDoc -> descriptor.
    expect((window as any).FinalFinal.beginStructuralOp(OP)).toBe(true);
    ff().setContent(POST);
    expect((window as any).FinalFinal.finalizeStructuralOpPostOpDoc(OP)).toBe(true);
    ff().setUndoDescriptor({ undoTopOpId: OP });
    expect(getRegistry().get(OP)?.markdown).toBeUndefined();

    press('undo');
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true); // the checkpoint of the old body's entry swaps in
    expect(docText()).toBe(PRE);
    swiftPerformedUndo();

    press('redo');
    const depth = undoDepth(view.state);
    const redone = ff().markdownStructuralSwap(OP, 'redo');
    expect(redone).toMatchObject({ ok: true, preRaw: PRE, postRaw: POST });
    expect(docText()).toBe(POST);
    expect(undoDepth(view.state)).toBe(depth);
    expect(getRegistry().get(OP)?.midOp).toBe(false);
  });

  // Review M-3. Break patch: in markdownStructuralSwap's redo branch ignore the request Swift sends (`let request = entry.markdown.request;`
  // without the `if (requestJson !== undefined) { ... }` block). Predicted failure: `a fresh request was ignored: leadersMismatch`.
  it('a redo carrying a FRESH request whose leaders differ from the stored one succeeds; the stored request is refused', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    press('undo');
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    swiftPerformedUndo();

    // The application changes a heading line while the delete is undone (a rebuild, a hierarchy fix): a sync-origin push, which the
    // entry's saved copy follows because the document equalled it. The request stored at the click names the old heading line now.
    const renamed = build([
      ...ch(1),
      { kind: 'leader', id: 'h2', level: 1, title: 'Chapter Two' },
      { kind: 'text', text: 'Text of chapter 2.' },
      ...ch(3),
      { kind: 'leader', id: 'h3a', level: 2, title: 'Part 3.1' },
      { kind: 'text', text: 'Text of part 3.1.' },
      ...ch(4),
    ]);
    ff().setContent(renamed.text);
    expect(docText()).toBe(renamed.text);

    press('redo');
    expect(
      structuralRedoRequested,
      'the press was not routed structural: the saved copy did not follow the push'
    ).toHaveBeenCalledTimes(1);
    const stale = ff().markdownStructuralSwap(OP, 'redo');
    expect(stale, 'premise: the stored request no longer matches').toMatchObject({
      ok: false,
      reason: 'leadersMismatch',
    });
    expect(docText()).toBe(renamed.text);

    const fresh = ff().markdownStructuralSwap(OP, 'redo', requestFor(renamed, 'h3'));
    expect(fresh.ok, `a fresh request was ignored: ${JSON.stringify(fresh)}`).toBe(true);
    expect(docText()).toBe(without(renamed.text, 'Chapter 3', 'Chapter 4'));
    expect(getRegistry().get(OP)?.midOp).toBe(false);
    swiftPerformedRedo();
    expect(isLatched()).toBe(false);
  });
});

describe('B-7 the text history of the deleted section comes back with it', () => {
  // Break patch: in swapUndo replace `view.setState(buildSwappedState(entry, live));` by a minimal diff to the pre-op text:
  // `view.dispatch({ changes: computeMinimalChanges(view.state.doc.toString(), entry.preOpDoc.toString()), annotations: Transaction.addToHistory.of(false) });`
  // Predicted failure: `the second Cmd-Z did not remove the typing inside the restored section`.
  it('type inside Chapter 3, delete it, Cmd-Z, Cmd-Z: the second removes the typing', () => {
    const built = docA();
    load(built.text);
    typeAfter('Text of chapter 3.', ' zq7');
    const typedPre = docText();
    expect(typedPre).toContain('zq7');
    expect(clickDelete(built, 'h3').ok).toBe(true);
    expect(docText()).not.toContain('zq7');

    press('undo');
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    swiftPerformedUndo();
    expect(docText()).toBe(typedPre);
    expect(undoDepth(view.state)).toBe(1);

    press('undo'); // nothing structural on top any more: CodeMirror's own text undo, with the history the checkpoint carried
    expect(structuralUndoRequested).toHaveBeenCalledTimes(1);
    expect(docText(), 'the second Cmd-Z did not remove the typing inside the restored section').toBe(built.text);
  });
});

describe('W9 setState side effects', () => {
  // Break patch: in swapUndo remove the re-apply loop (the `for (const { item, value } of captured) { ... }` block).
  // Predicted failure: `setting reverted after undo` (the image width Swift pushed after the Delete is back to the checkpoint's value).
  it('a setting changed after the Delete survives Cmd-Z; the next key posts contentChanged; the next caret move posts sectionChanged; anchors stay hidden; focus is unchanged', () => {
    vi.useFakeTimers();
    const built = docA();
    load(built.text);
    ff().setImageMeta([{ src: 'media/a.png', width: 300 }]);
    view.focus();
    const hadFocus = view.hasFocus;

    expect(clickDelete(built, 'h3').ok).toBe(true);
    ff().setImageMeta([{ src: 'media/a.png', width: 450 }]); // the setting Swift pushed after the Delete (the checkpoint holds 300)
    vi.advanceTimersByTime(500);

    const renderedLines = (): string[] =>
      [...view.contentDOM.querySelectorAll('.cm-line')].map((el) => el.textContent ?? '');
    const linesBefore = renderedLines();

    press('undo');
    const result = ff().markdownStructuralSwap(OP, 'undo');
    expect(result.ok, JSON.stringify(result)).toBe(true);
    swiftPerformedUndo();

    expect(readImageMeta(view.state), 'setting reverted after undo').toEqual([{ src: 'media/a.png', width: 450 }]);
    expect(view.hasFocus).toBe(hadFocus);

    // Anchor decorations: every `<!-- @sid:... -->` line of the document is rendered with its anchor hidden.
    const anchorLines = docText()
      .split('\n')
      .filter((l) => l.includes('<!-- @sid:'));
    expect(anchorLines.length).toBeGreaterThan(3);
    const linesAfter = renderedLines();
    expect(linesAfter.length, 'no lines rendered after the swap').toBeGreaterThan(0);
    expect(linesBefore.length).toBeGreaterThan(0);
    expect(
      linesAfter.filter((l) => l.includes('@sid')),
      'anchor decorations missing after undo'
    ).toEqual([]);

    // The swap itself posted nothing.
    contentChanged.mockClear();
    sectionChanged.mockClear();
    vi.advanceTimersByTime(1000);
    expect(contentChanged).not.toHaveBeenCalled();

    // The next typed key posts contentChanged with the live document.
    typeAfter('Text of chapter 2.', 'x');
    vi.advanceTimersByTime(100);
    expect(contentChanged, 'the next typed key did not post contentChanged').toHaveBeenCalledTimes(1);
    expect(contentChanged.mock.calls[0][0].content).toContain('Text of chapter 2.x');

    // The next caret move posts sectionChanged for the section the caret is now in.
    sectionChanged.mockClear();
    view.dispatch({ selection: { anchor: docText().indexOf('Text of chapter 4.') + 3 } });
    vi.advanceTimersByTime(300);
    expect(sectionChanged, 'the next caret move did not post sectionChanged').toHaveBeenCalledWith({
      title: 'Chapter 4',
      blockId: null,
    });
  });
});

describe('O1 injected anchors and renumbered footnotes in the post-op document still route structural', () => {
  it('the derived anchor push and the footnote renumber that follow a Delete do not stop Cmd-Z from routing structural', () => {
    const built = build([
      ...ch(1, 'Chapter one.[^1]'),
      ...ch(2, 'Chapter two.', { anchored: false }),
      ...ch(3, 'Chapter three.[^2]'),
      ...ch(4, 'Chapter four.[^3]', { anchored: false }),
      { kind: 'leader', id: 'hn', level: 1, title: 'Notes', managed: 'notes' },
      { kind: 'text', text: '[^1]: Note one.' },
      { kind: 'text', text: '[^2]: Note two, only in chapter three.' },
      { kind: 'text', text: '[^3]: Note three.' },
    ]);
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    const afterDelete = docText();
    expect(afterDelete).not.toContain('[^2]');

    // Swift's rebuild injects the anchors the headings did not have (a derived push), then the resync renumbers 3 to 2.
    const anchored = afterDelete
      .replace('# Chapter 2', `<!-- @sid:${sid('h2')} --># Chapter 2`)
      .replace('# Chapter 4', `<!-- @sid:${sid('h4')} --># Chapter 4`);
    ff().setContent(anchored, { origin: 'derived' });
    expect(docText()).toBe(anchored);
    ff().renumberFootnotes({ '3': '2' });
    expect(docText()).toContain('Chapter four.[^2]');
    expect(docText()).toContain('[^2]: Note three.');

    press('undo');
    expect(
      structuralUndoRequested,
      'Cmd-Z was not routed structural after anchors were injected and footnotes renumbered'
    ).toHaveBeenCalledWith({
      opId: OP,
    });
    const result = ff().markdownStructuralSwap(OP, 'undo');
    expect(result.ok, JSON.stringify(result)).toBe(true);
  });
});

describe('O2 setContent with an equal document leaves the text history alone', () => {
  it.each([
    [undefined],
    [{ origin: 'derived' as const }],
    [{ origin: 'intentional' as const }],
  ])('options %j', (options) => {
    const built = docA();
    load(built.text);
    // Two typing groups far apart (typing merges into one undo step only when adjacent).
    typeAfter('Text of chapter 1.', ' aaa');
    typeAfter('Text of chapter 2.', ' bbb');
    press('undo'); // text undo: removes " bbb"
    expect(undoDepth(view.state)).toBe(1);
    expect(redoDepth(view.state)).toBe(1);
    const text = docText();
    const doc = view.state.doc;

    ff().setContent(text, options);

    expect(view.state.doc).toBe(doc);
    expect(undoDepth(view.state)).toBe(1);
    expect(redoDepth(view.state)).toBe(1);
  });
});

describe('exception safety', () => {
  it('a throwing dispatch leaves no registry entry and midOp false, and the next command works', () => {
    const built = docA();
    load(built.text);
    const docBefore = view.state.doc;
    const spy = vi.spyOn(view, 'dispatch').mockImplementationOnce(() => {
      throw new Error('boom');
    });
    const result = ff().markdownStructuralEditorFirst(JSON.stringify(requestFor(built, 'h3')));
    spy.mockRestore();

    expect(result).toMatchObject({ ok: false, reason: 'dispatchThrew' });
    expect(getRegistry().size, 'a throwing dispatch left an entry').toBe(0);
    expect([...getRegistry().values()].some((e) => e.midOp)).toBe(false);
    expect(view.state.doc).toBe(docBefore);

    expect(clickDelete(built, 'h3').ok).toBe(true);
  });

  it('a throwing setState in the undo keeps the entry (never deletes it), midOp false, and changes nothing', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    const entry = getRegistry().get(OP);
    const postDoc = view.state.doc;
    press('undo');
    const spy = vi.spyOn(view, 'setState').mockImplementationOnce(() => {
      throw new Error('boom');
    });
    const result = ff().markdownStructuralSwap(OP, 'undo');
    spy.mockRestore();

    expect(result).toMatchObject({ ok: false, reason: 'swapThrew' });
    expect(getRegistry().get(OP)).toMatchObject({ midOp: false });
    expect(getRegistry().get(OP)?.checkpoint).toBe(entry?.checkpoint);
    expect(getRegistry().get(OP)?.postOpDoc).toBe(postDoc);
    expect(view.state.doc).toBe(postDoc);
  });

  it('a throwing dispatch in the quick redo puts the earlier entry back instead of deleting it', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    press('undo');
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    swiftPerformedUndo();
    const entry = getRegistry().get(OP);

    press('redo');
    const spy = vi.spyOn(view, 'dispatch').mockImplementationOnce(() => {
      throw new Error('boom');
    });
    const result = ff().markdownStructuralSwap(OP, 'redo');
    spy.mockRestore();

    expect(result).toMatchObject({ ok: false, reason: 'dispatchThrew' });
    expect(getRegistry().get(OP)).toBeDefined();
    expect(getRegistry().get(OP)?.midOp).toBe(false);
    expect(getRegistry().get(OP)?.preOpDoc).toBe(entry?.preOpDoc);
    expect(docText()).toBe(built.text);
  });
});

describe('W10 the redo carry (O24)', () => {
  // Break patch: in buildSwappedState (api-structural-markdown.ts) return the plain checkpoint, i.e. make the body just
  // `return entry.checkpoint;` (install the checkpoint's own history, whose redo branch is empty).
  // Predicted failure: `the redo branch was not carried across the swap` (and, later in the sequence, `typing not restored by redo`).
  it('Delete, type, Cmd-Z x2, Cmd-Shift-Z x2 brings the typing back', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    typeAfter('Text of chapter 2.', ' abc');
    const typed = docText();

    press('undo'); // text undo of the typing
    expect(structuralUndoRequested).not.toHaveBeenCalled();
    press('undo'); // structural
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    swiftPerformedUndo();
    expect(docText()).toBe(built.text);
    expect(redoDepth(view.state), 'the redo branch was not carried across the swap').toBe(1);
    press('redo'); // structural redo of the delete
    expect(ff().markdownStructuralSwap(OP, 'redo').ok).toBe(true);
    swiftPerformedRedo();
    press('redo'); // text redo of the typing
    expect(docText(), 'typing not restored by redo').toBe(typed);
  });

  it('undo, redo, undo keeps working with the carried branch, and the typing still comes back at the end', () => {
    const built = docA();
    load(built.text);
    const PRE = built.text;
    expect(clickDelete(built, 'h3').ok).toBe(true);
    typeAfter('Text of chapter 2.', ' abc');
    const typed = docText();
    press('undo'); // text undo
    press('undo'); // structural undo
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    swiftPerformedUndo();
    press('redo'); // structural redo
    expect(ff().markdownStructuralSwap(OP, 'redo').ok).toBe(true);
    swiftPerformedRedo();
    expect(redoDepth(view.state), 'the redo branch was lost by the quick redo').toBe(1);
    press('undo'); // structural undo again
    expect(structuralUndoRequested).toHaveBeenCalledTimes(2);
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    swiftPerformedUndo();
    expect(docText()).toBe(PRE);
    expect(redoDepth(view.state)).toBe(1);
    press('redo');
    expect(ff().markdownStructuralSwap(OP, 'redo').ok).toBe(true);
    swiftPerformedRedo();
    press('redo'); // text redo
    expect(docText(), 'typing not restored by redo').toBe(typed);
  });

  it('a typed character INSIDE the removed range maps away without error; the one outside it comes back', () => {
    const built = docA();
    load(built.text);
    typeAfter('Text of chapter 3.', ' zq7'); // inside the section that is about to be removed
    const typedPre = docText();
    typeAfter('Text of chapter 2.', ' abc'); // outside it, before
    press('undo'); // " abc" is undone (redo branch: abc)
    expect(docText()).toBe(typedPre);
    expect(undoDepth(view.state)).toBe(1);
    expect(redoDepth(view.state)).toBe(1);

    expect(clickDelete(built, 'h3').ok).toBe(true); // the delete maps the zq7 event (inside the removed range) away
    expect(undoDepth(view.state), 'the typing event inside the removed range survived the delete').toBe(0);
    expect(redoDepth(view.state)).toBe(1);

    press('undo'); // structural
    const swapped = ff().markdownStructuralSwap(OP, 'undo');
    expect(swapped.ok, JSON.stringify(swapped)).toBe(true);
    swiftPerformedUndo();
    expect(docText()).toBe(typedPre);
    expect(undoDepth(view.state), 'the checkpoint brings the typing inside the section back with it').toBe(1);
    expect(redoDepth(view.state)).toBe(1);

    press('redo'); // structural redo of the delete
    expect(ff().markdownStructuralSwap(OP, 'redo').ok).toBe(true);
    swiftPerformedRedo();
    press('redo'); // text redo: abc only
    expect(docText()).toContain('Text of chapter 2. abc');
    expect(docText()).not.toContain('zq7');
  });

  // Break patch: in carryRedoBranch (redo-branch.ts) ignore the rewrites the app made to the live document after the command, i.e.
  // replace the `toCheckpoint = live.doc.eq(produced) ? inverse : ChangeSet.of(...).compose(inverse)` choice by `toCheckpoint = inverse`.
  // Predicted failure: no carry is built (the composed check refuses), so `the redo branch was not carried across the swap`.
  it("maps through the app's own rewrites: anchors injected after the Delete do not shift the redone typing", () => {
    const built = build([
      ...ch(1, 'Text of chapter 1.', { anchored: false }),
      ...ch(2, 'Text of chapter 2.', { anchored: false }),
      ...ch(3),
      ...ch(4, 'Text of chapter 4.', { anchored: false }),
    ]);
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    const postDelete = docText();
    typeAfter('Text of chapter 2.', ' abc');
    const typed = docText();
    press('undo'); // text undo of " abc"
    // The rebuild's derived push injects anchors in front of the headings (positions after them shift).
    const anchored = postDelete
      .replace('# Chapter 1', `<!-- @sid:${sid('h1')} --># Chapter 1`)
      .replace('# Chapter 2', `<!-- @sid:${sid('h2')} --># Chapter 2`)
      .replace('# Chapter 4', `<!-- @sid:${sid('h4')} --># Chapter 4`);
    ff().setContent(anchored, { origin: 'derived' });
    expect(docText()).toBe(anchored);

    press('undo'); // structural (the entry followed the anchors: advanced)
    expect(structuralUndoRequested).toHaveBeenCalledTimes(1);
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    swiftPerformedUndo();
    expect(docText()).toBe(built.text);
    expect(redoDepth(view.state), 'the redo branch was not carried across the swap').toBe(1);
    press('redo');
    expect(ff().markdownStructuralSwap(OP, 'redo').ok).toBe(true);
    swiftPerformedRedo();
    press('redo'); // text redo
    expect(docText(), "typing came back at the wrong place after the app's own rewrites").toBe(typed);
  });

  it('a carry that cannot be built falls back to the plain checkpoint: the swap still succeeds, only the redo branch is lost', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    typeAfter('Text of chapter 2.', ' abc');
    press('undo');
    const entry = getRegistry().get(OP);
    expect(entry?.markdown).toBeDefined();
    // A change set of the wrong length: applying it throws, so the carry cannot be built.
    if (entry?.markdown) entry.markdown.opChanges = ChangeSet.of([{ from: 0, insert: 'x' }], 3);
    press('undo');
    const result = ff().markdownStructuralSwap(OP, 'undo');
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toBe(built.text);
    expect(redoDepth(view.state)).toBe(0);
    expect(errorHandlerMessages.some((m) => m.includes('redo carry skipped'))).toBe(true);
  });
});

// =============================================================================================================================
// Round 2b
// =============================================================================================================================

describe('W7 held presses (O19)', () => {
  // Break patch: in queuePress (undo-coordinator.ts) make the body just `return;` (consume the press and forget it).
  // Predicted failure: `second press not run`.
  it('two quick Cmd-Z presses: the second is held and runs after the first resolves', () => {
    const built = docA();
    load(built.text);
    typeAfter('Text of chapter 2.', ' zq7');
    expect(clickDelete(built, 'h3').ok).toBe(true);

    press('undo'); // routed structural, the latch goes up
    press('undo'); // during the latch: held
    expect(structuralUndoRequested).toHaveBeenCalledTimes(1);
    expect(ff().heldUndoPressCount()).toBe(1);
    expect(undoHeldPressSettled).not.toHaveBeenCalled();

    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    expect(docText()).toContain('Chapter 3'); // the first press is carried out; the second has not run yet
    expect(docText()).toContain('zq7');
    swiftPerformedUndo(); // the reply clears the latch and drains the queue

    expect(ff().heldUndoPressCount()).toBe(0);
    expect(docText(), 'second press not run').toBe(built.text); // the held press took the typing back out
    expect(undoHeldPressSettled).toHaveBeenCalledWith({ count: 1 });
    expect(undoQueueDropped).not.toHaveBeenCalled();
  });

  it('held presses run oldest first, each re-routed against the document as it is at its own turn', () => {
    const built = docA();
    load(built.text);
    typeAfter('Text of chapter 2.', ' zq7');
    const typedPre = docText();
    expect(clickDelete(built, 'h3').ok).toBe(true);

    press('undo'); // structural
    press('undo'); // held #1 (will be a text undo of the typing)
    press('redo'); // held #2 (the document is no longer the pre-op one by then: a text redo of the typing)
    expect(ff().heldUndoPressCount()).toBe(2);
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    swiftPerformedUndo();

    expect(ff().heldUndoPressCount()).toBe(0);
    expect(docText()).toBe(typedPre); // #1 removed the typing, #2 brought it back
    expect(structuralRedoRequested).not.toHaveBeenCalled();
    expect(undoHeldPressSettled).toHaveBeenCalledTimes(2);
  });

  it('a drained press that routes structural takes the latch again and is sent as a held request', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true); // OP removes chapter 3
    const OP2 = '99999999-2222-3333-4444-555555555555';
    const built2 = build([...ch(1), ...ch(2), ...ch(4)]);
    const second = ff().markdownStructuralEditorFirst(JSON.stringify(requestFor(built2, 'h4', OP2)));
    expect(second.ok, JSON.stringify(second)).toBe(true);
    ff().setUndoDescriptor({ undoTopOpId: OP2 });

    press('undo'); // OP2, structural
    press('undo'); // held
    expect(structuralUndoRequested).toHaveBeenCalledWith({ opId: OP2 });
    expect(ff().markdownStructuralSwap(OP2, 'undo').ok).toBe(true);
    ff().setUndoDescriptor({ undoTopOpId: OP, redoTopOpId: OP2 });
    ff().receiveUndoOutcome(OP2, 'performed');

    // the document is now the one OP produced: the held press goes structural for OP, as a held request
    expect(structuralUndoRequested).toHaveBeenLastCalledWith({ opId: OP, held: true });
    expect(isLatched()).toBe(true);
    expect(ff().heldUndoPressCount()).toBe(0);
  });

  it('auto-repeat keydowns of a held-down key are consumed but not queued', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    press('undo');
    press('undo', true);
    press('undo', true);
    expect(ff().heldUndoPressCount()).toBe(0);
    press('undo');
    expect(ff().heldUndoPressCount()).toBe(1);
  });

  // Break patch: in drainQueuedPresses replace the routing decision by a structural one for the top entry, i.e. replace
  // `const decision = decideLiveRouting(view, press.direction);` by
  // `const decision = { action: 'structural', opId: descriptor.undoTopOpId ?? '' } as const;` (replay the press as a structural request).
  // Predicted failure: `"x" still present after drained Cmd-Z`.
  it('W7b Cmd-Z (structural, latch up), a typed key, Cmd-Z, then the reply: the drained press re-routes against the live document and removes the key', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);

    press('undo'); // structural, the latch goes up
    typeAfter('Text of chapter 2.', 'x'); // typed during the latch
    press('undo'); // held
    expect(ff().heldUndoPressCount()).toBe(1);
    expect(docText()).toContain('Text of chapter 2.x');

    ff().receiveUndoOutcome(OP, 'performed'); // the reply (no swap ran: nothing here depends on it)

    expect(docText(), '"x" still present after drained Cmd-Z').not.toContain('Text of chapter 2.x');
    expect(structuralUndoRequested, 'the drained press was replayed as a structural request').toHaveBeenCalledTimes(1);
    expect(ff().heldUndoPressCount()).toBe(0);
    expect(undoHeldPressSettled).toHaveBeenCalledWith({ count: 1 });
  });

  // Break patch (timeout): in the latch timeout callback of requestStructural delete `dropQueuedPresses('latch timeout');`.
  // Predicted failure: `the queue was not dropped on the latch timeout`.
  it('the latch timeout drops the held presses and posts the notice messages', () => {
    vi.useFakeTimers();
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    press('undo');
    press('undo');
    expect(ff().heldUndoPressCount()).toBe(1);

    vi.advanceTimersByTime(LATCH_TIMEOUT_MS + 10);

    expect(isLatched()).toBe(false);
    expect(ff().heldUndoPressCount(), 'the queue was not dropped on the latch timeout').toBe(0);
    expect(undoQueueDropped).toHaveBeenCalledWith({ count: 1 });
    expect(undoHeldPressSettled).toHaveBeenCalledWith({ count: 1 });
    expect(docText()).not.toContain('Chapter 3'); // nothing was replayed
  });

  it('a failed reply drops the held presses without touching the document, and posts the notice messages', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    const postDoc = view.state.doc;
    press('undo');
    press('undo');
    ff().receiveUndoOutcome(OP, 'failed');
    expect(view.state.doc).toBe(postDoc);
    expect(ff().heldUndoPressCount()).toBe(0);
    expect(undoQueueDropped).toHaveBeenCalledWith({ count: 1 });
    expect(undoHeldPressSettled).toHaveBeenCalledWith({ count: 1 });
  });

  it('a cancelled reply (close or switch) drops the held presses silently: settled, but no warning', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    press('undo');
    press('undo');
    ff().receiveUndoOutcome(OP, 'cancelled');
    expect(ff().heldUndoPressCount()).toBe(0);
    expect(undoQueueDropped).not.toHaveBeenCalled();
    expect(undoHeldPressSettled).toHaveBeenCalledWith({ count: 1 });
  });

  it('a barrier (clearStructuralUndoRegistry) releases the latch and forgets the held presses; Swift is told they ended', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    press('undo');
    press('undo');
    ff().clearStructuralUndoRegistry();
    expect(isLatched()).toBe(false);
    expect(ff().heldUndoPressCount()).toBe(0);
    expect(undoQueueDropped).not.toHaveBeenCalled();
    expect(undoHeldPressSettled).toHaveBeenCalledWith({ count: 1 });
  });
});

describe('W8 the structural-settle renumber is not a history step (B5)', () => {
  // Break patch: in renumberFootnotes (api.ts) always use the derivedCorrection annotation, i.e. replace
  // `structuralSettleOpId !== null ? Transaction.addToHistory.of(false) : derivedCorrection.of(true)` by `derivedCorrection.of(true)`.
  // Predicted failure: `undoDepth increased by renumber`.
  const footnoted = (): Built =>
    build([
      ...ch(1, 'Chapter one.[^1]'),
      ...ch(2, 'Chapter two.[^2]'),
      ...ch(3, 'Chapter three.[^3]'),
      { kind: 'leader', id: 'hn', level: 1, title: 'Notes', managed: 'notes' },
      { kind: 'text', text: '[^1]: Note one.' },
      { kind: 'text', text: '[^2]: Note two.' },
      { kind: 'text', text: '[^3]: Note three.' },
    ]);

  it('after a Delete of a footnoted chapter and typing, the settle renumber is not a step: Cmd-Z undoes the typing, the next Cmd-Z reaches the command', () => {
    const built = footnoted();
    load(built.text);
    expect(clickDelete(built, 'h2').ok).toBe(true);
    typeAfter('Chapter one.[^1]', ' x');
    const depth = undoDepth(view.state);

    ff().setStructuralSettleOpId(OP); // the settle's resyncs run between these two calls
    ff().renumberFootnotes({ '3': '2' });
    ff().setStructuralSettleOpId(null);
    expect(docText()).toContain('Chapter three.[^2]');
    expect(undoDepth(view.state), 'undoDepth increased by renumber').toBe(depth);

    press('undo'); // the typing, not the renumber
    expect(structuralUndoRequested).not.toHaveBeenCalled();
    expect(docText()).not.toContain('Chapter one.[^1] x');
    expect(docText()).toContain('Chapter three.[^2]');
    press('undo'); // now the command (equal modulo the renumber)
    expect(structuralUndoRequested).toHaveBeenCalledWith({ opId: OP });
  });

  it('the renumber advances the saved copies when the document equals them (it is still a sync-origin change)', () => {
    const built = footnoted();
    load(built.text);
    expect(clickDelete(built, 'h2').ok).toBe(true);
    ff().setStructuralSettleOpId(OP);
    ff().renumberFootnotes({ '3': '2' });
    ff().setStructuralSettleOpId(null);
    expect(getRegistry().get(OP)?.postOpDoc.eq(view.state.doc)).toBe(true);
  });

  it('pin: outside a settle (flag null) the renumber is exactly what it was, a derivedCorrection that is its own undo step', () => {
    const built = footnoted();
    load(built.text);
    expect(clickDelete(built, 'h2').ok).toBe(true);
    const depth = undoDepth(view.state);
    ff().renumberFootnotes({ '3': '2' });
    expect(undoDepth(view.state)).toBe(depth + 1);
    ff().setStructuralSettleOpId(OP);
    ff().setStructuralSettleOpId(null);
    ff().renumberFootnotes({ '1': '9' });
    expect(undoDepth(view.state), 'a cleared flag must leave the renumber as it was').toBe(depth + 2);
  });
});

describe('W11 region-scoped replace of the Notes / bibliography text (O28)', () => {
  const notes = (id = 'hn'): Block => ({ kind: 'leader', id, level: 1, title: 'Notes', managed: 'notes' });
  const bibGlued: Block = {
    kind: 'leader',
    id: 'hb',
    level: 1,
    title: 'Bibliography',
    managed: 'bibliography',
    glueMarker: true,
  };
  const END: Block = { kind: 'text', text: '<!-- ::auto-bibliography-end:: -->' };
  const withNotesAndBib = (): Built =>
    build([
      ...ch(1, 'Chapter one.[^1]'),
      ...ch(2, 'Chapter two.[^2]'),
      notes(),
      { kind: 'text', text: '[^1]: Note one.' },
      { kind: 'text', text: '[^2]: Note two.' },
      bibGlued,
      { kind: 'text', text: 'Smith, J. (2020). A book.' },
      END,
    ]);
  const NOTES_OLD = '# Notes\n\n[^1]: Note one.\n\n[^2]: Note two.';
  const BIB_OLD = '# Bibliography\n\nSmith, J. (2020). A book.';
  const notesRequest = (over: Partial<Record<string, unknown>> = {}) => ({
    region: 'notes',
    headingLine: '# Notes',
    expectedOld: NOTES_OLD,
    newText: '# Notes\n\n[^1]: Note one, revised.\n\n[^2]: Note two.',
    ...over,
  });
  const replace = (request: object): MarkdownManagedRegionResult =>
    ff().markdownReplaceManagedRegion(JSON.stringify(request));

  it('replaces only the Notes region, keeps its anchor and the text around it, and reports the new raw text', () => {
    const built = withNotesAndBib();
    load(built.text);
    const result = replace(notesRequest());
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(result.changed).toBe(true);
    expect(result.postRaw).toBe(docText());
    const expected = built.text.replace('[^1]: Note one.', '[^1]: Note one, revised.');
    expect(docText()).toBe(expected);
    expect(docText()).toContain(`<!-- @sid:${sid('hn')} --># Notes`); // the anchor stays
  });

  // Break patch: in markdownReplaceManagedRegion (api-managed-region.ts) replace the dispatched change by a whole-document replace:
  // `changes: { from: 0, to: doc.length, insert: doc.sliceString(0, located.from) + insert + doc.sliceString(to) }`.
  // Predicted failure: `history lost after region push` (every history event of the user's typing maps away with the replaced text).
  it("is outside the text history: Cmd-Z afterwards walks the user's own history intact", () => {
    const built = withNotesAndBib();
    load(built.text);
    typeAfter('Chapter one.[^1]', ' abc');
    const depth = undoDepth(view.state);
    expect(replace(notesRequest()).ok).toBe(true);
    expect(undoDepth(view.state), 'history lost after region push').toBe(depth);
    press('undo'); // the typing, not the replace
    expect(docText()).not.toContain('Chapter one.[^1] abc');
    expect(docText()).toContain('[^1]: Note one, revised.');
  });

  // Break patch: delete the `annotations: Transaction.addToHistory.of(false),` line of the dispatch (a user-origin change).
  // Predicted failure: `Cmd-Z was not routed structural after the region replace`.
  it('is sync-origin: a structural Cmd-Z still routes after it', () => {
    const built = withNotesAndBib();
    load(built.text);
    expect(clickDelete(built, 'h2').ok).toBe(true);
    const result = replace(
      notesRequest({
        expectedOld: '# Notes\n\n[^1]: Note one.',
        newText: '# Notes\n\n[^1]: Note one, edited by the rebuild.',
      })
    );
    expect(result.ok, JSON.stringify(result)).toBe(true);
    press('undo');
    expect(structuralUndoRequested, 'Cmd-Z was not routed structural after the region replace').toHaveBeenCalledWith({
      opId: OP,
    });
  });

  // Break patch: delete the `if (normalizeRegionText(text) !== expected) continue;` line of locateNotes.
  // Predicted failure: `typed text lost`.
  it('rejects the replace when the region changed since expectedOld, and keeps the typed text', () => {
    const built = withNotesAndBib();
    load(built.text);
    typeAfter('[^1]: Note one.', ' TYPED');
    const docBefore = view.state.doc;
    const result = replace(notesRequest());
    expect(docText(), 'typed text lost').toContain('[^1]: Note one. TYPED');
    expect(result).toMatchObject({ ok: false, reason: 'regionChanged' });
    expect(view.state.doc).toBe(docBefore);
  });

  it('typing in the body is untouched and the caret stays: before the region by position, after it by the text it sits in', () => {
    const built = withNotesAndBib();
    load(built.text);
    typeAfter('Chapter one.[^1]', ' kp4');
    const bodyHead = view.state.selection.main.head;
    expect(replace(notesRequest()).ok).toBe(true);
    expect(docText()).toContain('Chapter one.[^1] kp4');
    expect(view.state.selection.main.head).toBe(bodyHead);

    // a caret inside the bibliography entry (after the region): it moves with the text, not with the offset
    const at = docText().indexOf('A book') + 3;
    view.dispatch({ selection: { anchor: at } });
    const before = docText().slice(at - 3, at + 3);
    expect(
      replace(
        notesRequest({
          expectedOld: '# Notes\n\n[^1]: Note one, revised.\n\n[^2]: Note two.',
          newText: '# Notes\n\n[^1]: A much longer first note than before.\n\n[^2]: Note two.',
        })
      ).ok
    ).toBe(true);
    const head = view.state.selection.main.head;
    expect(docText().slice(head - 3, head + 3)).toBe(before);
  });

  it('answers noRegion when the region cannot be found, changing nothing', () => {
    const built = withNotesAndBib();
    load(built.text);
    const docBefore = view.state.doc;
    expect(replace(notesRequest({ headingLine: '# Remarks' }))).toMatchObject({ ok: false, reason: 'noRegion' });
    expect(replace(notesRequest({ headingLine: null }))).toMatchObject({ ok: false, reason: 'noRegion' });
    expect(view.state.doc).toBe(docBefore);

    const noMarkers = build([
      ...ch(1),
      { kind: 'leader', id: 'hb', level: 1, title: 'Bibliography', managed: 'bibliography' },
      { kind: 'text', text: 'Smith.' },
    ]);
    load(noMarkers.text);
    expect(replace({ region: 'bibliography', expectedOld: BIB_OLD, newText: BIB_OLD })).toMatchObject({
      ok: false,
      reason: 'noRegion',
    });
    const noEnd = build([...ch(1), bibGlued, { kind: 'text', text: 'Smith.' }]);
    load(noEnd.text);
    expect(replace({ region: 'bibliography', expectedOld: '# Bibliography\n\nSmith.', newText: 'x' })).toMatchObject({
      ok: false,
      reason: 'noRegion',
    });
    expect(replace({ region: 'nonsense', expectedOld: '', newText: '' })).toMatchObject({
      ok: false,
      reason: 'badRequest',
    });
  });

  it('replaces the bibliography between its markers, keeping the opening marker, the heading anchor and the end marker (glued shape)', () => {
    const built = withNotesAndBib();
    load(built.text);
    const result = replace({
      region: 'bibliography',
      expectedOld: BIB_OLD,
      newText: '# Bibliography\n\nJones, K. (2021). Another book.\n\nSmith, J. (2020). A book.',
    });
    expect(result.ok, JSON.stringify(result)).toBe(true);
    const text = docText();
    expect(text).toContain(`<!-- ::auto-bibliography:: --><!-- @sid:${sid('hb')} --># Bibliography`);
    expect(text).toContain(
      'Jones, K. (2021). Another book.\n\nSmith, J. (2020). A book.\n\n<!-- ::auto-bibliography-end:: -->'
    );
    expect(text.startsWith(built.text.slice(0, built.text.indexOf('<!-- ::auto-bibliography::')))).toBe(true); // the body is byte for byte what it was
    expect(text.match(/<!-- ::auto-bibliography-end:: -->/g)).toHaveLength(1);
  });

  it('keeps the standalone opening-marker shape and the heading anchor of a bibliography written that way', () => {
    const built = build([
      ...ch(1),
      { kind: 'text', text: '<!-- ::auto-bibliography:: -->', managedRow: true },
      { kind: 'leader', id: 'hb', level: 1, title: 'Bibliography', managed: 'bibliography' },
      { kind: 'text', text: 'Smith, J. (2020). A book.' },
      END,
    ]);
    load(built.text);
    const result = replace({
      region: 'bibliography',
      expectedOld: BIB_OLD,
      newText: '# Bibliography\n\nJones, K. (2021). Another book.',
    });
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).toContain(
      `<!-- ::auto-bibliography:: -->\n\n<!-- @sid:${sid('hb')} --># Bibliography\n\nJones, K. (2021). Another book.\n\n<!-- ::auto-bibliography-end:: -->`
    );
  });

  it('removes the region (heading included) when newText is empty, and says changed:false when nothing differs', () => {
    const built = withNotesAndBib();
    load(built.text);
    const same = replace(notesRequest({ newText: NOTES_OLD }));
    expect(same).toMatchObject({ ok: true, changed: false });
    expect(docText()).toBe(built.text);

    const removed = replace(notesRequest({ newText: '' }));
    expect(removed.ok, JSON.stringify(removed)).toBe(true);
    expect(docText()).not.toContain('Notes');
    expect(docText()).not.toContain('[^1]: Note one');
    expect(docText()).toContain('Chapter two.[^2]');
    expect(docText()).toContain('<!-- ::auto-bibliography:: -->'); // the bibliography after it is untouched
  });

  it('the Notes heading with every definition removed by a Delete stays until the rebuild sends an empty region (answers D-8)', () => {
    const built = build([
      ...ch(1, 'Chapter one.'),
      ...ch(2, 'Chapter two.[^1]'),
      notes(),
      { kind: 'text', text: '[^1]: Note one.' },
    ]);
    load(built.text);
    expect(clickDelete(built, 'h2').ok).toBe(true);
    expect(docText()).toContain('# Notes'); // the Delete removed the orphan definition only
    expect(docText()).not.toContain('[^1]: Note one.');
    const result = replace({ region: 'notes', headingLine: '# Notes', expectedOld: '# Notes', newText: '' });
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(docText()).not.toContain('# Notes');
  });
});

// =============================================================================================================================
// Review-fix round (judge-review1): the page counts exactly what BlockParser counts, and the smaller web-side fixes
// =============================================================================================================================

describe('W-M1 the page counts a ~~~ line the way BlockParser does: as ordinary text, not a fence', () => {
  // Break patch: put the tilde branch back in scanDocument (api-structural-markdown.ts), i.e. before the `$$` check insert
  // `if (text.startsWith('~~~')) { fence = '~~~'; continue; }`.
  // Predicted failure: `delete refused: {"ok":false,"reason":"leadersMismatch","detail":"leaderCount editor=2 database=3"}`.
  it('a "# x" line between two ~~~ lines is a heading to the database (["## A","# x","## B"]) and to the page', () => {
    const built = build([
      { kind: 'leader', id: 'a', level: 2, title: 'A' },
      { kind: 'text', text: 'text' },
      { kind: 'text', text: '~~~' },
      { kind: 'leader', id: 'x', level: 1, title: 'x', anchored: false },
      { kind: 'text', text: '~~~' },
      { kind: 'leader', id: 'b', level: 2, title: 'B' },
      { kind: 'text', text: 'more' },
    ]);
    expect(built.leaders.map((l) => l.line)).toEqual(['## A', '# x', '## B']);
    load(built.text);
    const result = clickDelete(built, 'a');
    expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText()).toBe(without(built.text, '## A', '# x'));
  });

  it('an unclosed ~~~ line does not hide the headings behind it', () => {
    const built = build([...ch(1, 'Text of chapter 1.\n\n~~~ never closed'), ...ch(2), ...ch(3)]);
    load(built.text);
    const result = clickDelete(built, 'h2');
    expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText()).toBe(without(built.text, '# Chapter 2', '# Chapter 3'));
  });

  it('a backtick fence still hides a "# comment" inside it (the splitter has that rule)', () => {
    const built = build([...ch(1, 'Intro.\n\n```sh\n\n# not a heading\n\n```\n\nOutro.'), ...ch(2)]);
    expect(built.leaders).toHaveLength(2);
    load(built.text);
    const result = clickDelete(built, 'h1');
    expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);
  });
});

describe('W-M4 a heading is "#" then ICU white space (U+3000 and NBSP count; U+FEFF does not)', () => {
  // Break patch: in api-structural-markdown.ts put the old rule back: `ATX_HEADING = /^#{1,6}[ \t]/`.
  // Predicted failure: `delete refused: {"ok":false,"reason":"leadersMismatch","detail":"leaderCount editor=2 database=3"}`.
  const heading = (gap: string) => `#${gap}第二章`;
  const request = (middleLine: string | null) => ({
    kind: 'delete' as const,
    opId: OP,
    rootId: 'c',
    leaders: [
      { id: 'a', line: '# Chapter 1', level: 1 },
      ...(middleLine ? [{ id: 'b', line: middleLine, level: 1 }] : []),
      { id: 'c', line: '# Chapter 3', level: 1 },
    ],
    stopLine: null,
    endLeaderId: null,
  });

  it.each([
    ['U+3000 ideographic space', '　'],
    ['U+00A0 no-break space', ' '],
    ['U+0085 next line', '\u0085'],
    ['U+2003 em space', ' '],
  ])('"#"+%s is a heading row in the database, so the page counts it', (_label, gap) => {
    const text = `# Chapter 1\n\nText.\n\n${heading(gap)}\n\nText 2.\n\n# Chapter 3\n\nText 3.\n`;
    load(text);
    const result = ff().markdownStructuralEditorFirst(request(heading(gap)));
    expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);
    expect(docText()).toBe(without(text, '# Chapter 3'));
  });

  it('"#"+U+FEFF is NOT white space to ICU: not a heading in the database, so the page must not count it either', () => {
    const text = `# Chapter 1\n\nText.\n\n${heading('﻿')}\n\nText 2.\n\n# Chapter 3\n\nText 3.\n`;
    load(text);
    const result = ff().markdownStructuralEditorFirst(request(null));
    expect(result.ok, `delete refused: ${JSON.stringify(result)}`).toBe(true);
  });
});

describe('W-M2 a footnote definition with a second paragraph goes whole', () => {
  // Break patch: in orphanDefinitionRanges (api-structural-markdown.ts) delete the `if (within(last + 2) && ...) { last += 2; continue; }`
  // block (stop at the first blank line).
  // Predicted failure: `a stray paragraph of the removed footnote was left in Notes`.
  it('removes "[^2]: ..." with its blank-line + four-space paragraph(s), keeps the shared label and the other definitions', () => {
    const built = build([
      ...ch(1, 'Chapter one.[^1][^3]'),
      ...ch(2, 'Chapter two.[^2][^3]'),
      { kind: 'leader', id: 'hn', level: 1, title: 'Notes', managed: 'notes' },
      { kind: 'text', text: '[^1]: Note one.' },
      {
        kind: 'text',
        text: '[^2]: Note two.\n\n    Second paragraph of note two,\n    which has two lines.\n\n    Third paragraph.',
      },
      { kind: 'text', text: '[^3]: Note three, shared.' },
    ]);
    load(built.text);
    const result = clickDelete(built, 'h2');
    expect(result.ok, JSON.stringify(result)).toBe(true);
    const post = docText();
    expect(post, 'a stray paragraph of the removed footnote was left in Notes').not.toContain('Second paragraph');
    expect(post).not.toContain('which has two lines');
    expect(post).not.toContain('Third paragraph');
    expect(post).not.toContain('Note two');
    expect(post).toContain('[^1]: Note one.');
    expect(post).toContain('[^3]: Note three, shared.');
    const afterChapter = without(built.text, '# Chapter 2', '# Notes');
    expect(post).toBe(without(afterChapter, '[^2]: Note two.', '[^3]: Note three'));
  });

  it('the splitter ends a definition at two blank lines or at a line that is not four-space indented: so does the page', () => {
    const built = build([
      ...ch(1, 'Chapter one.[^1]'),
      ...ch(2, 'Chapter two.[^2]'),
      { kind: 'leader', id: 'hn', level: 1, title: 'Notes', managed: 'notes' },
      { kind: 'text', text: '[^1]: Note one.' },
      { kind: 'text', text: '[^2]: Note two.' },
      { kind: 'text', text: '  A two-space paragraph after a blank line is a block of its own.' },
    ]);
    load(built.text);
    expect(clickDelete(built, 'h2').ok).toBe(true);
    expect(docText()).not.toContain('Note two');
    expect(docText()).toContain('A two-space paragraph after a blank line is a block of its own.');
  });
});

describe('W-M5 the region comparison uses one normal form on both sides (L-5)', () => {
  // Break patch: in normalizeRegionText (api-managed-region.ts) delete the last line `.replace(/([^\n])\n(?=\[\^\d+\]:)/g, '$1\n\n')`
  // (compare the page's text as it stands).
  // Predicted failure: `a hand-typed single-newline Notes region was rejected: {"ok":false,"reason":"regionChanged"...`.
  it('a Notes region whose definitions are one per line (single newline) is replaced when expectedOld is the rows joined by blank lines', () => {
    const built = build([
      ...ch(1, 'Chapter one.[^1]'),
      { kind: 'leader', id: 'hn', level: 1, title: 'Notes', managed: 'notes' },
      { kind: 'text', text: '[^1]: Note one.\n[^2]: Note two.' },
    ]);
    load(built.text);
    expect(docText()).toContain('[^1]: Note one.\n[^2]: Note two.');
    const bodyBefore = docText().slice(0, docText().indexOf(`<!-- @sid:${sid('hn')}`));
    const result = ff().markdownReplaceManagedRegion({
      region: 'notes',
      headingLine: '# Notes',
      expectedOld: '# Notes\n\n[^1]: Note one.\n\n[^2]: Note two.',
      newText: '# Notes\n\n[^1]: Note one, revised.\n\n[^2]: Note two.',
    });
    expect(result.ok, `a hand-typed single-newline Notes region was rejected: ${JSON.stringify(result)}`).toBe(true);
    expect(result.changed).toBe(true);
    expect(docText().startsWith(bodyBefore)).toBe(true); // the body is untouched
    expect(docText()).toContain('[^1]: Note one, revised.');
  });
});

describe('W-L1 the recent-edit span is cleared by the swap', () => {
  // Break patch: delete the `recentEditSpan` item of CARRIED_STATE (api-structural-markdown.ts).
  // Predicted failure: `a Swift-derived push after the swap became its own undo step: undoDepth 1`.
  it('Cmd-Z twice within the span window, then a derived setContent over the typed spot: no extra undo step', () => {
    const built = docA();
    load(built.text);
    expect(clickDelete(built, 'h3').ok).toBe(true);
    typeAfter('Text of chapter 2.', ' abc'); // the span the user last typed in
    press('undo'); // the typing
    press('undo'); // the command: the swap
    expect(ff().markdownStructuralSwap(OP, 'undo').ok).toBe(true);
    swiftPerformedUndo();
    expect(undoDepth(view.state)).toBe(0);

    // a derived push that lands right where the user typed (an insertion at the end of that paragraph)
    ff().setContent(built.text.replace('Text of chapter 2.', 'Text of chapter 2.!'), { origin: 'derived' });

    expect(docText()).toContain('Text of chapter 2.!');
    expect(
      undoDepth(view.state),
      `a Swift-derived push after the swap became its own undo step: undoDepth ${undoDepth(view.state)}`
    ).toBe(0);
  });
});

describe('W8b overlapping settle flags: compare-and-clear (F9/M-5)', () => {
  // Break patch: in setStructuralSettleOpId (api.ts) delete the `if (typeof expecting === 'string' && structuralSettleOpId !== expecting) return;` line.
  // Predicted failure: `settle B's renumber became its own undo step`.
  const footnoted = (): Built =>
    build([
      ...ch(1, 'Chapter one.[^1]'),
      ...ch(2, 'Chapter two.[^2]'),
      ...ch(3, 'Chapter three.[^3]'),
      { kind: 'leader', id: 'hn', level: 1, title: 'Notes', managed: 'notes' },
      { kind: 'text', text: '[^1]: Note one.' },
      { kind: 'text', text: '[^2]: Note two.' },
      { kind: 'text', text: '[^3]: Note three.' },
    ]);

  it("A sets, B sets, A clears (expecting A): B's flag stays in force and B's renumber is absorbed; then B clears", () => {
    const built = footnoted();
    load(built.text);
    expect(clickDelete(built, 'h2').ok).toBe(true);
    const depth = undoDepth(view.state);

    ff().setStructuralSettleOpId('op-A');
    ff().setStructuralSettleOpId('op-B');
    ff().setStructuralSettleOpId(null, 'op-A'); // A's unmark runs while B's settle is already under way
    ff().renumberFootnotes({ '3': '2' }); // B's renumber
    expect(undoDepth(view.state), "settle B's renumber became its own undo step").toBe(depth);

    ff().setStructuralSettleOpId(null, 'op-B');
    ff().renumberFootnotes({ '1': '9' });
    expect(undoDepth(view.state), 'the flag was still set after B cleared it').toBe(depth + 1);
  });

  it('a clear without `expecting` still clears unconditionally, and a clear expecting another opId leaves the flag alone', () => {
    const built = footnoted();
    load(built.text);
    expect(clickDelete(built, 'h2').ok).toBe(true);
    const depth = undoDepth(view.state);
    ff().setStructuralSettleOpId('op-A');
    ff().setStructuralSettleOpId(null, 'op-other');
    ff().renumberFootnotes({ '3': '2' });
    expect(undoDepth(view.state)).toBe(depth); // still absorbed
    ff().setStructuralSettleOpId(null);
    ff().renumberFootnotes({ '1': '9' });
    expect(undoDepth(view.state)).toBe(depth + 1); // cleared unconditionally
  });
});

describe('CRLF documents', () => {
  // What the page does with CRLF, stated as a test: CodeMirror splits an incoming string on "\r\n", "\r" and "\n" (Text.of), so a text
  // pushed with CRLF line endings is stored with plain "\n" and the page never sees a "\r". The scan, the leaders and the range are
  // therefore the same for a CRLF project as for an LF one, and `preRaw`/`postRaw` carry "\n".
  it('a CRLF text is stored with LF line endings and a Delete works on it', () => {
    const built = docA();
    load('');
    ff().setContent(built.text.replace(/\n/g, '\r\n'));
    view = currentView();
    expect(docText()).not.toContain('\r');
    expect(docText()).toBe(built.text);
    const result = clickDelete(built, 'h3');
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(result.preRaw).not.toContain('\r');
    expect(result.postRaw).not.toContain('\r');
  });
});
