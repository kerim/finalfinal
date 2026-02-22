/**
 * Section Anchor & Bibliography Plugin for CodeMirror 6
 *
 * Hides invisible markers in the editor while preserving them in the document:
 * - `<!-- @sid:UUID -->` - Section anchors for ID tracking
 * - `<!-- ::auto-bibliography:: -->` - Bibliography marker (on same line as header)
 * - `<!-- ::zoom-notes:: -->` - Zoom-notes separator (between content and footnotes)
 *
 * Features:
 * - Decoration.replace() makes markers invisible
 * - atomicRanges makes cursor skip over hidden regions
 * - Clipboard handlers strip markers from copied text
 */

import { type EditorState, type Extension, RangeSetBuilder } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';

// Regex to match section anchor comments: <!-- @sid:UUID -->
// UUID format: 8-4-4-4-12 hex characters (standard UUID v4)
// Anchors are on the same line as headers (no trailing newline)
const _ANCHOR_REGEX = /<!-- @sid:[0-9a-fA-F-]+ -->/g;

// For extracting anchor info (no newline - just the comment)
const ANCHOR_PATTERN = /<!-- @sid:([0-9a-fA-F-]+) -->/;

// For decorations and atomic ranges
// Anchors are on the same line as headers: <!-- @sid:UUID --># Header
const ANCHOR_DECORATION_REGEX = /<!-- @sid:[0-9a-fA-F-]+ -->/g;

// Bibliography marker - on same line as header, no end marker needed
// Pattern: <!-- ::auto-bibliography:: --># Bibliography
const BIBLIOGRAPHY_START_REGEX = /<!-- ::auto-bibliography:: -->/g;

// Zoom-notes marker - separates main content from footnotes when zoomed into a section
const ZOOM_NOTES_MARKER_REGEX = /<!-- ::zoom-notes:: -->/g;

// Combined regex for stripping all hidden markers from clipboard
// No end marker - only start marker and section anchors
// Exported for spellcheck-plugin to strip markers before checking
export const ALL_HIDDEN_MARKERS_REGEX =
  /<!-- @sid:[0-9a-fA-F-]+ -->|<!-- ::auto-bibliography:: -->|<!-- ::zoom-notes:: -->/g;

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
  return [anchorDecorationPlugin, atomicAnchorRanges, clipboardHandlers];
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
