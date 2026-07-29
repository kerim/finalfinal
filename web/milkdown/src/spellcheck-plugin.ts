/**
 * Spellcheck decoration plugin for Milkdown
 * Bridges to NSSpellChecker via Swift message handlers.
 * Extracts text segments from ProseMirror doc, sends to Swift for checking,
 * and renders decorations for spelling/grammar errors.
 */

import { editorViewCtx } from '@milkdown/kit/core';
import type { Node } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey, type Transaction } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet, type EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import { getEditorInstance } from './editor-state';
import { dismissMenu, showSpellcheckMenu } from './spellcheck-menu';
import { dismissPopover, isPopoverOpen, showProofingPopover } from './spellcheck-popover';

// --- Module state ---

export interface SpellcheckResult {
  from: number;
  to: number;
  word: string;
  type: 'spelling' | 'grammar' | 'style';
  suggestions: string[];
  message?: string | null;
  shortMessage?: string | null;
  ruleId?: string | null;
  isPicky?: boolean;
}

let spellcheckResults: SpellcheckResult[] = [];
let currentRequestId = 0;
let debounceTimer: ReturnType<typeof setTimeout> | null = null;
let enabled = true;

/** Range of the grammar/style result whose proofing popover is currently open, if any. */
let activeProofingRange: { from: number; to: number } | null = null;

export const spellcheckPluginKey = new PluginKey('spellcheck-decorations');

// --- API exports ---

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const diagLog = (...args: unknown[]) => {
  const msg = `[LT-DIAG:milkdown] ${args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}`;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const handler = (window as any).webkit?.messageHandlers?.errorHandler;
  if (handler?.postMessage) handler.postMessage({ type: 'debug', message: msg });
  else console.log(msg);
};

export function setSpellcheckResults(requestId: number, results: SpellcheckResult[]): void {
  if (requestId !== currentRequestId) {
    diagLog(
      `DISCARDED stale results: incoming requestId=${requestId} currentRequestId=${currentRequestId} resultsCount=${results.length}`
    );
    return; // Discard stale results
  }
  spellcheckResults = results;
  diagLog(`ACCEPTED requestId=${requestId} resultsCount=${results.length}`);

  const editor = getEditorInstance();
  if (editor) {
    const view = editor.ctx.get(editorViewCtx);
    const before = buildDecorationSet(results, view.state.doc);
    diagLog(
      `buildDecorationSet produced ${before.find().length} decorations from ${results.length} results, docSize=${view.state.doc.content.size}`
    );
    view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, results));
  } else {
    diagLog('DISCARDED: no editor instance available');
  }
}

export function enableSpellcheck(): void {
  enabled = true;
  triggerCheck();
}

export function triggerSpellcheck(): void {
  triggerCheck();
}

export function disableSpellcheck(): void {
  enabled = false;
  spellcheckResults = [];
  if (debounceTimer) {
    clearTimeout(debounceTimer);
    debounceTimer = null;
  }
  const editor = getEditorInstance();
  if (editor) {
    const view = editor.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, []));
  }
}

/** Read-only getter for the module's current toggle state — mirrors
 *  isSmartQuotesEnabled() in smart-quotes-plugin.ts. Exposed on window.FinalFinal
 *  so Swift-side tests can verify applyPersistedToggleStates() actually propagated
 *  a persisted UserDefaults preference into a freshly-created editor instance,
 *  rather than assuming the JS module started in whatever state the toggle call
 *  implies. */
export function isSpellcheckEnabled(): boolean {
  return enabled;
}

// --- Decoration helpers ---

function buildDecorationSet(results: SpellcheckResult[], doc: Node): DecorationSet {
  if (results.length === 0) return DecorationSet.empty;
  const decorations: Decoration[] = [];
  for (const result of results) {
    if (result.from < 0 || result.to > doc.content.size || result.from >= result.to) continue;
    const className =
      result.type === 'grammar' ? 'grammar-error' : result.type === 'style' ? 'style-error' : 'spell-error';
    const attrs: Record<string, string> = { class: className };
    if (result.message) attrs.title = result.message;
    try {
      decorations.push(Decoration.inline(result.from, result.to, attrs));
    } catch {
      /* skip invalid positions */
    }
  }
  return DecorationSet.create(doc, decorations);
}

function mapResults(
  results: SpellcheckResult[],
  mapping: { map(pos: number, assoc?: number): number }
): SpellcheckResult[] {
  return results
    .map((r) => ({ ...r, from: mapping.map(r.from, 1), to: mapping.map(r.to, -1) }))
    .filter((r) => r.from < r.to);
}

