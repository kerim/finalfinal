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
  setBlockIdZoomMode,
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
  clearContentPushTimer,
  getCurrentContent,
  getEditorInstance,
  setContentHasBeenSet,
  setCurrentContent,
  setIsSettingContent,
  setPendingSlashRedo,
  setPendingSlashUndo,
  setZoomFootnoteState,
} from './editor-state';
import { clearSearch } from './find-replace';
import { consumePendingDropPos } from './image-plugin';
import { isSourceModeEnabled } from './source-mode-plugin';
import { syncLog } from './sync-debug';
import type { Block, ImageBlockMeta } from './types';

/** Re-snapshot in the next animation frame, then unpause sync.
 *  Ensures normalization transactions are absorbed before change detection resumes. */
function deferredSnapshotAndUnpause(): void {
  requestAnimationFrame(() => {
    const inst = getEditorInstance();
    if (inst) {
      const v = inst.ctx.get(editorViewCtx);
      resetAndSnapshot(v.state.doc);
    }
    setSyncPaused(false);
  });
}

export function setContent(markdown: string, options?: { scrollToStart?: boolean }): void {
  syncLog('API:setContent', `entry len=${markdown.length} scrollToStart=${options?.scrollToStart ?? false}`);

  // NOTE: Do NOT clear zoom mode here. setContent() is called from updateNSView
  // during zoom, and clearing zoom mode causes temp IDs to be generated for mini-Notes
  // nodes before pushBlockIds re-enables it. Zoom mode is independently managed by:
  // - setContentWithBlockIds() for full document loads
  // - resetForProjectSwitch() for project switches
  // - syncBlockIds() with explicit zoomMode parameter
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    setCurrentContent(markdown);
    return;
  }

  setContentHasBeenSet(true);
  clearContentPushTimer();  // Cancel stale timers — both empty-content and normal paths replace doc

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
        setCurrentContent(markdown);
      } finally {
        setIsSettingContent(false);
        deferredSnapshotAndUnpause();
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

      // Preserve figure attributes not encoded in markdown (width, blockId)
      // Markdown ![alt](src) does NOT encode width or blockId — re-parsing loses them.
      // Use positional matching with src verification (consistent with applyBlocks/setContentWithBlockIds pattern)
      const savedFigures: Array<{ src: string; width: number | null; blockId: string }> = [];
      view.state.doc.forEach((node) => {
        if (node.type.name === 'figure') {
          savedFigures.push({
            src: node.attrs.src || '',
            width: node.attrs.width,
            blockId: node.attrs.blockId || '',
          });
        }
      });

      if (savedFigures.length > 0) {
        syncLog(
          'API:setContent',
          `figures before replace: ${savedFigures.map((f) => `src=${f.src.split('/').pop()} w=${f.width}`).join(', ')}`
        );
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

      // Restore figure attributes by position with src verification
      // (Matches applyBlocks/setContentWithBlockIds pattern — BEFORE resetAndSnapshot)
      if (savedFigures.length > 0) {
        let figureIdx = 0;
        let metaTr = view.state.tr;
        let restoredCount = 0;
        view.state.doc.forEach((node, pos) => {
          if (node.type.name === 'figure' && figureIdx < savedFigures.length) {
            const saved = savedFigures[figureIdx];
            // Only restore if src matches (same image at same position)
            if (node.attrs.src === saved.src) {
              const updates: Record<string, any> = { ...node.attrs };
              if (saved.width != null) updates.width = saved.width;
              if (saved.blockId) updates.blockId = saved.blockId;
              if (updates.width !== node.attrs.width || updates.blockId !== node.attrs.blockId) {
                metaTr = metaTr.setNodeMarkup(pos, undefined, updates);
                restoredCount++;
              }
            }
            figureIdx++;
          }
        });
        if (metaTr.steps.length > 0) view.dispatch(metaTr);
        syncLog('API:setContent', `figures after restore: ${restoredCount}/${savedFigures.length}`);
      }

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
    // Delay snapshot + unpause to RAF so normalization transactions are absorbed
    deferredSnapshotAndUnpause();
  }
}

