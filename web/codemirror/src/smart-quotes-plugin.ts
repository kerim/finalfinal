// Smart quotes plugin for CodeMirror (source mode).
//
// Ports the same idea as Milkdown's smart-quotes-plugin.ts to CM6's own APIs: curl
// straight quotes as the user types, using the real surrounding text so open/close
// can't mismatch, and discard whatever WebKit's own native quote substitution tries
// to do — whether the toggle is on (our own curling already produced the correct
// result) or off (WebKit's attempt must simply be thrown away for "off" to mean
// anything). See the smart-quotes-fix plan's "CodeMirror parity" addendum for the
// full design rationale.
//
// Mirrors spellcheck-plugin.ts's module-flag pattern: a module-level `enabled` flag
// checked at call time (not baked into extension construction), so toggling the
// "Smart Quotes" menu item is a live, instant switch.

import { syntaxTree } from '@codemirror/language';
import type { EditorState } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { isNativeQuoteSubstitution, plainEquivalentOf } from '../../shared/smart-quotes';

let enabled = true;

export function enableSmartQuotes(): void {
  enabled = true;
}

export function disableSmartQuotes(): void {
  enabled = false;
}

export function isSmartQuotesEnabled(): boolean {
  return enabled;
}

// Code-region exclusion — a small, dedicated set, not an import of spellcheck's
// broader SKIP_NODES (that set also skips URL, Autolink, HeaderMark, etc., which are
// irrelevant to quote curling; keeping this file's own minimal set matches this
// codebase's existing convention of separate, decoupled per-concern plugin files).
const CODE_NODE_NAMES = new Set(['FencedCode', 'CodeBlock', 'InlineCode', 'CodeText', 'CodeMark']);

function isInsideCodeRegion(state: EditorState, pos: number): boolean {
  let node = syntaxTree(state).resolveInner(pos);
  while (node) {
    if (CODE_NODE_NAMES.has(node.name)) return true;
    node = node.parent;
  }
  return false;
}

