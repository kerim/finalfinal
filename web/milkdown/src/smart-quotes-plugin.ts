// Smart quotes plugin for Milkdown.
//
// Converts straight quotes to curly ("smart") quotes as the user types, using
// ProseMirror's built-in `smartQuotes` InputRules (from `prosemirror-inputrules`,
// available transitively via `@milkdown/kit/prose/inputrules` — see
// `@milkdown/kit@7.18.0`'s `prose/inputrules` subpath, which re-exports
// `@milkdown/prose/inputrules`, which re-exports `prosemirror-inputrules` directly).
// These rules inspect the real preceding character in the ProseMirror document to
// decide open vs. close, so — unlike WebKit's own per-keystroke native quote
// substitution inside the WKWebView `contenteditable` surface, which decides
// open-vs-close independently for each keystroke from its own (possibly stale) view
// of the DOM — they are inherently balanced.
//
// Mirrors spellcheck-plugin.ts's module-flag pattern: a module-level `enabled` flag
// checked inside the handler at call time (not baked into plugin construction), so
// toggling the "Smart Quotes" menu item is a live, instant switch rather than
// requiring the plugin to be torn down and re-registered.

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import { InputRule, inputRules, smartQuotes } from '@milkdown/kit/prose/inputrules';
import type { EditorState, Transaction } from '@milkdown/kit/prose/state';
import { $prose } from '@milkdown/kit/utils';

let enabled = true;

export function enableSmartQuotes(): void {
  enabled = true;
}

export function disableSmartQuotes(): void {
  enabled = false;
}

/** Exposed for the `beforeinput`/`insertReplacementText` interceptor in main.ts,
 *  which needs to know the current toggle state to decide whether a WebKit-native
 *  quote substitution that arrives as the *only* event for a keystroke (see Step 0a
 *  in the smart-quotes-fix plan) should be let through to the InputRule pipeline
 *  (enabled) or inserted plainly (disabled). */
export function isSmartQuotesEnabled(): boolean {
  return enabled;
}

// `InputRule.match` and `InputRule.handler` are real runtime instance fields — see
// prosemirror-inputrules/src/inputrules.ts: the constructor does
// `this.match = match; this.handler = typeof handler == "string" ? ... : handler`.
// But both are marked `@internal` in the source and are stripped from the package's
// public `dist/index.d.ts` (the compiled `InputRule` class there declares only
// `inCode`/`inCodeMark` as members). Verified directly against the installed
// `prosemirror-inputrules@1.5.1` package (both `src/` and `dist/index.d.ts`) rather
// than assumed — there is no supported public API for decomposing a built `InputRule`
// back into its `match`/`handler` parts, so `as any` is required to read them here.
interface RawInputRule {
  match: RegExp;
  handler: (state: EditorState, match: RegExpMatchArray, start: number, end: number) => Transaction | null;
}

// prosemirror-inputrules exports `smartQuotes` in this fixed order — see
// prosemirror-inputrules/src/rules.ts:
//   export const smartQuotes = [openDoubleQuote, closeDoubleQuote, openSingleQuote, closeSingleQuote]
const [openDoubleQuoteRule, closeDoubleQuoteRule, openSingleQuoteRule, closeSingleQuoteRule] =
  smartQuotes as unknown as RawInputRule[];

/** Wraps a built-in smart-quote handler so it no-ops (returns null, meaning "rule did
 *  not match/handle") whenever the toggle is off. Exported individually — same
 *  reasoning as `markdownLinkInputRuleHandler` in markdown-link-input-rule.ts — so
 *  tests can drive each handler directly against a minimal schema/state without
 *  needing the full Milkdown ctx. */
function gate(
  rule: RawInputRule
): (state: EditorState, match: RegExpMatchArray, start: number, end: number) => Transaction | null {
  return (state, match, start, end) => {
    if (!enabled) return null;
    return rule.handler(state, match, start, end);
  };
}

export const openDoubleQuoteHandler = gate(openDoubleQuoteRule);
export const closeDoubleQuoteHandler = gate(closeDoubleQuoteRule);
export const openSingleQuoteHandler = gate(openSingleQuoteRule);
export const closeSingleQuoteHandler = gate(closeSingleQuoteRule);

interface GatedSmartQuoteRule {
  match: RegExp;
  handler: (state: EditorState, match: RegExpMatchArray, start: number, end: number) => Transaction | null;
}

