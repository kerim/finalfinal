// Content-related API method implementations for window.FinalFinal

import { editorViewCtx, parserCtx } from '@milkdown/kit/core';
import { Slice } from '@milkdown/kit/prose/model';
import { Selection } from '@milkdown/kit/prose/state';
import { getMarkdown } from '@milkdown/kit/utils';
import {
  applyPendingConfirmations,
  clearBlockIds,
  confirmBlockIds as confirmBlockIdsPlugin,
  getAllBlockIds,
  getBlockIdAtPos,
  resetBlockIdState,
  setBlockIdsForTopLevel,
} from './block-id-plugin';
import {
  type BlockChanges,
  destroyBlockSyncState,
  getBlockChanges as getBlockChangesPlugin,
  hasPendingChanges,
  resetAndSnapshot,
  setSyncPaused,
  updateSnapshotIds,
} from './block-sync-plugin';
import { resetCAYWState } from './cayw';
import {
  getCurrentContent,
  getEditorInstance,
  setCurrentContent,
  setIsSettingContent,
  setPendingSlashRedo,
  setPendingSlashUndo,
} from './editor-state';
import { clearSearch } from './find-replace';
import { isSourceModeEnabled } from './source-mode-plugin';
import type { Block } from './types';

export function setContent(markdown: string, options?: { scrollToStart?: boolean }): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    setCurrentContent(markdown);
    return;
  }

  // Handle empty content FIRST - ensure doc has valid empty paragraph, not section_break
  // This must run BEFORE the currentContent === markdown check because:
  // - Editor may initialize with section_break due to schema default
  // - currentContent starts as '' so the equality check would skip the fix
  if (!markdown.trim()) {
    editorInstance.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      const doc = view.state.doc;

      // Check if already a valid empty paragraph (optimization: skip if already correct)
      if (doc.childCount === 1 && doc.firstChild?.type.name === 'paragraph' && doc.firstChild?.textContent === '') {
        setCurrentContent(markdown);
        return;
      }

      // Replace with empty paragraph
      setSyncPaused(true);
      setIsSettingContent(true);
      try {
        const emptyParagraph = view.state.schema.nodes.paragraph.create();
        const emptyDoc = view.state.schema.nodes.doc.create(null, emptyParagraph);
        const tr = view.state.tr.replaceWith(0, view.state.doc.content.size, emptyDoc.content);
        view.dispatch(tr.setSelection(Selection.atStart(tr.doc)));
        resetAndSnapshot(view.state.doc);
        setCurrentContent(markdown);
      } finally {
        setIsSettingContent(false);
        setSyncPaused(false);
      }
    });
    return;
  }

  // For non-empty content, skip if unchanged
  if (getCurrentContent() === markdown) {
    return;
  }

  setSyncPaused(true);
  setIsSettingContent(true);
  try {
    editorInstance.action((ctx) => {
      const view = ctx.get(editorViewCtx);

      const parser = ctx.get(parserCtx);
      let doc;
      try {
        doc = parser(markdown);
      } catch (e) {
        console.error('[Milkdown] Parser error:', e instanceof Error ? e.message : e);
        console.error('[Milkdown] Stack:', e instanceof Error ? e.stack : 'N/A');
        return;
      }
      if (!doc) {
        console.error('[Milkdown] Parser returned null/undefined doc');
        return;
      }

      const { from } = view.state.selection;
      const docSize = view.state.doc.content.size;
      let tr = view.state.tr.replace(0, docSize, new Slice(doc.content, 0, 0));

      // For zoom transitions, set selection to start; otherwise try to preserve position
      if (options?.scrollToStart) {
        tr = tr.setSelection(Selection.atStart(tr.doc));
      } else {
        const safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));
        try {
          tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
        } catch {
          tr = tr.setSelection(Selection.atStart(tr.doc));
        }
      }
      view.dispatch(tr);
      resetAndSnapshot(view.state.doc);

      // Reset scroll position for zoom transitions
      // Swift handles hiding/showing the WKWebView at compositor level
      if (options?.scrollToStart) {
        // Reset scroll immediately
        view.dom.scrollTop = 0;
        window.scrollTo({ top: 0, left: 0, behavior: 'instant' });

        // Force layout calculation
        void view.dom.offsetHeight;
        void document.body.offsetHeight;

        // Wait for actual paint to complete using double RAF
        // First RAF: queued after current frame
        // Second RAF: queued after the paint of the first frame
        // This ensures the browser has actually rendered the content
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            // CRITICAL: Force compositor refresh with micro-scroll
            // WKWebView's compositor caches the previous content.
            // A scroll triggers compositor refresh, showing the new content.
            window.scrollTo({ top: 1, left: 0, behavior: 'instant' });
            window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
            view.dom.scrollTop = 0;

            // Signal Swift that paint is complete
            if (typeof (window as any).webkit?.messageHandlers?.paintComplete?.postMessage === 'function') {
              (window as any).webkit.messageHandlers.paintComplete.postMessage({
                scrollHeight: view.dom.scrollHeight,
                timestamp: Date.now(),
              });
            }
          });
        });
      }
    });
    setCurrentContent(markdown);
  } finally {
    setIsSettingContent(false);
    setSyncPaused(false);
  }
}

