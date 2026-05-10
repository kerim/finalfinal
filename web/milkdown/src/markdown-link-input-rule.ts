import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import { InputRule, inputRules } from '@milkdown/kit/prose/inputrules';
import { $prose } from '@milkdown/kit/utils';

// Match `[text](url)` or `[text](url "title")` at the end of input.
// - text: non-empty, no unescaped `]` (avoids crossing cell boundaries)
// - url: non-empty, no whitespace, no `)` (note: URLs with literal parens like Wikipedia
//   won't trigger — they must be percent-encoded; acceptable for a typing InputRule)
const PATTERN = /\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)$/;

const markdownLinkProsPlugin = $prose(() => {
  const markdownLinkInputRule = new InputRule(PATTERN, (state, match, start, end) => {
    const [, text, href, title] = match;
    if (!text || !href) return null;
    const linkMark = state.schema.marks.link;
    if (!linkMark) return null;
    const attrs = title ? { href, title } : { href };
    const node = state.schema.text(text, [linkMark.create(attrs)]);
    return state.tr.replaceWith(start, end, node);
  });

  return inputRules({ rules: [markdownLinkInputRule] });
});

export const markdownLinkPlugin: MilkdownPlugin[] = [markdownLinkProsPlugin].flat();
