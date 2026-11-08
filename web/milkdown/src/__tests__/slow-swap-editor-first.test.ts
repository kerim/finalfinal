// @vitest-environment jsdom
//
// Phase 4b slice 3, round 3b (t-18b7fa48): `structuralSwapEditorFirst` (api-structural-swap.ts) -- the editor half of the SLOW
// snapshot undo and redo. Today a structural undo that cannot take the quick path flushes, swaps the saved EditorState in
// (`performStructuralSwap`), restores the database, pushes ids and settles (`finishStructuralSwapSettle`), and loses what the user
// typed meanwhile. Here the editor is swapped first, in ONE synchronous turn, with the ids the database is about to hold; the
// pending-edit batch is taken in that same turn and comes back on every path; a document that changed since the press is refused
// (nothing swapped) so typing is never overwritten.
//
// V3-1 a text undo after the slow undo takes back the typing made BEFORE the op (the history chain survives the swap).
// V3-2 the redo bookkeeping (`redoCheckpoint`, `postOpDoc`, `preOpDoc`, the entry's keys) and the routing answers after the new call
//      equal those of today's `performStructuralSwap` + `syncBlockIds` + `finishStructuralSwapSettle`, run on identical documents.
// V3-3 a document that changed since the press gives `ok: false, 'docChanged'`: nothing swapped, the entry stays recorded, the pending
//      batch is returned.
// R2   (binding requirement) the batch and the swap are one turn: typing just before the click is in the returned batch, on the
//      refusal AND on a swap that went ahead because the typing sat in a region the saved-copy comparison ignores.
// Also: `noCheckpoint`, `idAlignment` (before and after the swap), an exception after the swap (all put back, batch returned), the
// redo direction (undo, redo, undo), the redo's own re-check, the reply and the trace line, the payload ids and managed ids, and the
// content notification.
//
// The harness (editor-first-harness.ts) is the real thing: a real Milkdown editor with the block-id, block-sync and history plugins,
// `view.dispatch` wired through the production `runUndoTrackedDispatch`. Swift's side of the conversation is played by the test.

import { undo, undoDepth } from '@milkdown/kit/prose/history';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { setContentWithBlockIds, syncBlockIds } from '../api-content';
import { deleteSectionEditorFirst } from '../api-section-delete';
import { type StructuralSwapPayload, setTestAfterSwapHook, structuralSwapEditorFirst } from '../api-structural-swap';
import { bibliographyEndMarkerPlugin } from '../bibliography-end-marker-plugin';
import { bibliographyPlugin } from '../bibliography-plugin';
import {
  getManagedBlockIds,
  resetBlockIdState,
  setBlockIdZoomMode,
  setManagedBlockIds,
  setTopLevelIdsAt,
} from '../block-id-plugin';
import {
  flushPendingBlockChanges,
  hasPendingChanges,
  hasUnsettledLocalEdit,
  resetBlockSyncState,
  setSyncPaused,
} from '../block-sync-plugin';
import { getContentHasBeenSet, getEditorInstance, getIsSettingContent, setEditorInstance } from '../editor-state';
import {
  finishStructuralSwapSettle,
  getRegistry,
  getTypingCollector,
  performStructuralSwap,
  receiveUndoOutcome,
  resetUndoCoordinatorState,
  setUndoDescriptor,
} from '../undo-coordinator';
import {
  EMPTY_BATCH,
  endOfParagraph,
  heading,
  idsInOrder,
  load,
  makeEditor,
  type Posted,
  para,
  pressRedo,
  pressUndo,
  type Spec,
  sleep,
  swiftFinishesRedo,
  typeInto,
  waitForRAF,
} from './editor-first-harness';
import { takePendingAsReport } from './pending-for-test';

const OP = 'dddddddd-2222-3333-4444-555555555555';

// The document, and what deleting Section A leaves of it. Ids are the spec names.
const DOC = [
  heading('h1', 1, 'Chapter'),
  para('p1', 'Chapter body.'),
  heading('a', 2, 'Section A'),
  para('pa', 'A body.'),
  heading('b', 2, 'Section B'),
  para('pb', 'B body.'),
];
const POST_OP = DOC.filter((s) => !['a', 'pa'].includes(s.name));
const POST_OP_IDS = POST_OP.map((s) => s.name);

// The ids Swift's queued job will write: fresh for every block (the worst case, as for the whole restore), so a test can tell them
// from the ids the editor held before.
const PRE_IDS = DOC.map((s) => `n-${s.name}`); // the pre-op document, swapped in by an undo
const POST_IDS = POST_OP.map((s) => `m-${s.name}`); // the post-op document, swapped in by a redo
const PRE_IDS_AGAIN = DOC.map((s) => `k-${s.name}`);

function blockTypeOf(md: string): string {
  if (md.startsWith('#')) return 'heading';
  if (md.startsWith('<!-- ::break')) return 'section_break';
  return 'paragraph';
}

/** What Swift's `editorPayload(for: planRows)` gives for these blocks (the fields this call reads). */
function swapPayload(specs: Spec[], ids: string[], managedBlockIds: string[] = []): StructuralSwapPayload {
  return {
    blockIds: ids,
    expectedBlocks: specs.map((s) => ({ blockType: blockTypeOf(s.md), nonEmpty: true })),
    managedBlockIds,
  };
}
const undoPayload = () => swapPayload(DOC, PRE_IDS);
const redoPayload = () => swapPayload(POST_OP, POST_IDS);

afterEach(() => {
  setTestAfterSwapHook(null);
});

