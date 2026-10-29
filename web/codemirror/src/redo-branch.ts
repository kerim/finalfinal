// The editor's REDO branch across the Markdown quick undo of a structural command (t-4a8fd8af, O24, the Q2 ruling).
//
// The quick undo of an editor-first Markdown command (api-structural-markdown.ts) swaps the whole pre-op EditorState back in, so
// the section returns with its own text history. A plain swap installs the checkpoint's history as it was at the click -- and its
// REDO branch with it: what the user typed after the command and then took back with Cmd-Z can no longer be brought back with
// Cmd-Shift-Z. The old Markdown body keeps that branch (its `setContent` is a history-neutral change, which @codemirror/commands
// maps both branches through), and Rich Text keeps it explicitly (web/milkdown/src/redo-branch.ts). This is the CodeMirror
// counterpart: `carryRedoBranch` builds the state the swap should install -- the checkpoint's document, selection and DONE branch,
// plus the LIVE redo branch mapped onto the checkpoint document. The checkpoint swap never ships without it.
//
// How the live redo branch is mapped: @codemirror/commands already maps both branches through any change that is not added to the
// history (`addToHistory: false`; that is what keeps the branches right through the command's own dispatch). So a throwaway state
// that holds nothing but the live document and the live history is given ONE such change, "live document -> checkpoint document",
// and the redo branch it ends with is the one we want. No history internals are reimplemented: the history is read and written
// only through the public `historyField` JSON (`state.toJSON({history: historyField})` and `EditorState.fromJSON`), whose shape
// and the library versions are pinned by redo-branch.test.ts, so an upgrade that changes either fails at build time.
//
// "Live document -> checkpoint document" is NOT just the inverse of the command's own change set: by the time of the undo the live
// document has had the app's own rewrites (the anchors injected by the rebuild, the renumbered footnotes) applied to it as
// history-neutral changes, so its positions are not those of the document right after the command. The change set used is
// therefore `churn` (live -> the document the command produced, `computeRefinedChanges`: small hunks however long the book is, so
// the moved span below can be followed through it) composed with the inverse of the
// command's change set (that document -> the checkpoint), and it is checked to turn the live document into the checkpoint's
// exactly. For an entry the old body recorded (no stored change set) it is the line diff between the two documents.
//
// On this carry (the list the editor holds between the undo and the redo, and the fall-back when the put-back below is refused),
// events that lie inside text the undo removes are left out: for a delete there is none (its inverse removes nothing), for a drag it is
// the moved text, and for an entry the old body recorded it is every span the line diff between the live document and the checkpoint
// removes. They are not lost: the full list is set aside at the undo and put back once the redo has landed (`putBackRedo`, below).
// Any failure (an exception, a mapping that does not reproduce the checkpoint document, a changed event count) comes back as
// `carried: false` with the reason, and the caller falls back to the plain swap, which loses the redo branch and nothing else.
//
// WHY events inside a removed span are left out of the carry. In CodeMirror an INSERTION inside a range that a change removes survives
// the mapping and lands at the removal point (a typed character is never mapped away). Left alone, a redo event that types into the
// moved chapter (a reorder) or into the copy (the old body's Duplicate) would come back at the start of the next chapter's heading
// line -- inside the line, splitting it -- and that chapter would stop being a section. So the carry takes the spans the undo removes
// (`moved` for a reorder, `removedSpans` of the line diff for an old-body entry) and DROPS the redo events that touch them.
// An event is found by replaying the live redo branch on a throwaway state: each redo yields the event's change in the coordinates of
// the document it applies to, so the spans can be followed through the events that come before them. The first event that touches
// a span is dropped TOGETHER WITH every event after it, because the later ones are written for the document the dropped one produced;
// everything before it is mapped as for any command. (Rich Text's quick route also maps steps inside removed text away, and also
// puts them back the same way; its drag takes the slow route, which saves the whole live state and never needed this.)
//
// THE PUT-BACK (t-14f908b4). The undo swap hands `setAsideRedo` the live redo branch untouched (its history JSON `undone`, the live
// document it belongs to and the redo depth the undo left), keyed by the entry's opId. After the redo has landed the document again,
// `putBackRedo` maps that list through the difference record.doc -> the document now on the screen (`computeRefinedChanges`, no
// 500-line bound: the app's footnote renumber and anchors usually make it a few characters, and in a book the first relabelled
// reference and the Notes definitions are far apart) and installs it as the live redo branch, so the next Cmd-Shift-Z brings back what
// was typed inside the copy or the dragged chapter. The drop rule is applied once more, to the spans that difference removes, as a guard.
// A refusal (the redo list changed meanwhile, the mapping does not reproduce the live document, an exception) leaves the carried list
// the redo found: the operation is redone, typing that lay inside the new text is not, and nothing is written into a wrong place.
// A DELETE entry is never set aside: its quick redo re-runs the command, and a delete loses no typing (QU19, W10).
// The same machinery keeps a waiting redo list across the app's RECORDED footnote renumber (`keepRedoList` / `keptRedoOnto`, used by
// api.ts `renumberFootnotes` outside a structural settle; there the list is mapped through the renumber transaction's own change set):
// @codemirror/commands empties the redo list on any recorded change.
// Slices 3 and 4 (board t-4a8fd8af) must apply the drop rule to their own entries' carry (an editor-first Markdown Duplicate inverse
// deletes the copy, and an insertion inside it lands at the removal point), and must read `depthBeforeRedo` BEFORE any quick re-run
// returns (like runDelete, api-structural-markdown.ts), because its redone document may differ from the stored one.

