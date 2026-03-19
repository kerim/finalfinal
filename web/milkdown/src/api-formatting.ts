// Formatting API methods for Milkdown WYSIWYG editor
// Provides callable formatting methods exposed via window.FinalFinal

import { editorViewCtx } from '@milkdown/kit/core';
import {
  createCodeBlockCommand,
  toggleEmphasisCommand,
  toggleStrongCommand,
  wrapInBlockquoteCommand,
  wrapInBulletListCommand,
  wrapInHeadingCommand,
  wrapInOrderedListCommand,
} from '@milkdown/kit/preset/commonmark';
import { toggleStrikethroughCommand } from '@milkdown/kit/preset/gfm';
import { lift } from '@milkdown/kit/prose/commands';
import { liftListItem } from '@milkdown/kit/prose/schema-list';
import { callCommand } from '@milkdown/kit/utils';
import { getEditorInstance } from './editor-state';
import { openLinkEdit } from './link-tooltip';

// GFM strikethrough: use the GFM preset's toggleStrikethroughCommand
// via callCommand to avoid mark name mismatches (GFM registers as
// "strike_through" with underscore, not "strikethrough")
function toggleStrikethroughViaMarks(): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;

  try {
    editorInstance.action(callCommand(toggleStrikethroughCommand.key));
    return true;
  } catch {
    return false;
  }
}

export function toggleBold(): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  try {
    editorInstance.action(callCommand(toggleStrongCommand.key));
    return true;
  } catch {
    return false;
  }
}

export function toggleItalic(): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  try {
    editorInstance.action(callCommand(toggleEmphasisCommand.key));
    return true;
  } catch {
    return false;
  }
}

export function toggleStrikethrough(): boolean {
  return toggleStrikethroughViaMarks();
}

export function setHeading(level: number): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  try {
    if (level === 0) {
      // Level 0 = convert to paragraph: use ProseMirror directly
      const view = editorInstance.ctx.get(editorViewCtx);
      const { from } = view.state.selection;
      const $from = view.state.doc.resolve(from);
      const parentStart = $from.before($from.depth);
      const parentEnd = $from.after($from.depth);
      const parentNode = $from.parent;

      if (parentNode.type.name === 'heading') {
        const paragraphType = view.state.schema.nodes.paragraph;
        const content = parentNode.content;
        const paragraph = paragraphType.create(null, content, parentNode.marks);
        const tr = view.state.tr.replaceWith(parentStart, parentEnd, paragraph);
        view.dispatch(tr);
        view.focus();
      }
      return true;
    }
    editorInstance.action(callCommand(wrapInHeadingCommand.key, level));
    return true;
  } catch {
    return false;
  }
}

export function toggleBulletList(): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { $from } = view.state.selection;

    // Check if already inside a bullet_list
    for (let d = $from.depth; d > 0; d--) {
      if ($from.node(d).type.name === 'bullet_list') {
        // Lift list item to unwrap
        const listItemType = view.state.schema.nodes.list_item;
        if (listItemType) {
          liftListItem(listItemType)(view.state, view.dispatch);
          view.focus();
        }
        return true;
      }
    }

    editorInstance.action(callCommand(wrapInBulletListCommand.key));
    return true;
  } catch {
    return false;
  }
}

export function toggleNumberList(): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { $from } = view.state.selection;

    // Check if already inside an ordered_list
    for (let d = $from.depth; d > 0; d--) {
      if ($from.node(d).type.name === 'ordered_list') {
        const listItemType = view.state.schema.nodes.list_item;
        if (listItemType) {
          liftListItem(listItemType)(view.state, view.dispatch);
          view.focus();
        }
        return true;
      }
    }

    editorInstance.action(callCommand(wrapInOrderedListCommand.key));
    return true;
  } catch {
    return false;
  }
}

export function toggleBlockquote(): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { $from } = view.state.selection;

    // Check if already inside a blockquote
    for (let d = $from.depth; d > 0; d--) {
      if ($from.node(d).type.name === 'blockquote') {
        lift(view.state, view.dispatch);
        view.focus();
        return true;
      }
    }

    editorInstance.action(callCommand(wrapInBlockquoteCommand.key));
    return true;
  } catch {
    return false;
  }
}

export function toggleCodeBlock(): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { $from } = view.state.selection;

    // Check if already inside a code_block
    if ($from.parent.type.name === 'code_block') {
      const paragraphType = view.state.schema.nodes.paragraph;
      const start = $from.before($from.depth);
      const end = $from.after($from.depth);
      const content = $from.parent.content;
      const paragraph = paragraphType.create(null, content);
      const tr = view.state.tr.replaceWith(start, end, paragraph);
      view.dispatch(tr);
      view.focus();
      return true;
    }

    editorInstance.action(callCommand(createCodeBlockCommand.key));
    return true;
  } catch {
    return false;
  }
}

export function insertLinkAtCursor(): boolean {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return false;
  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    openLinkEdit(view);
    return true;
  } catch {
    return false;
  }
}
