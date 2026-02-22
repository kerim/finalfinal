// Zoom Notes Marker Plugin for Milkdown
// Renders invisibly in editor, serializes to <!-- ::zoom-notes:: --> in markdown
// This preserves the marker through editor round-trips for stripZoomNotes()

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node } from '@milkdown/kit/prose/model';
import { $node, $remark } from '@milkdown/kit/utils';
import type { Root } from 'mdast';
import { visit } from 'unist-util-visit';

// Remark plugin to convert HTML comments to zoom_notes_marker nodes
// Runs during initial parse phase, before HTML filtering strips them
const remarkPlugin = $remark('zoom-notes-marker', () => () => (tree: Root) => {
  visit(tree, 'html', (node: any) => {
    if (node.value?.trim() === '<!-- ::zoom-notes:: -->') {
      node.type = 'zoomNotesMarker';
      delete node.value;
    }
  });
});

// Define the zoom_notes_marker node — invisible, non-interactive
const zoomNotesMarkerNode = $node('zoom_notes_marker', () => ({
  group: 'block',
  atom: true,
  selectable: false,

  parseDOM: [{ tag: 'div.zoom-notes-marker' }],

  toDOM: () =>
    [
      'div',
      {
        class: 'zoom-notes-marker',
        style: 'display:none',
        contenteditable: 'false',
      },
      '',
    ] as const,

  parseMarkdown: {
    match: (node: any) => node.type === 'zoomNotesMarker',
    runner: (state: any, _node: any, type: any) => {
      state.addNode(type);
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'zoom_notes_marker',
    runner: (state: any) => {
      state.addNode('html', undefined, '<!-- ::zoom-notes:: -->');
    },
  },
}));

export const zoomNotesMarkerPlugin: MilkdownPlugin[] = [remarkPlugin, zoomNotesMarkerNode].flat();
