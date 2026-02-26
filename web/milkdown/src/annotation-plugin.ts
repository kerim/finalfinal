// Annotation Plugin for Milkdown
// Renders annotations as atomic inline nodes with text stored as attribute
// Click to edit via popup (annotation-edit-popup.ts)
// Serializes to <!-- ::type:: content --> HTML comments
// Types: task (☐/☑), comment (◇), reference (▤)

import type { Ctx, MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node } from '@milkdown/kit/prose/model';
import { $node, $remark, $view } from '@milkdown/kit/utils';
import type { Root } from 'mdast';
import { visit } from 'unist-util-visit';
import { showAnnotationEditPopup } from './annotation-edit-popup';
import { isSourceModeEnabled } from './source-mode-plugin';

// Annotation type definitions
export type AnnotationType = 'task' | 'comment' | 'reference';

export interface AnnotationAttrs {
  type: AnnotationType;
  isCompleted: boolean;
  text: string;
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
// Note: (.*?) allows empty content for newly created annotations
const annotationRegex = /^<!--\s*::(\w+)::\s*(.*?)\s*-->$/s;
const taskCheckboxRegex = /^\s*\[([ xX])\]\s*(.*)$/s;

// Remark plugin to convert HTML comments to annotation nodes
const remarkAnnotationPlugin = $remark('annotation', () => () => (tree: Root) => {
  // Track nodes that need to be wrapped in paragraphs (can't mutate during visit)
  const nodesToWrap: Array<{ parent: any; index: number }> = [];

  visit(tree, 'html', (node: any, index: number | undefined, parent: any) => {
    const value = node.value?.trim();
    if (!value) return;

    // Normalize Unicode whitespace and invisible characters
    const normalizedValue = value
      .replace(/\u00A0/g, ' ') // Non-breaking space → regular space
      .replace(/[\u200B-\u200D\uFEFF]/g, '') // Zero-width spaces
      .replace(/\u2003/g, ' ') // Em space
      .replace(/\u2002/g, ' ') // En space
      .replace(/\r\n/g, '\n') // Windows line endings
      .replace(/\r/g, '\n') // Old Mac line endings
      .trim();

    const match = normalizedValue.match(annotationRegex);
    if (!match) {
      return;
    }

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

    // Transform to annotation node with text stored in data (for atom node)
    node.type = 'annotation';
    node.data = {
      annotationType: type,
      isCompleted,
      text: text.trim(),
    };
    // No children for atomic node
    node.children = [];
    delete node.value;

    // If annotation is a direct child of root (block-level), mark it for wrapping
    // Inline nodes can't be direct children of doc in ProseMirror
    if (parent && parent.type === 'root' && typeof index === 'number') {
      nodesToWrap.push({ parent, index });
    }
  });

  // Wrap standalone annotations in paragraphs (process in reverse to preserve indices)
  for (let i = nodesToWrap.length - 1; i >= 0; i--) {
    const { parent, index } = nodesToWrap[i];
    const annotationNode = parent.children[index];
    // Wrap the annotation in a paragraph
    parent.children[index] = {
      type: 'paragraph',
      children: [annotationNode],
    };
  }
});

// Define the annotation node as atomic (non-editable, text stored in attrs)
const annotationNode = $node('annotation', () => ({
  group: 'inline',
  inline: true,
  atom: true,
  selectable: true,
  draggable: false,

  attrs: {
    type: { default: 'comment' },
    isCompleted: { default: false },
    text: { default: '' },
  },

  parseDOM: [
    {
      tag: 'span.ff-annotation',
      getAttrs: (dom: HTMLElement) => ({
        type: dom.dataset.type || 'comment',
        isCompleted: dom.dataset.completed === 'true',
        text: dom.dataset.text || '',
      }),
    },
  ],

  toDOM: (node: Node) => {
    const { type, isCompleted, text } = node.attrs as AnnotationAttrs;
    let marker = annotationMarkers[type];

    if (type === 'task' && isCompleted) {
      marker = completedTaskMarker;
    }

    const classes = ['ff-annotation', `ff-annotation-${type}`, isCompleted ? 'ff-annotation-completed' : '']
      .filter(Boolean)
      .join(' ');

    // Atomic structure: marker + static text span (no content hole)
    return [
      'span',
      {
        class: classes,
        'data-type': type,
        'data-text': text,
        'data-completed': String(isCompleted),
        title: text,
      },
      // Marker span (non-editable)
      ['span', { class: 'ff-annotation-marker', contenteditable: 'false' }, marker],
      // Text span (static display, not editable inline)
      ['span', { class: 'ff-annotation-text' }, text || ''],
    ];
  },

  parseMarkdown: {
    match: (node: any) => node.type === 'annotation',
    runner: (state: any, node: any, type: any) => {
      // Add as atom node with text in attrs
      state.addNode(type, {
        type: node.data.annotationType,
        isCompleted: node.data.isCompleted,
        text: node.data.text || '',
      });
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'annotation',
    runner: (state: any, node: Node) => {
      const { type, isCompleted, text: rawText } = node.attrs as AnnotationAttrs;
      // Sanitize newlines in text attribute
      const text = (rawText || '')
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

// NodeView for atomic annotation rendering with click-to-edit popup
const annotationNodeView = $view(annotationNode, (_ctx: Ctx) => {
  return (node, view, getPos) => {
    const attrs = node.attrs as AnnotationAttrs;

    // Track source mode at NodeView creation time
    const createdInSourceMode = isSourceModeEnabled();

    // Create the wrapper span
    const dom = document.createElement('span');
    dom.className = ['ff-annotation', `ff-annotation-${attrs.type}`, attrs.isCompleted ? 'ff-annotation-completed' : '']
      .filter(Boolean)
      .join(' ');
    dom.dataset.type = attrs.type;
    dom.dataset.completed = String(attrs.isCompleted);
    dom.dataset.text = attrs.text || '';
    dom.title = attrs.text || '';

    // Create the marker span (non-editable)
    const markerSpan = document.createElement('span');
    markerSpan.className = 'ff-annotation-marker';
    markerSpan.contentEditable = 'false';
    let marker = annotationMarkers[attrs.type];
    if (attrs.type === 'task' && attrs.isCompleted) {
      marker = completedTaskMarker;
    }
    markerSpan.textContent = marker;

    // Handle marker click for task completion toggle
    if (attrs.type === 'task') {
      markerSpan.style.cursor = 'pointer';
      markerSpan.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const pos = typeof getPos === 'function' ? getPos() : null;
        if (pos !== null && pos !== undefined) {
          const currentNode = view.state.doc.nodeAt(pos);
          if (currentNode && currentNode.type.name === 'annotation') {
            const currentCompleted = currentNode.attrs.isCompleted;
            const tr = view.state.tr.setNodeMarkup(pos, undefined, {
              ...currentNode.attrs,
              isCompleted: !currentCompleted,
            });
            view.dispatch(tr);
          }
        }
      });
    }

    // Create the text span (non-editable display)
    const textSpan = document.createElement('span');
    textSpan.className = 'ff-annotation-text';
    textSpan.textContent = attrs.text || '';

    // Click handler to open edit popup (skip if click was on marker for task toggle)
    dom.addEventListener('click', (e) => {
      // Don't open popup if marker was clicked (task toggle handles it)
      if (markerSpan.contains(e.target as HTMLElement)) return;
      // Don't open popup in source mode
      if (isSourceModeEnabled()) return;

      const pos = typeof getPos === 'function' ? getPos() : null;
      if (pos !== null && pos !== undefined) {
        const currentNode = view.state.doc.nodeAt(pos);
        if (currentNode && currentNode.type.name === 'annotation') {
          showAnnotationEditPopup(pos, view, currentNode.attrs as AnnotationAttrs);
        }
      }
    });

    // Source mode rendering helper
    const renderSourceMode = (a: AnnotationAttrs) => {
      const checkbox = a.type === 'task' ? (a.isCompleted ? '[x] ' : '[ ] ') : '';
      while (dom.firstChild) dom.removeChild(dom.firstChild);
      dom.textContent = `<!-- ::${a.type}:: ${checkbox}${a.text || ''} -->`;
      dom.classList.add('source-mode-annotation');
    };

    // Initial render
    if (createdInSourceMode) {
      renderSourceMode(attrs);
    } else {
      dom.appendChild(markerSpan);
      dom.appendChild(textSpan);
    }

    return {
      dom,
      update: (updatedNode) => {
        if (updatedNode.type.name !== 'annotation') {
          return false;
        }

        // Force recreation if source mode changed
        if (isSourceModeEnabled() !== createdInSourceMode) {
          return false;
        }

        const newAttrs = updatedNode.attrs as AnnotationAttrs;

        // Update wrapper attributes
        dom.dataset.type = newAttrs.type;
        dom.dataset.completed = String(newAttrs.isCompleted);
        dom.dataset.text = newAttrs.text || '';
        dom.title = newAttrs.text || '';
        dom.className = [
          'ff-annotation',
          `ff-annotation-${newAttrs.type}`,
          newAttrs.isCompleted ? 'ff-annotation-completed' : '',
        ]
          .filter(Boolean)
          .join(' ');

        if (isSourceModeEnabled()) {
          renderSourceMode(newAttrs);
        } else {
          // Update marker
          let newMarker = annotationMarkers[newAttrs.type];
          if (newAttrs.type === 'task' && newAttrs.isCompleted) {
            newMarker = completedTaskMarker;
          }
          markerSpan.textContent = newMarker;
          // Update text display
          textSpan.textContent = newAttrs.text || '';
        }

        return true;
      },
      ignoreMutation: () => true, // Atom node - ignore all mutations
    };
  };
});

// Export the plugin array
export const annotationPlugin: MilkdownPlugin[] = [remarkAnnotationPlugin, annotationNode, annotationNodeView].flat();

// Export node and helper for use in slash commands
export { annotationNode };

// Helper to create annotation markdown
export function createAnnotationMarkdown(type: AnnotationType, text: string = ''): string {
  if (type === 'task') {
    return `<!-- ::task:: [ ] ${text} -->`;
  }
  return `<!-- ::${type}:: ${text} -->`;
}