/** The last `typing-since-press` line the route wrote. */
function typingLine(posted: Posted): string | undefined {
  return posted
    .filter((p) => p.handler === 'errorHandler' && typeof p.body?.message === 'string')
    .map((p) => p.body.message as string)
    .filter((m) => m.startsWith('[STRUCT-TRACE] typing-since-press'))
    .map((m) => m.replace('[STRUCT-TRACE] ', ''))
    .pop();
}

function topLevelTexts(view: EditorView): string[] {
  const texts: string[] = [];
  view.state.doc.forEach((node) => {
    texts.push(node.textContent);
  });
  return texts;
}

/** The swap's trace lines, in order. */
function swapTraces(posted: Posted): string[] {
  return posted
    .filter((p) => p.handler === 'errorHandler' && typeof p.body?.message === 'string')
    .map((p) => p.body.message as string)
    .filter((m) => m.startsWith('[STRUCT-TRACE] swap-editor-first'));
}

/** The editor-first delete of Section A: the op whose slow undo these tests run. */
function deleteSectionA(): void {
  const r = deleteSectionEditorFirst(OP, 'a', []);
  expect(r.ok, `the delete: ${r.reason}`).toBe(true);
}

/** What Swift does after a slow undo: push the descriptor, reply (the reply releases the in-flight latch). */
function swiftRepliesUndo(descriptor: { undoTopOpId?: string; redoTopOpId?: string }): void {
  setUndoDescriptor(descriptor);
  receiveUndoOutcome(OP, 'performed');
}

/** After a swap (or a refusal) block-sync must be running against the document on screen: the next edit is one UPDATE of `id`. */
function expectNextEditIsAnUpdateOf(view: EditorView, startsWith: string, id: string): void {
  typeInto(view, startsWith, ' next');
  flushPendingBlockChanges();
  const diff = takePendingAsReport();
  expect(diff.updates.map((u) => u.id)).toEqual([id]);
  expect(diff.inserts).toEqual([]);
  expect(diff.deletes).toEqual([]);
}

// A document with Notes and a Bibliography. Deleting Section "Title" leaves "Second" and the managed sections. Text typed into a
// bibliography entry is ignored by the saved-copy comparison (derived-equivalence.ts: the bibliography is regenerated), so a press
// stays routable with such an edit pending, and an undo routed that way captures a live document that is NOT byte-equal to the saved
// post-op one (which is what makes a redo re-anchor `postOpDoc` to a different document).
const MANAGED_MD = [
  '# Title',
  'Body one.',
  '# Second',
  'Body two.',
  '## Notes',
  'Note text.',
  '<!-- ::auto-bibliography:: -->',
  '## Bibliography',
  'Reference one.',
  '<!-- ::auto-bibliography-end:: -->',
].join('\n\n');
const MANAGED_DOC_IDS = ['t', 'b1', 'u', 'b2', 'notes', 'np', 'bib', 'bp'];
const MANAGED = ['notes', 'np', 'bib', 'bp'];
const MANAGED_PRE_SPECS: Spec[] = [
  heading('t', 1, 'Title'),
  para('b1', 'Body one.'),
  heading('u', 1, 'Second'),
  para('b2', 'Body two.'),
  heading('notes', 2, 'Notes'),
  para('np', 'Note text.'),
  heading('bib', 2, 'Bibliography'),
  para('bp', 'Reference one.'),
];
const MANAGED_POST_SPECS = MANAGED_PRE_SPECS.slice(2); // what deleting "Title" leaves
const MANAGED_PRE_IDS = MANAGED_PRE_SPECS.map((s) => `n-${s.name}`);
const managedPayload = () =>
  swapPayload(
    MANAGED_PRE_SPECS,
    MANAGED_PRE_IDS,
    MANAGED.map((id) => `n-${id}`)
  );
const managedRedoPayload = () =>
  swapPayload(
    MANAGED_POST_SPECS,
    MANAGED_POST_SPECS.map((s) => `m-${s.name}`),
    MANAGED.map((id) => `m-${id}`)
  );

/** An editor holding the managed document, with "Title" not yet deleted. */
async function makeManagedEditor() {
  const made = await makeEditor([bibliographyPlugin, bibliographyEndMarkerPlugin]);
  setContentWithBlockIds(MANAGED_MD, MANAGED_DOC_IDS, { managedBlockIds: MANAGED });
  await waitForRAF();
  takePendingAsReport();
  return made;
}

/** The press has routed to the delete of "Title" and ' LATE' sits, undetected, in the bibliography entry 'bp'. */
async function managedDocWithLateTyping() {
  const made = await makeManagedEditor();
  expect(deleteSectionEditorFirst(OP, 't', MANAGED).ok).toBe(true);
  expect(pressUndo(made.view, OP)).toBe(true);
  typeInto(made.view, 'Reference one', ' LATE');
  return made;
}

