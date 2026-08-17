// @vitest-environment jsdom
// Proof-obligation tests for clearEditorHistory() (api-content.ts) -- the fix for the two-step
// reconfigure() bug described in that function's doc comment: a naive single-step plugin swap
// left the OLD undo/redo stack in place because EditorState.reconfigure() preserves a plugin's
// state by FIELD NAME ("history$"), not object identity, so a same-position swap alone never
// actually re-runs the history plugin's init(). These tests exercise the REAL production
// function (exported for testing, same as diffTopLevelBlocks/buildBlockLevelReplace in
// block-diff.test.ts) against a real Editor + real history plugin, with a negative control
// proving the positive assertion isn't vacuous.
//
// Also covers the unified-undo Phase 1 fix: resetForProjectSwitch() (the pre-existing bug --
// it cleared the document via an addToHistory:false transaction but never touched the history
// plugin itself, so a stale, rebased undo stack from the outgoing project survived into the
// incoming one) now calls clearEditorHistory() and must leave undo depth at zero.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { undoDepth } from '@milkdown/kit/prose/history';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { clearEditorHistory, resetForProjectSwitch } from '../api-content';
import { blockIdPlugin, getAllBlockIds, resetBlockIdState } from '../block-id-plugin';
import { resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';

describe('clearEditorHistory', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    resetBlockIdState();
    resetBlockSyncState();
    setSyncPaused(false);
  });

  // Mirrors block-diff.test.ts's makeEditor: blockIdPlugin before commonmark/gfm, history last
  // -- the same registration order main.ts uses in production.
  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(blockIdPlugin)
      .use(commonmark)
      .use(gfm)
      .use(historyPlugin)
      .create();
    editor = e;
    setEditorInstance(e);
    return e;
  }

  it('zeroes undo depth after a real tracked edit put it above zero', async () => {
    const e = await makeEditor('Paragraph one.\n\nParagraph two.');
    const view = e.ctx.get(editorViewCtx);

    // A real, tracked edit (default addToHistory: true) -- same as a normal keystroke.
    view.dispatch(view.state.tr.insertText('X'));
    expect(undoDepth(view.state)).toBeGreaterThan(0);

    clearEditorHistory(view);

    expect(undoDepth(view.state)).toBe(0);
  });

  it('negative control: undo depth stays above zero when the clear step is skipped', async () => {
    const e = await makeEditor('Paragraph one.\n\nParagraph two.');
    const view = e.ctx.get(editorViewCtx);

    view.dispatch(view.state.tr.insertText('X'));
    expect(undoDepth(view.state)).toBeGreaterThan(0);

    // clearEditorHistory() deliberately NOT called here -- proves the zero result in the test
    // above is actually caused by calling it, not some artifact of the harness/environment that
    // would make that assertion vacuously true regardless of what's called.
    expect(undoDepth(view.state)).toBeGreaterThan(0);
  });

  it('is a no-op (does not throw) when the view has no history plugin registered', async () => {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, 'No history plugin here.');
      })
      .use(blockIdPlugin)
      .use(commonmark)
      .use(gfm)
      .create();
    editor = e;
    setEditorInstance(e);
    const view = e.ctx.get(editorViewCtx);

    expect(() => clearEditorHistory(view)).not.toThrow();
  });

  it('preserves document content and other plugin state (block ids) across the clear', async () => {
    const e = await makeEditor('Paragraph one.\n\nParagraph two.');
    const view = e.ctx.get(editorViewCtx);
    const docBefore = view.state.doc.toString();

    view.dispatch(view.state.tr.insertText('X'));
    expect(undoDepth(view.state)).toBeGreaterThan(0);
    const docAfterEdit = view.state.doc.toString();
    // Snapshot the actual block-id-plugin state before the clear -- comparing doc text alone
    // (as an earlier version of this test did) doesn't exercise "other plugin state" at all;
    // block ids are the concrete other-plugin state this test's own name promises to check.
    const idsBeforeClear = new Map(getAllBlockIds());
    expect(idsBeforeClear.size).toBeGreaterThan(0);

    clearEditorHistory(view);

    // Only the history stack is reset -- the two-step reconfigure targets exclusively the
    // "history$" field, so the document itself and every OTHER plugin's state (here,
    // block-id-plugin's id assignments), since their object identity never changes across
    // either reconfigure step, must be untouched.
    const idsAfterClear = new Map(getAllBlockIds());
    expect(idsAfterClear).toEqual(idsBeforeClear);
    expect(view.state.doc.toString()).toBe(docAfterEdit);
    expect(view.state.doc.toString()).not.toBe(docBefore);
  });
});

