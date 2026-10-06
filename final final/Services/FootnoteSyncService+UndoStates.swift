//
//  FootnoteSyncService+UndoStates.swift
//  final final
//
//  t-94369a83 Phase 3a-2 Step 6: every ⌘Z step brings back ITS OWN footnote. A burst of deletes is one write and one
//  checkpoint, but the user undoes it one step at a time, and each step lands on a document the service saw while
//  the burst was running. The checkpoint therefore keeps a CHAIN of undo states instead of one "before" document:
//
//  - Burst states (`numbering == .old`): the document before the first change of the burst (S0) and, every time the
//    references change again inside the burst, the document the service saw just before that change. They carry the
//    labels as the user saw them, because the editor renumbers only when the write happens. The document the write
//    was computed from ("Slast") closes the chain.
//  - The written state W (`numbering == .new`): the document after the write, with the editor's renumbered labels,
//    recorded at the first equal-refs check after a write that renamed something.
//
//  Matching and restoring live in FootnoteSyncService+UndoCheckpoint.swift. This file holds the state types, the
//  recording, and the cheap per-check bookkeeping: on every check the only new work is one copy-on-write assignment
//  of `lastChecked`; states are stored in the `undoComparable` form the match already uses.
//

import Foundation

/// Which labels a state (or the stored Notes rows) carries: the numbering before the write that deleted the
/// definitions (`old`, the labels the user saw while deleting) or after it (`new`, the survivors renumbered).
enum FootnoteUndoNumbering {
    case old
    case new
}

/// One document an undo can land on.
struct FootnoteUndoState {
    /// Notes stripped and trimmed (`FootnoteSyncService.undoComparable`).
    let body: String
    /// The references in that document, in order.
    let refs: [String]
    let numbering: FootnoteUndoNumbering
}

extension FootnoteSyncService {
    /// The most states one checkpoint keeps; the state before the burst is always kept, the oldest middle ones go first.
    static let undoStateLimit = 16

    /// An equal-refs check (the references are what the Notes rows already match): remembers the content as the
    /// last content seen with the committed references and as the last check, and, once per checkpoint, records
    /// the written state W.
    func noteEqualRefsCheck(content: String, refs: [String]) {
        lastContentWithKnownRefs = content
        lastChecked = (content, refs)
        guard let index = undoCheckpoints.indices.last else { return }
        let checkpoint = undoCheckpoints[index]
        // W is the document after the write that renamed something, seen for the first time: the table is in the
        // new numbering and the references equal the ones the write committed.
        guard !checkpoint.writtenStateRecorded, !checkpoint.appliedRenameMap.isEmpty,
              checkpoint.committedNumbering == .new, checkpoint.committedRefs == refs else { return }
        undoCheckpoints[index].states.append(FootnoteUndoState(body: Self.undoComparable(content), refs: refs, numbering: .new))
        undoCheckpoints[index].writtenStateRecorded = true
        FootnoteDiag.log("undo state recorded: the written state labels=\(FootnoteDiag.labels(refs)) numbering=new " +
            "states=\(undoCheckpoints[index].states.count)")
    }

    /// A check whose references differ from the committed ones and that no restore consumed (`scheduleBurst` calls
    /// this for every such check). The last check made before it is the document ⌘Z of this change lands on, so it
    /// becomes a burst state when its references are different; the first change of a burst starts the list, so
    /// that state is S0.
    func noteChangedRefsCheck(content: String, refs: [String], newBurst: Bool) {
        if newBurst { burstStates = [] }
        if let previous = lastChecked, previous.refs != refs {
            let state = FootnoteUndoState(body: Self.undoComparable(previous.content), refs: previous.refs, numbering: .old)
            if let last = burstStates.last, last.refs == state.refs, last.body == state.body {
                // the same document twice in a row: nothing new
            } else {
                // Keep S0 (index 0); drop the oldest middle state once the list is full (the last slot is Slast's).
                if burstStates.count >= Self.undoStateLimit - 1 { burstStates.remove(at: 1) }
                burstStates.append(state)
                FootnoteDiag.log("undo state recorded: labels=\(FootnoteDiag.labels(state.refs)) numbering=old " +
                    "burstStates=\(burstStates.count)")
            }
        }
        lastChecked = (content, refs)
    }
}
