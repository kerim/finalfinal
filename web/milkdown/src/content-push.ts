// The editor's `contentChanged` notification to Swift, in one place.
//
// main.ts's 50 ms typing debounce posts it after the document changed: serialise the live document, remember the text as the
// editor's current content, and tell Swift (`webkit.messageHandlers.contentChanged`, which sets `editorState.content`). The quick
// undo of a section delete (api-section-undo.ts, `resumeSyncAfterQuickUndo`) sends the very same notification once it has handed
// block-sync back, so Swift learns the restored text the way it learns typed text, with no whole-document push into the editor.
// One function, so the two senders cannot drift apart.

import { getMarkdown } from '@milkdown/kit/utils';
import { getEditorInstance, setCurrentContent } from './editor-state';
import { syncLog } from './sync-debug';

/**
 * Serialises the live document, stores it as the editor's current content and posts `contentChanged` to Swift. No guards: both
 * callers check `getIsSettingContent()` / `getContentHasBeenSet()` themselves (the timer path re-checks them when it fires).
 * Returns the serialised text, or null when there is no editor.
 */
export function pushLiveContentToSwift(wasUndo: boolean): string | null {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return null;
  const md = editorInstance.action(getMarkdown());
  setCurrentContent(md);
  // t-561c4083: the heading's length only, never its text (the diagnostic log must hold no pieces of the document).
  const firstHeadingLen = md.match(/^#{1,6}\s+.*/m)?.[0]?.length ?? 0;
  syncLog('ContentPush', `PUSHED: len=${md.length}, firstHLen=${firstHeadingLen}`);
  (window as any).webkit?.messageHandlers?.contentChanged?.postMessage({ content: md, wasUndo });
  return md;
}
