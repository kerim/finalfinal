import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import { InputRule, inputRules } from '@milkdown/kit/prose/inputrules';
import type { EditorState, Transaction } from '@milkdown/kit/prose/state';
import { $prose } from '@milkdown/kit/utils';

// Match `[text](url)` or `[text](url "title")` at the end of input.
// - text: non-empty, no unescaped `]` (avoids crossing cell boundaries)
// - url: non-empty, no whitespace, no `)` (note: URLs with literal parens like Wikipedia
//   won't trigger — they must be percent-encoded; acceptable for a typing InputRule)
export const PATTERN = /\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)$/;

// Exported so tests can drive the InputRule's handler directly against a minimal
// schema/state, without needing the full Milkdown ctx.
export function markdownLinkInputRuleHandler(
  state: EditorState,
  match: RegExpMatchArray,
  start: number,
  end: number
): Transaction | null {
  const [, text, href, title] = match;
  if (!text || !href) return null;
  const linkMark = state.schema.marks.link;
  if (!linkMark) return null;
  const attrs = title ? { href, title } : { href };
  const node = state.schema.text(text, [linkMark.create(attrs)]);
  // The link mark is inclusive by default (Milkdown's compiled preset-commonmark schema
  // sets no `inclusive` flag), so leaving the caret at the replaced node's right edge would
  // let position-derived marks resolve to the link and silently absorb the next typed
  // character. Keeping the caret plain there — and on every subsequent transaction, since a
  // one-shot clear here was tried and found unreliable — is link-cursor.ts's job.
  return state.tr.replaceWith(start, end, node);
}

const markdownLinkProsPlugin = $prose(() => {
  const markdownLinkInputRule = new InputRule(PATTERN, markdownLinkInputRuleHandler);

  return inputRules({ rules: [markdownLinkInputRule] });
});

export const markdownLinkPlugin: MilkdownPlugin[] = [markdownLinkProsPlugin].flat();
