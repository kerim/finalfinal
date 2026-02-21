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
import { dismissMenu, showSpellcheckMenu } from './spellcheck-menu';
import { dismissPopover, showProofingPopover } from './spellcheck-popover';

// --- Types ---

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

interface TextSegment {
  text: string;
  from: number;
  to: number;
  blockId?: number;
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
          parts.push({ text, from: seg.from + lastIdx, to: seg.from + m.index, blockId: seg.blockId });
        }
      }
      lastIdx = m.index + m[0].length;
    }
    if (lastIdx === 0) return [seg]; // No markers found
    if (lastIdx < seg.text.length) {
      const text = seg.text.slice(lastIdx);
      if (text.trim().length > 0) {
        parts.push({ text, from: seg.from + lastIdx, to: seg.from + lastIdx + text.length, blockId: seg.blockId });
      }
    }
    return parts;
  });
}

// --- Citation stripping ---

/** Matches segments that are entirely Pandoc citation content (no brackets — those are stripped by LinkMark skip) */
const CITATION_CONTENT_REGEX = /^-?@[\w]/;

/**
 * Filter out segments that are bare citation keys.
 * Lezer's LinkMark (in SKIP_NODES) strips [ and ] brackets, so citation
 * content like `@friedmanLearningLocalLanguages2005` appears as its own
 * segment without brackets. We filter these out entirely so LanguageTool
 * never sees them.
 */
function stripCitations(segments: TextSegment[]): TextSegment[] {
  return segments.filter((seg) => !CITATION_CONTENT_REGEX.test(seg.text.trim()));
}

// --- Footnote marker stripping ---

/** Matches [^N] footnote references and [^N]: definition prefixes */
const FOOTNOTE_REF_REGEX = /\[\^\d+\]/g;
const FOOTNOTE_DEF_REGEX = /^\[\^\d+\]:\s*/;

/**
 * Strip footnote markers from segments to prevent spellcheck false positives.
 * Removes [^N] references inline and [^N]: prefixes at line start.
 */
function stripFootnoteMarkers(segments: TextSegment[]): TextSegment[] {
  return segments
    .map((seg) => {
      let { text, from } = seg;

      // Strip [^N]: prefix at line start
      const defMatch = FOOTNOTE_DEF_REGEX.exec(text);
      if (defMatch) {
        text = text.slice(defMatch[0].length);
        from += defMatch[0].length;
      }

      // Strip [^N] references inline
      text = text.replace(FOOTNOTE_REF_REGEX, '');

      if (text.trim().length === 0) return null;
      return { ...seg, text, from };
    })
    .filter((seg): seg is TextSegment => seg !== null);
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
  'Comment', // inline HTML comments (annotations, section anchors)
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
          segments.push({ text, from: textStart, to: textEnd, blockId: lineNum });
        }
      }
      pos = Math.max(pos, skip.to);
    }

    // Remaining text after last skip range
    if (pos < lineEnd) {
      const textStart = Math.max(pos, line.from);
      const text = doc.sliceString(textStart, lineEnd);
      if (text.trim().length > 0) {
        segments.push({ text, from: textStart, to: lineEnd, blockId: lineNum });
      }
    }
  }

  // Strip hidden markers (anchor comments, bibliography markers) and footnote syntax
  // that are visually collapsed but present in raw text — prevents false positives
  return stripCitations(stripFootnoteMarkers(stripHiddenMarkers(segments)));
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

// --- Decoration builder ---

const spellingDeco = Decoration.mark({ class: 'cm-spell-error' });
const grammarDeco = Decoration.mark({ class: 'cm-grammar-error' });
const styleDeco = Decoration.mark({ class: 'cm-style-error' });

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
    const deco = result.type === 'grammar' ? grammarDeco : result.type === 'style' ? styleDeco : spellingDeco;
    builder.add(result.from, result.to, deco);
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

            // Grammar/style uses click popover, not context menu
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
          click(event: MouseEvent, view: EditorView) {
            if (!enabled) return false;

            const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
            if (pos === null) return false;

            const result = findResultAtPos(pos);
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
                view.dispatch({
                  changes: { from: result.from, to: result.to, insert: suggestion },
                });
              },
              onIgnore: () => {
                spellcheckResults = spellcheckResults.filter((r) => r !== result);
                view.dispatch({});
                window.webkit?.messageHandlers?.spellcheck?.postMessage({ action: 'ignore', word: result.word });
                triggerCheck();
              },
              onDisableRule: (ruleId: string) => {
                spellcheckResults = spellcheckResults.filter((r) => r.ruleId !== ruleId);
                view.dispatch({});
                window.webkit?.messageHandlers?.spellcheck?.postMessage({ action: 'disableRule', ruleId });
              },
            });

            return true;
          },
        },
      }
    ),
  ];
}
