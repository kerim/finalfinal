import { HighlightStyle, syntaxHighlighting, syntaxTree } from '@codemirror/language';
import { RangeSetBuilder } from '@codemirror/state';
import { Decoration, type DecorationSet, type EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import { tags } from '@lezer/highlight';

// Custom highlight style for syntax elements (bold, italic, links, code)
// Headings are handled by headingDecorationPlugin (line decorations) instead,
// because HighlightStyle only creates spans for explicitly tagged nodes,
// and heading TEXT is not tagged (only the ATXHeading container node is).
export const customHighlightStyle = HighlightStyle.define([
  { tag: tags.strong, fontWeight: '700' },
  { tag: tags.emphasis, fontStyle: 'italic' },
  { tag: tags.link, color: 'var(--accent-color, #007aff)' },
  { tag: tags.url, color: 'var(--accent-color, #007aff)', opacity: '0.7' },
  { tag: tags.monospace, background: 'var(--editor-selection, rgba(0, 122, 255, 0.1))' },
]);

// Line decoration plugin for markdown headings
// HighlightStyle.define only creates spans for explicitly tagged nodes,
// but heading TEXT is not tagged (only the ATXHeading container is).
// So we use line decorations instead, which apply CSS classes to entire lines.
//
// This plugin has two passes:
// 1. Syntax tree pass: finds standard ATX headings (# at column 0)
// 2. Regex fallback pass: finds headings after section anchors (<!-- @sid:UUID --># heading)
//    These aren't parsed as headings because Markdown requires # at column 0.
export const headingDecorationPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = this.buildDecorations(view);
    }

    update(update: ViewUpdate) {
      if (update.docChanged || update.viewportChanged || syntaxTree(update.startState) !== syntaxTree(update.state)) {
        this.decorations = this.buildDecorations(update.view);
      }
    }

    buildDecorations(view: EditorView): DecorationSet {
      const doc = view.state.doc;
      const decorations: { pos: number; level: number }[] = [];
      const decoratedLines = new Set<number>();

      // First pass: Syntax tree (finds headings at line start)
      for (const { from, to } of view.visibleRanges) {
        syntaxTree(view.state).iterate({
          from,
          to,
          enter: (node) => {
            // Match ATXHeading1 through ATXHeading6
            const match = node.name.match(/^ATXHeading(\d)$/);
            if (match) {
              const line = doc.lineAt(node.from);
              if (!decoratedLines.has(line.number)) {
                decoratedLines.add(line.number);
                decorations.push({ pos: line.from, level: parseInt(match[1], 10) });
              }
            }
          },
        });
      }

      // Second pass: Regex fallback for headings after known comment markers
      // Matches one or more section anchors or bibliography markers followed by heading syntax.
      // Uses explicit allowlist to avoid false positives with annotation comments.
      const anchorHeadingRegex = /^(?:<!--\s*(?:@sid:[0-9a-fA-F-]+|::auto-bibliography::)\s*-->)+(#{1,6})\s/;

      for (const { from, to } of view.visibleRanges) {
        const startLine = doc.lineAt(from).number;
        const endLine = doc.lineAt(to).number;

        for (let lineNum = startLine; lineNum <= endLine; lineNum++) {
          if (decoratedLines.has(lineNum)) continue; // Already decorated by syntax tree

          const line = doc.line(lineNum);
          const match = line.text.match(anchorHeadingRegex);
          if (match) {
            decoratedLines.add(lineNum);
            decorations.push({ pos: line.from, level: match[1].length });
          }
        }
      }

      // Sort by position (RangeSetBuilder requires sorted order)
      decorations.sort((a, b) => a.pos - b.pos);

      const builder = new RangeSetBuilder<Decoration>();
      for (const { pos, level } of decorations) {
        builder.add(pos, pos, Decoration.line({ class: `cm-heading-${level}-line` }));
      }

      return builder.finish();
    }
  },
  {
    decorations: (v) => v.decorations,
  }
);

// Re-export syntaxHighlighting for use in main.ts
export { syntaxHighlighting };
