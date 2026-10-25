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
// therefore `churn` (live -> the document the command produced, a small multi-span line diff) composed with the inverse of the
// command's change set (that document -> the checkpoint), and it is checked to turn the live document into the checkpoint's
// exactly. For an entry the old body recorded (no stored change set) it is the line diff between the two documents.
//
// Events that lie inside text the command removed map away (nothing is left to redo there), exactly as in Rich Text.
// Any failure (an exception, a mapping that does not reproduce the checkpoint document, a changed event count) comes back as
// `carried: false` with the reason, and the caller falls back to the plain swap, which loses the redo branch and nothing else.
//
// A REORDER is different from a delete in one way that matters here. Its text is not removed, it is moved, and in CodeMirror an
// INSERTION inside a range that a change removes survives the mapping and lands at the removal point (a typed character is never
// mapped away). Left alone, a redo event that types into the moved chapter would come back at the start of the hopped-over chapter's
// heading line, and that chapter would stop being a section. So for a reorder the caller passes `moved` (the moved text, in the
// coordinates of the document the command produced) and the carry DROPS the redo events that touch it, as Rich Text does (its history
// steps inside a moved range are mapped away): typing you did inside a dragged chapter cannot be redone after you undo the drag.
// An event is found by replaying the live redo branch on a throwaway state: each redo yields the event's change in the coordinates of
// the document it applies to, so the moved range can be followed through the events that come before it. The first event that touches
// the range is dropped TOGETHER WITH every event after it, because the later ones are written for the document the dropped one
// produced; everything before it is mapped as for any command.

import { history, historyField, redo, redoDepth } from '@codemirror/commands';
import { ChangeSet, EditorState, type Extension, Transaction } from '@codemirror/state';
import { computeMinimalChanges } from './text-diff';

/** `dropped` is the number of redo events the carry left behind because they lie inside a moved range (a reorder, see `moved` below). */
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

/**
 * How many events of `live`'s redo branch, counted from the next one to be redone, come before the first event that touches `moved`
 * (the moved text, in `live`'s coordinates). Replays the branch on a throwaway state; stops at the first event that touches the span.
 */
function redoEventsBeforeMoved(live: EditorState, liveJson: unknown, moved: MovedRange): number {
  let state = EditorState.fromJSON(liveJson, { extensions: [history()] }, { history: historyField });
  let { from, to } = moved;
  const depth = redoDepth(live);
  let kept = 0;
  while (kept < depth) {
    const taken: Transaction[] = [];
    if (!redo({ state, dispatch: (tr) => taken.push(tr) }) || taken.length === 0) break;
    const step = taken[0];
    if (touchesSpan(step.changes, from, to)) break;
    // Not touching: the span only shifts (typing before it), never grows.
    from = step.changes.mapPos(from, 1);
    to = step.changes.mapPos(to, -1);
    state = step.state;
    kept++;
  }
  return kept;
}

/**
 * The state the quick undo should install: `checkpoint`'s document, selection and undo branch plus `live`'s redo branch mapped onto
 * the checkpoint document. `opChanges` is the change set the command applied (pre-op document to post-op document), or undefined
 * for an entry the old body recorded. `extensions` is the editor's own extension set (the swapped-in state must carry exactly it).
 *
 * `moved` is set for a reorder only: the moved text in the coordinates of the document the command produced (see the header).
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
    let liveMoved: MovedRange | null = null; // `moved` in the coordinates of the live document
    if (opChanges) {
      const produced = opChanges.apply(checkpoint.doc); // the document the command produced
      const inverse = opChanges.invert(checkpoint.doc); // produced -> checkpoint
      if (live.doc.eq(produced)) {
        toCheckpoint = inverse;
        liveMoved = moved ?? null;
      } else {
        const churn = ChangeSet.of(computeMinimalChanges(live.doc.toString(), produced.toString()), live.doc.length);
        toCheckpoint = churn.compose(inverse);
        if (moved) {
          const back = churn.invert(live.doc); // produced -> live
          liveMoved = { from: back.mapPos(moved.from, 1), to: back.mapPos(moved.to, -1) };
        }
      }
    } else {
      toCheckpoint = diffChanges(live, checkpoint);
    }
    if (!toCheckpoint.apply(live.doc).eq(checkpoint.doc)) {
      return { carried: false, reason: 'the change set does not turn the live document into the checkpoint document' };
    }

    // 2. The live redo branch, mapped by @codemirror/commands itself (a history-neutral change maps both branches). For a reorder the
    // events that touch the moved text are left out first (the header says why); they are the bottom of the branch from the first one on.
    const liveJson = live.toJSON({ history: historyField });
    let liveUndone = liveJson.history.undone;
    let dropped = 0;
    if (liveMoved && liveMoved.to > liveMoved.from) {
      const kept = redoEventsBeforeMoved(live, liveJson, liveMoved);
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