import { history, historyField, redo, redoDepth } from '@codemirror/commands';
import { ChangeSet, EditorState, type Extension, type Text, Transaction } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { computeMinimalChanges, computeRefinedChanges } from './text-diff';

/** `dropped` is the number of redo events the carry left behind because they lie inside a span the undo removes: the moved range of a
 * reorder (see `moved` below), or a span the line diff removes for an entry the old body recorded. */
export type RedoCarry =
  | { carried: true; state: EditorState; events: number; dropped: number }
  | { carried: false; reason: string };

/** A span of the document, in offsets. */
export interface MovedRange {
  from: number;
  to: number;
}

/** The line-diff change set turning `from` into `to` (both whole documents of the given states). */
function diffChanges(from: EditorState, to: EditorState): ChangeSet {
  return ChangeSet.of(computeMinimalChanges(from.doc.toString(), to.doc.toString()), from.doc.length);
}

/** Whether any change in `changes` (offsets of the document it applies to) touches [from, to): an insertion at `from` up to just
 * before `to`, or a replacement or deletion that overlaps the span. */
function touchesSpan(changes: ChangeSet, from: number, to: number): boolean {
  let touched = false;
  changes.iterChangedRanges((fromA, toA) => {
    if (fromA === toA ? fromA >= from && fromA < to : fromA < to && toA > from) touched = true;
  });
  return touched;
}

/** The spans `changes` deletes or replaces, in the offsets of the document it applies to. */
export function removedSpans(changes: ChangeSet): MovedRange[] {
  const spans: MovedRange[] = [];
  changes.iterChangedRanges((fromA, toA) => {
    if (toA > fromA) spans.push({ from: fromA, to: toA });
  });
  return spans;
}

/**
 * How many events of the redo branch held by `state` (whose `toJSON({history})` is `json`), counted from the next one to be redone,
 * come before the first event that touches any of `spans` (in `state`'s coordinates). Replays the branch on a throwaway state; stops
 * at the first event that touches a span.
 */
function redoEventsBeforeSpans(state: EditorState, json: unknown, spans: MovedRange[]): number {
  let replay = EditorState.fromJSON(json, { extensions: [history()] }, { history: historyField });
  let tracked = spans.map((span) => ({ ...span }));
  const depth = redoDepth(state);
  let kept = 0;
  while (kept < depth) {
    const taken: Transaction[] = [];
    if (!redo({ state: replay, dispatch: (tr) => taken.push(tr) }) || taken.length === 0) break;
    const step = taken[0];
    if (tracked.some((span) => touchesSpan(step.changes, span.from, span.to))) break;
    // Not touching: a span only shifts (typing before it), never grows.
    tracked = tracked.map((span) => ({
      from: step.changes.mapPos(span.from, 1),
      to: step.changes.mapPos(span.to, -1),
    }));
    replay = step.state;
    kept++;
  }
  return kept;
}

