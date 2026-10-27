// The editor's REDO branch across changes that would otherwise throw it away (quick-undo-section-delete, redo-history fix).
//
// Two places lose it today, and both are fixed here with the same few lines of prosemirror-history 1.5.0 internals, kept in this
// one file and pinned by quick-undo-redo-history.test.ts (QU19p: the version, `Branch.addMaps`, the `historyState` meta protocol):
//   * the quick undo of a section delete swaps in the whole EditorState saved before the delete, history plugin state included
//     (api-section-undo.ts). `carryRedoBranch` builds the history state that swap should have: the checkpoint's undo branch, and the
//     LIVE redo branch mapped onto the checkpoint document;
//   * a recorded `derivedCorrection` step (the footnote renumber, the heading-level correction) empties the redo branch, because
//     prosemirror-history empties it on any step it records. `dispatchDerivedCorrection` keeps the step recorded (the footnote
//     undo checkpoints need "undo the renumber" to be its own Cmd-Z) and puts the branch back, mapped through the step.
// Real typing still empties the branch: nothing else calls these.
//
// A third piece (t-14f908b4) fixes what the first one still loses. The carry maps the live redo branch onto the PRE-operation
// document, and for the operations that ADD text (Duplicate Section, Insert as New Section, Replace Current Section, Restore Entire
// Project) every redo step the user made inside that text lies in a range the carry removes, so prosemirror-history drops it when
// the branch is mapped: undo the typing, undo the operation, redo the operation, and the typing could not be redone. So the quick
// undo also keeps the live redo branch ASIDE, untouched and in post-operation coordinates (`setAsideRedoBranch`, one record per
// operation id, held here and not on the registry entry: the entry is replaced by spread copies many times between an undo and its
// redo), and the quick redo, once it has run the operation again, puts it back (`putBackSetAsideRedo`), mapped through the small
// difference between the document it belongs to and the document the redo produced (none, when they are equal). The carry stays
// as it is: it is the redo list while the operation is undone, and the fall-back when the put-back refuses.
//
// The history plugin is reached the way `clearEditorHistory` (api-content.ts) reaches it: through `pluginsByKey.history$`. A new
// history state is handed to it through its own meta protocol: a transaction carrying `{ historyState }` under the plugin's key
// makes it adopt that state as it is (`applyTransaction` returns `historyTr.historyState`).

import { closeHistory } from '@milkdown/kit/prose/history';
import type { Node } from '@milkdown/kit/prose/model';
import type { EditorState, Plugin, Transaction } from '@milkdown/kit/prose/state';
import { type StepMap, Transform } from '@milkdown/kit/prose/transform';
import type { EditorView } from '@milkdown/kit/prose/view';

/** prosemirror-history's `Branch` (the undo or the redo stack), as far as this file uses it. */
export interface HistoryBranch {
  readonly eventCount: number;
  /** A branch with `maps` appended: the steps in it are mapped through them when the branch is popped. */
  addMaps(maps: readonly StepMap[]): HistoryBranch;
}

/** prosemirror-history's `HistoryState` (the history plugin's state field). */
export interface HistoryStateLike {
  done: HistoryBranch;
  undone: HistoryBranch;
  prevRanges: number[] | null;
  prevTime: number;
  prevComposition: number;
}

function historyOf(state: EditorState): { plugin: Plugin; history: HistoryStateLike } | null {
  const pluginsByKey = (state as unknown as { config: { pluginsByKey?: Record<string, Plugin> } }).config.pluginsByKey;
  const plugin = pluginsByKey?.history$;
  const history = plugin?.getState(state) as HistoryStateLike | undefined;
  return plugin && history ? { plugin, history } : null;
}

/** `history` with another redo branch. With `closeGroup` the typing-group fields are reset the way `closeHistory` resets them, so
 * the next keystroke opens a new undo group. */
function withUndone(history: HistoryStateLike, undone: HistoryBranch, closeGroup: boolean): HistoryStateLike {
  const reset = closeGroup ? { prevRanges: null, prevTime: 0, prevComposition: -1 } : {};
  return Object.assign(Object.create(Object.getPrototypeOf(history)), history, { undone }, reset);
}

/** The state's redo branch, or null when it has nothing to redo (or there is no history plugin). */
export function redoBranchOf(state: EditorState): HistoryBranch | null {
  const branch = historyOf(state)?.history.undone;
  return branch && branch.eventCount > 0 ? branch : null;
}

