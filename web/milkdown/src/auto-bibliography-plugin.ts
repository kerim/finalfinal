// Auto-Bibliography Marker Plugin for Milkdown
// Renders as invisible markers in editor, serializes to HTML comments in markdown
// Pattern follows sectionBreakPlugin exactly

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node } from '@milkdown/kit/prose/model';
import { $node, $remark } from '@milkdown/kit/utils';
import type { Root } from 'mdast';
import { visit } from 'unist-util-visit';

// Remark plugin to convert HTML comments to custom nodes
// Runs during initial parse phase, before HTML filtering
const remarkPlugin = $remark('auto-bibliography', () => () => (tree: Root) => {
  visit(tree, 'html', (node: any) => {
    const value = node.value?.trim();
    if (value === '<!-- ::auto-bibliography:: -->') {
      node.type = 'autoBibliographyStart';
      delete node.value;
    } else if (value === '<!-- ::end-auto-bibliography:: -->') {
      node.type = 'autoBibliographyEnd';
      delete node.value;
    }
  });
});

// Start marker node (invisible)
const autoBibStartNode = $node('auto_bibliography_start', () => ({
  group: 'block',
  atom: true,
  selectable: false,
  draggable: false,

  parseDOM: [{ tag: 'span.auto-bib-start' }],

  toDOM: (_node: Node) => ['span', { class: 'auto-bib-start', contenteditable: 'false' }],

  parseMarkdown: {
    match: (node: any) => node.type === 'autoBibliographyStart',
    runner: (state: any, _node: any, type: any) => {
      state.addNode(type);
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'auto_bibliography_start',
    runner: (state: any, _node: Node) => {
      state.addNode('html', undefined, '<!-- ::auto-bibliography:: -->');
    },
  },
}));

// End marker node (invisible)
const autoBibEndNode = $node('auto_bibliography_end', () => ({
  group: 'block',
  atom: true,
  selectable: false,
  draggable: false,

  parseDOM: [{ tag: 'span.auto-bib-end' }],

  toDOM: (_node: Node) => ['span', { class: 'auto-bib-end', contenteditable: 'false' }],

  parseMarkdown: {
    match: (node: any) => node.type === 'autoBibliographyEnd',
    runner: (state: any, _node: any, type: any) => {
      state.addNode(type);
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'auto_bibliography_end',
    runner: (state: any, _node: Node) => {
      state.addNode('html', undefined, '<!-- ::end-auto-bibliography:: -->');
    },
  },
}));

export const autoBibliographyPlugin: MilkdownPlugin[] = [remarkPlugin, autoBibStartNode, autoBibEndNode].flat();
