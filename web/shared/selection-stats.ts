// Shared selection-stats transport for both editors.
// Pushes the currently selected text to Swift via the `selectionChanged`
// message handler so the status bar can show a live selection word count.
// Swift counts the text with MarkdownUtils.wordCount — the same rules as the
// document total — so the two numbers always agree.
//
// Deduplicated: an unchanged selection sends nothing, a collapsed selection
// sends '' once so Swift clears the count. Each editor bundle gets its own
// module instance, so the dedup state is per-WebView.

export const SELECTION_DEBOUNCE_MS = 150;

let lastSent: string | null = null;

export function postSelection(text: string): void {
  if (text === lastSent) return;
  lastSent = text;
  (
    window as unknown as { webkit?: { messageHandlers?: { selectionChanged?: { postMessage: (m: string) => void } } } }
  ).webkit?.messageHandlers?.selectionChanged?.postMessage(text);
}
