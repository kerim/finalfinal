// Diagnostic logging for macOS text replacements (autocorrect, text replacement, spelling-menu
// fixes) in the Rich Text editor. Task t-717a0bc5: typing near an autocorrection can move text
// to the wrong place. The suspected cause is that the DOM range WebKit hands us in
// `insertReplacementText` is stale, because the spelling underline re-rendered the word in the
// meantime, so `posAtDOM` resolves it to the wrong document positions. These lines go to the
// persistent diagnostic log (same route as the LT-DIAG lines) so a real occurrence shows
// whether the replace positions missed the word. Logging only: nothing here changes behaviour.

import type { EditorView } from '@milkdown/kit/prose/view';

const diagLog = (msg: string) => {
  const line = `[AUTOCORRECT-DIAG] ${msg}`;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const handler = (window as any).webkit?.messageHandlers?.errorHandler;
  if (handler?.postMessage) handler.postMessage({ type: 'debug', message: line });
  else console.log(line);
};

/** Text of the document around [from, to], with the range itself in ⟦ ⟧. */
function snippet(view: EditorView, from: number, to: number, pad = 25): string {
  const doc = view.state.doc;
  const size = doc.content.size;
  if (from < 0 || to < 0 || from > size || to > size || from > to) return `(out of range, docSize=${size})`;
  const text = (a: number, b: number) => doc.textBetween(a, b, '¶', '￼');
  return JSON.stringify(
    `${text(Math.max(0, from - pad), from)}⟦${text(from, to)}⟧${text(to, Math.min(size, to + pad))}`
  );
}

function describeDomPoint(view: EditorView, node: Node, offset: number): string {
  const kind = node.nodeType === Node.TEXT_NODE ? `#text(len=${node.textContent?.length ?? 0})` : node.nodeName;
  const parent = node.nodeType === Node.TEXT_NODE ? node.parentNode : node;
  const parentClass = parent instanceof Element && parent.className ? `.${parent.className}` : '';
  return `${kind}${parentClass}@${offset}${view.dom.contains(node) ? '' : ' DETACHED'}`;
}

/**
 * Log every input event that is not a plain one-character keystroke or a backspace, so a
 * report shows exactly what macOS sent when an autocorrection fired (inputType, text, and the
 * target range WebKit attached). Registered before the replacement handler so it sees the
 * event first.
 */
export function logUnusualInput(view: EditorView, e: InputEvent): void {
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
    `input type=${e.inputType} data=${JSON.stringify(data.slice(0, 80))} ranges=[${rangeText}] ` +
      `selection=${from}-${to} around=${snippet(view, from, to)}`
  );
}

/** Log what a replacement is about to do: positions, the text being replaced, the caret. */
export function logReplacementTarget(
  view: EditorView,
  path: string,
  startPos: number,
  endPos: number,
  replacement: string
): void {
  const { from, to } = view.state.selection;
  diagLog(
    `replace path=${path} target=${startPos}-${endPos} replacing=${snippet(view, startPos, endPos)} ` +
      `with=${JSON.stringify(replacement.slice(0, 80))} selection=${from}-${to} caretText=${snippet(view, from, to)}`
  );
}

/** Log the document around the inserted text right after the replacement was applied. */
export function logReplacementResult(view: EditorView, startPos: number, replacement: string): void {
  diagLog(`replaced result=${snippet(view, startPos, startPos + replacement.length)}`);
}
