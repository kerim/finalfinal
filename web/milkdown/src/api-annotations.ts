// Annotation + citation API method implementations for window.FinalFinal

import { editorViewCtx } from '@milkdown/kit/core';
import { Selection } from '@milkdown/kit/prose/state';
import {
  setAnnotationDisplayModes as setDisplayModes,
  setHideCompletedTasks as setHideCompletedTasksPlugin,
} from './annotation-display-plugin';
import { type AnnotationType, annotationNode } from './annotation-plugin';
import {
  handleCAYWCallback,
  handleCAYWCancelled,
  handleCAYWError,
  handleEditCitationCallback,
  getCAYWDebugState as getCAYWDebugStateImpl,
  requestCitationResolutionInternal,
} from './cayw';
import type { CSLItem } from './citation-plugin';
import { clearPendingResolution } from './citation-plugin';
import {
  getCitationLibrary,
  getCitationLibrarySize,
  setCitationLibrary,
} from './citation-search';
import { getCiteprocEngine } from './citeproc-engine';
import { getEditorInstance } from './editor-state';
import { highlightMark } from './highlight-plugin';
import { scrollToOffset } from './api-modes';
import type { CAYWCallbackData, EditCitationCallbackData } from './types';

export function setAnnotationDisplayModes(modes: Record<string, string>): void {
  setDisplayModes(modes);
  // Trigger redecoration by dispatching an empty transaction
  const editorInstance = getEditorInstance();
  if (editorInstance) {
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      view.dispatch(view.state.tr);
    } catch {
      // Dispatch failed, ignore
    }
  }
}

export function getAnnotations(): Array<{ type: string; text: string; offset: number; completed?: boolean }> {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return [];

  const annotations: Array<{ type: string; text: string; offset: number; completed?: boolean }> = [];

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { doc } = view.state;

    doc.descendants((node, pos) => {
      if (node.type.name === 'annotation') {
        // Text is now content of the node, not an attribute
        const text = node.textContent || '';
        annotations.push({
          type: node.attrs.type,
          text: text.trim(),
          offset: pos,
          completed: node.attrs.type === 'task' ? node.attrs.isCompleted : undefined,
        });
      }
      return true;
    });
  } catch {
    // Traversal failed, return empty
  }

  return annotations;
}

export function scrollToAnnotation(offset: number): void {
  scrollToOffset(offset);
}

export function insertAnnotation(type: string): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  if (!['task', 'comment', 'reference'].includes(type)) return;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { from } = view.state.selection;
    const nodeType = annotationNode.type(editorInstance.ctx);

    // Create annotation node with no text content (enables :empty placeholder CSS)
    const node = nodeType.create(
      { type: type as AnnotationType, isCompleted: false }
      // No text content - allows CSS :empty::before placeholder to show
    );

    let tr = view.state.tr.insert(from, node);
    // Position cursor inside the annotation's content area
    // from = start of annotation node, from + 1 = inside node's content
    tr = tr.setSelection(Selection.near(tr.doc.resolve(from + 1)));
    view.dispatch(tr);
    view.focus();
  } catch {
    // Insert failed, ignore
  }
}

export function setHideCompletedTasks(enabled: boolean): void {
  setHideCompletedTasksPlugin(enabled);
  // Trigger redecoration by dispatching an empty transaction
  const editorInstance = getEditorInstance();
  if (editorInstance) {
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      view.dispatch(view.state.tr);
    } catch {
      // Dispatch failed, ignore
    }
  }
}

