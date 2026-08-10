/**
 * Section Anchor & Bibliography Plugin for CodeMirror 6
 *
 * Hides invisible markers in the editor while preserving them in the document:
 * - `<!-- @sid:UUID -->` - Section anchors for ID tracking
 * - `<!-- ::auto-bibliography:: -->` - Bibliography marker (on same line as header)
 * - `<!-- ::auto-bibliography-end:: -->` - Bibliography terminator (own line, closes the
 *   section for BlockParser.parse() — see BlockParser.bibliographyEndMarker's Swift-side doc
 *   comment). Same treatment as the opening marker above: hidden, atomic, clipboard-stripped.
 *   Unlike the opening marker, an accidentally-corrupted terminator (e.g. one dropped
 *   character from the cursor landing inside it) doesn't just fail to re-open the section —
 *   `parse()` matches it by exact string equality, so a corrupted terminator silently fails
 *   to CLOSE the section, re-flagging trailing user text as bibliography on the next reparse
 *   and reopening the exact orphan-flag bug this marker exists to fix. That's why the atomic
 *   range here isn't optional polish. It also gets an Enter-key insertion-boundary fix — see
 *   `bibliographyEndEnterKeymap` below — the CodeMirror analogue of
 *   bibliography-end-marker-plugin.ts's `bibliographyEndEnterKeymap` in the Milkdown package.
 * - `<!-- ::zoom-notes:: -->` - Zoom-notes separator (between content and footnotes)
 *
 * Features:
 * - Decoration.replace() makes markers invisible
 * - atomicRanges makes cursor skip over hidden regions
 * - Clipboard handlers strip markers from copied text
 * - Enter at the end of the last bibliography entry's line inserts the new line after the
 *   terminator instead of before it
 */

import { type EditorState, type Extension, Prec, RangeSetBuilder } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, keymap, ViewPlugin, type ViewUpdate } from '@codemirror/view';

// Regex to match section anchor comments: <!-- @sid:UUID -->
// UUID format: 8-4-4-4-12 hex characters (standard UUID v4)
// Anchors are on the same line as headers (no trailing newline)
const _ANCHOR_REGEX = /<!-- @sid:[0-9a-fA-F-]+ -->/g;

// For extracting anchor info (no newline - just the comment)
const ANCHOR_PATTERN = /<!-- @sid:([0-9a-fA-F-]+) -->/;

// For decorations and atomic ranges
// Anchors are on the same line as headers: <!-- @sid:UUID --># Header
const ANCHOR_DECORATION_REGEX = /<!-- @sid:[0-9a-fA-F-]+ -->/g;

// Bibliography marker - on same line as header, matched as one standalone HTML comment
// (not a start/end delimiter pair itself — the separate BIBLIOGRAPHY_END_REGEX below is a
// different marker altogether, closing the whole section rather than this one comment)
// Pattern: <!-- ::auto-bibliography:: --># Bibliography
const BIBLIOGRAPHY_START_REGEX = /<!-- ::auto-bibliography:: -->/g;

// Bibliography terminator - own blank-line-separated line, closes the section for
// BlockParser.parse() (Swift side). See BlockParser.bibliographyEndMarker's doc comment.
const BIBLIOGRAPHY_END_REGEX = /<!-- ::auto-bibliography-end:: -->/g;

// Zoom-notes marker - separates main content from footnotes when zoomed into a section
const ZOOM_NOTES_MARKER_REGEX = /<!-- ::zoom-notes:: -->/g;

// Combined regex for stripping all hidden markers from clipboard
// Exported for spellcheck-plugin to strip markers before checking
export const ALL_HIDDEN_MARKERS_REGEX =
  /<!-- @sid:[0-9a-fA-F-]+ -->|<!-- ::auto-bibliography:: -->|<!-- ::auto-bibliography-end:: -->|<!-- ::zoom-notes:: -->/g;

/**
 * Find all hidden marker ranges in the document for decoration purposes
 * Includes section anchors and bibliography markers
 */
function findHiddenMarkers(state: EditorState): { from: number; to: number }[] {
  const text = state.doc.toString();
  const markers: { from: number; to: number }[] = [];

  // Find section anchors
  let match: RegExpExecArray | null;
  ANCHOR_DECORATION_REGEX.lastIndex = 0;
  while ((match = ANCHOR_DECORATION_REGEX.exec(text)) !== null) {
    markers.push({
      from: match.index,
      to: match.index + match[0].length,
    });
  }

  // Find bibliography start markers (on same line as header, no end marker)
  BIBLIOGRAPHY_START_REGEX.lastIndex = 0;
  while ((match = BIBLIOGRAPHY_START_REGEX.exec(text)) !== null) {
    markers.push({
      from: match.index,
      to: match.index + match[0].length,
    });
  }

  // Find bibliography end (terminator) markers
  BIBLIOGRAPHY_END_REGEX.lastIndex = 0;
  while ((match = BIBLIOGRAPHY_END_REGEX.exec(text)) !== null) {
    markers.push({
      from: match.index,
      to: match.index + match[0].length,
    });
  }

  // Find zoom-notes markers (separates content from footnotes in zoomed sections)
  ZOOM_NOTES_MARKER_REGEX.lastIndex = 0;
  while ((match = ZOOM_NOTES_MARKER_REGEX.exec(text)) !== null) {
    markers.push({
      from: match.index,
      to: match.index + match[0].length,
    });
  }

  // Sort by position (required for RangeSetBuilder)
  markers.sort((a, b) => a.from - b.from);

  return markers;
}

