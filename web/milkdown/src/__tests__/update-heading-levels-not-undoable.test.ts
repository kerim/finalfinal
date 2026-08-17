// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { undo } from '@milkdown/kit/prose/history';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { updateHeadingLevels } from '../api-content';
import { blockIdPlugin, getAllBlockIds } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';

// Regression test for the one genuine gap in the addToHistory classification
// (unified-undo plan, Phase 1 / §2): updateHeadingLevels() is a native
// hierarchy-enforcement push (ContentView+HierarchyEnforcement.swift calling
// through to here), not a user edit. Every other programmatic dispatch in
// api-content.ts already marks itself addToHistory:false; this one didn't,
// so a heading demotion the user never asked for used to sit on top of the
// undo stack and eat a Cmd-Z that should have undone the user's last real
// edit.

describe('updateHeadingLevels: hierarchy enforcement must not be user-undoable', () => {
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
      .use(history)
      .create();
    return editor;
  }

  it('undo reverts only the preceding user edit -- hierarchy enforcement is not on the undo stack at all', async () => {
    const editor = await makeEditor('# Top\n\nBody text.\n\n### Deep');
    setEditorInstance(editor);
    vi.useFakeTimers();

    const view = editor.ctx.get(editorViewCtx);
    const idsByPos = getAllBlockIds();

    let deepHeadingId: string | undefined;
    let bodyPos: number | undefined;
    view.state.doc.forEach((node, pos) => {
      if (node.type.name === 'heading' && node.textContent === 'Deep') {
        deepHeadingId = idsByPos.get(pos);
      }
      if (node.type.name === 'paragraph' && node.textContent === 'Body text.') {
        bodyPos = pos;
      }
    });
    expect(deepHeadingId).toBeDefined();
    expect(bodyPos).toBeDefined();

    function levelOfDeepHeading(): number | undefined {
      let level: number | undefined;
      view.state.doc.forEach((node) => {
        if (node.type.name === 'heading' && node.textContent === 'Deep') {
          level = node.attrs.level;
        }
      });
      return level;
    }

    function bodyParagraphText(): string | undefined {
      let text: string | undefined;
      view.state.doc.forEach((node) => {
        if (node.type.name === 'paragraph' && node.textContent.endsWith('Body text.')) {
          text = node.textContent;
        }
      });
      return text;
    }

    expect(levelOfDeepHeading()).toBe(3);

    // A REAL, tracked user edit (default addToHistory: true) -- the exact real-world sequence
    // is: the user types, THEN Swift's native hierarchy enforcement fires afterward. Without
    // this edit on the stack, `undo()` returning false is a vacuous pass: a completely missing
    // history plugin would "pass" identically. This is the claim actually under test --
    // undo() must revert ONLY the typed edit, leaving the enforced heading level untouched.
    view.dispatch(view.state.tr.insertText('X', bodyPos! + 1));
    expect(bodyParagraphText()).toBe('XBody text.');

    // Mirrors what Swift's hierarchy enforcement does: demote a heading whose
    // level no longer fits the document's outline, without any user action.
    updateHeadingLevels([{ blockId: deepHeadingId!, newLevel: 2 }]);
    expect(levelOfDeepHeading()).toBe(2);

    // With addToHistory:false, updateHeadingLevels()'s own transaction never entered the
    // prosemirror-history undo stack -- the ONLY thing undo() finds is the user's typed edit
    // from before the enforcement ran. Undoing it must succeed (undone === true) and revert
    // ONLY that edit; the enforced heading level must survive untouched.
    const undone = undo(view.state, view.dispatch);
    expect(undone).toBe(true);
    expect(bodyParagraphText()).toBe('Body text.');
    expect(levelOfDeepHeading()).toBe(2);

    await vi.runOnlyPendingTimersAsync();
  });
});