export function getContent(): string {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return getCurrentContent();

  const sourceEnabled = isSourceModeEnabled();
  let markdown = getMarkdown()(editorInstance.ctx);

  // Unescape heading syntax that ProseMirror's serializer escapes in paragraphs.
  // This happens when users paste markdown as plain text - Milkdown creates
  // paragraph nodes and the serializer escapes # to prevent heading interpretation.
  // Only matches \# followed by 1-5 more # chars and whitespace at line start.
  markdown = markdown.replace(/^\\(#{1,6}\s)/gm, '$1');

  // Fix double ## prefixes in source mode: "## ## Heading" → "## Heading"
  if (sourceEnabled) {
    markdown = markdown.replace(/^(#{1,6}) \1 /gm, '$1 ');
  }

  const trimmed = markdown.trim();

  // Empty/minimal document may serialize to just a section break marker - treat as empty
  if (trimmed === '' || trimmed === '<!-- ::break:: -->') {
    return '';
  }

  setCurrentContent(markdown);
  return markdown;
}

export function resetEditorState(): void {
  resetForProjectSwitch();
}

export function resetForProjectSwitch(): void {
  const editorInstance = getEditorInstance();

  // Reset block-related state
  resetBlockIdState();
  destroyBlockSyncState();
  setCurrentContent('');
  setIsSettingContent(false);
  setPendingSlashUndo(false);
  setPendingSlashRedo(false);
  // Clear search state
  clearSearch();

  // Clear CAYW and citation state
  resetCAYWState();

  // Clear document via normal transaction (preserves ProseMirror's internal layout caches,
  // unlike updateState() which destroys them and causes rendering issues on project switch)
  if (editorInstance) {
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      const emptyParagraph = view.state.schema.nodes.paragraph.create();
      const emptyDoc = view.state.schema.nodes.doc.create(null, emptyParagraph);
      const tr = view.state.tr
        .replace(0, view.state.doc.content.size, new Slice(emptyDoc.content, 0, 0))
        .setSelection(Selection.atStart(view.state.tr.doc));
      tr.setMeta('addToHistory', false);
      view.dispatch(tr);
      view.dom.scrollTop = 0;
    } catch {
      // State reset failed, ignore
    }
  }

  // Reset scroll position to top (prevents previous project's scroll persisting)
  window.scrollTo(0, 0);
  document.documentElement.scrollTop = 0;
  document.body.scrollTop = 0;
}

export function applyBlocks(blocks: Block[]): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const parser = editorInstance.ctx.get(parserCtx);

    // Sort blocks by sortOrder
    const sortedBlocks = [...blocks].sort((a, b) => a.sortOrder - b.sortOrder);

    // Assemble markdown from blocks
    const markdown = sortedBlocks.map((b) => b.markdownFragment).join('\n\n');

    // Parse and replace document content
    setSyncPaused(true);
    setIsSettingContent(true);
    try {
      const doc = parser(markdown);
      if (!doc) return;

      const { from } = view.state.selection;
      const docSize = view.state.doc.content.size;
      let tr = view.state.tr.replace(0, docSize, new Slice(doc.content, 0, 0));

      // Try to preserve cursor position
      const safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));
      try {
        tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
      } catch {
        tr = tr.setSelection(Selection.atStart(tr.doc));
      }

      view.dispatch(tr);
      setCurrentContent(markdown);

      // Clear stale temp IDs from assignBlockIds, set real IDs, rebuild snapshot
      clearBlockIds();
      const blockIds = sortedBlocks.map((b) => b.id);
      setBlockIdsForTopLevel(blockIds, view.state.doc);
      resetAndSnapshot(view.state.doc);
    } finally {
      setIsSettingContent(false);
      setSyncPaused(false);
    }
  } catch (e) {
    console.error('[Milkdown] applyBlocks failed:', e);
  }
}

export function setContentWithBlockIds(markdown: string, blockIds: string[], options?: { scrollToStart?: boolean }): void {
  // 1. Set content (parse, dispatch, resetAndSnapshot already called inside)
  setContent(markdown, options);
  // 2. Immediately assign real block IDs (still synchronous, same JS turn)
  const editorInstance = getEditorInstance();
  if (blockIds.length > 0 && editorInstance) {
    const view = editorInstance.ctx.get(editorViewCtx);
    setBlockIdsForTopLevel(blockIds, view.state.doc);
    resetAndSnapshot(view.state.doc);
  }
}

export function scrollToBlock(blockId: string): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const blockIds = getAllBlockIds();

    // Find position for this block ID
    let targetPos: number | null = null;
    for (const [pos, id] of blockIds) {
      if (id === blockId) {
        targetPos = pos;
        break;
      }
    }

    if (targetPos === null) return;

    // Scroll to the block
    const selection = Selection.near(view.state.doc.resolve(targetPos + 1));
    view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
    view.focus();
  } catch (e) {
    console.error('[Milkdown] scrollToBlock failed:', e);
  }
}

export function getBlockAtCursor(): { blockId: string; offset: number } | null {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return null;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { head } = view.state.selection;
    const $head = view.state.doc.resolve(head);

    // Find the nearest block containing the cursor
    for (let depth = $head.depth; depth > 0; depth--) {
      const pos = $head.before(depth);
      const blockId = getBlockIdAtPos(pos);
      if (blockId) {
        // Calculate offset within the block
        const offset = head - pos - 1; // -1 for node start boundary
        return { blockId, offset: Math.max(0, offset) };
      }
    }

    return null;
  } catch (e) {
    console.error('[Milkdown] getBlockAtCursor failed:', e);
    return null;
  }
}

export function hasBlockChanges(): boolean {
  return hasPendingChanges();
}

export function getBlockChangesApi(): BlockChanges {
  return getBlockChangesPlugin();
}

export function confirmBlockIdsApi(mapping: Record<string, string>): void {
  confirmBlockIdsPlugin(mapping);
  const applied = applyPendingConfirmations();
  updateSnapshotIds(applied);
  // No empty transaction needed — IDs updated synchronously in maps
}

export function syncBlockIds(orderedIds: string[]): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  const view = editorInstance.ctx.get(editorViewCtx);
  setBlockIdsForTopLevel(orderedIds, view.state.doc);
  resetAndSnapshot(view.state.doc);
}