// Exported so both tests and main.ts's beforeinput interceptor can resolve open-vs-close
// from real document context without needing the full Milkdown ctx or plugin machinery.
export const smartQuoteRules: readonly GatedSmartQuoteRule[] = [
  { match: openDoubleQuoteRule.match, handler: openDoubleQuoteHandler },
  { match: closeDoubleQuoteRule.match, handler: closeDoubleQuoteHandler },
  { match: openSingleQuoteRule.match, handler: openSingleQuoteHandler },
  { match: closeSingleQuoteRule.match, handler: closeSingleQuoteHandler },
];

/** Mirrors prosemirror-inputrules' internal per-keystroke dispatch (see `run()` in
 *  prosemirror-inputrules/src/inputrules.ts): tries each gated rule's regex against the
 *  text immediately before `to` (with `text` appended), in document order, and returns
 *  the first non-null transaction, or null if none matched (including when the toggle
 *  is off, since each handler above already gates on `enabled`).
 *
 *  Exported for two consumers:
 *  - Tests, so a `"hello"` sequence can be typed char-by-char and resolved to the
 *    correct open/close curly quote from context, exactly as real typing would be.
 *  - main.ts's beforeinput interceptor, for the (unconfirmed — see Step 0a) case where
 *    WebKit's native substitution is the *only* event for a keystroke, so nothing has
 *    reached the ordinary InputRule pipeline yet and this needs to be driven manually. */
export function runSmartQuoteInputRules(
  state: EditorState,
  from: number,
  to: number,
  text: string
): Transaction | null {
  if (!enabled) return null;
  const $from = state.doc.resolve(from);

  // inCodeMark:false exclusion #1 (see prosemirror-inputrules/src/inputrules.ts run(),
  // ~line 119): don't curl if the position itself carries a code mark.
  if ($from.marks().some((m) => m.type.spec.code)) return null;
  // inCode exclusion (same run(), ~line 120-123): none of the 4 smart-quote rules opt
  // into inCode, so don't curl inside a code-type block node (e.g. a fenced code
  // block) either.
  if ($from.parent.type.spec.code) return null;

  const textBefore =
    $from.parent.textBetween(Math.max(0, $from.parentOffset - 500), $from.parentOffset, undefined, '\ufffc') + text;
  for (const rule of smartQuoteRules) {
    const match = rule.match.exec(textBefore);
    if (!match || match[0].length < text.length) continue;
    const startPos = from - (match[0].length - text.length);
    // inCodeMark:false exclusion #2 (same run(), ~line 128-134): a rule that consumed
    // a preceding character (e.g. to confirm an opening-quote context) must not
    // straddle out of an inline-code run either — check every inline node the matched
    // span actually covers, not just the insertion point.
    let spansCodeMark = false;
    state.doc.nodesBetween(startPos, $from.pos, (node) => {
      if (node.isInline && node.marks.some((m) => m.type.spec.code)) spansCodeMark = true;
    });
    if (spansCodeMark) continue;
    const tr = rule.handler(state, match, startPos, to);
    if (tr) return tr;
  }
  return null;
}

const smartQuotesProsePlugin = $prose(() => {
  const rules = smartQuoteRules.map(({ match, handler }) => new InputRule(match, handler, { inCodeMark: false }));
  return inputRules({ rules });
});

export const smartQuotesPlugin: MilkdownPlugin[] = [smartQuotesProsePlugin].flat();

// --- beforeinput/insertReplacementText interceptor support (used by main.ts) ---
//
// Exported from here rather than defined inline in main.ts because main.ts has heavy
// side effects at module load (it constructs the whole Milkdown editor instance), so
// — following this codebase's established convention — no test imports main.ts
// directly. Keeping these pure, DOM-free functions in this already-test-friendly
// module is what makes them unit-testable at all.
//
// Moved to web/shared/smart-quotes.ts (byte-for-byte, no behavior change) so
// CodeMirror's own smart-quotes-plugin.ts can reuse the exact same, already-verified
// logic instead of duplicating it — see the smart-quotes-fix plan's "CodeMirror
// parity" addendum. Re-exported here so main.ts's existing imports and this file's
// own test suite (__tests__/smart-quotes-plugin.test.ts) keep working unchanged.
export { isNativeQuoteSubstitution, plainEquivalentOf } from '../../shared/smart-quotes';
