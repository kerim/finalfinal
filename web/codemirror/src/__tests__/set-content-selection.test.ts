// @vitest-environment jsdom
// Regression tests for setContent()'s selection/scroll-anchor behavior in api.ts.
//
// The bug this hardens against: setContent() used to unconditionally dispatch a
// whole-document replace (`from: 0, to: doc.length`). CodeMirror maps any selection
// inside a fully-replaced range to the START of the replacement, so the cursor (and
// therefore the scroll anchor) silently teleported to document position 0 on every
// derived-content push -- e.g. the bibliography-section rebuild that follows a citation
// insert in Source Mode, which is what actually surfaced this as a user-visible bug
// (see text-diff.ts's doc comment for the full mechanism).
//
// Uses a real CodeMirror EditorView (not a bare EditorState) via the same harness
// pattern as cayw-position-race.test.ts, since setContent() operates on the module-level
// `editorView` singleton via getEditorView()/setEditorView().
//
// Caveat: jsdom has no real layout engine, so these tests prove the selection-
// preservation MECHANISM (where CodeMirror's selection/cursor ends up after a dispatch),
// not the actual visual scroll pixel position -- that needs manual/e2e verification
// separately (see the report's user-verification steps).

import { history, undoDepth } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorState, type Extension } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterEach, beforeAll, describe, expect, it } from 'vitest';
import { resetForProjectSwitch, scrollToOffset, setContent } from '../api';
import { setEditorExtensions, setEditorView } from '../editor-state';

// jsdom has no real layout engine and doesn't implement Range.prototype.getBoundingClientRect
// (unlike Element.prototype.getBoundingClientRect, which it stubs to an all-zero rect).
// resetForProjectSwitch() installs line-height-fix.ts, which measures dummy elements via
// the Range API to compute per-heading-level character widths. Polyfill it to a zeroed
// DOMRect so that measurement path doesn't throw in this headless environment -- the
// resulting zero widths don't affect anything these tests assert on (selection/scroll
// anchor position), only real-browser layout metrics this suite doesn't exercise.
beforeAll(() => {
  if (typeof Range !== 'undefined' && !Range.prototype.getBoundingClientRect) {
    Range.prototype.getBoundingClientRect = function (this: Range): DOMRect {
      return {
        x: 0,
        y: 0,
        width: 0,
        height: 0,
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        toJSON() {
          return {};
        },
      } as DOMRect;
    };
  }
});