describe('structuralSwapEditorFirst: the slow undo in one turn', () => {
  it('S1: swaps the saved pre-op document in with the payload ids and reports what moved; it is one synchronous turn', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    expect(topLevelTexts(view)).toEqual(['Chapter', 'Chapter body.', 'Section B', 'B body.']);
    const entryBefore = getRegistry().get(OP);
    expect(pressUndo(view, OP), 'Cmd-Z routes to the delete').toBe(true);
    setManagedBlockIds(['stale']);
    let microtaskRan = false;
    queueMicrotask(() => {
      microtaskRan = true;
    });
    const sentBefore = posted.length;

    const r = structuralSwapEditorFirst(OP, 'undo', swapPayload(DOC, PRE_IDS, ['n-pb']));

    expect(r, 'a plain object, never a promise').not.toBeInstanceOf(Promise);
    expect(microtaskRan, 'nothing could run between the batch, the re-check, the swap and the settle').toBe(false);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.swappedTo).toBe('checkpoint');
    expect(topLevelTexts(view), 'the pre-op document is back').toEqual([
      'Chapter',
      'Chapter body.',
      'Section A',
      'A body.',
      'Section B',
      'B body.',
    ]);
    expect(idsInOrder(), 'the blocks hold the payload ids, not the ids they had').toEqual(PRE_IDS);
    expect(Array.from(getManagedBlockIds()), "the payload's managed ids replace the editor's set").toEqual(['n-pb']);
    const painted = Array.from(view.dom.querySelectorAll('[data-block-id]')).map((el) =>
      el.getAttribute('data-block-id')
    );
    expect(painted, 'the DOM paints the payload ids').toEqual(PRE_IDS);
    expect(view.dom.querySelector('[data-managed]')?.getAttribute('data-block-id')).toBe('n-pb');

    // The reply: the whole old document went out, the whole new one came in.
    expect(r.insertedIds).toEqual(PRE_IDS);
    expect(r.insertedLeaderIds).toEqual(['n-h1', 'n-a', 'n-b']);
    expect(r.insertedSectionsSnapshot).toEqual([
      { id: 'n-h1', kind: 'heading', level: 1, title: 'Chapter' },
      { id: 'n-a', kind: 'heading', level: 2, title: 'Section A' },
      { id: 'n-b', kind: 'heading', level: 2, title: 'Section B' },
    ]);
    expect(r.removedIds).toEqual(POST_OP_IDS);
    expect(r.removedLeaderIds).toEqual(['h1', 'b']);
    expect(r.predecessorId).toBeNull();
    expect(r.batch).toEqual(EMPTY_BATCH);

    // It touched the entry only the way the legacy swap does: a redo checkpoint was added.
    const entryAfter = getRegistry().get(OP);
    expect(entryAfter?.redoCheckpoint, 'the redo checkpoint is the live state the swap left').toBeDefined();
    expect(entryAfter?.checkpoint).toBe(entryBefore?.checkpoint);

    // Nothing but debug trace lines reached Swift during the call; the content notification follows later.
    expect(posted.slice(sentBefore).filter((p) => p.handler !== 'errorHandler')).toEqual([]);
    swiftRepliesUndo({ redoTopOpId: OP });
    expectNextEditIsAnUpdateOf(view, 'A body', 'n-pa');
  });

  it('S2: the call never enters the content-set window, and the editor tells Swift the swapped-in text afterwards (contentChanged)', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    expect(pressUndo(view, OP)).toBe(true);
    expect(getContentHasBeenSet(), 'premise: the document was set').toBe(true);
    let settingContentInside: boolean | null = null;
    setTestAfterSwapHook(() => {
      settingContentInside = getIsSettingContent();
    });
    const sentBefore = posted.length;

    const r = structuralSwapEditorFirst(OP, 'undo', undoPayload());

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(settingContentInside, 'no setContent window: this is a live-editor operation').toBe(false);
    expect(getIsSettingContent()).toBe(false);
    expect(posted.slice(sentBefore).filter((p) => p.handler === 'contentChanged')).toEqual([]);
    await sleep(120);
    const pushes = posted.slice(sentBefore).filter((p) => p.handler === 'contentChanged');
    expect(pushes, 'one ordinary contentChanged for the swapped-in text').toHaveLength(1);
    expect(pushes[0].body.content).toContain('Section A');
    expect(pushes[0].body.wasUndo).toBe(false);
    swiftRepliesUndo({ redoTopOpId: OP });
  });

  it('S3: a full BlockFetchResult can be sent as it is: the fields this call does not read are ignored', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    expect(pressUndo(view, OP)).toBe(true);
    const wide = {
      ...undoPayload(),
      markdown: 'ignored',
      imageMeta: [{ id: 'x', caption: 'c', width: 10 }],
      bibBoundaryIndex: null,
      bibBoundaryEndIndex: null,
    };

    const r = structuralSwapEditorFirst(OP, 'undo', wide);

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(PRE_IDS);
    swiftRepliesUndo({ redoTopOpId: OP });
  });

  it('S4: typing right after the click is held until the reply, then goes out as an update of the payload id, never an insert, never lost', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    expect(pressUndo(view, OP)).toBe(true);
    expect(structuralSwapEditorFirst(OP, 'undo', undoPayload()).ok).toBe(true);

    // Typed in the very next task: before any animation frame, before Swift's reply. While the press is latched the polls get nothing
    // (phase 4c job 2: the hold ends with the latch), so the poll that takes it comes after the reply.
    typeInto(view, 'B body', ' next');
    flushPendingBlockChanges();
    expect(takePendingAsReport(), 'held while the press is latched').toEqual(EMPTY_BATCH);
    await waitForRAF();
    swiftRepliesUndo({ redoTopOpId: OP });
    const diff = takePendingAsReport();
    expect(diff.updates.map((u) => u.id)).toEqual(['n-pb']);
    expect(diff.inserts).toEqual([]);
    expect(diff.deletes).toEqual([]);
  });
});

