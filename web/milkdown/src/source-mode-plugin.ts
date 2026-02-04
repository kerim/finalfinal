// Source Mode Plugin for dual-appearance editing
// Uses ProseMirror decorations to show markdown syntax characters
// When enabled, the editor appears as a source/code view while maintaining the same document structure

import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { Node } from '@milkdown/kit/prose/model';
import { $prose } from '@milkdown/kit/utils';

export const sourceModePluginKey = new PluginKey('source-mode');

let sourceModeEnabled = false;

/**
 * Enable or disable source mode
 */
export function setSourceModeEnabled(enabled: boolean): void {
  sourceModeEnabled = enabled;
  // Update body class for CSS styling
  document.body.classList.toggle('source-mode', enabled);
}

/**
 * Check if source mode is currently enabled
 */
export function isSourceModeEnabled(): boolean {
  return sourceModeEnabled;
}

/**
 * Get the markdown syntax prefix for a heading level
 */
function getHeadingPrefix(level: number): string {
  return '#'.repeat(level) + ' ';
}

/**
 * Get the markdown syntax for a mark type
 */
function getMarkSyntax(markType: string, isStart: boolean, href?: string): string | null {
  switch (markType) {
    case 'strong':
      return '**';
    case 'emphasis':
    case 'em':
      return '*';
    case 'code_inline':
    case 'inlineCode':
      return '`';
    case 'strikethrough':
      return '~~';
    case 'link':
      return isStart ? '[' : `](${href || ''})`;
    default:
      return null;
  }
}

/**
 * Get the CSS class name for a mark type
 */
function getMarkClass(markType: string): string {
  switch (markType) {
    case 'strong':
      return 'bold';
    case 'emphasis':
    case 'em':
      return 'italic';
    case 'code_inline':
    case 'inlineCode':
      return 'code';
    case 'strikethrough':
      return 'strike';
    case 'link':
      return 'link';
    default:
      return 'unknown';
  }
}

/**
 * Create decorations for showing markdown syntax in source mode
 */
