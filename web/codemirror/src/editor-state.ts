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

export function getPendingSlashUndo(): boolean {
  return pendingSlashUndo;
}
export function setPendingSlashUndo(value: boolean): void {
  pendingSlashUndo = value;
}

// --- Citation CAYW picker state ---

let pendingCAYWRange: { start: number; end: number } | null = null;

export function getPendingCAYWRange(): { start: number; end: number } | null {
  return pendingCAYWRange;
}
export function setPendingCAYWRange(value: { start: number; end: number } | null): void {
  pendingCAYWRange = value;
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
