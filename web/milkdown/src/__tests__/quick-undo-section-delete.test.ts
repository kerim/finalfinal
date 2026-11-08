// @vitest-environment jsdom
//
// Phase 4b part 2, slice 2b (t-07eac5cb): the quick undo and quick redo of an editor-first section delete (api-section-undo.ts).
//
// These are GUARD tests (the must-fail reproductions of the loss live in the Swift unit tests, plan section 6.1): each one pins one
// property of the editor half and has its own targeted break (a small patch to the production code, run by the driver) with the
// assertion-level fingerprint named in the failure message of the assertion that carries the property.
//
// The harness is the real thing, as in delete-section-editor-first.test.ts: a real Milkdown editor with the block-id, block-sync
// and history plugins, `view.dispatch` wired through the production `runUndoTrackedDispatch`, real timers and real animation frames.
// A Cmd-Z is a real keydown through `handleUnifiedUndoKeydown`, so the in-flight latch the quick undo's re-check needs is the one
// the production press sets. Swift's side of the conversation (the descriptor push and the reply) is played by the test.
//
// Tests: QU1 history kept, QU2 ids and the confirmation log, QU3 typing during the pause, QU3b the contentChanged notification,
// QU4 the re-check refuses, QU5 original labels and no queued restore, QU6 quick redo is a fresh removal, QU7 undo-redo-undo, QU7b the
// redone entry is the newest registry key, QU8 a held second press, QU9 an id push after the delete, QU10 a throw after the swap,
// QU11 resume never ends someone else's pause, QU13 the paint markers, QU14 a refused or failed redo, plus the cost measurement.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { undo, undoDepth } from '@milkdown/kit/prose/history';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { confirmBlockIdsApi, setContentWithBlockIds, syncBlockIds } from '../api-content';
import { deleteSectionEditorFirst } from '../api-section-delete';
import {
  quickUndoLiveDiffersFromRestored,
  redoSectionDeleteEditorFirst,
  resumeSyncAfterQuickUndo,
  undoSectionDeleteEditorFirst,
} from '../api-section-undo';
import { blockIdPlugin, getAllBlockIds, resetBlockIdState, setBlockIdZoomMode } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { pushLiveContentToSwift } from '../content-push';
import { setContentHasBeenSet, setEditorInstance } from '../editor-state';
import { find, getSearchState, replaceCurrent } from '../find-replace';
import { highlightPlugin } from '../highlight-plugin';
import { sectionBreakPlugin } from '../section-break-plugin';
import { setTraceTyping } from '../typing-trace';
import {
  beginStructuralOp,
  clearStructuralUndoRegistry,
  finalizeStructuralOpPostOpDoc,
  getQueuedPressDirections,
  getQuickUndoPausedOpId,
  getRegistry,
  handleUnifiedUndoKeydown,
  performStructuralSwap,
  receiveRedoOutcome,
  receiveUndoOutcome,
  resetUndoCoordinatorState,
  runUndoTrackedDispatch,
  setInFlightOpId,
  setLatched,
  setUndoDescriptor,
  typingCollectorPlugin,
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

const SPECS: Spec[] = [
  heading('a', 1, 'Chapter A'),
  para('a-p1', 'Alpha one.'),
  heading('b', 1, 'Chapter B'),
  para('b-p1', 'Beta one.'),
  para('b-p2', 'Beta two.'),
  heading('c', 1, 'Chapter C'),
  para('c-p1', 'Gamma one.'),
];

const OP_A = '11111111-2222-3333-4444-555555555555';
const OP_B = '66666666-7777-8888-9999-000000000000';
const OP_C = 'cccccccc-7777-8888-9999-000000000000';
const EMPTY_BATCH = { updates: [], inserts: [], deletes: [] };

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

/** The Swift bridge as a recorder: every message the editor posts, by handler name. */
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
    .use(commonmark)
    .use(gfm)
    .use(highlightPlugin)
    .use(blockIdPlugin)
    .use(historyPlugin)
    .use(blockSyncPlugin)
    .use(typingCollectorPlugin) // records the steps typed while a press waits, as main.ts registers it
    .create();
  current = editor;
  setEditorInstance(editor);
  const view = editor.ctx.get(editorViewCtx);
  const originalDispatch = view.dispatch.bind(view);
  view.dispatch = (tr) => runUndoTrackedDispatch(view, tr, originalDispatch);
  return { view, posted };
}

/** Block ids in document order, as the block-id plugin holds them. */
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

/** Document position at the end of the text of the paragraph starting with `startsWith`. */
function endOfParagraph(view: EditorView, startsWith: string): number {
  let endPos = -1;
  view.state.doc.forEach((node, offset) => {
    if (endPos === -1 && node.type.name === 'paragraph' && node.textContent.startsWith(startsWith)) {
      endPos = offset + node.nodeSize - 1;
    }
  });
  expect(endPos, `paragraph starting with "${startsWith}" must exist`).toBeGreaterThan(-1);
  return endPos;
}

/** A real, history-adding user edit. */
function typeInto(view: EditorView, startsWith: string, word: string): void {
  view.dispatch(view.state.tr.insertText(word, endOfParagraph(view, startsWith)));
}

/** An automatic rewrite (a footnote renumber or a Notes rebuild landing): sync origin, not added to the text history. */
function automaticRewrite(view: EditorView, startsWith: string, word: string): void {
  view.dispatch(view.state.tr.insertText(word, endOfParagraph(view, startsWith)).setMeta('addToHistory', false));
}