describe('V3-1: the text history survives the slow undo', () => {
  it('V3-1: a text undo after the slow undo takes back the typing made BEFORE the op', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    typeInto(view, 'B body', ' EARLY'); // a history step, made before the op
    deleteSectionA();
    expect(view.state.doc.textContent).toContain('EARLY');
    expect(pressUndo(view, OP)).toBe(true);

    const r = structuralSwapEditorFirst(OP, 'undo', undoPayload());

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    swiftRepliesUndo({ redoTopOpId: OP });
    expect(view.state.doc.textContent, 'premise: the section is back').toContain('Section A');
    expect(view.state.doc.textContent, 'premise: and so is the early typing').toContain('EARLY');
    expect(undoDepth(view.state), 'the swapped-in state brought its own text history').toBeGreaterThan(0);

    expect(undo(view.state, view.dispatch)).toBe(true);

    expect(view.state.doc.textContent, 'the text undo took back the typing made before the op').not.toContain('EARLY');
    expect(view.state.doc.textContent, 'and left the restored section alone').toContain('Section A');
  });
});

/** The legacy sequence Swift runs today around the same swap: the swap, the id push from the database (`syncBlockIds`), the settle. */
function legacySwap(direction: 'undo' | 'redo', payload: StructuralSwapPayload): void {
  expect(performStructuralSwap(OP, direction)).toBe(true);
  syncBlockIds(payload.blockIds, false, payload.expectedBlocks);
  expect(finishStructuralSwapSettle()).toBe(true);
}

/** Everything about the editor and the entry that a later Cmd-Z / Cmd-Shift-Z depends on, reduced to values comparable across editors. */
function observeAfterSwap(
  view: EditorView,
  before: { postOp: unknown; preOp: unknown; checkpoint: unknown; liveDoc: unknown }
) {
  // `before.liveDoc` is the live document at the moment the swap was asked for: the document a redo checkpoint must have captured.
  const entry = getRegistry().get(OP);
  return {
    texts: topLevelTexts(view),
    ids: idsInOrder(),
    redoCheckpointDocEqualsOldLiveDoc: entry?.redoCheckpoint?.doc.eq(before.liveDoc as never) ?? null,
    hasRedoCheckpoint: entry?.redoCheckpoint !== undefined,
    postOpDocIsOldPostOp: entry?.postOpDoc === before.postOp,
    postOpDocEqualsLiveDoc: entry?.postOpDoc.eq(view.state.doc),
    preOpDocIsOldPreOp: entry?.preOpDoc === before.preOp,
    preOpDocEqualsLiveDoc: entry?.preOpDoc.eq(view.state.doc),
    checkpointIsOldCheckpoint: entry?.checkpoint === before.checkpoint,
    midOp: entry?.midOp,
    entryKeys: Object.keys(entry ?? {}).sort(),
    registryKeys: Array.from(getRegistry().keys()),
    pendingChanges: hasPendingChanges(),
    unsettledEdit: hasUnsettledLocalEdit(),
    textUndoDepth: undoDepth(view.state),
  };
}

/** The routing answer a press gets right now, with the descriptor Swift would have pushed; the latch it sets is released again. */
function routingAnswer(view: EditorView, direction: 'undo' | 'redo'): 'structural' | 'fallthrough' {
  const routed = direction === 'undo' ? pressUndo(view, OP) : pressRedo(view, OP);
  if (!routed) return 'fallthrough';
  receiveUndoOutcome(OP, 'cancelled');
  return 'structural';
}

async function discardEditor(): Promise<void> {
  await sleep(70); // a scheduled contentChanged must fire into THIS run's bridge
  await getEditorInstance()?.destroy();
  setEditorInstance(null);
  resetBlockIdState();
  resetBlockSyncState();
  setBlockIdZoomMode(false);
  setSyncPaused(false);
  resetUndoCoordinatorState();
  delete (window as any).webkit;
}

/** One complete scenario on a fresh editor, driven either by today's legacy sequence or by the new call; returns what it observed. */
async function runScenario(flow: 'legacy' | 'new') {
  const swap = (direction: 'undo' | 'redo', payload: StructuralSwapPayload) => {
    if (flow === 'legacy') legacySwap(direction, payload);
    else {
      const r = structuralSwapEditorFirst(OP, direction, payload);
      expect(r.ok, `${direction}: ${r.reason}`).toBe(true);
    }
  };
  const { view } = await makeManagedEditor();
  typeInto(view, 'Body two', ' EARLY'); // a history step, made before the op
  expect(deleteSectionEditorFirst(OP, 't', MANAGED).ok).toBe(true);
  const registered = getRegistry().get(OP);
  if (!registered) throw new Error('the delete left no registry entry');
  const old = { postOp: registered.postOpDoc, preOp: registered.preOpDoc, checkpoint: registered.checkpoint };
  // An edit the saved-copy comparison ignores (the bibliography is regenerated): the live document is now NOT byte-equal to the saved
  // post-op one, and the press is routed by the fallback comparison.
  typeInto(view, 'Reference one', ' LATE');
  const liveBeforeUndo = view.state.doc;
  expect(old.postOp.eq(liveBeforeUndo), 'premise: the live document differs from the saved post-op one').toBe(false);

  expect(pressUndo(view, OP), 'Cmd-Z routes to the delete').toBe(true);
  swap('undo', managedPayload());
  swiftRepliesUndo({ redoTopOpId: OP });
  const afterUndo = observeAfterSwap(view, { ...old, liveDoc: liveBeforeUndo });
  const afterUndoRedoRoute = routingAnswer(view, 'redo');
  // Typing on top of the restored document: a redo press must NOT route structurally; the text undo brings the routing back.
  typeInto(view, 'Body two', ' LATER');
  const afterUndoTyped = routingAnswer(view, 'redo');
  undo(view.state, view.dispatch);
  const afterUndoTypedUndone = routingAnswer(view, 'redo');

  const liveBeforeRedo = view.state.doc;
  expect(pressRedo(view, OP), 'Cmd-Shift-Z routes to the undone delete').toBe(true);
  swap('redo', managedRedoPayload());
  swiftFinishesRedo(OP, { undoTopOpId: OP });
  const afterRedo = observeAfterSwap(view, { ...old, liveDoc: liveBeforeRedo });
  const afterRedoUndoRoute = routingAnswer(view, 'undo');
  return { afterUndo, afterUndoRedoRoute, afterUndoTyped, afterUndoTypedUndone, afterRedo, afterRedoUndoRoute };
}

