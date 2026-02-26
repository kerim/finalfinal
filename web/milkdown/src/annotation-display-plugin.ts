// Annotation Display Plugin for Milkdown
// Controls annotation visibility based on display mode (inline, collapsed)
// Global "panel only" mode hides all annotations
// Completed task filtering hides completed tasks when enabled
// Uses ProseMirror decorations - NOT DOM manipulation

import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import type { AnnotationType } from './annotation-plugin';

export type AnnotationDisplayMode = 'inline' | 'collapsed';

export const annotationDisplayPluginKey = new PluginKey('annotation-display');

// Current display modes per type
// NOTE: These defaults MUST match Swift's defaults in EditorViewState.swift
// Swift's onChange only fires when values change, not on initialization
const displayModes: Record<AnnotationType, AnnotationDisplayMode> = {
  task: 'inline',
  comment: 'inline',
  reference: 'inline',
};

// Global "panel only" mode - hides all annotations from editor
let isPanelOnlyMode = false;

// Hide completed tasks filter - hides completed task annotations
let hideCompletedTasks = false;

// Set display modes from Swift
// modes object may include special keys:
//   '__panelOnly' for global toggle
//   '__hideCompletedTasks' for completed task filtering
export function setAnnotationDisplayModes(modes: Record<string, string>) {
  const validTypes = ['task', 'comment', 'reference'];
  const validModes = ['inline', 'collapsed'];

  // Handle global panel-only mode
  if ('__panelOnly' in modes) {
    isPanelOnlyMode = modes.__panelOnly === 'true';
  }

  // Handle hide completed tasks filter
  if ('__hideCompletedTasks' in modes) {
    hideCompletedTasks = modes.__hideCompletedTasks === 'true';
  }

  for (const [type, mode] of Object.entries(modes)) {
    if (type.startsWith('__')) continue; // Skip special keys
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

// Get hide completed tasks state
export function isHideCompletedTasks(): boolean {
  return hideCompletedTasks;
}

// Direct setter for hide completed tasks (alternative to modes object)
export function setHideCompletedTasks(enabled: boolean) {
  hideCompletedTasks = enabled;
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
            const isCompleted = node.attrs.isCompleted === true;
            const mode = displayModes[type];
            const text = node.attrs.text || '';

            if (isPanelOnlyMode) {
              // Global panel-only mode - hide ALL annotations
              decorations.push(
                Decoration.node(pos, pos + node.nodeSize, {
                  class: 'ff-annotation-hidden',
                  'data-text': text,
                })
              );
            } else if (hideCompletedTasks && type === 'task' && isCompleted) {
              // Hide completed tasks when filter is active
              decorations.push(
                Decoration.node(pos, pos + node.nodeSize, {
                  class: 'ff-annotation-hidden',
                  'data-text': text,
                })
              );
            } else if (mode === 'collapsed') {
              // Show only the marker, hide text
              decorations.push(
                Decoration.node(pos, pos + node.nodeSize, {
                  class: 'ff-annotation-collapsed',
                  'data-text': text,
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
