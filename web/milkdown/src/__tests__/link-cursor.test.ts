// @vitest-environment jsdom
import type { Mark } from '@milkdown/kit/prose/model';
import { Schema } from '@milkdown/kit/prose/model';
import { EditorState, TextSelection } from '@milkdown/kit/prose/state';
import { describe, expect, it } from 'vitest';
import { buildLinkCursorPlugin } from '../link-cursor';

// Deliberately no `inclusive` flag on the link mark — it defaults to `true`, matching
// Milkdown's real compiled preset-commonmark schema, which is exactly what makes the
// boundary trap possible.
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
const plugin = buildLinkCursorPlugin(link);

/** Would the next typed character carry the link mark? */
function nextIsLink(state: EditorState): boolean {
  return !!link.isInSet(state.storedMarks ?? state.selection.$from.marks());
}

/** Build a state with the plugin registered, so appendTransaction runs on every .apply(). */
function stateFor(doc: ReturnType<typeof schema.node>): EditorState {
  return EditorState.create({ doc, plugins: [plugin] });
}

/** Place the cursor as a user click/jump would (selection-only transaction). */
function placeCursor(state: EditorState, pos: number): EditorState {
  return state.apply(state.tr.setSelection(TextSelection.create(state.doc, pos)));
}

/** Simulate typing one character the way the view does: marks = storedMarks ?? marks(). */
function typeChar(state: EditorState, ch: string): EditorState {
  const marks = (state.storedMarks ?? state.selection.$from.marks()) as Mark[];
  return state.apply(state.tr.replaceSelectionWith(schema.text(ch, marks), false));
}

function linkedText(state: EditorState): string {
  let text = '';
  state.doc.firstChild?.forEach((child) => {
    if (link.isInSet(child.marks)) text += child.text ?? '';
  });
  return text;
}

describe('markdown-link right-edge shape (position-derived marks = link, storedMarks null)', () => {
  it('clears the mark so typing the next char stays plain', () => {
    // "Hi hello" plain, cursor at the end; one transaction marks "hello" as a link and
    // leaves the cursor right after it — the same shape markdown-link-input-rule.ts's
    // replaceWith produces (nothing follows the newly-created link).
    const doc = schema.node('doc', null, [schema.node('paragraph', null, [schema.text('Hi hello')])]);
    const base = placeCursor(stateFor(doc), 9); // end of "Hi hello" (paragraph 1..9)
    const created = base.apply(base.tr.addMark(4, 9, link.create({ href: 'https://example.com' })));

    expect(nextIsLink(created)).toBe(false);
    const after = typeChar(created, 'x');
    expect(linkedText(after)).toBe('hello');
    expect(after.doc.firstChild?.textContent).toBe('Hi hellox');
  });
});

describe('autolink-after-space shape (stray storedMarks, plain position-derived marks)', () => {
  const url = 'https://example.com';
  function doc() {
    return schema.node('doc', null, [
      schema.node('paragraph', null, [schema.text(url, [link.create({ href: url })]), schema.text(' ')]),
    ]);
  }
  const pos = 1 + url.length + 1; // right after the trailing plain space

  it('is already plain on real arrival — nothing to clear', () => {
    const state = placeCursor(stateFor(doc()), pos);
    expect(nextIsLink(state)).toBe(false);
  });

  it('clears a stray storedMarks=[link] so typing the next char stays plain', () => {
    // Position-derived marks are plain here (nodeBefore = the trailing space, which carries
    // no marks) — the real bug is a stray storedMarks value that outlives the creating
    // transaction, which $pos.marks() alone would never see. Simulate that stray value
    // directly and confirm the plugin heals it.
    const arrived = placeCursor(stateFor(doc()), pos);
    const strayed = arrived.apply(arrived.tr.setStoredMarks([link.create({ href: url })]));

    expect(nextIsLink(strayed)).toBe(false); // appendTransaction healed it within the same apply()
    const after = typeChar(strayed, 'x');
    expect(linkedText(after)).toBe(url);
    expect(after.doc.firstChild?.textContent).toBe(`${url} x`);
  });

  it('without the plugin, the same stray storedMarks value would leak into the next char', () => {
    // Baseline, to show the healing above is doing real work rather than being a no-op.
    const bare = EditorState.create({ doc: doc(), selection: TextSelection.create(doc(), pos) });
    const strayed = bare.apply(bare.tr.setStoredMarks([link.create({ href: url })]));
    expect(nextIsLink(strayed)).toBe(true);
    const after = typeChar(strayed, 'x');
    expect(linkedText(after)).toBe(`${url}x`);
  });
});

describe('regression: editing strictly inside an existing link run', () => {
  it('does not clear the mark; typing extends the link', () => {
    // "Hi " + link("linktext") + " there" — cursor placed strictly inside the run, with
    // linked neighbors on both sides.
    const doc = schema.node('doc', null, [
      schema.node('paragraph', null, [
        schema.text('Hi '),
        schema.text('linktext', [link.create({ href: 'https://example.com' })]),
        schema.text(' there'),
      ]),
    ]);
    // "Hi " = 1..4, "linktext" = 4..12 — position 8 is strictly inside the run.
    const state = placeCursor(stateFor(doc), 8);
    expect(nextIsLink(state)).toBe(true);

    const after = typeChar(state, 'X');
    expect(linkedText(after)).toBe('linkXtext');
  });
});

describe('left edge of a link (plain text immediately before it)', () => {
  it('is already plain — the plugin is a no-op', () => {
    // "Hi " + link("linktext") — cursor right between them, at the link's left edge.
    const doc = schema.node('doc', null, [
      schema.node('paragraph', null, [
        schema.text('Hi '),
        schema.text('linktext', [link.create({ href: 'https://example.com' })]),
      ]),
    ]);
    const state = placeCursor(stateFor(doc), 4); // right before "linktext"
    expect(nextIsLink(state)).toBe(false);

    const after = typeChar(state, 'X');
    expect(linkedText(after)).toBe('linktext'); // the typed char stayed plain, not prepended to the link
    expect(after.doc.firstChild?.textContent).toBe('Hi Xlinktext');
  });
});

describe('degenerate schema', () => {
  it('is inert when the schema has no link mark', () => {
    const bare = new Schema({
      nodes: {
        doc: { content: 'paragraph+' },
        paragraph: { content: 'text*', toDOM: () => ['p', 0] },
        text: {},
      },
      marks: {},
    });
    const p = buildLinkCursorPlugin(undefined);
    const doc = bare.node('doc', null, [bare.node('paragraph', null, [bare.text('hi')])]);
    const state = EditorState.create({ doc, plugins: [p] });
    expect(() => state.apply(state.tr.setSelection(TextSelection.create(doc, 1)))).not.toThrow();
  });
});