function keyZ(shift: boolean): KeyboardEvent {
  return new KeyboardEvent('keydown', { key: 'z', metaKey: true, shiftKey: shift, cancelable: true });
}

/** Cmd-Z with `top` on top of Swift's undo stack: the production routing decision, which latches the coordinator for `top`. */
function pressUndo(view: EditorView, top: string, descriptor: { redoTopOpId?: string } = {}): boolean {
  setUndoDescriptor({ undoTopOpId: top, ...descriptor });
  return handleUnifiedUndoKeydown(keyZ(false), view, 'undo');
}

function pressRedo(view: EditorView, top: string): boolean {
  setUndoDescriptor({ redoTopOpId: top });
  return handleUnifiedUndoKeydown(keyZ(true), view, 'redo');
}

const requestedOps = (posted: Posted, handler: string) =>
  posted.filter((p) => p.handler === handler).map((p) => p.body as { opId: string; held?: boolean });

/** What Swift does after a successful quick undo: resume (the real order is: reserve the reinsert's ticket, then resume), push the
 * descriptor, reply. The latch clears at the reply, which also routes any press that was held behind it. */
function swiftFinishesUndo(opId: string, descriptor: { undoTopOpId?: string; redoTopOpId?: string }): void {
  resumeSyncAfterQuickUndo();
  setUndoDescriptor(descriptor);
  receiveUndoOutcome(opId, 'performed');
}

/** The same for a quick redo (no resume: the redo pauses and unpauses block-sync inside the call). */
function swiftFinishesRedo(opId: string, descriptor: { undoTopOpId?: string; redoTopOpId?: string }): void {
  setUndoDescriptor(descriptor);
  receiveRedoOutcome(opId, 'performed');
}

// === QU1 to QU5 ===

