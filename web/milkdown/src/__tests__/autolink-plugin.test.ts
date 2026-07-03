// @vitest-environment jsdom
import type { Mark } from '@milkdown/kit/prose/model';
import { Schema } from '@milkdown/kit/prose/model';
import { EditorState, TextSelection } from '@milkdown/kit/prose/state';
import { describe, expect, it } from 'vitest';
import { autolinkInputRuleHandler, URL_REGEX } from '../autolink-plugin';

// Regex tests, following the same convention as markdown-link-input-rule.test.ts.
describe('autolink InputRule regex', () => {
  it('matches a bare URL followed by a trailing space', () => {
    const m = URL_REGEX.exec('https://example.com ');
    expect(m).not.toBeNull();
    expect(m![1]).toBe('https://example.com');
  });

  it('matches a URL preceded by whitespace', () => {
    const m = URL_REGEX.exec('see https://example.com ');
    expect(m).not.toBeNull();
    expect(m![1]).toBe('https://example.com');
  });

  it('does not match without the trailing space', () => {
    expect(URL_REGEX.exec('https://example.com')).toBeNull();
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

/**
 * doc = paragraph(text) with the cursor placed right after `text` (`end`) — mirroring the
 * real caret position when the InputRule handler fires: the triggering space has NOT yet
 * been inserted into the document (handleTextInput fires before the default insert, and the
 * handler is responsible for inserting it itself), only simulated in the regex match source.
 *
 * `text` may be just the bare URL, or the URL preceded by other text on the same line — in
 * the latter case `(?:^|\s)` in URL_REGEX consumes a leading whitespace character into
 * `match[0]`, so `start` must shift by `match.index`, exactly mirroring how
 * prosemirror-inputrules computes `startPos` for the real handler call.
 */
function stateForUrl(text: string): { state: EditorState; match: RegExpMatchArray; start: number; end: number } {
  const match = URL_REGEX.exec(`${text} `);
  if (!match) throw new Error(`regex did not match: ${text}`);
  const doc = schema.node('doc', null, [schema.node('paragraph', null, [schema.text(text)])]);
  const paragraphStart = 1;
  const end = paragraphStart + text.length;
  const start = paragraphStart + match.index;
  const state = EditorState.create({ doc, selection: TextSelection.create(doc, end) });
  return { state, match, start, end };
}

describe('autolink InputRule ProseMirror wiring', () => {
  it('links the URL, inserts a plain trailing space, and clears the stored link mark', () => {
    const url = 'https://example.com';
    const { state, match, start, end } = stateForUrl(url);

    const tr = autolinkInputRuleHandler(state, match, start, end);
    expect(tr).not.toBeNull();
    expect(link.isInSet(tr!.storedMarks ?? [])).toBeFalsy();

    const next = state.apply(tr!);
    const para = next.doc.firstChild;
    expect(para?.textContent).toBe(`${url} `);

    // The URL itself is linked...
    let linkedText = '';
    para?.forEach((child) => {
      if (link.isInSet(child.marks)) linkedText += child.text ?? '';
    });
    expect(linkedText).toBe(url);

    // ...but the trailing space node must NOT carry the link mark.
    const spaceNode = next.doc.textBetween(end, end + 1) === ' ' ? next.doc.resolve(end).nodeAfter : null;
    expect(spaceNode).not.toBeNull();
    expect(link.isInSet(spaceNode?.marks ?? [])).toBeFalsy();

    // Stronger check: apply the transaction, then simulate typing one more character on the
    // resulting state — the new character must not be linked either.
    const after = typeChar(next, 'x');
    const finalPara = after.doc.firstChild;
    let finalLinkedText = '';
    finalPara?.forEach((child) => {
      if (link.isInSet(child.marks)) finalLinkedText += child.text ?? '';
    });
    expect(finalLinkedText).toBe(url);
    expect(finalPara?.textContent).toBe(`${url} x`);
  });

  it('links only the URL when preceded by other text on the same line', () => {
    const text = 'see https://example.com';
    const url = 'https://example.com';
    const { state, match, start, end } = stateForUrl(text);

    const tr = autolinkInputRuleHandler(state, match, start, end);
    expect(tr).not.toBeNull();
    expect(link.isInSet(tr!.storedMarks ?? [])).toBeFalsy();

    const next = state.apply(tr!);
    const para = next.doc.firstChild;
    expect(para?.textContent).toBe(`${text} `);

    // The link mark covers exactly the URL substring — not "see " and not more/less than the URL.
    let linkedText = '';
    para?.forEach((child) => {
      if (link.isInSet(child.marks)) linkedText += child.text ?? '';
    });
    expect(linkedText).toBe(url);

    // ...but the trailing space node must NOT carry the link mark.
    const spaceNode = next.doc.textBetween(end, end + 1) === ' ' ? next.doc.resolve(end).nodeAfter : null;
    expect(spaceNode).not.toBeNull();
    expect(link.isInSet(spaceNode?.marks ?? [])).toBeFalsy();

    // Stronger check: apply the transaction, then simulate typing one more character on the
    // resulting state — the new character must not be linked either, same as the
    // start-of-line case.
    const after = typeChar(next, 'x');
    const finalPara = after.doc.firstChild;
    let finalLinkedText = '';
    finalPara?.forEach((child) => {
      if (link.isInSet(child.marks)) finalLinkedText += child.text ?? '';
    });
    expect(finalLinkedText).toBe(url);
    expect(finalPara?.textContent).toBe(`${text} x`);
  });

  it('strips trailing punctuation from the linked range but keeps it as plain text', () => {
    const url = 'https://example.com';
    const { state, match, start, end } = stateForUrl(`${url}.`);

    const tr = autolinkInputRuleHandler(state, match, start, end);
    expect(tr).not.toBeNull();
    const next = state.apply(tr!);
    const para = next.doc.firstChild;
    expect(para?.textContent).toBe(`${url}. `);

    let linkedText = '';
    para?.forEach((child) => {
      if (link.isInSet(child.marks)) linkedText += child.text ?? '';
    });
    expect(linkedText).toBe(url);
  });

  it('regression: typing in the middle of an existing autolinked URL still picks up the link mark', () => {
    // "See " + link("https://example.com") + " now" — cursor placed strictly inside the run.
    const doc = schema.node('doc', null, [
      schema.node('paragraph', null, [
        schema.text('See '),
        schema.text('https://example.com', [link.create({ href: 'https://example.com', title: null })]),
        schema.text(' now'),
      ]),
    ]);
    // "See " = 1..5, "https://example.com" = 5..24 — position 10 is strictly inside the run.
    const state = EditorState.create({ doc, selection: TextSelection.create(doc, 10) });
    expect(nextIsLink(state)).toBe(true);
  });
});