export function getContent(): string {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return getCurrentContent();

  const sourceEnabled = isSourceModeEnabled();
  const rawMarkdown = getMarkdown()(editorInstance.ctx);
  let markdown = rawMarkdown;

  // Unescape heading syntax that ProseMirror's serializer escapes in paragraphs.
  const beforeHeadingUnescape = markdown;
  markdown = markdown.replace(/^\\(#{1,6}\s)/gm, '$1');
  if (markdown !== beforeHeadingUnescape) {
    syncLog('API:getContent', 'heading unescape applied');
  }

  // Unescape footnote definition brackets escaped by ProseMirror's serializer.
  const beforeFootnoteUnescape = markdown;
  markdown = markdown.replace(/^\\(\[\^\d+\]:)/gm, '$1');
  if (markdown !== beforeFootnoteUnescape) {
    syncLog('API:getContent', 'footnote unescape applied');
  }

  // Fix double ## prefixes in source mode: "## ## Heading" → "## Heading"
  if (sourceEnabled) {
    const beforeDoubleFix = markdown;
    markdown = markdown.replace(/^(#{1,6}) \1 /gm, '$1 ');
    if (markdown !== beforeDoubleFix) {
      syncLog('API:getContent', 'double-## prefix fix applied');
    }
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
  clearContentPushTimer();  // Defense in depth — prevent stale timer from old project
  const editorInstance = getEditorInstance();

  // Reset block-related state
  resetBlockIdState();
  destroyBlockSyncState();
  setCurrentContent('');
  setContentHasBeenSet(false);
  setIsSettingContent(false);
  setPendingSlashUndo(false);
  setPendingSlashRedo(false);
  setZoomFootnoteState(false, 0);
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
  clearContentPushTimer();  // Cancel stale timers before document replacement
  syncLog('API:applyBlocks', `entry blocks=${blocks.length} syncPaused=true`);
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const parser = editorInstance.ctx.get(parserCtx);

    // Sort blocks by sortOrder, then filter empty fragments (stay in sync with Swift BlockParser)
    const sortedBlocks = [...blocks].sort((a, b) => a.sortOrder - b.sortOrder);
    const nonEmptyBlocks = sortedBlocks.filter((b) => b.markdownFragment.trim().length > 0);

    // Assemble markdown from non-empty blocks
    const markdown = nonEmptyBlocks.map((b) => b.markdownFragment).join('\n\n');

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

      // Clear stale temp IDs from assignBlockIds, set real IDs, rebuild snapshot.
      // NOTE: blockIds should already be collapsed for list merging on the Swift side
      // (consecutive same-type list blocks map to a single PM list node).
      clearBlockIds();
      const blockIds = nonEmptyBlocks.map((b) => b.id);
      setBlockIdsForTopLevel(blockIds, view.state.doc);

      // Inject image metadata (caption, width) from block data into figure nodes
      // MUST use nonEmptyBlocks to keep positional figure matching aligned
      const figureBlocks = nonEmptyBlocks.filter((b) => b.blockType === 'image');
      if (figureBlocks.length > 0) {
        let figureIdx = 0;
        let metaTr = view.state.tr;
        view.state.doc.forEach((node, pos) => {
          if (node.type.name === 'figure' && figureIdx < figureBlocks.length) {
            const block = figureBlocks[figureIdx];
            metaTr = metaTr.setNodeMarkup(pos, undefined, {
              ...node.attrs,
              caption: block.imageCaption || '',
              width: block.imageWidth || null,
              blockId: block.id,
            });
            figureIdx++;
          }
        });
        if (metaTr.steps.length > 0) view.dispatch(metaTr);
      }
    } finally {
      setIsSettingContent(false);
      // Delay snapshot + unpause to RAF so normalization transactions are absorbed
      deferredSnapshotAndUnpause();
    }
  } catch (e) {
    console.error('[Milkdown] applyBlocks failed:', e);
  }
}

export function setContentWithBlockIds(
  markdown: string,
  blockIds: string[],
  options?: { scrollToStart?: boolean; imageMeta?: ImageBlockMeta[]; cursorBoundary?: number }
): void {
  clearContentPushTimer();  // Cancel stale timers before document replacement
  syncLog(
    'API:setContentWithBlockIds',
    `entry len=${markdown.length} blocks=${blockIds.length} scrollToStart=${options?.scrollToStart ?? false}`
  );
  setBlockIdZoomMode(false); // Clear zoom mode when loading full content
  setContentHasBeenSet(true);
  const editorInstance = getEditorInstance();
  if (!editorInstance) {
    setCurrentContent(markdown);
    return;
  }

  // Empty content: clear block IDs and snapshot
  if (!markdown.trim()) {
    setIsSettingContent(true);
    setSyncPaused(true);
    try {
      editorInstance.action((ctx) => {
        const view = ctx.get(editorViewCtx);
        const emptyParagraph = view.state.schema.nodes.paragraph.create();
        const emptyDoc = view.state.schema.nodes.doc.create(null, emptyParagraph);
        const tr = view.state.tr.replaceWith(0, view.state.doc.content.size, emptyDoc.content);
        view.dispatch(tr.setSelection(Selection.atStart(tr.doc)));
        clearBlockIds();
      });
      setCurrentContent(markdown);
    } finally {
      setIsSettingContent(false);
      deferredSnapshotAndUnpause();
    }
    return;
  }

  // Match applyBlocks pattern: sync paused through ENTIRE operation
  setIsSettingContent(true);
  setSyncPaused(true);
  let parseSucceeded = false;
  try {
    editorInstance.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      const parser = ctx.get(parserCtx);

      let doc;
      try {
        doc = parser(markdown);
      } catch (e) {
        console.error('[Milkdown] setContentWithBlockIds parser error:', e);
        resetAndSnapshot(view.state.doc);
        return;
      }
      if (!doc) {
        resetAndSnapshot(view.state.doc);
        return;
      }

      const { from } = view.state.selection;
      const docSize = view.state.doc.content.size;
      let tr = view.state.tr.replace(0, docSize, new Slice(doc.content, 0, 0));

      if (options?.scrollToStart) {
        tr = tr.setSelection(Selection.atStart(tr.doc));
      } else {
        let safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));

        // Clamp cursor before bibliography section to prevent typing into bib paragraphs.
        // cursorBoundary is the node index of the first bibliography block.
        const boundary = options?.cursorBoundary ?? -1;
        let bibPos = doc.content.size;
        if (boundary >= 0) {
          let nodeIdx = 0;
          doc.forEach((_node, pos) => {
            if (nodeIdx === boundary) {
              bibPos = pos;
            }
            nodeIdx++;
          });
          if (safeFrom >= bibPos) {
            safeFrom = Math.max(0, bibPos - 1);
          }
        }

        syncLog(
          'API:setContentWithBlockIds',
          `cursor: from=${from} safeFrom=${safeFrom} boundary=${boundary} bibPos=${bibPos} docSize=${doc.content.size}`
        );

        try {
          tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
        } catch {
          tr = tr.setSelection(Selection.atStart(tr.doc));
        }
      }
      view.dispatch(tr);
      parseSucceeded = true;

      // Clear stale IDs, assign real ones, snapshot — all within syncPaused
      clearBlockIds();
      if (blockIds.length > 0) {
        setBlockIdsForTopLevel(blockIds, view.state.doc);
      }

      // Inject image metadata (width, caption, blockId) into figure nodes
      // Same pattern as applyBlocks — matches figure nodes positionally with metadata
      const imageMeta = options?.imageMeta;
      if (imageMeta && imageMeta.length > 0) {
        let figureIdx = 0;
        let metaTr = view.state.tr;
        view.state.doc.forEach((node, pos) => {
          if (node.type.name === 'figure' && figureIdx < imageMeta.length) {
            const meta = imageMeta[figureIdx];
            metaTr = metaTr.setNodeMarkup(pos, undefined, {
              ...node.attrs,
              caption: meta.caption || '',
              width: meta.width || null,
              blockId: meta.id,
            });
            figureIdx++;
          }
        });
        if (metaTr.steps.length > 0) view.dispatch(metaTr);
      }
    });
    if (parseSucceeded) {
      setCurrentContent(markdown);
    }
  } finally {
    setIsSettingContent(false);
    // Delay snapshot + unpause to RAF so normalization transactions are absorbed
    deferredSnapshotAndUnpause();
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

    if (targetPos === null) {
      return;
    }

    // Scroll to position ~100px from top for visual consistency with scrollToOffset
    const coords = view.coordsAtPos(targetPos + 1);
    if (coords) {
      const targetScrollY = coords.top + window.scrollY - 100;
      window.scrollTo({ top: Math.max(0, targetScrollY), behavior: 'smooth' });
    }
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

export function syncBlockIds(orderedIds: string[], zoomMode: boolean): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  const view = editorInstance.ctx.get(editorViewCtx);
  setBlockIdZoomMode(zoomMode); // Set zoom mode based on caller context
  setBlockIdsForTopLevel(orderedIds, view.state.doc);
  resetAndSnapshot(view.state.doc);
}

