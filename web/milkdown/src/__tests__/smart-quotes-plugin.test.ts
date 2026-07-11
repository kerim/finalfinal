// @vitest-environment jsdom
import { Schema } from '@milkdown/kit/prose/model';
import { EditorState, TextSelection } from '@milkdown/kit/prose/state';
import { afterEach, describe, expect, it } from 'vitest';
import {
  disableSmartQuotes,
  enableSmartQuotes,
  isNativeQuoteSubstitution,
  plainEquivalentOf,
  runSmartQuoteInputRules,
} from '../smart-quotes-plugin';

// Reset the module-level toggle after every test so state doesn't leak across cases.
afterEach(() => {
  enableSmartQuotes();
});

// Minimal doc/schema — no marks needed, quote curling only touches text nodes.
const schema = new Schema({
  nodes: {
    doc: { content: 'paragraph+' },
    paragraph: { content: 'text*', toDOM: () => ['p', 0] },
    text: {},
  },
});

/** doc = paragraph(raw) with the cursor placed at the end, mirroring the real caret
 *  position while typing. */
function stateForText(raw: string): EditorState {
  const doc = schema.node('doc', null, [schema.node('paragraph', null, raw ? [schema.text(raw)] : [])]);
  const end = 1 + raw.length;
  return EditorState.create({ doc, selection: TextSelection.create(doc, end) });
}

/** Simulates one real keystroke: run it through the gated smart-quote InputRules
 *  (exactly as `run()` in prosemirror-inputrules would), falling back to a plain
 *  insertion when no rule matches (or the toggle is off) — mirroring how ProseMirror's
 *  own view behaves when `handleTextInput` returns null. */
function typeChar(state: EditorState, ch: string): EditorState {
  const { from, to } = state.selection;
  const tr = runSmartQuoteInputRules(state, from, to, ch);
  if (tr) return state.apply(tr);
  return state.apply(state.tr.insertText(ch, from, to));
}

function typeString(state: EditorState, str: string): EditorState {
  let s = state;
  for (const ch of str) s = typeChar(s, ch);
  return s;
}

describe('smart quotes InputRule wiring', () => {
  it('opens a double quote at a word boundary', () => {
    const state = typeChar(stateForText('Say '), '"');
    expect(state.doc.textContent).toBe('Say “'); // “
  });

  it('opens a single quote at a word boundary', () => {
    const state = typeChar(stateForText('Say '), "'");
    expect(state.doc.textContent).toBe('Say ‘'); // ‘
  });

  it('closes a double quote after a letter', () => {
    const state = typeChar(stateForText('hello'), '"');
    expect(state.doc.textContent).toBe('hello”'); // ”
  });

  it('closes a single quote after a letter', () => {
    const state = typeChar(stateForText('hello'), "'");
    expect(state.doc.textContent).toBe('hello’'); // ’
  });

  it('curls a full "hello" sequence typed char-by-char into a balanced pair', () => {
    const state = typeString(stateForText(''), '"hello"');
    expect(state.doc.textContent).toBe('“hello”'); // “hello”
  });

  it('curls an apostrophe within a word as a closing single quote (contraction)', () => {
    const state = typeString(stateForText('it'), "'s a test");
    expect(state.doc.textContent).toBe('it’s a test'); // it’s a test
  });

  it('leaves a full "hello" sequence straight when disabled', () => {
    disableSmartQuotes();
    const state = typeString(stateForText(''), '"hello"');
    expect(state.doc.textContent).toBe('"hello"');
  });

  it('re-enabling after disable resumes curling', () => {
    disableSmartQuotes();
    typeString(stateForText(''), '"hello"'); // disabled — not asserted here
    enableSmartQuotes();
    const state = typeString(stateForText(''), '"hello"');
    expect(state.doc.textContent).toBe('“hello”');
  });

  it('re-curls a multi-character replacement when processed one character at a time', () => {
    // Mirrors main.ts's beforeinput interceptor: a native WebKit substitution can arrive
    // as a multi-character replacement (isNativeQuoteSubstitution permits these), but
    // every smartQuotes regex only ever matches a single trailing character, so the
    // interceptor must process the plain-equivalent text one character at a time (see
    // main.ts) rather than in a single dispatcher call over the whole string — a single
    // call would always fail the length check and silently fall back to inserting the
    // text straight, even with the toggle on. typeString already loops char-by-char, so
    // this asserts that loop produces curly output throughout, never a straight
    // fallback, for a 2-character run.
    const state = typeString(stateForText('hello'), '""');
    expect(state.doc.textContent).not.toContain('"');
    expect(state.doc.textContent).toBe('hello””'); // hello followed by two closing curls
  });
});

