// @vitest-environment jsdom
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { setContentWithBlockIds, topLevelBlockStarts } from '../api-content';
import { blockIdPlugin } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';

// Regression tests for the cursor-restore clamp in setContentWithBlockIds()
// (api-content.ts). The clamp exists to stop the user's cursor from landing
// inside a machine-generated bibliography paragraph (see
// docs/findings/bibliography-id-theft-corruption.md, "Round 2: Cursor
// clamping at bibliography boundary") — but the original implementation only
// took a START boundary (cursorBoundary / bibPos) and clamped any cursor
// AT-OR-AFTER it, unconditionally. Once a regenerated bibliography could be
// reinserted at a mid-document anchor instead of always landing at the
// document's end (BibliographySyncService.updateBibliographyBlock), that
// unconditional clamp yanked the user's cursor backward out of real trailing
// content that legitimately sits AFTER the bibliography — a HIGH-severity
// regression.
//
// The fix threads a second boundary, cursorBoundaryEnd (bibEndPos), so the
// clamp only fires when the cursor falls INSIDE the bibliography's own
// [bibPos, bibEndPos) range, not merely at-or-past bibPos.
//
// These cases pin the fix directly against the real setContentWithBlockIds
// implementation (not a reimplementation of its clamp math):
//   A. cursor in trailing content AFTER the bibliography — must NOT clamp
//      (the exact scenario that was broken before this round's fix).
//   B. cursor INSIDE the bibliography's own range — must still clamp
//      (confirms the fix didn't break the clamp's original purpose).
//   C. cursorBoundaryEnd omitted (old call shape) — degrades to the old
//      unconditional at-or-after-bibPos behavior, since the bibliography
//      runs to the document's end in that case.

describe('setContentWithBlockIds cursor-restore clamp — cursorBoundary/cursorBoundaryEnd', () => {
  afterEach(() => {
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

  function placeCursor(view: EditorView, pos: number): void {
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)));
  }

  // A bibliography section (heading + two entries) with real trailing user
  // content AFTER it — the shape that only became possible once a
  // regenerated bibliography could be reinserted back at a mid-document
  // anchor instead of always being appended at the document's end.
  const DOC_WITH_TRAILING_CONTENT =
    'Intro paragraph before the bibliography.\n\n' +
    '# References\n\n' +
    'Smith, J. (2020). First entry.\n\n' +
    'Jones, A. (2021). Second entry.\n\n' +
    'Trailing paragraph after the bibliography.';
  // Top-level node indices: 0 intro, 1 heading, 2 entry, 3 entry, 4 trailing.
  const BIB_START_INDEX = 1;
  const BIB_END_INDEX = 4; // one PAST the last entry (index 3) — lastBibliographyNodeIndex's contract

  it('Case A: a cursor in trailing content AFTER the bibliography survives unmoved (not clamped)', async () => {
    const editor = await makeEditor(DOC_WITH_TRAILING_CONTENT);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const starts = topLevelBlockStarts(view.state.doc);
    const bibEndPos = starts[BIB_END_INDEX];
    // A few characters into the trailing paragraph's own text — past bibEndPos.
    const trailingCursorPos = bibEndPos + 5;
    placeCursor(view, trailingCursorPos);

    setContentWithBlockIds(DOC_WITH_TRAILING_CONTENT, [], {
      cursorBoundary: BIB_START_INDEX,
      cursorBoundaryEnd: BIB_END_INDEX,
    });

    expect(view.state.selection.from).toBe(trailingCursorPos);
  });

  it('Case B: a cursor INSIDE the bibliography range still gets clamped to just before it', async () => {
    const editor = await makeEditor(DOC_WITH_TRAILING_CONTENT);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const starts = topLevelBlockStarts(view.state.doc);
    const bibPos = starts[BIB_START_INDEX];
    // A few characters into the bibliography heading's own text — inside [bibPos, bibEndPos).
    const insideBibCursorPos = bibPos + 3;
    placeCursor(view, insideBibCursorPos);

    setContentWithBlockIds(DOC_WITH_TRAILING_CONTENT, [], {
      cursorBoundary: BIB_START_INDEX,
      cursorBoundaryEnd: BIB_END_INDEX,
    });

    expect(view.state.selection.from).toBe(bibPos - 1);
  });

  it('Case C: cursorBoundaryEnd omitted degrades to the old unconditional at-or-after-bibPos clamp', async () => {
    // No trailing content: the bibliography IS the last thing in the document,
    // matching every call site that predates cursorBoundaryEnd.
    const docNoTrailing =
      'Intro paragraph before the bibliography.\n\n' +
      '# References\n\n' +
      'Smith, J. (2020). First entry.\n\n' +
      'Jones, A. (2021). Second entry.';

    const editor = await makeEditor(docNoTrailing);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const starts = topLevelBlockStarts(view.state.doc);
    const bibPos = starts[BIB_START_INDEX];
    // Inside the LAST bibliography entry, close to the document's end.
    const lastEntryIndex = 3;
    const insideLastEntryPos = starts[lastEntryIndex] + 3;
    placeCursor(view, insideLastEntryPos);

    setContentWithBlockIds(docNoTrailing, [], {
      cursorBoundary: BIB_START_INDEX,
      // cursorBoundaryEnd intentionally omitted.
    });

    expect(view.state.selection.from).toBe(bibPos - 1);
  });
});
