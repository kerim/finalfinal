// @vitest-environment jsdom
// Regression test for t-18576cf7: "Documents open blank, then unstyled, when opened from the
// Open command." A project-open content push (setContentWithBlockIds) can arrive before
// main.ts's async Editor.make().create() resolves -- e.g. a freshly-claimed/created Milkdown
// WebView whose `didFinish`/`.ready` (page load) fires well before the editor instance exists.
// The old code stashed only the markdown string (setCurrentContent) and replayed it through
// setContent() post-mount -- but setContent()'s own `getCurrentContent() === markdown`
// early-return guard always matched that exact value, so the replay silently no-op'd and the
// document stayed empty. This fix stashes the FULL argument set (markdown, blockIds, options)
// and replays through setContentWithBlockIds() itself, which has no such guard.

import { defaultValueCtx, Editor, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import {
  replayPendingPreMountContent,
  resetForProjectSwitch,
  setContent,
  setContentWithBlockIds,
} from '../api-content';
import { blockIdPlugin, getAllBlockIds, resetBlockIdState } from '../block-id-plugin';
import { resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { citationPlugin } from '../citation-plugin';
import {
  getCurrentContent,
  getPendingBlockContent,
  isEditorMounted,
  setEditorInstance,
  setEditorMounted,
  setPendingBlockContent,
} from '../editor-state';

describe('pre-mount content push (t-18576cf7)', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    setEditorMounted(false);
    setPendingBlockContent(null);
    resetBlockIdState();
    resetBlockSyncState();
    setSyncPaused(false);
  });

  // Mirrors main.ts's real registration order for these plugins (blockIdPlugin before
  // citationPlugin, both before commonmark/gfm, history last) -- same pattern as
  // block-diff.test.ts's makeEditor. Deliberately does NOT call setEditorInstance() or
  // setEditorMounted() itself -- callers below control exactly when "mount" happens, since
  // that ordering is the whole point of this test.
  async function makeEditor(): Promise<Editor> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, '');
      })
      .use(blockIdPlugin)
      .use(citationPlugin)
      .use(commonmark)
      .use(gfm)
      .use(history)
      .create();
    editor = e;
    return e;
  }

  function docText(e: Editor): string {
    return e.action(getMarkdown());
  }

  it('isEditorMounted() is false before mount, true after -- setEditorInstance alone does not flip it', async () => {
    expect(isEditorMounted()).toBe(false);
    const e = await makeEditor();
    setEditorInstance(e);
    // setEditorInstance() runs before main.ts's root.appendChild(...) -- isEditorMounted()
    // must still read false at this point, or the gate this fix adds means nothing.
    expect(isEditorMounted()).toBe(false);
    setEditorMounted(true);
    expect(isEditorMounted()).toBe(true);
  });

  it('stashes the full argument set (not just markdown) when no editor instance exists, and renders nothing', () => {
    setEditorInstance(null);
    const markdown = '# Heading\n\nBody text.';
    const blockIds = ['block-aaa', 'block-bbb'];
    const options = {
      imageMeta: [{ id: 'img-1', width: 200 }],
      expected: [{ blockType: 'heading', nonEmpty: true }],
    };

    setContentWithBlockIds(markdown, blockIds, options);

    expect(getCurrentContent()).toBe(markdown); // other readers still expect this
    const pending = getPendingBlockContent();
    expect(pending).not.toBeNull();
    expect(pending?.markdown).toBe(markdown);
    expect(pending?.blockIds).toEqual(blockIds);
    expect(pending?.options).toEqual(options);
  });

  it('a pre-mount push replayed the OLD way (through setContent()) left the document empty -- the regression this fix closes', async () => {
    const e = await makeEditor();
    const markdown = '# Heading\n\nBody text.';

    setEditorInstance(null); // pre-mount: no instance yet
    setContentWithBlockIds(markdown, ['block-aaa'], undefined);

    setEditorInstance(e); // "mount" happens
    setEditorMounted(true);

    // The OLD main.ts replay: getCurrentContent() straight into setContent(), which early-
    // returns whenever `getCurrentContent() === markdown` -- always true here, since the
    // stash above set it to this exact string via setCurrentContent(). Nothing renders.
    const currentContent = getCurrentContent();
    if (currentContent?.trim()) {
      setContent(currentContent);
    }

    expect(docText(e).trim()).toBe('');
  });

  // M20: calls the REAL production replay function (replayPendingPreMountContent, exported
  // from api-content.ts and used by main.ts's post-mount code) instead of hand-copying its
  // logic inline -- a future regression in that function would actually fail this test.
  it('replayPendingPreMountContent() replays the stashed push through setContentWithBlockIds after mount, preserving markdown and block IDs in document order, then clears the stash', async () => {
    const markdown = '# Heading\n\nBody text.';
    const blockIds = ['block-aaa', 'block-bbb'];

    setEditorInstance(null); // pre-mount
    setContentWithBlockIds(markdown, blockIds, undefined);
    expect(getPendingBlockContent()).not.toBeNull();

    const e = await makeEditor();
    setEditorInstance(e);
    setEditorMounted(true);

    // Replay path, exactly as main.ts's post-mount code now does (M8: after mount AND after
    // view.dispatch is patched -- irrelevant to this test, which only exercises the replay
    // function itself against the real editor instance).
    replayPendingPreMountContent();

    const rendered = docText(e).trim();
    expect(rendered).not.toBe('');
    expect(rendered).toContain('Heading');
    expect(rendered).toContain('Body text');

    const ids = Array.from(getAllBlockIds().entries())
      .sort((a, b) => a[0] - b[0])
      .map(([, id]) => id);
    expect(ids).toEqual(blockIds);

    // Fire-once: cleared before the call, so a second mount can't double-push.
    expect(getPendingBlockContent()).toBeNull();
  });

  // M20: same real production function, exercising its `else` branch (no pendingBlockContent
  // -- only a legacy plain-setContent stash in currentContent).
  it('replayPendingPreMountContent() replays a legacy plain setContent() stash through setContent when no block-ID push is pending', async () => {
    const markdown = '# Plain Heading\n\nPlain body.';

    setEditorInstance(null); // pre-mount
    setContent(markdown);
    expect(getPendingBlockContent()).toBeNull();
    expect(getCurrentContent()).toBe(markdown);

    const e = await makeEditor();
    setEditorInstance(e);
    setEditorMounted(true);

    replayPendingPreMountContent();

    const rendered = docText(e).trim();
    expect(rendered).toContain('Plain Heading');
    expect(rendered).toContain('Plain body');
  });

  // MF2: a pendingBlockContent stash left over from the project being switched AWAY FROM must
  // not survive into the next one -- otherwise a later mount (or a delayed replay) would
  // resurrect the PREVIOUS project's content instead of the new project's.
  it('resetForProjectSwitch() clears a pending pre-mount block-content stash', () => {
    setEditorInstance(null); // pre-mount
    setContentWithBlockIds('# Old project heading', ['block-old'], undefined);
    expect(getPendingBlockContent()).not.toBeNull();

    resetForProjectSwitch();

    expect(getPendingBlockContent()).toBeNull();
  });

  // MF3: the two pre-mount stashes (pendingBlockContent, currentContent) must resolve by
  // ARRIVAL ORDER, not by which kind of call happened to write them -- replayPendingPreMountContent
  // unconditionally prefers pendingBlockContent when present, so a plain setContent() call that
  // arrives AFTER an earlier setContentWithBlockIds() stash must clear it, or the older,
  // block-ID-bearing content would incorrectly win the replay over this newer plain push.
  it('a later plain setContent() call wins over an earlier setContentWithBlockIds() stash (last write wins)', async () => {
    setEditorInstance(null); // pre-mount
    setContentWithBlockIds('# Old block-ID push', ['block-old'], undefined);
    expect(getPendingBlockContent()).not.toBeNull();

    // A later, different plain push arrives -- must win the replay.
    setContent('# Newer plain push');
    expect(getPendingBlockContent()).toBeNull(); // MF3 fix: cleared by the later plain write

    const e = await makeEditor();
    setEditorInstance(e);
    setEditorMounted(true);

    replayPendingPreMountContent();

    const rendered = docText(e).trim();
    expect(rendered).toContain('Newer plain push');
    expect(rendered).not.toContain('Old block-ID push');
  });

  // MF3, reverse ordering: a setContentWithBlockIds() call that arrives AFTER an earlier plain
  // setContent() stash must win -- already correct before this round's fix (setContentWithBlockIds's
  // no-instance branch always overwrites both stashes), pinned here so a future change can't
  // silently regress this direction while fixing the other one.
  it('a later setContentWithBlockIds() call wins over an earlier plain setContent() stash (last write wins)', async () => {
    setEditorInstance(null); // pre-mount
    setContent('# Old plain push');
    expect(getPendingBlockContent()).toBeNull();

    setContentWithBlockIds('# Newer block-ID push', ['block-new'], undefined);
    expect(getPendingBlockContent()?.markdown).toBe('# Newer block-ID push');

    const e = await makeEditor();
    setEditorInstance(e);
    setEditorMounted(true);

    replayPendingPreMountContent();

    const rendered = docText(e).trim();
    expect(rendered).toContain('Newer block-ID push');
    expect(rendered).not.toContain('Old plain push');
  });
});
