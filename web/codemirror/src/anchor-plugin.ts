/**
 * Section Anchor Plugin for CodeMirror 6
 *
 * Hides `<!-- @sid:UUID -->` comments in the editor while preserving them in the document.
 * These anchors travel with content during cut/paste/reorder operations, providing
 * 100% accurate section ID tracking.
 *
 * Features:
 * - Decoration.replace() makes anchors invisible
 * - atomicRanges makes cursor skip over hidden regions
 * - Clipboard handlers strip anchors from copied text
 */

import { type EditorState, type Extension, RangeSetBuilder } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';

// Regex to match section anchor comments: <!-- @sid:UUID -->
// UUID format: 8-4-4-4-12 hex characters (standard UUID v4)
// Includes optional trailing newline for stripping operations
const ANCHOR_REGEX = /<!-- @sid:[0-9a-fA-F-]+ -->\n?/g;

// For extracting anchor info (no newline - just the comment)
const ANCHOR_PATTERN = /<!-- @sid:([0-9a-fA-F-]+) -->/;

// For decorations and atomic ranges - must NOT include newline
// (CodeMirror restriction: Decoration.replace() cannot span line breaks)
// Users CAN delete the newline after anchors - normalization happens on mode switch
const ANCHOR_DECORATION_REGEX = /<!-- @sid:[0-9a-fA-F-]+ -->/g;

/**
 * Find all anchor ranges in the document for decoration purposes
 * Uses ANCHOR_DECORATION_REGEX which excludes newlines (CodeMirror restriction:
 * Decoration.replace() cannot span line breaks when specified via plugins)
 */
function findAnchorsForDecoration(state: EditorState): { from: number; to: number; id: string }[] {
  const text = state.doc.toString();
  const anchors: { from: number; to: number; id: string }[] = [];

  let match: RegExpExecArray | null;
  ANCHOR_DECORATION_REGEX.lastIndex = 0;
  while ((match = ANCHOR_DECORATION_REGEX.exec(text)) !== null) {
    const idMatch = match[0].match(ANCHOR_PATTERN);
    if (idMatch) {
      anchors.push({
        from: match.index,
        to: match.index + match[0].length,
        id: idMatch[1],
      });
    }
  }

  return anchors;
}

/**
 * Build decorations to hide anchor comments (visual only, excludes newlines)
 */
function buildDecorations(state: EditorState): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const anchors = findAnchorsForDecoration(state);

  for (const anchor of anchors) {
    // Use Decoration.replace with empty widget to completely hide the anchor
    builder.add(anchor.from, anchor.to, Decoration.replace({}));
  }

  return builder.finish();
}

/**
 * ViewPlugin that maintains decorations to hide anchors (visual only)
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
 * Extension that makes cursor skip over anchor regions (anchor comment only)
 * Users CAN delete the newline after anchors - normalization happens on mode switch
 */
const atomicAnchorRanges = EditorView.atomicRanges.of((view: EditorView) => {
  const plugin = view.plugin(anchorDecorationPlugin);
  return plugin?.decorations ?? Decoration.none;
});

/**
 * Strip anchor comments from text
 * Used for clipboard operations to ensure clean export
 */
export function stripAnchors(text: string): string {
  return text.replace(ANCHOR_REGEX, '');
}

/**
 * Extract anchor IDs and their positions from text
 * Returns array of { id, offset } where offset is position in the STRIPPED text
 */
export function extractAnchors(text: string): { id: string; headerOffset: number }[] {
  const results: { id: string; headerOffset: number }[] = [];
  let strippedOffset = 0;
  let originalOffset = 0;

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
      originalOffset += line.length + 1;
      continue;
    }

    strippedOffset += line.length + 1;
    originalOffset += line.length + 1;
  }

  return results;
}

/**
 * Inject anchor comments before headers
 * Takes markdown and a map of header positions to section IDs
 */
export function injectAnchors(markdown: string, anchors: { sectionId: string; headerOffset: number }[]): string {
  if (anchors.length === 0) return markdown;

  // Sort anchors by offset in reverse order so we can insert from end to start
  // (this prevents offset drift during insertion)
  const sorted = [...anchors].sort((a, b) => b.headerOffset - a.headerOffset);

  let result = markdown;
  for (const anchor of sorted) {
    const anchorText = `<!-- @sid:${anchor.sectionId} -->\n`;
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
