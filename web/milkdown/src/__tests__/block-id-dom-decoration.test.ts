// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { undoDepth } from '@milkdown/kit/prose/history';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { confirmBlockIdsApi, setContent, setContentWithBlockIds, syncBlockIds } from '../api-content';
import { blockIdPlugin, getAllBlockIds, resetBlockIdState, setBlockIdZoomMode } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';

// Regression coverage for t-623b1713.
//
// `data-block-id` is a ProseMirror Decoration.node built in block-id-plugin's
// `decorations(state)` prop from the module-level `currentBlockIds` Map
// (block-id-plugin.ts:996-1004). ProseMirror only recomputes decorations when a
// transaction reaches the view. Several Swift->JS entry points mutate that Map
// directly, between transactions -- so the Map holds the correct ids while the DOM
// keeps rendering whatever the previous dispatch painted (usually fresh temp- ids).
//
// Every pre-existing block-id test asserts on getAllBlockIds() -- the Map, which is
// always correct. These are the first to assert on the rendered DOM, which is what
// DOM consumers (e.g. the Cmd-click-zoom handler in t-e6d9bb37) actually read.

const domIds = (view: { dom: HTMLElement }): (string | null)[] =>
  Array.from(view.dom.querySelectorAll('[data-block-id]')).map((el) => el.getAttribute('data-block-id'));

const mapIds = (): string[] =>
  Array.from(getAllBlockIds().entries())
    .sort((a, b) => a[0] - b[0])
    .map(([, id]) => id);

