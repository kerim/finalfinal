// Heading NodeView Plugin for Milkdown
// In source mode, renders heading markers (# ## ###) as editable content
// This allows users to select and edit the # prefix directly
// In WYSIWYG mode, uses default ProseMirror heading rendering
//
// Also includes a keymap for improved heading deletion behavior:
// When entire heading content is selected, backspace deletes the whole block

import type { Ctx, MilkdownPlugin } from '@milkdown/kit/ctx';
import { headingSchema } from '@milkdown/kit/preset/commonmark';
import { keymap } from '@milkdown/kit/prose/keymap';
import { $prose, $view } from '@milkdown/kit/utils';
import { isSourceModeEnabled } from './source-mode-plugin';

// NodeView for headings - only active in source mode
// In WYSIWYG mode, returns null to use default rendering
const headingNodeView = $view(headingSchema.node, (_ctx: Ctx) => {
  return (node) => {
    // Track source mode at creation time
    const createdInSourceMode = isSourceModeEnabled();

    // WYSIWYG mode - return null to use default ProseMirror heading rendering
    // This is more efficient than creating a custom NodeView that mimics default behavior
    if (!createdInSourceMode) {
      // Return a simple passthrough that forces recreation on mode change
      const level = node.attrs.level as number;
      const dom = document.createElement(`h${level}`);
      // Add data-placeholder for empty heading visibility (shows "## " when empty)
      const placeholder = `${'#'.repeat(level)} `;
      dom.setAttribute('data-placeholder', placeholder);

      // Add heading-empty class if node has no content (for CSS placeholder)
      if (node.content.size === 0) {
        dom.classList.add('heading-empty');
      }

      const contentDOM = document.createElement('span');
      dom.appendChild(contentDOM);

      return {
        dom,
        contentDOM,
        update: (updatedNode) => {
          if (updatedNode.type.name !== 'heading') return false;
          // Force recreation if mode changed
          if (isSourceModeEnabled() !== createdInSourceMode) {
            return false;
          }
          // Update heading level if changed
          if (updatedNode.attrs.level !== node.attrs.level) {
            return false; // Recreate with new tag
          }

          // Toggle heading-empty class based on content
          if (updatedNode.content.size === 0) {
            dom.classList.add('heading-empty');
          } else {
            dom.classList.remove('heading-empty');
          }

          return true;
        },
      };
    }

    // Source mode - prefix is now in the text content
    const level = node.attrs.level as number;

    const dom = document.createElement('div');
    dom.className = `heading-source-mode heading-level-${level}`;
    dom.setAttribute('data-level', String(level));

    // Single contentDOM for all text (including ## prefix)
    const contentDOM = document.createElement('span');
    contentDOM.className = 'heading-content';
    dom.appendChild(contentDOM);

    return {
      dom,
      contentDOM,
      update: (updatedNode) => {
        if (updatedNode.type.name !== 'heading') return false;
        if (isSourceModeEnabled() !== createdInSourceMode) return false;
        if (updatedNode.attrs.level !== node.attrs.level) return false;
        return true;
      },
    };
  };
});

// Keymap for improved heading deletion behavior
// When entire heading content is selected, backspace deletes the whole block in one press
// This improves UX by reducing the number of backspaces needed from 4 to 1-2
const headingBackspaceKeymap = $prose(() => {
  return keymap({
    Backspace: (state, dispatch) => {
      const { $from, $to, empty } = state.selection;

      // Only handle non-empty selections (when text is selected)
      if (empty) return false;

      // Check if selection is entirely within a heading
      if ($from.parent.type.name !== 'heading') return false;
      if ($to.parent !== $from.parent) return false; // Selection spans multiple nodes

      // Check if entire heading content is selected
      const isEntireContent = $from.parentOffset === 0 && $to.parentOffset === $from.parent.content.size;

      if (isEntireContent) {
        // Delete the entire heading block
        if (dispatch) {
          const tr = state.tr.delete($from.before($from.depth), $to.after($to.depth));
          dispatch(tr);
        }
        return true;
      }

      return false; // Let default handling take over
    },
  });
});

// Export the plugin
export const headingNodeViewPlugin: MilkdownPlugin[] = [headingNodeView, headingBackspaceKeymap].flat();
