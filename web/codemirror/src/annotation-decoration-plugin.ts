/**
 * Annotation decoration plugin for CodeMirror 6
 *
 * Styles annotation marks (<!-- ::task:: ... -->, <!-- ::comment:: ... -->,
 * <!-- ::reference:: ... -->) with type-differentiated colors.
 * Delimiters render in secondary text color; content gets type-specific color.
 */

import { RangeSetBuilder } from '@codemirror/state';
import { Decoration, type DecorationSet, type EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';

// --- Constants ---

/** Annotation types that should receive decoration styling */
const ANNOTATION_TYPES = new Set(['task', 'comment', 'reference']);

/** Matches annotation HTML comments with captured segments:
 *  Group 1: opening delimiter (<!-- )
 *  Group 2: type + content (::task:: [ ] some text)
 *  Group 3: type name (task)
 *  Group 4: closing delimiter ( -->)
 */
const ANNOTATION_REGEX = /(<!--\s*)(::(\w+)::\s*.+?)(\s*-->)/gs;

/** Matches task checkbox to detect completed tasks */
const TASK_CHECKBOX_REGEX = /^\s*\[([ xX])\]\s*/s;

// --- Decoration marks ---

const delimDeco = Decoration.mark({ class: 'cm-annotation-delim' });
const taskDeco = Decoration.mark({ class: 'cm-annotation-task' });
const taskCompletedDeco = Decoration.mark({ class: 'cm-annotation-task-completed' });
const commentDeco = Decoration.mark({ class: 'cm-annotation-comment' });
const referenceDeco = Decoration.mark({ class: 'cm-annotation-reference' });

// --- Decoration builder ---

function buildDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const text = view.state.doc.toString();
  const ranges: { from: number; to: number; deco: Decoration }[] = [];

  ANNOTATION_REGEX.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = ANNOTATION_REGEX.exec(text)) !== null) {
    const type = match[3];
    if (!ANNOTATION_TYPES.has(type)) continue;

    const fullStart = match.index;
    const openDelim = match[1]; // <!--
    const content = match[2]; // ::type:: content
    const closeDelim = match[4]; // -->

    // Opening delimiter: <!--
    const openFrom = fullStart;
    const openTo = fullStart + openDelim.length;
    ranges.push({ from: openFrom, to: openTo, deco: delimDeco });

    // Content: ::type:: text
    const contentFrom = openTo;
    const contentTo = openTo + content.length;

    let contentDeco: Decoration;
    if (type === 'task') {
      const checkboxMatch = content.match(TASK_CHECKBOX_REGEX);
      if (checkboxMatch && checkboxMatch[1].toLowerCase() === 'x') {
        contentDeco = taskCompletedDeco;
      } else {
        contentDeco = taskDeco;
      }
    } else if (type === 'comment') {
      contentDeco = commentDeco;
    } else {
      contentDeco = referenceDeco;
    }
    ranges.push({ from: contentFrom, to: contentTo, deco: contentDeco });

    // Closing delimiter: -->
    const closeFrom = contentTo;
    const closeTo = contentTo + closeDelim.length;
    ranges.push({ from: closeFrom, to: closeTo, deco: delimDeco });
  }

  // Sort by position with tiebreaker for consistency
  ranges.sort((a, b) => a.from - b.from || a.to - b.to);

  for (const range of ranges) {
    builder.add(range.from, range.to, range.deco);
  }

  return builder.finish();
}

// --- Plugin ---

export function annotationDecorationPlugin() {
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
    }
  );
}
