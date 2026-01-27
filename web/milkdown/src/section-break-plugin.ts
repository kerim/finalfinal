// Section Break Plugin for Milkdown
// Renders as § in editor, serializes to <!-- ::break:: --> in markdown

import { MilkdownPlugin } from '@milkdown/kit/ctx';
import { Node } from '@milkdown/kit/prose/model';
import { $node, $remark } from '@milkdown/kit/utils';
import { visit } from 'unist-util-visit';
import type { Root } from 'mdast';

// Remark plugin to convert HTML comments to section_break nodes
// Uses unist-util-visit for proper tree traversal
// This runs during the initial parse phase, before HTML filtering
const remarkPlugin = $remark('section-break', () => () => (tree: Root) => {
  visit(tree, 'html', (node: any) => {
    if (node.value?.trim() === '<!-- ::break:: -->') {
      // Transform in place to custom node type before filtering runs
      node.type = 'sectionBreak';
      delete node.value;
    }
  });
});

// Define the section_break node
const sectionBreakNode = $node('section_break', () => ({
  group: 'block',
  atom: true,
  selectable: true,
  draggable: false,

  parseDOM: [
    {
      tag: 'div.section-break',
    },
  ],

  toDOM: (_node: Node) => [
    'div',
    { class: 'section-break', contenteditable: 'false' },
    '\u00A7', // § character
  ],

  parseMarkdown: {
    match: (node: any) => node.type === 'sectionBreak',
    runner: (state: any, _node: any, type: any) => {
      state.addNode(type);
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'section_break',
    runner: (state: any, _node: Node) => {
      // Output as HTML comment
      state.addNode('html', undefined, '<!-- ::break:: -->');
    },
  },
}));

// Export the plugin array
export const sectionBreakPlugin: MilkdownPlugin[] = [
  remarkPlugin,
  sectionBreakNode,
].flat();

// Export the node for use in slash commands
export { sectionBreakNode };
