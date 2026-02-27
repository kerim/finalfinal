/**
 * Spellcheck decoration plugin for Milkdown
 * Bridges to NSSpellChecker via Swift message handlers.
 * Extracts text segments from ProseMirror doc, sends to Swift for checking,
 * and renders decorations for spelling/grammar errors.
 */

import { editorViewCtx } from '@milkdown/kit/core';
import type { Node } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet, type EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import { getEditorInstance } from './editor-state';
import { dismissMenu, showSpellcheckMenu } from './spellcheck-menu';
import { dismissPopover, showProofingPopover } from './spellcheck-popover';

// --- Module state ---

interface SpellcheckResult {
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

export const spellcheckPluginKey = new PluginKey('spellcheck-decorations');

// --- API exports ---

export function setSpellcheckResults(requestId: number, results: SpellcheckResult[]): void {
  if (requestId !== currentRequestId) return; // Discard stale results
  spellcheckResults = results;

  const editor = getEditorInstance();
  if (editor) {
    const view = editor.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, results));
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
  'html_block',
  'auto_bibliography_start',
  'auto_bibliography_end',
]);

/** Mark types whose text content should be skipped */
const SKIP_MARK_TYPES = new Set(['code_inline']);

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

      // Skip nodes with code_inline mark
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

  // Grammar/style: show proofing popover
  dismissMenu();
  dismissPopover();

  showProofingPopover({
    x: event.clientX,
    y: event.clientY + 20,
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

  return true;
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
          spellcheckResults = mapResults(spellcheckResults, tr.mapping);
          return decorationSet.map(tr.mapping, tr.doc);
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
        },
      };
    },
  });
});

export default spellcheckPlugin;
