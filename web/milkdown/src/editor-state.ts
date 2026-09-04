// Shared mutable state for the Milkdown editor
// Other modules import getter/setter functions instead of accessing module-level variables directly

import type { Editor } from '@milkdown/kit/core';
import type { ExpectedBlockMeta, ImageBlockMeta } from './types';

let editorInstance: Editor | null = null;
let currentContent = '';
let isSettingContent = false;

// True only once the editor instance exists AND its view DOM has been parented into #editor
// (main.ts's initEditor(), after `root.appendChild(...)`). Deliberately NOT derived from
// getEditorInstance() !== null -- setEditorInstance() runs before the DOM append, so a check
// against the instance alone would report "mounted" one tick too early (t-18576cf7).
let editorMounted = false;

export function isEditorMounted(): boolean {
  return editorMounted;
}
export function setEditorMounted(value: boolean): void {
  editorMounted = value;
}

/** The full argument set of one `setContentWithBlockIds` call that arrived before the editor
 * instance existed. Stashed whole (not just the markdown string) so main.ts's post-mount
 * replay can call `setContentWithBlockIds` again with the caller's real block UUIDs, image
 * metadata, and cursor boundaries intact -- see api-content.ts's no-instance branch and
 * main.ts's replay block (t-18576cf7). */
export interface PendingBlockContent {
  markdown: string;
  blockIds: string[];
  options?: {
    scrollToStart?: boolean;
    imageMeta?: ImageBlockMeta[];
    cursorBoundary?: number;
    cursorBoundaryEnd?: number;
    detectPausedEdits?: boolean;
    expected?: ExpectedBlockMeta[];
    zoomMode?: boolean;
    scrollToBlockId?: string;
  };
}
let pendingBlockContent: PendingBlockContent | null = null;

export function getPendingBlockContent(): PendingBlockContent | null {
  return pendingBlockContent;
}
export function setPendingBlockContent(value: PendingBlockContent | null): void {
  pendingBlockContent = value;
}

// Track slash command execution for smart undo/redo
let pendingSlashUndo = false;
let pendingSlashRedo = false;

export function getEditorInstance(): Editor | null {
  return editorInstance;
}
export function setEditorInstance(instance: Editor | null): void {
  editorInstance = instance;
}

export function getCurrentContent(): string {
  return currentContent;
}
export function setCurrentContent(content: string): void {
  currentContent = content;
}

export function getIsSettingContent(): boolean {
  return isSettingContent;
}
export function setIsSettingContent(value: boolean): void {
  isSettingContent = value;
}

/** N3 (major, Phase B remediation plan): how long a `setPendingSlashUndo(true)` stays
 * honorable before it's considered stale. Nothing resets this flag except an actual editing
 * keystroke (character key, Backspace, Delete -- see the keydown handler in
 * slash-commands.ts) -- a slash command followed by clicking elsewhere, scrolling, or simply
 * waiting leaves it sitting `true` indefinitely. 5s comfortably covers "the user hit Cmd-Z
 * right away after the slash command fired" (the actual use case) while bounding how long an
 * unrelated LATER Cmd-Z can be misrouted into the smart two-step slash-undo instead of a
 * plain (or structural) undo. */
export const PENDING_SLASH_UNDO_FRESHNESS_MS = 5000;
let pendingSlashUndoSetAt = 0;

export function getPendingSlashUndo(): boolean {
  return pendingSlashUndo;
}
export function setPendingSlashUndo(value: boolean): void {
  pendingSlashUndo = value;
  if (value) pendingSlashUndoSetAt = Date.now();
}
/** True only while `pendingSlashUndo` is set AND was set within the freshness window (N3).
 * Use this instead of `getPendingSlashUndo()` at every Cmd-Z decision point so a stale flag
 * can never silently swallow an unrelated later undo (structural or plain-text). */
export function isPendingSlashUndoFresh(): boolean {
  return pendingSlashUndo && Date.now() - pendingSlashUndoSetAt <= PENDING_SLASH_UNDO_FRESHNESS_MS;
}

export function getPendingSlashRedo(): boolean {
  return pendingSlashRedo;
}
export function setPendingSlashRedo(value: boolean): void {
  pendingSlashRedo = value;
}

// Gate: prevents contentPushTimer from firing before Swift has called setContent/setContentWithBlockIds.
// Implicit contract: Swift MUST call setContent() or setContentWithBlockIds() before the editor
// becomes interactive. All current code paths do this (EditorPreloader → claim → loadContent).
let contentHasBeenSet = false;

export function getContentHasBeenSet(): boolean {
  return contentHasBeenSet;
}
export function setContentHasBeenSet(value: boolean): void {
  contentHasBeenSet = value;
}

// Content push timer management — shared so api-content.ts can clear stale timers
// when Swift programmatically replaces document content (prevents race conditions)
let contentPushTimer: ReturnType<typeof setTimeout> | null = null;

export function setContentPushTimer(timer: ReturnType<typeof setTimeout>): void {
  contentPushTimer = timer;
}

export function clearContentPushTimer(): void {
  if (contentPushTimer) {
    clearTimeout(contentPushTimer);
    contentPushTimer = null;
  }
}

// Track zoom mode state for footnote insertion
let isZoomMode = false;
let documentFootnoteCount = 0;

export function getIsZoomMode(): boolean {
  return isZoomMode;
}
export function getDocumentFootnoteCount(): number {
  return documentFootnoteCount;
}
export function setZoomFootnoteState(zoomed: boolean, maxLabel: number): void {
  isZoomMode = zoomed;
  documentFootnoteCount = maxLabel;
}
