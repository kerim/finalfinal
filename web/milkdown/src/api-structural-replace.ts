// Editor-first range replace -- the editor half of Phase 4b slice 2, round 2c (t-18b7fa48): the three Version History restores.
//
// Today a restore saves the whole document, changes the rows in the database and pushes the whole document back into the editor;
// the push overwrites whatever the user typed meanwhile. Here the EDITOR changes first, in one synchronous JavaScript turn, and the
// database catches up afterwards as a queued write job (Swift side, round 2d). Nothing is pushed back over the user's text. It is the
// duplicate's sibling (api-section-duplicate.ts): the same shared turn (`runEditorFirstChange`, editor-first-op.ts, whose header
// lists the steps and says what protects the editor while the change is dispatched), the same reply discipline -- the batch of
// pending edits the call consumed comes back on EVERY path, and Swift always applies it -- and the same quick undo
// (api-section-undo.ts `undoSectionDeleteEditorFirst`, the generic checkpoint swap, which takes the replaced range back out and puts
// the old one in again). That undo is not changed here; it undoes every mode of this file back to the exact pre-op document.
//
// One call, three modes (`payload.mode`):
//   'whole'        the whole document is replaced by the payload's Markdown (restore project). The same steps the whole-document push
//                  (api-content.ts `setContentWithBlockIds`) takes, minus its animation-frame-deferred re-baseline, which would
//                  swallow typing made in the first frame after the reply: parse, block-level diff-replace, ids, managed ids.
//   'section'      the FLAT range of the target heading (`findFlatSectionRange`: the heading plus its own body, up to the next
//                  heading of ANY level, a section break, the first managed block or the end) is replaced by the parsed fragment
//                  (replace current section). The first node of the fragment keeps the target heading's id; the sub-sections
//                  below the range are not touched, and keep their ids.
//   'insertAfter'  the parsed fragment is inserted after the anchor block, or after the last non-managed block when no anchor is
//                  given, so it lands above Notes and Bibliography (restore as duplicate). Nothing is removed.
//
// The payload is the result of Swift's `StructuralUndoController.editorPayload(for:)` (the markdown, the id of each top-level node,
// what each is expected to be, the image metadata, the bibliography span and the managed ids), plus the mode and the anchors. The
// ids must line up with the editor's own parse exactly the way a whole-document push lines up; this file checks that BEFORE it
// dispatches anything (count, types, non-blank content, no id used twice), and again AFTER (every top-level block holds the id it was
// meant to hold). A mismatch refuses with `reason: 'idAlignment'`: before the dispatch nothing was touched; after it the shared turn
// puts the checkpoint, the id maps and the baseline back (and this file the managed-id set). Swift then runs the old restore.
//
// What the turn does, in order: (a) the shared steps -- flush, take the batch, pause block-sync, begin the op, copy the id maps; (e)
// find the range, parse the fragment, check the alignment, prepare the nodes (a figure gets its own id and its image metadata);
// (f) dispatch ONE transaction, not added to the text history, and give the new top-level nodes their payload ids; then the shared
// steps again -- re-baseline block-sync on the document WITH the payload ids, resume, finalize. Batch N, the change and the
// re-baseline all happen inside this one synchronous call: nothing can be typed between them.