export function toggleHighlight(): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { from, to, empty } = view.state.selection;

    // Require a selection - highlighting empty text makes no sense
    if (empty) {
      return false;
    }

    // Get the highlight mark type from the schema
    const markType = highlightMark.type(editorInstance.ctx);

    // Check if the selection already has the highlight mark
    const { doc } = view.state;
    let hasHighlight = false;
    doc.nodesBetween(from, to, (node) => {
      if (markType.isInSet(node.marks)) {
        hasHighlight = true;
      }
    });

    let tr = view.state.tr;
    if (hasHighlight) {
      // Remove the highlight mark
      tr = tr.removeMark(from, to, markType);
    } else {
      // Add the highlight mark
      tr = tr.addMark(from, to, markType.create());
    }

    view.dispatch(tr);
    view.focus();

    return true;
  } catch {
    return false;
  }
}

// === Citation API ===

export function setCitationLibraryApi(items: CSLItem[]): void {
  // Update search index
  setCitationLibrary(items);
  // Update citeproc engine
  getCiteprocEngine().setBibliography(items);
  // Notify citation nodes that library has been updated
  // This allows them to re-render with formatted display
  document.dispatchEvent(new CustomEvent('citation-library-updated'));
  // Trigger re-render of any existing citations
  const editorInstance = getEditorInstance();
  if (editorInstance) {
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      view.dispatch(view.state.tr);
    } catch {
      // Dispatch failed, ignore
    }
  }
}

export function setCitationStyle(styleXML: string): void {
  getCiteprocEngine().setStyle(styleXML);
  // Trigger re-render of citations
  const editorInstance = getEditorInstance();
  if (editorInstance) {
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      view.dispatch(view.state.tr);
    } catch {
      // Dispatch failed, ignore
    }
  }
}

export function getBibliographyCitekeys(): string[] {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return [];

  const citekeys: string[] = [];

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { doc } = view.state;

    doc.descendants((node) => {
      if (node.type.name === 'citation') {
        const keys = ((node.attrs.citekeys as string) || '').split(',').filter((k) => k.trim());
        citekeys.push(...keys);
      }
      return true;
    });
  } catch {
    // Traversal failed
  }

  // Return unique citekeys
  return [...new Set(citekeys)];
}

export function getCitationCount(): number {
  return getCitationLibrarySize();
}

export function getAllCitekeys(): string[] {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return [];

  const citekeys = new Set<string>();

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    view.state.doc.descendants((node) => {
      if (node.type.name === 'citation' && node.attrs.citekeys) {
        const keys = (node.attrs.citekeys as string).split(',').filter((k) => k.trim());
        for (const k of keys) {
          citekeys.add(k.trim());
        }
      }
      return true;
    });
  } catch {
    // Traversal failed
  }

  return Array.from(citekeys);
}

export function requestCitationResolution(keys: string[]): void {
  requestCitationResolutionInternal(keys);
}

export function addCitationItems(items: CSLItem[]): void {
  // Add items to citeproc engine without replacing existing
  getCiteprocEngine().addItems(items);
  // Update the citation library cache
  setCitationLibrary([...getCitationLibrary(), ...items]);
  // Clear pending resolution state for these keys
  const resolvedKeys = items.map((item) => (item as any)['citation-key'] || item.citationKey || item.id);
  clearPendingResolution(resolvedKeys);
  // Trigger re-render of all citations
  document.dispatchEvent(new CustomEvent('citation-library-updated'));
}

export function searchCitationsCallback(items: CSLItem[]): void {
  // Legacy callback - update citeproc with items
  const engine = getCiteprocEngine();
  engine.addItems(items);
  setCitationLibrary(items);
}

// CAYW picker callback delegates
export function citationPickerCallback(data: CAYWCallbackData, items: CSLItem[]): void {
  handleCAYWCallback(data, items);
}

export function citationPickerCancelled(): void {
  handleCAYWCancelled();
}

export function citationPickerError(message: string): void {
  handleCAYWError(message);
}

export function editCitationCallback(data: EditCitationCallbackData, items: CSLItem[]): void {
  handleEditCitationCallback(data, items);
}

export function getCAYWDebugState(): {
  pendingCAYWRange: { start: number; end: number } | null;
  hasEditor: boolean;
  docSize: number | null;
} {
  return getCAYWDebugStateImpl();
}
