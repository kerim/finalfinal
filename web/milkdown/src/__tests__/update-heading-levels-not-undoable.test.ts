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
import { noteTransactionForEditSpanTracking, resetRecentUserEditSpanForTests } from '../recent-edit-span';

// Regression test for the addToHistory classification of hierarchy enforcement
// (unified-undo plan, Phase 1 / §2, then widened by P3 of the undo-mode-switch-focus
// second-timing-gap fix): updateHeadingLevels() is a native hierarchy-enforcement push
// (ContentView+HierarchyEnforcement.swift calling through to here), not a user edit.
//
// DELIBERATE, USER-APPROVED BEHAVIOR CHANGE (not a regression) as of the second
// timing-gap fix: when a correction OVERLAPS text the user just typed, it is now dispatched
// as its own undoable step (closeHistory + a `derivedCorrection` tag, NOT
// addToHistory:false) instead of being silently skipped -- see api-content.ts's
// updateHeadingLevels doc comment for the full rationale. A NON-overlapping correction is
// UNCHANGED: still never reaches the undo stack at all, exactly as this file's original
// single test proved. This file is split into one test per behavior.
//
// This bare test harness never calls `initEditor()` (main.ts), so the real `view.dispatch`
// override that wires `noteTransactionForEditSpanTracking` into every transaction is never
// installed here -- tests that need overlap detection call it manually right after each
// simulated "real user edit" dispatch, mirroring exactly what that override does in
// production.

describe('updateHeadingLevels: hierarchy enforcement undo-stack behavior', () => {
  afterEach(() => {
    vi.useRealTimers();
    setEditorInstance(null);
    resetBlockSyncState();
    resetRecentUserEditSpanForTests();
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

  it('non-overlapping: undo reverts only the preceding user edit -- hierarchy enforcement is not on the undo stack at all', async () => {
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

    // A REAL, tracked user edit (default addToHistory: true) in a DIFFERENT node than the
    // one about to be corrected -- the exact real-world sequence is: the user types, THEN
    // Swift's native hierarchy enforcement fires afterward, somewhere else in the document.
    const userTr = view.state.tr.insertText('X', bodyPos! + 1);
    view.dispatch(userTr);
    noteTransactionForEditSpanTracking(userTr); // mirrors main.ts's real dispatch override
    expect(bodyParagraphText()).toBe('XBody text.');

    // Mirrors what Swift's hierarchy enforcement does: demote a heading whose level no
    // longer fits the document's outline, without any user action, and NOT overlapping
    // where the user just typed.
    updateHeadingLevels([{ blockId: deepHeadingId!, newLevel: 2 }]);
    expect(levelOfDeepHeading()).toBe(2);

    // Non-overlapping: dispatched addToHistory:false, so it never entered the
    // prosemirror-history undo stack -- the ONLY thing undo() finds is the user's typed
    // edit from before the enforcement ran. Undoing it must succeed and revert ONLY that
    // edit; the enforced heading level must survive untouched.
    const undone = undo(view.state, view.dispatch);
    expect(undone).toBe(true);
    expect(bodyParagraphText()).toBe('Body text.');
    expect(levelOfDeepHeading()).toBe(2);

    await vi.runOnlyPendingTimersAsync();
  });

  it('overlapping: hierarchy enforcement on a heading the user just edited becomes its own undoable step, and does not absorb subsequent typing (trailing boundary)', async () => {
    const editor = await makeEditor('# Top\n\n### Deep');
    setEditorInstance(editor);
    vi.useFakeTimers();

    const view = editor.ctx.get(editorViewCtx);
    const idsByPos = getAllBlockIds();

    let deepHeadingId: string | undefined;
    let deepHeadingPos: number | undefined;
    view.state.doc.forEach((node, pos) => {
      if (node.type.name === 'heading' && node.textContent === 'Deep') {
        deepHeadingId = idsByPos.get(pos);
        deepHeadingPos = pos;
      }
    });
    expect(deepHeadingId).toBeDefined();
    expect(deepHeadingPos).toBeDefined();

    function headingText(): string | undefined {
      let text: string | undefined;
      view.state.doc.forEach((node) => {
        if (node.type.name === 'heading') text = node.textContent;
      });
      return text;
    }
    function headingLevel(): number | undefined {
      let level: number | undefined;
      view.state.doc.forEach((node) => {
        if (node.type.name === 'heading') level = node.attrs.level;
      });
      return level;
    }

    expect(headingLevel()).toBe(3);

    // User types INSIDE the heading node that hierarchy enforcement is about to correct --
    // the overlap case.
    const userTr = view.state.tr.insertText('X', deepHeadingPos! + 1);
    view.dispatch(userTr);
    noteTransactionForEditSpanTracking(userTr);
    expect(headingText()).toBe('XDeep');

    updateHeadingLevels([{ blockId: deepHeadingId!, newLevel: 2 }]);
    expect(headingLevel()).toBe(2);
    expect(headingText()).toBe('XDeep'); // level changed, text untouched

    // Trailing-boundary check: the user resumes typing IMMEDIATELY after the correction,
    // at an adjacent position -- well within prosemirror-history's default 500ms
    // newGroupDelay. If the second, empty closeHistory dispatch didn't run, this would
    // silently join the correction's own undo group instead of starting a fresh one.
    const userTr2 = view.state.tr.insertText('Y', deepHeadingPos! + 1);
    view.dispatch(userTr2);
    noteTransactionForEditSpanTracking(userTr2);
    expect(headingText()).toBe('YXDeep');

    // Undo #1: must revert ONLY the second typed edit ('Y') -- proving it did NOT join the
    // correction's undo group. The correction (level 2) must still be in effect.
    let undone = undo(view.state, view.dispatch);
    expect(undone).toBe(true);
    expect(headingText()).toBe('XDeep');
    expect(headingLevel()).toBe(2);

    // Undo #2: must revert the correction itself, now that it's its own undoable step.
    undone = undo(view.state, view.dispatch);
    expect(undone).toBe(true);
    expect(headingLevel()).toBe(3);
    expect(headingText()).toBe('XDeep'); // the first typed edit is still in effect

    // Undo #3: must revert the first typed edit ('X'), restoring the original document.
    undone = undo(view.state, view.dispatch);
    expect(undone).toBe(true);
    expect(headingText()).toBe('Deep');

    await vi.runOnlyPendingTimersAsync();
  });
});