// The exact 4 regexes, transcribed from prosemirror-inputrules@1.5.1/src/rules.ts
// (lines 8-14), tried in this order — first match wins (mirrors smartQuotes's own
// array order and run()'s dispatch in prosemirror-inputrules/src/inputrules.ts):
//   openDoubleQuote:  /(?:^|[\s\{\[\(\<'"‘“])(")$/  → “
//   closeDoubleQuote: /"$/                                     → ”
//   openSingleQuote:  /(?:^|[\s\{\[\(\<'"‘“])(')$/  → ‘
//   closeSingleQuote: /'$/                                     → ’
//
// Verified simplification (see the addendum): stringHandler always resolves its edit
// down to only the single trailing quote character — the leading context character is
// read-only, never part of the replaced span, for any of the 4 rules. So this port
// only needs a boolean test per regex to decide which single Unicode replacement
// character to substitute for the just-typed quote — never a multi-character span
// edit.
const QUOTE_RULES: { match: RegExp; replacement: string }[] = [
  { match: /(?:^|[\s{[(<'"‘“])(")$/, replacement: '“' }, // “
  { match: /"$/, replacement: '”' }, // ”
  { match: /(?:^|[\s{[(<'"‘“])(')$/, replacement: '‘' }, // ‘
  { match: /'$/, replacement: '’' }, // ’
];

/** Resolves the correct curly replacement (or null, meaning "leave it straight") for
 *  a quote character about to be typed at `pos`. Exported for tests, mirroring
 *  Milkdown's `runSmartQuoteInputRules` test-ability rationale — drive orientation
 *  logic directly without a full EditorView.
 *
 *  Known, accepted simplification: bounding `textBefore` to `line.from` (a real line
 *  break) rather than ProseMirror's "current paragraph" is not a perfect match — a
 *  markdown paragraph that hard-wraps across two source lines without a blank line
 *  between them would see the second line's start treated as "start of context"
 *  (triggering an opening quote) even though it's mid-paragraph semantically. Judged
 *  an acceptable, rare edge case for source-mode typing. */
export function resolveSmartQuoteChar(state: EditorState, pos: number, typed: string): string | null {
  if (!enabled) return null;
  if (isInsideCodeRegion(state, pos)) return null;
  const line = state.doc.lineAt(pos);
  const start = Math.max(line.from, pos - 500); // capped lookback, bounded to current line
  const textBefore = state.sliceDoc(start, pos) + typed;
  for (const rule of QUOTE_RULES) {
    if (rule.match.test(textBefore)) return rule.replacement;
  }
  return null;
}

/** Live curling while typing — wired via EditorView.inputHandler, CM6's own analogue
 *  of ProseMirror's InputRule/handleTextInput pipeline. Returning false (toggle off,
 *  no match, or not a quote character) lets CM6 apply its own default plain-character
 *  insertion — simpler than Milkdown's beforeinput branch, which had to manually
 *  re-insert after calling preventDefault(); CM6's inputHandler contract handles the
 *  "let it through" case for us. */
export function smartQuotesInputHandler(view: EditorView, from: number, to: number, text: string): boolean {
  if (text.length !== 1 || (text !== '"' && text !== "'")) return false;
  const curly = resolveSmartQuoteChar(view.state, from, text);
  if (!curly) return false;
  view.dispatch({ changes: { from, to, insert: curly }, selection: { anchor: from + curly.length } });
  return true;
}

/** Discards WebKit's native quote-curling substitution, reusing the shared
 *  isNativeQuoteSubstitution/plainEquivalentOf predicates (translated to CM6's
 *  position APIs). Same defensive, handle-both-possible-event-sequences design as
 *  Milkdown's interceptor (collapsed vs. non-collapsed range distinguishing the
 *  one-event vs two-event case), not an assumption that either model applies here —
 *  CodeMirror's `.cm-content` is a differently-structured contenteditable surface, so
 *  its actual event sequence was re-verified rather than inherited from Milkdown's
 *  (see the addendum's "CodeMirror-specific Step 0"). */
export function handleBeforeInput(event: InputEvent, view: EditorView): boolean {
  if (event.inputType !== 'insertReplacementText') return false;
  const replacement = event.dataTransfer?.getData('text/plain') || event.data || '';
  if (!replacement || !isNativeQuoteSubstitution(replacement)) return false;
  event.preventDefault();

  const ranges = event.getTargetRanges();
  let startPos: number;
  let endPos: number;
  if (ranges.length > 0) {
    startPos = view.posAtDOM(ranges[0].startContainer, ranges[0].startOffset);
    endPos = view.posAtDOM(ranges[0].endContainer, ranges[0].endOffset);
  } else {
    ({ from: startPos, to: endPos } = view.state.selection.main);
  }

  if (startPos !== endPos) {
    // Non-collapsed: an ordinary insertText already landed here via
    // smartQuotesInputHandler (curled if enabled, plain if not) — this native
    // replacement is redundant/stale. Discard.
    return true;
  }

  // Collapsed: nothing landed via the ordinary path first — drive insertion
  // ourselves, one character at a time (mirrors main.ts's Milkdown interceptor: each
  // rule only matches a single trailing character). Re-reads the cursor position from
  // view.state.selection after each dispatch, rather than trusting `insert.length`
  // arithmetic — this matches the proven pattern already used by Milkdown's
  // interceptor (which reads view.state.selection.to after each dispatch rather than
  // computing position arithmetic by hand), since a dispatched change can in
  // principle be adjusted/mapped by other extensions before landing.
  const plain = plainEquivalentOf(replacement);
  let pos = startPos;
  for (const ch of plain) {
    const curly = resolveSmartQuoteChar(view.state, pos, ch);
    const insert = curly ?? ch;
    view.dispatch({ changes: { from: pos, to: pos, insert } });
    pos = view.state.selection.main.head;
  }
  return true;
}
