import type { Extension } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import type { FindOptions } from './types';

// --- Editor instance ---

let editorView: EditorView | null = null;

export function getEditorView(): EditorView | null {
  return editorView;
}
export function setEditorView(view: EditorView | null): void {
  editorView = view;
}

// --- Editor extensions (used by initEditor and resetForProjectSwitch) ---

let editorExtensions: Extension[] = [];

export function getEditorExtensions(): Extension[] {
  return editorExtensions;
}
export function setEditorExtensions(ext: Extension[]): void {
  editorExtensions = ext;
}

// --- Slash command undo tracking ---

let pendingSlashUndo = false;

/** N3 (major, Phase B remediation plan) -- mirrors Milkdown's editor-state.ts (see its
 * comment for the full rationale): how long a `setPendingSlashUndo(true)` stays honorable
 * before it's considered stale. */
export const PENDING_SLASH_UNDO_FRESHNESS_MS = 5000;
let pendingSlashUndoSetAt = 0;

export function getPendingSlashUndo(): boolean {
  return pendingSlashUndo;
}
export function setPendingSlashUndo(value: boolean): void {
  pendingSlashUndo = value;
  if (value) pendingSlashUndoSetAt = Date.now();
}
/** True only while `pendingSlashUndo` is set AND was set within the freshness window (N3). */
export function isPendingSlashUndoFresh(): boolean {
  return pendingSlashUndo && Date.now() - pendingSlashUndoSetAt <= PENDING_SLASH_UNDO_FRESHNESS_MS;
}

// --- Citation CAYW picker state ---

// Store the command range for each in-flight CAYW request, keyed by an opaque
// requestId (not the raw position — see allocateCAYWRequestId below). The Zotero
// round-trip is a real async HTTP call that can take arbitrary time and is NOT
// blocked by the app's own UI, so multiple requests can be in flight at once,
// and a single module-level singleton can't track more than one without one
// silently clobbering another's stored range. Mirrors pendingCAYWRequests in
// web/milkdown/src/cayw.ts. Positions are kept accurate across intervening edits
// by cayw-remap-plugin.ts's ViewPlugin (registered in main.ts).
const pendingCAYWRequests = new Map<number, { start: number; end: number }>();
let nextCAYWRequestId = 0;

/** Returns the live pending-requests map (callers mutate it directly via get/set/delete). */
export function getPendingCAYWRequests(): Map<number, { start: number; end: number }> {
  return pendingCAYWRequests;
}

/** Allocates and returns a new, never-reused requestId. */
export function allocateCAYWRequestId(): number {
  return nextCAYWRequestId++;
}

/**
 * Clears all pending CAYW requests (for project-switch cleanup). Deliberately does NOT
 * reset the requestId counter: it must stay monotonic for the entire lifetime of this JS
 * module instance. If it were reset to 0, a stale callback for a request issued before this
 * reset (already in-flight to Zotero, so still capable of resolving later) could arrive AFTER
 * a new request is issued post-reset and collide with its id — letting the stale callback
 * insert into the wrong (new) pending range. An ever-incrementing counter guarantees every
 * requestId ever issued is unique for the module's lifetime, so cross-request id-reuse
 * corruption can never happen.
 */
export function clearPendingCAYWRequests(): void {
  pendingCAYWRequests.clear();
}

// --- Append mode state for adding citations to existing ones ---

let pendingAppendMode = false;
let pendingAppendRange: { start: number; end: number } | null = null;

export function getPendingAppendMode(): boolean {
  return pendingAppendMode;
}
export function setPendingAppendMode(value: boolean): void {
  pendingAppendMode = value;
}
export function getPendingAppendRange(): { start: number; end: number } | null {
  return pendingAppendRange;
}
export function setPendingAppendRange(value: { start: number; end: number } | null): void {
  pendingAppendRange = value;
}

// --- Floating add citation button ---

let citationAddButton: HTMLElement | null = null;

export function getCitationAddButton(): HTMLElement | null {
  return citationAddButton;
}
export function setCitationAddButton(value: HTMLElement | null): void {
  citationAddButton = value;
}

// --- Search state ---

let currentSearchQuery = '';
let currentSearchOptions: FindOptions = {};
let currentMatchIndex = 0;

export function getCurrentSearchQuery(): string {
  return currentSearchQuery;
}
export function setCurrentSearchQuery(value: string): void {
  currentSearchQuery = value;
}
export function getCurrentSearchOptions(): FindOptions {
  return currentSearchOptions;
}
export function setCurrentSearchOptions(value: FindOptions): void {
  currentSearchOptions = value;
}
export function getCurrentMatchIndex(): number {
  return currentMatchIndex;
}
export function setCurrentMatchIndex(value: number): void {
  currentMatchIndex = value;
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
