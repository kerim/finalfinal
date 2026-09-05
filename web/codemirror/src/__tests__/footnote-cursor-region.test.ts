// @vitest-environment jsdom
//
// E2 (Stage E, notes-heading-scanner-unify): tests for `findNotesRegion` and the
// region-anchored `scrollToFootnoteDefinition` in api.ts — replaces a whole-document
// `content.indexOf('[^N]:')` (first match wins, anywhere in the document) with a search
// bounded to the Notes region first, falling back to the whole-document search only on a
// region miss. Companion to
// `../../../milkdown/src/__tests__/footnote-cursor-placement.test.ts` — E5's cross-editor
// contract (both editors land the cursor at the START of the definition's own body text for
// the same document/label) is asserted independently in each file; see that file's own E5
// test for the Milkdown half of the same invariant.
//
// T9: the pre/post-call comparison test below distinguishes "scrollToFootnoteDefinition did
// nothing" from "it actually moved the cursor to the real definition" — a bare "cursor ended
// up inside the def" assertion could pass by accident if the pre-call position happened to
// already be there.

import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { afterEach, describe, expect, it } from 'vitest';
import { findNotesRegion, scrollToFootnoteDefinition } from '../api';
import { setEditorView } from '../editor-state';
import { handleClick } from '../footnote-decoration-plugin';

describe('findNotesRegion', () => {
  it('finds the [start, end) range of a confirmed H1 Notes section', () => {
    const content = 'Intro.\n\n# Notes\n\n[^1]: def one\n\n[^2]: def two';
    const region = findNotesRegion(content);
    expect(region).not.toBeNull();
    expect(content.slice(region!.start, region!.end)).toBe('# Notes\n\n[^1]: def one\n\n[^2]: def two');
  });

  it('confirms an H2 Notes heading the same way (mirrors NotesOpeningSelector H1-or-H2)', () => {
    const content = 'Intro.\n\n## Notes\n\n[^1]: def one';
    const region = findNotesRegion(content);
    expect(region).not.toBeNull();
    expect(content.slice(region!.start, region!.end)).toBe('## Notes\n\n[^1]: def one');
  });

  it('does NOT confirm a heading titled "Notes" with no evidence beneath it', () => {
    const content = 'Intro.\n\n# Notes\n\nJust an ordinary heading with no footnotes.';
    expect(findNotesRegion(content)).toBeNull();
  });

  it('closes the run at the next heading of ANY level, not swallowing trailing content', () => {
    const content = '# Notes\n\n[^1]: def one\n\n## Appendix\n\nTrailing content.';
    const region = findNotesRegion(content);
    expect(region).not.toBeNull();
    expect(content.slice(region!.start, region!.end)).toBe('# Notes\n\n[^1]: def one\n\n');
  });

  it('picks the FIRST confirmed opening in document order when more than one exists (primaryOpening tie rule)', () => {
    const content = '# Notes\n\n[^1]: first run def\n\n## Appendix\n\nBody.\n\n# Notes\n\n[^2]: second run def';
    const region = findNotesRegion(content);
    expect(region).not.toBeNull();
    expect(content.slice(region!.start, region!.end)).toContain('first run def');
    expect(content.slice(region!.start, region!.end)).not.toContain('second run def');
  });

  it('ignores a Notes-heading/evidence-shaped line inside a code fence', () => {
    const content = '```\n# Notes\n\n[^1]: fake, inside a fence\n```\n\n# Notes\n\n[^2]: real definition';
    const region = findNotesRegion(content);
    expect(region).not.toBeNull();
    expect(content.slice(region!.start, region!.end)).toContain('real definition');
    expect(content.slice(region!.start, region!.end)).not.toContain('fake, inside a fence');
  });
});

