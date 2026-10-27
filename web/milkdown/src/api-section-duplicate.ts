// Editor-first section duplicate -- the editor half of Phase 4b slice 3, round 1d (t-18b7fa48).
//
// Today a Duplicate Section reads the whole document out of the editor, saves all of it, copies the rows in the database and pushes
// the whole document back into the editor; the push overwrites whatever the user typed meanwhile. Here the EDITOR inserts the copy
// first, in one synchronous JavaScript turn, and the database catches up afterwards as a queued write job (Swift side). Nothing is
// pushed back over the user's text. It is the delete's twin (api-section-delete.ts): the same shared turn
// (`runEditorFirstChange`, editor-first-op.ts, whose header lists the steps and says what protects the editor while the change is
// dispatched), the same reply discipline -- the batch of pending edits the call consumed comes back on EVERY path, and Swift always
// applies it -- and the same quick undo (api-section-undo.ts `undoSectionDeleteEditorFirst`, which swaps the pre-op checkpoint back
// in and reports the leaders it removed).
//
// This file supplies the part that is the duplicate's own, steps (e) and (f) of the shared turn:
//   (e) find the SUBTREE range with `findSectionRange` (the same rule the database duplicate uses: the root leader and everything
//       under it, up to the next leader at the same or a higher level, never into Notes or Bibliography), and make the copy of that
//       slice: every top-level block gets a fresh PERMANENT id (the block-id plugin's own UUID generator, never a `temp-` id), and
//       " copy" is appended to the first heading's text ONLY when the root node itself is a heading (a section break as root has no
//       title to suffix; the database does the same, Database+SectionOps.swift `duplicateSections`);
//   (f) dispatch ONE insertion transaction at the end of the range, not added to the text history, then replace the temp ids the
//       plugin gave the inserted blocks with the minted ones (`setTopLevelIdsAt`) and repaint the ids. The skeleton then
//       re-baselines block-sync on the document WITH the permanent ids, so the copies are never reported as inserts and typing in a
//       copy later is an UPDATE of the copy's permanent id.
// The reply is `ok: false` with the batch on a refusal or a failure, so Swift's failure alert is true (the document is as it was and
// block-sync queued nothing). A managed root (Notes, Bibliography) is refused: nothing dispatched, no registry entry left.
//
// The quick REDO (`redoSectionDuplicateEditorFirst`) is a fresh duplicate of the document as it stands now, under the same opId,
// that REUSES the ids of the first click's `copies` [S9]: the database job writes those ids again, so a later Cmd-Z of something
// done to the copy, or a delete of the copy redone after it, still finds the rows it expects.

