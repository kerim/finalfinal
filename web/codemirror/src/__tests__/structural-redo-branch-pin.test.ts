// @vitest-environment jsdom
//
// T-U21 (t-4a8fd8af, round 1): PIN of what Markdown mode does TODAY, on unmodified code.
//
// The question: in Markdown mode, after a Delete Section, does the editor's text-redo branch
// survive the old structural undo/redo path, so that this ordinary sequence brings the typing
// back at the end?
//
//     Delete Section -> type some text -> Cmd-Z (undoes the typing) -> Cmd-Z (undoes the
//     delete) -> Cmd-Shift-Z (redoes the delete) -> Cmd-Shift-Z (redoes the typing)
//
// Today's Markdown structural undo/redo is the OLD BODY (StructuralUndoController.swift
// performStructuralOp / performUndo / performRedo): the database is changed and the editor then
// receives the DB-assembled markdown through `window.FinalFinal.setContent(text)` with no
// options (StructuralUndoController.swift ~:809 for the forward op, ~:2205 for undo/redo via
// settleAfterDBRestore). That is an `addToHistory: false` minimal-diff dispatch
// (web/codemirror/src/api.ts setContent, the isIntentional branch), and
// @codemirror/commands history maps BOTH branches through such a change instead of clearing
// them.
//
// This file drives that sequence through the REAL page code: it imports the real main.ts (the
// real extension set, the real update listeners, the real capture-phase keydown interceptor,
// the real `window.FinalFinal` API) into jsdom, and it plays the Swift side of the bridge
// exactly as the old body does:
//   forward op : beginStructuralOp(opId) -> setContent(postText) -> finalizeStructuralOpPostOpDoc(opId)
//                -> setUndoDescriptor({undoTopOpId: opId})
//   undo       : (JS posts structuralUndoRequested) -> setContent(preText)
//                -> setUndoDescriptor({redoTopOpId: opId}) -> receiveUndoOutcome(opId, 'performed')
//   redo       : (JS posts structuralRedoRequested) -> setContent(postText)
//                -> setUndoDescriptor({undoTopOpId: opId}) -> receiveRedoOutcome(opId, 'performed')
// Cmd-Z / Cmd-Shift-Z are real KeyboardEvents on the editor's contentDOM, so the unified-undo
// routing (document equality) and CodeMirror's own `Mod-z` / `Mod-Shift-z` keymap run for real.
//
// It must PASS on today's code (this is a pin, not a bug test). Round 7 re-runs it as an
// assertion after the checkpoint swap + redo carry (W10) land; if it fails then, the redo branch
// has been lost.
//
// The pinned dependency versions (a history-JSON shape change would change what a later redo
// carry has to rebuild) are asserted in the last test; the shape pin proper belongs to W10.

import { redoDepth, undoDepth } from '@codemirror/commands';
import { EditorView } from '@codemirror/view';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

type FF = {
  setContent: (md: string, options?: unknown) => void;
  getContentRaw: () => string;
  beginStructuralOp: (opId: string) => boolean;
  finalizeStructuralOpPostOpDoc: (opId: string) => boolean;
  setUndoDescriptor: (d: { undoTopOpId?: string; redoTopOpId?: string }) => void;
  receiveUndoOutcome: (opId: string, outcome: string) => void;
  receiveRedoOutcome: (opId: string, outcome: string) => void;
  resetForProjectSwitch: () => void;
  clearStructuralUndoRegistry: () => void;
  focus: () => void;
};

const ff = (): FF => (window as any).FinalFinal as FF;

// A small document in the shape the editor shows: four chapters. Chapter 3 is the one deleted.
const CH1 = '# Chapter 1\n\nFirst chapter text.\n\n';
const CH2 = '# Chapter 2\n\nSecond chapter text.\n\n';
const CH3 = '# Chapter 3\n\nThird chapter text.\n\n';
const CH4 = '# Chapter 4\n\nFourth chapter text.\n';
const PRE = CH1 + CH2 + CH3 + CH4; // the document before Delete Section
const POST = CH1 + CH2 + CH4; // the document after Delete Section on Chapter 3

const OP_ID = '11111111-2222-3333-4444-555555555555';

let structuralUndoRequested: ReturnType<typeof vi.fn>;
let structuralRedoRequested: ReturnType<typeof vi.fn>;
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

/** The user types `text` at document position `pos` (a real transaction with the same userEvent a keystroke has). */
function typeAt(pos: number, text: string): void {
  view.dispatch(
    view.state.update({
      changes: { from: pos, insert: text },
      selection: { anchor: pos + text.length },
      userEvent: 'input.type',
    })
  );
}

