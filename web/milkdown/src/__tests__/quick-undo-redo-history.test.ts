// @vitest-environment jsdom
//
// Quick undo of an editor-first section delete keeps the editor's REDO history (t-07eac5cb, redo-history fix, 2026-10-16).
//
// The everyday path: delete a section, type a sentence somewhere else, press Cmd-Z until the section is back (press 1 takes the
// typing away, press 2 brings the section back at once: the quick undo), then Cmd-Shift-Z twice. Press 1 removes the section again
// (the quick redo), press 2 must bring the sentence back. Two things used to throw the sentence's redo step away:
//   (A) the quick undo swaps in the whole EditorState saved before the delete, history plugin state included, and the swap dropped
//       the live redo branch (found by the VM test WriteQueuePhase4bDeleteFlowE2ETests/testDeleteTypeUndo_book6);
//   (B) the footnote renumber (and the heading-level correction) that follows is dispatched as its own recorded undo step, and
//       prosemirror-history empties the redo branch on any recorded step.
// The fix carries the branch across the swap (api-section-undo.ts, built by redo-branch.ts) and keeps it across every
// `derivedCorrection` dispatch (footnote-plugin.ts, api-content.ts).
//
// Tests: QU19 two typed sentences, redo depth asserted at every step; QU19b the same with a footnote inside the deleted section (the
// renumber fires after the quick redo); QU19c typing after the quick undo still empties the redo branch; QU19d the heading-level
// correction keeps the branch; QU19e a plain text undo of a typed footnote reference keeps the branch through its renumber;
// QU19f/QU19g/QU19j the carry's guards fall back to the plain swap and say so; QU19h a renumber that lands after the typing; QU19i the
// cost on a generated book; QU19p the pin on prosemirror-history 1.5.0 (the version and the protocol the code relies on).
//
// Same harness as quick-undo-section-delete.test.ts: a real Milkdown editor, `view.dispatch` through the production
// `runUndoTrackedDispatch`, a Cmd-Z as a real keydown through `handleUnifiedUndoKeydown`; Swift's side is played by the test.

import { readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { history as pmHistory, redo, redoDepth, undo, undoDepth } from '@milkdown/kit/prose/history';
import { type Node, Schema } from '@milkdown/kit/prose/model';
import { EditorState, type Plugin } from '@milkdown/kit/prose/state';
import { Transform } from '@milkdown/kit/prose/transform';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { setContentWithBlockIds, updateHeadingLevels } from '../api-content';
import { deleteSectionEditorFirst } from '../api-section-delete';
import {
  redoSectionDeleteEditorFirst,
  resumeSyncAfterQuickUndo,
  undoSectionDeleteEditorFirst,
} from '../api-section-undo';
import { blockIdPlugin, getAllBlockIds, resetBlockIdState, setBlockIdZoomMode } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { setContentHasBeenSet, setEditorInstance } from '../editor-state';
import { footnotePlugin, insertFootnote, renumberFootnotes } from '../footnote-plugin';
import { highlightPlugin } from '../highlight-plugin';
import { noteTransactionForEditSpanTracking, resetRecentUserEditSpanForTests } from '../recent-edit-span';
import { sectionBreakPlugin } from '../section-break-plugin';
import { setTraceTyping } from '../typing-trace';
import {
  handleUnifiedUndoKeydown,
  receiveRedoOutcome,
  receiveUndoOutcome,
  resetUndoCoordinatorState,
  runUndoTrackedDispatch,
  setUndoDescriptor,
} from '../undo-coordinator';
import { takePendingAsReport } from './pending-for-test';

// === Documents ===

interface Spec {
  name: string;
  md: string;
}
const heading = (name: string, level: number, title: string): Spec => ({ name, md: `${'#'.repeat(level)} ${title}` });
const para = (name: string, text: string): Spec => ({ name, md: text });
const markdownOf = (specs: Spec[]) => specs.map((s) => s.md).join('\n\n');

/** Footnotes before (1) and after (2) the section that gets deleted; the section itself has none, so no renumber follows. */
const PLAIN_SPECS: Spec[] = [
  heading('a', 1, 'Chapter A'),
  para('a-p1', 'Alpha one.[^1]'),
  heading('b', 1, 'Chapter B'),
  para('b-p1', 'Beta one.'),
  para('b-p2', 'Beta two.'),
  heading('c', 1, 'Chapter C'),
  para('c-p1', 'Gamma one.[^2]'),
  para('c-p2', 'Gamma two.'),
  heading('notes', 2, 'Notes'),
  para('n1', '[^1]: Note one.'),
  para('n2', '[^2]: Note two.'),
];

/** Footnotes before (1), INSIDE (2) and after (3, 4) the section that gets deleted: the delete leaves the renumber {3: 2, 4: 3}. */
const INNER_SPECS: Spec[] = [
  heading('a', 1, 'Chapter A'),
  para('a-p1', 'Alpha one.[^1]'),
  heading('b', 1, 'Chapter B'),
  para('b-p1', 'Beta one.[^2]'),
  para('b-p2', 'Beta two.'),
  heading('c', 1, 'Chapter C'),
  para('c-p1', 'Gamma one.[^3]'),
  para('c-p2', 'Gamma two.[^4]'),
  heading('notes', 2, 'Notes'),
  para('n1', '[^1]: Note one.'),
  para('n2', '[^2]: Note two.'),
  para('n3', '[^3]: Note three.'),
  para('n4', '[^4]: Note four.'),
];

const OP_A = '11111111-2222-3333-4444-555555555555';
const FIRST = ' FIRST-SENTENCE.';
const SECOND = ' SECOND-SENTENCE.';

// === Harness ===

let current: Editor | null = null;

afterEach(async () => {
  // A resume schedules its contentChanged about 50 ms ahead: let it fire into THIS test's bridge, never into the next test's.
  await sleep(70);
  setTraceTyping(false);
  setContentHasBeenSet(false);
  vi.useRealTimers();
  if (current) {
    await current.destroy();
    current = null;
  }
  setEditorInstance(null);
  resetBlockIdState();
  resetBlockSyncState();
  setBlockIdZoomMode(false);
  setSyncPaused(false);
  resetUndoCoordinatorState();
  resetRecentUserEditSpanForTests();
  delete (window as any).webkit;
});

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** Waits `frames` animation frames and then one task: a content push unpauses block-sync from a frame callback. */
function waitForRAF(frames = 3): Promise<void> {
  return new Promise((resolve) => {
    let remaining = frames;
    const step = () => {
      remaining--;
      if (remaining <= 0) setTimeout(resolve, 0);
      else requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
}

type Posted = Array<{ handler: string; body: any }>;

function installBridge(): Posted {
  const posted: Posted = [];
  const handler = (name: string) => ({ postMessage: (body: unknown) => posted.push({ handler: name, body }) });
  (window as any).webkit = {
    messageHandlers: {
      structuralUndoRequested: handler('structuralUndoRequested'),
      structuralRedoRequested: handler('structuralRedoRequested'),
      errorHandler: handler('errorHandler'),
      contentChanged: handler('contentChanged'),
      undoHeldPressSettled: handler('undoHeldPressSettled'),
      undoQueueDropped: handler('undoQueueDropped'),
      historyEdited: handler('historyEdited'),
    },
  };
  return posted;
}

async function makeEditor(): Promise<{ view: EditorView; posted: Posted }> {
  const posted = installBridge();
  const div = document.createElement('div');
  document.body.appendChild(div);
  const editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, '');
    })
    .use(sectionBreakPlugin)
    .use(footnotePlugin)
    .use(commonmark)
    .use(gfm)
    .use(highlightPlugin)
    .use(blockIdPlugin)
    .use(historyPlugin)
    .use(blockSyncPlugin)
    .create();
  current = editor;
  setEditorInstance(editor);
  const view = editor.ctx.get(editorViewCtx);
  const originalDispatch = view.dispatch.bind(view);
  view.dispatch = (tr) => runUndoTrackedDispatch(view, tr, originalDispatch);
  return { view, posted };
}

function idsInOrder(): string[] {
  return Array.from(getAllBlockIds().entries())
    .sort((a, b) => a[0] - b[0])
    .map(([, id]) => id);
}

/** Loads `specs` with explicit ids (the spec names) and lets the push's deferred unpause run. */
async function load(specs: Spec[]): Promise<void> {
  setContentWithBlockIds(
    markdownOf(specs),
    specs.map((s) => s.name)
  );
  await waitForRAF();
  takePendingAsReport(); // whatever the push itself left pending is not what these tests are about
  expect(idsInOrder()).toEqual(specs.map((s) => s.name));
}

/** Document position at the end of the content of the top-level node of type `type` whose text starts with `startsWith`. */
function endOf(view: EditorView, type: string, startsWith: string): number {
  let endPos = -1;
  view.state.doc.forEach((node, offset) => {
    if (endPos === -1 && node.type.name === type && node.textContent.startsWith(startsWith)) {
      endPos = offset + node.nodeSize - 1;
    }
  });
  expect(endPos, `${type} starting with "${startsWith}" must exist`).toBeGreaterThan(-1);
  return endPos;
}

/** A real, history-adding user edit at the end of a paragraph (after a trailing footnote reference, if it has one). */
function typeInto(view: EditorView, startsWith: string, word: string): void {
  view.dispatch(view.state.tr.insertText(word, endOf(view, 'paragraph', startsWith)));
}

/** Swift's Notes rebuild removing a definition paragraph: a sync-origin change, not in the text history. */
function dropParagraphAsSync(view: EditorView, startsWith: string): void {
  let range: { from: number; to: number } | null = null;
  view.state.doc.forEach((node, offset) => {
    if (!range && node.type.name === 'paragraph' && node.textContent.includes(startsWith)) {
      range = { from: offset, to: offset + node.nodeSize };
    }
  });
  expect(range, `paragraph containing "${startsWith}" must exist`).not.toBeNull();
  const { from, to } = range as unknown as { from: number; to: number };
  view.dispatch(view.state.tr.delete(from, to).setMeta('addToHistory', false));
}

/** Swift relabelling footnote definitions only (the new reference was renumbered by the insertion itself): sync origin. */
function relabelDefinitionsAsSync(view: EditorView, map: Record<string, string>): void {
  const tr = view.state.tr;
  view.state.doc.descendants((n, pos) => {
    const to = map[String(n.attrs.label)];
    if (n.type.name === 'footnote_def' && to) tr.setNodeMarkup(pos, undefined, { ...n.attrs, label: to });
  });
  expect(tr.docChanged, 'premise: a definition was relabelled').toBe(true);
  view.dispatch(tr.setMeta('addToHistory', false));
}

function labelsIn(doc: Node, typeName: 'footnote_ref' | 'footnote_def'): string[] {
  const out: string[] = [];
  doc.descendants((n) => {
    if (n.type.name === typeName) out.push(String(n.attrs.label));
  });
  return out;
}

/** The children of the paragraph starting with `startsWith`, as 'text:...' and 'ref:<label>' entries. */
function paragraphParts(view: EditorView, startsWith: string): string[] {
  let parts: string[] | null = null;
  view.state.doc.forEach((node) => {
    if (parts === null && node.type.name === 'paragraph' && node.textContent.startsWith(startsWith)) {
      parts = [];
      node.forEach((child) => {
        (parts as string[]).push(child.isText ? `text:${child.text}` : `${child.type.name}:${child.attrs.label}`);
      });
    }
  });
  expect(parts, `paragraph starting with "${startsWith}" must exist`).not.toBeNull();
  return parts as unknown as string[];
}

const textOf = (view: EditorView, startsWith: string) =>
  paragraphParts(view, startsWith)
    .filter((p) => p.startsWith('text:'))
    .map((p) => p.slice(5))
    .join('');

function headingLevel(view: EditorView, startsWith: string): number | undefined {
  let level: number | undefined;
  view.state.doc.forEach((node) => {
    if (level === undefined && node.type.name === 'heading' && node.textContent.startsWith(startsWith)) {
      level = node.attrs.level;
    }
  });
  return level;
}

function keyZ(shift: boolean): KeyboardEvent {
  return new KeyboardEvent('keydown', { key: 'z', metaKey: true, shiftKey: shift, cancelable: true });
}

/** Cmd-Z with `top` on top of Swift's undo stack: the production routing decision, which latches the coordinator for `top`. */
function pressUndo(view: EditorView, top: string): boolean {
  setUndoDescriptor({ undoTopOpId: top });
  return handleUnifiedUndoKeydown(keyZ(false), view, 'undo');
}

function pressRedo(view: EditorView, top: string): boolean {
  setUndoDescriptor({ redoTopOpId: top });
  return handleUnifiedUndoKeydown(keyZ(true), view, 'redo');
}

/** What Swift does after a successful quick undo: resume, push the descriptor, reply. */
function swiftFinishesUndo(opId: string, descriptor: { undoTopOpId?: string; redoTopOpId?: string }): void {
  resumeSyncAfterQuickUndo();
  setUndoDescriptor(descriptor);
  receiveUndoOutcome(opId, 'performed');
}

function swiftFinishesRedo(opId: string, descriptor: { undoTopOpId?: string; redoTopOpId?: string }): void {
  setUndoDescriptor(descriptor);
  receiveRedoOutcome(opId, 'performed');
}

/** Cmd-Z that the editor's own history handles (the routing falls through because the typing differs from the saved copy). */
function textUndo(view: EditorView, label: string): void {
  expect(pressUndo(view, OP_A), `${label}: the press is the editor's own text undo`).toBe(false);
  expect(undo(view.state, view.dispatch), `${label}: there is a text step to undo`).toBe(true);
}

/** The first Cmd-Z/Cmd-Shift-Z that is a structural one: the press latches the coordinator and the quick path answers it. */
function quickUndo(view: EditorView): void {
  expect(pressUndo(view, OP_A), 'the live document equals the saved copy again: this press is structural').toBe(true);
  const result = undoSectionDeleteEditorFirst(OP_A);
  expect(result.ok, `quick undo reason: ${result.reason}`).toBe(true);
  swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
}

function quickRedo(view: EditorView, root = 'b', managedIds: string[] = []): void {
  expect(pressRedo(view, OP_A), 'the live document equals the restored copy: this press is structural').toBe(true);
  const result = redoSectionDeleteEditorFirst(OP_A, root, managedIds);
  expect(result.ok, `quick redo reason: ${result.reason}`).toBe(true);
  swiftFinishesRedo(OP_A, { undoTopOpId: OP_A });
}

// === QU19 to QU19e ===

describe('quick undo keeps the editor redo history', () => {
  it('QU19: two typed sentences, both undone, then the quick undo and quick redo: both can still be redone, in order', async () => {
    const { view } = await makeEditor();
    await load(PLAIN_SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    typeInto(view, 'Alpha one', FIRST); // before the deleted section, after a footnote reference
    typeInto(view, 'Gamma one', SECOND); // after the deleted section, after a footnote reference
    expect(redoDepth(view.state), 'typing leaves nothing to redo').toBe(0);

    textUndo(view, 'Cmd-Z 1');
    expect(redoDepth(view.state), 'redo depth after text undo 1').toBe(1);
    textUndo(view, 'Cmd-Z 2');
    expect(redoDepth(view.state), 'redo depth after text undo 2').toBe(2);
    expect(textOf(view, 'Alpha one')).toBe('Alpha one.');
    expect(textOf(view, 'Gamma one')).toBe('Gamma one.');

    quickUndo(view); // Cmd-Z 3: the section is back
    expect(view.state.doc.textContent).toContain('Beta one.');
    expect(redoDepth(view.state), 'redo depth right after the quick undo: both sentences are still redoable').toBe(2);

    quickRedo(view); // Cmd-Shift-Z 1: the section is gone again
    expect(view.state.doc.textContent).not.toContain('Beta one.');
    expect(redoDepth(view.state), 'redo depth right after the quick redo: still both').toBe(2);

    expect(redo(view.state, view.dispatch), 'Cmd-Shift-Z 2 is a text redo').toBe(true);
    expect(textOf(view, 'Alpha one'), 'the first sentence is back, where it was typed').toBe(`Alpha one.${FIRST}`);
    expect(textOf(view, 'Gamma one')).toBe('Gamma one.');
    expect(redoDepth(view.state), 'redo depth after text redo 1').toBe(1);
    expect(redo(view.state, view.dispatch), 'Cmd-Shift-Z 3 is a text redo').toBe(true);
    expect(textOf(view, 'Gamma one'), 'the second sentence is back, where it was typed').toBe(`Gamma one.${SECOND}`);
    expect(redoDepth(view.state), 'redo depth after text redo 2').toBe(0);
    expect(view.state.doc.textContent, 'the section stayed deleted through both text redos').not.toContain('Beta');
  });

  it('QU19b: with a footnote inside the deleted section the renumber after the quick redo keeps both sentences redoable, with the right labels', async () => {
    const { view } = await makeEditor();
    await load(INNER_SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    renumberFootnotes({ '3': '2', '4': '3' }); // Swift's renumber after the delete: its own recorded text-undo step
    dropParagraphAsSync(view, 'Note two.'); // Swift's Notes rebuild: the deleted section's definition goes
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1', '2', '3']);
    expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(['1', '2', '3']);
    typeInto(view, 'Alpha one', FIRST);
    typeInto(view, 'Gamma one', SECOND); // a paragraph after the section whose footnote reference was renumbered 3 -> 2

    textUndo(view, 'Cmd-Z 1');
    textUndo(view, 'Cmd-Z 2');
    expect(redoDepth(view.state), 'redo depth after both text undos').toBe(2);

    quickUndo(view);
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'the pre-delete labels are back').toEqual(['1', '2', '3', '4']);
    expect(redoDepth(view.state), 'redo depth right after the quick undo').toBe(2);

    quickRedo(view);
    expect(redoDepth(view.state), 'redo depth right after the quick redo').toBe(2);
    // The same automatic rewrites land again after the quick redo; the renumber is a recorded step.
    const undoDepthBeforeRenumber = undoDepth(view.state);
    renumberFootnotes({ '3': '2', '4': '3' });
    expect(undoDepth(view.state), 'premise: the renumber is its own text-undo step').toBe(undoDepthBeforeRenumber + 1);
    dropParagraphAsSync(view, 'Note two.');
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1', '2', '3']);
    expect(redoDepth(view.state), 'redo depth after the renumber that follows the quick redo').toBe(2);

    expect(redo(view.state, view.dispatch)).toBe(true);
    expect(textOf(view, 'Alpha one'), 'the first sentence is back').toBe(`Alpha one.${FIRST}`);
    expect(redoDepth(view.state), 'redo depth after text redo 1').toBe(1);
    expect(redo(view.state, view.dispatch)).toBe(true);
    expect(paragraphParts(view, 'Gamma one'), 'the second sentence is back, after the renumbered reference').toEqual([
      'text:Gamma one.',
      'footnote_ref:2',
      `text:${SECOND}`,
    ]);
    expect(redoDepth(view.state), 'redo depth after text redo 2').toBe(0);
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'the labels are the renumbered ones').toEqual(['1', '2', '3']);
    expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(['1', '2', '3']);
  });

  it('QU19c: typing after the quick undo empties the redo branch, as normal typing does', async () => {
    const { view } = await makeEditor();
    await load(PLAIN_SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    typeInto(view, 'Alpha one', FIRST);
    textUndo(view, 'Cmd-Z 1');
    expect(redoDepth(view.state)).toBe(1);
    quickUndo(view);
    expect(redoDepth(view.state), 'redo depth right after the quick undo: the undone sentence is redoable').toBe(1);

    typeInto(view, 'Gamma one', ' NEW-WORDS.');

    expect(redoDepth(view.state), 'a new keystroke empties the redo branch').toBe(0);
    expect(redo(view.state, view.dispatch), 'and there is nothing left to redo').toBe(false);
    expect(textOf(view, 'Alpha one')).toBe('Alpha one.');
  });

  it('QU19d: the heading-level correction on a heading the user just edited keeps the redo branch', async () => {
    const { view } = await makeEditor();
    await load(PLAIN_SPECS);
    // A real edit in the heading (tracked, as main.ts's dispatch override tracks it), then a sentence elsewhere that gets undone.
    const headingEdit = view.state.tr.insertText(' X', endOf(view, 'heading', 'Chapter C'));
    view.dispatch(headingEdit);
    noteTransactionForEditSpanTracking(headingEdit);
    typeInto(view, 'Alpha one', FIRST);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(redoDepth(view.state), 'the undone sentence is redoable').toBe(1);
    const undoDepthBefore = undoDepth(view.state);
    expect(headingLevel(view, 'Chapter C')).toBe(1);

    updateHeadingLevels([{ blockId: 'c', newLevel: 2 }]); // hierarchy enforcement lands on the heading just edited
    await waitForRAF();

    expect(headingLevel(view, 'Chapter C'), 'premise: the correction was applied').toBe(2);
    expect(undoDepth(view.state), 'premise: an overlapping correction is its own undoable step').toBe(
      undoDepthBefore + 1
    );
    expect(redoDepth(view.state), 'the correction keeps the redo branch').toBe(1);
    expect(redo(view.state, view.dispatch)).toBe(true);
    expect(textOf(view, 'Alpha one'), 'the sentence is redone').toBe(`Alpha one.${FIRST}`);
    expect(headingLevel(view, 'Chapter C'), 'and the correction stays').toBe(2);
    expect(redoDepth(view.state)).toBe(0);
  });

  it('QU19e: undoing a typed footnote reference and the renumber it causes keeps the redo branch: redoing brings the reference back with the right labels', async () => {
    const { view } = await makeEditor();
    await load([
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      para('a-p2', 'Alpha two.'),
      para('a-p3', 'Alpha three.[^1]'),
      heading('notes', 2, 'Notes'),
      para('n1', '[^1]: Note one.'),
    ]);
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1']);
    // The user inserts a footnote reference BEFORE the existing one: one recorded transaction that also renumbers the later reference.
    const newLabel = insertFootnote(endOf(view, 'paragraph', 'Alpha one'));
    expect(newLabel).toBe('1');
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'premise: the existing reference became 2').toEqual(['1', '2']);
    relabelDefinitionsAsSync(view, { '1': '2' }); // Swift moves the existing definition to 2
    expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(['2']);

    expect(undo(view.state, view.dispatch), 'Cmd-Z takes the typed reference back').toBe(true);
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1']);
    expect(redoDepth(view.state), 'the typed reference is redoable').toBe(1);
    // The definitions no longer match: Swift's footnote sync renumbers the definition back. It is a recorded step.
    const undoDepthBefore = undoDepth(view.state);
    renumberFootnotes({ '2': '1' });
    expect(labelsIn(view.state.doc, 'footnote_def'), 'premise: the renumber was applied').toEqual(['1']);
    expect(undoDepth(view.state), 'premise: the renumber is its own text-undo step').toBe(undoDepthBefore + 1);
    expect(redoDepth(view.state), 'the renumber keeps the redo branch').toBe(1);

    expect(redo(view.state, view.dispatch), 'Cmd-Shift-Z brings the typed reference back').toBe(true);
    expect(paragraphParts(view, 'Alpha one'), 'the reference is back, where it was typed').toEqual([
      'text:Alpha one.',
      'footnote_ref:1',
    ]);
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'the later reference is renumbered again').toEqual(['1', '2']);
    expect(redoDepth(view.state)).toBe(0);
    relabelDefinitionsAsSync(view, { '1': '2' }); // and Swift follows with the definition
    expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(['2']);
  });
});