/**
 * Compute the ranges of the pre-transaction document that a transaction's steps touched
 * (inserted into, deleted from, or replaced), in the same coordinate space as `spellcheckResults`
 * before the transaction is applied. Each step's StepMap reports its touched range in the
 * coordinate space just before that step; for steps after the first we map that range back
 * through the (inverted) preceding steps to land in the original, pre-transaction doc.
 */
function getChangedRangesInOldDoc(tr: Transaction): { from: number; to: number }[] {
  const ranges: { from: number; to: number }[] = [];
  const maps = tr.mapping.maps;
  for (let i = 0; i < maps.length; i++) {
    maps[i].forEach((oldStart, oldEnd) => {
      let from = oldStart;
      let to = oldEnd;
      for (let j = i - 1; j >= 0; j--) {
        from = maps[j].invert().map(from, -1);
        to = maps[j].invert().map(to, 1);
      }
      ranges.push({ from, to });
    });
  }
  return ranges;
}

/**
 * Does a changed range "touch" a result's range? Interior overlap always counts. A zero-width
 * change (a pure insertion, no deletion) also counts if it lands exactly on either boundary —
 * e.g. typing a missing letter right after "runnin" to fix "running", or right before a word —
 * so the underline clears on that same keystroke instead of surviving until the async re-check.
 */
function touchesResult(range: { from: number; to: number }, result: { from: number; to: number }): boolean {
  if (range.from === range.to) {
    return result.from <= range.from && range.from <= result.to;
  }
  return range.from < result.to && result.from < range.to;
}

/**
 * Reconcile existing spellcheck results against a document-changing transaction: drop any
 * result whose range was touched by the edit (so its underline clears immediately instead of
 * lingering until the async LanguageTool re-check responds), then remap the survivors'
 * positions through the transaction.
 */
export function reconcileResultsAfterEdit(results: SpellcheckResult[], tr: Transaction): SpellcheckResult[] {
  const touchedRanges = getChangedRangesInOldDoc(tr);
  const survivors =
    touchedRanges.length === 0 ? results : results.filter((r) => !touchedRanges.some((t) => touchesResult(t, r)));
  const isSyncOrigin = tr.getMeta('addToHistory') === false;
  if (results.length !== survivors.length) {
    diagLog(
      `RECONCILE dropped ${results.length - survivors.length}/${results.length} results | ` +
        `syncOrigin=${isSyncOrigin} touchedRanges=${JSON.stringify(touchedRanges)} steps=${tr.steps.length}`
    );
  }
  return mapResults(survivors, tr.mapping);
}

// --- Text extraction ---

interface TextSegment {
  text: string;
  from: number;
  to: number;
  blockId?: number;
}

/** Node types to skip entirely (no text extraction) */
const SKIP_NODE_TYPES = new Set([
  'code_block',
  'fence',
  'image',
  'figure',
  'html_block',
  'auto_bibliography_start',
  'auto_bibliography_end',
]);

/** Mark types whose text content should be skipped */
const SKIP_MARK_TYPES = new Set(['inlineCode']);

/**
 * Extract checkable text segments from ProseMirror document.
 * One segment per block node (paragraph, heading, list item).
 * Skips code blocks, images, code inline marks, link URLs, citation nodes.
 */
