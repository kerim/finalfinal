// Shared mutable state for the Milkdown editor
// Other modules import getter/setter functions instead of accessing module-level variables directly

import type { Editor } from '@milkdown/kit/core';

let editorInstance: Editor | null = null;
let currentContent = '';
let isSettingContent = false;

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

export function getPendingSlashUndo(): boolean {
  return pendingSlashUndo;
}
export function setPendingSlashUndo(value: boolean): void {
  pendingSlashUndo = value;
}

export function getPendingSlashRedo(): boolean {
  return pendingSlashRedo;
}
export function setPendingSlashRedo(value: boolean): void {
  pendingSlashRedo = value;
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
