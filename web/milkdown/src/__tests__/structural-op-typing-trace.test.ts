// @vitest-environment jsdom
//
// Phase 4b TRACE (diagnostic only): what happens to text a user types while a structural operation
// (section delete / duplicate / version restore, or the undo of one) is running?
//
// Hypothesis under test (see the Phase 4b brief): during a section delete the editor stays typeable;
// the operation flushes the editor's text to the database, switches off Swift's 2-second poll (as it did then), mutates
// the database, and pushes the database copy of the whole document back with `setContentWithBlockIds`
// (`buildBlockLevelReplace`). Text typed after the flush is therefore not in the database copy, is
// overwritten on screen at the push, and is never written because nothing drains the pending queue
// afterwards. On the undo path, `performStructuralSwap` swaps in a saved editor state and
// `finishStructuralSwapSettle` calls `resetAndSnapshot`, which makes whatever is on screen the new
// baseline and drops the pending queue: text typed between the swap and the settle would stay on
// screen but never be saved.
//
// Every test here runs the REAL modules (real Milkdown editor with the block-id, block-sync and history
// plugins; real `beginStructuralOp`, `finalizeStructuralOpPostOpDoc`, `performStructuralSwap`,
// `finishStructuralSwapSettle`, `setContentWithBlockIds`, `syncBlockIds`; the registry-advance and
// history-edited hooks wired exactly like main.ts's `view.dispatch` override). Typing is a real
// history-adding ProseMirror transaction. Block-sync's own 100ms debounce is let to elapse with fake
// timers so a typed edit sits in the pending queue exactly as in the app.
//
// Each scenario prints one `[TRACE] <name> key=value ...` line with the measured facts and asserts the
// behaviour OBSERVED TODAY. The comment above each test says which result would mean the Phase 4b fix
// has landed -- when a fix lands, the assertion below is expected to flip and the test is to be updated
// deliberately, not worked around. These are characterization tests, not specifications.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { setContentWithBlockIds, syncBlockIds } from '../api-content';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import {
  blockSyncPlugin,
  blockSyncPluginKey,
  getBlockChanges,
  hasPendingChanges,
  resetBlockSyncState,
  setSyncPaused,
} from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import {
  beginStructuralOp,
  finalizeStructuralOpPostOpDoc,
  finishStructuralSwapSettle,
  getRegistry,
  handleUnifiedUndoKeydown,
  performStructuralSwap,
  resetUndoCoordinatorState,
  runUndoTrackedDispatch,
  setRegistryEntry,
  setUndoDescriptor,
} from '../undo-coordinator';

// === The document ===
// Three sections, eleven top-level blocks, each with a block id as Swift's initial load assigns them.
// Paragraph numbering is document-wide: "Paragraph five" is the fifth paragraph (the last of Beta).

interface TestBlock {
  id: string;
  md: string;
}

const INITIAL_BLOCKS: TestBlock[] = [
  { id: 'h-alpha', md: '# Alpha' },
  { id: 'p1', md: 'Paragraph one original text.' },
  { id: 'p2', md: 'Paragraph two original text.' },
  { id: 'h-beta', md: '# Beta' },
  { id: 'p3', md: 'Paragraph three original text.' },
  { id: 'p4', md: 'Paragraph four original text.' },
  { id: 'p5', md: 'Paragraph five original text.' },
  { id: 'h-gamma', md: '# Gamma' },
  { id: 'p6', md: 'Paragraph six original text.' },
  { id: 'p7', md: 'Paragraph seven original text.' },
  { id: 'p8', md: 'Paragraph eight original text.' },
];

// The operation deletes the Alpha section (h-alpha, p1, p2). The database copy of the post-operation
// document therefore has eight blocks, and paragraph five is exactly as it was when the editor's text
// was flushed: WITHOUT any word typed after that flush.
const POST_OP_BLOCKS = INITIAL_BLOCKS.filter((b) => !['h-alpha', 'p1', 'p2'].includes(b.id));

// Undo restores the whole project from a snapshot: every block comes back with a fresh id.
const RESTORED_IDS = INITIAL_BLOCKS.map((b) => `r-${b.id}`);

const markdownOf = (blocks: TestBlock[]) => blocks.map((b) => b.md).join('\n\n');
const idsOf = (blocks: TestBlock[]) => blocks.map((b) => b.id);