describe("V3-2: the bookkeeping equals today's performStructuralSwap + finishStructuralSwapSettle", () => {
  it('V3-2: undo then redo on identical documents: the redo checkpoint, postOpDoc, preOpDoc, entry keys and routing answers are the same', async () => {
    const legacy = await runScenario('legacy');
    await discardEditor();
    const fresh = await runScenario('new');

    // The comparison is not vacuous: the legacy run shows what the bookkeeping is.
    expect(legacy.afterUndo.hasRedoCheckpoint).toBe(true);
    expect(legacy.afterUndo.redoCheckpointDocEqualsOldLiveDoc, 'the undo captured the live post-op document').toBe(
      true
    );
    expect(legacy.afterUndo.preOpDocEqualsLiveDoc, 'the swapped-in document is the saved pre-op one').toBe(true);
    expect(legacy.afterUndoRedoRoute).toBe('structural');
    expect(legacy.afterUndoTyped).toBe('fallthrough');
    expect(legacy.afterUndoTypedUndone).toBe('structural');
    expect(
      legacy.afterRedo.postOpDocEqualsLiveDoc,
      'a redo re-anchors the saved post-op document to the live one'
    ).toBe(true);
    expect(legacy.afterRedo.postOpDocIsOldPostOp).toBe(false);
    expect(legacy.afterRedoUndoRoute).toBe('structural');

    expect(fresh.afterUndo, 'after the undo').toEqual(legacy.afterUndo);
    expect(fresh.afterUndoRedoRoute).toBe(legacy.afterUndoRedoRoute);
    expect(fresh.afterUndoTyped, 'typing on top of the restored document').toBe(legacy.afterUndoTyped);
    expect(fresh.afterUndoTypedUndone).toBe(legacy.afterUndoTypedUndone);
    expect(fresh.afterRedo, 'after the redo').toEqual(legacy.afterRedo);
    expect(fresh.afterRedoUndoRoute).toBe(legacy.afterRedoUndoRoute);
  });
});

describe('V3-3 and R2: typing since the press is put back; a document that changed otherwise is refused, and the batch is taken in the same turn', () => {
  it('V3-3: typing between the press and the click is put back on top of the swapped-in document: ok, typingReplayed, no batch N, the typing sent once by the replay', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    expect(pressUndo(view, OP)).toBe(true);
    typeInto(view, 'B body', ' JUSTTYPED'); // the 100 ms detection has not run when the click arrives
    expect(getTypingCollector().stepsSince(1).length, 'premise: the typing was recorded').toBeGreaterThanOrEqual(1);

    // The snapshot rows of a delete carry the ids the blocks had before it (the editor's own), so the surviving blocks match by id.
    const originalIds = DOC.map((spec) => spec.name);
    const r = structuralSwapEditorFirst(OP, 'undo', swapPayload(DOC, originalIds));

    expect(typingLine(posted)).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=rebased$/);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.typingReplayed).toBe(true);
    expect(r.batch, 'the replay is the only carrier of the wait typing').toEqual(EMPTY_BATCH);
    expect(topLevelTexts(view)).toEqual([
      'Chapter',
      'Chapter body.',
      'Section A',
      'A body.',
      'Section B',
      'B body. JUSTTYPED',
    ]);
    expect(idsInOrder(), 'the payload ids are installed').toEqual(originalIds);
    expect(getRegistry().get(OP)?.redoCheckpoint, 'the entry was swapped: it has its redo checkpoint').toBeDefined();
    swiftRepliesUndo({ redoTopOpId: OP });
    // The replay is new typing for block-sync: one update of the payload id, once.
    flushPendingBlockChanges();
    const batch = takePendingAsReport();
    expect(batch.updates.map((u) => u.id)).toEqual(['pb']);
    expect(batch.updates[0].textContent).toBe('B body. JUSTTYPED');
    expect(takePendingAsReport(), 'not queued a second time').toEqual(EMPTY_BATCH);
    expectNextEditIsAnUpdateOf(view, 'Chapter body', 'p1');
  });

  it('R2a: after a refusal for a change that is not typing, a text undo takes it back and the very next press swaps (it never refuses twice on a quiet document)', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    expect(pressUndo(view, OP)).toBe(true);
    // Typing, then an automatic correction (undoable like typing, but not the user's typing) lands in the wait: the order cannot be unpicked.
    typeInto(view, 'B body', ' JUSTTYPED');
    view.dispatch(view.state.tr.insertText(' CORR', endOfParagraph(view, 'B body')).setMeta('derivedCorrection', true));
    expect(getTypingCollector().stepsSince(1).length, 'premise: the changes were recorded').toBeGreaterThanOrEqual(2);
    const refused = structuralSwapEditorFirst(OP, 'undo', undoPayload());
    expect(typingLine(posted)).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=changed$/);
    expect(refused.reason).toBe('docChanged');
    receiveUndoOutcome(OP, 'failed'); // Swift: refuse with the notice, release the latch; the entry stays where it was

    for (let i = 0; i < 4 && /JUSTTYPED|CORR/.test(view.state.doc.textContent); i++) undo(view.state, view.dispatch);
    expect(view.state.doc.textContent, 'Cmd-Z: the text undo takes the changes back').not.toMatch(/JUSTTYPED|CORR/);
    expect(pressUndo(view, OP), 'the next Cmd-Z routes to the delete again').toBe(true);
    const r = structuralSwapEditorFirst(OP, 'undo', undoPayload());

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(topLevelTexts(view)).toContain('Section A');
    swiftRepliesUndo({ redoTopOpId: OP });
  });

  it('V3-3b: a change that is not typing since the press: ok:false docChanged, nothing swapped, the entry stays recorded, the batch carries the pending edit', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    expect(pressUndo(view, OP)).toBe(true);
    // Typing, then an automatic correction, lands in the wait (the 100 ms detection has not run when the click arrives).
    typeInto(view, 'B body', ' JUSTTYPED');
    view.dispatch(view.state.tr.insertText(' CORR', endOfParagraph(view, 'B body')).setMeta('derivedCorrection', true));
    expect(getTypingCollector().stepsSince(1).length, 'premise: the changes were recorded').toBeGreaterThanOrEqual(2);
    const docBefore = view.state.doc;
    const entryBefore = getRegistry().get(OP);
    setManagedBlockIds(['keep']);

    const r = structuralSwapEditorFirst(OP, 'undo', undoPayload());

    expect(view.state.doc.eq(docBefore), 'swapped although the document had changed').toBe(true);
    expect(r.ok).toBe(false);
    expect(r.reason).toBe('docChanged');
    expect(idsInOrder(), 'the ids are the ones the editor had').toEqual(POST_OP_IDS);
    expect(Array.from(getManagedBlockIds())).toEqual(['keep']);
    expect(getRegistry().get(OP), 'the entry stays recorded, untouched (no redo checkpoint added)').toBe(entryBefore);
    expect(
      r.batch.updates.map((u) => u.id),
      'the pending edit comes back as batch N'
    ).toEqual(['pb']);
    expect(r.batch.updates[0].textContent).toBe('B body. JUSTTYPED CORR');
    expect(r.insertedIds).toEqual([]);
    expect(r.removedIds).toEqual([]);
    expect(typingLine(posted)).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=changed$/);
    expect(swapTraces(posted).pop()).toBe(
      '[STRUCT-TRACE] swap-editor-first direction=undo opId=dddddddd ok=false reason=docChanged'
    );
    // The edit is in the batch and block-sync is running: it is not reported a second time, and the next edit is one update.
    await sleep(160);
    expect(takePendingAsReport(), 'the consumed edit is not queued again').toEqual(EMPTY_BATCH);
    receiveUndoOutcome(OP, 'failed');
    expectNextEditIsAnUpdateOf(view, 'Chapter body', 'p1');
  });
});

