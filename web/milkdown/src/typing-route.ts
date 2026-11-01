// Glue between the routes and typing-rebase.ts (Phase 4c, job 2, t-d2061b27): the small pieces that read editor state the pure layer
// does not know about. No import of undo-coordinator.ts, which imports this file.

import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import { Mapping } from '@milkdown/kit/prose/transform';
import { alignTopLevelIds } from './block-id-plugin';
import type { ExpectedBlockMeta } from './types';
import { commutePress, type TypingCollector } from './typing-rebase';

/** Top-level offset -> block id for `doc`, from the ordered ids Swift sends with a swap (`payload.blockIds`, one per block node,
 * marker atoms excluded), placed exactly as `setBlockIdsForTopLevel` places them after the swap. */
export function idsByOffsetFromPayload(
  doc: ProsemirrorNode,
  orderedIds: string[],
  expected: ExpectedBlockMeta[]
): Map<number, string> {
  return new Map(alignTopLevelIds(orderedIds, doc, expected).blockIds);
}

/** The block ids of the document the press acts on (`commutePress(...).doc`), at the offsets of THAT document, for a press whose stored
 * ids are in the coordinates of the document at the press (the one the replay is about to run for). The stored ids hold every block of
 * that document, a block the user's typing joined away included (a Backspace at the start of a paragraph: the replay has to know the
 * joined block to place the join), so they are moved through the automatic changes that landed since (a rewrite earlier in the
 * document shifts every later offset). Without stored ids the live ids are used (`idsAtPressInLiveCoordinates`). */
export function idsOfDocumentAtPress(
  collector: TypingCollector,
  press: number,
  liveDoc: ProsemirrorNode,
  liveIds: ReadonlyMap<number, string>
): Map<number, string> {
  const back = commutePress(collector, press, liveDoc);
  const stored = collector.idsAtPress(press);
  if (!back.ok || stored === undefined) return idsAtPressInLiveCoordinates(collector, press, liveDoc, liveIds);
  const ids = new Map<number, string>();
  // Ascending offsets: where a rewrite collapsed several blocks onto one position, the block that follows wins.
  for (const [offset, id] of [...stored].sort((a, b) => a[0] - b[0])) ids.set(back.autoMapping.map(offset, 1), id);
  return ids;
}

/** The block ids of the document as it was at `press`, in the offsets of that document, rebuilt from the LIVE ids: used for a press that
 * is still held after a replay moved the document (the ids it stored when it was queued are in the old coordinates). A live block
 * that did not exist at the press (made by typing) has no place in the earlier document and is left out, and so is a block the
 * typing joined away (it has no live id). */
export function idsAtPressInLiveCoordinates(
  collector: TypingCollector,
  press: number,
  liveDoc: ProsemirrorNode,
  liveIds: ReadonlyMap<number, string>
): Map<number, string> {
  const ids = new Map<number, string>();
  const back = commutePress(collector, press, liveDoc);
  if (!back.ok) return ids;
  const steps = back.typing;
  const mapping = new Mapping();
  for (let index = steps.length - 1; index >= 0; index--) mapping.appendMap(steps[index].inverted.getMap());
  liveDoc.forEach((node, offset) => {
    const id = liveIds.get(offset);
    if (id === undefined) return;
    try {
      const pos = mapping.map(offset, 1);
      const $pos = back.doc.resolve(pos);
      if ($pos.depth === 0 && $pos.nodeAfter?.type === node.type) ids.set(pos, id);
    } catch {
      // A position that does not resolve in the earlier document belongs to a block that was not there.
    }
  });
  return ids;
}