/**
 * Dispatches an automatic correction (`derivedCorrection`) as its own recorded text-undo step, isolated on both history
 * boundaries, WITHOUT emptying the redo branch.
 *
 * Leading boundary: `closeHistory` resets prevTime to 0 BEFORE the correction applies, so it can never join the user's still-open
 * typing group. Trailing boundary: without a second history reset, the state left by the correction stores prevTime = the
 * correction's own time, so the user's very next keystroke within newGroupDelay (500 ms) at an adjacent position (right after the
 * first corrected marker: "user resumes typing right where the correction just happened", the common case) would join the
 * correction's own undo group, and the one Cmd-Z that should take back only the typing would take back the correction with it.
 * The branch comes back through the same dispatch as that second reset.
 */
export function dispatchDerivedCorrection(view: EditorView, tr: Transaction): void {
  const kept = redoBranchOf(view.state);
  view.dispatch(closeHistory(tr.setMeta('derivedCorrection', true)));
  if (!kept || !reattachRedoBranch(view, kept, tr.mapping.maps)) view.dispatch(closeHistory(view.state.tr));
}

/** Puts `kept` back as the redo branch after a recorded step emptied it, mapped through the step's `maps`, and closes the typing
 * group (what `closeHistory` does) in the same dispatch. False when the view has no history plugin: nothing was dispatched. */
function reattachRedoBranch(view: EditorView, kept: HistoryBranch, maps: readonly StepMap[]): boolean {
  const found = historyOf(view.state);
  if (!found) return false;
  const historyState = withUndone(found.history, kept.addMaps(maps), true);
  view.dispatch(view.state.tr.setMeta(found.plugin, { redo: false, historyState }));
  return true;
}

/** What `carryRedoBranch` hands back: the transaction meta to dispatch on the restored state, or why the branch was not carried. */
export type RedoCarry =
  | { carried: true; plugin: Plugin; historyState: HistoryStateLike; events: number }
  | { carried: false; reason: string };

interface Block {
  node: Node;
  pos: number;
  id: string | undefined;
}

interface Edit {
  /** Position in the LIVE document (before any edit is applied; edits run from the end of the document backwards). */
  from: number;
  /** An insertion runs after any other edit at the same position. */
  insertion: boolean;
  apply: (tr: Transform) => void;
}

function blocksOf(doc: Node, ids: ReadonlyMap<number, string>): Block[] {
  const blocks: Block[] = [];
  doc.forEach((node, pos) => {
    blocks.push({ node, pos, id: ids.get(pos) });
  });
  return blocks;
}

/** The top-level blocks both documents hold, as (live index, restored index) pairs, matched by block id and in order in both. */
function anchorPairs(live: Block[], restored: Block[]): Array<[number, number]> {
  const restoredIndex = new Map<string, number>();
  const duplicated = new Set<string>();
  restored.forEach((block, j) => {
    if (block.id === undefined) return;
    if (restoredIndex.has(block.id)) duplicated.add(block.id);
    else restoredIndex.set(block.id, j);
  });
  const pairs: Array<[number, number]> = [];
  let last = -1;
  live.forEach((block, i) => {
    if (block.id === undefined || duplicated.has(block.id)) return;
    const j = restoredIndex.get(block.id);
    if (j !== undefined && j > last) {
      pairs.push([i, j]);
      last = j;
    }
  });
  return pairs;
}

/** Edits that turn `a` (at `pos` in the live document) into `b`. A node that has content and differs from `b` only in its own
 * attributes (a heading slug) becomes an attribute change on that node (`setNodeMarkup`), which keeps every position inside it,
 * and the same goes for each of its children in turn. A text node or a leaf node that differs (a changed run of text, a
 * `footnote_ref` with another label) is replaced as a whole: a position strictly inside it collapses, a position at its edge (the
 * caret right after a footnote reference) is kept. So is a node whose type or child count differs. */
function syncNode(a: Node, b: Node, pos: number, edits: Edit[]): void {
  if (a === b || a.eq(b)) return;
  if (a.type !== b.type || a.isLeaf || a.childCount !== b.childCount) {
    edits.push({ from: pos, insertion: false, apply: (tr) => tr.replaceWith(pos, pos + a.nodeSize, b) });
    return;
  }
  if (!a.sameMarkup(b)) {
    edits.push({ from: pos, insertion: false, apply: (tr) => tr.setNodeMarkup(pos, undefined, b.attrs, b.marks) });
  }
  let childPos = pos + 1;
  for (let k = 0; k < a.childCount; k++) {
    syncNode(a.child(k), b.child(k), childPos, edits);
    childPos += a.child(k).nodeSize;
  }
}