/**
 * The state the quick undo should install: `checkpoint`'s document, selection and undo branch plus `live`'s redo branch mapped onto
 * the checkpoint document. `opChanges` is the change set the command applied (pre-op document to post-op document), or undefined
 * for an entry the old body recorded. `extensions` is the editor's own extension set (the swapped-in state must carry exactly it).
 *
 * `moved` is set for a reorder only: the moved text in the coordinates of the document the command produced (see the header). An
 * entry the old body recorded (`opChanges` undefined) computes its own spans from the line diff.
 *
 * Returns null when there is nothing to carry (neither the live nor the checkpoint state has anything to redo): the caller installs
 * the checkpoint itself. Never throws.
 */
export function carryRedoBranch(
  live: EditorState,
  checkpoint: EditorState,
  opChanges: ChangeSet | undefined,
  extensions: Extension[],
  moved?: MovedRange | null
): RedoCarry | null {
  if (redoDepth(live) === 0 && redoDepth(checkpoint) === 0) return null;
  try {
    // 1. The change set from the live document to the checkpoint document.
    let toCheckpoint: ChangeSet;
    // The spans of the live document whose redo events are left out (the header says why): `moved` for a reorder, every span the line
    // diff removes for an entry the old body recorded. A delete has none: its inverse removes nothing.
    let spans: MovedRange[] = [];
    if (opChanges) {
      const produced = opChanges.apply(checkpoint.doc); // the document the command produced
      const inverse = opChanges.invert(checkpoint.doc); // produced -> checkpoint
      if (live.doc.eq(produced)) {
        toCheckpoint = inverse;
        if (moved) spans = [moved];
      } else {
        const churn = ChangeSet.of(computeRefinedChanges(live.doc.toString(), produced.toString()), live.doc.length);
        toCheckpoint = churn.compose(inverse);
        if (moved) {
          const back = churn.invert(live.doc); // produced -> live
          spans = [{ from: back.mapPos(moved.from, 1), to: back.mapPos(moved.to, -1) }];
        }
      }
    } else {
      toCheckpoint = diffChanges(live, checkpoint);
      spans = removedSpans(toCheckpoint);
    }
    spans = spans.filter((span) => span.to > span.from);
    if (!toCheckpoint.apply(live.doc).eq(checkpoint.doc)) {
      return { carried: false, reason: 'the change set does not turn the live document into the checkpoint document' };
    }

    // 2. The live redo branch, mapped by @codemirror/commands itself (a history-neutral change maps both branches). The events that touch
    // the spans are left out first (the header says why); they are the bottom of the branch from the first one on.
    const liveJson = live.toJSON({ history: historyField });
    let liveUndone = liveJson.history.undone;
    let dropped = 0;
    if (spans.length > 0) {
      const kept = redoEventsBeforeSpans(live, liveJson, spans);
      dropped = redoDepth(live) - kept;
      if (dropped > 0) liveUndone = kept === 0 ? [] : liveUndone.slice(liveUndone.length - kept);
    }
    const probe = EditorState.fromJSON(
      { ...liveJson, history: { done: liveJson.history.done, undone: liveUndone } },
      { extensions: [history()] },
      { history: historyField }
    );
    const mapped = probe.update({ changes: toCheckpoint, annotations: Transaction.addToHistory.of(false) }).state;
    const mappedHistory = mapped.toJSON({ history: historyField }).history;

    // 3. The checkpoint, with that redo branch instead of its own.
    const saved = checkpoint.toJSON({ history: historyField });
    const state = EditorState.fromJSON(
      {
        doc: saved.doc,
        selection: saved.selection,
        history: { done: saved.history.done, undone: mappedHistory.undone },
      },
      { extensions },
      { history: historyField }
    );
    if (!state.doc.eq(checkpoint.doc)) return { carried: false, reason: 'the rebuilt state holds another document' };
    const expected = redoDepth(mapped);
    if (redoDepth(state) !== expected) {
      return { carried: false, reason: `redo depth ${redoDepth(state)} after the carry, ${expected} expected` };
    }
    return { carried: true, state, events: expected, dropped };
  } catch (error) {
    return { carried: false, reason: `exception: ${error instanceof Error ? error.message : String(error)}` };
  }
}

// === Set aside at the undo, put back after the redo (t-14f908b4) ===

