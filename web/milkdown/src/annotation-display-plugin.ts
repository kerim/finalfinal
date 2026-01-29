// Annotation Display Plugin for Milkdown
// Controls annotation visibility based on display mode (inline, collapsed)
// Global "panel only" mode hides all annotations
// Uses ProseMirror decorations - NOT DOM manipulation

import { $prose } from '@milkdown/kit/utils';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { AnnotationType } from './annotation-plugin';

export type AnnotationDisplayMode = 'inline' | 'collapsed';

export const annotationDisplayPluginKey = new PluginKey('annotation-display');

// Current display modes per type
let displayModes: Record<AnnotationType, AnnotationDisplayMode> = {
  task: 'inline',
  comment: 'collapsed',
  reference: 'collapsed',
};

// Global "panel only" mode - hides all annotations from editor
let isPanelOnlyMode = false;

// Set display modes from Swift
// modes object may include special key '__panelOnly' for global toggle
export function setAnnotationDisplayModes(modes: Record<string, string>) {
  const validTypes = ['task', 'comment', 'reference'];
  const validModes = ['inline', 'collapsed'];

  // Handle global panel-only mode
  if ('__panelOnly' in modes) {
    isPanelOnlyMode = modes['__panelOnly'] === 'true';
  }

  for (const [type, mode] of Object.entries(modes)) {
    if (type === '__panelOnly') continue; // Skip special key
    if (validTypes.includes(type) && validModes.includes(mode)) {
      displayModes[type as AnnotationType] = mode as AnnotationDisplayMode;
    }
  }
}

// Get current display modes
export function getAnnotationDisplayModes(): Record<AnnotationType, AnnotationDisplayMode> {
  return { ...displayModes };
}

// Get panel-only mode state
export function isPanelOnly(): boolean {
  return isPanelOnlyMode;
}

// Wrap ProseMirror plugin with $prose for Milkdown compatibility
export const annotationDisplayPlugin = $prose(() => {
  return new Plugin({
    key: annotationDisplayPluginKey,
    props: {
      decorations(state) {
        const decorations: Decoration[] = [];
        const { doc } = state;

        // Find all annotation nodes and apply display mode decorations
        doc.descendants((node, pos) => {
          if (node.type.name === 'annotation') {
            const type = node.attrs.type as AnnotationType;
            const mode = displayModes[type];

            if (isPanelOnlyMode) {
              // Global panel-only mode - hide ALL annotations
              decorations.push(
                Decoration.node(pos, pos + node.nodeSize, {
                  class: 'ff-annotation-hidden',
                })
              );
            } else if (mode === 'collapsed') {
              // Show only the marker, hide text
              decorations.push(
                Decoration.node(pos, pos + node.nodeSize, {
                  class: 'ff-annotation-collapsed',
                })
              );
            }
            // 'inline' mode shows everything - no decoration needed
          }

          return true;
        });

        return DecorationSet.create(doc, decorations);
      },
    },
  });
});