/**
 * Steps that turn the live document into the restored one without collapsing the positions of any block both hold: the blocks
 * only the restored document has (the deleted section, the Notes definitions its footnotes left) go in as their own insertion
 * steps, a block that exists on both sides is changed in place (`syncNode`), and a block only the live document has is removed.
 * Blocks are matched by their block id. One whole-document replace would do the same to the DOCUMENT but collapse every position
 * inside it, and prosemirror-history then drops each redo step at redo time without a word.
 */
function stepsToRestoredDocument(
  live: Node,
  liveIds: ReadonlyMap<number, string>,
  restored: Node,
  restoredIds: ReadonlyMap<number, string>
): Transform {
  const liveBlocks = blocksOf(live, liveIds);
  const restoredBlocks = blocksOf(restored, restoredIds);
  const edits: Edit[] = [];
  let liveNext = 0;
  let restoredNext = 0;
  const gap = (liveEnd: number, restoredEnd: number) => {
    if (liveEnd === liveNext && restoredEnd === restoredNext) return;
    const from = liveNext < liveBlocks.length ? liveBlocks[liveNext].pos : live.content.size;
    const last = liveBlocks[liveEnd - 1];
    const to = liveEnd > liveNext ? last.pos + last.node.nodeSize : from;
    const nodes = restoredBlocks.slice(restoredNext, restoredEnd).map((block) => block.node);
    edits.push({ from, insertion: to === from, apply: (tr) => tr.replaceWith(from, to, nodes) });
  };
  for (const [i, j] of anchorPairs(liveBlocks, restoredBlocks)) {
    gap(i, j);
    syncNode(liveBlocks[i].node, restoredBlocks[j].node, liveBlocks[i].pos, edits);
    liveNext = i + 1;
    restoredNext = j + 1;
  }
  gap(liveBlocks.length, restoredBlocks.length);

  edits.sort((x, y) => y.from - x.from || Number(x.insertion) - Number(y.insertion));
  const transform = new Transform(live);
  for (const edit of edits) edit.apply(transform);
  return transform;
}

/**
 * The history state the quick undo of a section delete should leave behind: the restored (checkpoint) state's history, plus the
 * redo branch the live state holds right now, mapped onto the restored document. `liveIds` and `restoredIds` are the block-id
 * maps (position to id) of the two documents. Returns null when the live state has nothing to redo. Never throws; any failure
 * (an exception, a document that is not the restored one, a branch whose event count changed) comes back as `carried: false` and
 * the caller falls back to the plain swap, which loses the redo branch and nothing else.
 */
export function carryRedoBranch(
  live: EditorState,
  restored: EditorState,
  liveIds: ReadonlyMap<number, string>,
  restoredIds: ReadonlyMap<number, string>
): RedoCarry | null {
  const liveHistory = historyOf(live);
  const restoredHistory = historyOf(restored);
  const branch = liveHistory?.history.undone;
  if (!branch || branch.eventCount === 0 || !restoredHistory) return null;
  try {
    const transform = stepsToRestoredDocument(live.doc, liveIds, restored.doc, restoredIds);
    if (!transform.doc.eq(restored.doc))
      return { carried: false, reason: 'the steps do not produce the restored document' };
    const undone = branch.addMaps(transform.mapping.maps);
    if (undone.eventCount !== branch.eventCount) {
      return {
        carried: false,
        reason: `event count ${undone.eventCount} after the carry, ${branch.eventCount} before`,
      };
    }
    return {
      carried: true,
      plugin: restoredHistory.plugin,
      historyState: withUndone(restoredHistory.history, undone, false),
      events: branch.eventCount,
    };
  } catch (e) {
    return { carried: false, reason: `exception: ${e instanceof Error ? e.message : String(e)}` };
  }
}

/** The transaction meta that makes the history plugin adopt a carried history state. */
export function setCarriedHistory(tr: Transaction, carry: Extract<RedoCarry, { carried: true }>): Transaction {
  return tr.setMeta(carry.plugin, { redo: false, historyState: carry.historyState });
}

// === The redo branch set aside across a quick undo, and put back after the quick redo (t-14f908b4) ===

/** What the quick undo keeps aside for the quick redo of the same operation. */
export interface SetAsideRedo {
  /** The live redo branch at the undo, untouched: its steps are in POST-OPERATION coordinates (the document the operation left). */
  branch: HistoryBranch;
  /** The live document that branch belongs to. */
  doc: Node;
  /** That document's block-id map (offset to id). */
  ids: ReadonlyMap<number, string>;
  /** How many redo events the live state is expected to hold when the put-back runs: right after the quick undo it is the carried
   * branch's count. The put-back only runs when the redo finds that count: a text undo and a text redo done in between push and
   * pop one event and leave it equal. It is a count check, and it suffices: real typing in between empties the list and refuses
   * the structural redo before it can run. */
  depthAfterUndo: number;
}