const OP_ID = '11111111-2222-3333-4444-555555555555';
const TYPED_FORWARD = ' TYPEDWORD';
const TYPED_SWAP = ' TYPED2';
const TYPED_AFTER_SETTLE = ' TYPED3';
const TYPED_CONTROL = ' TYPEDWORD';

// === Harness ===

interface Harness {
  editor: Editor;
  view: EditorView;
  /** Every message posted on the errorHandler channel (what Swift logs as `JS DEBUG: ...`). */
  debugLines: string[];
}

let current: Editor | null = null;

afterEach(async () => {
  // Let every pending animation frame (including the nested ones paint signals schedule) run BEFORE
  // going back to real timers: jsdom's requestAnimationFrame keeps its own interval handle, and dropping
  // a pending fake one would leave that handle stale, so no later test's frame would ever fire (block-sync
  // would stay paused and its debounce timer would never be cleared).
  if (vi.isFakeTimers()) await vi.advanceTimersByTimeAsync(500);
  vi.useRealTimers();
  if (current) {
    await current.destroy();
    current = null;
  }
  setEditorInstance(null);
  resetBlockIdState();
  resetBlockSyncState();
  setSyncPaused(false);
  resetUndoCoordinatorState();
  delete (window as any).webkit;
});

/** Builds the real editor and loads the eleven-block document the way Swift's initial load does
 * (`setContentWithBlockIds` with real block ids), then lets the paused window close so block-sync is
 * live. Fake timers are switched on after the editor exists (same order as undo-coordinator.test.ts). */
async function makeHarness(): Promise<Harness> {
  const debugLines: string[] = [];
  (window as any).webkit = {
    messageHandlers: { errorHandler: { postMessage: (m: { message: string }) => debugLines.push(m.message) } },
  };

  const div = document.createElement('div');
  document.body.appendChild(div);
  const editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, markdownOf(INITIAL_BLOCKS));
    })
    .use(blockIdPlugin)
    .use(commonmark)
    .use(gfm)
    .use(highlightPlugin)
    .use(historyPlugin)
    .use(blockSyncPlugin)
    .create();
  current = editor;
  setEditorInstance(editor);

  const view = editor.ctx.get(editorViewCtx);
  // main.ts's `view.dispatch` override, through the same production function: the hooks that absorb
  // automatic rewrites into the registry and count user transactions run on EVERY transaction.
  const originalDispatch = view.dispatch.bind(view);
  view.dispatch = (tr) => runUndoTrackedDispatch(view, tr, originalDispatch);

  vi.useFakeTimers();
  setContentWithBlockIds(markdownOf(INITIAL_BLOCKS), idsOf(INITIAL_BLOCKS));
  await vi.advanceTimersByTimeAsync(100); // the deferred snapshot + unpause (requestAnimationFrame)
  return { editor, view, debugLines };
}

/** Types `word` at the end of the paragraph whose text starts with `startsWith` -- a real,
 * history-adding ProseMirror transaction, exactly what a keystroke produces. */
function typeIntoParagraph(view: EditorView, startsWith: string, word: string): void {
  let endPos = -1;
  view.state.doc.forEach((node, offset) => {
    if (endPos === -1 && node.type.name === 'paragraph' && node.textContent.startsWith(startsWith)) {
      endPos = offset + node.nodeSize - 1; // end of the paragraph's inline content
    }
  });
  expect(endPos, `paragraph starting with "${startsWith}" must exist`).toBeGreaterThan(-1);
  view.dispatch(view.state.tr.insertText(word, endPos));
}

/** Lets block-sync's 100ms debounce elapse, so a typed edit is diffed into the pending queue. */
async function letDebounceElapse(): Promise<void> {
  await vi.advanceTimersByTimeAsync(150);
}

/** Runs the next animation frame (the deferred unpause of `setContentWithBlockIds`). */
async function nextFrame(): Promise<void> {
  await vi.advanceTimersByTimeAsync(50);
}

interface Facts {
  /** The typed word is in the live document. */
  onScreen: boolean;
  /** `hasPendingChanges()`: what a report (or a route's drain) would take as non-empty. */
  queueNonEmpty: boolean;
  /** The pending queue holds an update or insert whose text contains the typed word. */
  queuedWithWord: boolean;
  /** Ids of pending updates (non-destructive peek). */
  queuedUpdateIds: string[];
}

/** Non-destructive reading of the block-sync pending queue (the plugin state shares its Maps with
 * the module-level `currentState` that `getBlockChanges()` drains and `hasPendingChanges()` reads). */