function createSourceModeDecorations(doc: Node): Decoration[] {
  const decorations: Decoration[] = [];

  doc.descendants((node, pos) => {
    // Add heading # markers
    if (node.type.name === 'heading') {
      const level = node.attrs.level as number;
      const prefix = getHeadingPrefix(level);

      // Add widget decoration before heading content
      decorations.push(
        Decoration.widget(pos + 1, () => {
          const span = document.createElement('span');
          span.className = 'source-mode-syntax source-mode-heading-marker';
          span.textContent = prefix;
          return span;
        }, { side: -1 })
      );
    }

    // Add blockquote > markers
    if (node.type.name === 'blockquote') {
      // Add > at start of blockquote
      decorations.push(
        Decoration.widget(pos + 1, () => {
          const span = document.createElement('span');
          span.className = 'source-mode-syntax source-mode-blockquote-marker';
          span.textContent = '> ';
          return span;
        }, { side: -1 })
      );
    }

    // Add bullet list markers
    if (node.type.name === 'bullet_list') {
      // Walk children to add - markers
      node.forEach((child, offset) => {
        if (child.type.name === 'list_item') {
          decorations.push(
            Decoration.widget(pos + 1 + offset + 1, () => {
              const span = document.createElement('span');
              span.className = 'source-mode-syntax source-mode-list-marker';
              span.textContent = '- ';
              return span;
            }, { side: -1 })
          );
        }
      });
    }

    // Add ordered list markers
    if (node.type.name === 'ordered_list') {
      let number = (node.attrs.order as number) || 1;
      node.forEach((child, offset) => {
        if (child.type.name === 'list_item') {
          decorations.push(
            Decoration.widget(pos + 1 + offset + 1, () => {
              const span = document.createElement('span');
              span.className = 'source-mode-syntax source-mode-list-marker';
              span.textContent = `${number}. `;
              return span;
            }, { side: -1 })
          );
          number++;
        }
      });
    }

    // Add code block fence markers
    if (node.type.name === 'code_block') {
      const language = (node.attrs.language as string) || '';

      // Opening fence
      decorations.push(
        Decoration.widget(pos, () => {
          const div = document.createElement('div');
          div.className = 'source-mode-syntax source-mode-code-fence';
          div.textContent = '```' + language;
          return div;
        }, { side: -1 })
      );

      // Closing fence
      decorations.push(
        Decoration.widget(pos + node.nodeSize, () => {
          const div = document.createElement('div');
          div.className = 'source-mode-syntax source-mode-code-fence';
          div.textContent = '```';
          return div;
        }, { side: 1 })
      );
    }

    // Add horizontal rule markers
    if (node.type.name === 'horizontal_rule' || node.type.name === 'hr') {
      decorations.push(
        Decoration.node(pos, pos + node.nodeSize, {
          class: 'source-mode-hr',
          'data-syntax': '---',
        })
      );
    }

    return true;
  });

  // Handle inline marks - add decorations around bold, italic, code spans
  // Track mark boundaries to handle nested marks correctly
  // For nested marks like ***bold italic***, we need to add markers in the right order
  interface MarkBoundary {
    pos: number;
    isStart: boolean;
    markType: string;
    priority: number; // Higher priority = closer to text
    href?: string; // For links
  }

  const markBoundaries: MarkBoundary[] = [];

  // Priority order (lower = further from text): link < strikethrough < strong < emphasis < code
  const markPriority: Record<string, number> = {
    'link': 0,
    'strikethrough': 1,
    'strong': 2,
    'emphasis': 3,
    'em': 3,
    'code_inline': 4,
    'inlineCode': 4,
  };

  doc.descendants((node, pos) => {
    if (node.isText && node.marks.length > 0) {
      const from = pos;
      const to = pos + node.nodeSize;

      for (const mark of node.marks) {
        const priority = markPriority[mark.type.name] ?? 5;
        markBoundaries.push({
          pos: from,
          isStart: true,
          markType: mark.type.name,
          priority,
          href: mark.type.name === 'link' ? (mark.attrs.href as string || '') : undefined,
        });
        markBoundaries.push({
          pos: to,
          isStart: false,
          markType: mark.type.name,
          priority,
          href: mark.type.name === 'link' ? (mark.attrs.href as string || '') : undefined,
        });
      }
    }
    return true;
  });

  // Group boundaries by position
  const boundariesByPos = new Map<number, MarkBoundary[]>();
  for (const boundary of markBoundaries) {
    const existing = boundariesByPos.get(boundary.pos) || [];
    existing.push(boundary);
    boundariesByPos.set(boundary.pos, existing);
  }

  // Process each position's boundaries
  for (const [pos, boundaries] of boundariesByPos) {
    // Sort: starts before ends, and by priority (lower priority = further from text)
    // At start: lower priority first (outer marks first)
    // At end: higher priority first (inner marks first)
    const starts = boundaries.filter(b => b.isStart).sort((a, b) => a.priority - b.priority);
    const ends = boundaries.filter(b => !b.isStart).sort((a, b) => b.priority - a.priority);

    // Add start markers (outer to inner)
    for (const boundary of starts) {
      const syntax = getMarkSyntax(boundary.markType, true, boundary.href);
      if (syntax) {
        decorations.push(
          Decoration.widget(pos, () => {
            const span = document.createElement('span');
            span.className = `source-mode-syntax source-mode-${getMarkClass(boundary.markType)}-marker`;
            span.textContent = syntax;
            return span;
          }, { side: -1 })
        );
      }
    }

    // Add end markers (inner to outer)
    for (const boundary of ends) {
      const syntax = getMarkSyntax(boundary.markType, false, boundary.href);
      if (syntax) {
        decorations.push(
          Decoration.widget(pos, () => {
            const span = document.createElement('span');
            span.className = `source-mode-syntax source-mode-${getMarkClass(boundary.markType)}-marker`;
            span.textContent = syntax;
            return span;
          }, { side: 1 })
        );
      }
    }
  }

  return decorations;
}

// Wrap ProseMirror plugin with $prose for Milkdown compatibility
export const sourceModePlugin = $prose(() => {
  return new Plugin({
    key: sourceModePluginKey,
    props: {
      decorations(state) {
        if (!sourceModeEnabled) {
          return DecorationSet.empty;
        }

        const decorations = createSourceModeDecorations(state.doc);
        return DecorationSet.create(state.doc, decorations);
      },
    },
  });
});