/** A real Cmd-Z / Cmd-Shift-Z keydown on the editor. The page's own capture-phase interceptor and CodeMirror's keymap handle it. */
function press(direction: 'undo' | 'redo'): void {
  const isRedo = direction === 'redo';
  const event = new KeyboardEvent('keydown', {
    key: isRedo ? 'Z' : 'z',
    code: 'KeyZ',
    keyCode: 90,
    ctrlKey: true, // jsdom's navigator.platform is not a Mac, so CodeMirror's `Mod` is Ctrl; the page accepts meta or ctrl
    shiftKey: isRedo,
    bubbles: true,
    cancelable: true,
  });
  view.contentDOM.dispatchEvent(event);
}

/** Swift's side of Delete Section in Markdown mode today (the old body, Source branch). */
function oldBodyDelete(preText: string, postText: string): void {
  expect(ff().beginStructuralOp(OP_ID)).toBe(true);
  ff().setContent(postText); // evalBoolCoercingVoidCall("window.FinalFinal.setContent(`...`)")
  expect(ff().finalizeStructuralOpPostOpDoc(OP_ID)).toBe(true);
  ff().setUndoDescriptor({ undoTopOpId: OP_ID }); // pushDescriptor() after the entry is recorded
  expect(currentView().state.doc.toString()).toBe(postText);
  void preText;
}

/** Swift's side of the old undo (performUndo -> settleAfterDBRestore, Source branch). */
function oldBodyUndo(restoredText: string): void {
  expect(structuralUndoRequested).toHaveBeenCalledTimes(1);
  ff().setContent(restoredText);
  ff().setUndoDescriptor({ redoTopOpId: OP_ID });
  ff().receiveUndoOutcome(OP_ID, 'performed');
  structuralUndoRequested.mockClear();
}