// Typing into a bibliography entry is ignored by the saved-copy comparison, so the press stays routable with edits pending: the only
// way to have both a swap that goes ahead and a non-empty batch.
describe('R2b: typing just before the click, in a region the saved-copy comparison ignores, is put back and sent once', () => {
  it('R2b: the bibliography entry typed just before the click is put back on top of the swapped-in document and sent once, by the replay', async () => {
    const { view, posted } = await managedDocWithLateTyping();
    expect(getTypingCollector().stepsSince(1).length, 'premise: the typing was recorded').toBeGreaterThanOrEqual(1);

    // The snapshot rows of a delete carry the ids the blocks had before it (the editor's own), so the blocks match by id.
    const r = structuralSwapEditorFirst(OP, 'undo', swapPayload(MANAGED_PRE_SPECS, MANAGED_DOC_IDS, MANAGED));

    expect(typingLine(posted)).toMatch(/^typing-since-press press=1 steps=[1-9]\d* decision=rebased$/);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.typingReplayed).toBe(true);
    expect(r.batch, 'the replay is the only carrier: no batch N').toEqual(EMPTY_BATCH);
    expect(topLevelTexts(view)).toContain('Title');
    expect(topLevelTexts(view)).toContain('Reference one. LATE');
    expect(idsInOrder()).toEqual(MANAGED_DOC_IDS);
    swiftRepliesUndo({ redoTopOpId: OP });
    flushPendingBlockChanges();
    const batch = takePendingAsReport();
    expect(batch.updates.map((u) => u.id)).toEqual(['bp']);
    expect(batch.updates[0].textContent).toBe('Reference one. LATE');
    expect(takePendingAsReport(), 'the replayed edit is not queued a second time').toEqual(EMPTY_BATCH);
  });

  const failures: Array<{
    name: string;
    hook: (() => void) | null;
    payload: () => StructuralSwapPayload;
    reason: (r: string) => boolean;
    trace: RegExp;
  }> = [
    {
      name: 'a payload with the wrong count (refused before the swap)',
      hook: null,
      payload: () => ({ ...managedPayload(), blockIds: managedPayload().blockIds.slice(0, 7) }),
      reason: (r) => r === 'idAlignment',
      trace: / ok=false reason=idAlignment detail=count: nodes=8 ids=7$/,
    },
    {
      name: 'an id the post-swap check does not find (put back after the swap)',
      hook: () => setTopLevelIdsAt([0], ['tampered']),
      payload: managedPayload,
      reason: (r) => r === 'idAlignment',
      trace: / ok=false reason=idAlignment detail=id at block 0 is not the expected one$/,
    },
    {
      name: 'an exception after the swap (put back)',
      hook: () => {
        throw new Error('injected failure after the swap');
      },
      payload: managedPayload,
      // F13 (round 5): the press carries the user's typing (the late bibliography edit), so the page refuses with the notice
      // (`docChanged`) instead of `exception: ...`, which would make Swift run the old restore body and drop the typing. The exception
      // text is in the trace line only.
      reason: (r) => r === 'docChanged',
      trace: / ok=false reason=docChanged detail=exception: injected failure after the swap$/,
    },
  ];

  it.each(
    failures
  )('R2c: $name: the document, ids, managed set and entry are as they were, block-sync runs, and the reply still carries the batch', async ({
    hook,
    payload,
    reason,
    trace,
  }) => {
    const { view, posted } = await managedDocWithLateTyping();
    const docBefore = view.state.doc;
    const idsBefore = idsInOrder();
    const managedBefore = Array.from(getManagedBlockIds());
    const entryBefore = getRegistry().get(OP);
    setTestAfterSwapHook(hook);

    const r = structuralSwapEditorFirst(OP, 'undo', payload());

    expect(r.ok).toBe(false);
    expect(reason(r.reason ?? ''), `reason was ${r.reason}`).toBe(true);
    expect(
      r.batch.updates.map((u) => u.id),
      'typing just before the click was lost'
    ).toEqual(['bp']);
    expect(view.state.doc.eq(docBefore), 'the document is as it was').toBe(true);
    expect(idsInOrder(), 'and so are the block ids').toEqual(idsBefore);
    expect(Array.from(getManagedBlockIds()), 'and the managed set').toEqual(managedBefore);
    expect(getRegistry().get(OP), 'and the entry: no redo checkpoint is left behind').toBe(entryBefore);
    expect(r.insertedIds).toEqual([]);
    expect(swapTraces(posted).pop()).toMatch(trace);
    setTestAfterSwapHook(null);
    await sleep(160);
    expect(takePendingAsReport(), 'the consumed edit is not queued a second time').toEqual(EMPTY_BATCH);
    receiveUndoOutcome(OP, 'failed');
    expectNextEditIsAnUpdateOf(view, 'Body two', 'b2'); // block-sync is running against the document on screen
  });
});

