// Shared harness for the editor-first structural-operation tests (t-18b7fa48 round 1d onwards): a COPY of the helpers in
// quick-undo-section-delete.test.ts (which stays as it is), plus `typeIntoNth` and the `sectionBreak` spec.
//
// The harness is the real thing, as in delete-section-editor-first.test.ts: a real Milkdown editor with the block-id, block-sync and
// history plugins, `view.dispatch` wired through the production `runUndoTrackedDispatch` exactly as main.ts's override does, real
// timers and real animation frames. A Cmd-Z is a real keydown through `handleUnifiedUndoKeydown`, so the in-flight latch the quick
// undo's re-check needs is the one the production press sets. Swift's side of the conversation (the descriptor push and the reply)
// is played by the test.
//
// Importing this module registers its own `afterEach` cleanup (editor destroyed, module state reset), so a test file only imports
// the helpers it uses.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, expect, vi } from 'vitest';
import { getBlockChangesApi, setContentWithBlockIds } from '../api-content';
import { resumeSyncAfterQuickUndo } from '../api-section-undo';
import { blockIdPlugin, getAllBlockIds, resetBlockIdState, setBlockIdZoomMode } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { setContentHasBeenSet, setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import { resetSetAsideRedo } from '../redo-branch';
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

// === Documents ===

export interface Spec {
  name: string;
  md: string;
}
export const heading = (name: string, level: number, title: string): Spec => ({
  name,
  md: `${'#'.repeat(level)} ${title}`,
});
export const para = (name: string, text: string): Spec => ({ name, md: text });
/** A section break: the `<!-- ::break:: -->` line the section-break plugin turns into a `section_break` node (a level-1 leader). */
export const sectionBreak = (name: string): Spec => ({ name, md: '<!-- ::break:: -->' });
export const markdownOf = (specs: Spec[]) => specs.map((s) => s.md).join('\n\n');

export const EMPTY_BATCH = { updates: [], inserts: [], deletes: [] };

// === Harness ===

let current: Editor | null = null;

export const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

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
  resetSetAsideRedo(); // a record the quick undo kept aside must not outlive its test (the tests share one operation id)
  delete (window as any).webkit;
});

/** Waits `frames` animation frames and then one task: a content push unpauses block-sync from a frame callback. */
export function waitForRAF(frames = 3): Promise<void> {
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

export type Posted = Array<{ handler: string; body: any }>;

/** The Swift bridge as a recorder: every message the editor posts, by handler name. */
export function installBridge(): Posted {
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

/** `extraPlugins` are registered before commonmark/gfm, as main.ts registers the image plugin (figure schema + remark transform). */
export async function makeEditor(
  extraPlugins: Array<Parameters<Editor['use']>[0]> = []
): Promise<{ view: EditorView; posted: Posted }> {
  const posted = installBridge();
  const div = document.createElement('div');
  document.body.appendChild(div);
  // sectionBreakPlugin must be registered BEFORE commonmark/gfm: it turns HTML comments into nodes before commonmark's own HTML
  // handling sees them -- the order main.ts uses.
  let maker = Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, '');
    })
    .use(sectionBreakPlugin);
  for (const plugin of extraPlugins) maker = maker.use(plugin);
  const editor = await maker
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

/** Block ids in document order, as the block-id plugin holds them. */
export function idsInOrder(): string[] {
  return Array.from(getAllBlockIds().entries())
    .sort((a, b) => a[0] - b[0])
    .map(([, id]) => id);
}

/** Loads `specs` with explicit ids (the spec names) and lets the push's deferred unpause run. */
export async function load(specs: Spec[]): Promise<void> {
  setContentWithBlockIds(
    markdownOf(specs),
    specs.map((s) => s.name)
  );
  await waitForRAF();
  getBlockChangesApi(); // whatever the push itself left pending is not what these tests are about
  expect(idsInOrder()).toEqual(specs.map((s) => s.name));
}

/** Document position at the end of the text of the `nth` (0-based) paragraph starting with `startsWith`. */
export function endOfNthParagraph(view: EditorView, startsWith: string, nth = 0): number {
  let endPos = -1;
  let seen = 0;
  view.state.doc.forEach((node, offset) => {
    if (endPos === -1 && node.type.name === 'paragraph' && node.textContent.startsWith(startsWith)) {
      if (seen === nth) endPos = offset + node.nodeSize - 1;
      seen++;
    }
  });
  expect(endPos, `paragraph #${nth} starting with "${startsWith}" must exist`).toBeGreaterThan(-1);
  return endPos;
}

/** Document position at the end of the text of the first paragraph starting with `startsWith`. */
export function endOfParagraph(view: EditorView, startsWith: string): number {
  return endOfNthParagraph(view, startsWith, 0);
}

/** A real, history-adding user edit at the end of the first paragraph starting with `startsWith`. */
export function typeInto(view: EditorView, startsWith: string, word: string): void {
  view.dispatch(view.state.tr.insertText(word, endOfParagraph(view, startsWith)));
}

/** A real, history-adding user edit at the end of the `nth` (0-based) paragraph starting with `startsWith`: with a section and its
 * copy side by side, `nth` 0 is the original and 1 is the copy. */
export function typeIntoNth(view: EditorView, startsWith: string, nth: number, word: string): void {
  view.dispatch(view.state.tr.insertText(word, endOfNthParagraph(view, startsWith, nth)));
}

/** An automatic rewrite (a footnote renumber or a Notes rebuild landing): sync origin, not added to the text history. */
export function automaticRewrite(view: EditorView, startsWith: string, word: string): void {
  view.dispatch(view.state.tr.insertText(word, endOfParagraph(view, startsWith)).setMeta('addToHistory', false));
}

export function keyZ(shift: boolean): KeyboardEvent {
  return new KeyboardEvent('keydown', { key: 'z', metaKey: true, shiftKey: shift, cancelable: true });
}

/** Cmd-Z with `top` on top of Swift's undo stack: the production routing decision, which latches the coordinator for `top`. */
export function pressUndo(view: EditorView, top: string, descriptor: { redoTopOpId?: string } = {}): boolean {
  setUndoDescriptor({ undoTopOpId: top, ...descriptor });
  return handleUnifiedUndoKeydown(keyZ(false), view, 'undo');
}

export function pressRedo(view: EditorView, top: string): boolean {
  setUndoDescriptor({ redoTopOpId: top });
  return handleUnifiedUndoKeydown(keyZ(true), view, 'redo');
}

/** What Swift does after a successful quick undo: resume (the real order is: reserve the reinsert's ticket, then resume), push the
 * descriptor, reply. The latch clears at the reply, which also routes any press that was held behind it. */
export function swiftFinishesUndo(opId: string, descriptor: { undoTopOpId?: string; redoTopOpId?: string }): void {
  resumeSyncAfterQuickUndo();
  setUndoDescriptor(descriptor);
  receiveUndoOutcome(opId, 'performed');
}

/** The same for a quick redo (no resume: the redo pauses and unpauses block-sync inside the call). */
export function swiftFinishesRedo(opId: string, descriptor: { undoTopOpId?: string; redoTopOpId?: string }): void {
  setUndoDescriptor(descriptor);
  receiveRedoOutcome(opId, 'performed');
}
