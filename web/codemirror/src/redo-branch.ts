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

import { history, historyField, redoDepth } from '@codemirror/commands';
import { ChangeSet, EditorState, type Extension, Transaction } from '@codemirror/state';
import { computeMinimalChanges } from './text-diff';

export type RedoCarry = { carried: true; state: EditorState; events: number } | { carried: false; reason: string };

/** The line-diff change set turning `from` into `to` (both whole documents of the given states). */
function diffChanges(from: EditorState, to: EditorState): ChangeSet {
  return ChangeSet.of(computeMinimalChanges(from.doc.toString(), to.doc.toString()), from.doc.length);
}

/**
 * The state the quick undo should install: `checkpoint`'s document, selection and undo branch plus `live`'s redo branch mapped onto
 * the checkpoint document. `opChanges` is the change set the command applied (pre-op document to post-op document), or undefined
 * for an entry the old body recorded. `extensions` is the editor's own extension set (the swapped-in state must carry exactly it).
 *
 * Returns null when there is nothing to carry (neither the live nor the checkpoint state has anything to redo): the caller installs
 * the checkpoint itself. Never throws.
 */
export function carryRedoBranch(
  live: EditorState,
  checkpoint: EditorState,
  opChanges: ChangeSet | undefined,
  extensions: Extension[]
): RedoCarry | null {
  if (redoDepth(live) === 0 && redoDepth(checkpoint) === 0) return null;
  try {
    // 1. The change set from the live document to the checkpoint document.
    let toCheckpoint: ChangeSet;
    if (opChanges) {
      const produced = opChanges.apply(checkpoint.doc); // the document the command produced
      const inverse = opChanges.invert(checkpoint.doc); // produced -> checkpoint
      toCheckpoint = live.doc.eq(produced)
        ? inverse
        : ChangeSet.of(computeMinimalChanges(live.doc.toString(), produced.toString()), live.doc.length).compose(
            inverse
          );
    } else {
      toCheckpoint = diffChanges(live, checkpoint);
    }
    if (!toCheckpoint.apply(live.doc).eq(checkpoint.doc)) {
      return { carried: false, reason: 'the change set does not turn the live document into the checkpoint document' };
    }

    // 2. The live redo branch, mapped by @codemirror/commands itself (a history-neutral change maps both branches).
    const probe = EditorState.fromJSON(
      live.toJSON({ history: historyField }),
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
    return { carried: true, state, events: expected };
  } catch (error) {
    return { carried: false, reason: `exception: ${error instanceof Error ? error.message : String(error)}` };
  }
}
