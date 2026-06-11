// @vitest-environment jsdom
import type { Mark } from '@milkdown/kit/prose/model';
import { Schema } from '@milkdown/kit/prose/model';
import type { Plugin } from '@milkdown/kit/prose/state';
import { EditorState, TextSelection } from '@milkdown/kit/prose/state';
import { describe, expect, it } from 'vitest';
import { buildInlineCodeCursorPlugin } from '../inline-code-cursor';

const schema = new Schema({
  nodes: {
    doc: { content: 'paragraph+' },
    paragraph: { content: 'text*', toDOM: () => ['p', 0] },
    text: {},
  },
  marks: {
    inlineCode: { code: true, toDOM: () => ['code', 0] },
    strong: { toDOM: () => ['strong', 0] },
  },
});
const code = schema.marks.inlineCode;
const plugin = buildInlineCodeCursorPlugin(code);

// doc 1: paragraph("Hi " + code("code")) + paragraph("next")
// positions: "Hi " = 1..4, "code" = 4..8 → right edge E = 8. Span ends the block.
function endDoc() {
  return schema.node('doc', null, [
    schema.node('paragraph', null, [schema.text('Hi '), schema.text('code', [code.create()])]),
    schema.node('paragraph', null, [schema.text('next')]),
  ]);
}

// doc 2: paragraph(code("code") + "X") — left edge = 1, right edge = 5, plain text after.
function midDoc() {
  return schema.node('doc', null, [
    schema.node('paragraph', null, [schema.text('code', [code.create()]), schema.text('X')]),
  ]);
}

function stateFor(doc: ReturnType<typeof endDoc>): EditorState {
  return EditorState.create({ doc, plugins: [plugin] });
}

