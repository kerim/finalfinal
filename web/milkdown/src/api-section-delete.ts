// Editor-first section delete -- the editor half of Phase 4b part 2, slice 2a (t-94369a83).
//
// Today a section delete reads the whole document out of the editor, saves all of it, deletes the rows in the database and
// pushes the whole document back into the editor; the push overwrites whatever the user typed meanwhile. Here the EDITOR removes
// the section first, in one synchronous JavaScript turn, and the database catches up afterwards as a queued write job (Swift side,
// StructuralUndoController). Nothing is pushed back over the user's text.
//
// `deleteSectionEditorFirst` is that one turn. Swift reserves its writer ticket for the batch this call returns and submits the
// call in the same synchronous stretch (plan D1 step 3), so reservation order equals execution order. The call returns the batch
// of pending edits it consumed on EVERY path -- success, refusal and failure alike -- and Swift always applies a returned batch,
// because the consumed edits are gone from the editor's queue.
//
// What it does, in order (plan D1 step 3 (a)-(j), addendum A6/A12): the skeleton -- flush, take the batch, pause block-sync, begin the
// structural op, copy the id maps, re-baseline, resume, finalize, and the put-back if anything throws after the dispatch -- is
// `runEditorFirstChange` (editor-first-op.ts, shared with every other editor-first operation; its header lists the steps and says
// what protects the editor while the change is dispatched). This file supplies the one part that is the delete's own:
//   (e) find the range (see `findSectionRange`);
//   (f) dispatch ONE removal transaction, tagged `structuralRemoval`, not added to the text history.
// The reply is `ok: false` with the batch on a refusal or a failure, so Swift's failure alert is true (the section is on screen and
// block-sync queued no deletes).

import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import type { BlockChanges } from './block-sync-plugin';
import { runEditorFirstChange } from './editor-first-op';
import { noteRemovalForPaint } from './typing-trace';
import type { UndoRegistryEntry } from './undo-coordinator';

/** One section leader the removal took out, for Swift's sidebar bookkeeping. */
export interface RemovedSectionSnapshot {
  id: string;
  kind: 'heading' | 'section_break';
  /** Effective level: a heading's own level, 1 for a section break (the database's `headingLevel ?? 1`). */
  level: number;
  /** A heading's text; empty for a section break. */
  title: string;
}

/** What `deleteSectionEditorFirst` returns, on every path. Swift reads it as `JSON.stringify(...)`, like `getBlockChanges`. */
export interface DeleteSectionResult {
  /** Every pending edit this call consumed, in `getBlockChanges()` shape. Empty when nothing was pending. */
  batch: BlockChanges;
  ok: boolean;
  /** Why `ok` is false: 'noEditor', 'beginFailed', 'rootNotFound', 'managedRoot', 'rootNotLeader', or 'exception: <message>'. */
  reason?: string;
  /** Block ids of every top-level node the removal took out (leaders and body), in document order. */
  removedIds: string[];
  /** The subset of `removedIds` that are section leaders (headings and section breaks). */
  removedLeaderIds: string[];
  /** Id of the nearest block before the removed range that has one, or null when the range began the document. */
  predecessorId: string | null;
  /** One entry per removed leader, in document order. */
  removedSectionsSnapshot: RemovedSectionSnapshot[];
  /** The quick REDO only, on an `ok: true` reply: true when the user typed since the key was pressed (the page's own answer, from the
   * redo's gate), absent on every other reply. A non-empty `batch` is not proof of typing (it can hold a rewrite the previous command's
   * settle left); Swift ends the older redo entries only when this is true. */
  typed?: boolean;
}

/** One top-level node of the document with the block id the block-id plugin holds for it (undefined for the marker atoms,
 * which sit outside the plugin's allowlist, and for any block that has no id yet). */
export interface TopLevelEntry {
  node: ProsemirrorNode;
  pos: number;
  id: string | undefined;
}

export type SectionRange =
  | {
      ok: true;
      /** Document positions: `from` is before the root leader, `to` is after the last removed node. */
      from: number;
      to: number;
      removed: TopLevelEntry[];
      predecessorId: string | null;
    }
  | { ok: false; reason: 'rootNotFound' | 'managedRoot' | 'rootNotLeader' };