describe('noCheckpoint and idAlignment before the swap: nothing is touched', () => {
  it('N1: no registry entry for the op (a zoom or mode switch cleared it): noCheckpoint, nothing swapped, the batch returned', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    typeInto(view, 'B body', ' PENDING');
    const docBefore = view.state.doc;
    const ids = idsInOrder();

    const r = structuralSwapEditorFirst(OP, 'undo', undoPayload());

    expect(r.ok).toBe(false);
    expect(r.reason).toBe('noCheckpoint');
    expect(r.batch.updates.map((u) => u.id)).toEqual(['pb']);
    expect(view.state.doc.eq(docBefore)).toBe(true);
    expect(idsInOrder()).toEqual(ids);
    expect(getRegistry().has(OP)).toBe(false);
    expect(swapTraces(posted).pop()).toBe(
      '[STRUCT-TRACE] swap-editor-first direction=undo opId=dddddddd ok=false reason=noCheckpoint detail=no registry entry'
    );
    await sleep(160);
    expect(takePendingAsReport()).toEqual(EMPTY_BATCH);
    expectNextEditIsAnUpdateOf(view, 'A body', 'pa');
  });

  it('N2: a redo for an entry that was never undone has no redo checkpoint: noCheckpoint, the entry is untouched', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    const entryBefore = getRegistry().get(OP);
    const docBefore = view.state.doc;

    const r = structuralSwapEditorFirst(OP, 'redo', redoPayload());

    expect(r.reason).toBe('noCheckpoint');
    expect(getRegistry().get(OP)).toBe(entryBefore);
    expect(view.state.doc.eq(docBefore)).toBe(true);
    expect(idsInOrder()).toEqual(POST_OP_IDS);
  });

  it('A1: a payload that says a block is something else than the checkpoint holds is refused before the swap', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    expect(pressUndo(view, OP)).toBe(true);
    const docBefore = view.state.doc;
    const entryBefore = getRegistry().get(OP);
    const wrongType = undoPayload();
    wrongType.expectedBlocks[1] = { blockType: 'heading', nonEmpty: true }; // the checkpoint's second block is a paragraph

    const r = structuralSwapEditorFirst(OP, 'undo', wrongType);

    expect(r.ok).toBe(false);
    expect(r.reason).toBe('idAlignment');
    expect(view.state.doc.eq(docBefore)).toBe(true);
    expect(idsInOrder()).toEqual(POST_OP_IDS);
    expect(getRegistry().get(OP), 'no redo checkpoint was captured').toBe(entryBefore);
    expect(swapTraces(posted).pop()).toMatch(/ ok=false reason=idAlignment detail=mismatch at index 1: type: /);
    receiveUndoOutcome(OP, 'failed');
  });
});