function extractSegments(view: EditorView): TextSegment[] {
  const segments: TextSegment[] = [];
  const doc = view.state.doc;

  doc.descendants((node, pos) => {
    // Skip non-checkable block nodes
    if (SKIP_NODE_TYPES.has(node.type.name)) {
      return false; // Don't descend
    }

    // Skip bibliography section (detect by looking for auto-bib markers)
    if (node.type.name === 'heading') {
      const text = node.textContent.toLowerCase();
      if (text === 'bibliography' || text === 'references' || text === 'works cited') {
        // Don't skip the heading itself, but we'll skip content after it
        // (handled by the bibliography plugin's markers)
      }
    }

    // Only extract text from block-level nodes that contain inline content
    if (!node.isBlock || node.isAtom || !node.inlineContent) {
      return true; // Continue descending
    }

    // Build one segment for this block by concatenating text children
    let blockText = '';
    const blockFrom = pos + 1; // +1 for entering the block node
    let segmentStart = blockFrom;
    const blockId = pos; // Paragraph position used to group related segments

    node.forEach((child, offset) => {
      // Skip inline atom nodes (citations, section breaks, footnote refs)
      if (child.type.name === 'citation' || child.type.name === 'section_break' || child.type.name === 'footnote_ref') {
        // If we have accumulated text, emit a segment
        if (blockText.length > 0) {
          segments.push({ text: blockText, from: segmentStart, to: segmentStart + blockText.length, blockId });
          blockText = '';
        }
        segmentStart = blockFrom + offset + child.nodeSize;
        return;
      }

      // Skip nodes with inlineCode mark
      if (child.isText && child.marks.some((m) => SKIP_MARK_TYPES.has(m.type.name))) {
        if (blockText.length > 0) {
          segments.push({ text: blockText, from: segmentStart, to: segmentStart + blockText.length, blockId });
          blockText = '';
        }
        segmentStart = blockFrom + offset + child.nodeSize;
        return;
      }

      if (child.isText) {
        if (blockText.length === 0) {
          segmentStart = blockFrom + offset;
        }
        blockText += child.text || '';
      } else {
        // Non-text inline node (hard break, annotation, etc.) — split segment
        if (blockText.length > 0) {
          segments.push({ text: blockText, from: segmentStart, to: segmentStart + blockText.length, blockId });
          blockText = '';
        }
        segmentStart = blockFrom + offset + child.nodeSize;
      }
    });

    // Flush remaining text for this block
    if (blockText.length > 0) {
      segments.push({ text: blockText, from: segmentStart, to: segmentStart + blockText.length, blockId });
    }

    return false; // Already processed children
  });

  return segments;
}

// --- Check trigger ---

function triggerCheck(): void {
  if (!enabled) return;

  const editor = getEditorInstance();
  if (!editor) return;

  const view = editor.ctx.get(editorViewCtx);
  const segments = extractSegments(view);

  if (segments.length === 0) {
    spellcheckResults = [];
    view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, []));
    return;
  }

  currentRequestId++;
  const requestId = currentRequestId;

  window.webkit?.messageHandlers?.spellcheck?.postMessage({
    action: 'check',
    segments: segments.map((s) => ({ text: s.text, from: s.from, to: s.to, blockId: s.blockId })),
    requestId,
  });
}

function debouncedCheck(): void {
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(triggerCheck, 400);
}

// --- Context menu ---

function findResultAtPos(pos: number): SpellcheckResult | null {
  return spellcheckResults.find((r) => pos >= r.from && pos < r.to) ?? null;
}

function handleContextMenu(view: EditorView, event: MouseEvent): boolean {
  if (!enabled) return false;

  const pos = view.posAtCoords({ left: event.clientX, top: event.clientY });
  if (!pos) return false;

  const result = findResultAtPos(pos.pos);
  if (!result) return false;

  // For grammar/style, context menu is not used (click handler shows popover)
  if (result.type === 'grammar' || result.type === 'style') return false;

  event.preventDefault();

  showSpellcheckMenu({
    x: event.clientX,
    y: event.clientY,
    word: result.word,
    type: result.type as 'spelling' | 'grammar',
    suggestions: result.suggestions,
    message: result.message,
    onReplace: (replacement: string) => {
      const current = spellcheckResults.find((r) => r.word === result.word && r.type === result.type);
      if (!current) return;
      const tr = view.state.tr.replaceWith(current.from, current.to, view.state.schema.text(replacement));
      view.dispatch(tr);
    },
    onLearn: (word: string) => {
      spellcheckResults = spellcheckResults.filter((r) => r.word !== word);
      view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, spellcheckResults));
      window.webkit?.messageHandlers?.spellcheck?.postMessage({ action: 'learn', word });
      triggerCheck();
    },
    onIgnore: (word: string) => {
      spellcheckResults = spellcheckResults.filter((r) => r.word !== word);
      view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, spellcheckResults));
      window.webkit?.messageHandlers?.spellcheck?.postMessage({ action: 'ignore', word });
      triggerCheck();
    },
  });

  return true;
}