describe('setContent() selection/scroll-anchor preservation', () => {
  let view: EditorView | null = null;

  afterEach(() => {
    setEditorView(null);
    setEditorExtensions([]);
    if (view) {
      view.destroy();
      view = null;
    }
  });

  function makeEditor(doc: string, extraExtensions: Extension[] = []): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const extensions: Extension[] = [markdown({ base: markdownLanguage }), ...extraExtensions];
    const v = new EditorView({
      state: EditorState.create({ doc, extensions }),
      parent: div,
    });
    view = v;
    setEditorView(v);
    // So resetForProjectSwitch()'s EditorState.create(...) rebuilds with the same
    // extensions instead of an empty array (mirrors main.ts's production wiring, where
    // setEditorExtensions() is called once at init and reused by resetForProjectSwitch).
    setEditorExtensions(extensions);
    return v;
  }

  // ---- 1: bibliography resync preserves cursor (direct regression test) ----

  it('preserves cursor position across a bibliography-resync-shaped tail change', () => {
    const bodyPrefix = `${'A'.repeat(300)}\n\n# Body Heading\n\n`;
    const bodyText = 'Some long body text the cursor sits in the middle of, well before the bibliography.';
    const oldBib = '# References\n\nOld entry (2020).';
    const oldDoc = `${bodyPrefix}${bodyText}\n\n${oldBib}`;
    const v = makeEditor(oldDoc);

    const cursorPos = oldDoc.indexOf('middle');
    expect(cursorPos).toBeGreaterThan(-1);
    v.dispatch({ selection: { anchor: cursorPos } });
    expect(v.state.selection.main.head).toBe(cursorPos);

    const newBib = '# References\n\nNew entry (2021).\n\nAnother entry (2022).';
    const newDoc = `${bodyPrefix}${bodyText}\n\n${newBib}`;
    setContent(newDoc);

    expect(v.state.doc.toString()).toBe(newDoc);
    expect(v.state.selection.main.head).toBe(cursorPos);
  });

  // ---- 2: push stays out of undo history ----

  it('does not add the push to undo history', () => {
    const v = makeEditor('Original content.', [history()]);
    const depthBefore = undoDepth(v.state);

    setContent('Original content, changed at the tail.');

    expect(undoDepth(v.state)).toBe(depthBefore);
  });

  // ---- 3: resetForProjectSwitch() itself still zeroes selection before setContent runs ----
  //
  // This is a DIFFERENT, independent guarantee from the diff fix: resetForProjectSwitch()
  // rebuilds EditorState with no explicit selection (defaulting to 0) BEFORE setContent()
  // ever pushes the new project's content -- so by the time setContent() runs, there's
  // nothing for the diff to preserve. This test intentionally does NOT exercise
  // setContent()'s own diff-based selection behavior (see tests 4-5 below for that) --
  // it only confirms production's actual call order (resetForProjectSwitch(), then
  // setContent()) still produces the right end state.
  it('resetForProjectSwitch() zeroes selection before setContent() ever runs, and the switch still ends up with the right content', () => {
    const v = makeEditor('Old project content.\n\nWith a cursor position marker here.');
    const cursorPos = v.state.doc.toString().indexOf('marker');
    v.dispatch({ selection: { anchor: cursorPos } });
    expect(v.state.selection.main.head).toBe(cursorPos);

    // Mirrors production: ContentView+ProjectLifecycle.swift's handleProjectOpened()
    // calls resetForProjectSwitch() via JS eval BEFORE the new project's content is
    // ever pushed via setContent().
    resetForProjectSwitch();
    expect(v.state.selection.main.head).toBe(0);

    const newDoc = 'Completely unrelated new project document text, nothing shared with the old one.';
    setContent(newDoc);

    expect(v.state.doc.toString()).toBe(newDoc);
    // The property this test's name actually promises ("ends up with the right
    // content") includes the selection staying sane too, not just the text. Since
    // resetForProjectSwitch() already zeroed the selection and the pushed document
    // shares no prefix with the old one, computeMinimalChange degrades to a
    // whole-document replace starting at 0 -- so the already-zeroed cursor has
    // nothing to preserve and correctly stays at 0. A prior version of this test
    // stopped checking selection after resetForProjectSwitch() and never re-checked
    // it here, so it would have missed a regression that left the selection
    // somewhere other than 0 after this setContent() call.
    expect(v.state.selection.main.head).toBe(0);
  });

  // ---- 4 & 5: the REAL diff-related regression surface for project switch ----
  //
  // Before this fix, ANY whole-document replace -- including a project switch -- mapped
  // the cursor (and, by construction, the scroll anchor) to position 0 as an incidental
  // side effect of CodeMirror's position mapping. The minimal-diff push no longer
  // guarantees that when the old and new documents happen to share a leading prefix (e.g.
  // two documents both starting with the same generic heading). Production now makes the
  // project-switch scroll reset EXPLICIT instead of relying on that side effect --
  // ContentView+ProjectLifecycle.swift's handleProjectOpened() sets
  // editorState.scrollToOffset = 0 for the Source-Mode path, which CodeMirrorEditor.swift
  // relays via scrollToOffset() (exported from this same api.ts). These two tests exercise
  // that real regression surface directly -- WITHOUT calling resetForProjectSwitch() first,
  // since that call's own unconditional selection-zeroing would mask exactly the behavior
  // under test (this is precisely what made the old version of test 3 above vacuous: it
  // could never fail even if this regression were real).

  it('a shared-prefix document switch no longer incidentally resets the cursor to 0 (documents the accepted behavior change)', () => {
    const sharedPrefix = '# Untitled\n\n';
    const oldDoc = `${sharedPrefix}Old project body text goes here.`;
    const v = makeEditor(oldDoc);

    const cursorPos = oldDoc.indexOf('Old project');
    v.dispatch({ selection: { anchor: cursorPos } });
    expect(v.state.selection.main.head).toBe(cursorPos);

    const newDoc = `${sharedPrefix}Completely different new project body.`;
    setContent(newDoc);

    expect(v.state.doc.toString()).toBe(newDoc);
    // The diff is confined to the tail after the shared prefix, so the cursor maps to
    // where that span starts -- NOT to document position 0. This is the accepted
    // behavior change production now covers with an explicit reset instead (next test).
    expect(v.state.selection.main.head).toBe(sharedPrefix.length);
    expect(v.state.selection.main.head).not.toBe(0);
  });

  it('scrollToOffset(0) -- the mechanism Source-Mode project switch now uses to correct this -- fires an effect-bearing dispatch regardless of where the diff left the cursor', () => {
    const sharedPrefix = '# Untitled\n\n';
    const oldDoc = `${sharedPrefix}Old project body text goes here.`;

    let effectCountSinceReset = 0;
    const v = makeEditor(oldDoc, [
      EditorView.updateListener.of((update) => {
        effectCountSinceReset += update.transactions.reduce((sum, tr) => sum + tr.effects.length, 0);
      }),
    ]);

    const cursorPos = oldDoc.indexOf('Old project');
    v.dispatch({ selection: { anchor: cursorPos } });

    const newDoc = `${sharedPrefix}Completely different new project body.`;
    setContent(newDoc);
    // Sanity check that the reset below is genuinely needed here, not a vacuous no-op --
    // same shared-prefix setup as the test above.
    expect(v.state.selection.main.head).not.toBe(0);

    effectCountSinceReset = 0;
    scrollToOffset(0);

    // jsdom has no real layout engine, so this can't assert on the actual visual scroll
    // pixel position (see file-level comment) -- it confirms the mechanism itself fires:
    // scrollToOffset(0) dispatches a transaction carrying a scrollIntoView effect. Actual
    // on-screen scroll correction needs manual/e2e verification.
    expect(effectCountSinceReset).toBeGreaterThan(0);
  });

  // ---- 6: scrollToStart resets selection to 0 (zoom-transition parity) ----

  it('scrollToStart: true resets selection to 0 even for a small tail edit that would otherwise preserve the cursor', () => {
    const longPrefix = 'A'.repeat(200);
    const v = makeEditor(`${longPrefix}\n\nOld tail text.`);

    // Cursor sits well inside the untouched prefix -- without scrollToStart, an ordinary
    // tail-only change would leave it exactly here (see test 1 above).
    v.dispatch({ selection: { anchor: 5 } });

    setContent(`${longPrefix}\n\nNew tail text, changed.`, { scrollToStart: true });

    expect(v.state.selection.main.head).toBe(0);
  });

  // ---- 7: identical-content push dispatches nothing ----

  it('dispatches nothing when the pushed content is identical to the current document', () => {
    const doc = 'Unchanged content, pushed again.';
    let docChangedCount = 0;
    makeEditor(doc, [
      EditorView.updateListener.of((update) => {
        if (update.docChanged) docChangedCount++;
      }),
    ]);

    setContent(doc);

    expect(docChangedCount).toBe(0);
  });

  // ---- 8: cursor inside the changed span maps to the span start (accepted residual) ----

  it('maps a cursor inside the changed span to the span start, not to document position 0', () => {
    const v = makeEditor('before [MIDDLE] after');
    const spanStart = v.state.doc.toString().indexOf('[MIDDLE]') + 1; // inside the brackets
    const cursorInsideSpan = spanStart + 2; // inside the word MIDDLE

    v.dispatch({ selection: { anchor: cursorInsideSpan } });
    expect(v.state.selection.main.head).toBe(cursorInsideSpan);

    setContent('before [CHANGED] after');

    expect(v.state.doc.toString()).toBe('before [CHANGED] after');
    // Accepted residual documented in api.ts: maps to the start of the replaced span...
    expect(v.state.selection.main.head).toBe(spanStart);
    // ...not to document position 0, which is the bug this fix eliminates.
    expect(v.state.selection.main.head).not.toBe(0);
  });
});
