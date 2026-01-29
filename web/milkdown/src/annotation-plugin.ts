// Annotation Plugin for Milkdown
// Renders annotations as inline markers with editable text content
// Uses Hybrid pattern: marker (non-editable) + text (ProseMirror-managed)
// Serializes to <!-- ::type:: content --> HTML comments
// Types: task (☐/☑), comment (◇), reference (▤)

import { MilkdownPlugin, Ctx } from '@milkdown/kit/ctx';
import { Node } from '@milkdown/kit/prose/model';
import { $node, $remark, $view } from '@milkdown/kit/utils';
import { visit } from 'unist-util-visit';
import type { Root } from 'mdast';

// Annotation type definitions
export type AnnotationType = 'task' | 'comment' | 'reference';

export interface AnnotationAttrs {
  type: AnnotationType;
  isCompleted: boolean;
}

// Marker symbols for display
export const annotationMarkers: Record<AnnotationType, string> = {
  task: '☐',
  comment: '◇',
  reference: '▤',
};

export const completedTaskMarker = '☑';

// Regex to parse annotation HTML comments: <!-- ::type:: content -->
// For tasks: <!-- ::task:: [ ] text --> or <!-- ::task:: [x] text -->
const annotationRegex = /^<!--\s*::(\w+)::\s*(.+?)\s*-->$/s;
const taskCheckboxRegex = /^\s*\[([ xX])\]\s*(.*)$/s;

// Remark plugin to convert HTML comments to annotation nodes
const remarkAnnotationPlugin = $remark('annotation', () => () => (tree: Root) => {
  visit(tree, 'html', (node: any) => {
    const value = node.value?.trim();
    if (!value) return;

    const match = value.match(annotationRegex);
    if (!match) return;

    const [, typeStr, content] = match;

    // Validate type before type assertion
    if (!['task', 'comment', 'reference'].includes(typeStr)) return;
    const type = typeStr as AnnotationType;

    let text = content;
    let isCompleted = false;

    // Parse task checkbox
    if (type === 'task') {
      const checkboxMatch = content.match(taskCheckboxRegex);
      if (checkboxMatch) {
        isCompleted = checkboxMatch[1].toLowerCase() === 'x';
        text = checkboxMatch[2];
      }
    }

    // Transform to annotation node with text as child
    node.type = 'annotation';
    node.data = {
      annotationType: type,
      isCompleted,
    };
    // Store text as children for the parser
    node.children = [{ type: 'text', value: text.trim() }];
    delete node.value;
  });
});