import { Fragment, type Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import { findSectionRange, leaderLevel, type RemovedSectionSnapshot } from './api-section-delete';
import { checkQuickRedoAllowed, putBackAfterQuickRedo } from './api-section-undo';
import { generateBlockId, isBlockType, setTopLevelIdsAt } from './block-id-plugin';
import type { BlockChanges } from './block-sync-plugin';
import { runEditorFirstChange, trace } from './editor-first-op';
import type { UndoRegistryEntry } from './undo-coordinator';

/** One copied top-level block: the id the SOURCE block had in the editor at the click (a temp id when Swift had not confirmed it
 * yet; '' only if the editor held none), and the permanent id the copy got. */
export interface DuplicatedBlock {
  sourceId: string;
  newId: string;
}

/** One section leader of the copy, for Swift's sidebar bookkeeping. Same shape as the delete's `RemovedSectionSnapshot`: `title`
 * is the copy's own text (the root heading's text WITH " copy"), `level` a heading's own level or 1 for a section break. */
export type InsertedSectionSnapshot = RemovedSectionSnapshot;

/** What `duplicateSectionEditorFirst` and `redoSectionDuplicateEditorFirst` return, on every path. Swift reads it as
 * `JSON.stringify(...)`, like `getBlockChanges`. */
export interface DuplicateSectionResult {
  /** Every pending edit this call consumed, in `getBlockChanges()` shape. Empty when nothing was pending, and on a redo refusal
   * (the gate consumes nothing). Swift always applies a returned batch. */
  batch: BlockChanges;
  ok: boolean;
  /** Why `ok` is false: 'noEditor', 'beginFailed', 'rootNotFound', 'managedRoot', 'rootNotLeader', 'notInFlight', 'noEntry',
   * 'midOp', 'docChanged' (the last four are the redo's gate), or 'exception: <message>'. */
  reason?: string;
  /** One entry per copied top-level block (leaders and body), in document order. The order is the order of the source range, which
   * is also the order of the database subtree, so Swift matches it against the subtree's rows by position. */
  copies: DuplicatedBlock[];
  /** The subset of the copies' new ids that are section leaders (headings and section breaks), in document order. */
  insertedLeaderIds: string[];
  /** One entry per copied leader, in document order. */
  insertedSectionsSnapshot: InsertedSectionSnapshot[];
  /** Id of the block the copy sits directly after: the last block of the ORIGINAL section that has an id (null if none has). */
  predecessorId: string | null;
}

// Test seam (web tests only; production never sets it): runs right after the insertion was dispatched and its ids replaced, before
// block-sync is re-baselined. A throw from it exercises the failure path a real error after the dispatch would take.
let afterInsertHook: (() => void) | null = null;
export function setTestAfterInsertHook(hook: (() => void) | null): void {
  afterInsertHook = hook;
}

/** How `duplicateInEditor` is being used. */
interface DuplicateOptions {
  /** 'duplicate' is the click (the trace line reads `duplicate-editor-first`); 'duplicate-redo' is the quick redo
   * (`duplicate-redo-editor-first`). */
  label: 'duplicate' | 'duplicate-redo';
  /** The quick redo only: the registry entry this opId already has (see `runEditorFirstChange`'s `previousEntry`). */
  previousEntry?: UndoRegistryEntry;
  /** The quick redo only: the `copies` of the first click. The i-th copied block takes the i-th entry's `newId`; a block with no
   * entry (the editor cannot have a different block count here, the re-check passed, but a short list must not fail the redo)
   * gets a freshly minted id. Only the NEW ids are used: the source ids may have been confirmed since. */
  reuseCopies?: readonly DuplicatedBlock[];
}

/** What the duplicate's mutator hands back through `runEditorFirstChange` on success. */
interface DuplicateFacts {
  copies: DuplicatedBlock[];
  insertedLeaderIds: string[];
  insertedSectionsSnapshot: InsertedSectionSnapshot[];
  predecessorId: string | null;
}

/** `node` with " copy" appended to its text, as plain text after whatever the heading already holds (the database appends the
 * suffix to the heading's Markdown fragment, so it never carries a mark either). */
function withCopySuffix(node: ProsemirrorNode): ProsemirrorNode {
  const suffix = node.type.schema.text(' copy');
  return node.copy(node.content.append(Fragment.from(suffix)));
}

/** A copy of a figure with its own id on the `blockId` attr: the attr is what the DOM paints until the next decoration pass, and a
 * copy must not paint the SOURCE's id. (The id map outranks the attr whenever it holds a permanent id, image-plugin.ts.) */
function withBlockIdAttr(node: ProsemirrorNode, id: string): ProsemirrorNode {
  return node.type.create({ ...node.attrs, blockId: id }, node.content, node.marks);
}

/**
 * The one editor-side duplicate, shared by `duplicateSectionEditorFirst` (the click) and `redoSectionDuplicateEditorFirst` (the
 * quick redo): the shared turn is `runEditorFirstChange`; the duplicate's own part, steps (e) and (f) of the header, is the mutator
 * below.
 */
function duplicateInEditor(
  opId: string,
  rootBlockId: string,
  managedIds: string[],
  options: DuplicateOptions
): DuplicateSectionResult {
  const { label, previousEntry, reuseCopies } = options;
  const result = runEditorFirstChange<DuplicateFacts>(opId, label, previousEntry, (view, savedIds, ctx) => {
    const range = findSectionRange(view.state.doc, savedIds, rootBlockId, new Set(managedIds)); // (e)
    if (!range.ok) return { ok: false, reason: range.reason };
    ctx.lap('range');

    const rootIsHeading = range.removed[0].node.type.name === 'heading';
    const copies: DuplicatedBlock[] = [];
    const insertedSectionsSnapshot: InsertedSectionSnapshot[] = [];
    const nodes: ProsemirrorNode[] = [];
    const idPositions: number[] = []; // document positions the copied blocks will start at once inserted
    const idsAtPositions: string[] = [];
    let offsetInCopy = 0;
    let reusedCount = 0;
    for (let i = 0; i < range.removed.length; i++) {
      const source = range.removed[i];
      let node = source.node;
      let newId: string | undefined;
      if (isBlockType(node)) {
        const reused = reuseCopies?.[copies.length]?.newId;
        if (reused !== undefined) reusedCount++;
        newId = reused ?? generateBlockId();
        copies.push({ sourceId: source.id ?? '', newId });
        if (node.type.name === 'figure') node = withBlockIdAttr(node, newId);
      }
      if (i === 0 && rootIsHeading) node = withCopySuffix(node);
      if (newId !== undefined) {
        idPositions.push(range.to + offsetInCopy);
        idsAtPositions.push(newId);
        const level = leaderLevel(node);
        if (level !== undefined) {
          insertedSectionsSnapshot.push({
            id: newId,
            kind: node.type.name === 'section_break' ? 'section_break' : 'heading',
            level,
            title: node.type.name === 'heading' ? node.textContent : '',
          });
        }
      }
      nodes.push(node);
      offsetInCopy += node.nodeSize;
    }
    if (reuseCopies && reusedCount !== copies.length) {
      // The re-check passed, so the block count should match; a mismatch only means some copies got fresh ids. Counts only.
      trace(`${label}-editor-first opId=${opId.slice(0, 8)} reused ${reusedCount} of ${copies.length} ids`);
    }

    // The last block of the original section that has an id: the block the copy sits directly after.
    let predecessorId: string | null = null;
    for (let i = range.removed.length - 1; i >= 0; i--) {
      const id = range.removed[i].id;
      if (id !== undefined) {
        predecessorId = id;
        break;
      }
    }
    ctx.lap('collect');

    // `markDispatching` first: from here on a throw puts the checkpoint back (the skeleton's `finally`).
    ctx.markDispatching();
    const fragment = Fragment.fromArray(nodes);
    // The `structuralDuplicate` tag is a label for tests and the trace; nothing in production reads it (plan D16). What protects
    // the editor is the skeleton's `setSyncPaused` + `resetAndSnapshot` + the `midOp` guard.
    view.dispatch(
      view.state.tr.insert(range.to, fragment).setMeta('structuralDuplicate', true).setMeta('addToHistory', false)
    ); // (f)
    ctx.lap('dispatch');
    // The plugin's `apply` has just given the inserted blocks `temp-` ids; replace them with the minted permanent ones, in the
    // same synchronous turn, before anything snapshots the document.
    setTopLevelIdsAt(idPositions, idsAtPositions);
    // `data-block-id` is a decoration that only recomputes on a transaction (api-content.ts `redecorateBlockIds`): without this
    // step-less dispatch the copies would paint their temp ids, and a Cmd-click on a copied heading would zoom on a dead id.
    view.dispatch(view.state.tr);
    afterInsertHook?.();

    return {
      ok: true,
      value: {
        copies,
        insertedLeaderIds: insertedSectionsSnapshot.map((s) => s.id),
        insertedSectionsSnapshot,
        predecessorId,
      },
      traceDetail: `copied=${copies.length} leaders=${insertedSectionsSnapshot.length}`,
    };
  });

  if (!result.ok) {
    return {
      batch: result.batch,
      ok: false,
      reason: result.reason,
      copies: [],
      insertedLeaderIds: [],
      insertedSectionsSnapshot: [],
      predecessorId: null,
    };
  }
  return { batch: result.batch, ok: true, ...result.value };
}

/**
 * Bridge target for `window.FinalFinal.duplicateSectionEditorFirst`. Synchronous; Swift calls it as
 * `JSON.stringify(window.FinalFinal.duplicateSectionEditorFirst(opId, rootBlockId, managedIds))` in the same synchronous stretch in
 * which it reserves its writer ticket for the returned batch, so reservation order equals execution order. `managedIds` is the list
 * of block ids Swift's database flags Notes or Bibliography (never empty on a real document).
 */
export function duplicateSectionEditorFirst(
  opId: string,
  rootBlockId: string,
  managedIds: string[]
): DuplicateSectionResult {
  return duplicateInEditor(opId, rootBlockId, managedIds, { label: 'duplicate' });
}

/**
 * Bridge target for `window.FinalFinal.redoSectionDuplicateEditorFirst`. Synchronous; Swift calls it, with the structural-redo latch
 * held for `opId`, like the delete's redo. Re-checks that the live document is still the saved pre-op copy
 * (`checkQuickRedoAllowed`, shared with the delete's redo; nothing is touched on a refusal: `ok: false`, `reason: 'docChanged'`,
 * an empty batch), then duplicates the section again from the document as it is NOW, under the same opId, as a fresh editor-first
 * duplicate. `copies` is the first click's `copies`: the new blocks take those ids again [S9].
 */
export function redoSectionDuplicateEditorFirst(
  opId: string,
  rootBlockId: string,
  managedIds: string[],
  copies?: DuplicatedBlock[]
): DuplicateSectionResult {
  const gate = checkQuickRedoAllowed(opId);
  if ('reason' in gate) {
    trace(`duplicate-quick-redo opId=${opId.slice(0, 8)} refused reason=${gate.reason}`);
    return {
      batch: { updates: [], inserts: [], deletes: [] },
      ok: false,
      reason: gate.reason,
      copies: [],
      insertedLeaderIds: [],
      insertedSectionsSnapshot: [],
      predecessorId: null,
    };
  }
  const result = duplicateInEditor(opId, rootBlockId, managedIds, {
    label: 'duplicate-redo',
    previousEntry: gate.entry,
    reuseCopies: copies,
  });
  // The redo steps the quick undo kept aside (typing done inside the copy) go back now that the copy is back (t-14f908b4).
  if (result.ok) putBackAfterQuickRedo(opId, 'duplicate-quick-redo');
  return result;
}
