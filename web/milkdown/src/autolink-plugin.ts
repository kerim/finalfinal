// Autolink Plugin for Milkdown
// Converts bare URLs to clickable links when the user types a space after them
// Uses ProseMirror InputRule for real-time auto-linking (GFM autolinks only work at parse time)

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import { InputRule, inputRules } from '@milkdown/kit/prose/inputrules';
import type { EditorState, Transaction } from '@milkdown/kit/prose/state';
import { $prose } from '@milkdown/kit/utils';

// Match a URL followed by a space at the end of input
// The URL must start with http:// or https://
export const URL_REGEX = /(?:^|\s)(https?:\/\/[^\s]+)\s$/;

// Trailing punctuation to strip (matches GitHub/Slack autolink behavior)
const TRAILING_PUNCT = /[.,;:!?)}\]>'"]+$/;

// True if appending `char` (")" or "]") to `text` would close a "("/"[" that's
// unmatched within `text` -- i.e. the bracket is part of the URL's own content,
// not surrounding prose punctuation. Mirrors closesUnmatchedBracket in
// linkify-urls.lua (final final/Resources/Export/linkify-urls.lua): that filter
// only ever sees a bare URL as a pandoc `Str` node, which this InputRule
// pre-empts by auto-linking as the user types, so the same bracket-balance
// check has to be duplicated here or a URL like a Wikipedia disambiguation
// link loses its closing paren before pandoc ever runs.
function closesUnmatchedBracket(text: string, char: ')' | ']'): boolean {
  const open = char === ')' ? '(' : '[';
  let opens = 0;
  let closes = 0;
  for (const c of text) {
    if (c === open) opens += 1;
    else if (c === char) closes += 1;
  }
  return opens > closes;
}

// Exported so tests can drive the InputRule's handler directly against a minimal
// schema/state, without needing the full Milkdown ctx.
export function autolinkInputRuleHandler(
  state: EditorState,
  match: RegExpMatchArray,
  start: number,
  end: number
): Transaction | null {
  let url = match[1];

  // Strip trailing punctuation from URL
  const punctMatch = url.match(TRAILING_PUNCT);
  if (punctMatch) {
    url = url.slice(0, -punctMatch[0].length);
    // Re-absorb leading trail characters that are ")"/"]" closing an earlier
    // unmatched "("/"[" within the URL itself, so they stay in the link target
    // instead of being stripped as surrounding prose punctuation -- same
    // re-absorption loop as linkify-urls.lua's Str handler.
    let trail = punctMatch[0];
    while (trail.length > 0) {
      const firstChar = trail[0];
      if ((firstChar === ')' || firstChar === ']') && closesUnmatchedBracket(url, firstChar)) {
        url += firstChar;
        trail = trail.slice(1);
      } else {
        break;
      }
    }
  }

  const linkMark = state.schema.marks.link.create({ href: url });
  const linkStart = start + match[0].indexOf(url);
  const linkEnd = linkStart + url.length;

  // Insert the trailing space BEFORE marking the URL. The link mark is inclusive by
  // default (Milkdown's compiled schema sets no `inclusive` flag), so if the space were
  // inserted after addMark, `end` would resolve at the newly-marked range's right edge and
  // the space (then the next typed character too) would get pulled into the link. Inserting
  // first means `end` still resolves against plain, unmarked text.
  //
  // Keeping the caret plain at the boundary after this transaction (and on every subsequent
  // one, since a stray storedMarks value can otherwise reappear a transaction or two later)
  // is link-cursor.ts's job, not this handler's — see that file for why a one-shot clear here
  // was tried and found unreliable.
  return state.tr.insertText(' ', end).addMark(linkStart, linkEnd, linkMark);
}

const autolinkProsPlugin = $prose(() => {
  const autolinkInputRule = new InputRule(URL_REGEX, autolinkInputRuleHandler);

  return inputRules({ rules: [autolinkInputRule] });
});

export const autolinkPlugin: MilkdownPlugin[] = [autolinkProsPlugin].flat();
