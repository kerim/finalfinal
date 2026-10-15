// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { getBlockChangesApi, setContentWithBlockIds } from '../api-content';
import {
  blockIdPlugin,
  getAllBlockIds,
  resetBlockIdState,
  setBlockIdsForTopLevel,
  setBlockIdZoomMode,
  setManagedBlockIds,
} from '../block-id-plugin';
import { blockSyncPlugin, resetAndSnapshot, resetBlockSyncState } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import { setTraceTyping } from '../typing-trace';
import { runUndoTrackedDispatch } from '../undo-coordinator';

// Phase 4b part 2, slice 0 (measurement only, t-94369a83): the typing-latency trace.
//
// Two JS-to-Swift messages exist only for the trace, and both are posted ONLY while Swift has switched the flag on
// (`window.FinalFinal.setTraceTyping(true)`; default false):
//   - `typingEcho`: from the first animation frame after a REAL USER EDIT transaction (undo-coordinator.ts's
//     `isRealUserEditTransaction`: the document changed, history not switched off, not a `derivedCorrection`);
//   - `typingTrace` {event: 'rebuild-replaced-pending', kind, block}: a Notes / bibliography / footnote rebuild push dropped
//     the pending (typed, not yet saved) edit of a block it replaced (block-sync-plugin.ts's
//     `reconcilePendingQueueAfterManagedRebuild`).
//
// The harness is the real thing: a real Milkdown editor with the block-id and block-sync plugins, `view.dispatch` wired
// through the production `runUndoTrackedDispatch` exactly as main.ts's override does, and real animation frames. The
// message handlers are spies standing in for WKWebView's `window.webkit.messageHandlers`.

/** Waits `frames` animation frames, then one more task: the echo is posted from a task after the frame callback. */
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

