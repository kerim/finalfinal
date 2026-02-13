// CAYW (Cite-As-You-Write) integration and lazy citation resolution

import { editorViewCtx } from '@milkdown/kit/core';
import { Selection } from '@milkdown/kit/prose/state';
import {
  type CSLItem,
  citationNode,
  clearAppendMode,
  clearPendingResolution,
  getEditPopupInput,
  getPendingAppendBase,
  isPendingAppendMode,
  mergeCitations,
  updateEditPreview,
} from './citation-plugin';
import { setCitationLibrary } from './citation-search';
import { getCiteprocEngine } from './citeproc-engine';
import { getEditorInstance } from './editor-state';
import type { CAYWCallbackData, EditCitationCallbackData } from './types';

// === Lazy Citation Resolution ===
// Debounced batch resolution of unresolved citekeys

const pendingCitekeys = new Set<string>();
let resolutionTimer: ReturnType<typeof setTimeout> | null = null;

/**
 * Request lazy resolution of citekeys from Swift/Zotero
 * Batches multiple requests within a 500ms window
 */
export function requestCitationResolutionInternal(keys: string[]): void {
  for (const k of keys) {
    pendingCitekeys.add(k);
  }

  // Debounce: wait 500ms before sending to batch multiple requests
  if (resolutionTimer) {
    clearTimeout(resolutionTimer);
  }

  resolutionTimer = setTimeout(() => {
    const keysToResolve = Array.from(pendingCitekeys);
    pendingCitekeys.clear();
    resolutionTimer = null;

    if (keysToResolve.length === 0) return;

    // Call Swift message handler
    if (typeof (window as any).webkit?.messageHandlers?.resolveCitekeys?.postMessage === 'function') {
      (window as any).webkit.messageHandlers.resolveCitekeys.postMessage(keysToResolve);
    } else {
      // Swift bridge not available - clear pending state since resolution won't happen
      clearPendingResolution(keysToResolve);
    }
  }, 500);
}

// === CAYW (Cite-As-You-Write) Integration ===

// Store the command range for CAYW callback (start = /cite position, end = cursor after /cite)
let pendingCAYWRange: { start: number; end: number } | null = null;

/**
 * Open Zotero's native CAYW citation picker via Swift bridge
 * The picker is blocking on Zotero's side; we'll get a callback when done
 * @param cmdStart - Position of '/' in /cite command
 * @param cmdEnd - Cursor position at end of /cite (where user stopped typing)
 */
export function openCAYWPicker(cmdStart: number, cmdEnd: number): void {
  pendingCAYWRange = { start: cmdStart, end: cmdEnd };

  // Call Swift message handler (only pass cmdStart, Swift doesn't need end)
  if (typeof (window as any).webkit?.messageHandlers?.openCitationPicker?.postMessage === 'function') {
    (window as any).webkit.messageHandlers.openCitationPicker.postMessage(cmdStart);
  } else {
    // Fallback: no Swift bridge available (dev mode)
    pendingCAYWRange = null;
  }
}

/**
 * Handle successful CAYW picker callback from Swift
 * Inserts citation node at the stored position range, or appends to existing citation in edit popup
 */