/** A leader's effective level: headings by their own level, section breaks as level 1; `undefined` for anything else (an `hr`
 * is NOT a leader). Mirrors the database rule `leader = heading || pseudo-section, level = headingLevel ?? 1`
 * (Database+SectionOps.swift `resolveSectionSubtree`). */
export function leaderLevel(node: ProsemirrorNode): number | undefined {
  if (node.type.name === 'heading') return (node.attrs.level as number | undefined) ?? 1;
  if (node.type.name === 'section_break') return 1;
  return undefined;
}

/** Notes/Bibliography content: a block whose id Swift passed as managed, or one of the two bibliography marker atoms (they carry no
 * block id, so Swift's list cannot name them, and the opening marker sits directly before the Bibliography heading). */
export function isManagedEntry(entry: TopLevelEntry, managedIds: ReadonlySet<string>): boolean {
  const name = entry.node.type.name;
  if (name === 'auto_bibliography' || name === 'auto_bibliography_end') return true;
  return entry.id !== undefined && managedIds.has(entry.id);
}

/**
 * The one shared rule for "the section" (plan D1.0), JS side. Leaders are headings and section breaks (level 1), never `hr`. The
 * range runs from the root leader up to, not including, the next leader at the same or a higher level (a smaller or equal level
 * number), so deeper leaders and everything under them belong to it whatever levels were skipped. It never includes Notes or
 * Bibliography content and stops before the first such node. `managedIds` is Swift's list, read from the database at the click;
 * JS never trusts its own managed set (the block-id plugin's copy is replaced wholesale by every push and can be stale).
 */
