// Math equation insert API for window.FinalFinal
// Mirrors insertTable in api-modes.ts: get view → build node → dispatch → focus.

import { editorViewCtx } from '@milkdown/kit/core';
import { getEditorInstance } from './editor-state';

/**
 * Insert an equation at the cursor.
 * isDisplay=false → math_inline node (inserted at inline cursor position)
 * isDisplay=true  → math_display node (inserted at block boundary, like insertTable)
 */
export function insertEquation(latex: string, isDisplay: boolean): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  try {
    const view = editorInstance.ctx.get(editorViewCtx);
    const { state } = view;
    const typeName = isDisplay ? 'math_display' : 'math_inline';
    const nodeType = state.schema.nodes[typeName];
    if (!nodeType) {
      console.warn(`[math] Node type '${typeName}' not found in schema`);
      return;
    }

    const node = nodeType.create({ latex });

    if (!isDisplay) {
      // Inline: insert at the raw cursor position (schema-legal inside paragraph)
      const { from, to } = state.selection;
      const tr = state.tr.replaceWith(from, to, node);
      view.dispatch(tr);
    } else {
      // Block: resolve to top-level block boundary — mirrors insertTable logic.
      // Inserting a block node at the inline cursor position causes a schema
      // violation that ProseMirror silently rejects, dropping the node entirely.
      const { from } = state.selection;
      const $from = state.doc.resolve(from);
      const topLevel = $from.depth >= 1 ? $from.node(1) : null;
      const isEmptyTopParagraph =
        topLevel !== null && topLevel.type.name === 'paragraph' && topLevel.content.size === 0;

      const tr = isEmptyTopParagraph
        ? state.tr.replaceWith($from.before(1), $from.after(1), node)
        : state.tr.insert($from.after(1), node);
      view.dispatch(tr);
    }

    view.focus();
  } catch (e) {
    console.error('[math] insertEquation failed:', e);
  }
}

export { insertEquationDialog } from '../../shared/equation-dialog';
