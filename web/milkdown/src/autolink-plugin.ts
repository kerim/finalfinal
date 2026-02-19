// Autolink Plugin for Milkdown
// Converts bare URLs to clickable links when the user types a space after them
// Uses ProseMirror InputRule for real-time auto-linking (GFM autolinks only work at parse time)

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import { InputRule, inputRules } from '@milkdown/kit/prose/inputrules';
import { $prose } from '@milkdown/kit/utils';

// Match a URL followed by a space at the end of input
// The URL must start with http:// or https://
const URL_REGEX = /(?:^|\s)(https?:\/\/[^\s]+)\s$/;

// Trailing punctuation to strip (matches GitHub/Slack autolink behavior)
const TRAILING_PUNCT = /[.,;:!?)}\]>'"]+$/;

const autolinkProsPlugin = $prose(() => {
  const autolinkInputRule = new InputRule(URL_REGEX, (state, match, start, end) => {
    let url = match[1];

    // Strip trailing punctuation from URL
    const punctMatch = url.match(TRAILING_PUNCT);
    if (punctMatch) {
      url = url.slice(0, -punctMatch[0].length);
    }

    const linkMark = state.schema.marks.link.create({ href: url });
    const linkStart = start + match[0].indexOf(url);
    const linkEnd = linkStart + url.length;

    return state.tr.addMark(linkStart, linkEnd, linkMark).insertText(' ', end);
  });

  return inputRules({ rules: [autolinkInputRule] });
});

export const autolinkPlugin: MilkdownPlugin[] = [autolinkProsPlugin].flat();