// === QU19f to QU19h: the guard, and derived content inside the redo branch ===

/** The history plugin's state for the view (prosemirror-history's `HistoryState`). */
const historyOf = (view: EditorView): { done: any; undone: any } =>
  (view.state as any).config.pluginsByKey.history$.getState(view.state);

const traceLines = (posted: Posted): string[] =>
  posted.filter((p) => p.handler === 'errorHandler').map((p) => String((p.body as { message?: string }).message));

describe('the carry is a guard, not a requirement', () => {
  /** Replaces `target[name]` with `replacement(original)` and returns the function that puts the original back. */
  const replaceMethod = (target: any, name: string, replacement: (original: any) => any) => {
    const original = target[name];
    target[name] = replacement(original);
    return () => {
      target[name] = original;
    };
  };

  /** Runs one quick undo with a piece of the carry's machinery broken by `breakIt`, which returns the function that mends it. */
  async function quickUndoWithBrokenCarry(breakIt: (view: EditorView) => () => void) {
    const { view, posted } = await makeEditor();
    await load(PLAIN_SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    typeInto(view, 'Alpha one', FIRST);
    textUndo(view, 'Cmd-Z 1');
    expect(redoDepth(view.state)).toBe(1);
    expect(pressUndo(view, OP_A)).toBe(true);
    const mend = breakIt(view);
    let result: ReturnType<typeof undoSectionDeleteEditorFirst>;
    try {
      result = undoSectionDeleteEditorFirst(OP_A);
    } finally {
      mend();
    }
    return { view, posted, result };
  }

  /** What a guarded fallback leaves behind: the section back, no redo branch, the reason on the trace. */
  function expectPlainSwap(
    { view, posted, result }: Awaited<ReturnType<typeof quickUndoWithBrokenCarry>>,
    reasonSubstring: string
  ): void {
    expect(result.ok, `reason: ${result.reason}`).toBe(true);
    expect(view.state.doc.textContent, 'the document is restored').toContain('Beta one.');
    expect(redoDepth(view.state), 'the plain swap loses the redo branch, and only that').toBe(0);
    expect(
      traceLines(posted).some((m) => m.includes('redo branch not carried') && m.includes(reasonSubstring)),
      'the fallback leaves a trace line'
    ).toBe(true);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
  }

  it('QU19f: a carried branch whose event count changed is not used: the section is back, the redo branch is lost, a trace line says so', async () => {
    const run = await quickUndoWithBrokenCarry((view) =>
      replaceMethod(Object.getPrototypeOf(historyOf(view).undone), 'addMaps', (original) => {
        return function (this: unknown, ...args: any[]) {
          const branch = original.apply(this, args);
          return Object.assign(Object.create(Object.getPrototypeOf(branch)), branch, {
            eventCount: branch.eventCount + 1,
          });
        };
      })
    );

    expectPlainSwap(run, 'event count 2 after the carry, 1 before');
  });

  it('QU19g: a throw while building the carry is the same fallback', async () => {
    const run = await quickUndoWithBrokenCarry((view) =>
      replaceMethod(Object.getPrototypeOf(historyOf(view).undone), 'addMaps', () => {
        return () => {
          throw new Error('carry-boom');
        };
      })
    );

    expectPlainSwap(run, 'exception: carry-boom');
  });

  it('QU19j: steps that do not produce the restored document are not used either', async () => {
    const run = await quickUndoWithBrokenCarry(() =>
      replaceMethod(Transform.prototype, 'replaceWith', () => {
        return function (this: unknown) {
          return this; // the insertion of the deleted section never happens
        };
      })
    );

    expectPlainSwap(run, 'the steps do not produce the restored document');
  });

  it('QU19h: a renumber that landed AFTER the typing is a redo step too: it survives the quick undo and the quick redo, and redoing everything ends with the right labels', async () => {
    const { view } = await makeEditor();
    await load(INNER_SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    typeInto(view, 'Alpha one', FIRST);
    renumberFootnotes({ '3': '2', '4': '3' }); // lands after the typing: a text-undo step of its own
    dropParagraphAsSync(view, 'Note two.');
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1', '2', '3']);

    textUndo(view, 'Cmd-Z 1'); // takes the renumber back
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1', '3', '4']);
    expect(redoDepth(view.state)).toBe(1);
    textUndo(view, 'Cmd-Z 2'); // takes the typing back
    expect(redoDepth(view.state)).toBe(2);
    quickUndo(view);
    expect(redoDepth(view.state), 'redo depth right after the quick undo: the renumber and the sentence').toBe(2);
    quickRedo(view);
    expect(redoDepth(view.state), 'redo depth right after the quick redo').toBe(2);
    renumberFootnotes({ '3': '2', '4': '3' }); // the same rewrites land again
    dropParagraphAsSync(view, 'Note two.');
    expect(redoDepth(view.state), 'redo depth after the rewrites that follow the quick redo').toBe(2);

    expect(redo(view.state, view.dispatch)).toBe(true);
    expect(textOf(view, 'Alpha one'), 'the sentence is back').toBe(`Alpha one.${FIRST}`);
    expect(redoDepth(view.state)).toBe(1);
    expect(redo(view.state, view.dispatch), 'the renumber redo applies on top of the renumber that landed again').toBe(
      true
    );
    expect(redoDepth(view.state)).toBe(0);
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1', '2', '3']);
    expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(['1', '2', '3']);
    expect(view.state.doc.textContent).not.toContain('Beta');
  });
});

// === QU19i: the cost on a generated book (reported, not a timing assertion: jsdom is not WKWebView) ===
// Twelve chapters of sixteen sections of five paragraphs, a Notes tail of sixty footnote definitions, five footnote references at the
// end of every chapter intro: about 1,300 top-level blocks. Chapter 6 is deleted, so thirty references and definitions are
// renumbered and five definitions are orphaned, as Swift's rewrites do. The figures are logged (`[quick-undo-redo-cost]`) so the run
// record can quote them with the block count beside them.

const SENTENCE =
  'The fieldwork continued through the monsoon season while the archive stayed closed to outside readers. ';
const PARAGRAPH = SENTENCE.repeat(6).trim();

function generateFootnoteBook(): Spec[] {
  const specs: Spec[] = [];
  let note = 0;
  for (let c = 1; c <= 12; c++) {
    specs.push(heading(`ch${c}`, 1, `Chapter ${c}`));
    const refs: string[] = [];
    for (let k = 0; k < 5; k++) refs.push(`[^${++note}]`);
    specs.push(para(`ch${c}-intro`, `Chapter ${c}. ${PARAGRAPH}${refs.join('')}`));
    for (let s = 1; s <= 16; s++) {
      specs.push(heading(`ch${c}-s${s}`, 2, `Section ${c}.${s}`));
      for (let k = 1; k <= 5; k++) specs.push(para(`ch${c}-s${s}-p${k}`, `Paragraph ${c}.${s}.${k}. ${PARAGRAPH}`));
    }
  }
  specs.push(heading('notes-h', 2, 'Notes'));
  for (let n = 1; n <= note; n++) specs.push(para(`note${n}`, `[^${n}]: Note ${n}.`));
  return specs;
}

describe('the redo branch on a generated twelve-chapter book', () => {
  it('QU19i: two undone sentences survive the quick undo and the quick redo on about 1,300 blocks, and the carry cost is logged', async () => {
    const { view, posted } = await makeEditor();
    const specs = generateFootnoteBook();
    await load(specs);
    const blocks = view.state.doc.childCount;
    const managed = specs.filter((s) => s.name.startsWith('note')).map((s) => s.name);
    expect(deleteSectionEditorFirst(OP_A, 'ch6', managed).ok).toBe(true);
    const renumber: Record<string, string> = {};
    for (let n = 31; n <= 60; n++) renumber[String(n)] = String(n - 5);
    const swiftRewrites = () => {
      renumberFootnotes(renumber);
      for (let n = 26; n <= 30; n++) dropParagraphAsSync(view, `Note ${n}.`);
    };
    swiftRewrites();
    expect(labelsIn(view.state.doc, 'footnote_ref')).toHaveLength(55);
    typeInto(view, 'Chapter 1.', FIRST);
    typeInto(view, 'Chapter 12.', SECOND); // after the deleted chapter, behind five renumbered references
    textUndo(view, 'Cmd-Z 1');
    textUndo(view, 'Cmd-Z 2');
    expect(redoDepth(view.state), 'redo depth after both text undos').toBe(2);
    expect(pressUndo(view, OP_A)).toBe(true);

    const t0 = performance.now();
    const result = undoSectionDeleteEditorFirst(OP_A);
    const undoMs = performance.now() - t0;
    expect(result.ok, `reason: ${result.reason}`).toBe(true);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
    expect(redoDepth(view.state), 'both sentences are still redoable after the quick undo').toBe(2);
    expect(labelsIn(view.state.doc, 'footnote_ref')).toHaveLength(60);

    quickRedo(view, 'ch6', managed);
    swiftRewrites();
    expect(redoDepth(view.state), 'redo depth after the quick redo and the rewrites that follow it').toBe(2);
    expect(redo(view.state, view.dispatch)).toBe(true);
    expect(redo(view.state, view.dispatch)).toBe(true);
    expect(textOf(view, 'Chapter 1.').endsWith(FIRST), 'the first sentence is back at the end of chapter 1').toBe(true);
    expect(textOf(view, 'Chapter 12.').endsWith(SECOND), 'the second sentence is back at the end of chapter 12').toBe(
      true
    );
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'the references are the renumbered ones again').toHaveLength(55);

    const undoLine = traceLines(posted).find((m) => m.includes('quick-undo opId') && m.includes('ok=true'));
    console.log(
      `[quick-undo-redo-cost] blocks=${blocks} footnotes=60 renumbered=30 restored=${result.restoredIds.length} undoCallMs=${undoMs.toFixed(1)}\n${undoLine}`
    );
  }, 60_000);
});

// === QU19p: the pin on prosemirror-history 1.5.0 ===
// redo-branch.ts reaches into prosemirror-history's internals (`pluginsByKey.history$`, `HistoryState`, `Branch.addMaps`, the
// `historyState` meta protocol). They are not public API; this test fails, with the broken assumption in its message, the day the
// installed version or any of those behaviours changes.

describe('QU19p: prosemirror-history 1.5.0, the version and the protocol redo-branch.ts relies on', () => {
  it('the installed version is exactly 1.5.0', () => {
    // Plain string handling, not `new URL(...)`: under jsdom the URL class is jsdom's, which Node's fileURLToPath refuses.
    const here = decodeURIComponent(import.meta.url.replace(/^file:\/\//, ''));
    const webRoot = resolve(dirname(here), '../../..');
    const installed = readdirSync(join(webRoot, 'node_modules', '.pnpm')).filter((name) =>
      name.startsWith('prosemirror-history@')
    );
    expect(installed, 'a different prosemirror-history is installed: re-check redo-branch.ts against it').toEqual([
      'prosemirror-history@1.5.0',
    ]);
  });

  it('a recorded step empties the redo branch, a step outside the history maps it, and a carried branch is adopted and redone', () => {
    const schema = new Schema({
      nodes: {
        doc: { content: 'paragraph+' },
        paragraph: { content: 'text*', toDOM: () => ['p', 0] },
        text: {},
      },
    });
    const paragraph = (text: string) => schema.nodes.paragraph.create(null, text ? schema.text(text) : undefined);
    const live0 = EditorState.create({
      schema,
      doc: schema.nodes.doc.create(null, [paragraph('one'), paragraph('two')]),
      plugins: [pmHistory()],
    });
    const plugin = (live0 as any).config.pluginsByKey.history$ as Plugin;
    expect(plugin, 'the history plugin is registered under "history$"').toBeDefined();

    // Two typed sentences in two undo groups, both undone: the redo branch holds two events.
    let live = live0;
    live = live.apply(live.tr.insertText('A', 4)); // end of "one"
    live = live.apply(live.tr.insertText('B', 10)); // end of "two": paragraph 1 is now 6 wide, so the content of paragraph 2 ends at 6 + 1 + 3
    const undoIn = (state: EditorState) => {
      let next = state;
      undo(state, (tr) => {
        next = state.apply(tr);
      });
      return next;
    };
    live = undoIn(undoIn(live));
    expect(redoDepth(live), 'two undone events').toBe(2);
    expect(live.doc.textContent).toBe('onetwo');

    // The branch object: a number of events, and addMaps on its prototype.
    const hist = plugin.getState(live) as any;
    expect(typeof hist.undone.eventCount).toBe('number');
    expect(typeof Object.getPrototypeOf(hist.undone).addMaps, 'Branch.addMaps exists').toBe('function');

    // A recorded step empties the branch; a step outside the history keeps it (and maps it).
    expect(redoDepth(live.apply(live.tr.insertText('X', 1))), 'a recorded step empties the redo branch').toBe(0);
    const keptByUnrecorded = live.apply(live.tr.insertText('Y', 1).setMeta('addToHistory', false));
    expect(redoDepth(keptByUnrecorded), 'a step outside the history keeps the redo branch').toBe(2);

    // The carry: the document changes under the branch (a paragraph in front), the branch is mapped through that change and handed to
    // a state that has none, through the meta protocol, as a copy of the HistoryState with another `undone`.
    const change = new Transform(live.doc).insert(0, paragraph('zero'));
    const target = EditorState.create({ schema, doc: change.doc, plugins: live.plugins });
    const carriedUndone = hist.undone.addMaps(change.mapping.maps);
    expect(carriedUndone.eventCount, 'addMaps keeps the events').toBe(2);
    const targetHist = plugin.getState(target) as any;
    expect(targetHist.undone.eventCount).toBe(0);
    const historyState = Object.assign(Object.create(Object.getPrototypeOf(targetHist)), targetHist, {
      undone: carriedUndone,
    });
    const carried = target.apply(target.tr.setMeta(plugin, { redo: false, historyState }));
    expect(carried.doc.eq(target.doc), 'the meta transaction does not touch the document').toBe(true);
    expect(redoDepth(carried), 'the carried branch is adopted').toBe(2);

    const redoIn = (state: EditorState) => {
      let next = state;
      redo(state, (tr) => {
        next = state.apply(tr);
      });
      return next;
    };
    const redone1 = redoIn(carried);
    expect(redone1.doc.textContent, 'the first redo lands in the right paragraph, shifted by the change').toBe(
      'zerooneAtwo'
    );
    const redone2 = redoIn(redone1);
    expect(redone2.doc.textContent).toBe('zerooneAtwoB');
    expect(redoDepth(redone2)).toBe(0);
  });
});