/** What the quick undo of a structural entry keeps aside for the redo: the live redo branch exactly as it stood. */
export interface SetAsideRedo {
  /** The history JSON `undone` of the live state at the undo, untouched: its events are in the coordinates of `doc`. */
  undone: unknown[];
  /** The live document at the undo (the document `undone` belongs to). */
  doc: Text;
  /** The redo depth the undo left in the state it installed (the carried list, or the checkpoint's own). The put-back needs the same
   * depth just before the redo, which is a COUNT check: in every sequence an editor can reach, an unchanged count means an unchanged
   * list (a text undo and its redo push and pop one event; typing empties the list and the structural redo is then not offered; a
   * sync-origin change that empties an event lowers the count and refuses the put-back, which is the safe side). */
  depthAfterUndo: number;
}

const setAside = new Map<string, SetAsideRedo>();

/** Keeps `record` for `opId` (replacing an earlier one) and forgets every record whose opId is no longer in `liveOpIds`. */
export function setAsideRedo(opId: string, record: SetAsideRedo, liveOpIds: Iterable<string>): void {
  const live = new Set(liveOpIds);
  for (const key of [...setAside.keys()]) if (!live.has(key)) setAside.delete(key);
  setAside.set(opId, record);
}

/** Forgets the record of `opId`: an undo with nothing to set aside must not leave an older record for a later redo to find. */
export function clearSetAsideRedo(opId: string): void {
  setAside.delete(opId);
}

/** The record for `opId`, or undefined. For tests (they break the record to exercise the fall-back). */
export function setAsideRedoOf(opId: string): SetAsideRedo | undefined {
  return setAside.get(opId);
}

/** Forgets every record. Called by `clearStructuralUndoRegistry` and by the tests. */
export function resetSetAsideRedo(): void {
  setAside.clear();
}

export type RedoPutBack =
  | { carried: true; state: EditorState; events: number; dropped: number }
  | { carried: false; reason: string };

/**
 * The state to install after the structural redo has landed: the live document, selection and DONE branch, plus the redo branch that
 * was set aside at the undo, mapped from the document it belonged to onto the document that is now on the screen. `depthBeforeRedo` is
 * the redo depth read BEFORE the redo's own dispatch. Returns null when nothing was set aside for `opId`; takes (removes) the record
 * either way. Never throws. The caller installs `state` (api-structural-markdown.ts `installState`); the document is not touched.
 */
export function putBackRedo(
  view: EditorView,
  opId: string,
  depthBeforeRedo: number,
  extensions: Extension[]
): RedoPutBack | null {
  const record = setAside.get(opId);
  if (!record) return null;
  setAside.delete(opId);
  try {
    if (depthBeforeRedo !== record.depthAfterUndo) {
      return {
        carried: false,
        reason: `the redo list changed since the undo (${depthBeforeRedo} events now, ${record.depthAfterUndo} left by the undo)`,
      };
    }
    return redoListOnto(view.state, record.undone, record.doc, null, extensions);
  } catch (error) {
    return { carried: false, reason: `exception: ${error instanceof Error ? error.message : String(error)}` };
  }
}

/**
 * The state that is `live` with the redo branch `undone` (history JSON events, in the coordinates of `from`, the document they belong
 * to) mapped onto `live`'s document. The mapping is `known` when the caller has the change set that turned `from` into `live.doc` (the
 * renumber's own transaction); otherwise it is the difference `from` -> `live.doc` (`computeRefinedChanges`): usually nothing (the redo
 * lands on the document the undo started from) or a few characters (a footnote label, an anchor the app rewrote meanwhile). The drop rule
 * is applied once more, to the spans that change set removes, as a guard. Shared by the put-back after a structural redo and by the redo
 * list kept across a recorded automatic change (`keepRedoList`). May throw: the callers wrap it.
 */