describe('quick undo of an editor-first section delete', () => {
  it("QU1: restores the section in one call and keeps the delete's text history", async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    typeInto(view, 'Beta one', ' TYPED-QU1'); // a history step INSIDE the section that is about to be deleted
    const docBeforeDelete = view.state.doc;
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(view.state.doc.textContent).not.toContain('Beta');
    expect(pressUndo(view, OP_A)).toBe(true);

    const result = undoSectionDeleteEditorFirst(OP_A);

    expect(result.ok, `reason: ${result.reason}`).toBe(true);
    expect(view.state.doc.eq(docBeforeDelete), 'the whole section is back, in one call').toBe(true);
    expect(
      undoDepth(view.state),
      "the restored state carries the text history of the checkpoint (the delete's history)"
    ).toBeGreaterThan(0);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
    expect(undo(view.state, view.dispatch), 'a text undo has a step to undo').toBe(true);
    expect(
      view.state.doc.textContent,
      'one text undo takes the typed word back out of the restored section'
    ).not.toContain('TYPED-QU1');
    expect(view.state.doc.textContent).toContain('Beta one.');
  });

  it('QU2: restored blocks carry their pre-delete ids, temp ids resolved through the confirmation log', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    // A paragraph typed into section B and not yet confirmed by Swift holds a temp id.
    const { schema } = view.state;
    view.dispatch(
      view.state.tr.insert(
        endOfParagraph(view, 'Beta two') + 1,
        schema.nodes.paragraph.create(null, schema.text('Beta new.'))
      )
    );
    const tempId = idsInOrder().find((id) => id.startsWith('temp-')) as string;
    expect(tempId, 'the new paragraph has a temp id').toBeDefined();
    const idsBeforeDelete = idsInOrder();
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    // Swift confirms that temp id AFTER the delete (the batch the delete consumed carried the insert): the block is gone from the
    // editor, so only the registry entry's log can learn of it.
    confirmBlockIdsApi({ [tempId]: 'perm-qu2' });
    // A rewrite that landed after the delete (absorbed into the saved copy), diffed by block-sync and not yet polled by Swift: the
    // press consumes it as the batch Swift applies BEFORE the reinsert (the everyday case after a renumber or a text undo).
    automaticRewrite(view, 'Gamma', ' (pending-qu2)');
    await sleep(160);
    expect(pressUndo(view, OP_A)).toBe(true);

    const result = undoSectionDeleteEditorFirst(OP_A);

    expect(result.ok, `reason: ${result.reason}`).toBe(true);
    expect(
      result.batch.updates.map((u) => u.id),
      'the edit pending before the press is consumed and returned as the batch on success'
    ).toEqual(['c-p1']);
    expect(result.batch.updates[0].textContent).toContain('(pending-qu2)');
    expect(takePendingAsReport(), 'and it is consumed, not queued a second time').toEqual(EMPTY_BATCH);
    const expectedIds = idsBeforeDelete.map((id) => (id === tempId ? 'perm-qu2' : id));
    expect(idsInOrder(), 'the restored blocks hold the confirmed permanent id, not the temp id').toEqual(expectedIds);
    expect(result.restoredIds).toEqual(['b', 'b-p1', 'b-p2', 'perm-qu2']);
    expect(result.restoredLeaderIds).toEqual(['b']);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
  });

  it('QU3: typing during the pause is detected at resume and queued, and the paused window recorded nothing', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(pressUndo(view, OP_A)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A).ok).toBe(true);
    expect(getQuickUndoPausedOpId()).toBe(OP_A);

    typeInto(view, 'Beta one', ' TYPED-QU3-IN'); // into the restored section
    typeInto(view, 'Gamma', ' TYPED-QU3-OUT'); // elsewhere
    await sleep(160);
    expect(takePendingAsReport(), 'block-sync is paused: a poll in this window gets nothing').toEqual({
      updates: [],
      inserts: [],
      deletes: [],
    });

    const resumed = resumeSyncAfterQuickUndo();

    expect(resumed.ok).toBe(true);
    expect(resumed.resumed).toBe(true);
    // Swift's polls get nothing while the press is latched (phase 4c job 2); the reply ends the hold and the queued edits go out.
    expect(takePendingAsReport(), 'held until the reply').toEqual(EMPTY_BATCH);
    receiveUndoOutcome(OP_A, 'performed');
    const queued = takePendingAsReport();
    const text = (id: string) => queued.updates.find((u) => u.id === id)?.textContent ?? '';
    expect(text('b-p1'), 'the word typed into the restored paragraph is queued at resume').toContain('TYPED-QU3-IN');
    expect(text('c-p1'), 'the word typed elsewhere during the pause is queued at resume').toContain('TYPED-QU3-OUT');
    expect(queued.inserts).toEqual([]);
    expect(queued.deletes).toEqual([]);
    // Block-sync runs again after the resume: a later edit is one ordinary update.
    typeInto(view, 'Alpha', ' AFTER-RESUME');
    await sleep(160);
    expect(takePendingAsReport().updates.map((u) => u.id)).toEqual(['a-p1']);
  });

  it('QU3b: resume sends the contentChanged notification, off the call, with the live restored text', async () => {
    const { view, posted } = await makeEditor();
    await load(SPECS);
    setContentHasBeenSet(true);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(pressUndo(view, OP_A)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A).ok).toBe(true);
    typeInto(view, 'Beta one', ' TYPED-QU3B');
    const contentMessages = () => posted.filter((p) => p.handler === 'contentChanged');
    expect(contentMessages(), 'nothing is posted before the resume').toHaveLength(0);

    const resumed = resumeSyncAfterQuickUndo();

    expect(resumed.contentChangedScheduled).toBe(true);
    expect(contentMessages(), 'the serialisation is not on the resume call').toHaveLength(0);
    await sleep(120);
    expect(contentMessages(), 'a contentChanged notification fires after the resume').toHaveLength(1);
    const body = contentMessages()[0].body as { content: string; wasUndo: boolean };
    expect(body.wasUndo).toBe(false);
    expect(body.content, 'it carries the restored section').toContain('Chapter B');
    expect(body.content, 'and what was typed in the meantime').toContain('TYPED-QU3B');
    receiveUndoOutcome(OP_A, 'performed');
  });

  it('QU4: refuses and changes nothing when a change that is not typing was made since the press (the document no longer matches the saved copy)', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(pressUndo(view, OP_A)).toBe(true); // routed structurally: the document equalled the saved copy at the press
    // ... and the user types, then an automatic correction lands, before the quick undo's turn (typing alone would be put back on top:
    // typing-across-undo-quick.test.ts)
    typeInto(view, 'Gamma', ' TYPED');
    view.dispatch(
      view.state.tr.insertText(' TYPED-QU4', endOfParagraph(view, 'Gamma')).setMeta('derivedCorrection', true)
    );
    const docWithTyping = view.state.doc;
    const entryBefore = getRegistry().get(OP_A);

    const result = undoSectionDeleteEditorFirst(OP_A);

    expect(result.ok, 'the quick undo refuses: the document changed since the press').toBe(false);
    expect(result.reason).toBe('docChanged');
    expect(result.batch, 'a refusal consumes nothing').toEqual({ updates: [], inserts: [], deletes: [] });
    expect(view.state.doc.eq(docWithTyping), 'a refusal leaves the document exactly as the user has it').toBe(true);
    expect(view.state.doc.textContent).not.toContain('Beta');
    expect(getRegistry().get(OP_A), 'the registry entry is untouched').toBe(entryBefore);
    expect(entryBefore?.redoCheckpoint).toBeUndefined();
    expect(getQuickUndoPausedOpId()).toBeNull();
    // Block-sync was never paused and the edit was never consumed: it is queued by the normal detection, and goes out once the reply has
    // ended the hold on Swift's polls (phase 4c job 2).
    await sleep(160);
    expect(takePendingAsReport(), 'held while the press is latched').toEqual(EMPTY_BATCH);
    expect(resumeSyncAfterQuickUndo()).toMatchObject({ ok: true, resumed: false });
    receiveUndoOutcome(OP_A, 'failed');
    const queued = takePendingAsReport();
    expect(queued.updates.map((u) => u.id)).toEqual(['c-p1']);
    expect(queued.updates[0].textContent).toContain('TYPED-QU4');
  });

  it('QU5: after an absorbed renumber, puts the original reference labels back and queues no block changes for the restore itself', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    // The rewrite lands after the delete (a footnote renumber, say), is absorbed into the saved copy, and goes to the database
    // through the ordinary poll.
    automaticRewrite(view, 'Gamma', ' (renumbered)');
    await sleep(160);
    takePendingAsReport();
    const checkpointDoc = getRegistry().get(OP_A)?.checkpoint.doc;
    expect(pressUndo(view, OP_A)).toBe(true);

    const result = undoSectionDeleteEditorFirst(OP_A);

    expect(result.ok, `reason: ${result.reason}`).toBe(true);
    expect(view.state.doc.textContent, 'the original labels are back, not the renumbered ones').not.toContain(
      '(renumbered)'
    );
    expect(view.state.doc.eq(checkpointDoc as NonNullable<typeof checkpointDoc>)).toBe(true);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
    expect(
      takePendingAsReport(),
      'right after the restore and the resume, before any typing, nothing is queued'
    ).toEqual(EMPTY_BATCH);
    await sleep(160);
    expect(
      takePendingAsReport(),
      'the restore itself queues no block changes (the reinsert carries it to the database)'
    ).toEqual({ updates: [], inserts: [], deletes: [] });
  });

  it('QU6: quick redo is a fresh removal of the CURRENT document: labels from the current document, a fresh confirmation log', async () => {
    const { view, posted } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    const logAtDelete = getRegistry().get(OP_A)?.confirmLog;
    expect(pressUndo(view, OP_A)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A).ok).toBe(true);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
    // After the undo an automatic rewrite lands (the renumber of the restored section's footnotes, say) and is absorbed.
    automaticRewrite(view, 'Gamma', ' (renumbered-2)');
    await sleep(160);
    takePendingAsReport();
    expect(pressRedo(view, OP_A)).toBe(true);
    expect(requestedOps(posted, 'structuralRedoRequested')).toEqual([{ opId: OP_A }]);

    const result = redoSectionDeleteEditorFirst(OP_A, 'b', []);

    expect(result.ok, `reason: ${result.reason}`).toBe(true);
    expect(result.removedIds).toEqual(['b', 'b-p1', 'b-p2']);
    expect(result.removedLeaderIds).toEqual(['b']);
    expect(
      view.state.doc.textContent,
      'the redo removes the section from the current document and keeps its labels'
    ).toContain('(renumbered-2)');
    expect(view.state.doc.textContent).not.toContain('Beta');
    const entry = getRegistry().get(OP_A);
    expect(entry?.confirmLog, 'the redone entry starts a fresh confirmation log').not.toBe(logAtDelete);
    expect(entry?.confirmLog).toEqual([]);
    expect(entry?.idMap ? Array.from(entry.idMap.values()) : []).toEqual([
      'a',
      'a-p1',
      'b',
      'b-p1',
      'b-p2',
      'c',
      'c-p1',
    ]);
    expect(entry?.redoCheckpoint, 'a fresh entry: no stored redo state').toBeUndefined();
    expect(entry?.midOp).toBe(false);
    expect(entry?.postOpDoc.eq(view.state.doc)).toBe(true);
    expect(entry?.checkpoint.doc.textContent).toContain('Beta one.');
    expect(entry?.checkpoint.doc.textContent).toContain('(renumbered-2)');
    swiftFinishesRedo(OP_A, { undoTopOpId: OP_A });
  });

  it('QU7: undo, redo, undo keeps the registry consistent: the redo re-captures checkpoint, postOpDoc and preOpDoc', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(pressUndo(view, OP_A)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A).ok).toBe(true);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
    automaticRewrite(view, 'Gamma', ' (renumbered-7)');
    await sleep(160);
    takePendingAsReport();
    const docBeforeRedo = view.state.doc;
    expect(pressRedo(view, OP_A)).toBe(true);
    expect(redoSectionDeleteEditorFirst(OP_A, 'b', []).ok).toBe(true);
    swiftFinishesRedo(OP_A, { undoTopOpId: OP_A });
    const entry = getRegistry().get(OP_A);
    expect(entry?.preOpDoc.eq(docBeforeRedo), 'preOpDoc is the document the redo found').toBe(true);
    expect(entry?.postOpDoc.eq(view.state.doc), 'postOpDoc is the document after the redo').toBe(true);
    expect(entry?.checkpoint.doc.eq(docBeforeRedo), 'checkpoint is the state the redo found').toBe(true);

    // The second undo routes structurally (postOpDoc is exact) and restores the document the REDO found, not the first undo's.
    expect(pressUndo(view, OP_A), 'Cmd-Z routes to the redone delete').toBe(true);
    const second = undoSectionDeleteEditorFirst(OP_A);

    expect(second.ok, `reason: ${second.reason}`).toBe(true);
    expect(view.state.doc.eq(docBeforeRedo), 'the second undo restores the document the redo found').toBe(true);
    expect(view.state.doc.textContent).toContain('(renumbered-7)');
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
  });

  it('QU7b: the redone entry is the newest registry key, so the saved-copy rebase targets it and its next undo still routes', async () => {
    const { view, posted } = await makeEditor();
    await load(SPECS);
    // Delete A then B; undo B, undo A, redo A: the registry then lists B before A.
    expect(deleteSectionEditorFirst(OP_A, 'a', []).ok).toBe(true);
    expect(deleteSectionEditorFirst(OP_B, 'b', []).ok).toBe(true);
    expect(pressUndo(view, OP_B)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_B).ok).toBe(true);
    swiftFinishesUndo(OP_B, { undoTopOpId: OP_A, redoTopOpId: OP_B });
    expect(pressUndo(view, OP_A, { redoTopOpId: OP_B })).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A).ok).toBe(true);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
    expect(pressRedo(view, OP_A)).toBe(true);
    expect(redoSectionDeleteEditorFirst(OP_A, 'a', []).ok).toBe(true);
    swiftFinishesRedo(OP_A, { undoTopOpId: OP_A });
    expect(Array.from(getRegistry().keys()), 'the redone entry moved to the end of the registry').toEqual([OP_B, OP_A]);

    // The user types, an automatic rewrite lands (no text-history step), and the typing is undone again.
    typeInto(view, 'Gamma', ' TYPED-QU7B');
    automaticRewrite(view, 'Beta two', ' (rewritten)');
    await sleep(160);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('TYPED-QU7B');
    expect(view.state.doc.textContent).toContain('(rewritten)');
    takePendingAsReport();

    expect(pressUndo(view, OP_A), "A's next Cmd-Z routes to the section delete, not to a refusal").toBe(true);
    expect(requestedOps(posted, 'structuralUndoRequested').at(-1)).toEqual({ opId: OP_A });
    const result = undoSectionDeleteEditorFirst(OP_A);
    expect(result.ok, `reason: ${result.reason}`).toBe(true);
    receiveUndoOutcome(OP_A, 'performed');
  });

  it('QU8: after performed, a held second press is decided against the restored document', async () => {
    const { view, posted } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'a', []).ok).toBe(true);
    expect(deleteSectionEditorFirst(OP_B, 'b', []).ok).toBe(true);
    expect(pressUndo(view, OP_B)).toBe(true); // the first Cmd-Z: latched
    expect(handleUnifiedUndoKeydown(keyZ(false), view, 'undo'), 'the second Cmd-Z is held behind the latch').toBe(true);
    expect(getQueuedPressDirections()).toEqual(['undo']);
    expect(requestedOps(posted, 'structuralUndoRequested')).toEqual([{ opId: OP_B }]);

    expect(undoSectionDeleteEditorFirst(OP_B).ok).toBe(true);
    swiftFinishesUndo(OP_B, { undoTopOpId: OP_A, redoTopOpId: OP_B }); // the reply releases the held press

    expect(
      requestedOps(posted, 'structuralUndoRequested'),
      'the held press routes to the NEXT entry, against the restored document'
    ).toEqual([{ opId: OP_B }, { opId: OP_A, held: true }]);
    expect(getQueuedPressDirections()).toEqual([]);
    const second = undoSectionDeleteEditorFirst(OP_A);
    expect(second.ok, `reason: ${second.reason}`).toBe(true);
    expect(view.state.doc.textContent).toContain('Chapter A');
    expect(view.state.doc.textContent).toContain('Chapter B');
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
  });

  it('QU9: an id push after the delete (the idle backup) leaves routing structural, and the restore puts the pre-delete ids back', async () => {
    const { view, posted } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    // The backup re-ids every surviving row and pushes the new ids: ids only, never the document.
    const docBefore = view.state.doc;
    syncBlockIds(['fresh-a', 'fresh-a-p1', 'fresh-c', 'fresh-c-p1'], false);
    expect(view.state.doc.eq(docBefore), 'an id push never touches the document').toBe(true);
    expect(idsInOrder()).toEqual(['fresh-a', 'fresh-a-p1', 'fresh-c', 'fresh-c-p1']);

    expect(pressUndo(view, OP_A), 'Cmd-Z still routes structurally after the id push').toBe(true);
    expect(requestedOps(posted, 'structuralUndoRequested')).toEqual([{ opId: OP_A }]);
    const result = undoSectionDeleteEditorFirst(OP_A);

    expect(result.ok, `reason: ${result.reason}`).toBe(true);
    expect(idsInOrder(), 'the restore puts every id back as it was at the delete').toEqual(SPECS.map((s) => s.name));
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
  });

  it('QU10: a throw after the swap (at the caret scroll) puts the live state, the ids and block-sync back, and the refusal still carries the consumed batch', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    automaticRewrite(view, 'Gamma', ' (pending-qu10)'); // diffed by block-sync, not yet polled: the press consumes it
    await sleep(160);
    const docAfterDelete = view.state.doc;
    const idsAfterDelete = idsInOrder();
    const entryBefore = getRegistry().get(OP_A);
    expect(pressUndo(view, OP_A)).toBe(true);
    // The throw is the caret-scroll transaction: it runs after the checkpoint swap, the saved id maps and the baseline were put in,
    // so the rollback has real work to undo (ids included).
    const dispatch = view.dispatch;
    let thrown = false;
    view.dispatch = (tr) => {
      if (!thrown && !tr.docChanged && tr.scrolledIntoView) {
        thrown = true;
        throw new Error('injected failure at the caret scroll');
      }
      dispatch(tr);
    };

    const result = undoSectionDeleteEditorFirst(OP_A);
    view.dispatch = dispatch;

    expect(thrown, 'the injected failure fired after the swap').toBe(true);
    expect(result.ok).toBe(false);
    expect(result.reason).toContain('injected failure at the caret scroll');
    expect(view.state.doc.eq(docAfterDelete), 'the document is back to what the user had before the press').toBe(true);
    expect(idsInOrder(), 'and so are the block ids').toEqual(idsAfterDelete);
    expect(
      result.batch.updates.map((u) => u.id),
      'the failure reply still carries the batch the call consumed'
    ).toEqual(['c-p1']);
    expect(getRegistry().get(OP_A), 'the registry entry is the one it was').toBe(entryBefore);
    expect(getQuickUndoPausedOpId()).toBeNull();
    // Block-sync runs, against the live document: an edit is exactly one update.
    typeInto(view, 'Gamma', ' AFTER-QU10');
    await sleep(160);
    expect(takePendingAsReport(), 'held while the press is latched (phase 4c job 2)').toEqual(EMPTY_BATCH);
    receiveUndoOutcome(OP_A, 'failed');
    const queued = takePendingAsReport();
    expect(queued.updates.map((u) => u.id)).toEqual(['c-p1']);
    expect(queued.inserts).toEqual([]);
    expect(queued.deletes).toEqual([]);
  });

  it('QU12: a barrier inside the paused window ends the pause itself: typing done during it is queued, and typing after it is recorded', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(pressUndo(view, OP_A)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A).ok).toBe(true);
    typeInto(view, 'Beta one', ' TYPED-QU12-IN'); // during the pause
    // The section-metadata barrier (`invalidateAll`, no content push after it) lands before Swift's resume call.
    clearStructuralUndoRegistry();
    expect(getQuickUndoPausedOpId()).toBeNull();
    expect(resumeSyncAfterQuickUndo(), 'the later resume has nothing of the quick undo to hand back').toMatchObject({
      ok: true,
      resumed: false,
    });

    // Before any further typing: what the user typed during the pause is already queued (the barrier diffed it).
    const atBarrier = takePendingAsReport();
    expect(
      atBarrier.updates.find((u) => u.id === 'b-p1')?.textContent ?? '',
      'the typing done during the pause is queued by the barrier'
    ).toContain('TYPED-QU12-IN');

    typeInto(view, 'Gamma', ' TYPED-QU12-OUT'); // after the barrier
    await sleep(160);
    const afterwards = takePendingAsReport();
    expect(
      afterwards.updates.find((u) => u.id === 'c-p1')?.textContent ?? '',
      'a barrier in the paused window ends the pause: block-sync records typing again'
    ).toContain('TYPED-QU12-OUT');
  });

  it("QU11: resume with no quick undo waiting touches nothing: it never ends another operation's block-sync pause", async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    setSyncPaused(true); // someone else's pause (a content push, say)

    const resumed = resumeSyncAfterQuickUndo();

    expect(resumed).toEqual({
      ok: true,
      resumed: false,
      pausedEdits: { updates: 0, inserts: 0, deletes: 0 },
      contentChangedScheduled: false,
    });
    typeInto(view, 'Gamma', ' WHILE-PAUSED');
    await sleep(160);
    expect(takePendingAsReport().updates, "the other operation's pause is still in force: nothing is recorded").toEqual(
      []
    );
  });

  it('QU13: the restore paint marker is posted for the quick and the slow path, only while the typing trace is on', async () => {
    const { view, posted } = await makeEditor();
    await load(SPECS);
    const paintLines = () =>
      posted
        .filter((p) => p.handler === 'errorHandler')
        .map((p) => (p.body as { message: string }).message)
        .filter((m) => m.includes('restore painted'));

    // Flag off: nothing is scheduled.
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(pressUndo(view, OP_A)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A).ok).toBe(true);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
    await waitForRAF();
    expect(paintLines()).toEqual([]);
    // What the quick redo really uses: the entry's `preOpDoc` is the restored document, and no stored redo state exists.
    const entry = getRegistry().get(OP_A);
    expect(entry?.redoCheckpoint, 'the quick path stores no redo state').toBeUndefined();
    expect(
      entry?.preOpDoc.eq(view.state.doc),
      'preOpDoc is the restored document: the quick redo re-checks against it'
    ).toBe(true);

    // Flag on: a quick redo, then the quick undo again (its marker), then a delete undone by the SLOW swap (its marker).
    setTraceTyping(true);
    expect(pressRedo(view, OP_A)).toBe(true);
    expect(redoSectionDeleteEditorFirst(OP_A, 'b', []).ok).toBe(true);
    swiftFinishesRedo(OP_A, { undoTopOpId: OP_A });
    expect(pressUndo(view, OP_A)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A).ok).toBe(true);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
    expect(paintLines(), 'not before the frame').toEqual([]);
    await waitForRAF();
    expect(paintLines(), 'the quick undo posts its restore paint marker (path=quick)').toEqual([
      '[STRUCT-TRACE] restore painted op=11111111 path=quick',
    ]);

    expect(deleteSectionEditorFirst(OP_B, 'c', []).ok).toBe(true);
    expect(performStructuralSwap(OP_B, 'undo'), 'the slow swap of the second delete').toBe(true);
    await waitForRAF();
    expect(paintLines().at(-1), 'the slow swap posts its restore paint marker (path=slow)').toBe(
      '[STRUCT-TRACE] restore painted op=66666666 path=slow'
    );
  });

  it('QU14: a redo whose removal would take typed words with it (typing INSIDE the removed chapter) is refused, and one that fails after it started leaves the op undone with its entry', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(pressUndo(view, OP_A)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A).ok).toBe(true);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
    const entryAfterUndo = getRegistry().get(OP_A);

    // Round 3 (Q2): a quick redo is a fresh command on the document as it stands, so typing ELSEWHERE no longer refuses it (see
    // typing-across-undo-quick.test.ts W16a). Typed between the press and the redo's turn INSIDE the chapter the redo takes out (the
    // typed words would go with it): refused, nothing removed, the typing comes back in the reply once.
    expect(pressRedo(view, OP_A)).toBe(true);
    typeInto(view, 'Beta one', ' TYPED-QU14');
    const docWithTyping = view.state.doc;
    const refused = redoSectionDeleteEditorFirst(OP_A, 'b', []);
    expect(refused.ok).toBe(false);
    expect(refused.reason).toBe('docChanged');
    expect(refused.batch.updates.map((u) => u.id)).toEqual(['b-p1']);
    expect(refused.batch.updates[0].textContent).toBe('Beta one. TYPED-QU14');
    expect(view.state.doc.eq(docWithTyping)).toBe(true);
    expect(getRegistry().get(OP_A)).toBe(entryAfterUndo);
    receiveRedoOutcome(OP_A, 'failed');

    // The typing is undone again; the redo is asked to remove a block that is not there: the removal fails after it began.
    expect(undo(view.state, view.dispatch)).toBe(true);
    await sleep(160);
    takePendingAsReport();
    expect(pressRedo(view, OP_A)).toBe(true);
    const docBeforeFailure = view.state.doc;
    const failed = redoSectionDeleteEditorFirst(OP_A, 'no-such-id', []);
    expect(failed.ok).toBe(false);
    expect(failed.reason).toBe('rootNotFound');
    expect(view.state.doc.eq(docBeforeFailure)).toBe(true);
    expect(getRegistry().get(OP_A), 'the entry the op had before the failed redo is back').toBe(entryAfterUndo);
    receiveRedoOutcome(OP_A, 'failed');
  });

  it('QU16: the delete click, the quick undo and the quick redo clear a Find session like every slow structural path', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    // jsdom has no layout: a Find match selects text, and scrolling a text selection into view asks the DOM Range for its rects.
    const rangeProto = Range.prototype as unknown as Record<string, unknown>;
    const rect = { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 };
    rangeProto.getClientRects ??= () => [rect];
    rangeProto.getBoundingClientRect ??= () => rect;
    expect(find('Alpha').matchCount).toBe(1);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(getSearchState(), 'the delete click cleared the Find session').toBeNull();

    expect(find('Gamma').matchCount).toBe(1);
    expect(pressUndo(view, OP_A)).toBe(true);
    const undone = undoSectionDeleteEditorFirst(OP_A);
    expect(undone.ok, `reason: ${undone.reason}`).toBe(true);
    expect(getSearchState(), 'the quick undo cleared the Find session').toBeNull();
    expect(replaceCurrent('X'), 'Replace after the restore finds no stale match to act on').toBe(false);
    expect(view.state.doc.textContent).toContain('Gamma one.');
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });

    // A redo that refuses (typing since the press, inside the chapter it takes out: round 3 refuses only that) has still cleared the
    // Find session: hygiene comes before the re-check.
    expect(find('Gamma').matchCount).toBe(1);
    expect(pressRedo(view, OP_A)).toBe(true);
    typeInto(view, 'Beta one', ' TYPED-QU16');
    expect(redoSectionDeleteEditorFirst(OP_A, 'b', [])).toMatchObject({ ok: false, reason: 'docChanged' });
    expect(getSearchState(), 'the quick redo cleared the Find session before its re-check').toBeNull();
    receiveRedoOutcome(OP_A, 'failed');
    expect(undo(view.state, view.dispatch)).toBe(true);
    await sleep(160);
    takePendingAsReport();

    expect(find('Gamma').matchCount).toBe(1);
    expect(pressRedo(view, OP_A)).toBe(true);
    expect(redoSectionDeleteEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(getSearchState(), 'the quick redo (through its removal) cleared the Find session').toBeNull();
    expect(replaceCurrent('X')).toBe(false);
    swiftFinishesRedo(OP_A, { undoTopOpId: OP_A });
  });

  it('QU17: quickUndoLiveDiffersFromRestored is false right after the restore, stays false for an automatic rewrite, and is true once the user typed', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(pressUndo(view, OP_A)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A).ok).toBe(true);
    expect(quickUndoLiveDiffersFromRestored(OP_A), 'right after the restore the document is the restored one').toBe(
      false
    );
    automaticRewrite(view, 'Gamma', ' (renumbered-qu17)'); // followed by the saved copy, never the user's typing
    expect(quickUndoLiveDiffersFromRestored(OP_A), 'an automatic rewrite is not a difference').toBe(false);
    expect(quickUndoLiveDiffersFromRestored('no-such-op'), 'an op with no entry has nothing to compare').toBe(false);

    typeInto(view, 'Beta one', ' TYPED-QU17'); // typed during the paused window
    expect(quickUndoLiveDiffersFromRestored(OP_A), 'the bridge reports the typing since the restore').toBe(true);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
  });

  it('QU18: the quick undo refuses when the latch is not held for the op, when the entry is mid-op, has no id map, or does not exist', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'a', []).ok).toBe(true);
    expect(deleteSectionEditorFirst(OP_B, 'b', []).ok).toBe(true);
    const doc = view.state.doc;

    // No press at all: the latch is not held.
    expect(undoSectionDeleteEditorFirst(OP_B), 'no press, no latch').toMatchObject({
      ok: false,
      reason: 'notInFlight',
      batch: EMPTY_BATCH,
    });
    expect(view.state.doc.eq(doc)).toBe(true);
    // A press for ANOTHER op holds the latch: still not in flight for this one.
    expect(pressUndo(view, OP_B)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A), 'the latch belongs to another op').toMatchObject({
      ok: false,
      reason: 'notInFlight',
    });
    expect(view.state.doc.eq(doc)).toBe(true);
    receiveUndoOutcome(OP_B, 'failed');

    // An entry that is still mid-op (the op has not finalized).
    beginStructuralOp(OP_C);
    expect(pressUndo(view, OP_C)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_C)).toMatchObject({ ok: false, reason: 'midOp' });
    receiveUndoOutcome(OP_C, 'failed');
    // Finalized, but not made by the editor-first delete: no saved id maps.
    finalizeStructuralOpPostOpDoc(OP_C);
    expect(pressUndo(view, OP_C)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_C)).toMatchObject({ ok: false, reason: 'noIdMap' });
    receiveUndoOutcome(OP_C, 'failed');
    // The latch is held for an op the registry does not know (a barrier cleared it).
    setLatched(true);
    setInFlightOpId('dddddddd-0000-0000-0000-000000000000');
    expect(undoSectionDeleteEditorFirst('dddddddd-0000-0000-0000-000000000000')).toMatchObject({
      ok: false,
      reason: 'noEntry',
    });
    setLatched(false);
    setInFlightOpId(null);
    expect(view.state.doc.eq(doc), 'no refusal touched the document').toBe(true);
    expect(getQuickUndoPausedOpId()).toBeNull();
  });

  it('QU18b: the quick redo refuses when the latch is not held for the op, or when the entry does not exist', async () => {
    const { view } = await makeEditor();
    await load(SPECS);
    expect(deleteSectionEditorFirst(OP_A, 'b', []).ok).toBe(true);
    expect(pressUndo(view, OP_A)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_A).ok).toBe(true);
    swiftFinishesUndo(OP_A, { redoTopOpId: OP_A });
    const doc = view.state.doc;
    const entry = getRegistry().get(OP_A);

    // No redo press: the redo latch is not held.
    expect(redoSectionDeleteEditorFirst(OP_A, 'b', []), 'no press, no latch').toMatchObject({
      ok: false,
      reason: 'notInFlight',
      batch: EMPTY_BATCH,
    });
    expect(view.state.doc.eq(doc), 'a refusal leaves the restored section on screen').toBe(true);
    expect(getRegistry().get(OP_A)).toBe(entry);
    setLatched(true);
    setInFlightOpId('dddddddd-0000-0000-0000-000000000000');
    expect(redoSectionDeleteEditorFirst('dddddddd-0000-0000-0000-000000000000', 'b', [])).toMatchObject({
      ok: false,
      reason: 'noEntry',
    });
    setLatched(false);
    setInFlightOpId(null);
  });
});

