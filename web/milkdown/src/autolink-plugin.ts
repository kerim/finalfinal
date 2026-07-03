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