export function findSectionRange(
  doc: ProsemirrorNode,
  ids: ReadonlyMap<number, string>,
  rootBlockId: string,
  managedIds: ReadonlySet<string>
): SectionRange {
  const entries: TopLevelEntry[] = [];
  doc.forEach((node, pos) => {
    entries.push({ node, pos, id: ids.get(pos) });
  });

  const rootIndex = entries.findIndex((entry) => entry.id === rootBlockId);
  if (rootIndex < 0) return { ok: false, reason: 'rootNotFound' };
  if (managedIds.has(rootBlockId)) return { ok: false, reason: 'managedRoot' };
  const rootLevel = leaderLevel(entries[rootIndex].node);
  if (rootLevel === undefined) return { ok: false, reason: 'rootNotLeader' };

  let end = rootIndex + 1;
  while (end < entries.length) {
    const entry = entries[end];
    if (isManagedEntry(entry, managedIds)) break;
    const level = leaderLevel(entry.node);
    if (level !== undefined && level <= rootLevel) break;
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

// Test seam (web tests only; production never sets it): runs right after the removal was dispatched, before block-sync is
// re-baselined. A throw from it exercises the failure path a real error after the dispatch would take (addendum A6, W10).
let afterRemovalHook: (() => void) | null = null;
export function setTestAfterRemovalHook(hook: (() => void) | null): void {
  afterRemovalHook = hook;
}

/** How `removeSectionInEditor` is being used. */
export interface RemoveSectionOptions {
  /** 'delete' is the click (the trace line reads `delete-editor-first`); 'redo' is the quick redo of a quick-undone delete
   * (`redo-editor-first`), which removes the section again from the CURRENT document under the same opId. */
  label: 'delete' | 'redo';
  /** The quick redo only (api-section-undo.ts): the registry entry this opId already has. `runEditorFirstChange` deletes it from
   * the registry right before `beginStructuralOp(opId)`, so the redone entry becomes the NEWEST key (the saved-copy rebase targets
   * the last key, undo-coordinator.ts `advanceRegistryEntries`; plan v3 D8), and puts it back untouched if the removal does not
   * complete: a failed redo leaves the op undone with the entry it had, so a later press still routes. */
  previousEntry?: UndoRegistryEntry;
  /** The quick redo only, and only when the user typed since its press: asked with the span the removal is about to take out; true
   * (typing sits inside it) refuses the redo (`docChanged`) before anything is dispatched, so the typing is not removed with it. */
  refuseIfTypedInside?: (from: number, to: number) => boolean;
}

/** What the delete's mutator hands back through `runEditorFirstChange` on success. */
interface RemovalFacts {
  removedIds: string[];
  removedLeaderIds: string[];
  predecessorId: string | null;
  removedSectionsSnapshot: RemovedSectionSnapshot[];
}

/**
 * The one editor-side removal, shared by `deleteSectionEditorFirst` (the click) and `redoSectionDeleteEditorFirst` (the quick
 * redo of an undone delete): the shared turn is `runEditorFirstChange` (editor-first-op.ts); the delete's own part, steps (e) and
 * (f) of the header, is the mutator below. A redo is a fresh delete of the document as it stands now, so it re-captures
 * `checkpoint`, `preOpDoc`, `postOpDoc` and the block-id maps for the opId and starts a fresh confirmation log; nothing stored at
 * the undo is swapped in (a stored state would put back labels and Notes the automatic rewrites have since changed).
 */
export function removeSectionInEditor(
  opId: string,
  rootBlockId: string,
  managedIds: string[],
  options: RemoveSectionOptions
): DeleteSectionResult {
  const { label, previousEntry } = options;
  const result = runEditorFirstChange<RemovalFacts>(opId, label, previousEntry, (view, savedIds, ctx) => {
    const range = findSectionRange(view.state.doc, savedIds, rootBlockId, new Set(managedIds)); // (e)
    if (!range.ok) return { ok: false, reason: range.reason };
    if (options.refuseIfTypedInside?.(range.from, range.to)) return { ok: false, reason: 'docChanged' };
    ctx.lap('range');

    const removedIds: string[] = [];
    const removedLeaderIds: string[] = [];
    const removedSectionsSnapshot: RemovedSectionSnapshot[] = [];
    for (const entry of range.removed) {
      if (entry.id !== undefined) removedIds.push(entry.id);
      const level = leaderLevel(entry.node);
      if (level !== undefined && entry.id !== undefined) {
        removedLeaderIds.push(entry.id);
        removedSectionsSnapshot.push({
          id: entry.id,
          kind: entry.node.type.name === 'section_break' ? 'section_break' : 'heading',
          level,
          title: entry.node.type.name === 'heading' ? entry.node.textContent : '',
        });
      }
    }

    ctx.lap('collect');

    ctx.markDispatching();
    // The `structuralRemoval` tag protects nothing: it is a label for the tests and the trace, and no production code reads it
    // (plan D16). What protects the editor is `setSyncPaused` + `resetAndSnapshot` + the `midOp` guard in `runEditorFirstChange`.
    view.dispatch(
      view.state.tr.delete(range.from, range.to).setMeta('structuralRemoval', true).setMeta('addToHistory', false)
    ); // (f)
    ctx.lap('dispatch');
    noteRemovalForPaint(opId);
    afterRemovalHook?.();

    return {
      ok: true,
      value: { removedIds, removedLeaderIds, predecessorId: range.predecessorId, removedSectionsSnapshot },
      traceDetail: `removed=${removedIds.length} leaders=${removedLeaderIds.length}`,
    };
  });

  if (!result.ok) {
    return {
      batch: result.batch,
      ok: false,
      reason: result.reason,
      removedIds: [],
      removedLeaderIds: [],
      predecessorId: null,
      removedSectionsSnapshot: [],
    };
  }
  return {
    batch: result.batch,
    ok: true,
    removedIds: result.value.removedIds,
    removedLeaderIds: result.value.removedLeaderIds,
    predecessorId: result.value.predecessorId,
    removedSectionsSnapshot: result.value.removedSectionsSnapshot,
  };
}

/**
 * Bridge target for `window.FinalFinal.deleteSectionEditorFirst`. Synchronous; Swift calls it as
 * `JSON.stringify(window.FinalFinal.deleteSectionEditorFirst(opId, rootBlockId, managedIds))`.
 * `managedIds` is the list of block ids Swift's database flags Notes or Bibliography (never empty on a real document).
 */
export function deleteSectionEditorFirst(opId: string, rootBlockId: string, managedIds: string[]): DeleteSectionResult {
  return removeSectionInEditor(opId, rootBlockId, managedIds, { label: 'delete' });
}