/**
 * Insert an image figure node at the end of the document.
 * Called from Swift after image import completes.
 */
export function insertImage(opts: {
  src: string;
  alt: string;
  caption: string;
  width: number | null;
  blockId: string;
}): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const figureType = view.state.schema.nodes.figure;
    if (!figureType) {
      console.error('[Milkdown] figure node type not found in schema');
      return;
    }

    // Remove ghost inline images from ProseMirror state (not just DOM).
    // WebKit's native performDragOperation can insert <img> elements before
    // JS events fire; ProseMirror incorporates them as inline image nodes.
    // Legitimate images use the projectmedia:// scheme, never blob:/data:.
    const imageType = view.state.schema.nodes.image;
    let tr = view.state.tr;
    if (imageType) {
      const removals: { from: number; to: number }[] = [];
      view.state.doc.descendants((node, pos) => {
        if (node.type === imageType) {
          const src = (node.attrs.src as string) || '';
          if (src.startsWith('blob:') || src.startsWith('data:')) {
            removals.push({ from: pos, to: pos + node.nodeSize });
          }
        }
      });
      if (removals.length > 0) {
        syncLog('API:insertImage', `removing ${removals.length} ghost image(s)`);
        // Delete in reverse order to preserve earlier positions
        for (let i = removals.length - 1; i >= 0; i--) {
          tr = tr.delete(removals[i].from, removals[i].to);
        }
      }
    }
    // DOM cleanup as belt-and-suspenders
    for (const el of document.querySelectorAll('img[src^="blob:"], img[src^="data:"]')) {
      el.remove();
    }

    const node = figureType.create({
      src: opts.src,
      alt: opts.alt,
      caption: opts.caption,
      width: opts.width,
      blockId: opts.blockId,
    });

    // Use pending drop position if available (from handleDrop), otherwise insert after cursor's block
    // Compute against tr.doc (which may have had ghost images removed)
    let insertPos: number;
    const dropPos = consumePendingDropPos();
    const docSize = tr.doc.content.size;
    syncLog('API:insertImage', `dropPos=${dropPos} docSize=${docSize}`);
    if (dropPos !== null && dropPos >= 0 && dropPos <= docSize) {
      insertPos = dropPos;
    } else {
      // Fallback: after current selection's top-level block
      try {
        const { from } = view.state.selection;
        const $from = tr.doc.resolve(Math.min(from, docSize));
        insertPos = $from.after(1);
      } catch {
        insertPos = tr.doc.content.size;
      }
    }
    tr = tr.insert(insertPos, node);
    view.dispatch(tr);
  } catch (e) {
    console.error('[Milkdown] insertImage failed:', e);
  }
}

