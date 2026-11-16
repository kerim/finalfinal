// Diagnostic logging for macOS text replacements (autocorrect, text replacement, spelling-menu
// fixes) in the Rich Text editor. Task t-717a0bc5: typing near an autocorrection can move text
// to the wrong place. The suspected cause is that the DOM range WebKit hands us in
// `insertReplacementText` is stale, because the spelling underline re-rendered the word in the
// meantime, so `posAtDOM` resolves it to the wrong document positions. These lines go to the
// persistent diagnostic log (same route as the LT-DIAG lines) so a real occurrence shows
// whether the replace positions missed the word. Logging only: nothing here changes behaviour.
//
// t-561c4083: the diagnostic log must never hold pieces of the document. These lines are written
// ONLY while Swift has the typing trace switched on (`isTraceTypingOn()`, the Diagnostics switch),
// each function returns before it reads anything while it is off, and no line contains document
// text, even with the trace on: only positions, lengths and the kind of text (word, space, mixed).

import type { EditorView } from '@milkdown/kit/prose/view';
import { isTraceTypingOn } from './typing-trace';

const diagLog = (msg: string) => {
  const line = `[AUTOCORRECT-DIAG] ${msg}`;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const handler = (window as any).webkit?.messageHandlers?.errorHandler;
  if (handler?.postMessage) handler.postMessage({ type: 'debug', message: line });
  else console.log(line);
};

/** What kind of text `text` is, without saying what it is: empty, a single word, only whitespace, or mixed. */
function kindOf(text: string): 'empty' | 'word' | 'space' | 'mixed' {
  if (text.length === 0) return 'empty';
  if (/^[\p{L}\p{M}\p{N}'’-]+$/u.test(text)) return 'word';
  if (/^\s+$/u.test(text)) return 'space';
  return 'mixed';
}

/** The span [from, to] as `from-to len=<n> kind=<empty|word|space|mixed|out-of-range>`. Never the text itself. */
function describeSpan(view: EditorView, from: number, to: number): string {
  const doc = view.state.doc;
  const size = doc.content.size;
  if (from < 0 || to < 0 || from > size || to > size || from > to) return `${from}-${to} out-of-range docSize=${size}`;
  const kind = kindOf(doc.textBetween(from, to, '¶', '￼'));
  return `${from}-${to} len=${to - from} kind=${kind}`;
}

function describeDomPoint(view: EditorView, node: Node, offset: number): string {
  const kind = node.nodeType === Node.TEXT_NODE ? `#text(len=${node.textContent?.length ?? 0})` : node.nodeName;
  const parent = node.nodeType === Node.TEXT_NODE ? node.parentNode : node;
  const parentClass = parent instanceof Element && parent.className ? `.${parent.className}` : '';
  return `${kind}${parentClass}@${offset}${view.dom.contains(node) ? '' : ' DETACHED'}`;
}

/**
 * Log every input event that is not a plain one-character keystroke or a backspace, so a
 * report shows exactly what macOS sent when an autocorrection fired (inputType, the length of the
 * text, and the target range WebKit attached). Registered before the replacement handler so it
 * sees the event first. Writes nothing, and reads nothing, while the trace switch is off.
 */
export function logUnusualInput(view: EditorView, e: InputEvent): void {
  if (!isTraceTypingOn()) return;
  const data = e.data ?? e.dataTransfer?.getData('text/plain') ?? '';
  const plainKey = e.inputType === 'insertText' && data.length <= 1;
  if (plainKey || e.inputType === 'deleteContentBackward') return;
  const ranges = e.getTargetRanges();
  const rangeText = ranges
    .map(
      (r) =>
        `${describeDomPoint(view, r.startContainer, r.startOffset)} → ${describeDomPoint(view, r.endContainer, r.endOffset)}`
    )
    .join(' | ');
  const { from, to } = view.state.selection;
  diagLog(
    `input type=${e.inputType} dataLen=${data.length} dataNewlines=${data.split('\n').length - 1} ranges=[${rangeText}] ` +
      `selection=${from}-${to} around=${describeSpan(view, from, to)}`
  );
}

/** Log what a replacement is about to do: positions, the kind and length of the text being replaced, the caret. */
export function logReplacementTarget(
  view: EditorView,
  path: string,
  startPos: number,
  endPos: number,
  replacement: string
): void {
  if (!isTraceTypingOn()) return;
  const { from, to } = view.state.selection;
  diagLog(
    `replace path=${path} target=${startPos}-${endPos} replacing=${describeSpan(view, startPos, endPos)} ` +
      `withLen=${replacement.length} withKind=${kindOf(replacement)} selection=${from}-${to} caret=${describeSpan(view, from, to)}`
  );
}

/** Log the span of the inserted text right after the replacement was applied. */
export function logReplacementResult(view: EditorView, startPos: number, replacement: string): void {
  if (!isTraceTypingOn()) return;
  diagLog(`replaced result=${describeSpan(view, startPos, startPos + replacement.length)}`);
}