// === Cost on a large generated document (reported, not a timing assertion: jsdom is not WKWebView) ===
// Twelve chapters of sixteen sections of five paragraphs, plus a Notes tail: about 1,200 top-level blocks. The figures are logged
// (`[quick-undo-cost]`) so the run record can quote them with the block count beside them.

const SENTENCE =
  'The fieldwork continued through the monsoon season while the archive stayed closed to outside readers. ';
const PARAGRAPH = SENTENCE.repeat(6).trim();

function generateBook(chapters: number, sectionsPerChapter: number, paragraphsPerSection: number): Spec[] {
  const specs: Spec[] = [];
  for (let c = 1; c <= chapters; c++) {
    specs.push(heading(`ch${c}`, 1, `Chapter ${c}`));
    specs.push(para(`ch${c}-intro`, `Chapter ${c}. ${PARAGRAPH}`));
    for (let s = 1; s <= sectionsPerChapter; s++) {
      specs.push(heading(`ch${c}-s${s}`, 2, `Section ${c}.${s}`));
      for (let k = 1; k <= paragraphsPerSection; k++) {
        specs.push(para(`ch${c}-s${s}-p${k}`, `Paragraph ${c}.${s}.${k}. ${PARAGRAPH}`));
      }
    }
  }
  specs.push(heading('notes-h', 2, 'Notes'));
  specs.push(para('notes-p1', 'Note one.'));
  return specs;
}