describe('data-block-id decoration stays in sync with the block-ID map', () => {
  let editor: Editor | null = null;

  // Teardown mirrors clear-history.test.ts:29-38, PLUS setBlockIdZoomMode(false):
  // resetBlockIdState() clears the id/type/confirmation Maps but does NOT reset the
  // module-level blockIdZoomMode flag (block-id-plugin.ts:117-124), and
  // setContentWithBlockIds writes that flag on every call -- so without this line a
  // case here can poison an unrelated later test in the same run.
  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    resetBlockIdState();
    resetBlockSyncState();
    setSyncPaused(false);
    setBlockIdZoomMode(false);
  });

  // Plugin order mirrors main.ts's production registration (blockIdPlugin/blockSyncPlugin
  // BEFORE commonmark/gfm, highlightPlugin AFTER commonmark/gfm, history last) -- see
  // clear-history.test.ts's makeEditor for the same convention. historyPlugin is included (and
  // not in clear-history.test.ts's own subset) so this file's undoDepth assertion below actually
  // exercises a real history plugin instead of trivially returning 0 with none registered.
  async function makeEditor(markdown: string): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    editor = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .use(blockIdPlugin)
      .use(blockSyncPlugin)
      .use(commonmark)
      .use(gfm)
      .use(highlightPlugin)
      .use(historyPlugin)
      .create();
    return editor;
  }

  // Site 1 -- confirmBlockIdsApi. Swift calls this after every insert flush
  // (BlockSyncService.swift:1136 -> :736); applyPendingConfirmations rewrites
  // temp -> permanent in currentBlockIds with no dispatch.
  it('confirmBlockIds repaints data-block-id with the permanent ids', async () => {
    const ed = await makeEditor('# Heading\n\nBody text.');
    setEditorInstance(ed);
    const view = ed.ctx.get(editorViewCtx);

    const provisional = mapIds();
    expect(provisional.length).toBe(2);
    expect(domIds(view)).toEqual(provisional); // sane starting point

    confirmBlockIdsApi({
      [provisional[0]]: 'perm-heading-id',
      [provisional[1]]: 'perm-body-id',
    });

    expect(mapIds()).toEqual(['perm-heading-id', 'perm-body-id']); // Map was always right
    expect(domIds(view)).toEqual(['perm-heading-id', 'perm-body-id']); // DOM is what regressed
    // redecorateBlockIds's central safety claim (see its doc comment in api-content.ts): the
    // stepless dispatch does not pollute undo/redo history. No tracked edit happened before
    // this call, so the baseline is 0 -- same convention as clear-history.test.ts.
    expect(undoDepth(view.state)).toBe(0);
  });

  // Sites 2 + 3 -- setContentWithBlockIds, both branches.
  it('setContentWithBlockIds renders real UUIDs, and clearing to empty strands nothing', async () => {
    const ed = await makeEditor('Placeholder.');
    setEditorInstance(ed);
    const view = ed.ctx.get(editorViewCtx);

    // setContentWithBlockIds ends by scheduling a requestAnimationFrame (deferredSnapshotAndUnpause,
    // api-content.ts) that reads the editor instance when it fires. Left un-flushed, that rAF
    // could fire mid-`editor.destroy()` in this file's shared afterEach and touch a torn-down
    // instance. Fake timers + an explicit flush make the two calls below deterministic instead --
    // same established pattern as block-sync-pause-race.test.ts.
    vi.useFakeTimers();
    try {
      // Main branch (site 3) -- the document-open repro.
      setContentWithBlockIds('# Heading\n\nBody text.', ['real-heading-id', 'real-body-id']);
      expect(mapIds()).toEqual(['real-heading-id', 'real-body-id']);
      expect(domIds(view)).toEqual(['real-heading-id', 'real-body-id']);

      // Empty branch (site 2) -- dispatches, THEN clearBlockIds(), then returns.
      setContentWithBlockIds('', []);
      expect(mapIds()).toEqual([]);
      expect(domIds(view)).toEqual([]); // no stale attributes left behind

      // Flush both calls' deferred rAF before this test (and its afterEach) proceeds.
      await vi.runOnlyPendingTimersAsync();
    } finally {
      vi.useRealTimers();
    }
  });

  // Site 4 -- syncBlockIds. Seeds ids and calls resetAndSnapshot (which does NOT
  // dispatch), with no doc change anywhere in the path.
  //
  // Scoped deliberately to the non-zoom case: the fixture has no zoom_notes_marker
  // node, so zoomNotesBoundary never engages and a zoomMode:true variant here would
  // assert nothing zoom-specific. Real zoom-mode behaviour is already owned by
  // __tests__/block-id-zoom-suppression.test.ts.
  it('syncBlockIds repaints data-block-id with no intervening doc change', async () => {
    const ed = await makeEditor('# Heading\n\nBody text.');
    setEditorInstance(ed);
    const view = ed.ctx.get(editorViewCtx);

    expect(domIds(view)).not.toContain('sync-heading-id'); // precondition

    syncBlockIds(['sync-heading-id', 'sync-body-id'], false);

    expect(mapIds()).toEqual(['sync-heading-id', 'sync-body-id']);
    expect(domIds(view)).toEqual(['sync-heading-id', 'sync-body-id']);
  });

  // Must-fix G (review-fix round): proves the `data-managed` mechanism itself -- applied on a
  // managed push, REMOVED on a later push that no longer flags the same block as managed. This
  // is the test that would have caught must-fix B: setContent() (a plain, non-block-id push)
  // used to leave block-id-plugin's managedBlockIds set untouched, so a `data-managed` flag
  // minted by an earlier setContentWithBlockIds() push could survive stale onto content
  // setContent() itself never flagged as managed. See setContent()'s and applyBlocks()'s own
  // setManagedBlockIds([]) calls (api-content.ts) and setManagedBlockIds's doc comment
  // (block-id-plugin.ts).
  it('data-managed is applied on a managed push and cleared by a later plain setContent() push', async () => {
    const ed = await makeEditor('Placeholder.');
    setEditorInstance(ed);
    const view = ed.ctx.get(editorViewCtx);

    const isManaged = (id: string): boolean =>
      view.dom.querySelector(`[data-block-id="${id}"]`)?.hasAttribute('data-managed') ?? false;

    vi.useFakeTimers();
    try {
      // Authoritative push: Swift flags the heading (but not the body) as managed.
      setContentWithBlockIds('# Bibliography\n\nRef A.', ['bib-id', 'body-id'], {
        managedBlockIds: ['bib-id'],
      });
      expect(isManaged('bib-id')).toBe(true);
      expect(isManaged('body-id')).toBe(false);

      // A later plain, non-block-id push (the MilkdownEditor.setContent -> api-content.setContent
      // path every content-binding change short of a full block-id push goes through) reclaims
      // the SAME heading id via ordinary position/type matching -- the heading text is
      // unchanged, only the body differs, so block count and structure are unchanged and
      // block-id-plugin's phase1CanClaim reattaches 'bib-id' to the same heading node -- but
      // this push carries no managed-id information of its own. `data-managed` must not survive
      // stale on that id.
      setContent('# Bibliography\n\nRef B.');
      expect(isManaged('bib-id')).toBe(false);

      await vi.runOnlyPendingTimersAsync();
    } finally {
      vi.useRealTimers();
    }
  });
});
