/**
 * Spellcheck decoration plugin for CodeMirror 6
 * Bridges to NSSpellChecker via Swift message handlers.
 * Extracts text segments using Lezer syntax tree, sends to Swift for checking,
 * and renders decorations for spelling/grammar errors.
 */

import { syntaxTree } from '@codemirror/language';
import { RangeSetBuilder } from '@codemirror/state';
import { Decoration, type DecorationSet, type EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import { ALL_HIDDEN_MARKERS_REGEX } from './anchor-plugin';
import { getEditorView } from './editor-state';
import { showSpellcheckMenu } from './spellcheck-menu';

// --- Types ---

interface SpellcheckResult {
  from: number;
  to: number;
  word: string;
  type: 'spelling' | 'grammar';
  suggestions: string[];
  message?: string | null;
}

interface TextSegment {
  text: string;
  from: number;
  to: number;
}

// --- Module state ---

let spellcheckResults: SpellcheckResult[] = [];
let currentRequestId = 0;
let debounceTimer: ReturnType<typeof setTimeout> | null = null;
let enabled = true;

// --- API exports ---

export function setSpellcheckResults(requestId: number, results: SpellcheckResult[]): void {
  if (requestId !== currentRequestId) return;
  spellcheckResults = results;

  // Force CM6 to re-render decorations
  const view = getEditorView();
  if (view) {
    // Dispatch a no-op transaction to trigger decoration rebuild
    view.dispatch({});
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
  const view = getEditorView();
  if (view) {
    view.dispatch({});
  }
}

// --- Hidden marker stripping ---

/**
 * Strip hidden markers (section anchors, bibliography markers) from extracted segments.
 * These are visually hidden by Decoration.replace() but present in the raw text,
 * causing NSSpellChecker to flag UUID hex fragments as misspelled words.
 */
function stripHiddenMarkers(segments: TextSegment[]): TextSegment[] {
  return segments.flatMap((seg) => {
    const parts: TextSegment[] = [];
    let lastIdx = 0;
    const regex = new RegExp(ALL_HIDDEN_MARKERS_REGEX.source, 'g');
    let m: RegExpExecArray | null;
    while ((m = regex.exec(seg.text)) !== null) {
      if (m.index > lastIdx) {
        const text = seg.text.slice(lastIdx, m.index);
        if (text.trim().length > 0) {
          parts.push({ text, from: seg.from + lastIdx, to: seg.from + m.index });
        }
      }
      lastIdx = m.index + m[0].length;
    }
    if (lastIdx === 0) return [seg]; // No markers found
    if (lastIdx < seg.text.length) {
      const text = seg.text.slice(lastIdx);
      if (text.trim().length > 0) {
        parts.push({ text, from: seg.from + lastIdx, to: seg.from + lastIdx + text.length });
      }
    }
    return parts;
  });
}

// --- Text extraction ---

/** Lezer node types to skip (no text extraction inside these) */
const SKIP_NODES = new Set([
  'FencedCode',
  'InlineCode',
  'CodeBlock',
  'URL',
  'Autolink',
  'HTMLTag',
  'CodeText',
  'CodeInfo',
  'HTMLBlock',
  'CommentBlock',
  // Markdown marker nodes — syntax characters (# > - * _ ` [ ] etc.)
  // that would cause false positives if sent to NSSpellChecker
  'HeaderMark',
  'QuoteMark',
  'ListMark',
  'EmphasisMark',
  'CodeMark',
  'LinkMark',
  'HardBreak',
  'Escape',
]);

/**
 * Extract checkable text segments from CodeMirror document.
 * Walks the Lezer syntax tree to identify code/URL regions to skip.
 */
function extractSegments(view: EditorView): TextSegment[] {
  const doc = view.state.doc;
  const tree = syntaxTree(view.state);
  const segments: TextSegment[] = [];

  // Build a list of ranges to skip
  const skipRanges: { from: number; to: number }[] = [];
  tree.iterate({
    enter: (node) => {
      if (SKIP_NODES.has(node.name)) {
        skipRanges.push({ from: node.from, to: node.to });
        return false; // Don't descend
      }
    },
  });

  // Sort skip ranges
  skipRanges.sort((a, b) => a.from - b.from);

  // Process each line, skipping code/URL ranges
  for (let lineNum = 1; lineNum <= doc.lines; lineNum++) {
    const line = doc.line(lineNum);
    if (line.length === 0) continue;

    // Find portions of this line that aren't in skip ranges
    let pos = line.from;
    const lineEnd = line.to;

    for (const skip of skipRanges) {
      if (skip.to <= pos) continue;
      if (skip.from >= lineEnd) break;

      // Text before the skip range
      const textStart = Math.max(pos, line.from);
      const textEnd = Math.min(skip.from, lineEnd);
      if (textEnd > textStart) {
        const text = doc.sliceString(textStart, textEnd);
        if (text.trim().length > 0) {
          segments.push({ text, from: textStart, to: textEnd });
        }
      }
      pos = Math.max(pos, skip.to);
    }

    // Remaining text after last skip range
    if (pos < lineEnd) {
      const textStart = Math.max(pos, line.from);
      const text = doc.sliceString(textStart, lineEnd);
      if (text.trim().length > 0) {
        segments.push({ text, from: textStart, to: lineEnd });
      }
    }
  }

  // Strip hidden markers (anchor comments, bibliography markers) that
  // are visually collapsed but present in raw text — prevents false positives
  return stripHiddenMarkers(segments);
}

// --- Check trigger ---

function triggerCheck(): void {
  if (!enabled) return;

  const view = getEditorView();
  if (!view) return;

  const segments = extractSegments(view);

  if (segments.length === 0) {
    spellcheckResults = [];
    view.dispatch({});
    return;
  }

  currentRequestId++;
  const requestId = currentRequestId;

  console.log('[spellcheck-cm] Sending', segments.length, 'segments to Swift');
  segments.forEach((s, i) =>
    console.log(`[spellcheck-cm] segment[${i}]:`, JSON.stringify(s.text), `pos ${s.from}-${s.to}`)
  );

  window.webkit?.messageHandlers?.spellcheck?.postMessage({
    action: 'check',
    segments: segments.map((s) => ({ text: s.text, from: s.from, to: s.to })),
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

// --- Decoration builder ---

const spellingDeco = Decoration.mark({ class: 'cm-spell-error' });
const grammarDeco = Decoration.mark({ class: 'cm-grammar-error' });

function buildDecorations(view: EditorView): DecorationSet {
  if (!enabled || spellcheckResults.length === 0) {
    return Decoration.none;
  }

  const builder = new RangeSetBuilder<Decoration>();
  const docLength = view.state.doc.length;

  // Sort results by from position (required by RangeSetBuilder)
  const sorted = [...spellcheckResults]
    .filter((r) => r.from >= 0 && r.to <= docLength && r.from < r.to)
    .sort((a, b) => a.from - b.from || a.to - b.to);

  for (const result of sorted) {
    builder.add(result.from, result.to, result.type === 'grammar' ? grammarDeco : spellingDeco);
  }

  return builder.finish();
}

// --- Plugin ---

export function spellcheckPlugin() {
  return [
    ViewPlugin.fromClass(
      class {
        decorations: DecorationSet;

        constructor(view: EditorView) {
          this.decorations = buildDecorations(view);
        }

        update(update: ViewUpdate) {
          if (update.docChanged) {
            debouncedCheck();
          }
          // Always rebuild decorations (results may have changed)
          this.decorations = buildDecorations(update.view);
        }
      },
      {
        decorations: (v) => v.decorations,

        eventHandlers: {
          contextmenu(event: MouseEvent, view: EditorView) {
            if (!enabled) return false;

            const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
            if (pos === null) return false;

            const result = findResultAtPos(pos);
            if (!result) return false;

            event.preventDefault();

            showSpellcheckMenu({
              x: event.clientX,
              y: event.clientY,
              word: result.word,
              type: result.type as 'spelling' | 'grammar',
              suggestions: result.suggestions,
              message: result.message,
              onReplace: (replacement: string) => {
                console.log('[spellcheck-cm] onReplace called:', replacement, 'at', result.from, result.to);
                console.log('[spellcheck-cm] current text at pos:', view.state.doc.sliceString(result.from, result.to));
                view.dispatch({
                  changes: { from: result.from, to: result.to, insert: replacement },
                });
              },
              onLearn: (word: string) => {
                spellcheckResults = spellcheckResults.filter((r) => r.word !== word);
                view.dispatch({});
                window.webkit?.messageHandlers?.spellcheck?.postMessage({ action: 'learn', word });
                triggerCheck();
              },
              onIgnore: (word: string) => {
                spellcheckResults = spellcheckResults.filter((r) => r.word !== word);
                view.dispatch({});
                window.webkit?.messageHandlers?.spellcheck?.postMessage({ action: 'ignore', word });
                triggerCheck();
              },
            });

            return true;
          },
        },
      }
    ),
  ];
}
