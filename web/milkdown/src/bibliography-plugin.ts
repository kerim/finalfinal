// Bibliography Plugin for Milkdown
// Hides <!-- ::auto-bibliography:: --> comments in the editor
// Follows the same pattern as section-break-plugin.ts

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node } from '@milkdown/kit/prose/model';
import { $node, $remark } from '@milkdown/kit/utils';
import type { Root } from 'mdast';
import { visit } from 'unist-util-visit';

// Remark plugin to convert auto-bibliography HTML comments to custom nodes
// Runs during initial parse phase, before HTML filtering strips them
const remarkPlugin = $remark('bibliography', () => () => (tree: Root) => {
  visit(tree, 'html', (node: any) => {
    const trimmed = node.value?.trim() ?? '';
    if (trimmed.startsWith('<!-- ::auto-bibliography:: -->')) {
      // Handle marker concatenated with following content (e.g. marker + "# Bibliography")
      const remainder = trimmed.slice('<!-- ::auto-bibliography:: -->'.length).trim();
      if (remainder) {
        // Keep the remainder as raw HTML content (will be re-parsed on next cycle)
        node.value = remainder;
      } else {
        node.type = 'autoBibliography';
        delete node.value;
      }
    }
  });
});

// Define the auto_bibliography node — invisible in editor, preserved in markdown
const autoBibliographyNode = $node('auto_bibliography', () => ({
  group: 'block',
  atom: true,
  selectable: false,
  draggable: false,

  parseDOM: [
    {
      tag: 'div.auto-bib-marker',
    },
  ],

  toDOM: (_node: Node) => ['div', { class: 'auto-bib-marker' }],

  parseMarkdown: {
    match: (node: any) => node.type === 'autoBibliography',
    runner: (state: any, _node: any, type: any) => {
      state.addNode(type);
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'auto_bibliography',
    runner: (state: any, _node: Node) => {
      state.addNode('html', undefined, '<!-- ::auto-bibliography:: -->');
    },
  },
}));

export const bibliographyPlugin: MilkdownPlugin[] = [remarkPlugin, autoBibliographyNode].flat();