function measure(view: EditorView, word: string): Facts {
  const state = blockSyncPluginKey.getState(view.state);
  const updates = state ? Array.from(state.pendingUpdates.values()) : [];
  const inserts = state ? Array.from(state.pendingInserts.values()) : [];
  const word0 = word.trim();
  const holdsWord = (text: string | undefined) => (text ?? '').includes(word0);
  return {
    onScreen: view.state.doc.textContent.includes(word0),
    queueNonEmpty: hasPendingChanges(),
    queuedWithWord:
      updates.some((u) => holdsWord(u.textContent) || holdsWord(u.markdownFragment)) ||
      inserts.some((i) => holdsWord(i.textContent) || holdsWord(i.markdownFragment)),
    queuedUpdateIds: updates.map((u) => u.id),
  };
}

function trace(name: string, fields: Record<string, string | number | boolean>): void {
  const rendered = Object.entries(fields)
    .map(([k, v]) => `${k}=${v}`)
    .join(' ');
  console.log(`[TRACE] ${name} ${rendered}`);
}

function structTraceLines(h: Harness): string[] {
  return h.debugLines.filter((l) => l.startsWith('[STRUCT-TRACE]'));
}

/** Forward operation, as Swift runs it, minus the database (the post-operation markdown IS what the
 * database would hold). `typeDuringWindow` runs after `beginStructuralOp` and before the push. */
async function runForwardOp(h: Harness, opts: { typeDuringWindow?: string } = {}) {
  expect(beginStructuralOp(OP_ID)).toBe(true);
  if (opts.typeDuringWindow) {
    typeIntoParagraph(h.view, 'Paragraph five', opts.typeDuringWindow);
    await letDebounceElapse();
  }
  const beforePush = measure(h.view, opts.typeDuringWindow ?? 'NO-WORD');
  setContentWithBlockIds(markdownOf(POST_OP_BLOCKS), idsOf(POST_OP_BLOCKS), { detectPausedEdits: true });
  const rightAfterPush = measure(h.view, opts.typeDuringWindow ?? 'NO-WORD');
  expect(finalizeStructuralOpPostOpDoc(OP_ID)).toBe(true);
  await nextFrame();
  const afterFrame = measure(h.view, opts.typeDuringWindow ?? 'NO-WORD');
  return { beforePush, rightAfterPush, afterFrame };
}