describe('typing trace (slice 0): posted only when the flag is on, and only for what it names', () => {
  const echo = vi.fn();
  const trace = vi.fn();

  beforeEach(() => {
    echo.mockClear();
    trace.mockClear();
    (window as any).webkit = {
      messageHandlers: { typingEcho: { postMessage: echo }, typingTrace: { postMessage: trace } },
    };
  });

  afterEach(() => {
    setTraceTyping(false);
    delete (window as any).webkit;
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
    setBlockIdZoomMode(false);
  });

  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    return await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(commonmark)
      .use(gfm)
      .use(highlightPlugin)
      .use(blockIdPlugin)
      .use(blockSyncPlugin)
      .use(history)
      .create();
  }

  /** Seeds block ids, the managed set and the block-sync baseline, the state a real content load leaves behind. */
  function seed(view: EditorView, ids: string[], managedIds: string[] = []): void {
    setBlockIdsForTopLevel(ids, view.state.doc);
    setManagedBlockIds(managedIds);
    resetAndSnapshot(view.state.doc);
  }

  /** Routes `view.dispatch` through the production per-transaction hooks, as main.ts's `view.dispatch` override does. */
  function wireDispatch(view: EditorView): void {
    const original = view.dispatch.bind(view);
    view.dispatch = (tr) => runUndoTrackedDispatch(view, tr, original);
  }

  function posById(): Map<string, number> {
    return new Map(Array.from(getAllBlockIds().entries()).map(([pos, id]) => [id, pos]));
  }

  function typeAtEndOf(view: EditorView, id: string, text: string, meta?: Record<string, unknown>): void {
    const pos = posById().get(id)!;
    const node = view.state.doc.nodeAt(pos)!;
    let tr = view.state.tr.insertText(text, pos + node.nodeSize - 1);
    for (const [key, value] of Object.entries(meta ?? {})) tr = tr.setMeta(key, value);
    view.dispatch(tr);
  }

  // === typingEcho ===

  it('flag off (the default): a real user edit posts nothing', async () => {
    const editor = await makeEditor('# Heading\n\nParagraph.');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    seed(view, ['id-h', 'id-p']);
    wireDispatch(view);

    typeAtEndOf(view, 'id-p', ' typed');
    await waitForRAF();

    expect(echo).not.toHaveBeenCalled();
    expect(trace).not.toHaveBeenCalled();
  });

  it('flag on: a real user edit posts one typingEcho, from an animation frame, not synchronously', async () => {
    const editor = await makeEditor('# Heading\n\nParagraph.');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    seed(view, ['id-h', 'id-p']);
    wireDispatch(view);
    setTraceTyping(true);

    typeAtEndOf(view, 'id-p', ' typed');
    expect(echo).not.toHaveBeenCalled(); // not before the frame that paints the keystroke
    await waitForRAF();

    expect(echo).toHaveBeenCalledTimes(1);
    expect(echo).toHaveBeenCalledWith({ n: 1 });
  });

  it('flag on: edits before one frame share one echo; an edit after it gets its own', async () => {
    const editor = await makeEditor('# Heading\n\nParagraph.');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    seed(view, ['id-h', 'id-p']);
    wireDispatch(view);
    setTraceTyping(true);

    typeAtEndOf(view, 'id-p', ' a');
    typeAtEndOf(view, 'id-p', 'b');
    typeAtEndOf(view, 'id-p', 'c');
    await waitForRAF();
    expect(echo).toHaveBeenCalledTimes(1);
    expect(echo).toHaveBeenLastCalledWith({ n: 3 }); // the one echo says it covers three edits

    typeAtEndOf(view, 'id-p', 'd');
    await waitForRAF();
    expect(echo).toHaveBeenCalledTimes(2);
    expect(echo).toHaveBeenLastCalledWith({ n: 1 });
  });

  it('flag on: a sync-origin edit, an automatic correction and a selection-only transaction post nothing', async () => {
    const editor = await makeEditor('# Heading\n\nParagraph.');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    seed(view, ['id-h', 'id-p']);
    wireDispatch(view);
    setTraceTyping(true);

    typeAtEndOf(view, 'id-p', ' pushed by the app', { addToHistory: false }); // how content pushes are marked
    typeAtEndOf(view, 'id-p', ' renumbered', { derivedCorrection: true }); // the footnote renumber / heading-level fix
    view.dispatch(view.state.tr.scrollIntoView()); // no document change
    await waitForRAF();

    expect(echo).not.toHaveBeenCalled();
  });

  it('flag switched off after the edit and before its frame: nothing is posted', async () => {
    const editor = await makeEditor('# Heading\n\nParagraph.');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    seed(view, ['id-h', 'id-p']);
    wireDispatch(view);
    setTraceTyping(true);

    typeAtEndOf(view, 'id-p', ' typed');
    setTraceTyping(false);
    await waitForRAF();

    expect(echo).not.toHaveBeenCalled();
  });

  // === rebuild-replaced-pending ===

  const BIB_DOC = '# Heading\n\nOld paragraph.\n\n## Bibliography\n\nOld entry.';
  const BIB_IDS = ['id-h', 'id-p', 'id-bib-h', 'id-bib-e'];

  /** Types into the bibliography entry (a block the coming rebuild replaces) and into the user paragraph (one it keeps),
   * then pushes a bibliography rebuild whose new entry has a different id. Returns after the rebuild's own frame. */
  async function typeThenRebuild(): Promise<void> {
    const editor = await makeEditor(BIB_DOC);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    seed(view, BIB_IDS, ['id-bib-h', 'id-bib-e']);
    wireDispatch(view);

    typeAtEndOf(view, 'id-bib-e', ' typed in the replaced entry');
    typeAtEndOf(view, 'id-p', ' typed in the kept paragraph');

    setContentWithBlockIds(
      '# Heading\n\nOld paragraph.\n\n## Bibliography\n\nNew entry.',
      ['id-h', 'id-p', 'id-bib-h', 'id-bib-e2'],
      { managedBlockIds: ['id-bib-h', 'id-bib-e2'], preserveUserBlocks: true, traceKind: 'bibliography' }
    );
    await waitForRAF();
  }

  it('flag off: a rebuild that drops a pending edit posts nothing, and the push itself is unchanged', async () => {
    await typeThenRebuild();

    expect(trace).not.toHaveBeenCalled();
    // The behaviour the trace only observes: the replaced block's queued edit is gone, the kept block's survives.
    const changes = getBlockChangesApi();
    expect(changes.updates.find((u) => u.id === 'id-bib-e')).toBeUndefined();
    expect(changes.updates.find((u) => u.id === 'id-p')?.textContent).toContain('typed in the kept paragraph');
  });

  it('flag on: the replaced block with a pending edit is reported once, with the rebuild kind; the kept block is not', async () => {
    setTraceTyping(true);
    await typeThenRebuild();

    expect(trace).toHaveBeenCalledTimes(1);
    expect(trace).toHaveBeenCalledWith({ event: 'rebuild-replaced-pending', kind: 'bibliography', block: 'id-bib-e' });
    // Reporting must not change what the rebuild does: the replaced block's queued edit is still dropped, the kept block's
    // survives (the same assertions as the flag-off test above).
    const changes = getBlockChangesApi();
    expect(changes.updates.find((u) => u.id === 'id-bib-e')).toBeUndefined();
    expect(changes.updates.find((u) => u.id === 'id-p')?.textContent).toContain('typed in the kept paragraph');
  });

  it('flag on, rebuild kind not sent: reported with kind "unknown"', async () => {
    setTraceTyping(true);
    const editor = await makeEditor(BIB_DOC);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    seed(view, BIB_IDS, ['id-bib-h', 'id-bib-e']);
    wireDispatch(view);
    typeAtEndOf(view, 'id-bib-e', ' typed');

    setContentWithBlockIds(
      '# Heading\n\nOld paragraph.\n\n## Bibliography\n\nNew entry.',
      ['id-h', 'id-p', 'id-bib-h', 'id-bib-e2'],
      { managedBlockIds: ['id-bib-h', 'id-bib-e2'], preserveUserBlocks: true }
    );
    await waitForRAF();

    expect(trace).toHaveBeenCalledWith({ event: 'rebuild-replaced-pending', kind: 'unknown', block: 'id-bib-e' });
  });

  it('flag on: a rebuild that replaces a block with NO pending edit posts nothing', async () => {
    setTraceTyping(true);
    const editor = await makeEditor(BIB_DOC);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    seed(view, BIB_IDS, ['id-bib-h', 'id-bib-e']);
    wireDispatch(view);
    typeAtEndOf(view, 'id-p', ' typed only in the kept paragraph');

    setContentWithBlockIds(
      '# Heading\n\nOld paragraph.\n\n## Bibliography\n\nNew entry.',
      ['id-h', 'id-p', 'id-bib-h', 'id-bib-e2'],
      { managedBlockIds: ['id-bib-h', 'id-bib-e2'], preserveUserBlocks: true, traceKind: 'bibliography' }
    );
    await waitForRAF();

    expect(trace).not.toHaveBeenCalled();
  });
});