describe('quick undo on a generated twelve-chapter book', () => {
  it('QU15: undo, resume and the contentChanged serialisation on about 1,200 blocks all succeed, and their cost is logged', async () => {
    const { view, posted } = await makeEditor();
    const specs = generateBook(12, 16, 5);
    await load(specs);
    const blocks = view.state.doc.childCount;
    expect(deleteSectionEditorFirst(OP_A, 'ch6', ['notes-h', 'notes-p1']).ok).toBe(true);
    expect(pressUndo(view, OP_A)).toBe(true);

    const t0 = performance.now();
    const result = undoSectionDeleteEditorFirst(OP_A);
    const undoMs = performance.now() - t0;
    expect(result.ok, `reason: ${result.reason}`).toBe(true);
    typeInto(view, 'Chapter 1.', ' TYPED-BOOK'); // typed while paused, so the resume has an edit to diff
    const t1 = performance.now();
    const resumed = resumeSyncAfterQuickUndo();
    const resumeMs = performance.now() - t1;
    expect(resumed.ok).toBe(true);
    receiveUndoOutcome(OP_A, 'performed');
    const t2 = performance.now();
    const markdown = pushLiveContentToSwift(false) as string; // what the deferred notification does when it runs
    const serialiseMs = performance.now() - t2;
    expect(markdown).toContain('TYPED-BOOK');

    const undoLine = posted
      .filter((p) => p.handler === 'errorHandler')
      .map((p) => (p.body as { message: string }).message)
      .find((m) => m.includes('quick-undo opId') && m.includes('ok=true'));
    console.log(
      `[quick-undo-cost] blocks=${blocks} restored=${result.restoredIds.length} undoCallMs=${undoMs.toFixed(1)} ` +
        `resumeCallMs=${resumeMs.toFixed(1)} serialiseMs=${serialiseMs.toFixed(1)} markdownChars=${markdown.length}\n${undoLine}`
    );
  }, 60_000);
});