describe('structural op x typing -- characterization (Phase 4b trace)', () => {
  // S4 -- CONTROL for S1. No operation running. If this does not show queuedForSave=true the harness is
  // wrong and S1/S2 mean nothing. Expected today and after any fix: true.
  it('characterization (pre-4b): S4 control, typing with no operation running is queued for save', async () => {
    const h = await makeHarness();

    typeIntoParagraph(h.view, 'Paragraph five', TYPED_CONTROL);
    await letDebounceElapse();
    const f = measure(h.view, TYPED_CONTROL);

    trace('S4-control-no-operation', {
      typedWordSurvivesOnScreen: f.onScreen,
      typedWordQueuedForSave: f.queuedWithWord,
      queueNonEmpty: f.queueNonEmpty,
      queuedUpdateIds: f.queuedUpdateIds.join(','),
    });
    expect(f.onScreen).toBe(true);
    expect(f.queuedWithWord).toBe(true);
    expect(f.queuedUpdateIds).toEqual(['p5']);
  });

  // S1 -- forward operation, text typed after beginStructuralOp and before the push, debounce elapsed.
  // The post-operation markdown is what the database holds: paragraph five WITHOUT the typed word.
  //
  // WHAT THE FIX LANDING WOULD LOOK LIKE: typedWordSurvivesOnScreen=true (the push preserves or re-applies
  // the typed word) AND typedWordQueuedForSave=true (the typed edit is still in the queue after the
  // unpause, or has been saved). Today's assertions below say the opposite on both counts.
  it('characterization (pre-4b): S1 forward op, typing mid-operation is overwritten and never queued', async () => {
    const h = await makeHarness();

    const m = await runForwardOp(h, { typeDuringWindow: TYPED_FORWARD });

    trace('S1-forward-typing-mid-operation', {
      queuedBeforePush: m.beforePush.queuedWithWord,
      onScreenRightAfterPush: m.rightAfterPush.onScreen,
      queuedRightAfterPush: m.rightAfterPush.queuedWithWord,
      queuedUpdateIdsRightAfterPush: m.rightAfterPush.queuedUpdateIds.join(','),
      queueNonEmptyAfterFrame: m.afterFrame.queueNonEmpty,
      typedWordSurvivesOnScreen: m.afterFrame.onScreen,
      typedWordQueuedForSave: m.afterFrame.queuedWithWord,
    });
    console.log(`[TRACE-LOG] S1 ${structTraceLines(h).join(' || ')}`);

    // Sanity: the harness saw the typed edit sitting in the queue before the push (same fact as S4).
    expect(m.beforePush.queuedWithWord).toBe(true);
    // The push overwrote paragraph five with the database copy.
    expect(m.rightAfterPush.onScreen).toBe(false);
    expect(m.afterFrame.onScreen).toBe(false);
    // Right after the push the stale queued update is still there; the deferred unpause then clears it
    // (detectPausedEditsAndSnapshot wipes the queue before diffing against its post-push baseline).
    expect(m.rightAfterPush.queuedWithWord).toBe(true);
    expect(m.afterFrame.queuedWithWord).toBe(false);
    expect(m.afterFrame.queueNonEmpty).toBe(false);
  });

  // S1b -- control for the one thing `detectPausedEdits` is built for: text typed AFTER the push, inside
  // the paused window (before the deferred unpause). Expected today and after any fix: queued for save,
  // because the baseline is taken right after the replace. Together with S1 this shows the option only
  // protects the instant after the push, not the seconds before it.
  it('characterization (pre-4b): S1b control, typing in the instant after the push IS queued by detectPausedEdits', async () => {
    const h = await makeHarness();

    expect(beginStructuralOp(OP_ID)).toBe(true);
    setContentWithBlockIds(markdownOf(POST_OP_BLOCKS), idsOf(POST_OP_BLOCKS), { detectPausedEdits: true });
    expect(finalizeStructuralOpPostOpDoc(OP_ID)).toBe(true);
    typeIntoParagraph(h.view, 'Paragraph five', TYPED_FORWARD); // sync is still paused: no debounce starts
    const rightAfterTyping = measure(h.view, TYPED_FORWARD);
    await nextFrame();
    const afterFrame = measure(h.view, TYPED_FORWARD);

    trace('S1b-control-typing-just-after-push', {
      queuedRightAfterTyping: rightAfterTyping.queuedWithWord,
      typedWordSurvivesOnScreen: afterFrame.onScreen,
      typedWordQueuedForSave: afterFrame.queuedWithWord,
    });
    expect(rightAfterTyping.queuedWithWord).toBe(false); // paused: nothing diffed yet
    expect(afterFrame.onScreen).toBe(true);
    expect(afterFrame.queuedWithWord).toBe(true);
  });

  // S2 -- undo: text typed after performStructuralSwap and before finishStructuralSwapSettle. Between the
  // two, Swift restores the database and pushes fresh block ids (`BlockSyncService.pushBlockIds` ->
  // `syncBlockIds`, which itself calls resetAndSnapshot). S2 types BEFORE that id push, S2b AFTER it;
  // both are before the settle.
  //
  // WHAT THE FIX LANDING WOULD LOOK LIKE: typedWordQueuedForSave=true (the typed edit is detected against
  // the post-swap baseline and queued, or saved before the settle). Today's assertions say it is on
  // screen but NOT queued.
  it('characterization (pre-4b): S2 undo, typing after the swap and before the id push stays on screen but is never queued', async () => {
    const h = await makeHarness();
    await runForwardOp(h);
    h.debugLines.length = 0;

    expect(performStructuralSwap(OP_ID, 'undo')).toBe(true);
    typeIntoParagraph(h.view, 'Paragraph five', TYPED_SWAP);
    await letDebounceElapse();
    const afterTyping = measure(h.view, TYPED_SWAP);
    syncBlockIds(RESTORED_IDS, false); // Swift's pushBlockIds between the swap and the settle
    const afterIdPush = measure(h.view, TYPED_SWAP);
    expect(finishStructuralSwapSettle()).toBe(true);
    await letDebounceElapse();
    const afterSettle = measure(h.view, TYPED_SWAP);

    trace('S2-undo-typing-after-swap-before-id-push', {
      queuedAfterTyping: afterTyping.queuedWithWord,
      queuedAfterIdPush: afterIdPush.queuedWithWord,
      typedWordSurvivesOnScreen: afterSettle.onScreen,
      typedWordQueuedForSave: afterSettle.queuedWithWord,
      queueNonEmptyAfterSettle: afterSettle.queueNonEmpty,
    });
    console.log(`[TRACE-LOG] S2 ${structTraceLines(h).join(' || ')}`);

    expect(afterTyping.queuedWithWord).toBe(false); // sync is paused for the whole swap window
    expect(afterSettle.onScreen).toBe(true);
    expect(afterSettle.queuedWithWord).toBe(false);
    expect(afterSettle.queueNonEmpty).toBe(false);
  });

  it('characterization (pre-4b): S2b undo, typing after the id push and before the settle stays on screen but is never queued', async () => {
    const h = await makeHarness();
    await runForwardOp(h);
    h.debugLines.length = 0;

    expect(performStructuralSwap(OP_ID, 'undo')).toBe(true);
    syncBlockIds(RESTORED_IDS, false);
    typeIntoParagraph(h.view, 'Paragraph five', TYPED_SWAP);
    await letDebounceElapse();
    const beforeSettle = measure(h.view, TYPED_SWAP);
    expect(finishStructuralSwapSettle()).toBe(true);
    await letDebounceElapse();
    const afterSettle = measure(h.view, TYPED_SWAP);

    trace('S2b-undo-typing-after-id-push-before-settle', {
      queuedBeforeSettle: beforeSettle.queuedWithWord,
      typedWordSurvivesOnScreen: afterSettle.onScreen,
      typedWordQueuedForSave: afterSettle.queuedWithWord,
      queueNonEmptyAfterSettle: afterSettle.queueNonEmpty,
    });

    expect(beforeSettle.queuedWithWord).toBe(false);
    expect(afterSettle.onScreen).toBe(true);
    expect(afterSettle.queuedWithWord).toBe(false);
    expect(afterSettle.queueNonEmpty).toBe(false);
  });

  // S3 -- undo, typing AFTER the settle completes. CONTROL for S2: expected today and after any fix: queued
  // for save. Proves the harness can see a queued edit on the undo path at all.
  it('characterization (pre-4b): S3 control, undo then typing after the settle is queued for save', async () => {
    const h = await makeHarness();
    await runForwardOp(h);

    expect(performStructuralSwap(OP_ID, 'undo')).toBe(true);
    syncBlockIds(RESTORED_IDS, false);
    expect(finishStructuralSwapSettle()).toBe(true);
    await nextFrame();
    typeIntoParagraph(h.view, 'Paragraph five', TYPED_AFTER_SETTLE);
    await letDebounceElapse();
    const f = measure(h.view, TYPED_AFTER_SETTLE);

    trace('S3-control-undo-typing-after-settle', {
      typedWordSurvivesOnScreen: f.onScreen,
      typedWordQueuedForSave: f.queuedWithWord,
      queuedUpdateIds: f.queuedUpdateIds.join(','),
    });
    expect(f.onScreen).toBe(true);
    expect(f.queuedWithWord).toBe(true);
    expect(f.queuedUpdateIds).toEqual(['r-p5']);
  });
});

