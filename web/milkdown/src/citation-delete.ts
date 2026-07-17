// Shared citation-deletion transaction builder.
//
// Used by both the Backspace/Delete keymap (citation-plugin.ts) and the popup's
// Delete button (citation-edit-popup.ts) so both entry points produce the exact
// same single, atomic, undoable transaction: delete the citation node, and if
// doing so would leave a doubled space behind (citation was surrounded by
// whitespace on both sides), collapse that down to one space instead of two.
//
// Whitespace-collapse side: we always extend the deleted range to consume the
// space AFTER the citation (`to + 1`), never the space before it. This keeps
// the cursor landing at the boundary between the preceding text and whatever
// follows — e.g. "See [@key] for details." -> "See for details." with the
// cursor right before "for", not with a trailing space stranded before it.
// Collapsing the leading space instead would leave the cursor sitting one
// character further left (before the surviving space), which reads oddly
// after a Backspace/Delete-driven removal. This choice must stay consistent
// between the keymap and the popup button so both feel identical.
import type { EditorState, Transaction } from '@milkdown/kit/prose/state';
import { TextSelection } from '@milkdown/kit/prose/state';

export const CITATION_NODE_NAME = 'citation';

function isWhitespace(ch: string | undefined): ch is string {
  return !!ch && /\s/.test(ch);
}

/**
 * Build a transaction that deletes the citation node at `pos`, collapsing a
 * doubled space around it if present. Returns null if there is no citation
 * node at `pos` (e.g. the position went stale between when it was captured
 * and when this is called).
 */
export function buildCitationDeleteTransaction(state: EditorState, pos: number): Transaction | null {
  const node = state.doc.nodeAt(pos);
  if (!node || node.type.name !== CITATION_NODE_NAME) return null;

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
