// Shared smart-quotes primitives — used by both Milkdown (ProseMirror) and
// CodeMirror's own quote-curling implementations.
//
// These four are pure string functions with zero ProseMirror or CM6 dependency, and
// — unlike the quote-orientation regexes each editor's own plugin file owns — they
// are originally authored in this codebase, not a re-export of a third-party
// package, so sharing them here introduces no new dependency into either bundle.
// See the smart-quotes-fix plan's "CodeMirror parity" addendum for the full
// rationale (moved out of web/milkdown/src/smart-quotes-plugin.ts byte-for-byte).

// WebKit's native "smart quote" substitution arrives as a `beforeinput` event with
// `inputType === 'insertReplacementText'` whose `data`/dataTransfer text is composed
// purely of curly quote characters. See the smart-quotes-fix plan's root-cause
// writeup: WebKit runs this substitution independently of either editor's own
// document model, with no public API to disable it, and it can target a stale
// range — producing the reported "only one side curls" bug. This predicate lets
// each editor's interceptor discard WebKit's own attempt unconditionally.
const CURLY_QUOTE_TO_PLAIN: Record<string, string> = {
  '‘': "'", // ‘ left single quote
  '’': "'", // ’ right single quote
  '“': '"', // “ left double quote
  '”': '"', // ” right double quote
};
const CURLY_QUOTE_CHARS = new Set(Object.keys(CURLY_QUOTE_TO_PLAIN));

// This matches on the replacement `data` alone — deliberately does NOT compare against
// the original (pre-replacement) text. An earlier version of this predicate checked
// whether the original text was a straight quote before discarding, but that's unsafe:
// when the toggle is ON and the editor's own curling has already run synchronously via
// the ordinary typing path, the original text at that range is already curly by the
// time WebKit's event arrives — an "was it straight?" check would return false and let
// WebKit's stale replacement clobber the already-correct quote, reproducing the exact
// reported bug in the default ON state. Matching on the replacement alone sidesteps
// this: any bare curly-quote replacement is discarded regardless of what's already
// there.
export function isNativeQuoteSubstitution(replacement: string): boolean {
  return replacement.length > 0 && [...replacement].every((ch) => CURLY_QUOTE_CHARS.has(ch));
}

/** Maps a curly-quote replacement string back to its plain-character equivalent.
 *  Used by each editor's interceptor in the (unconfirmed — see the plan's Step 0a)
 *  single-event case, where nothing has reached the ordinary input-handling pipeline
 *  yet and the plain character must be inserted manually. */
export function plainEquivalentOf(replacement: string): string {
  return [...replacement].map((ch) => CURLY_QUOTE_TO_PLAIN[ch] ?? ch).join('');
}