describe('the redo direction', () => {
  it('RD: undo, redo, undo through the call: the redo swaps the stored redo checkpoint in with the redo payload ids, and the entry stays usable', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    const postOpDoc = view.state.doc;
    expect(pressUndo(view, OP)).toBe(true);
    expect(structuralSwapEditorFirst(OP, 'undo', undoPayload()).ok).toBe(true);
    swiftRepliesUndo({ redoTopOpId: OP });
    const entryAfterUndo = getRegistry().get(OP);

    expect(pressRedo(view, OP), 'Cmd-Shift-Z routes to the undone delete').toBe(true);
    const redo = structuralSwapEditorFirst(OP, 'redo', redoPayload());

    expect(redo.ok, `reason: ${redo.reason}`).toBe(true);
    expect(redo.swappedTo).toBe('redo');
    expect(view.state.doc.eq(postOpDoc), 'the post-op document is back').toBe(true);
    expect(idsInOrder(), 'with the redo payload ids').toEqual(POST_IDS);
    expect(redo.insertedIds).toEqual(POST_IDS);
    expect(redo.insertedLeaderIds).toEqual(['m-h1', 'm-b']);
    expect(redo.removedIds).toEqual(PRE_IDS);
    expect(redo.removedLeaderIds).toEqual(['n-h1', 'n-a', 'n-b']);
    const entryAfterRedo = getRegistry().get(OP);
    expect(entryAfterRedo?.redoCheckpoint, 'the redo checkpoint is kept').toBe(entryAfterUndo?.redoCheckpoint);
    expect(entryAfterRedo?.postOpDoc.eq(view.state.doc), 'the saved post-op document is re-anchored').toBe(true);
    swiftFinishesRedo(OP, { undoTopOpId: OP });
    expectNextEditIsAnUpdateOf(view, 'B body', 'm-pb');

    // And the entry still undoes: the typing above is taken back by the text undo first, then the next press swaps.
    undo(view.state, view.dispatch);
    expect(pressUndo(view, OP)).toBe(true);
    const again = structuralSwapEditorFirst(OP, 'undo', swapPayload(DOC, PRE_IDS_AGAIN));
    expect(again.ok, `reason: ${again.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(PRE_IDS_AGAIN);
    swiftRepliesUndo({ redoTopOpId: OP });
  });

  it('RD-gate: a redo with typing since its press puts the typing back on top of the redone document: ok, typingReplayed, no batch N', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    expect(pressUndo(view, OP)).toBe(true);
    expect(structuralSwapEditorFirst(OP, 'undo', undoPayload()).ok).toBe(true);
    swiftRepliesUndo({ redoTopOpId: OP });
    expect(pressRedo(view, OP)).toBe(true);
    typeInto(view, 'B body', ' AFTERPRESS');
    expect(getTypingCollector().stepsSince(2).length, 'premise: the typing was recorded').toBeGreaterThanOrEqual(1);

    // The snapshot rows of the redo carry the ids the blocks hold now (the swap-in of the undo gave them the n- ids).
    const redoIds = POST_OP.map((spec) => `n-${spec.name}`);
    const r = structuralSwapEditorFirst(OP, 'redo', swapPayload(POST_OP, redoIds));

    expect(typingLine(posted)).toMatch(/^typing-since-press press=2 steps=[1-9]\d* decision=rebased$/);
    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.typingReplayed).toBe(true);
    expect(r.batch).toEqual(EMPTY_BATCH);
    expect(topLevelTexts(view)).toEqual(['Chapter', 'Chapter body.', 'Section B', 'B body. AFTERPRESS']);
    expect(idsInOrder()).toEqual(redoIds);
    swiftFinishesRedo(OP, { undoTopOpId: OP });
    flushPendingBlockChanges();
    expect(takePendingAsReport().updates.map((u) => u.id)).toEqual(['n-pb']);
  });

  it('RD-gate-b: a redo whose re-check finds a change that is not typing swaps nothing, keeps the entry and returns the batch', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    expect(pressUndo(view, OP)).toBe(true);
    expect(structuralSwapEditorFirst(OP, 'undo', undoPayload()).ok).toBe(true);
    swiftRepliesUndo({ redoTopOpId: OP });
    expect(pressRedo(view, OP)).toBe(true);
    typeInto(view, 'B body', ' AFTERPRESS');
    view.dispatch(view.state.tr.insertText(' CORR', endOfParagraph(view, 'B body')).setMeta('derivedCorrection', true));
    expect(getTypingCollector().stepsSince(2).length, 'premise: the changes were recorded').toBeGreaterThanOrEqual(2);
    const docBefore = view.state.doc;
    const entryBefore = getRegistry().get(OP);

    const r = structuralSwapEditorFirst(OP, 'redo', redoPayload());

    expect(r.ok).toBe(false);
    expect(r.reason).toBe('docChanged');
    expect(r.batch.updates.map((u) => u.id)).toEqual(['n-pb']);
    expect(view.state.doc.eq(docBefore)).toBe(true);
    expect(idsInOrder()).toEqual(PRE_IDS);
    expect(getRegistry().get(OP)).toBe(entryBefore);
    swiftFinishesRedo(OP, { redoTopOpId: OP });
  });
});

describe('the trace line', () => {
  it('T1: success names the direction, the op and the counts, with the timing laps; the redo has its own direction', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    deleteSectionA();
    expect(pressUndo(view, OP)).toBe(true);
    expect(structuralSwapEditorFirst(OP, 'undo', undoPayload()).ok).toBe(true);
    swiftRepliesUndo({ redoTopOpId: OP });
    expect(pressRedo(view, OP)).toBe(true);
    expect(structuralSwapEditorFirst(OP, 'redo', redoPayload()).ok).toBe(true);
    swiftFinishesRedo(OP, { undoTopOpId: OP });

    const lines = swapTraces(posted);
    expect(lines[0]).toMatch(
      /^\[STRUCT-TRACE\] swap-editor-first direction=undo opId=dddddddd ok=true blocks=6 removed=4 insertedLeaders=3 removedLeaders=2 batchUpdates=0 batchInserts=0 batchDeletes=0 jsMs total=\d+ flush=\d+ changes=\d+ recheck=\d+ align=\d+ swap=\d+ ids=\d+ collect=\d+ settle=\d+$/
    );
    expect(lines[1]).toMatch(
      /^\[STRUCT-TRACE\] swap-editor-first direction=redo opId=dddddddd ok=true blocks=4 removed=6 insertedLeaders=2 removedLeaders=3 /
    );
  });
});
