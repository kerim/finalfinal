// Content-related API method implementations for window.FinalFinal

import { editorViewCtx, parserCtx } from '@milkdown/kit/core';
import type { NodeType, Node as ProsemirrorNode, ResolvedPos } from '@milkdown/kit/prose/model';
import { Slice } from '@milkdown/kit/prose/model';
import { Selection, type Transaction } from '@milkdown/kit/prose/state';
import { getMarkdown } from '@milkdown/kit/utils';
import {
  applyPendingConfirmations,
  clearBlockIds,
  confirmBlockIds as confirmBlockIdsPlugin,
  getAllBlockIds,
  getBlockIdAtPos,
  resetBlockIdState,
  SYNC_DIAG_DETAIL,
  setBlockIdsForTopLevel,
  setBlockIdZoomMode,
} from './block-id-plugin';
import {
  type BlockChanges,
  type BlockSnapshot,
  destroyBlockSyncState,
  detectPausedEditsAndSnapshot,
  flushPendingBlockChanges as flushPendingBlockChangesPlugin,
  getBlockChanges as getBlockChangesPlugin,
  hasPendingChanges,
  resetAndSnapshot,
  setSyncPaused,
  snapshotBlocks,
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
import { consumePendingDropPos, consumePendingPastePos } from './image-plugin';
import { isSourceModeEnabled } from './source-mode-plugin';
import { syncLog } from './sync-debug';
import type { Block, ExpectedBlockMeta, ImageBlockMeta } from './types';

/** Re-snapshot in the next animation frame, then unpause sync.
 *  Ensures normalization transactions are absorbed before change detection resumes.
 *  When `detectPausedEdits` is true, edits made while sync was paused are queued
 *  as pending changes instead of being silently discarded, by diffing `baseline`
 *  (a snapshot the caller captured at the moment its own paused push settled —
 *  NOT the ambient last-known state, which may reflect an unrelated prior reset)
 *  against the document as it stands once the pause ends. See
 *  detectPausedEditsAndSnapshot() for the full reasoning and safety constraints. */
function deferredSnapshotAndUnpause(detectPausedEdits = false, baseline?: Map<string, BlockSnapshot>): void {
  requestAnimationFrame(() => {
    const inst = getEditorInstance();
    if (inst) {
      const v = inst.ctx.get(editorViewCtx);
      if (detectPausedEdits && baseline) {
        detectPausedEditsAndSnapshot(v.state.doc, baseline);
      } else {
        resetAndSnapshot(v.state.doc);
      }
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
  clearContentPushTimer(); // Cancel stale timers — both empty-content and normal paths replace doc

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
        view.dispatch(tr.setMeta('addToHistory', false).setSelection(Selection.atStart(tr.doc)));
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
      view.dispatch(tr.setMeta('addToHistory', false));

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
        if (metaTr.steps.length > 0) view.dispatch(metaTr.setMeta('addToHistory', false));
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

  // Unescape backticks that ProseMirror's serializer escapes in text nodes.
  // Safe: ProseMirror does not escape inside code_block nodes, only inline text.
  // Global regex (not line-anchored) is correct because escaped backticks only appear in inline text.
  if (!sourceEnabled) {
    const beforeBacktickUnescape = markdown;
    markdown = markdown.replace(/\\`/g, '`');
    if (markdown !== beforeBacktickUnescape) {
      syncLog('API:getContent', 'backtick unescape applied');
    }
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
  clearContentPushTimer(); // Defense in depth — prevent stale timer from old project
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
  clearContentPushTimer(); // Cancel stale timers before document replacement
  syncLog('API:applyBlocks', `entry blocks=${blocks.length} syncPaused=true`);
  // [SYNC-DIAG Round 2] First-few (id, blockType, textLen) so we can correlate
  // Swift's block-array shape with the DOM that ends up in the editor.
  if (SYNC_DIAG_DETAIL) {
    const firstFew = blocks
      .slice(0, 5)
      .map((b) => `(${b.id.slice(0, 8)},${b.blockType},txtLen=${b.textContent?.length ?? 0})`);
    syncLog('API:applyBlocks', `firstFew=[${firstFew.join(',')}]`);
  }
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

      view.dispatch(tr.setMeta('addToHistory', false));
      setCurrentContent(markdown);

      // Clear stale temp IDs from assignBlockIds, set real IDs, rebuild snapshot.
      // NOTE: blockIds should already be collapsed for list merging on the Swift side
      // (consecutive same-type list blocks map to a single PM list node).
      clearBlockIds();
      const blockIds = nonEmptyBlocks.map((b) => b.id);
      // NOTE: as of this writing, no Swift call site invokes window.FinalFinal.applyBlocks
      // (verified via repo-wide grep) — likely superseded by setContentWithBlockIds. Hardened
      // here anyway for uniformity/future-proofing; zero live-path risk either way.
      const expected: ExpectedBlockMeta[] = nonEmptyBlocks.map((b) => ({
        blockType: b.blockType,
        nonEmpty: b.textContent.trim().length > 0,
      }));
      setBlockIdsForTopLevel(blockIds, view.state.doc, expected);

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
              width: block.imageWidth ?? node.attrs.width ?? null,
              blockId: block.id,
            });
            figureIdx++;
          }
        });
        if (metaTr.steps.length > 0) view.dispatch(metaTr.setMeta('addToHistory', false));
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

// ---------------------------------------------------------------------------
// Block-level LCS diff for setContentWithBlockIds
//
// setContentWithBlockIds() used to replace the ENTIRE document in a single
// tr.replace(0, docSize, ...) step every time a background resync
// (bibliography/notes/footnote regeneration, zoom in/out, project restore,
// generic block rebuild, etc.) pushed new content. Per prosemirror-history's
// position-mapping rules, one step spanning the whole document collapses
// every earlier undo-history position to the boundary of that single step —
// even for content that didn't actually change. That silently broke undo for
// anything the user did shortly before a resync fired (e.g. deleting a
// citation, then having the bibliography resync land ~1s later, before they
// pressed Cmd+Z).
//
// The fix: diff the two documents' TOP-LEVEL blocks (paragraphs, headings,
// etc. — depth-1 children of the doc root) using a standard LCS algorithm
// with Node.eq() as the equality test, then replace only the specific block
// ranges that actually differ, each via its own tr.replace() call within one
// transaction. Blocks the LCS matches as unchanged keep their original
// identity/position (shifted only by the size deltas of earlier-replaced
// ranges, via tr.mapping) — so undo-history positions pointing into them
// survive intact.
// ---------------------------------------------------------------------------

/** A single contiguous run of top-level blocks that differs between the old
 * and new document, expressed as block INDICES (not document positions) into
 * each document's top-level child array. `oldFrom`/`newFrom` are inclusive,
 * `oldTo`/`newTo` are exclusive — the same convention as Array.slice. */
export interface BlockChangeRange {
  oldFrom: number;
  oldTo: number;
  newFrom: number;
  newTo: number;
}

/** Document positions of every top-level block boundary, indexed by block
 * index: starts[i] is the position immediately before block i, and
 * starts[doc.childCount] is the position immediately after the last block
 * (== doc.content.size). Translates the block-index ranges
 * diffTopLevelBlocks() produces into document/Fragment-cut positions. */
export function topLevelBlockStarts(doc: ProsemirrorNode): number[] {
  const starts: number[] = [0];
  let pos = 0;
  doc.forEach((node) => {
    pos += node.nodeSize;
    starts.push(pos);
  });
  return starts;
}

/** Cap on DP table cells (rows * cols of the trimmed middle) above which we
 * give up on finding the minimal diff and fall back to treating the entire
 * trimmed middle as one changed range — still bounded to the region that
 * actually differs (never the whole document), just not minimal within it.
 * Sized to keep worst-case memory/time in the tens-of-MB / low-hundreds-of-ms
 * range even for unusually large documents. */
const DIFF_DP_CELL_CAP = 4_000_000;

/**
 * Diff the top-level blocks of `oldDoc` and `newDoc` and return the list of
 * disjoint block-index ranges that differ, in document order.
 *
 * Uses the standard longest-common-subsequence algorithm (Node.eq() as the
 * match predicate) over the top-level block arrays, after trimming any
 * common prefix/suffix. This is what lets two separate edits on either side
 * of an untouched block (e.g. a citation's own paragraph, unchanged by a
 * resync that touches a paragraph before it AND one after it) come back as
 * TWO disjoint ranges rather than one range spanning — and replacing —
 * everything in between; that is the whole point of this fix (see the
 * bibliography-resync regression test in __tests__/block-diff.test.ts).
 *
 * Returns an empty array when the two documents' top-level blocks are
 * entirely `.eq()`-identical (nothing to replace).
 *
 * --- Accepted residual risk: content-identical duplicate blocks ---
 * When several top-level blocks are fully `.eq()`-identical to each other
 * (e.g. multiple paragraphs that each contain only the same citation
 * `[@samekey]`, or repeated blank spacer paragraphs) AND a resync also
 * changes how many such duplicates exist nearby, the LCS has no way to know
 * — from content alone — which specific occurrence a stale undo-history
 * position was pointing at; every duplicate is an equally valid match. The
 * backtrack below resolves ties deterministically but arbitrarily with
 * respect to "which occurrence" — it may sweep a duplicate a human would
 * consider "the same one" into a replaced range instead of matching it. This
 * is inherent to any purely content-based diff (there's no identity to
 * disambiguate identical content) and isn't fixable by improving this
 * algorithm specifically. The worst case is still strictly better than the
 * pre-fix behavior: at most the ambiguous duplicate-block region's undo
 * history is affected, never the whole document's. A test pins the current
 * arbitrary-but-deterministic behavior so a future change can't silently
 * regress it into sweeping in MORE blocks than necessary.
 */
export function diffTopLevelBlocks(oldDoc: ProsemirrorNode, newDoc: ProsemirrorNode): BlockChangeRange[] {
  const oldBlocks: ProsemirrorNode[] = [];
  oldDoc.forEach((node) => {
    oldBlocks.push(node);
  });
  const newBlocks: ProsemirrorNode[] = [];
  newDoc.forEach((node) => {
    newBlocks.push(node);
  });

  // Trim common prefix.
  let prefixLen = 0;
  const maxCommon = Math.min(oldBlocks.length, newBlocks.length);
  while (prefixLen < maxCommon && oldBlocks[prefixLen].eq(newBlocks[prefixLen])) {
    prefixLen++;
  }

  // Trim common suffix, bounded so it never overlaps the already-trimmed prefix.
  let suffixLen = 0;
  const maxSuffix = maxCommon - prefixLen;
  while (
    suffixLen < maxSuffix &&
    oldBlocks[oldBlocks.length - 1 - suffixLen].eq(newBlocks[newBlocks.length - 1 - suffixLen])
  ) {
    suffixLen++;
  }

  const oldMid = oldBlocks.slice(prefixLen, oldBlocks.length - suffixLen);
  const newMid = newBlocks.slice(prefixLen, newBlocks.length - suffixLen);

  if (oldMid.length === 0 && newMid.length === 0) {
    return [];
  }

  const m = oldMid.length;
  const n = newMid.length;

  // Fallback for pathologically large middles: one range spanning the whole
  // trimmed middle (== today's whole-document behavior, but bounded to the
  // region that actually differs rather than the entire document).
  if (m * n > DIFF_DP_CELL_CAP) {
    return [
      {
        oldFrom: prefixLen,
        oldTo: oldBlocks.length - suffixLen,
        newFrom: prefixLen,
        newTo: newBlocks.length - suffixLen,
      },
    ];
  }

  // dp[i][j] = length of the LCS of oldMid[i:] and newMid[j:].
  const dp: Int32Array[] = new Array(m + 1);
  for (let i = 0; i <= m; i++) dp[i] = new Int32Array(n + 1);
  for (let i = m - 1; i >= 0; i--) {
    for (let j = n - 1; j >= 0; j--) {
      dp[i][j] = oldMid[i].eq(newMid[j]) ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  // Backtrack to find the matched (unchanged) block index pairs, in order.
  const matches: Array<{ oldIdx: number; newIdx: number }> = [];
  {
    let i = 0;
    let j = 0;
    while (i < m && j < n) {
      if (oldMid[i].eq(newMid[j]) && dp[i][j] === dp[i + 1][j + 1] + 1) {
        matches.push({ oldIdx: i, newIdx: j });
        i++;
        j++;
      } else if (dp[i + 1][j] >= dp[i][j + 1]) {
        i++;
      } else {
        j++;
      }
    }
  }

  // Convert the gaps between matches (plus before-the-first/after-the-last)
  // into disjoint change ranges, offsetting back into full-document block
  // indices (undoing the prefix trim).
  const ranges: BlockChangeRange[] = [];
  let prevOld = 0;
  let prevNew = 0;
  for (const match of matches) {
    if (match.oldIdx > prevOld || match.newIdx > prevNew) {
      ranges.push({
        oldFrom: prefixLen + prevOld,
        oldTo: prefixLen + match.oldIdx,
        newFrom: prefixLen + prevNew,
        newTo: prefixLen + match.newIdx,
      });
    }
    prevOld = match.oldIdx + 1;
    prevNew = match.newIdx + 1;
  }
  if (prevOld < m || prevNew < n) {
    ranges.push({
      oldFrom: prefixLen + prevOld,
      oldTo: prefixLen + m,
      newFrom: prefixLen + prevNew,
      newTo: prefixLen + n,
    });
  }

  return ranges;
}

/**
 * Apply the block-level diff between `oldDoc` and `newDoc` to `tr` (which
 * must currently be positioned at `oldDoc`), replacing only the block ranges
 * that actually differ instead of the whole document. Each range is applied
 * via its own tr.replace() call in document order; positions are mapped
 * through `tr.mapping` before each call so earlier replacements in the same
 * loop (which may have changed content length) don't throw off later ones.
 */
export function buildBlockLevelReplace(tr: Transaction, oldDoc: ProsemirrorNode, newDoc: ProsemirrorNode): Transaction {
  const ranges = diffTopLevelBlocks(oldDoc, newDoc);
  if (ranges.length === 0) return tr;

  const oldStarts = topLevelBlockStarts(oldDoc);
  const newStarts = topLevelBlockStarts(newDoc);

  for (const range of ranges) {
    const from = tr.mapping.map(oldStarts[range.oldFrom]);
    const to = tr.mapping.map(oldStarts[range.oldTo]);
    const slice = new Slice(newDoc.content.cut(newStarts[range.newFrom], newStarts[range.newTo]), 0, 0);
    tr = tr.replace(from, to, slice);
  }

  return tr;
}

export function setContentWithBlockIds(
  markdown: string,
  blockIds: string[],
  options?: {
    scrollToStart?: boolean;
    imageMeta?: ImageBlockMeta[];
    cursorBoundary?: number;
    // Node index one PAST the last bibliography block — see the clamp logic below for how
    // this bounds the END of the section, as opposed to cursorBoundary's START.
    cursorBoundaryEnd?: number;
    detectPausedEdits?: boolean;
    expected?: ExpectedBlockMeta[];
    // Whether the pushed content is a zoomed subset of the document. See the
    // matching doc comment on window.FinalFinal.setContentWithBlockIds in
    // types.ts for the race this closes. Defaults to false (full-document load).
    zoomMode?: boolean;
  }
): void {
  clearContentPushTimer(); // Cancel stale timers before document replacement
  syncLog(
    'API:setContentWithBlockIds',
    `entry len=${markdown.length} blocks=${blockIds.length} scrollToStart=${options?.scrollToStart ?? false} zoomMode=${options?.zoomMode ?? false}`
  );
  // [SYNC-DIAG Round 2] First-few IDs so we can tie Swift's id-array to the parsed DOM
  if (SYNC_DIAG_DETAIL) {
    const firstFew = blockIds.slice(0, 5).map((id) => id.slice(0, 8));
    syncLog('API:setContentWithBlockIds', `firstFewIds=[${firstFew.join(',')}]`);
  }
  // Set zoom mode SYNCHRONOUSLY from the caller-supplied option (defaults to
  // false, matching the old unconditional-clear behavior for every call site
  // that doesn't pass it). Previously this always cleared to false and relied
  // on a LATER, separately-awaited syncBlockIds()/pushBlockIds() Swift
  // round-trip to flip it back on for zoom entry — leaving a window where a
  // position-0 insert into the zoomed section was misclassified
  // atDocumentStart: true. See block-sync-document-start.test.ts.
  setBlockIdZoomMode(options?.zoomMode ?? false);
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
    let emptyPushBaseline: Map<string, BlockSnapshot> | undefined;
    try {
      editorInstance.action((ctx) => {
        const view = ctx.get(editorViewCtx);
        const emptyParagraph = view.state.schema.nodes.paragraph.create();
        const emptyDoc = view.state.schema.nodes.doc.create(null, emptyParagraph);
        const tr = view.state.tr.replaceWith(0, view.state.doc.content.size, emptyDoc.content);
        view.dispatch(tr.setMeta('addToHistory', false).setSelection(Selection.atStart(tr.doc)));
        clearBlockIds();
        if (options?.detectPausedEdits) {
          emptyPushBaseline = snapshotBlocks(view.state.doc);
        }
      });
      setCurrentContent(markdown);
    } finally {
      setIsSettingContent(false);
      deferredSnapshotAndUnpause(options?.detectPausedEdits ?? false, emptyPushBaseline);
    }
    return;
  }

  // Match applyBlocks pattern: sync paused through ENTIRE operation
  setIsSettingContent(true);
  setSyncPaused(true);
  let parseSucceeded = false;
  // Captured at the very end of the paused callback below, once the pushed
  // content and its real block IDs (and any image-metadata adjustment) have
  // fully settled — the correct "before" baseline for detectPausedEdits, as
  // opposed to the ambient last-known state (see deferredSnapshotAndUnpause).
  let pausedPushBaseline: Map<string, BlockSnapshot> | undefined;
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
      let tr = buildBlockLevelReplace(view.state.tr, view.state.doc, doc);

      if (options?.scrollToStart) {
        tr = tr.setSelection(Selection.atStart(tr.doc));
      } else {
        let safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));

        // Clamp cursor before the bibliography section to prevent typing into bib paragraphs.
        // cursorBoundary is the node index of the first bibliography block; cursorBoundaryEnd
        // is the node index one past the LAST bibliography block (absent when the section runs
        // to the end of the document). The clamp only fires when the cursor actually falls
        // INSIDE that [bibPos, bibEndPos) range, not merely at-or-past bibPos: a regenerated
        // bibliography can now be reinserted back at a mid-document anchor instead of always
        // landing at the document's end, so a cursor sitting in real trailing user content
        // AFTER the section must be left alone, not yanked back to just before it.
        const boundary = options?.cursorBoundary ?? -1;
        const boundaryEnd = options?.cursorBoundaryEnd;
        let bibPos = doc.content.size;
        let bibEndPos = doc.content.size;
        if (boundary >= 0) {
          let nodeIdx = 0;
          doc.forEach((_node, pos) => {
            if (nodeIdx === boundary) {
              bibPos = pos;
            }
            if (boundaryEnd !== undefined && nodeIdx === boundaryEnd) {
              bibEndPos = pos;
            }
            nodeIdx++;
          });
          if (safeFrom >= bibPos && safeFrom < bibEndPos) {
            safeFrom = Math.max(0, bibPos - 1);
          }
        }

        syncLog(
          'API:setContentWithBlockIds',
          `cursor: from=${from} safeFrom=${safeFrom} boundary=${boundary} boundaryEnd=${boundaryEnd} bibPos=${bibPos} bibEndPos=${bibEndPos} docSize=${doc.content.size}`
        );

        try {
          tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
        } catch {
          tr = tr.setSelection(Selection.atStart(tr.doc));
        }
      }
      view.dispatch(tr.setMeta('addToHistory', false));
      parseSucceeded = true;

      // Clear stale IDs, assign real ones, snapshot — all within syncPaused
      clearBlockIds();
      if (blockIds.length > 0) {
        setBlockIdsForTopLevel(blockIds, view.state.doc, options?.expected);
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
              width: meta.width ?? node.attrs.width ?? null,
              blockId: meta.id,
            });
            figureIdx++;
          }
        });
        if (metaTr.steps.length > 0) view.dispatch(metaTr.setMeta('addToHistory', false));
      }

      // Capture the "just pushed" baseline LAST, after every transaction in this
      // paused callback has settled, so it reflects the fully-assembled restored
      // content (real IDs, image metadata) — not an intermediate state.
      if (options?.detectPausedEdits) {
        pausedPushBaseline = snapshotBlocks(view.state.doc);
      }
    });
    if (parseSucceeded) {
      setCurrentContent(markdown);
    }
  } finally {
    setIsSettingContent(false);
    // Delay snapshot + unpause to RAF so normalization transactions are absorbed
    deferredSnapshotAndUnpause(options?.detectPausedEdits ?? false, pausedPushBaseline);
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

export function flushPendingBlockChanges(): void {
  flushPendingBlockChangesPlugin();
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

export function syncBlockIds(orderedIds: string[], zoomMode: boolean, expected?: ExpectedBlockMeta[]): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;
  const view = editorInstance.ctx.get(editorViewCtx);
  // [SYNC-DIAG Round 2] syncBlockIds is a third Swift→JS seed point (zoom + pushBlockIds).
  // Log before setBlockIdsForTopLevel runs so the plugin-side log reflects the input.
  if (SYNC_DIAG_DETAIL) {
    const firstFew = orderedIds.slice(0, 5).map((id) => id.slice(0, 8));
    syncLog(
      'API:syncBlockIds',
      `entry orderedIds.length=${orderedIds.length} zoomMode=${zoomMode} firstFew=[${firstFew.join(',')}]`
    );
  }
  setBlockIdZoomMode(zoomMode); // Set zoom mode based on caller context
  setBlockIdsForTopLevel(orderedIds, view.state.doc, expected);
  resetAndSnapshot(view.state.doc);
}

// ---------------------------------------------------------------------------
// Cursor-aware insert-position algorithm (pasted-image placement fix)
//
// Pinned down and exhaustively verified against the real installed schema by
// the committed test suite in `__tests__/insert-pos.test.ts` (16+ tests) —
// see that file and `docs/`/plan history for the full container-by-container
// rationale. This is the production implementation the tests exercise
// directly (no parallel/duplicated copy).
// ---------------------------------------------------------------------------

const TABLE_FAMILY = new Set(['table', 'table_row', 'table_header_row', 'table_cell', 'table_header']);

function isTableFamily(node: ProsemirrorNode): boolean {
  return TABLE_FAMILY.has(node.type.name);
}

/** Ordered depths (deepest/least-escalated first) for which the caret's
 * position is at the start/end of every ancestor from that depth up to the
 * caret's own immediate parent — i.e. valid candidate anchor points for
 * "before(d)" / "after(d)" that still represent "at the caret", not a jump
 * backward/forward past sibling content.
 *
 * Always seeded with `$pos.depth` itself as the base candidate, so the
 * returned array is never empty (see `chainWalk`'s guard below, which relies
 * on this). */
function candidateDepths($pos: ResolvedPos, atStart: boolean): number[] {
  const out = [$pos.depth];
  for (let d = $pos.depth - 1; d >= 1; d--) {
    const idx = $pos.index(d);
    const matches = atStart ? idx === 0 : idx === $pos.node(d).childCount - 1;
    if (!matches) break;
    out.push(d);
  }
  return out;
}

/** Does this node's content model accept `nodeType` somewhere after its
 * actual current children (walking its content-match state machine), even
 * if not as the very first child? Handles position-dependent expressions
 * like list_item's "paragraph block*" (false before the mandatory first
 * paragraph, true after it) as well as unconditional ones like blockquote's
 * "block+" (true immediately) and bullet_list's "listItem+" (always false). */
function canEventuallyContainBlockType(node: ProsemirrorNode, nodeType: NodeType): boolean {
  let match = node.type.contentMatch;
  if (match.matchType(nodeType)) return true;
  for (let i = 0; i < node.childCount; i++) {
    const next = match.matchType(node.child(i).type);
    if (!next) return false;
    match = next;
    if (match.matchType(nodeType)) return true;
  }
  return false;
}

/** Full boundary-chain walk: always escalate exactly as far as the
 * structural "am I at the edge of this whole run of interchangeable
 * siblings" condition demands — never further, never less. Correct on its
 * own for: START in any container, and END in a "symmetric" container (one
 * whose content model treats all children uniformly, e.g. blockquote's
 * "block+" — no distinguished reserved slot to signal "nest here instead"). */
function chainWalk($pos: ResolvedPos, wantStart: boolean): number {
  const candidates = candidateDepths($pos, wantStart);
  const shallowest = candidates[candidates.length - 1];
  if (shallowest === undefined) {
    // candidateDepths always seeds its result with $pos.depth (itself
    // guaranteed >= 1 by the depth < 1 early-return in
    // computeCursorAwareInsertPos), so this branch should be unreachable.
    // Guard explicitly rather than falling through: $pos.before(undefined)/
    // $pos.after(undefined) silently default to $pos.depth in ProseMirror,
    // which would mask a real bug here instead of surfacing it.
    throw new Error('chainWalk: candidateDepths returned an empty array (unreachable)');
  }
  return wantStart ? $pos.before(shallowest) : $pos.after(shallowest);
}

/** Compute where to insert a block-level node (e.g. a pasted/dropped image
 * figure) so that it lands exactly at the caret, splitting the minimum
 * necessary structure and never tearing apart something that should stay
 * whole (e.g. a table, or a list's mandatory-first paragraph). */
export function computeCursorAwareInsertPos(doc: ProsemirrorNode, rawPos: number, nodeType: NodeType): number {
  const $pos = doc.resolve(rawPos);

  // Depth 0: already an unambiguous, valid top-level insertion point.
  if ($pos.depth < 1) return rawPos;

  const atStart = $pos.parentOffset === 0;
  const atEnd = $pos.parentOffset === $pos.parent.content.size;

  if (atStart || atEnd) {
    // Never attempt to escalate/split through table structure — table_cell's
    // content ("paragraph", exactly one) forces escalation all the way past
    // table/table_row, and ProseMirror's schema has no structural guarantee
    // that a split table would keep matching row/column counts. Use the
    // existing, proven-safe "after the outermost block" fallback instead.
    for (let d = 1; d <= $pos.depth; d++) {
      if (isTableFamily($pos.node(d))) return $pos.after(1);
    }

    // Is the caret's own immediate container "asymmetric" — does it reject
    // the figure type as a FIRST child (index 0)? list_item's
    // "paragraph block*" does (paragraph is mandatory-first); blockquote's
    // "block+" does not (no ordering constraint — any index is equally
    // valid). This distinguishes containers with a genuine "supplementary
    // content lives here, after the required lead-in" slot (list_item) from
    // uniform runs of interchangeable siblings (blockquote), where nesting —
    // even though schema-valid — has no such meaning and must not be
    // preferred over full escalation (verified: preferring it regresses the
    // blockquote-start/end flagship cases, since block+ trivially accepts a
    // figure at any index).
    const immediateParent = $pos.node($pos.depth - 1);
    const asymmetric = !immediateParent.canReplaceWith(0, 0, nodeType);

    const tryNestAtEnd = (): number | null => {
      const idx = $pos.indexAfter($pos.depth - 1);
      if (immediateParent.canReplaceWith(idx, idx, nodeType)) return $pos.after($pos.depth);
      return null;
    };

    if (atStart && atEnd) {
      // Genuinely empty textblock (e.g. an empty bullet). Prefer appending
      // in place (no escalation) when the container's own reserved-slot
      // asymmetry makes that the natural, intended placement; otherwise
      // (symmetric container, e.g. an empty quoted line) fall through to the
      // ordinary chain walk.
      if (asymmetric) {
        const nested = tryNestAtEnd();
        if (nested !== null) return nested;
      }
      return chainWalk($pos, false);
    }

    if (atEnd && asymmetric) {
      const nested = tryNestAtEnd();
      if (nested !== null) return nested;
    }

    return chainWalk($pos, atStart);
  }

  // Genuinely mid-text (interior, not at any ancestor's boundary).
  if ($pos.depth === 1) return $pos.pos;
  for (let d = $pos.depth - 1; d >= 1; d--) {
    if (isTableFamily($pos.node(d))) return $pos.after(1);
    if (canEventuallyContainBlockType($pos.node(d), nodeType)) return $pos.pos;
  }
  return $pos.after(1);
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
  /** Where this insert originated. `'picker'` = native file picker (no
   * cursor-based paste/drop position to consult — see position-selection
   * logic below). Any other value (or omitted) is treated as a
   * clipboard/drop origin. */
  origin?: string;
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

    // Position selection order: cursor-aware paste position first, then
    // cursor-aware drop position, then the existing after-cursor-block
    // fallback (still used by the image-picker flow). Both paste and drop
    // positions are routed through computeCursorAwareInsertPos() so a raw
    // position at any depth/boundary escalates or nests correctly instead of
    // going straight to tr.insert(). Compute against tr.doc (which may have
    // had ghost images removed).
    //
    // Both pending position fields are drained unconditionally (even for a
    // picker-originated call) so a picker insert never leaves stale state
    // behind for a later, unrelated paste/drop to pick up — see the mutual
    // one-shot-consume contract in image-plugin.ts.
    const pastePos = consumePendingPastePos();
    const dropPos = consumePendingDropPos();
    // Both pastePos and dropPos were captured in pre-deletion document
    // coordinates. If a ghost inline image (blob:/data:) existed before either
    // position, the tr.delete(...) calls above shifted everything after it, so
    // each must be mapped through the accumulated transform steps before being
    // resolved against tr.doc — otherwise it can point at the wrong logical spot.
    const mappedPastePos = pastePos !== null ? tr.mapping.map(pastePos) : null;
    const mappedDropPos = dropPos !== null ? tr.mapping.map(dropPos) : null;
    const docSize = tr.doc.content.size;
    syncLog(
      'API:insertImage',
      `pastePos=${pastePos} mappedPastePos=${mappedPastePos} dropPos=${dropPos} mappedDropPos=${mappedDropPos} docSize=${docSize} origin=${opts.origin ?? ''}`
    );

    const isPicker = opts.origin === 'picker';
    const rawPos =
      !isPicker && mappedPastePos !== null && mappedPastePos >= 0 && mappedPastePos <= docSize
        ? mappedPastePos
        : !isPicker && mappedDropPos !== null && mappedDropPos >= 0 && mappedDropPos <= docSize
          ? mappedDropPos
          : null;

    let insertPos: number;
    if (rawPos !== null) {
      insertPos = computeCursorAwareInsertPos(tr.doc, rawPos, figureType);
      syncLog('API:insertImage', `cursor-aware insertPos=${insertPos} (from rawPos=${rawPos})`);
    } else {
      // Fallback: after current selection's top-level block. Reached whenever
      // there's no usable cursor-aware position — the picker path (expected),
      // OR (unexpected, and a loss of precision) a clipboard paste/drop whose
      // pendingPastePos/pendingDropPos was never set or already expired (see
      // PENDING_POS_TIMEOUT_MS in image-plugin.ts). Logged explicitly so a
      // live-app retest's console makes it obvious which case this was.
      if (!isPicker) {
        syncLog(
          'API:insertImage',
          `FALLBACK: no usable paste/drop position (pastePos=${pastePos} mappedPastePos=${mappedPastePos} dropPos=${dropPos} mappedDropPos=${mappedDropPos}) — using after-current-block placement, cursor-aware positioning was lost`
        );
      }
      try {
        const { from } = view.state.selection;
        const $from = tr.doc.resolve(Math.min(from, docSize));
        insertPos = $from.after(1);
      } catch {
        insertPos = tr.doc.content.size;
      }
    }
    // Detect whether this insert is about to split ONE ordered_list into two
    // halves (e.g. pasting/dropping an image mid-list), as opposed to landing
    // in a gap that does NOT split a single list — between two independent
    // pre-existing lists, inside/after some other container, at the very top
    // level, etc. Resolved against tr.doc BEFORE the insert happens, so
    // $split.parent is the list as it stands whole, not yet split: a gap
    // between two separate adjacent ordered_list nodes resolves its .parent
    // to the containing doc/blockquote (not ordered_list), so that case is
    // correctly excluded here without any special-casing.
    //
    // Only in the genuine mid-list-split case do we continue the tail half's
    // numbering — a deliberately-started new list (manual list creation /
    // input rules) is untouched: those always resolve to a fresh position
    // whose $split.parent is never the SAME ordered_list with items on both
    // sides, so `continuation` stays null and `order` keeps its normal
    // default of 1.
    // Depth-agnostic by construction: `$split.parent` is whatever node
    // directly contains position `insertPos` at ITS OWN depth, resolved
    // dynamically — so this works identically whether the split list is a
    // top-level ordered_list or one nested many levels deep inside other
    // lists/blockquotes. There is no hardcoded depth to keep in sync with
    // nesting.
    //
    // Do NOT extend this to walk up past a `paragraph` parent to catch the
    // mid-text-paste case (pasting inside an item's text, not at an item
    // boundary). That case is intentionally excluded: `list_item`'s content
    // model is `"paragraph block*"`, which unconditionally absorbs a pasted
    // figure as an extra block child of the SAME item, without ever
    // splitting the list. There is nothing to continue numbering for —
    // walking up to find an ordered_list ancestor there would misidentify a
    // non-split as a split.
    const $split = tr.doc.resolve(insertPos);
    const splitDepth = $split.depth;
    let continuation: number | null = null;
    if (
      splitDepth > 0 &&
      $split.parent.type === view.state.schema.nodes.ordered_list &&
      $split.index(splitDepth) > 0 &&
      $split.indexAfter(splitDepth) < $split.parent.childCount
    ) {
      const list = $split.parent;
      const before = $split.index(splitDepth);
      continuation = (list.attrs.order ?? 1) + before;
    }

    tr = tr.insert(insertPos, node);

    if (continuation !== null) {
      // `insertPos` sat INSIDE the (still whole) list's own content, between
      // two list items — not at a top-level boundary. To actually place a
      // block-level figure there, ProseMirror's replace negotiation closes
      // the list right after the earlier items (one "list close" token,
      // ending the first half-list immediately before the figure) and opens
      // a fresh list right after the figure (the second half-list starts
      // there directly, with no further gap) — verified against the real
      // editor pipeline (see repro-list-paste.test.ts). So the tail list
      // begins one position past the figure, not directly at
      // insertPos + node.nodeSize.
      const tailPos = insertPos + 1 + node.nodeSize;
      const tailList = tr.doc.nodeAt(tailPos);
      if (tailList && tailList.type === view.state.schema.nodes.ordered_list) {
        tr = tr.setNodeMarkup(tailPos, undefined, { ...tailList.attrs, order: continuation });
      }
    }

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