function redoListOnto(
  live: EditorState,
  undone: unknown[],
  from: Text,
  known: ChangeSet | null,
  extensions: Extension[]
): RedoPutBack {
  const fromText = from.toString();
  const changes = known ?? ChangeSet.of(computeRefinedChanges(fromText, live.doc.toString()), from.length);
  const recordJson = {
    doc: fromText,
    selection: { main: 0, ranges: [{ anchor: 0, head: 0 }] },
    history: { done: [] as unknown[], undone },
  };
  let recordState = EditorState.fromJSON(recordJson, { extensions: [history()] }, { history: historyField });
  // The drop rule, once more, as a guard: an event inside text this difference removes would land at the removal point.
  const spans = removedSpans(changes);
  let dropped = 0;
  if (spans.length > 0) {
    const depth = redoDepth(recordState);
    const kept = redoEventsBeforeSpans(recordState, recordJson, spans);
    dropped = depth - kept;
    if (dropped > 0) {
      recordState = EditorState.fromJSON(
        { ...recordJson, history: { done: [], undone: kept === 0 ? [] : undone.slice(undone.length - kept) } },
        { extensions: [history()] },
        { history: historyField }
      );
    }
  }
  const mapped = changes.empty
    ? recordState
    : recordState.update({ changes, annotations: Transaction.addToHistory.of(false) }).state;
  if (!mapped.doc.eq(live.doc)) return { carried: false, reason: 'the difference does not produce the live document' };
  const mappedUndone = mapped.toJSON({ history: historyField }).history.undone;

  const liveJson = live.toJSON({ history: historyField });
  const state = EditorState.fromJSON(
    {
      doc: liveJson.doc,
      selection: liveJson.selection,
      history: { done: liveJson.history.done, undone: mappedUndone },
    },
    { extensions },
    { history: historyField }
  );
  if (!state.doc.eq(live.doc)) return { carried: false, reason: 'the rebuilt state holds another document' };
  const expected = redoDepth(mapped);
  if (redoDepth(state) !== expected) {
    return { carried: false, reason: `redo depth ${redoDepth(state)} after the put-back, ${expected} expected` };
  }
  return { carried: true, state, events: expected, dropped };
}

// === A redo list kept across a RECORDED automatic change (t-14f908b4: the footnote renumber outside a structural settle) ===

/** A live redo list taken before a recorded change, with the document it belongs to. */
export interface KeptRedo {
  undone: unknown[];
  doc: Text;
}

/**
 * A recorded change (one that is added to the history) empties the redo list: @codemirror/commands drops it on any such change. The
 * footnote renumber outside a structural settle is one (api.ts `renumberFootnotes`), and it can land while a list is waiting, for example
 * the put-back list right after a structural redo: left alone it wipes the list. Take the list here, BEFORE the dispatch, and build the
 * state that has it back with `keptRedoOnto`, AFTER it. Null when there is nothing to keep. Never throws.
 */
export function keepRedoList(state: EditorState): KeptRedo | null {
  if (redoDepth(state) === 0) return null;
  try {
    return { undone: state.toJSON({ history: historyField }).history.undone as unknown[], doc: state.doc };
  } catch {
    return null;
  }
}

/** The state to install after the recorded change has landed: the live document, selection and DONE branch, with the kept redo list
 * mapped onto the live document through `changes`, the change set of that very transaction (`tr.changes`: `kept.doc` -> live). The
 * caller installs `state` (api-structural-markdown.ts `installState`); the document is not touched. Never throws. */
export function keptRedoOnto(
  view: EditorView,
  kept: KeptRedo,
  changes: ChangeSet,
  extensions: Extension[]
): RedoPutBack {
  try {
    return redoListOnto(view.state, kept.undone, kept.doc, changes, extensions);
  } catch (error) {
    return { carried: false, reason: `exception: ${error instanceof Error ? error.message : String(error)}` };
  }
}

/**
 * For a command that is about to remove `spans` (pre-command coordinates = `live`'s) with `addToHistory: false`: the state to install
 * first so that the redo list holds no event that touches them -- or null when every event is clear of them (or there is nothing to
 * redo). An event typed inside text that is then removed would land at the removal point, the start of the line after the removed
 * text (a heading line), when it is redone. The first event that touches a span goes, with every event after it. Never throws.
 */
export function withoutRedoEventsTouching(
  live: EditorState,
  spans: MovedRange[],
  extensions: Extension[]
): { state: EditorState; dropped: number } | null {
  const depth = redoDepth(live);
  if (depth === 0 || spans.length === 0) return null;
  try {
    const json = live.toJSON({ history: historyField });
    const kept = redoEventsBeforeSpans(live, json, spans);
    if (kept >= depth) return null;
    const undone = kept === 0 ? [] : json.history.undone.slice(json.history.undone.length - kept);
    const state = EditorState.fromJSON(
      { doc: json.doc, selection: json.selection, history: { done: json.history.done, undone } },
      { extensions },
      { history: historyField }
    );
    if (!state.doc.eq(live.doc)) return null;
    return { state, dropped: depth - kept };
  } catch {
    return null;
  }
}
