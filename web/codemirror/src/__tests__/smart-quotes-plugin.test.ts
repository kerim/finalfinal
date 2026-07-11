import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorState } from '@codemirror/state';
import { afterEach, describe, expect, it } from 'vitest';
import { isNativeQuoteSubstitution, plainEquivalentOf } from '../../../shared/smart-quotes';
import { disableSmartQuotes, enableSmartQuotes, resolveSmartQuoteChar } from '../smart-quotes-plugin';

// Reset the module-level toggle after every test so state doesn't leak across cases.
afterEach(() => {
  enableSmartQuotes();
});

// The `markdown` extension must be active for `syntaxTree()` to produce real node
// types — matches how main.ts itself constructs it (markdown({ base: markdownLanguage })).
function stateForText(doc: string): EditorState {
  return EditorState.create({ doc, extensions: [markdown({ base: markdownLanguage })] });
}

/** Simulates one real keystroke: resolves the smart-quote orientation from real
 *  document context (exactly as smartQuotesInputHandler would), falling back to a
 *  plain insertion when no rule matches (or the toggle is off). */
function typeChar(state: EditorState, pos: number, ch: string): EditorState {
  const curly = resolveSmartQuoteChar(state, pos, ch);
  const insert = curly ?? ch;
  return state.update({ changes: { from: pos, to: pos, insert } }).state;
}

function typeString(state: EditorState, str: string): EditorState {
  let s = state;
  for (const ch of str) s = typeChar(s, s.doc.length, ch);
  return s;
}

describe('resolveSmartQuoteChar', () => {
  it('opens a double quote at a word boundary', () => {
    const state = stateForText('Say ');
    expect(resolveSmartQuoteChar(state, state.doc.length, '"')).toBe('“'); // “
  });

  it('opens a single quote at a word boundary', () => {
    const state = stateForText('Say ');
    expect(resolveSmartQuoteChar(state, state.doc.length, "'")).toBe('‘'); // ‘
  });

  it('closes a double quote after a letter', () => {
    const state = stateForText('hello');
    expect(resolveSmartQuoteChar(state, state.doc.length, '"')).toBe('”'); // ”
  });

  it('closes a single quote after a letter', () => {
    const state = stateForText('hello');
    expect(resolveSmartQuoteChar(state, state.doc.length, "'")).toBe('’'); // ’
  });

  it('curls a full "hello" sequence typed char-by-char into a balanced pair', () => {
    const state = typeString(stateForText(''), '"hello"');
    expect(state.doc.toString()).toBe('“hello”'); // “hello”
  });

  it('leaves a full "hello" sequence straight when disabled', () => {
    disableSmartQuotes();
    const state = typeString(stateForText(''), '"hello"');
    expect(state.doc.toString()).toBe('"hello"');
  });

  it('re-enabling after disable resumes curling', () => {
    disableSmartQuotes();
    typeString(stateForText(''), '"hello"'); // disabled — not asserted here
    enableSmartQuotes();
    const state = typeString(stateForText(''), '"hello"');
    expect(state.doc.toString()).toBe('“hello”');
  });
});

describe("code-region exclusion (CM6-native analogue of Milkdown's inCodeMark/inCode)", () => {
  it('does not curl a quote typed inside an inline code span', () => {
    // `code` — caret placed just before the closing backtick, i.e. inside the span.
    const state = stateForText('`code`');
    const pos = state.doc.toString().indexOf('code') + 'code'.length;
    expect(resolveSmartQuoteChar(state, pos, '"')).toBeNull();
  });

  it('curls normally just outside an inline code span (control case)', () => {
    const state = stateForText('`code` after');
    const pos = state.doc.length; // caret at the very end, well outside the span
    expect(resolveSmartQuoteChar(state, pos, '"')).not.toBeNull();
  });

  it('does not curl a quote typed inside a fenced code block', () => {
    const doc = '```\ncode\n```';
    const state = stateForText(doc);
    const pos = doc.indexOf('code') + 'code'.length;
    expect(resolveSmartQuoteChar(state, pos, '"')).toBeNull();
  });

  it('curls normally just outside a fenced code block (control case)', () => {
    const doc = '```\ncode\n```\nafter';
    const state = stateForText(doc);
    const pos = doc.length; // caret on the line after the closing fence
    expect(resolveSmartQuoteChar(state, pos, '"')).not.toBeNull();
  });
});

// These are now shared, imported (not redefined) from web/shared/smart-quotes.ts — a
// single smoke test per function is enough to confirm this module wires up the shared
// import correctly. Milkdown's own test suite already covers the full matrix.
describe('shared smart-quotes imports wire up correctly', () => {
  it('isNativeQuoteSubstitution recognizes a bare curly quote', () => {
    expect(isNativeQuoteSubstitution('”')).toBe(true); // ”
    expect(isNativeQuoteSubstitution('the')).toBe(false);
  });

  it('plainEquivalentOf maps a curly quote back to straight', () => {
    expect(plainEquivalentOf('“')).toBe('"');
    expect(plainEquivalentOf('’')).toBe("'");
  });
});
