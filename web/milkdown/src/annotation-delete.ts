// Shared annotation-deletion transaction builder.
//
// Direct analogue of citation-delete.ts (see that file's header for the full rationale) --
// used by the Backspace/Delete keymap (annotation-plugin.ts), the popup's Delete button
// (annotation-edit-popup.ts), and the panel card's delete button (api-annotations.ts) so all
// three entry points produce the exact same single, atomic, undoable transaction: delete the
// annotation node, and if doing so would leave a doubled space behind (the annotation was
// surrounded by whitespace on both sides), collapse that down to one space instead of two.
//
// Whitespace-collapse side: same convention as citations -- always extend the deleted range
// to consume the space AFTER the annotation (`to + 1`), never the space before it, so the
// keymap and the popup/panel-card buttons feel identical.
import type { EditorState, Transaction } from '@milkdown/kit/prose/state';
import { TextSelection } from '@milkdown/kit/prose/state';

export const ANNOTATION_NODE_NAME = 'annotation';

function isWhitespace(ch: string | undefined): ch is string {
  return !!ch && /\s/.test(ch);
}

/**
 * Build a transaction that deletes the annotation node at `pos`, collapsing a doubled space
 * around it if present. Returns null if there is no annotation node at `pos` (e.g. the
 * position went stale between when it was captured and when this is called).
 */
export function buildAnnotationDeleteTransaction(state: EditorState, pos: number): Transaction | null {
  const node = state.doc.nodeAt(pos);
  if (!node || node.type.name !== ANNOTATION_NODE_NAME) return null;

  const from = pos;
  const to = pos + node.nodeSize;

  const before = state.doc.resolve(from).nodeBefore;
  const after = state.doc.resolve(to).nodeAfter;
  const beforeChar = before?.isText ? before.text?.slice(-1) : undefined;
  const afterChar = after?.isText ? after.text?.slice(0, 1) : undefined;
  const hasDuplicateSpace = isWhitespace(beforeChar) && isWhitespace(afterChar);

  const tr = state.tr.delete(from, hasDuplicateSpace ? to + 1 : to);
  tr.setSelection(TextSelection.near(tr.doc.resolve(from)));
  return tr;
}
