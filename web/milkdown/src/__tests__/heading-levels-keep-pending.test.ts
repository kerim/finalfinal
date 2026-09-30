// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { flushPendingBlockChanges, getBlockChangesApi, updateHeadingLevels } from '../api-content';
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

// Regression coverage for t-94369a83 Phase 2, §3: updateHeadingLevels used to finish by
// calling deferredSnapshotAndUnpause() with no arguments, which routes to the full-wipe
// resetAndSnapshot() -- silently discarding any edit or pending insert already queued
// (or still sitting in block-sync's own 100ms debounce) before the heading fix ran. The
// fix routes through detectPausedEditsKeepingPending instead (the same mechanism
// setContentWithBlockIds's preserveUserBlocks push already uses -- see
// rebuild-preserve-user-blocks.test.ts, whose harness this file mirrors), plus flushes
// any still-debounced edit BEFORE pausing sync so it survives the RAF callback's own
// clearTimeout instead of being silently cancelled.
//
// Real timers throughout, no vi.useFakeTimers() -- see rebuild-preserve-user-blocks.test.ts's
// own comment on why: deferredSnapshotAndUnpause's RAF callback doesn't fire reliably once
// fake timers have been toggled on/off across multiple `it()`s in one file.

function waitForRAF(frames = 3): Promise<void> {
  return new Promise((resolve) => {
    let remaining = frames;
    const step = () => {
      remaining--;
      if (remaining <= 0) resolve();
      else requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
}

describe('updateHeadingLevels keeps the pending block-sync queue (t-94369a83 Phase 2, §3)', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
    setBlockIdZoomMode(false); // resetBlockIdState() does not reset this flag; see its own test
  });

  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const editor = await Editor.make()
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
    return editor;
  }

  /** Seeds block ids, the managed set, and a snapshot baseline -- the state a real initial
   * content load leaves behind, without round-tripping through setContentWithBlockIds itself.
   * Mirrors rebuild-preserve-user-blocks.test.ts's own seed() helper: `resetAndSnapshot` has
   * already run once by the time each test's own edits happen, matching that reference file's
   * pattern for establishing the baseline. */
  function seed(view: EditorView, ids: string[], managedIds: string[] = []): void {
    setBlockIdsForTopLevel(ids, view.state.doc);
    setManagedBlockIds(managedIds);
    resetAndSnapshot(view.state.doc);
  }

  function posById(): Map<string, number> {
    return new Map(Array.from(getAllBlockIds().entries()).map(([pos, id]) => [id, pos]));
  }

  it('(a) an already-flushed pending edit survives a heading-level fix, alongside the heading update itself', async () => {
    const editor = await makeEditor('# A\n\n### B\n\npara');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    seed(view, ['h-a', 'h-b', 'p-1'], []);

    // Type " more" at the end of para, then flush it into a genuine pending change --
    // BEFORE updateHeadingLevels is ever called.
    const pPos = posById().get('p-1')!;
    const pNode = view.state.doc.nodeAt(pPos)!;
    view.dispatch(view.state.tr.insertText(' more', pPos + pNode.nodeSize - 1));
    flushPendingBlockChanges();

    updateHeadingLevels([{ blockId: 'h-b', newLevel: 2 }]);
    await waitForRAF();

    const changes = getBlockChangesApi();
    const pUpdate = changes.updates.find((u) => u.id === 'p-1');
    expect(pUpdate).toBeDefined();
    expect(pUpdate?.textContent).toContain('para more');

    const hUpdate = changes.updates.find((u) => u.id === 'h-b');
    expect(hUpdate).toBeDefined();
    expect(hUpdate?.headingLevel).toBe(2);
    expect(hUpdate?.markdownFragment).toContain('## B');
  });

  it('(b) a pending insert made before the call stays pending, not silently dropped', async () => {
    const editor = await makeEditor('# A\n\n### B\n\npara');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    seed(view, ['h-a', 'h-b', 'p-1'], []);

    // A real insert, left sitting in block-sync's own 100ms debounce -- deliberately NOT
    // flushed here, so the heading fix's own internal flush (step 1 of the fix) is what
    // has to catch it.
    const pPos = posById().get('p-1')!;
    const newPara = view.state.schema.nodes.paragraph.create({}, view.state.schema.text('Inserted.'));
    view.dispatch(view.state.tr.insert(pPos, newPara));

    let tempId: string | undefined;
    for (const [, id] of getAllBlockIds()) {
      if (id.startsWith('temp-')) tempId = id;
    }
    expect(tempId).toBeDefined();

    updateHeadingLevels([{ blockId: 'h-b', newLevel: 2 }]);
    await waitForRAF();

    const changes = getBlockChangesApi();
    const insert = changes.inserts.find((i) => i.tempId === tempId);
    expect(insert).toBeDefined();
    expect(insert?.textContent).toBe('Inserted.');
  });

  it('(c) text typed into the heading itself just before the call is captured with the fresh text, not stale', async () => {
    const editor = await makeEditor('# A\n\n### B\n\npara');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);
    seed(view, ['h-a', 'h-b', 'p-1'], []);

    // Edit heading B itself (not just something around it), left in the debounce --
    // deliberately NOT flushed.
    const hPos = posById().get('h-b')!;
    const hNode = view.state.doc.nodeAt(hPos)!;
    view.dispatch(view.state.tr.insertText(' EDITED', hPos + hNode.nodeSize - 1));

    updateHeadingLevels([{ blockId: 'h-b', newLevel: 2 }]);
    await waitForRAF();

    const changes = getBlockChangesApi();
    const hUpdate = changes.updates.find((u) => u.id === 'h-b');
    expect(hUpdate).toBeDefined();
    expect(hUpdate?.headingLevel).toBe(2);
    expect(hUpdate?.markdownFragment).toContain('## B EDITED');
    expect(hUpdate?.markdownFragment).not.toContain('### B');
  });
});