// Define the annotation node with editable content
const annotationNode = $node('annotation', () => ({
  group: 'inline',
  inline: true,
  // Remove atom: true to allow text content
  content: 'text*',  // Allow text children for editable content
  selectable: true,
  draggable: false,

  attrs: {
    type: { default: 'comment' },
    isCompleted: { default: false },
  },

  parseDOM: [
    {
      tag: 'span.ff-annotation',
      getAttrs: (dom: HTMLElement) => ({
        type: dom.dataset.type || 'comment',
        isCompleted: dom.dataset.completed === 'true',
      }),
      // Content is parsed from the .ff-annotation-text child
      contentElement: '.ff-annotation-text',
    },
  ],

  toDOM: (node: Node) => {
    const { type, isCompleted } = node.attrs as AnnotationAttrs;
    let marker = annotationMarkers[type];

    if (type === 'task' && isCompleted) {
      marker = completedTaskMarker;
    }

    const classes = [
      'ff-annotation',
      `ff-annotation-${type}`,
      isCompleted ? 'ff-annotation-completed' : '',
    ].filter(Boolean).join(' ');

    // Get text content for data-text attribute (for tooltips and display modes)
    const textContent = node.textContent || '';

    // Hybrid structure: marker (non-editable) + text container (editable)
    return [
      'span',
      {
        class: classes,
        'data-type': type,
        'data-text': textContent,
        'data-completed': String(isCompleted),
        title: textContent,
      },
      // Marker span (non-editable)
      ['span', { class: 'ff-annotation-marker', contenteditable: 'false' }, marker],
      // Text span (editable, contains ProseMirror content)
      ['span', { class: 'ff-annotation-text' }, 0],  // 0 = contentDOM hole
    ];
  },

  parseMarkdown: {
    match: (node: any) => node.type === 'annotation',
    runner: (state: any, node: any, type: any) => {
      // Open the annotation node
      state.openNode(type, {
        type: node.data.annotationType,
        isCompleted: node.data.isCompleted,
      });
      // Add text content as children
      if (node.children && node.children.length > 0) {
        state.next(node.children);
      }
      // Close the annotation node
      state.closeNode();
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'annotation',
    runner: (state: any, node: Node) => {
      const { type, isCompleted } = node.attrs as AnnotationAttrs;
      // Extract text from child nodes and sanitize newlines
      // Replace all line endings (Windows \r\n, Unix \n, old Mac \r) with spaces
      // Then normalize multiple consecutive spaces to single space
      const text = (node.textContent || '')
        .replace(/[\r\n]+/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();

      let content: string;
      if (type === 'task') {
        const checkbox = isCompleted ? '[x]' : '[ ]';
        content = `<!-- ::task:: ${checkbox} ${text} -->`;
      } else {
        content = `<!-- ::${type}:: ${text} -->`;
      }

      state.addNode('html', undefined, content);
    },
  },
}));

// NodeView for custom rendering with non-editable marker
// This allows the marker to be completely non-editable while text is editable
const annotationNodeView = $view(annotationNode, () => (ctx: Ctx) => {
  return (node, view, getPos) => {
    const { type, isCompleted } = node.attrs as AnnotationAttrs;

    // Create the wrapper span
    const dom = document.createElement('span');
    dom.className = [
      'ff-annotation',
      `ff-annotation-${type}`,
      isCompleted ? 'ff-annotation-completed' : '',
    ].filter(Boolean).join(' ');
    dom.dataset.type = type;
    dom.dataset.completed = String(isCompleted);

    // Create the marker span (non-editable)
    const markerSpan = document.createElement('span');
    markerSpan.className = 'ff-annotation-marker';
    markerSpan.contentEditable = 'false';
    let marker = annotationMarkers[type];
    if (type === 'task' && isCompleted) {
      marker = completedTaskMarker;
    }
    markerSpan.textContent = marker;

    // Handle marker click for task completion toggle
    if (type === 'task') {
      markerSpan.style.cursor = 'pointer';
      markerSpan.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const pos = typeof getPos === 'function' ? getPos() : null;
        if (pos !== null && pos !== undefined) {
          const tr = view.state.tr.setNodeMarkup(pos, undefined, {
            ...node.attrs,
            isCompleted: !isCompleted,
          });
          view.dispatch(tr);
        }
      });
    }

    // Create the text span (editable - contentDOM)
    const contentDOM = document.createElement('span');
    contentDOM.className = 'ff-annotation-text';

    dom.appendChild(markerSpan);
    dom.appendChild(contentDOM);

    // Update tooltip when text changes
    const updateTooltip = () => {
      const text = contentDOM.textContent || '';
      dom.dataset.text = text;
      dom.title = text;
    };

    return {
      dom,
      contentDOM,
      update: (updatedNode) => {
        if (updatedNode.type.name !== 'annotation') return false;

        // Update attributes
        const newAttrs = updatedNode.attrs as AnnotationAttrs;
        dom.dataset.type = newAttrs.type;
        dom.dataset.completed = String(newAttrs.isCompleted);
        dom.className = [
          'ff-annotation',
          `ff-annotation-${newAttrs.type}`,
          newAttrs.isCompleted ? 'ff-annotation-completed' : '',
        ].filter(Boolean).join(' ');

        // Update marker
        let newMarker = annotationMarkers[newAttrs.type];
        if (newAttrs.type === 'task' && newAttrs.isCompleted) {
          newMarker = completedTaskMarker;
        }
        markerSpan.textContent = newMarker;

        // Update tooltip
        updateTooltip();

        return true;
      },
      destroy: () => {
        // Cleanup if needed
      },
    };
  };
});

// Export the plugin array
export const annotationPlugin: MilkdownPlugin[] = [
  remarkAnnotationPlugin,
  annotationNode,
  annotationNodeView,
].flat();

// Export node and helper for use in slash commands
export { annotationNode };

// Helper to create annotation markdown
export function createAnnotationMarkdown(type: AnnotationType, text: string = ''): string {
  if (type === 'task') {
    return `<!-- ::task:: [ ] ${text} -->`;
  }
  return `<!-- ::${type}:: ${text} -->`;
}
