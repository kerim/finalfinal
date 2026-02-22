// Selection Toolbar Plugin for Milkdown
// Shows a floating format bar when text is selected

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import { type ActiveFormats, hideToolbar, type SelectionRect, showToolbar } from '../../shared/selection-toolbar';
import { highlightMark } from './highlight-plugin';
import { isSourceModeEnabled } from './source-mode-plugin';

const selectionToolbarKey = new PluginKey('selection-toolbar');

function getActiveFormats(view: EditorView): ActiveFormats {
  const { state } = view;
  const { from, to } = state.selection;
  const formats: ActiveFormats = {};

  // Check inline marks
  const marks = state.storedMarks || state.selection.$from.marks();
  for (const mark of marks) {
    switch (mark.type.name) {
      case 'strong':
        formats.bold = true;
        break;
      case 'emphasis':
        formats.italic = true;
        break;
      case 'strike_through':
        formats.strikethrough = true;
        break;
    }
  }

  // Also check marks across the selection range
  if (from !== to) {
    state.doc.nodesBetween(from, to, (node) => {
      for (const mark of node.marks) {
        switch (mark.type.name) {
          case 'strong':
            formats.bold = true;
            break;
          case 'emphasis':
            formats.italic = true;
            break;
          case 'strike_through':
            formats.strikethrough = true;
            break;
        }
      }
    });
  }

  // Check highlight mark via the plugin's mark type
  try {
    const highlightMarkType = highlightMark.type(view.state);
    if (highlightMarkType) {
      const hasHighlight = marks.some((m) => m.type === highlightMarkType);
      if (hasHighlight) formats.highlight = true;

      if (!hasHighlight && from !== to) {
        state.doc.nodesBetween(from, to, (node) => {
          if (highlightMarkType.isInSet(node.marks)) {
            formats.highlight = true;
          }
        });
      }
    }
  } catch {
    // highlightMark may not be available
  }

  // Check block-level formatting
  const $from = state.selection.$from;
  const parentNode = $from.parent;

  if (parentNode.type.name === 'heading') {
    formats.heading = parentNode.attrs.level as number;
  } else {
    formats.heading = 0;
  }

  // Walk up to find list/blockquote context
  for (let d = $from.depth; d > 0; d--) {
    const node = $from.node(d);
    switch (node.type.name) {
      case 'bullet_list':
        formats.bulletList = true;
        break;
      case 'ordered_list':
        formats.numberList = true;
        break;
      case 'blockquote':
        formats.blockquote = true;
        break;
      case 'code_block':
        formats.codeBlock = true;
        break;
    }
  }

  return formats;
}

function getSelectionRect(view: EditorView): SelectionRect | null {
  const { from, to } = view.state.selection;
  const start = view.coordsAtPos(from);
  const end = view.coordsAtPos(to);

  if (!start || !end) return null;

  return {
    top: Math.min(start.top, end.top),
    left: Math.min(start.left, end.left),
    right: Math.max(start.right, end.right),
    bottom: Math.max(start.bottom, end.bottom),
    width: Math.abs(end.right - start.left),
  };
}

export const selectionToolbarPlugin: MilkdownPlugin = $prose(() => {
  return new Plugin({
    key: selectionToolbarKey,
    view() {
      return {
        update(view: EditorView) {
          const { selection } = view.state;
          const { empty } = selection;

          // Hide if selection is collapsed (cursor only)
          if (empty) {
            hideToolbar();
            return;
          }

          // Hide in source mode (selection toolbar is for WYSIWYG only in Milkdown)
          if (isSourceModeEnabled()) {
            hideToolbar();
            return;
          }

          const rect = getSelectionRect(view);
          if (!rect) {
            hideToolbar();
            return;
          }

          const formats = getActiveFormats(view);
          showToolbar(rect, formats);
        },
        destroy() {
          hideToolbar();
        },
      };
    },
  });
});