/** Swift's side of the old redo (performRedo -> settleAfterDBRestore, Source branch). */
function oldBodyRedo(restoredText: string): void {
  expect(structuralRedoRequested).toHaveBeenCalledTimes(1);
  ff().setContent(restoredText);
  ff().setUndoDescriptor({ undoTopOpId: OP_ID });
  ff().receiveRedoOutcome(OP_ID, 'performed');
  structuralRedoRequested.mockClear();
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
  (window as any).webkit = {
    messageHandlers: {
      structuralUndoRequested: { postMessage: structuralUndoRequested },
      structuralRedoRequested: { postMessage: structuralRedoRequested },
      structuralUndoRefused: { postMessage: vi.fn() },
      historyEdited: { postMessage: vi.fn() },
      contentChanged: { postMessage: vi.fn() },
      sectionChanged: { postMessage: vi.fn() },
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

  // main.ts builds the real extension set and mounts the real editor into #editor at import time,
  // and registers the real window.FinalFinal.
  await import('../main');
  ({ resetUndoCoordinatorState } = await import('../undo-coordinator'));
  ({ resetRecentUserEditSpanForTests: resetRecentUserEditSpan } = await import('../recent-edit-span'));
});

afterAll(() => {
  delete (window as any).webkit;
  document.body.innerHTML = '';
});

beforeEach(() => {
  // A fresh document with fresh text history, exactly as opening a project does (resetForProjectSwitch builds a new
  // EditorState from the real extension set), then the starting text; and empty structural-undo state.
  resetUndoCoordinatorState();
  resetRecentUserEditSpan(); // the span of the user's last keystroke is module state; a previous test's must not leak in
  ff().clearStructuralUndoRegistry();
  ff().resetForProjectSwitch();
  view = currentView();
  ff().setContent(PRE);
  // The initial load is not a user edit: start from a clean history.
  ff().resetForProjectSwitch();
  view = currentView();
  structuralUndoRequested.mockClear();
  structuralRedoRequested.mockClear();
  errorHandlerMessages.length = 0;
  expect(view.state.doc.toString()).toBe(PRE);
  expect(undoDepth(view.state)).toBe(0);
  expect(redoDepth(view.state)).toBe(0);
});

describe('T-U21 pin: today the Markdown redo branch survives Delete Section undo/redo (old body, unmodified code)', () => {
  it.each([
    [
      'at the end of the first paragraph of Chapter 2 (hand-test step 1 place)',
      CH1.length + '# Chapter 2\n\nSecond chapter text.'.length,
      'hello there',
    ],
    ['in the middle of a Chapter 2 paragraph', CH1.length + '# Chapter 2\n\nSecond '.length, 'kp4 '],
    ['inside Chapter 1 (far from the deleted section)', '# Chapter 1\n\nFirst'.length, 'zq7'],
  ] as const)('Delete, type %s, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z: the typing comes back', (_label, pos, typed) => {
    const steps: Array<Record<string, unknown>> = [];
    const snap = (name: string) => {
      steps.push({
        step: name,
        doc: view.state.doc.toString(),
        undoDepth: undoDepth(view.state),
        redoDepth: redoDepth(view.state),
      });
    };
    snap('start');

    // 1. Delete Section (Chapter 3), the old body.
    oldBodyDelete(PRE, POST);
    snap('after Delete Section');
    expect(view.state.doc.toString()).toBe(POST);

    // 2. The user types.
    typeAt(pos, typed);
    const TYPED = POST.slice(0, pos) + typed + POST.slice(pos);
    snap(`after typing ${JSON.stringify(typed)}`);
    expect(view.state.doc.toString()).toBe(TYPED);

    // 3. Cmd-Z: routes to plain text undo (the document is not the post-op document), which removes the typing.
    press('undo');
    snap('after Cmd-Z #1');
    expect(structuralUndoRequested).not.toHaveBeenCalled();
    expect(view.state.doc.toString()).toBe(POST);
    expect(redoDepth(view.state)).toBeGreaterThan(0); // the typing is on the redo branch

    // 4. Cmd-Z: the document equals the post-op document, so routing sends it structural. Swift's old body restores.
    press('undo');
    expect(structuralUndoRequested).toHaveBeenCalledTimes(1);
    expect(structuralUndoRequested).toHaveBeenCalledWith({ opId: OP_ID });
    oldBodyUndo(PRE);
    snap('after Cmd-Z #2 (structural undo of the delete)');
    expect(view.state.doc.toString()).toBe(PRE);
    const redoDepthAfterStructuralUndo = redoDepth(view.state);

    // 5. Cmd-Shift-Z: the document equals the pre-op document, so routing sends it structural. Swift's old body re-deletes.
    press('redo');
    expect(structuralRedoRequested).toHaveBeenCalledTimes(1);
    expect(structuralRedoRequested).toHaveBeenCalledWith({ opId: OP_ID });
    oldBodyRedo(POST);
    snap('after Cmd-Shift-Z #1 (structural redo of the delete)');
    expect(view.state.doc.toString()).toBe(POST);
    const redoDepthAfterStructuralRedo = redoDepth(view.state);

    // 6. Cmd-Shift-Z: nothing structural is left on the redo stack, so it falls through to the text redo.
    press('redo');
    snap('after Cmd-Shift-Z #2 (text redo of the typing)');

    // eslint-disable-next-line no-console
    console.log(`T-U21 steps (${_label}):\n${JSON.stringify(steps, null, 2)}`);

    // The pin: the redo branch survived both setContent() swaps, so the last redo brings the typing back.
    expect(redoDepthAfterStructuralUndo).toBeGreaterThan(0);
    expect(redoDepthAfterStructuralRedo).toBeGreaterThan(0);
    expect(structuralRedoRequested).not.toHaveBeenCalled(); // the last press was a text redo
    expect(view.state.doc.toString()).toBe(TYPED); // 'typing not restored by redo' would be the failure here
  });

  it('same sequence on the real editor text shape: section anchors on every heading, the old body pushes anchor-free text, anchors are re-injected as derived pushes, and the restore mints fresh ids', () => {
    // The real Markdown editor text carries `<!-- @sid:UUID -->` in front of every heading. Today's old body pushes the
    // DB-assembled markdown WITHOUT anchors (settleAfterDBRestore, "degraded path"), and the next content rebuild
    // re-injects anchors as a derived push (setContent origin 'derived'); a restore gives the sections fresh ids
    // (restoreEntireProject deletes and re-inserts them), so the routing decisions after the undo rest on the
    // "equal modulo anchors" fallback (derived-equivalence.ts). The redo branch must survive all of that churn too.
    const anchored = (text: string, idPrefix: string): string => {
      let n = 0;
      return text.replace(/^(# Chapter \d)/gm, (heading) => {
        n += 1;
        const id = `${idPrefix}${String(n).padStart(7, '0')}-aaaa-bbbb-cccc-dddddddddddd`;
        return `<!-- @sid:${id} -->${heading}`;
      });
    };
    // The surviving sections keep their ids across Delete (set "a"); a restore mints new ones (set "b").
    const preA = anchored(PRE, 'a');
    const postA = (): string => {
      // Chapter 3 is gone; chapters 1, 2 and 4 keep the ids they had in `preA` (a0000001, a0000002, a0000004).
      return preA.replace(/<!-- @sid:a0000003[^>]*-->#[^\n]*\n\nThird chapter text\.\n\n/, '');
    };
    const preB = anchored(PRE, 'b');
    const postB = (): string => preB.replace(/<!-- @sid:b0000003[^>]*-->#[^\n]*\n\nThird chapter text\.\n\n/, '');
    expect(postA()).not.toContain('Third chapter');
    expect(postB()).not.toContain('Third chapter');

    ff().setContent(preA);
    ff().resetForProjectSwitch();
    ff().setContent(preA);
    view = currentView();
    // resetForProjectSwitch keeps the doc and drops history; a setContent into an empty doc is not a user edit
    expect(view.state.doc.toString()).toBe(preA);
    expect(undoDepth(view.state)).toBe(0);

    const steps: Array<Record<string, unknown>> = [];
    const snap = (name: string) =>
      steps.push({
        step: name,
        doc: view.state.doc.toString(),
        undoDepth: undoDepth(view.state),
        redoDepth: redoDepth(view.state),
      });
    snap('start');

    // Delete Section: old body forward op = anchor-free push, finalize, descriptor; then the derived anchor re-injection.
    expect(ff().beginStructuralOp(OP_ID)).toBe(true);
    ff().setContent(POST);
    expect(ff().finalizeStructuralOpPostOpDoc(OP_ID)).toBe(true);
    ff().setUndoDescriptor({ undoTopOpId: OP_ID });
    ff().setContent(postA(), { origin: 'derived' });
    snap('after Delete Section (anchors re-injected)');
    expect(view.state.doc.toString()).toBe(postA());

    // The user types at the end of Chapter 2's first paragraph.
    const marker = 'Second chapter text.';
    const pos = view.state.doc.toString().indexOf(marker) + marker.length;
    typeAt(pos, 'hello there');
    const typedDoc = view.state.doc.toString();
    snap('after typing "hello there"');

    press('undo'); // text undo of the typing
    snap('after Cmd-Z #1');
    expect(structuralUndoRequested).not.toHaveBeenCalled();
    expect(view.state.doc.toString()).toBe(postA());

    press('undo'); // structural
    expect(structuralUndoRequested).toHaveBeenCalledTimes(1);
    // performUndo -> settleAfterDBRestore: anchor-free push; then the rebuild's derived anchor injection with fresh ids.
    ff().setContent(PRE);
    ff().setContent(preB, { origin: 'derived' });
    ff().setUndoDescriptor({ redoTopOpId: OP_ID });
    ff().receiveUndoOutcome(OP_ID, 'performed');
    structuralUndoRequested.mockClear();
    snap('after Cmd-Z #2 (structural undo, fresh ids)');
    expect(view.state.doc.toString()).toBe(preB);
    const redoDepthAfterStructuralUndo = redoDepth(view.state);

    press('redo'); // structural (the live doc equals the pre-op doc modulo anchors)
    expect(structuralRedoRequested).toHaveBeenCalledTimes(1);
    ff().setContent(POST);
    ff().setContent(postB(), { origin: 'derived' });
    ff().setUndoDescriptor({ undoTopOpId: OP_ID });
    ff().receiveRedoOutcome(OP_ID, 'performed');
    structuralRedoRequested.mockClear();
    snap('after Cmd-Shift-Z #1 (structural redo)');
    expect(view.state.doc.toString()).toBe(postB());
    const redoDepthAfterStructuralRedo = redoDepth(view.state);

    press('redo'); // text redo
    snap('after Cmd-Shift-Z #2 (text redo of the typing)');
    // eslint-disable-next-line no-console
    console.log(`T-U21 steps (with anchors and fresh ids):\n${JSON.stringify(steps, null, 2)}`);

    expect(redoDepthAfterStructuralUndo).toBeGreaterThan(0);
    expect(redoDepthAfterStructuralRedo).toBeGreaterThan(0);
    expect(structuralRedoRequested).not.toHaveBeenCalled();
    // 'typing not restored by redo' would be the failure here. The typed text sits where it was, next to the same
    // paragraph, now under the fresh anchors.
    expect(view.state.doc.toString()).toBe(postB().replace(marker, `${marker}hello there`));
    void typedDoc;
  });

  it('the dependency versions this pin was measured against are the ones installed', async () => {
    // Informational pin: a different @codemirror/commands or state version could change how history maps through a
    // non-history change, so a later change in this result must be traced here first. The history-JSON shape pin
    // proper belongs to W10 (round 2).
    const { readFileSync } = await import('node:fs');
    const here = decodeURIComponent(import.meta.url.replace(/^file:\/\//, ''));
    const packageRoot = here.slice(0, here.indexOf('/src/__tests__/'));
    const version = (name: string): string =>
      JSON.parse(readFileSync([packageRoot, 'node_modules', name, 'package.json'].join('/'), 'utf8')).version;
    expect(version('@codemirror/commands')).toBe('6.10.1');
    expect(version('@codemirror/state')).toBe('6.5.4');
  });
});
