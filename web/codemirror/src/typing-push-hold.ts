// The Markdown typing push, held while a Cmd-Z / Cmd-Shift-Z press is latched (Phase 4c job 2, plan-v2-amendments.md section 4 and judge D1).
//
// Markdown typing reaches Swift in one way: main.ts posts `contentChanged {content, wasUndo}` 50 ms after the last change. While a press is
// latched (waiting for an earlier section command, then being carried out) that push is HELD instead of posted: if the press ends with the
// typing put back on top of the undone document (decision `rebased`), the typing is saved exactly once, by the replay (Swift's step-8 flush
// reads the page's live text after the job); a held push sent first would be saved, replaced by the snapshot job, and saved again.
//
// Every other way out of the press releases the held push as the first thing that happens (D1): `releaseTypingPushes('send')` posts ONE
// push with the live text. `'discard'` is used only after a successful replay and when the editor is reset. Both are idempotent.
//
// Swift needs no change for this: the lifecycle flush (Cmd-W, Cmd-Q, project switch) and every other Swift-side read of the Markdown text
// PULL it (`getContent` / `getContentRaw` return `view.state.doc`, EditorViewState+Lifecycle.swift step 5), so held typing is always seen.

import { getEditorView } from './editor-state';

let held = false;
let owed: { wasUndo: boolean } | null = null;

/** The one place the page posts the debounced typing push. Reads the live document at call time. */
export function postContentPush(wasUndo: boolean): void {
  const view = getEditorView();
  if (!view) return;
  const raw = view.state.doc.toString(); // raw includes anchors
  (window as any).webkit?.messageHandlers?.contentChanged?.postMessage({ content: raw, wasUndo });
}

/** main.ts's 50 ms debounce calls this instead of posting: the push is sent now, or owed until the hold is released. */
export function pushOrHoldContent(wasUndo: boolean): void {
  if (!held) {
    postContentPush(wasUndo);
    return;
  }
  owed = { wasUndo: (owed?.wasUndo ?? false) || wasUndo };
}

/** A press was latched: typing pushes are held from now on until `releaseTypingPushes`. */
export function holdTypingPushes(): void {
  held = true;
}

export function isTypingPushHeld(): boolean {
  return held;
}

/** True when a push is owed (typing happened while held and has not been sent). For tests. */
export function hasOwedTypingPush(): boolean {
  return owed !== null;
}

/** Forgets the owed push but keeps holding (the replay carried the typing; the press has not answered yet). */
export function discardOwedTypingPush(): void {
  owed = null;
}

/** Ends the hold. `'send'` posts the owed push (if any) before returning; `'discard'` forgets it. Idempotent. */
export function releaseTypingPushes(mode: 'send' | 'discard'): void {
  held = false;
  const pending = owed;
  owed = null;
  if (pending && mode === 'send') postContentPush(pending.wasUndo);
}
