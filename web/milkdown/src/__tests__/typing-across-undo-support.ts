// Shared helpers for the typing-across-undo route tests (Phase 4c, job 2): typing as the editor receives it, block texts, and a
// structural operation played the way Swift's registry calls play it. Not a test file.

import { joinBackward, splitBlock } from '@milkdown/kit/prose/commands';
import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import { TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { expect } from 'vitest';
import { getBlockChangesApi } from '../api-content';
import { getAllBlockIds, setBlockIdsForTopLevel } from '../block-id-plugin';
import { flushPendingBlockChanges } from '../block-sync-plugin';
import { beginStructuralOp, finalizeStructuralOpPostOpDoc } from '../undo-coordinator';

/** A block's text, with a footnote reference written `[^label]`. */
export function describeBlock(node: ProsemirrorNode): string {
  return node.textBetween(0, node.content.size, '', (leaf) =>
    leaf.type.name === 'footnote_ref' ? `[^${leaf.attrs.label}]` : ''
  );
}

export const texts = (view: EditorView): string[] => {
  const out: string[] = [];
  view.state.doc.forEach((node) => {
    out.push(describeBlock(node));
  });
  return out;
};

/** The top-level blocks by id, as the editor holds them now. */
export function blocksById(view: EditorView): Map<string, ProsemirrorNode> {
  const ids = getAllBlockIds();
  const byId = new Map<string, ProsemirrorNode>();
  view.state.doc.forEach((node, offset) => {
    byId.set(ids.get(offset) as string, node);
  });
  return byId;
}

/** A structural operation as the editor sees it: the top-level blocks become `order` (by their current ids); not a text-history step. */
export function rewriteBlocks(view: EditorView, order: string[]): void {
  const nodes = blocksById(view);
  view.dispatch(
    view.state.tr
      .replaceWith(
        0,
        view.state.doc.content.size,
        order.map((id) => nodes.get(id) as ProsemirrorNode)
      )
      .setMeta('addToHistory', false)
  );
  setBlockIdsForTopLevel(order, view.state.doc);
}

/** A restore as the editor sees it: the block `oldId` becomes `node` and takes the fresh id `newId` (only a section's root heading keeps its own). */
export function replaceBlockNode(view: EditorView, oldId: string, newId: string, node: ProsemirrorNode): void {
  const ids = getAllBlockIds();
  const entries: Array<{ id: string; node: ProsemirrorNode }> = [];
  view.state.doc.forEach((existing, offset) => {
    const id = ids.get(offset) as string;
    entries.push(id === oldId ? { id: newId, node } : { id, node: existing });
  });
  view.dispatch(
    view.state.tr
      .replaceWith(
        0,
        view.state.doc.content.size,
        entries.map((entry) => entry.node)
      )
      .setMeta('addToHistory', false)
  );
  setBlockIdsForTopLevel(
    entries.map((entry) => entry.id),
    view.state.doc
  );
}

/** What Swift's registry calls do around an operation: the pre-op checkpoint, the operation, the post-op copy; then nothing pending. */
export function runRegisteredOp(_view: EditorView, opId: string, op: () => void): void {
  expect(beginStructuralOp(opId)).toBe(true);
  op();
  expect(finalizeStructuralOpPostOpDoc(opId)).toBe(true);
  flushPendingBlockChanges();
  getBlockChangesApi(); // what the operation itself left pending is not what these tests are about
}

export function placeCaret(view: EditorView, pos: number): void {
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)).setMeta('addToHistory', false));
}

/** Typed characters take the path the browser's input takes: input rules first, then the plain insertion. */
export function typeText(view: EditorView, text: string): void {
  for (const char of text) {
    const { from, to } = view.state.selection;
    const handled = view.someProp('handleTextInput', (handler) =>
      handler(view, from, to, char, () => view.state.tr.insertText(char, from, to))
    );
    if (!handled) view.dispatch(view.state.tr.insertText(char, from, to));
  }
}

export const pressEnter = (view: EditorView): boolean => splitBlock(view.state, (tr) => view.dispatch(tr), view);
export const pressBackspaceAtBlockStart = (view: EditorView): boolean =>
  joinBackward(view.state, (tr) => view.dispatch(tr), view);

/** The text of the first paragraph starting with `startsWith`. */
export function paragraphText(view: EditorView, startsWith: string): string {
  let found = '';
  view.state.doc.forEach((node) => {
    if (!found && node.type.name === 'paragraph' && node.textContent.startsWith(startsWith)) found = node.textContent;
  });
  return found;
}

/** Document position at the start of the text of the first paragraph starting with `startsWith`. */
export function startOfParagraph(view: EditorView, startsWith: string): number {
  let pos = -1;
  view.state.doc.forEach((node, offset) => {
    if (pos === -1 && node.type.name === 'paragraph' && node.textContent.startsWith(startsWith)) pos = offset + 1;
  });
  expect(pos, `paragraph starting with "${startsWith}" must exist`).toBeGreaterThan(-1);
  return pos;
}

export const endOfParagraphText = (view: EditorView, startsWith: string): number =>
  startOfParagraph(view, startsWith) + paragraphText(view, startsWith).length;