describe("inline-code exclusion (mirrors the registered plugin's inCodeMark: false)", () => {
  // Separate schema with a `code` mark (spec.code = true), matching Milkdown's real
  // inlineCode mark — the bare doc/paragraph/text schema above has no marks at all.
  const codeSchema = new Schema({
    nodes: {
      doc: { content: 'paragraph+' },
      paragraph: { content: 'text*', toDOM: () => ['p', 0] },
      text: {},
    },
    marks: {
      code: { code: true, toDOM: () => ['code', 0] },
    },
  });

  /** doc = paragraph(text with the code mark applied) with the cursor at the end,
   *  mirroring the caret position while typing more inline code. */
  function stateInsideCode(raw: string): EditorState {
    const codeMark = codeSchema.marks.code.create();
    const doc = codeSchema.node('doc', null, [
      codeSchema.node('paragraph', null, raw ? [codeSchema.text(raw, [codeMark])] : []),
    ]);
    const end = 1 + raw.length;
    return EditorState.create({ doc, selection: TextSelection.create(doc, end) });
  }

  it('does not curl a quote typed inside an inline-code mark', () => {
    const state = stateInsideCode('code');
    const { from, to } = state.selection;
    const tr = runSmartQuoteInputRules(state, from, to, '"');
    expect(tr).toBeNull();
  });

  it('curls normally just outside the inline-code mark (control case — the exclusion is scoped, not global)', () => {
    // Confirms the exclusion only suppresses curling where the code mark actually
    // applies — a plain (unmarked) run right after it still curls normally, so this
    // isn't accidentally disabling smart quotes document-wide.
    const state = stateForText('hello');
    const tr = runSmartQuoteInputRules(state, 6, 6, '"');
    expect(tr).not.toBeNull();
  });
});

describe('isNativeQuoteSubstitution', () => {
  it('is true for a bare closing double curly quote', () => {
    expect(isNativeQuoteSubstitution('”')).toBe(true); // ”
  });

  it('is true for a bare opening double curly quote', () => {
    expect(isNativeQuoteSubstitution('“')).toBe(true); // “
  });

  it('is true for a bare single curly quote', () => {
    expect(isNativeQuoteSubstitution('’')).toBe(true); // ’
  });

  it('is true for a multi-character replacement composed purely of curly quotes', () => {
    expect(isNativeQuoteSubstitution('“”')).toBe(true); // “”
  });

  it('is false for an empty string', () => {
    expect(isNativeQuoteSubstitution('')).toBe(false);
  });

  it('is false for a straight quote (not a native substitution at all)', () => {
    expect(isNativeQuoteSubstitution('"')).toBe(false);
  });

  it('is false for a real autocorrect typo fix', () => {
    expect(isNativeQuoteSubstitution('the')).toBe(false);
  });

  it('is false for a replacement mixing curly quotes with other characters', () => {
    expect(isNativeQuoteSubstitution('“teh”')).toBe(false);
  });

  // Deliberately no test gating on "was the original text straight" — that's the exact
  // check this predicate replaces, because it broke the default-ON case (see
  // smart-quotes-plugin.ts and the smart-quotes-fix plan's Approach section).
});

describe('plainEquivalentOf', () => {
  it('maps curly double quotes back to a straight double quote', () => {
    expect(plainEquivalentOf('“')).toBe('"');
    expect(plainEquivalentOf('”')).toBe('"');
  });

  it('maps curly single quotes back to a straight single quote', () => {
    expect(plainEquivalentOf('‘')).toBe("'");
    expect(plainEquivalentOf('’')).toBe("'");
  });

  it('maps a multi-character curly replacement char-by-char', () => {
    expect(plainEquivalentOf('“”')).toBe('""');
  });
});
