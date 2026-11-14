// Minimal escaping for the Markdown serializer (t-4eb7bfa9).
//
// The stock serializer (mdast-util-to-markdown) escapes every `_` and `*` in text, so a paragraph typed as `snake_case_name`
// is written `snake\_case\_name`. Markdown mode (CodeMirror) shows the raw text and nothing reads the backslashes back out, so a
// switch to Markdown would show them. This plugin wraps the stock `text` handler and drops a backslash in exactly two cases that
// CommonMark's emphasis rules prove cannot change how the text reads back:
//   1. `\_` with a letter or digit directly on both sides: an underscore inside a word never opens or closes emphasis.
//   2. `\*` or `\_` with a space or tab directly on both sides, when the same line already has text before it: a delimiter run
//      between spaces is neither left- nor right-flanking so it cannot open or close emphasis, and with text before it on the
//      line it cannot start a list item or a thematic break.
// Every other escape stays (`\$`, `\~`, `\[`, a line-start `\-`, `\*`, `1\.`, and the underscores of `\_\_init\_\_`, which bare
// would read back as bold).
//
// Registered once in main.ts, so the whole-document save (`getContent()`) and the per-block save (`blockMarkdownFragment` in
// block-sync-plugin.ts) escape alike by construction: both go through the same serializer.
//
// The handler only ever sees mdast `text` nodes, so code spans, code blocks, math and raw HTML are untouched.

import { remarkStringifyOptionsCtx } from '@milkdown/kit/core';
import type { MilkdownPlugin } from '@milkdown/kit/ctx';

const ASCII_PUNCTUATION = /[!-/:-@[-`{-~]/;
const LETTER_OR_DIGIT = /[\p{L}\p{N}]/u;

const isLetterOrDigit = (ch: string | undefined): boolean => ch !== undefined && LETTER_OR_DIGIT.test(ch);
const isSpaceOrTab = (ch: string | undefined): boolean => ch === ' ' || ch === '\t';

/**
 * Drops the backslash of an escaped `_` or `*` where the two rules above prove it unneeded; returns every other character,
 * including every other escape, unchanged. `out` is what the stock `text` handler wrote for one text node. Escapes are read as a
 * unit (a backslash and the ASCII punctuation after it), so an escaped backslash is never taken for the start of another escape.
 * Rule 2 is judged per line, within this text node's own output (a line break inside the text starts a new line).
 */
export function relaxSafeEscapes(out: string): string {
  if (!out.includes('\\')) return out;
  let result = '';
  let lineHasText = false; // non-blank content already written on the current line of `result`
  for (let i = 0; i < out.length; i++) {
    const ch = out[i];
    if (ch === '\n' || ch === '\r') {
      result += ch;
      lineHasText = false;
      continue;
    }
    if (ch === '\\' && i + 1 < out.length && ASCII_PUNCTUATION.test(out[i + 1])) {
      const escaped = out[i + 1];
      if (escaped === '_' || escaped === '*') {
        const before = result[result.length - 1];
        const after = out[i + 2];
        const insideWord = escaped === '_' && isLetterOrDigit(before) && isLetterOrDigit(after);
        const betweenSpaces = isSpaceOrTab(before) && isSpaceOrTab(after) && lineHasText;
        if (insideWord || betweenSpaces) {
          result += escaped;
          lineHasText = true;
          i++;
          continue;
        }
      }
      result += ch + escaped;
      lineHasText = true;
      i++;
      continue;
    }
    result += ch;
    if (!isSpaceOrTab(ch)) lineHasText = true;
  }
  return result;
}

/** Registers the relaxed `text` handler on top of the stock one (Milkdown's own, which also keeps a trailing space bare). */
export const minimalEscapePlugin: MilkdownPlugin = (ctx) => {
  ctx.update(remarkStringifyOptionsCtx, (prev) => {
    const stockText = prev.handlers?.text;
    if (!stockText) return prev;
    return {
      ...prev,
      handlers: {
        ...prev.handlers,
        text: (...args: Parameters<typeof stockText>) => relaxSafeEscapes(stockText(...args)),
      },
    };
  });
  return async () => {};
};