export function handleCAYWCallback(data: CAYWCallbackData, items: CSLItem[]): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    return;
  }

  // Check for append mode - merging new citations with existing ones in edit popup
  if (isPendingAppendMode()) {
    const pendingBase = getPendingAppendBase();

    // Update citeproc engine with new items
    const engine = getCiteprocEngine();
    engine.addItems(items);
    setCitationLibrary(items);

    // Merge the citations
    const merged = mergeCitations(pendingBase, data.rawSyntax);

    // Update the edit popup input
    const editInput = getEditPopupInput();
    if (editInput) {
      editInput.value = merged;
      updateEditPreview();
      // Keep the popup open and input focused so user can make further edits
      // or press Enter to commit
      editInput.focus();
    } else {
      // Popup was closed, focus the editor
      const view = editorInstance.ctx.get(editorViewCtx);
      view.focus();
    }

    // Clear append mode state
    clearAppendMode();
    return;
  }

  // Use stored range instead of querying cursor (cursor position unreliable after focus change)
  if (!pendingCAYWRange) {
    return;
  }

  const { start, end } = pendingCAYWRange;

  // Update citeproc engine with the new items
  const engine = getCiteprocEngine();
  engine.addItems(items);

  // Update citation library cache
  setCitationLibrary(items);

  // Insert citation node
  const view = editorInstance.ctx.get(editorViewCtx);
  const nodeType = citationNode.type(editorInstance.ctx);

  const citekeyStr = data.citekeys.join(',');

  const node = nodeType.create({
    citekeys: citekeyStr,
    locators: data.locators,
    prefix: data.prefix,
    suffix: '',
    suppressAuthor: data.suppressAuthor,
    rawSyntax: data.rawSyntax,
  });

  // Validate range is within document bounds
  const docSize = view.state.doc.content.size;
  if (start < 0 || end > docSize || start > end) {
    pendingCAYWRange = null;
    return;
  }

  try {
    // Delete from start to end (removes /cite text) and insert citation node
    let tr = view.state.tr.replaceRangeWith(start, end, node);

    // Set cursor after the inserted citation node
    const insertPos = start + node.nodeSize;
    tr = tr.setSelection(Selection.near(tr.doc.resolve(insertPos)));

    view.dispatch(tr);
    view.focus();
  } catch (_e) {
    // Citation insertion failed
  }

  pendingCAYWRange = null;
}

/**
 * Handle CAYW picker cancelled by user
 */
export function handleCAYWCancelled(): void {
  pendingCAYWRange = null;

  // Focus editor
  const editorInstance = getEditorInstance();
  if (editorInstance) {
    const view = editorInstance.ctx.get(editorViewCtx);
    view.focus();
  }
}

/**
 * Handle CAYW picker error
 */
export function handleCAYWError(message: string): void {
  pendingCAYWRange = null;

  // Show alert to user
  alert(message);

  // Focus editor
  const editorInstance = getEditorInstance();
  if (editorInstance) {
    const view = editorInstance.ctx.get(editorViewCtx);
    view.focus();
  }
}

/**
 * Handle edit citation callback from Swift
 * Updates an existing citation node at the specified position
 */
export function handleEditCitationCallback(data: EditCitationCallbackData, items: CSLItem[]): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    return;
  }

  // Add items to citeproc engine (use addItems with array, not addItem)
  const engine = getCiteprocEngine();
  engine.addItems(items);

  const view = editorInstance.ctx.get(editorViewCtx);
  const pos = data.pos;

  // Verify node at position is a citation
  const node = view.state.doc.nodeAt(pos);
  if (!node || node.type.name !== 'citation') {
    return;
  }

  // Update the citation node with new attributes
  const citekeyStr = data.citekeys.join(',');
  const tr = view.state.tr.setNodeMarkup(pos, undefined, {
    citekeys: citekeyStr,
    locators: data.locators,
    prefix: data.prefix,
    suffix: '',
    suppressAuthor: data.suppressAuthor,
    rawSyntax: data.rawSyntax,
  });

  view.dispatch(tr);
  view.focus();
}

/**
 * Get CAYW debug state for Swift to query
 */
export function getCAYWDebugState(): {
  pendingCAYWRange: { start: number; end: number } | null;
  hasEditor: boolean;
  docSize: number | null;
} {
  const editorInstance = getEditorInstance();
  return {
    pendingCAYWRange,
    hasEditor: !!editorInstance,
    docSize: editorInstance ? editorInstance.ctx.get(editorViewCtx).state.doc.content.size : null,
  };
}

/**
 * Reset CAYW state (for project switch cleanup)
 */
export function resetCAYWState(): void {
  pendingCAYWRange = null;
  pendingCitekeys.clear();
  if (resolutionTimer) {
    clearTimeout(resolutionTimer);
    resolutionTimer = null;
  }
}
