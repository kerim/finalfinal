// CAYW (Cite-As-You-Write) integration and lazy citation resolution

import { editorViewCtx } from '@milkdown/kit/core';
import { Plugin, PluginKey, Selection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
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

// Store the command range for each in-flight CAYW request, keyed by an opaque
// requestId (not the raw position — see nextCAYWRequestId below). The Zotero
// round-trip is a real async HTTP call that can take arbitrary time and is NOT
// blocked by the app's own UI, so multiple requests can be in flight at once,
// and a single module-level singleton can't track more than one without one
// silently clobbering another's stored range.
const pendingCAYWRequests = new Map<number, { start: number; end: number }>();
let nextCAYWRequestId = 0;

/** Delete the pending /cite command text from the editor, if the range is still valid */
function deleteCAYWCommandText(view: EditorView, range: { start: number; end: number }): void {
  const { start, end } = range;
  const docSize = view.state.doc.content.size;
  if (start < 0 || end > docSize || start > end) return;
  // Content-identity check: verify the range still contains slash command text.
  // If the user edited while the picker was open, the range may point to different content.
  const textAtRange = view.state.doc.textBetween(start, end, '');
  if (!textAtRange.startsWith('/')) return;
  view.dispatch(view.state.tr.delete(start, end));
}

/**
 * Open Zotero's native CAYW citation picker via Swift bridge
 * The picker is blocking on Zotero's side; we'll get a callback when done
 * @param cmdStart - Position of '/' in /cite command
 * @param cmdEnd - Cursor position at end of /cite (where user stopped typing)
 */
export function openCAYWPicker(cmdStart: number, cmdEnd: number): void {
  const requestId = nextCAYWRequestId++;
  pendingCAYWRequests.set(requestId, { start: cmdStart, end: cmdEnd });

  // Call Swift message handler with the opaque requestId (not the raw position —
  // Swift echoes it back on the eventual callback so we can look up the right
  // entry, even if the position has since been remapped by caywRemapPlugin).
  if (typeof (window as any).webkit?.messageHandlers?.openCitationPicker?.postMessage === 'function') {
    (window as any).webkit.messageHandlers.openCitationPicker.postMessage(requestId);
  } else {
    // Fallback: no Swift bridge available (dev mode)
    pendingCAYWRequests.delete(requestId);
  }
}

/**
 * Open the CAYW picker for a brand-new citation at the current cursor position.
 * Shared trigger for the ⌘⇧K keyboard shortcut (main.ts) and the native toolbar
 * "Cite" button (invoked via window.FinalFinal.insertCitation from Swift) — both
 * insert fresh citations with no existing /cite text to replace, so start and end
 * are the same.
 */
export function insertCitationAtCursor(): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  const view = editorInstance.ctx.get(editorViewCtx);
  const { from } = view.state.selection;
  openCAYWPicker(from, from);
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

  // Look up the stored range for this specific request instead of querying
  // the cursor (cursor position unreliable after focus change). Absent means
  // this request was already resolved/cancelled, or resetCAYWState() ran
  // during the round-trip — silently no-op. This is a load-bearing safety
  // property: no logging, no error, just skip the insertion.
  const range = pendingCAYWRequests.get(data.requestId);
  if (!range) {
    return;
  }

  const { start, end } = range;

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
    pendingCAYWRequests.delete(data.requestId);
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

  pendingCAYWRequests.delete(data.requestId);
}

/**
 * Handle CAYW picker cancelled by user
 */
export function handleCAYWCancelled(requestId: number): void {
  const range = pendingCAYWRequests.get(requestId);
  if (!range) return;
  pendingCAYWRequests.delete(requestId);

  const editorInstance = getEditorInstance();
  if (editorInstance) {
    const view = editorInstance.ctx.get(editorViewCtx);
    deleteCAYWCommandText(view, range);
    view.focus();
  }
}

/**
 * Handle CAYW picker error
 */
export function handleCAYWError(_message: string, requestId: number): void {
  const range = pendingCAYWRequests.get(requestId);
  if (!range) return;
  pendingCAYWRequests.delete(requestId);

  const editorInstance = getEditorInstance();
  if (editorInstance) {
    const view = editorInstance.ctx.get(editorViewCtx);
    deleteCAYWCommandText(view, range);
    view.focus();
  }
  // Error display handled by native NSAlert on Swift side.
  // JS alert() is silently swallowed in WKWebView (no WKUIDelegate).
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
  pendingCAYWRequests: Array<{ requestId: number; start: number; end: number }>;
  hasEditor: boolean;
  docSize: number | null;
} {
  const editorInstance = getEditorInstance();
  return {
    pendingCAYWRequests: Array.from(pendingCAYWRequests, ([requestId, range]) => ({ requestId, ...range })),
    hasEditor: !!editorInstance,
    docSize: editorInstance ? editorInstance.ctx.get(editorViewCtx).state.doc.content.size : null,
  };
}

/**
 * Reset CAYW state (for project switch cleanup)
 */
export function resetCAYWState(): void {
  // Deliberately NOT resetting nextCAYWRequestId here: it must stay monotonic
  // for the entire lifetime of this JS module instance. If it were reset to 0,
  // a stale callback for a request issued before this reset (already in-flight
  // to Zotero, so still capable of resolving later) could arrive AFTER a new
  // request is issued post-reset and collide with its id — letting the stale
  // callback insert into the wrong (new) pending range. An ever-incrementing
  // counter guarantees every requestId ever issued is unique for the module's
  // lifetime, so cross-request id-reuse corruption can never happen.
  pendingCAYWRequests.clear();
  pendingCitekeys.clear();
  if (resolutionTimer) {
    clearTimeout(resolutionTimer);
    resolutionTimer = null;
  }
}

/**
 * Remaps every pending CAYW request's start/end range across doc-changing
 * transactions. The Zotero round-trip is a real async HTTP call that can take
 * arbitrary time and is NOT blocked by the app's own UI — if the user keeps
 * editing while a request is pending, the raw offsets captured at open time go
 * stale. This plugin keeps them accurate so the eventual insertion lands in
 * the right place instead of corrupting or duplicating unrelated content.
 *
 * Bias: start maps with -1 (sticks to content before it — doesn't absorb text
 * inserted exactly at start), end maps with +1 (sticks to content after it —
 * DOES absorb text inserted exactly at end, so text typed inside the pending
 * /cite range extends what gets replaced).
 */
export const caywRemapPlugin = $prose(
  () =>
    new Plugin({
      key: new PluginKey('cayw-remap'),
      state: {
        init: () => null,
        apply(tr) {
          if (tr.docChanged && pendingCAYWRequests.size > 0) {
            for (const [id, range] of pendingCAYWRequests) {
              pendingCAYWRequests.set(id, {
                start: tr.mapping.map(range.start, -1),
                end: tr.mapping.map(range.end, 1),
              });
            }
          }
          return null;
        },
      },
    })
);