describe('scrollToFootnoteDefinition — E2 region-anchored cursor placement', () => {
  let view: EditorView | null = null;

  afterEach(() => {
    setEditorView(null);
    if (view) {
      view.destroy();
      view = null;
    }
  });

  function makeEditor(doc: string): EditorView {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const v = new EditorView({
      state: EditorState.create({ doc, extensions: [markdown({ base: markdownLanguage })] }),
      parent: div,
    });
    view = v;
    setEditorView(v);
    return v;
  }

  it('lands the cursor right after "[^N]: " inside the region-bounded match', () => {
    const v = makeEditor('# Notes\n\n[^1]: first def\n\n[^2]: second def');
    scrollToFootnoteDefinition('2');
    const pos = v.state.selection.main.head;
    expect(v.state.doc.sliceString(pos).startsWith('second def')).toBe(true);
  });

  it('E5: lands at the start of the definition body text — the shared cross-editor position contract (see milkdown/src/__tests__/footnote-cursor-placement.test.ts)', () => {
    const v = makeEditor('# Notes\n\n[^1]: alpha\n\n[^2]: beta text');
    scrollToFootnoteDefinition('2');
    const pos = v.state.selection.main.head;
    expect(v.state.doc.sliceString(pos)).toBe('beta text');
  });

  it('E6 (region half): the region-bounded search picks the definition inside the CONFIRMED Notes run, not a same-labeled decoy line outside it', () => {
    // A "[^2]:"-shaped line sitting OUTSIDE any confirmed Notes section (e.g. pasted stray
    // text) must never be picked over the real definition inside the confirmed region — the
    // whole-document indexOf this replaces had no way to avoid exactly this.
    const content =
      'Some stray text.\n\n[^2]: decoy, outside any confirmed Notes run\n\n' +
      '# Notes\n\n[^1]: first\n\n[^2]: real definition';
    const v = makeEditor(content);
    scrollToFootnoteDefinition('2');
    const pos = v.state.selection.main.head;
    expect(v.state.doc.sliceString(pos).startsWith('real definition')).toBe(true);
  });

  it('region miss (no confirmed Notes heading at all) falls back to the whole-document search and still finds the label', () => {
    const v = makeEditor('Body text.\n\n[^3]: stray definition, no Notes heading exists anywhere');
    scrollToFootnoteDefinition('3');
    const pos = v.state.selection.main.head;
    expect(v.state.doc.sliceString(pos).startsWith('stray definition')).toBe(true);
  });

  it('T9: pre/post comparison — a genuine match moves the cursor away from an unrelated pre-call position', () => {
    const v = makeEditor('# Notes\n\n[^1]: first\n\n[^2]: second def');
    const preCallPos = 3; // inside the "# Notes" heading line — nowhere near either definition
    v.dispatch({ selection: { anchor: preCallPos } });
    expect(v.state.selection.main.head).toBe(preCallPos);

    scrollToFootnoteDefinition('2');

    const postCallPos = v.state.selection.main.head;
    expect(postCallPos).not.toBe(preCallPos);
    expect(v.state.doc.sliceString(postCallPos).startsWith('second def')).toBe(true);
  });

  it('T9: NOT_FOUND (label not found anywhere) leaves the cursor at its pre-call value', () => {
    const v = makeEditor('# Notes\n\n[^1]: only def');
    const preCallPos = 3;
    v.dispatch({ selection: { anchor: preCallPos } });

    scrollToFootnoteDefinition('99');

    expect(v.state.selection.main.head).toBe(preCallPos);
  });

  // Regression test for t-fee9dce6: clicking a footnote's number in its definition (the
  // ref-return direction, def -> ref — the reverse of the tests above) used to land the anchor
  // at refMatch.index, the START of "[^N]", which sits BEFORE the marker.
  // footnoteDecorationPlugin's click handler now uses refMatch.index + refMatch[0].length so
  // typing continues the main text right after the marker instead of re-typing over it.
  //
  // This exercises the real `handleClick` from footnote-decoration-plugin.ts — the actual
  // fixed code — rather than duplicating its regex here. jsdom does no real layout, so
  // `posAtCoords` is stubbed to return the click's already-resolved document position (what a
  // real browser's coordinate math would produce for a click landing inside the "[^1]:"
  // prefix); everything downstream, including the fixed anchor computation, runs unmodified.
  it('t-fee9dce6: clicking a definition lands the anchor just past the closing "]" of its reference, not before it', () => {
    const content = 'Body text[^1] tail.\n\n[^1]: the note';
    const v = makeEditor(content);

    const refMatch = /\[\^1\](?!:)/.exec(content);
    expect(refMatch).not.toBeNull();
    const expectedAnchor = refMatch!.index + refMatch![0].length;

    // Click in the middle of the "[^1]:" definition prefix, same region the other tests target.
    const defIndex = content.indexOf('[^1]:', content.indexOf('\n\n') + 2);
    const clickPos = defIndex + 2;
    (v as unknown as { posAtCoords: () => number }).posAtCoords = () => clickPos;

    const handled = handleClick(v, new MouseEvent('click', { clientX: 0, clientY: 0 }));

    expect(handled).toBe(true);
    expect(v.state.selection.main.head).toBe(expectedAnchor);
    // Sanity check that this is genuinely past the marker, not at/before it (the regression).
    expect(v.state.selection.main.head).toBeGreaterThan(refMatch!.index);
  });

  // M2 (fix round for t-fee9dce6): the mirror-image bug in the OTHER direction — clicking a
  // reference in the body to jump to its definition — used to land the anchor at
  // defMatch.index, the START of "[^N]:", which sits BEFORE the marker. handleClick's
  // ref->def branch now matches api.ts's scrollToFootnoteDefinition arithmetic
  // (`idx + searchText.length + 1`, clamped to content.length) so the cursor lands right
  // after "[^N]: " for immediate typing into the definition body, same as every other entry
  // point into a definition.
  it('t-fee9dce6/M2: clicking a reference lands the anchor just past "[^N]: " in its definition, not before it', () => {
    const content = 'Body text[^1] tail.\n\n[^1]: the note';
    const v = makeEditor(content);

    const defMatch = /^\[\^1\]:/m.exec(content);
    expect(defMatch).not.toBeNull();
    const expectedAnchor = defMatch!.index + defMatch![0].length + 1;

    // Click in the middle of the "[^1]" reference in the body text.
    const refIndex = content.indexOf('[^1]');
    const clickPos = refIndex + 1;
    (v as unknown as { posAtCoords: () => number }).posAtCoords = () => clickPos;

    const handled = handleClick(v, new MouseEvent('click', { clientX: 0, clientY: 0 }));

    expect(handled).toBe(true);
    expect(v.state.selection.main.head).toBe(expectedAnchor);
    // Sanity check: past the colon+space, not at/before the "[^1]:" prefix start (the regression).
    expect(v.state.selection.main.head).toBeGreaterThan(defMatch!.index + defMatch![0].length);
    expect(v.state.doc.sliceString(expectedAnchor)).toBe('the note');
  });
});
