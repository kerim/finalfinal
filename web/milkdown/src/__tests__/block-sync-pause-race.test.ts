// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { setContentWithBlockIds } from '../api-content';
import { blockIdPlugin, getAllBlockIds } from '../block-id-plugin';
import { blockSyncPlugin, getBlockChanges, resetBlockSyncState } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';

// Regression test for the version-history-restore + quick-delete race.
//
// The bug: setContentWithBlockIds() pauses block-sync change detection while
// pushing restored content into the editor, then resumes via a
// requestAnimationFrame-deferred callback. Any edit applied to the real
// ProseMirror document during that pause — e.g. the user deleting a section's
// header right after the restore lands — must be caught by that deferred
// callback instead of silently discarded (permanent Outline-sidebar desync).
//
// This exercises the REAL wiring end-to-end: a real Milkdown editor, a real
// setContentWithBlockIds() call, a real transaction dispatched into the real
// paused window (before the deferred rAF fires), and asserts the deletion is
// captured via the real getBlockChanges() surface — not just the underlying
// comparator in isolation, which a previous attempt at this fix incorrectly
// relied on (its "before" snapshot was the ambient last-known state, which in
// the real app is reset to an unrelated empty document immediately before the
// restore push runs — a bug this integration test would have caught).

describe('setContentWithBlockIds + detectPausedEdits — real editor integration', () => {
  afterEach(() => {
    vi.useRealTimers();
    setEditorInstance(null);
    resetBlockSyncState();
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
      .create();
    return editor;
  }

  it('catches a header deleted mid-pause via the real setContentWithBlockIds + rAF wiring', async () => {
    // Whatever was on screen before the restore — content and IDs here are
    // deliberately unrelated to the restored content below, mirroring how the
    // real app's project-switch reset wipes to an unrelated empty document
    // immediately before the restore push.
    const editor = await makeEditor('Old unrelated content.');
    setEditorInstance(editor);

    vi.useFakeTimers();

    // The restored heading is deliberately the LAST top-level node — nothing
    // shifts into its old position after it's deleted, avoiding block-id-plugin's
    // separate, pre-existing offset-based ID-claiming heuristic (intended for
    // in-place heading<->paragraph conversion, e.g. backspacing a "#" prefix),
    // which a mid-document deletion would otherwise incidentally trigger.
    const restoredMarkdown = '# Existing Section\n\nExisting body text.\n\n# Restored Header';
    const restoredIds = ['id-existing-heading', 'id-existing-body', 'id-restored-heading'];

    // Synchronously pushes content, assigns real block IDs, captures the
    // "just pushed" baseline, and schedules the deferred rAF — held back by
    // fake timers so we can act inside the paused window before it fires.
    setContentWithBlockIds(restoredMarkdown, restoredIds, { detectPausedEdits: true });

    const view = editor.ctx.get(editorViewCtx);
    const idsByPos = getAllBlockIds();
    const posById = new Map(Array.from(idsByPos.entries()).map(([pos, id]) => [id, pos]));
    const restoredHeadingPos = posById.get('id-restored-heading');
    expect(restoredHeadingPos).toBeDefined();

    const headingNode = view.state.doc.nodeAt(restoredHeadingPos!);
    expect(headingNode?.type.name).toBe('heading');

    // Simulate the user deleting the restored section's header DURING the
    // paused window — a real transaction, applied before the rAF fires.
    const deleteTr = view.state.tr.delete(restoredHeadingPos!, restoredHeadingPos! + headingNode!.nodeSize);
    view.dispatch(deleteTr);

    // Flush the deferred rAF callback (detectPausedEditsAndSnapshot).
    await vi.runOnlyPendingTimersAsync();

    const changes = getBlockChanges();
    expect(changes.deletes).toContain('id-restored-heading');
  });
});