import { parserCtx } from '@milkdown/kit/core';
import { Fragment, type Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import { Selection } from '@milkdown/kit/prose/state';
import { buildBlockLevelReplace } from './api-content';
import {
  isManagedEntry,
  leaderLevel,
  type RemovedSectionSnapshot,
  type SectionRange,
  type TopLevelEntry,
} from './api-section-delete';
import { checkQuickRedoAllowed, finishQuickRedoLine, putBackAfterQuickRedo } from './api-section-undo';
import {
  alignTopLevelIds,
  clearBlockIds,
  getBlockIdAtPos,
  getManagedBlockIds,
  isBlockType,
  setBlockIdsForTopLevel,
  setManagedBlockIds,
  setTopLevelIdsAt,
} from './block-id-plugin';
import type { BlockChanges } from './block-sync-plugin';
import { runEditorFirstChange, trace } from './editor-first-op';
import { getEditorInstance } from './editor-state';
import type { ExpectedBlockMeta, ImageBlockMeta } from './types';
import type { UndoRegistryEntry } from './undo-coordinator';

export type ReplaceMode = 'whole' | 'section' | 'insertAfter';

/**
 * What Swift sends. The field names are those of Swift's `ContentView.BlockFetchResult` (what `editorPayload(for:)` returns) so the
 * struct can be encoded as it is, plus the four fields that say what to do with it.
 */
export interface ReplaceRangePayload {
  mode: ReplaceMode;
  /** 'section': the id of the target heading (its block id in the editor). The payload's first id must be this same id. */
  rootBlockId?: string;
  /** 'insertAfter': the id of the top-level block the fragment goes directly after. Absent or null: after the last block that is
   * not Notes or Bibliography content. */
  anchorBlockId?: string | null;
  /** The Markdown the editor parses: the whole document ('whole') or the fragment ('section', 'insertAfter'). */
  markdown: string;
  /** One id per top-level node the parse of `markdown` produces (`BlockParser.alignmentPairs` order). */
  blockIds: string[];
  /** One entry per id: what the node must be and whether it must have text (`BlockFetchResult.expectedBlocks`). */
  expectedBlocks: ExpectedBlockMeta[];
  /** The ids of the CURRENT document's Notes and Bibliography blocks, read from the database at the click (never the editor's own
   * copy, which can be stale). Used to find the end of a section and the last non-managed block. May be empty for 'whole'. */
  managedIds: string[];
  /** Caption and width of the figures in `markdown`, matched to the figures by id (`BlockFetchResult.imageMeta`). */
  imageMeta?: ImageBlockMeta[];
  /** Node index of the first bibliography block, and one past the last (`BlockFetchResult.bibBoundaryIndex/EndIndex`). 'whole'
   * only: they keep the caret out of the bibliography, as the whole-document push does. */
  bibBoundaryIndex?: number | null;
  bibBoundaryEndIndex?: number | null;
  /** The ids that are Notes or Bibliography content in the PAYLOAD's document (`BlockFetchResult.managedBlockIds`). 'whole' only:
   * it replaces the editor's managed-id set, which paints `data-managed`. */
  managedBlockIds?: string[];
}

/** What `replaceRangeEditorFirst` and `redoReplaceRangeEditorFirst` return, on every path. Swift reads it as `JSON.stringify(...)`. */
export interface ReplaceRangeResult {
  /** Every pending edit this call consumed, in `getBlockChanges()` shape. Empty when nothing was pending, and on a refusal by the redo's
   * gate (the gate consumes nothing). A redo refused because typing sits inside the text it replaces carries the typing (once). Swift
   * always applies a returned batch. */
  batch: BlockChanges;
  ok: boolean;
  /** Why `ok` is false: 'noEditor', 'beginFailed', 'rootNotFound', 'managedRoot', 'rootNotLeader' (section mode), 'anchorNotFound',
   * 'managedAnchor' (insertAfter with an explicit anchor), 'unknownMode', 'idAlignment' (the payload and the editor's parse
   * disagree; the document is untouched), 'notInFlight', 'noEntry', 'midOp', 'docChanged' (the last four are the redo's gate), or
   * 'exception: <message>'. */
  reason?: string;
  /** The ids the editor now holds for the replaced or inserted range, in document order: the payload's `blockIds`. For 'whole', the
   * ids of the whole new document. */
  insertedIds: string[];
  /** The subset of `insertedIds` that are section leaders (headings and section breaks). */
  insertedLeaderIds: string[];
  /** One entry per inserted leader, in document order (id, kind, level, title): for the sidebar. For 'whole', the leaders of the
   * whole new document. */
  insertedSectionsSnapshot: RemovedSectionSnapshot[];
  /** Ids of the top-level blocks the change took out, in document order. Empty for 'insertAfter'. For 'whole', every block of the
   * old document. */
  removedIds: string[];
  /** The subset of `removedIds` that were section leaders. */
  removedLeaderIds: string[];
  /** Id of the nearest block before the range that has one ('section'), or of the block the fragment follows ('insertAfter'); null
   * when there is none, and always null for 'whole'. */
  predecessorId: string | null;
  /** The quick REDO only, on an `ok: true` reply: true when the user typed since the key was pressed (the page's own answer, from the
   * redo's gate), absent on every other reply. A non-empty `batch` is not proof of typing (it can hold a rewrite the previous command's
   * settle left); Swift ends the older redo entries only when this is true. */
  typed?: boolean;
}

// Test seam (web tests only; production never sets it): runs right after the change was dispatched and its ids set, before they are
// checked. A throw from it exercises the failure path a real error after the dispatch would take; a hook that tampers with an id
// exercises the post-dispatch alignment check.
let afterReplaceHook: (() => void) | null = null;
export function setTestAfterReplaceHook(hook: (() => void) | null): void {
  afterReplaceHook = hook;
}

/** Every top-level node of `doc` with its position and the block id the plugin holds for it (undefined for the marker atoms). */
function topLevelEntries(doc: ProsemirrorNode, ids: ReadonlyMap<number, string>): TopLevelEntry[] {
  const entries: TopLevelEntry[] = [];
  doc.forEach((node, pos) => {
    entries.push({ node, pos, id: ids.get(pos) });
  });
  return entries;
}

/**
 * The FLAT section range, JS side: the root leader and its OWN body, up to -- not including -- the next leader of ANY level (a
 * heading or a section break), the first Notes/Bibliography node, or the end of the document. The twin of the database's
 * `ProjectDatabase.flatSectionBlockIds` (Database+SectionOps.swift) and of the cut `SectionSyncService` makes for Version History:
 * a level-1 chapter keeps its level-2 children when its own text is replaced. (`findSectionRange` in api-section-delete.ts is the
 * SUBTREE rule the delete and the duplicate use.) Same reply shape and same refusals as `findSectionRange`: the root must be a
 * leader and must not be managed.
 */
export function findFlatSectionRange(
  doc: ProsemirrorNode,
  ids: ReadonlyMap<number, string>,
  rootBlockId: string,
  managedIds: ReadonlySet<string>
): SectionRange {
  const entries = topLevelEntries(doc, ids);
  const rootIndex = entries.findIndex((entry) => entry.id === rootBlockId);
  if (rootIndex < 0) return { ok: false, reason: 'rootNotFound' };
  if (managedIds.has(rootBlockId)) return { ok: false, reason: 'managedRoot' };
  if (leaderLevel(entries[rootIndex].node) === undefined) return { ok: false, reason: 'rootNotLeader' };

  let end = rootIndex + 1;
  while (end < entries.length) {
    const entry = entries[end];
    if (isManagedEntry(entry, managedIds) || leaderLevel(entry.node) !== undefined) break;
    end++;
  }

  let predecessorId: string | null = null;
  for (let i = rootIndex - 1; i >= 0; i--) {
    const id = entries[i].id;
    if (id !== undefined) {
      predecessorId = id;
      break;
    }
  }

  const last = entries[end - 1];
  return {
    ok: true,
    from: entries[rootIndex].pos,
    to: last.pos + last.node.nodeSize,
    removed: entries.slice(rootIndex, end),
    predecessorId,
  };
}

/** Why the parsed Markdown cannot take the payload's ids, or null when it can. The same comparison a whole-document push makes
 * (`alignTopLevelIds` with the expected metadata), plus the count both ways. Exported for the slow undo's editor-first swap
 * (api-structural-swap.ts), which asks the same question of the checkpoint's document instead of a parse; it reads only the two
 * fields in the `Pick`. */
export function alignmentProblem(
  parsed: ProsemirrorNode,
  payload: Pick<ReplaceRangePayload, 'blockIds' | 'expectedBlocks'>
): string | null {
  let blockNodes = 0;
  parsed.forEach((node) => {
    if (isBlockType(node)) blockNodes++;
  });
  const idCount = payload.blockIds.length;
  if (blockNodes !== idCount) return `count: nodes=${blockNodes} ids=${idCount}`;
  if (payload.expectedBlocks.length !== idCount)
    return `expected: entries=${payload.expectedBlocks.length} ids=${idCount}`;
  const aligned = alignTopLevelIds(payload.blockIds, parsed, payload.expectedBlocks);
  if (aligned.mismatches.length > 0) {
    const first = aligned.mismatches[0];
    return `mismatch at index ${first.index}: ${first.reason}`;
  }
  return null;
}

/** The parsed top-level nodes, with every figure given its payload id on the node (`blockId` attr, which is what the DOM paints
 * until the next decoration pass) and, when the payload carries metadata for it, its caption and width. The ids are by block index
 * (the i-th block-type node has the i-th payload id), exactly as the alignment check lined them up. */
function preparedNodes(parsed: ProsemirrorNode, payload: ReplaceRangePayload): ProsemirrorNode[] {
  const metaById = new Map((payload.imageMeta ?? []).map((meta) => [meta.id, meta]));
  const nodes: ProsemirrorNode[] = [];
  let blockIndex = 0;
  parsed.forEach((node) => {
    if (!isBlockType(node)) {
      nodes.push(node);
      return;
    }
    const id = payload.blockIds[blockIndex++];
    if (node.type.name !== 'figure') {
      nodes.push(node);
      return;
    }
    const meta = metaById.get(id);
    const attrs = meta
      ? { ...node.attrs, caption: meta.caption || '', width: meta.width ?? node.attrs.width ?? null, blockId: id }
      : { ...node.attrs, blockId: id };
    nodes.push(node.type.create(attrs, node.content, node.marks));
  });
  return nodes;
}

/** The section leaders among `nodes` (given the payload ids by block index), for the sidebar. Exported for api-structural-swap.ts. */
export function leadersOf(
  nodes: readonly ProsemirrorNode[],
  ids: readonly string[]
): { leaderIds: string[]; snapshot: RemovedSectionSnapshot[] } {
  const leaderIds: string[] = [];
  const snapshot: RemovedSectionSnapshot[] = [];
  let blockIndex = 0;
  for (const node of nodes) {
    if (!isBlockType(node)) continue;
    const id = ids[blockIndex++];
    const level = leaderLevel(node);
    if (level === undefined) continue;
    leaderIds.push(id);
    snapshot.push({
      id,
      kind: node.type.name === 'section_break' ? 'section_break' : 'heading',
      level,
      title: node.type.name === 'heading' ? node.textContent : '',
    });
  }
  return { leaderIds, snapshot };
}

/** Why the ids the editor holds now are not the ones this change meant it to hold, or null when they are. `expected` is one entry per
 * top-level block of the new document in order; an entry left undefined (a block that held no id before the change) is not checked.
 * Exported for api-structural-swap.ts. */
export function idProblem(doc: ProsemirrorNode, expected: ReadonlyArray<string | undefined>): string | null {
  let index = 0;
  let problem: string | null = null;
  doc.forEach((node, pos) => {
    if (problem !== null || !isBlockType(node)) return;
    const want = expected[index];
    if (want !== undefined && getBlockIdAtPos(pos) !== want) {
      problem = `id at block ${index} is not the expected one`;
    }
    index++;
  });
  if (problem === null && index !== expected.length) problem = `blocks=${index} expected=${expected.length}`;
  return problem;
}

/** What the replace's mutator hands back through `runEditorFirstChange` on success. */
interface ReplaceFacts {
  insertedIds: string[];
  insertedLeaderIds: string[];
  insertedSectionsSnapshot: RemovedSectionSnapshot[];
  removedIds: string[];
  removedLeaderIds: string[];
  predecessorId: string | null;
}

/** How `replaceInEditor` is being used. */
interface ReplaceOptions {
  /** 'replace' is the click (the trace line reads `replace-editor-first mode=<m> opId=...`); 'replace-redo' is the quick redo
   * (`replace-redo-editor-first mode=<m> ...`). */
  label: 'replace' | 'replace-redo';
  /** The quick redo only: the registry entry this opId already has (see `runEditorFirstChange`'s `previousEntry`). */
  previousEntry?: UndoRegistryEntry;
  /** The quick redo only, and only when the user typed since its press: asked with the span the replace is about to take out; true
   * (typing sits inside it) refuses the redo (`docChanged`) before anything is dispatched, so the typing is not removed with it. */
  refuseIfTypedInside?: (from: number, to: number) => boolean;
}

const emptyBatch = (): BlockChanges => ({ updates: [], inserts: [], deletes: [] });

const failureReply = (batch: BlockChanges, reason: string): ReplaceRangeResult => ({
  batch,
  ok: false,
  reason,
  insertedIds: [],
  insertedLeaderIds: [],
  insertedSectionsSnapshot: [],
  removedIds: [],
  removedLeaderIds: [],
  predecessorId: null,
});

/** The entry an 'insertAfter' goes after: the explicit anchor, or the last top-level node that is not Notes/Bibliography content
 * (`index` -1 when there is none: the fragment then goes first). */
function findInsertAnchor(
  entries: readonly TopLevelEntry[],
  anchorBlockId: string | null | undefined,
  managedIds: ReadonlySet<string>
): { ok: true; index: number } | { ok: false; reason: 'anchorNotFound' | 'managedAnchor' } {
  if (anchorBlockId === undefined || anchorBlockId === null) {
    let last = -1;
    entries.forEach((entry, index) => {
      if (!isManagedEntry(entry, managedIds)) last = index;
    });
    return { ok: true, index: last };
  }
  const index = entries.findIndex((entry) => entry.id === anchorBlockId);
  if (index < 0) return { ok: false, reason: 'anchorNotFound' };
  if (managedIds.has(anchorBlockId)) return { ok: false, reason: 'managedAnchor' };
  return { ok: true, index };
}

/** The caret position after a whole-document replace: where it was, clamped into the new document and kept out of the bibliography
 * span, as the whole-document push (`setContentWithBlockIds`) does. */
function caretAfterWholeReplace(from: number, newDoc: ProsemirrorNode, payload: ReplaceRangePayload): number {
  let safeFrom = Math.min(from, Math.max(0, newDoc.content.size - 1));
  const boundary = payload.bibBoundaryIndex ?? -1;
  if (boundary < 0) return safeFrom;
  const boundaryEnd = payload.bibBoundaryEndIndex ?? undefined;
  let bibPos = newDoc.content.size;
  let bibEndPos = newDoc.content.size;
  let nodeIndex = 0;
  newDoc.forEach((_node, pos) => {
    if (nodeIndex === boundary) bibPos = pos;
    if (boundaryEnd !== undefined && nodeIndex === boundaryEnd) bibEndPos = pos;
    nodeIndex++;
  });
  if (safeFrom >= bibPos && safeFrom < bibEndPos) safeFrom = Math.max(0, bibPos - 1);
  return safeFrom;
}

/**
 * The one editor-side replace, shared by `replaceRangeEditorFirst` (the click) and `redoReplaceRangeEditorFirst` (the quick redo):
 * the shared turn is `runEditorFirstChange`; the replace's own part, steps (e) and (f) of the header, is the mutator below.
 */
function replaceInEditor(opId: string, payload: ReplaceRangePayload, options: ReplaceOptions): ReplaceRangeResult {
  const { label, previousEntry } = options;
  const mode = payload.mode;
  let refusalDetail = ''; // counts only, for the trace line of a refusal

  const result = runEditorFirstChange<ReplaceFacts>(
    opId,
    label,
    previousEntry,
    (view, savedIds, ctx) => {
      const editorInstance = getEditorInstance();
      if (!editorInstance) return { ok: false, reason: 'noEditor' };
      const doc = view.state.doc;
      const entries = topLevelEntries(doc, savedIds);
      const managed = new Set(payload.managedIds);

      // (e) where the change goes: the positions it replaces (`from === to` for an insertion) and the blocks it takes out.
      let from = 0;
      let to = doc.content.size;
      let removed: TopLevelEntry[] = entries;
      let predecessorId: string | null = null;
      if (mode === 'section') {
        const rootBlockId = payload.rootBlockId ?? '';
        const range = findFlatSectionRange(doc, savedIds, rootBlockId, managed);
        if (!range.ok) return { ok: false, reason: range.reason };
        if (payload.blockIds[0] !== rootBlockId) {
          // The first node of the fragment takes the target heading's id (plan D3); a payload that says otherwise would swap the
          // heading's identity under the sidebar.
          refusalDetail = 'the first id is not the root id';
          return { ok: false, reason: 'idAlignment' };
        }
        ({ from, to, removed, predecessorId } = range);
      } else if (mode === 'insertAfter') {
        const anchor = findInsertAnchor(entries, payload.anchorBlockId, managed);
        if (!anchor.ok) return { ok: false, reason: anchor.reason };
        const anchorEntry = anchor.index >= 0 ? entries[anchor.index] : undefined;
        from = to = anchorEntry ? anchorEntry.pos + anchorEntry.node.nodeSize : 0;
        removed = [];
        for (let i = anchor.index; i >= 0; i--) {
          if (entries[i].id !== undefined) {
            predecessorId = entries[i].id ?? null;
            break;
          }
        }
      } else if (mode !== 'whole') {
        return { ok: false, reason: 'unknownMode' };
      }
      // A quick redo with typing since its press: typing inside the span this replace takes out would be removed with it, so the redo
      // is refused before anything is dispatched (typing elsewhere is simply kept; the replace works on the document as it stands).
      if (from !== to && options.refuseIfTypedInside?.(from, to)) return { ok: false, reason: 'docChanged' };

      // The payload against the editor's own parse, BEFORE anything is dispatched: a refusal here touches nothing.
      const parsed = editorInstance.ctx.get(parserCtx)(payload.markdown);
      const problem = alignmentProblem(parsed, payload);
      if (problem !== null) {
        refusalDetail = problem;
        return { ok: false, reason: 'idAlignment' };
      }
      // The ids every top-level block must hold afterwards, in order: the blocks before the range keep theirs, the range takes the
      // payload's, the blocks after keep theirs (an entry left undefined was a block that held no id; it is not checked).
      const blockIdsOf = (list: readonly TopLevelEntry[]) => list.filter((e) => isBlockType(e.node)).map((e) => e.id);
      const expectedAfter: Array<string | undefined> = [
        ...blockIdsOf(entries.filter((e) => e.pos < from)),
        ...payload.blockIds,
        ...blockIdsOf(entries.filter((e) => e.pos >= to)),
      ];
      const seen = new Set<string>();
      for (const id of expectedAfter) {
        if (id === undefined) continue;
        if (seen.has(id)) {
          refusalDetail = 'an id would be held by two blocks';
          return { ok: false, reason: 'idAlignment' };
        }
        seen.add(id);
      }
      ctx.lap('range');

      const nodes = preparedNodes(parsed, payload);
      const { leaderIds, snapshot } = leadersOf(nodes, payload.blockIds);
      const removedIds: string[] = [];
      const removedLeaderIds: string[] = [];
      for (const entry of removed) {
        if (entry.id === undefined) continue;
        removedIds.push(entry.id);
        if (leaderLevel(entry.node) !== undefined) removedLeaderIds.push(entry.id);
      }
      ctx.lap('collect');

      // `markDispatching` first: from here on a refusal or a throw puts the checkpoint back (the shared turn's `finally`); the
      // managed-id set is not part of what it restores, so this mutator puts that back itself.
      const managedBefore = getManagedBlockIds();
      ctx.markDispatching();
      try {
        // The `structuralReplace` tag is a label for tests and the trace; nothing in production reads it (plan D16). What protects
        // the editor is the shared turn's `setSyncPaused` + `resetAndSnapshot` + the `midOp` guard.
        if (mode === 'whole') {
          const newDoc = parsed.copy(Fragment.fromArray(nodes));
          let tr = buildBlockLevelReplace(view.state.tr, doc, newDoc);
          const caret = caretAfterWholeReplace(view.state.selection.from, newDoc, payload);
          try {
            tr = tr.setSelection(Selection.near(tr.doc.resolve(caret)));
          } catch {
            tr = tr.setSelection(Selection.atStart(tr.doc));
          }
          view.dispatch(tr.setMeta('structuralReplace', true).setMeta('addToHistory', false)); // (f)
          ctx.lap('dispatch');
          // The same id steps as the whole-document push: clear, assign by position with the expected-metadata check, managed set.
          clearBlockIds();
          setBlockIdsForTopLevel(payload.blockIds, view.state.doc, payload.expectedBlocks);
          setManagedBlockIds(payload.managedBlockIds ?? []);
        } else {
          const fragment = Fragment.fromArray(nodes);
          const tr = from === to ? view.state.tr.insert(from, fragment) : view.state.tr.replaceWith(from, to, fragment);
          view.dispatch(tr.setMeta('structuralReplace', true).setMeta('addToHistory', false)); // (f)
          ctx.lap('dispatch');
          // The plugin's `apply` has just given the inserted blocks ids of its own choosing (a kept old id, or a `temp-` one); give
          // them the payload's, in the same synchronous turn, before anything snapshots the document.
          const positions: number[] = [];
          let offset = from;
          for (const node of nodes) {
            if (isBlockType(node)) positions.push(offset);
            offset += node.nodeSize;
          }
          setTopLevelIdsAt(positions, payload.blockIds);
        }
        // `data-block-id` is a decoration that only recomputes on a transaction (api-content.ts `redecorateBlockIds`): without this
        // step-less dispatch the new blocks would paint the ids the plugin gave them, not the payload's.
        view.dispatch(view.state.tr);
        afterReplaceHook?.();

        const idMismatch = idProblem(view.state.doc, expectedAfter);
        if (idMismatch !== null) {
          setManagedBlockIds(managedBefore);
          refusalDetail = idMismatch;
          return { ok: false, reason: 'idAlignment' };
        }
      } catch (e) {
        setManagedBlockIds(managedBefore);
        throw e;
      }

      return {
        ok: true,
        value: {
          insertedIds: payload.blockIds.slice(),
          insertedLeaderIds: leaderIds,
          insertedSectionsSnapshot: snapshot,
          removedIds,
          removedLeaderIds,
          predecessorId,
        },
        traceDetail: `inserted=${payload.blockIds.length} removed=${removedIds.length} leaders=${leaderIds.length}`,
      };
    },
    ` mode=${mode}`
  );

  if (!result.ok) {
    trace(
      `${label}-editor-first mode=${mode} opId=${opId.slice(0, 8)} ok=false reason=${result.reason.slice(0, 200)}` +
        (refusalDetail ? ` detail=${refusalDetail.slice(0, 200)}` : '')
    );
    return failureReply(result.batch, result.reason);
  }
  return { batch: result.batch, ok: true, ...result.value };
}

/**
 * Bridge target for `window.FinalFinal.replaceRangeEditorFirst`. Synchronous; Swift calls it as
 * `JSON.stringify(window.FinalFinal.replaceRangeEditorFirst(opId, payload))` in the same synchronous stretch in which it reserves its
 * writer ticket for the returned batch, so reservation order equals execution order. See `ReplaceRangePayload` for the payload and
 * `ReplaceRangeResult` for the reply. On a refusal or a failure the document is exactly as it was, block-sync runs, no registry
 * entry is left, and the reply still carries the batch the call consumed.
 */
export function replaceRangeEditorFirst(opId: string, payload: ReplaceRangePayload): ReplaceRangeResult {
  return replaceInEditor(opId, payload, { label: 'replace' });
}

/**
 * Bridge target for `window.FinalFinal.redoReplaceRangeEditorFirst`. Synchronous; Swift calls it, with the structural-redo latch held
 * for `opId`, like the duplicate's redo. Re-checks that the live document is still the saved pre-op copy (`checkQuickRedoAllowed`,
 * shared with the delete's and the duplicate's redo; nothing is touched on a refusal: `ok: false`, `reason: 'docChanged'`, an empty
 * batch). Typing since the press elsewhere is kept (it goes out once as batch N); typing inside the text the replace takes out refuses
 * the redo with `docChanged` and the batch carrying that typing. It replaces the range again in the document as it stands NOW, under the same opId, as a fresh editor-first replace.
 * `payload` is the first click's payload (the same ids), so the redo gives the same blocks the same ids [S9].
 */
export function redoReplaceRangeEditorFirst(opId: string, payload: ReplaceRangePayload): ReplaceRangeResult {
  const gate = checkQuickRedoAllowed(opId);
  if ('reason' in gate) {
    trace(`replace-quick-redo mode=${payload.mode} opId=${opId.slice(0, 8)} refused reason=${gate.reason}`);
    return failureReply(emptyBatch(), gate.reason);
  }
  const result = replaceInEditor(opId, payload, {
    label: 'replace-redo',
    previousEntry: gate.entry,
    refuseIfTypedInside: gate.guard,
  });
  finishQuickRedoLine(gate, result.ok);
  // The redo steps the quick undo kept aside (typing done inside the restored text) go back now that the text is back (t-14f908b4).
  if (result.ok) putBackAfterQuickRedo(opId, 'replace-quick-redo', gate.typed);
  return result.ok ? { ...result, typed: gate.typed } : result;
}