function handleClick(view: EditorView, event: MouseEvent): boolean {
  if (!enabled) return false;

  const pos = view.posAtCoords({ left: event.clientX, top: event.clientY });
  if (!pos) return false;

  const result = findResultAtPos(pos.pos);
  if (!result) return false;

  // Spelling: show spell menu on click
  if (result.type === 'spelling') {
    dismissPopover();
    showSpellcheckMenu({
      x: event.clientX,
      y: event.clientY,
      word: result.word,
      type: result.type as 'spelling' | 'grammar',
      suggestions: result.suggestions,
      message: result.message,
      onReplace: (replacement: string) => {
        const current = spellcheckResults.find((r) => r.word === result.word && r.type === result.type);
        if (!current) return;
        const tr = view.state.tr.replaceWith(current.from, current.to, view.state.schema.text(replacement));
        view.dispatch(tr);
      },
      onLearn: (word: string) => {
        spellcheckResults = spellcheckResults.filter((r) => r.word !== word);
        view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, spellcheckResults));
        window.webkit?.messageHandlers?.spellcheck?.postMessage({ action: 'learn', word });
        triggerCheck();
      },
      onIgnore: (word: string) => {
        spellcheckResults = spellcheckResults.filter((r) => r.word !== word);
        view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, spellcheckResults));
        window.webkit?.messageHandlers?.spellcheck?.postMessage({ action: 'ignore', word });
        triggerCheck();
      },
    });
    return true;
  }

  // Grammar/style: show proofing popover — but don't hijack a selection gesture.
  // A shift-click (extending selection) or a click that left a non-empty
  // selection (drag-select) means the user wants to select text, not see
  // suggestions.
  if (event.shiftKey || !view.state.selection.empty) {
    return false;
  }

  dismissMenu();
  dismissPopover();

  // Anchor the popover to the bottom of the flagged range rather than the
  // click point, so it doesn't overlap the annotated line.
  const coords = view.coordsAtPos(result.to);
  activeProofingRange = { from: result.from, to: result.to };

  showProofingPopover({
    x: coords.left,
    y: coords.bottom + 4,
    word: result.word,
    type: result.type,
    message: result.message || '',
    shortMessage: result.shortMessage || '',
    ruleId: result.ruleId || '',
    isPicky: result.isPicky || false,
    suggestions: result.suggestions,
    onReplace: (suggestion: string) => {
      const current = spellcheckResults.find((r) => r.word === result.word && r.type === result.type);
      if (!current) return;
      const tr = view.state.tr.replaceWith(current.from, current.to, view.state.schema.text(suggestion));
      view.dispatch(tr);
    },
    onIgnore: () => {
      spellcheckResults = spellcheckResults.filter((r) => r !== result);
      view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, spellcheckResults));
      window.webkit?.messageHandlers?.spellcheck?.postMessage({ action: 'ignore', word: result.word });
      triggerCheck();
    },
    onDisableRule: (ruleId: string) => {
      spellcheckResults = spellcheckResults.filter((r) => r.ruleId !== ruleId);
      view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, spellcheckResults));
      window.webkit?.messageHandlers?.spellcheck?.postMessage({ action: 'disableRule', ruleId });
    },
  });

  return false; // Don't consume — let ProseMirror place the cursor
}

// --- Plugin ---

export const spellcheckPlugin = $prose(() => {
  return new Plugin({
    key: spellcheckPluginKey,
    state: {
      init() {
        return DecorationSet.empty;
      },
      apply(tr, decorationSet) {
        const newResults = tr.getMeta(spellcheckPluginKey);
        if (newResults !== undefined) {
          spellcheckResults = newResults;
          return buildDecorationSet(newResults, tr.doc);
        }
        if (tr.docChanged) {
          spellcheckResults = reconcileResultsAfterEdit(spellcheckResults, tr);
          return buildDecorationSet(spellcheckResults, tr.doc);
        }
        return decorationSet;
      },
    },
    props: {
      decorations(state) {
        if (!enabled) return DecorationSet.empty;
        return spellcheckPluginKey.getState(state) ?? DecorationSet.empty;
      },
      handleDOMEvents: {
        contextmenu(view, event) {
          return handleContextMenu(view, event as MouseEvent);
        },
        click(view, event) {
          return handleClick(view, event as MouseEvent);
        },
      },
    },
    view() {
      return {
        update(view, prevState) {
          if (view.state.doc !== prevState.doc) {
            debouncedCheck();
          }

          // Dismiss the proofing popover once the selection moves outside
          // the range it was opened for (mirrors link-tooltip.ts's pattern).
          if (activeProofingRange) {
            if (!isPopoverOpen()) {
              activeProofingRange = null;
            } else {
              const { from } = view.state.selection;
              if (from < activeProofingRange.from || from > activeProofingRange.to) {
                dismissPopover();
                activeProofingRange = null;
              }
            }
          }
        },
      };
    },
  });
});

export default spellcheckPlugin;