/**
 * Build decorations to hide all hidden markers visually
 */
function buildDecorations(state: EditorState): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const markers = findHiddenMarkers(state);

  for (const marker of markers) {
    // Use Decoration.replace with empty widget to completely hide the marker
    builder.add(marker.from, marker.to, Decoration.replace({}));
  }

  return builder.finish();
}

/**
 * ViewPlugin that maintains decorations to hide all markers visually
 */
const anchorDecorationPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = buildDecorations(view.state);
    }

    update(update: ViewUpdate) {
      if (update.docChanged || update.viewportChanged) {
        this.decorations = buildDecorations(update.state);
      }
    }
  },
  {
    decorations: (v) => v.decorations,
  }
);

/**
 * Extension that makes cursor skip over hidden marker regions
 * Section anchors are on the same line as headers, so hiding them doesn't create blank lines
 * Bibliography markers are on their own lines (may leave empty lines when hidden)
 */
const atomicAnchorRanges = EditorView.atomicRanges.of((view: EditorView) => {
  const plugin = view.plugin(anchorDecorationPlugin);
  return plugin?.decorations ?? Decoration.none;
});

// ---- Bibliography terminator Enter-key insertion-boundary fix ----
//
// CodeMirror analogue of bibliography-end-marker-plugin.ts's `bibliographyEndEnterKeymap` in
// the Milkdown package — see that file's doc comment for the full rationale. CodeMirror has no
// block-node structure, so both the check and the fix below operate on raw text lines instead
// of ProseMirror doc nodes.
//
// The terminator always sits on its own line, blank-line-separated from whatever precedes it
// (fragments are joined with "\n\n" — see BlockParser+Assembly.swift's
// `assembleMarkdownForEditor`). CodeMirror's default Enter behavior (`insertNewlineAndIndent`,
// from `defaultKeymap` in main.ts) inserts the new line AT the cursor position — so a cursor at
// the end of the last bibliography entry's line, followed by Enter, would insert the new line
// BEFORE the terminator: still positionally inside the section on the next reparse (Source
// Mode's debounced re-parse, or the reparse that runs immediately before every PDF export),
// reproducing the exact orphan-flag bug this whole mechanism exists to close — on the single
// most natural way a user would type: Enter, then type.

/**
 * If `pos` sits at the very end of the nearest non-blank line above the bibliography-end
 * terminator (skipping any blank lines in between — the ordinary case is exactly one, from the
 * "\n\n" fragment join), returns the position immediately after the terminator's own line text
 * — where a new blank-line-separated line should be inserted instead of splitting at the
 * cursor. Returns null when there's no terminator in the document, or `pos` doesn't qualify
 * (ordinary mid-text or mid-document Enter, which must fall through to CodeMirror's default
 * behavior).
 *
 * Exported so it can be exercised directly in tests, mirroring how bibliography-end-marker-
 * plugin.ts's `isBibliographyEndMarkerAdjacent` is exported for the same reason.
 */
export function bibliographyEndInsertionPoint(state: EditorState, pos: number): number | null {
  const cursorLine = state.doc.lineAt(pos);
  if (pos !== cursorLine.to) return null; // must be at the very end of its line

  const text = state.doc.toString();
  BIBLIOGRAPHY_END_REGEX.lastIndex = 0;
  let match: RegExpExecArray | null;
  // Loop defensively over every match — assembleMarkdownForEditor only ever emits one
  // terminator per document today, but nothing here depends on that staying true.
  while ((match = BIBLIOGRAPHY_END_REGEX.exec(text)) !== null) {
    const terminatorLine = state.doc.lineAt(match.index);

    let lineNumber = terminatorLine.number - 1;
    while (lineNumber >= 1 && state.doc.line(lineNumber).text.trim() === '') {
      lineNumber--;
    }
    if (lineNumber >= 1 && lineNumber === cursorLine.number) {
      return terminatorLine.to;
    }
  }

  return null;
}

/**
 * Enter-key placement fix as a CodeMirror keymap binding. Wrapped in `Prec.highest` so it
 * always gets first refusal on Enter regardless of where `anchorPlugin()` sits in main.ts's
 * extension array — main.ts registers `defaultKeymap` (which owns the default Enter binding,
 * `insertNewlineAndIndent`) in its own separate `keymap.of([...])` call earlier in that array,
 * so without an explicit precedence bump this binding would lose on plain array order. This
 * makes the same guarantee the Milkdown fix documents relying on (every `$prose` plugin sits
 * ahead of Milkdown's merged base+preset keymap) explicit here via CodeMirror's own precedence
 * mechanism instead of an implicit array-order convention.
 */