describe('resetForProjectSwitch: Milkdown history must not survive a project switch', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    resetBlockIdState();
    resetBlockSyncState();
    setSyncPaused(false);
  });

  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(blockIdPlugin)
      .use(commonmark)
      .use(gfm)
      .use(historyPlugin)
      .create();
    editor = e;
    setEditorInstance(e);
    return e;
  }

  it('zeroes undo depth left over from the outgoing project (pre-existing bug this closes)', async () => {
    const e = await makeEditor('Project A content.');
    const view = e.ctx.get(editorViewCtx);

    // A real, tracked edit in project A -- exactly what would otherwise leave a stale,
    // rebased undo step reachable after the switch to project B.
    view.dispatch(view.state.tr.insertText('X'));
    expect(undoDepth(view.state)).toBeGreaterThan(0);

    resetForProjectSwitch();

    expect(undoDepth(view.state)).toBe(0);
  });

  it('clears history before the doc-clearing transaction runs, not after (ordering fix)', async () => {
    const e = await makeEditor('Project A content.');
    const view = e.ctx.get(editorViewCtx);
    expect(view.state.doc.textContent).toBe('Project A content.');

    let historyClearDocSnapshot: string | undefined;
    const realUpdateState = view.updateState.bind(view);
    vi.spyOn(view, 'updateState').mockImplementation((state: typeof view.state) => {
      // The plugin ARRAY only changes for clearEditorHistory()'s own updateState() call in
      // this whole function -- the content-clearing transaction's own (separate, internal)
      // updateState() call, triggered by view.dispatch(), keeps the same (already-swapped)
      // plugin array and only changes the doc. Use that to identify which call is which,
      // without assuming anything about prosemirror-view's internal redraw/updateDoc logic.
      if (state.plugins !== view.state.plugins) {
        historyClearDocSnapshot = view.state.doc.textContent;
      }
      realUpdateState(state);
    });

    resetForProjectSwitch();

    // Proof of the reordering: at the moment clearEditorHistory()'s updateState() call landed,
    // the document was still the outgoing project's ORIGINAL content -- not yet cleared. If
    // clearEditorHistory() ran AFTER the doc-clearing dispatch (the pre-fix ordering), this
    // would instead already be the empty post-clear document, and updateState() would be
    // handed a state whose plugin array changed AND whose doc differs from what's already
    // rendered in the same call -- exactly the combination the neighboring
    // "preserves ProseMirror's internal layout caches" comment says to avoid.
    expect(historyClearDocSnapshot).toBe('Project A content.');

    vi.restoreAllMocks();
  });

  it('clears the document -- newly-live behavior, not previously-working behavior this fix left alone', async () => {
    const e = await makeEditor('Project A content.');
    const view = e.ctx.get(editorViewCtx);

    resetForProjectSwitch();

    // resetForProjectSwitch() is SUPPOSED to replace the doc with a single empty paragraph --
    // but per the comment in api-content.ts's resetForProjectSwitch(), the pre-existing
    // selection bug fixed alongside the history-clear meant this transaction always threw and
    // was silently swallowed by the catch block, so this doc-clearing effect never actually
    // ran on any real project switch before this fix. This assertion is checking newly-live
    // behavior, not re-confirming something that already worked.
    expect(view.state.doc.childCount).toBe(1);
    expect(view.state.doc.textContent).toBe('');
  });
});