/** Would the next typed character carry the code mark? */
function nextIsCode(state: EditorState): boolean {
  return !!code.isInSet(state.storedMarks ?? state.selection.$from.marks());
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

/** Minimal EditorView stand-in for handleKeyDown: state + dispatch. */
function makeView(state: EditorState) {
  const view = {
    state,
    composing: false,
    dispatch(tr: Parameters<EditorState['apply']>[0]) {
      view.state = view.state.apply(tr);
    },
  };
  return view;
}

function pressArrow(view: ReturnType<typeof makeView>, key: 'ArrowLeft' | 'ArrowRight'): boolean {
  const handler = (plugin as Plugin).props.handleKeyDown;
  if (!handler) throw new Error('plugin has no handleKeyDown');
  return handler.call(plugin, view as any, new KeyboardEvent('keydown', { key }) as any);
}

describe('arrival at an edge defaults to OUTSIDE', () => {
  it('click at the right edge of an end-of-block span → typing is plain', () => {
    const s = placeCursor(stateFor(endDoc()), 8);
    expect(nextIsCode(s)).toBe(false);
  });

  it('click at a mid-line right edge (plain text follows) → typing is plain', () => {
    const s = placeCursor(stateFor(midDoc()), 5);
    expect(nextIsCode(s)).toBe(false);
  });

  it('click at the left edge of a span at line start → typing is plain (prepends outside)', () => {
    // Start elsewhere (after the X), then click at the start — a real arrival.
    const s = placeCursor(placeCursor(stateFor(midDoc()), 6), 1);
    expect(nextIsCode(s)).toBe(false);
  });

  it('input-rule shape: span created with cursor left at its edge → typing is plain', () => {
    // Plain "Hi code" with cursor at the end; one transaction marks "code" and keeps the
    // cursor at the edge — the same end state the commonmark backtick rule produces.
    const doc = schema.node('doc', null, [schema.node('paragraph', null, [schema.text('Hi code')])]);
    const base = placeCursor(EditorState.create({ doc, plugins: [plugin] }), 8);
    const created = base.apply(base.tr.addMark(4, 8, code.create()));
    expect(nextIsCode(created)).toBe(false);
  });

  it('clears only the code mark, preserving other marks for the next character', () => {
    const both = [code.create(), schema.marks.strong.create()];
    const doc = schema.node('doc', null, [
      schema.node('paragraph', null, [schema.text('Hi '), schema.text('code', both)]),
    ]);
    const s = placeCursor(EditorState.create({ doc, plugins: [plugin] }), 8);
    const marks = s.storedMarks ?? [];
    expect(code.isInSet(marks)).toBeFalsy();
    expect(schema.marks.strong.isInSet(marks)).toBeTruthy();
  });
});

describe('two stops at the right edge (cod|e → code| → code`|)', () => {
  it('ArrowLeft at the outside stop steps INSIDE without moving; typing then extends the code', () => {
    const view = makeView(placeCursor(stateFor(endDoc()), 8));
    expect(pressArrow(view, 'ArrowLeft')).toBe(true); // consumed: no caret move
    expect(view.state.selection.from).toBe(8);
    expect(nextIsCode(view.state)).toBe(true);
    // multi-character extension must survive (each char re-derives marks naturally)
    let s = typeChar(view.state, 'x');
    s = typeChar(s, 'y');
    const para = s.doc.firstChild;
    expect(para?.textContent).toBe('Hi codexy');
    // both typed chars carry the code mark
    let codeText = '';
    para?.forEach((child) => {
      if (code.isInSet(child.marks)) codeText += child.text ?? '';
    });
    expect(codeText).toBe('codexy');
  });

  it('second ArrowLeft (already inside) is not consumed — native move proceeds', () => {
    const view = makeView(placeCursor(stateFor(endDoc()), 8));
    pressArrow(view, 'ArrowLeft'); // inside
    expect(pressArrow(view, 'ArrowLeft')).toBe(false); // browser moves to cod|e
  });

  it('arriving at the edge from inside the span keeps INSIDE (cod|e → code| stays code)', () => {
    const s0 = placeCursor(stateFor(endDoc()), 7); // cod|e — inside the run
    const s1 = placeCursor(s0, 8); // moved 1 while in code
    expect(nextIsCode(s1)).toBe(true);
  });

  it('ArrowRight at the inside stop steps OUTSIDE without moving; second press is native', () => {
    const s0 = placeCursor(stateFor(endDoc()), 7);
    const view = makeView(placeCursor(s0, 8)); // inside via rule above
    expect(pressArrow(view, 'ArrowRight')).toBe(true); // → outside, no move
    expect(view.state.selection.from).toBe(8);
    expect(nextIsCode(view.state)).toBe(false);
    expect(pressArrow(view, 'ArrowRight')).toBe(false); // native move onward
  });

  it('typing at the outside stop is plain and stays plain', () => {
    let s = placeCursor(stateFor(endDoc()), 8);
    s = typeChar(s, 'z');
    s = typeChar(s, 'w');
    const para = s.doc.firstChild;
    let codeText = '';
    para?.forEach((child) => {
      if (code.isInSet(child.marks)) codeText += child.text ?? '';
    });
    expect(codeText).toBe('code');
    expect(para?.textContent).toBe('Hi codezw');
  });
});

describe('two stops at the left edge (|`code → `|code)', () => {
  it('ArrowRight at the outside stop steps INSIDE without moving; typing prepends code', () => {
    const view = makeView(placeCursor(placeCursor(stateFor(midDoc()), 6), 1)); // real arrival → outside
    expect(pressArrow(view, 'ArrowRight')).toBe(true);
    expect(view.state.selection.from).toBe(1);
    expect(nextIsCode(view.state)).toBe(true);
  });

  it('ArrowLeft at the inside stop steps back OUTSIDE', () => {
    const view = makeView(placeCursor(placeCursor(stateFor(midDoc()), 6), 1));
    pressArrow(view, 'ArrowRight'); // inside
    expect(pressArrow(view, 'ArrowLeft')).toBe(true); // back outside, no move
    expect(view.state.selection.from).toBe(1);
    expect(nextIsCode(view.state)).toBe(false);
  });
});

describe('explicit choices are respected', () => {
  it('an explicit code stored-mark (e.g. ⌘E) at the edge is never overridden', () => {
    const base = placeCursor(stateFor(endDoc()), 8);
    const toggled = base.apply(base.tr.setStoredMarks([code.create()]));
    expect(nextIsCode(toggled)).toBe(true);
  });

  it('a long jump always re-defaults to OUTSIDE, even when leaving from inside code', () => {
    const inside = placeCursor(stateFor(endDoc()), 6); // co|de
    const jumped = placeCursor(inside, 8); // moved 2 → fresh arrival
    expect(nextIsCode(jumped)).toBe(false);
  });
});

describe('code-mode highlight decoration', () => {
  function decosFor(state: EditorState) {
    const fn = (plugin as Plugin).props.decorations;
    return fn ? (fn.call(plugin, state) as any) : null;
  }

  it('highlights the whole run at the INSIDE boundary stop', () => {
    const view = makeView(placeCursor(stateFor(endDoc()), 8));
    pressArrow(view, 'ArrowLeft'); // step inside
    const set = decosFor(view.state);
    expect(set).toBeTruthy();
    const found = set.find();
    expect(found).toHaveLength(1);
    expect(found[0].from).toBe(4);
    expect(found[0].to).toBe(8);
  });

  it('shows no highlight at the OUTSIDE boundary stop', () => {
    const s = placeCursor(stateFor(endDoc()), 8);
    expect(decosFor(s)).toBeNull();
  });

  it('highlights while the cursor is strictly inside the span', () => {
    const s = placeCursor(stateFor(endDoc()), 6);
    const found = decosFor(s)?.find();
    expect(found?.[0]?.from).toBe(4);
    expect(found?.[0]?.to).toBe(8);
  });

  it('shows no highlight when the cursor is in plain text', () => {
    const s = placeCursor(stateFor(endDoc()), 2);
    expect(decosFor(s)).toBeNull();
  });
});

describe('degenerate schema', () => {
  it('is inert when the schema has no inlineCode mark', () => {
    const bare = new Schema({
      nodes: {
        doc: { content: 'paragraph+' },
        paragraph: { content: 'text*', toDOM: () => ['p', 0] },
        text: {},
      },
      marks: {},
    });
    const p = buildInlineCodeCursorPlugin(undefined);
    const doc = bare.node('doc', null, [bare.node('paragraph', null, [bare.text('hi')])]);
    const state = EditorState.create({ doc, plugins: [p] });
    const view = makeView(state);
    const handler = p.props.handleKeyDown;
    expect(handler?.call(p, view as any, new KeyboardEvent('keydown', { key: 'ArrowLeft' }) as any)).toBe(false);
  });
});