// === The [STRUCT-TRACE] lines themselves ===
// The app cannot be run from here, so these check that the logging added for the Phase 4b trace says
// what it is meant to say, on the same real-editor harness.

describe('[STRUCT-TRACE] logging (Phase 4b trace)', () => {
  it('the push probe does nothing on ordinary pushes: with no registry entry it never even walks the registry; a finalized entry is walked but logs nothing; only a mid-op entry logs', async () => {
    const h = await makeHarness();
    const registry = getRegistry();
    // The registry-empty guard in `traceMidOpPushDrift` is what keeps an ordinary push from walking the
    // registry. Walking an empty registry prints nothing either way, so the guard is only observable as
    // "was the registry iterated at all": count its iterations.
    const walked = vi.spyOn(registry, Symbol.iterator);
    h.debugLines.length = 0;

    // 1. No registry entry: nothing is logged AND the registry is never iterated.
    setContentWithBlockIds(markdownOf(INITIAL_BLOCKS), idsOf(INITIAL_BLOCKS), { detectPausedEdits: true });
    expect(structTraceLines(h)).toEqual([]);
    expect(walked, 'an empty registry is not walked on an ordinary push').not.toHaveBeenCalled();

    // 2. A FINALIZED entry (not mid-op) is walked (the spy is sensitive) but logs nothing.
    await runForwardOp(h);
    walked.mockClear();
    h.debugLines.length = 0;
    setContentWithBlockIds(markdownOf(POST_OP_BLOCKS), idsOf(POST_OP_BLOCKS), { detectPausedEdits: true });
    expect(walked, 'premise: with an entry present the registry IS walked').toHaveBeenCalled();
    expect(structTraceLines(h).filter((l) => l.includes('push-probe'))).toEqual([]);

    // 3. A mid-op entry logs exactly one probe line.
    expect(beginStructuralOp('99999999-0000-0000-0000-000000000000')).toBe(true);
    h.debugLines.length = 0;
    setContentWithBlockIds(markdownOf(POST_OP_BLOCKS), idsOf(POST_OP_BLOCKS), { detectPausedEdits: true });
    expect(structTraceLines(h).filter((l) => l.includes('push-probe'))).toHaveLength(1);
    walked.mockRestore();
  });

  it('the push probe reports that the live document drifted from the pre-operation document, and where', async () => {
    const h = await makeHarness();
    const preOpChildren = h.view.state.doc.childCount;
    const preOpSize = h.view.state.doc.content.size;
    expect(beginStructuralOp(OP_ID)).toBe(true);

    // Probe 1: nothing typed yet -- the live document still equals the pre-operation document.
    setContentWithBlockIds(markdownOf(INITIAL_BLOCKS), idsOf(INITIAL_BLOCKS), { detectPausedEdits: true });
    const untouched = structTraceLines(h).find((l) => l.includes('push-probe'));
    expect(untouched).toContain('eq=true');
    expect(untouched).toContain(`liveSize=${preOpSize}`);
    expect(untouched).toContain(`liveChildren=${preOpChildren}`);

    // Probe 2: a word typed into paragraph five (the seventh top-level block, index 6) during the window.
    await nextFrame();
    h.debugLines.length = 0;
    typeIntoParagraph(h.view, 'Paragraph five', TYPED_FORWARD);
    await letDebounceElapse();
    setContentWithBlockIds(markdownOf(POST_OP_BLOCKS), idsOf(POST_OP_BLOCKS), { detectPausedEdits: true });
    const drifted = structTraceLines(h).find((l) => l.includes('push-probe'));
    expect(drifted).toContain('eq=false');
    expect(drifted).toContain('diffChildren=1');
    expect(drifted).toContain('firstDiffChild=6');
    expect(drifted).toContain(`preOpSize=${preOpSize}`);
    expect(drifted).toContain(`liveSize=${preOpSize + TYPED_FORWARD.length}`);
    expect(drifted).toContain(`incomingChildren=${POST_OP_BLOCKS.length}`);
    expect(drifted).toContain('pendingQueue=true');
  });

  it('finalize and registry-advance lines carry the document sizes', async () => {
    const h = await makeHarness();
    await runForwardOp(h);

    const finalize = structTraceLines(h).find((l) => l.includes('finalize opId=11111111'));
    expect(finalize).toContain(`postOpChildren=${POST_OP_BLOCKS.length}`);
    expect(finalize).toContain(`preOpChildren=${INITIAL_BLOCKS.length}`);
    expect(finalize).toMatch(/postOpSize=\d+ /);
    expect(finalize).toMatch(/postOpTextLen=\d+ /);

    // A later sync-origin transaction (addToHistory:false, e.g. a derived-content resync) advances postOpDoc.
    h.debugLines.length = 0;
    const before = h.view.state.doc.content.size;
    h.view.dispatch(h.view.state.tr.insertText('!', 1).setMeta('addToHistory', false));
    const advance = structTraceLines(h).find((l) => l.includes('registry-advance'));
    expect(advance).toContain('count=1 opIds=11111111:post');
    expect(advance).toContain(`size=${before}->${before + 1}`);
  });

  it('registry-advance posts ONE line per chain, listing every entry that moved (not one line per entry)', async () => {
    const h = await makeHarness();
    await runForwardOp(h);
    // Two more finalized entries whose saved copies are the same document (the zero-diff Document Note
    // entries all look like this).
    const first = getRegistry().get(OP_ID);
    expect(first).toBeDefined();
    setRegistryEntry('aaaaaaaa-0000-0000-0000-000000000000', { ...(first as NonNullable<typeof first>) });
    setRegistryEntry('bbbbbbbb-0000-0000-0000-000000000000', { ...(first as NonNullable<typeof first>) });
    h.debugLines.length = 0;

    h.view.dispatch(h.view.state.tr.insertText('!', 1).setMeta('addToHistory', false));

    const advances = structTraceLines(h).filter((l) => l.includes('registry-advance'));
    expect(advances, 'one aggregated line for the whole chain').toHaveLength(1);
    expect(advances[0]).toContain('count=3');
    for (const prefix of ['11111111', 'aaaaaaaa', 'bbbbbbbb']) expect(advances[0]).toContain(`${prefix}:post`);
  });

  it('the routing probe names the failed condition and the document sizes when Cmd-Z is refused', async () => {
    const h = await makeHarness();
    await runForwardOp(h);
    setUndoDescriptor({ undoTopOpId: OP_ID });
    const key = () => new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });

    // Condition: a local edit block-sync has not diffed yet. The press flushes block-sync's debounce itself
    // (t-dfc4fb02, sibling cause 1), so it is judged on the document: the typed word is still there.
    typeIntoParagraph(h.view, 'Paragraph five', TYPED_FORWARD);
    h.debugLines.length = 0;
    expect(handleUnifiedUndoKeydown(key(), h.view, 'undo')).toBe(false);
    const unsettled = structTraceLines(h).find((l) => l.includes('routing-refused'));
    expect(unsettled).toContain('failed=docs-not-equal');

    // Condition: the live document no longer equals the saved post-operation document.
    await letDebounceElapse();
    h.debugLines.length = 0;
    expect(handleUnifiedUndoKeydown(key(), h.view, 'undo')).toBe(false);
    const notEqual = structTraceLines(h).find((l) => l.includes('routing-refused'));
    expect(notEqual).toContain('failed=docs-not-equal');
    expect(notEqual).toContain('target=postOpDoc');
    expect(notEqual).toContain('firstDiffChild=3'); // paragraph five is block index 3 of the 8-block post-op document
    expect(notEqual).toContain('diffChildren=1');
    expect(notEqual).toContain(`entryPostOpSize=${h.view.state.doc.content.size - TYPED_FORWARD.length}`);

    // Condition: no registry entry for the descriptor's top op.
    setUndoDescriptor({ undoTopOpId: '99999999-0000-0000-0000-000000000000' });
    h.debugLines.length = 0;
    expect(handleUnifiedUndoKeydown(key(), h.view, 'undo')).toBe(false);
    expect(structTraceLines(h).find((l) => l.includes('routing-refused'))).toContain('failed=no-registry-entry');

    // Nothing is logged when Swift's descriptor names no structural entry (the ordinary Cmd-Z).
    setUndoDescriptor({});
    h.debugLines.length = 0;
    handleUnifiedUndoKeydown(key(), h.view, 'undo');
    expect(structTraceLines(h).filter((l) => l.includes('routing-refused'))).toEqual([]);
  });

  it('the routing lines carry the routing time and never document text', async () => {
    const h = await makeHarness();
    await runForwardOp(h);
    setUndoDescriptor({ undoTopOpId: OP_ID });
    typeIntoParagraph(h.view, 'Paragraph five', TYPED_FORWARD);
    await letDebounceElapse();
    h.debugLines.length = 0;
    handleUnifiedUndoKeydown(
      new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true }),
      h.view,
      'undo'
    );

    const lines = structTraceLines(h);
    const equivalence = lines.find((l) => l.includes('routing-equivalence')) ?? '';
    const refused = lines.find((l) => l.includes('routing-refused')) ?? '';
    expect(equivalence).toMatch(/ ms=\d+\.\d totalMs=\d+\.\d /);
    expect(refused).toMatch(/ routingMs=\d+\.\d diagMs=\d+\.\d/);
    expect(refused).toContain('current(size=');
    expect(refused).not.toContain('textLen');
    for (const line of lines) {
      for (const forbidden of ['TYPEDWORD', 'Paragraph', 'original text', 'Alpha', 'Beta', 'Gamma']) {
        expect(line, `a trace line carries document text: ${forbidden}`).not.toContain(forbidden);
      }
    }
  });

  it('the swap and settle lines report sizes and whether the pending queue held edits at the settle', async () => {
    const h = await makeHarness();
    await runForwardOp(h);
    h.debugLines.length = 0;

    expect(performStructuralSwap(OP_ID, 'undo')).toBe(true);
    const swap = structTraceLines(h).find((l) => l.includes('swap opId='));
    expect(swap).toContain('direction=undo');
    expect(swap).toContain(`childrenBefore=${POST_OP_BLOCKS.length}`);
    expect(swap).toContain(`childrenAfter=${INITIAL_BLOCKS.length}`);

    typeIntoParagraph(h.view, 'Paragraph five', TYPED_SWAP);
    expect(finishStructuralSwapSettle()).toBe(true);
    const settle = structTraceLines(h).find((l) => l.includes('settle sizeBefore='));
    expect(settle).toContain(`childrenAfter=${INITIAL_BLOCKS.length}`);
    // The typed edit was made while sync was paused, so nothing is queued and the debounce never started:
    // the settle has nothing to drop, and the edit is invisible to block-sync.
    expect(settle).toContain('pendingQueueAtStart=false');
    expect(settle).toContain('unsettledEditAtStart=false');
    getBlockChanges(); // leave the queue empty for the next test
  });
});