const bibliographyEndEnterKeymap = Prec.highest(
  keymap.of([
    {
      key: 'Enter',
      run: (view: EditorView): boolean => {
        const sel = view.state.selection.main;
        if (!sel.empty) return false;

        const insertPos = bibliographyEndInsertionPoint(view.state, sel.head);
        if (insertPos === null) return false;

        // Insert two newlines right after the terminator's own line text. Combined with the
        // blank line already separating the terminator from whatever precedes or follows it,
        // this lands the cursor on its own blank-line-separated empty line — a new paragraph
        // positioned strictly after the terminator (and before any trailing content), instead
        // of splitting the current line in place ahead of it.
        view.dispatch({
          changes: { from: insertPos, to: insertPos, insert: '\n\n' },
          selection: { anchor: insertPos + 2 },
          scrollIntoView: true,
          userEvent: 'input',
        });
        return true;
      },
    },
  ])
);

/**
 * Strip all hidden markers from text (anchors and bibliography markers)
 * Used for clipboard operations to ensure clean export
 */
export function stripAnchors(text: string): string {
  return text.replace(ALL_HIDDEN_MARKERS_REGEX, '');
}

/**
 * Extract anchor IDs and their positions from text
 * Returns array of { id, offset } where offset is position in the STRIPPED text
 */
export function extractAnchors(text: string): { id: string; headerOffset: number }[] {
  const results: { id: string; headerOffset: number }[] = [];
  let strippedOffset = 0;
  let _originalOffset = 0;

  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const match = line.match(ANCHOR_PATTERN);

    if (match) {
      // This line is an anchor - the next non-empty line should be the header
      // Store the offset where the header will be after stripping
      results.push({
        id: match[1],
        headerOffset: strippedOffset,
      });
      // Don't add this line to strippedOffset since it will be removed
      _originalOffset += line.length + 1;
      continue;
    }

    strippedOffset += line.length + 1;
    _originalOffset += line.length + 1;
  }

  return results;
}

/**
 * Inject anchor comments before headers
 * Takes markdown and a map of header positions to section IDs
 * Anchors are placed on the SAME LINE as the header (no newline after anchor)
 * to prevent blank lines when the anchor decoration hides the comment
 */
export function injectAnchors(markdown: string, anchors: { sectionId: string; headerOffset: number }[]): string {
  if (anchors.length === 0) return markdown;

  // Sort anchors by offset in reverse order so we can insert from end to start
  // (this prevents offset drift during insertion)
  const sorted = [...anchors].sort((a, b) => b.headerOffset - a.headerOffset);

  let result = markdown;
  for (const anchor of sorted) {
    // No newline after anchor - anchor stays on same line as header
    const anchorText = `<!-- @sid:${anchor.sectionId} -->`;
    const offset = Math.min(anchor.headerOffset, result.length);
    result = result.slice(0, offset) + anchorText + result.slice(offset);
  }

  return result;
}

/**
 * DOM event handlers for clipboard operations
 * Strips anchors from copied/cut text to ensure clean export
 */
const clipboardHandlers = EditorView.domEventHandlers({
  copy(event, view) {
    const selection = view.state.selection.main;
    if (selection.empty) return false;

    const text = view.state.sliceDoc(selection.from, selection.to);
    const cleanText = stripAnchors(text);

    // Only intercept if there were anchors to strip
    if (cleanText !== text) {
      event.clipboardData?.setData('text/plain', cleanText);
      event.preventDefault();
      return true;
    }

    return false;
  },

  cut(event, view) {
    const selection = view.state.selection.main;
    if (selection.empty) return false;

    const text = view.state.sliceDoc(selection.from, selection.to);
    const cleanText = stripAnchors(text);

    // Only intercept if there were anchors to strip
    if (cleanText !== text) {
      event.clipboardData?.setData('text/plain', cleanText);
      event.preventDefault();

      // Perform the cut by deleting selected text
      view.dispatch({
        changes: { from: selection.from, to: selection.to },
        userEvent: 'delete.cut',
      });

      return true;
    }

    return false;
  },
});

/**
 * Main extension bundle for the anchor plugin
 * Includes all necessary extensions for hiding anchors and handling clipboard
 */
export function anchorPlugin(): Extension {
  return [anchorDecorationPlugin, atomicAnchorRanges, clipboardHandlers, bibliographyEndEnterKeymap];
}

/**
 * Get content without anchors (for Swift API)
 */
export function getContentWithoutAnchors(view: EditorView): string {
  return stripAnchors(view.state.doc.toString());
}

/**
 * Get raw content including anchors
 */
export function getContentWithAnchors(view: EditorView): string {
  return view.state.doc.toString();
}
