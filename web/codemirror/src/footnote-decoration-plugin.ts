/**
 * Footnote decoration plugin for CodeMirror 6
 *
 * Adds clickable styling to footnote references [^N] in document body
 * and footnote definitions [^N]: in the #Notes section.
 * Clicking a reference navigates to its definition, and vice versa.
 */

import { RangeSetBuilder } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';

// --- Regex patterns ---

/** Matches footnote references: [^N] (not followed by :) */
const FOOTNOTE_REF_REGEX = /\[\^(\d+)\](?!:)/g;

/** Matches footnote definition prefixes: [^N]: at line start */
const FOOTNOTE_DEF_REGEX = /^\[\^(\d+)\]:/gm;

// --- Decoration marks ---

const refDeco = Decoration.mark({ class: 'cm-footnote-ref' });
const defDeco = Decoration.mark({ class: 'cm-footnote-def' });

// --- Decoration builder ---

function buildDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const text = view.state.doc.toString();
  const ranges: { from: number; to: number; deco: Decoration }[] = [];

  // Find footnote references
  FOOTNOTE_REF_REGEX.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = FOOTNOTE_REF_REGEX.exec(text)) !== null) {
    ranges.push({ from: match.index, to: match.index + match[0].length, deco: refDeco });
  }

  // Find footnote definitions
  FOOTNOTE_DEF_REGEX.lastIndex = 0;
  while ((match = FOOTNOTE_DEF_REGEX.exec(text)) !== null) {
    // Mark just the [^N]: prefix (not the definition content)
    ranges.push({ from: match.index, to: match.index + match[0].length, deco: defDeco });
  }

  // Sort by position (required by RangeSetBuilder)
  ranges.sort((a, b) => a.from - b.from);

  for (const range of ranges) {
    builder.add(range.from, range.to, range.deco);
  }

  return builder.finish();
}

// --- Click handler ---

function handleClick(view: EditorView, event: MouseEvent): boolean {
  const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
  if (pos === null) return false;

  const text = view.state.doc.toString();

  // Check footnote references -> navigate to definition
  FOOTNOTE_REF_REGEX.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = FOOTNOTE_REF_REGEX.exec(text)) !== null) {
    if (pos >= match.index && pos < match.index + match[0].length) {
      const label = match[1];
      const defRegex = new RegExp(`^\\[\\^${label}\\]:`, 'm');
      const defMatch = defRegex.exec(text);
      if (defMatch) {
        view.dispatch({
          selection: { anchor: defMatch.index },
          effects: EditorView.scrollIntoView(defMatch.index, {
            y: 'center',
            yMargin: 100,
          }),
        });
      }
      return true;
    }
  }

  // Check footnote definitions -> navigate to first reference
  FOOTNOTE_DEF_REGEX.lastIndex = 0;
  while ((match = FOOTNOTE_DEF_REGEX.exec(text)) !== null) {
    if (pos >= match.index && pos < match.index + match[0].length) {
      const label = match[1];
      const refRegex = new RegExp(`\\[\\^${label}\\](?!:)`);
      const refMatch = refRegex.exec(text);
      if (refMatch) {
        view.dispatch({
          selection: { anchor: refMatch.index },
          effects: EditorView.scrollIntoView(refMatch.index, {
            y: 'center',
            yMargin: 100,
          }),
        });
      }
      return true;
    }
  }

  return false;
}

// --- Plugin ---

export function footnoteDecorationPlugin() {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;

      constructor(view: EditorView) {
        this.decorations = buildDecorations(view);
      }

      update(update: ViewUpdate) {
        if (update.docChanged || update.viewportChanged) {
          this.decorations = buildDecorations(update.view);
        }
      }
    },
    {
      decorations: (v) => v.decorations,
      eventHandlers: {
        click(event: MouseEvent, view: EditorView) {
          return handleClick(view, event);
        },
      },
    }
  );
}
