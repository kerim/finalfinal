// Highlight Plugin for Milkdown
// Renders ==text== as highlighted text marks

import { MilkdownPlugin } from '@milkdown/kit/ctx';
import { $mark, $remark } from '@milkdown/kit/utils';
import { visit } from 'unist-util-visit';
import type { Root, Text } from 'mdast';

// Remark plugin to parse ==highlight== in text nodes
const remarkHighlightPlugin = $remark('highlight', () => () => (tree: Root) => {
  visit(tree, 'text', (node: Text, index: number | undefined, parent: any) => {
    if (!parent || index === undefined) return;

    const value = node.value;

    // Use matchAll to avoid global regex state issues
    const matches = [...value.matchAll(/==([^=]+)==/g)].map(m => ({
      start: m.index!,
      end: m.index! + m[0].length,
      text: m[1],
    }));

    if (matches.length === 0) return;

    // Split the text node into parts
    const newNodes: any[] = [];
    let lastEnd = 0;

    for (const m of matches) {
      // Text before the highlight
      if (m.start > lastEnd) {
        newNodes.push({
          type: 'text',
          value: value.slice(lastEnd, m.start),
        });
      }

      // The highlighted text
      newNodes.push({
        type: 'highlight',
        children: [{ type: 'text', value: m.text }],
      });

      lastEnd = m.end;
    }

    // Remaining text after last highlight
    if (lastEnd < value.length) {
      newNodes.push({
        type: 'text',
        value: value.slice(lastEnd),
      });
    }

    // Replace the original node with the new nodes
    parent.children.splice(index, 1, ...newNodes);
  });
});

// Define the highlight mark
const highlightMark = $mark('highlight', () => ({
  parseDOM: [
    { tag: 'mark.ff-highlight' },
    { tag: 'mark', getAttrs: () => ({}) },
  ],

  toDOM: () => ['mark', { class: 'ff-highlight' }, 0],

  parseMarkdown: {
    match: (node: any) => node.type === 'highlight',
    runner: (state: any, node: any, markType: any) => {
      state.openMark(markType);
      state.next(node.children);
      state.closeMark(markType);
    },
  },

  toMarkdown: {
    match: (mark: any) => mark.type.name === 'highlight',
    runner: (state: any, mark: any) => {
      state.withMark(mark, 'highlight', undefined, {
        open: '==',
        close: '==',
      });
    },
  },
}));

// Export the plugin array
// Note: Input rule for ==text== removed - remark plugin handles parsing from markdown
export const highlightPlugin: MilkdownPlugin[] = [
  remarkHighlightPlugin,
  highlightMark,
].flat();

// Export the mark for programmatic use
export { highlightMark };
