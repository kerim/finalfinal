// @vitest-environment jsdom
import type { Mark } from '@milkdown/kit/prose/model';
import { Schema } from '@milkdown/kit/prose/model';
import { EditorState, TextSelection } from '@milkdown/kit/prose/state';
import { describe, expect, it } from 'vitest';
import { markdownLinkInputRuleHandler, PATTERN } from '../markdown-link-input-rule';

describe('markdown-link InputRule regex', () => {
  it('matches basic [text](url)', () => {
    const m = '[hello](https://example.com)'.match(PATTERN);
    expect(m).not.toBeNull();
    expect(m![1]).toBe('hello');
    expect(m![2]).toBe('https://example.com');
    expect(m![3]).toBeUndefined();
  });

  it('matches [text](url "title")', () => {
    const m = '[hello](https://example.com "My Title")'.match(PATTERN);
    expect(m).not.toBeNull();
    expect(m![1]).toBe('hello');
    expect(m![2]).toBe('https://example.com');
    expect(m![3]).toBe('My Title');
  });

  it('does not match when text is empty', () => {
    expect('[](https://example.com)'.match(PATTERN)).toBeNull();
  });

  it('does not match when href is empty', () => {
    expect('[text]()'.match(PATTERN)).toBeNull();
  });

  it('does not match when href contains whitespace', () => {
    expect('[text](url with spaces)'.match(PATTERN)).toBeNull();
  });

  it('does not match URL with literal unencoded parenthesis (expected limitation)', () => {
    // Wikipedia-style URLs with literal () won't trigger — see plan risks section
    const m = '[C](https://en.wikipedia.org/wiki/C_(programming_language))'.match(PATTERN);
    // The regex stops at the first ) inside the URL, so this won't produce a full match
    // for the href. Acceptable: user must percent-encode or use escapeHref output.
    if (m) {
      expect(m[2]).not.toBe('https://en.wikipedia.org/wiki/C_(programming_language)');
    }
  });

  it('matches at end of longer text (inline within paragraph)', () => {
    const m = 'Here is a link [click here](https://x.com) text'.match(PATTERN);
    // $ anchors to end of string, so the link must be at the END
    // "text" after the ) means this won't match
    expect(m).toBeNull();
  });

  it('matches when link is at the very end of input', () => {
    const m = 'Here is [click here](https://x.com)'.match(PATTERN);
    expect(m).not.toBeNull();
    expect(m![1]).toBe('click here');
    expect(m![2]).toBe('https://x.com');
  });
});

// ProseMirror wiring: build a minimal schema with a `link` mark. Deliberately no
// `inclusive` flag is set here — it defaults to `true`, matching Milkdown's real compiled
// preset-commonmark schema, which is exactly what makes the caret trap possible.
const schema = new Schema({
  nodes: {
    doc: { content: 'paragraph+' },
    paragraph: { content: 'text*', toDOM: () => ['p', 0] },
    text: {},
  },
  marks: {
    link: { attrs: { href: {}, title: { default: null } }, toDOM: () => ['a', 0] },
  },
});
const link = schema.marks.link;

/** Would the next typed character carry the link mark? */
function nextIsLink(state: EditorState): boolean {
  return !!link.isInSet(state.storedMarks ?? state.selection.$from.marks());
}

/** Simulate typing one character the way the view does: marks = storedMarks ?? marks(). */
function typeChar(state: EditorState, ch: string): EditorState {
  const marks = (state.storedMarks ?? state.selection.$from.marks()) as Mark[];
  return state.apply(state.tr.replaceSelectionWith(schema.text(ch, marks), false));
}

/** doc = paragraph(raw) with the cursor placed at `end`, mirroring the real caret position
 * when the InputRule handler fires (the view's selection is collapsed exactly there). */
function stateForRaw(raw: string): { state: EditorState; start: number; end: number } {
  const doc = schema.node('doc', null, [schema.node('paragraph', null, [schema.text(raw)])]);
  const start = 1;
  const end = start + raw.length;
  const state = EditorState.create({ doc, selection: TextSelection.create(doc, end) });
  return { state, start, end };
}

describe('markdown-link InputRule ProseMirror wiring', () => {
  it("creates the link node and leaves storedMarks untouched (boundary correctness is link-cursor.ts's job)", () => {
    const raw = '[hello](https://example.com)';
    const match = PATTERN.exec(raw);
    expect(match).not.toBeNull();
    const { state, start, end } = stateForRaw(raw);

    const tr = markdownLinkInputRuleHandler(state, match!, start, end);
    expect(tr).not.toBeNull();
    // The handler no longer calls removeStoredMark — replaceWith is the only step, and a
    // plain step (with no explicit setStoredMarks/ensureMarks call after it) always leaves
    // storedMarks null.
    expect(tr!.storedMarks).toBeNull();

    const next = state.apply(tr!);
    const para = next.doc.firstChild;
    let linkedText = '';
    para?.forEach((child) => {
      if (link.isInSet(child.marks)) linkedText += child.text ?? '';
    });
    expect(linkedText).toBe('hello');
    expect(para?.textContent).toBe('hello');

    // NOTE: at this exact boundary — cursor immediately after a just-created link, nothing
    // after it — position-derived marks resolve to the link (it's inclusive by default), so
    // typing the very next character HERE, with only this handler's transaction applied,
    // still inherits the link mark. That's expected now: this file is no longer responsible
    // for clearing the boundary after creation. link-cursor.ts's appendTransaction is the
    // single owner of that (it runs as a separate plugin on every subsequent transaction in
    // the real editor); its self-healing behavior for exactly this shape is covered by
    // __tests__/link-cursor.test.ts, not here.
    const after = typeChar(next, 'x');
    let trappedText = '';
    after.doc.firstChild?.forEach((child) => {
      if (link.isInSet(child.marks)) trappedText += child.text ?? '';
    });
    expect(trappedText).toBe('hellox');
  });

  it('still creates the link with the right text, href, and title', () => {
    const raw = '[hello](https://example.com "My Title")';
    const match = PATTERN.exec(raw);
    expect(match).not.toBeNull();
    const { state, start, end } = stateForRaw(raw);

    const tr = markdownLinkInputRuleHandler(state, match!, start, end);
    const next = state.apply(tr!);
    const textNode = next.doc.firstChild?.firstChild;
    expect(textNode?.text).toBe('hello');
    const mark = link.isInSet(textNode?.marks ?? []);
    expect(mark).toBeTruthy();
    expect(mark?.attrs.href).toBe('https://example.com');
    expect(mark?.attrs.title).toBe('My Title');
  });

  it('regression: typing in the middle of an existing link still picks up the link mark', () => {
    // "Hi " + link("linktext") + " there" — cursor placed strictly inside the linked run,
    // not at either boundary.
    const doc = schema.node('doc', null, [
      schema.node('paragraph', null, [
        schema.text('Hi '),
        schema.text('linktext', [link.create({ href: 'https://example.com', title: null })]),
        schema.text(' there'),
      ]),
    ]);
    // "Hi " = 1..4, "linktext" = 4..12 — position 8 is strictly inside the run.
    const state = EditorState.create({ doc, selection: TextSelection.create(doc, 8) });
    expect(nextIsLink(state)).toBe(true);
  });
});