/**
 * Surgically update heading levels in the editor without replacing the document.
 * Called from Swift hierarchy enforcement to avoid the DB-to-editor round-trip
 * that causes content discrepancy and data loss.
 */
export function updateHeadingLevels(changes: Array<{ blockId: string; newLevel: number }>): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance || changes.length === 0) return;

  syncLog('API:updateHeadingLevels', `${changes.length} changes`);
  setSyncPaused(true);
  setIsSettingContent(true);
  try {
    editorInstance.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      const blockIds = getAllBlockIds(); // Map<pos, id>

      // Invert: id → pos
      const idToPos = new Map<string, number>();
      for (const [pos, id] of blockIds) {
        idToPos.set(id, pos);
      }

      let tr = view.state.tr;
      let appliedCount = 0;
      for (const change of changes) {
        const pos = idToPos.get(change.blockId);
        if (pos === undefined) {
          syncLog('API:updateHeadingLevels', `WARN: blockId ${change.blockId.slice(0, 8)} not found`);
          continue;
        }
        const node = tr.doc.nodeAt(pos);
        if (!node || node.type.name !== 'heading') continue;
        tr = tr.setNodeMarkup(pos, undefined, {
          ...node.attrs,
          level: change.newLevel,
        });
        appliedCount++;
      }

      if (tr.steps.length > 0) {
        view.dispatch(tr);
      }

      // Update currentContent to match post-surgery state
      // (prevents stale currentContent from causing issues with setContent unchanged check)
      setCurrentContent(getMarkdown()(ctx));

      syncLog('API:updateHeadingLevels', `applied ${appliedCount}/${changes.length} changes`);
    });
  } finally {
    setIsSettingContent(false);
    // Delay snapshot + unpause to RAF so normalization transactions are absorbed
    deferredSnapshotAndUnpause();
  }
}