/** What `putBackSetAsideRedo` did: the put-back happened (with the redo events it restored), or why it did not. */
export type RedoPutBack = { putBack: true; events: number } | { putBack: false; reason: string };

// One record per operation id. Held here, not on the registry entry (undo-coordinator.ts is not touched by this fix): the entry is
// replaced by spread copies many times between an undo and its redo, and the id stays.
const setAside = new Map<string, SetAsideRedo>();

/**
 * Keeps `record` aside for the redo of `opId`, replacing whatever was kept for it before; `null` (nothing to set aside: the live
 * redo list is empty) deletes the old record, so a redo can never take a record from an earlier undo. Also drops every record whose
 * operation id is no longer in `liveOpIds` (the registry's keys), so a record for an entry that is gone does not stay. The quick
 * undo of a section delete stores one too, which its redo never takes: it costs memory only and is pruned by the next store.
 */
export function setAsideRedoBranch(opId: string, record: SetAsideRedo | null, liveOpIds: Iterable<string>): void {
  const live = new Set(liveOpIds);
  for (const key of Array.from(setAside.keys())) {
    if (!live.has(key)) setAside.delete(key);
  }
  if (record) setAside.set(opId, record);
  else setAside.delete(opId);
}

/** The record kept for `opId`, or undefined. Read-only; tests use it to break a record on purpose. */
export function setAsideRedoOf(opId: string): SetAsideRedo | undefined {
  return setAside.get(opId);
}

/** Forgets every record. The test harness calls it after each test; production calls it from the barrier clear
 * (`clearStructuralUndoRegistryAndRedoRecords`, api-section-undo.ts), whose timeline the records belonged to. */
export function resetSetAsideRedo(): void {
  setAside.clear();
}

/**
 * Puts the redo branch that `setAsideRedoBranch` kept for `opId` back, after the quick redo has run the operation again, so the
 * Cmd-Shift-Z that follows redoes the typing the user did inside the operation's text. Returns null when there is no record. The
 * branch is in the coordinates of `record.doc`; `view.state.doc` is the document the redo produced: when the two
 * are equal (the everyday case) the branch goes back as it is, otherwise it is mapped through the id-matched steps that turn one
 * into the other (`stepsToRestoredDocument`: a block both documents hold keeps its position, and so does every position inside it,
 * except inside a text or leaf node that differs, which is replaced as a whole and takes the positions strictly inside it with it
 * (see `syncNode`); typing inside a block the redone document does not hold is not redone, and nothing is misplaced). `idsNow` is
 * the live block-id map. Delivered the way
 * `reattachRedoBranch` delivers a kept branch: one meta-only transaction, so block-sync, the registry and the content push see
 * nothing. Never throws; every refusal comes back as `putBack: false` and leaves the live redo list as the redo left it. The record
 * is taken and deleted, whatever the result.
 */
export function putBackSetAsideRedo(
  view: EditorView,
  opId: string,
  idsNow: ReadonlyMap<number, string>
): RedoPutBack | null {
  const record = setAside.get(opId);
  if (!record) return null;
  try {
    const depthNow = historyOf(view.state)?.history.undone.eventCount ?? 0;
    if (depthNow !== record.depthAfterUndo) {
      return {
        putBack: false,
        reason: `the redo list changed since the undo (${depthNow} events, ${record.depthAfterUndo} then)`,
      };
    }
    let maps: readonly StepMap[] = [];
    if (!record.doc.eq(view.state.doc)) {
      const transform = stepsToRestoredDocument(record.doc, record.ids, view.state.doc, idsNow);
      // Defensive only: `stepsToRestoredDocument` always builds the target document, so this cannot be false short of a throw.
      if (!transform.doc.eq(view.state.doc))
        return { putBack: false, reason: 'the steps do not produce the redone document' };
      maps = transform.mapping.maps;
    }
    if (!reattachRedoBranch(view, record.branch, maps)) return { putBack: false, reason: 'no history plugin' };
    return { putBack: true, events: record.branch.eventCount };
  } catch (e) {
    return { putBack: false, reason: `exception: ${e instanceof Error ? e.message : String(e)}` };
  } finally {
    setAside.delete(opId);
  }
}