// === No per-keystroke line ===
// The structural-operation diagnostics post one line per structural EVENT (finalize, advance, push,
// refusal, swap, settle, rebase). Ordinary typing must post nothing -- even while a registry entry exists,
// which is when every keystroke passes through the advancement rule. An automatic rewrite that lands after the
// user typed posts one counts-only registry-rebase line (t-dfc4fb02), one per automatic chain, never per keystroke.

describe('[STRUCT-TRACE] silence on ordinary typing (structural-operation diagnostics)', () => {
  /** A sync-origin (addToHistory:false) one-step edit at the end of the paragraph "Paragraph four...". */
  function derivedInsert(view: EditorView, text: string): void {
    let endPos = -1;
    view.state.doc.forEach((node, offset) => {
      if (endPos === -1 && node.type.name === 'paragraph' && node.textContent.startsWith('Paragraph four')) {
        endPos = offset + node.nodeSize - 1;
      }
    });
    expect(endPos, 'paragraph four must exist').toBeGreaterThan(-1);
    view.dispatch(view.state.tr.insertText(text, endPos).setMeta('addToHistory', false));
  }

  it('typing posts no trace line; an automatic rewrite after it posts exactly one registry-rebase line, counts only (t-dfc4fb02)', async () => {
    const h = await makeHarness();
    await runForwardOp(h);

    // The registry holds a finalized entry now. A keystroke is a real user edit: nothing is absorbed, nothing is logged.
    h.debugLines.length = 0;
    typeIntoParagraph(h.view, 'Paragraph five', TYPED_FORWARD);
    expect(structTraceLines(h)).toEqual([]);

    // The typed word moved the document away from the entry's saved copy, so the exact advancement matches no entry
    // (no registry-advance line). The automatic rewrite lands in a block the user did not touch and left no text-history
    // step, so the saved copy follows it: ONE registry-rebase line per automatic chain, never one per keystroke, and
    // counts and timing only -- no document text.
    h.debugLines.length = 0;
    derivedInsert(h.view, '?');
    const lines = structTraceLines(h);
    expect(lines, 'exactly one line, and it is not a registry-advance').toHaveLength(1);
    expect(lines[0]).toMatch(/registry-rebase .* result=rebased/);
    // Round F3 of t-18b7fa48 deliberately added `historyStep=false user=[...] chain=[...]` to this line (index ranges and
    // node TYPES where the saved copy differs from the live document and what the chain changed; never text).
    expect(lines[0]).toMatch(
      /^\[STRUCT-TRACE\] registry-rebase opId=[0-9a-f]{8} result=rebased userRanges=\d+ chainRanges=\d+ cells=\d+ ms=\d+\.\d children=\d+->\d+ historyStep=false user=\[[^\]]*\] chain=\[[^\]]*\]$/
    );
    expect(lines[0], 'the new fields name index ranges and node types only').toMatch(
      /user=\[1 range: a\[\d+,\d+\)b\[\d+,\d+\) paragraph>paragraph\] chain=\[1 range: a\[\d+,\d+\)b\[\d+,\d+\) paragraph>paragraph\]$/
    );
    for (const forbidden of ['TYPEDWORD', '?', 'Paragraph', 'Alpha', 'Beta', 'Gamma']) {
      expect(lines[0], `a trace line carries document text: ${forbidden}`).not.toContain(forbidden);
    }
  });
});
