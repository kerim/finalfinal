//
//  StructuralUndoController+FootnoteCheckpointGuard.swift
//  final final
//
//  t-18b7fa48 Phase 4b, fix round F1 (finding D, a real-app run: `testSlowUndoThenTypeAtOnce_article` lost a footnote definition and
//  duplicated another): the footnote undo checkpoints and a queued job that rewrites every Notes row.
//
//  THE HOLE. A section delete whose resync renumbered the footnotes recorded a footnote undo checkpoint (`FootnoteSyncService`,
//  FootnoteSyncService+UndoCheckpoint.swift): the states of the document before the delete, and the rename the delete applied. The
//  editor-first slow undo (and the whole-project restore) swaps the old document into the editor and queues a job that writes the
//  snapshot's rows, Notes included, in the OLD numbering. About 50 ms after the swap the editor tells Swift its text
//  (`contentChanged`); the footnote service sees nine references where its table holds eight, finds that the new text equals the
//  checkpoint's first state ("checkpoint matched") and queues a footnote restore planned against the table as it was AFTER the delete
//  (the new numbering): "move the rows back to the old numbering". First in, first out: it runs AFTER the slow undo's own job, which has
//  already written the old numbering, so the delete's renumbering is undone twice. The old slow body avoided it by setting
//  `contentState = .structuralUndo` around the swap (the checkpoint matcher runs only while the state is `.idle`); the editor-first
//  road, by design (requirement R1), sets no state, and the quick undo avoids it explicitly (`holdUndoCheckpoints` and
//  `dropUndoCheckpoints(notIn:)`), which the slow road did not do.
//
//  THE GUARD, taken SYNCHRONOUSLY in the click's reply turn (before the editor's push can arrive): the footnote service's pending
//  burst is cancelled, every checkpoint is dropped, and a hold stops a write scheduled before the click from recording a new one
//  when it commits. The job's task releases the hold when it is over. After the job the settle's resync (`resyncAfterEditorFirstDelete`)
//  reconciles the Notes from the swapped-in text with no rename.
//
//  The two section restores and the duplicate do not need it: their jobs write only the rows of their own range, never a Notes row, so
//  a checkpoint's table (the Notes rows the delete left) is still the table when a restored section's text happens to match a state,
//  and the footnote restore the checkpoint then queues is the right one.
//

import Foundation

extension StructuralUndoController {

    /// Takes the guard for the job that holds `token` (its registry key). Call it in the click's reply turn, before anything suspends.
    func guardFootnoteCheckpointsForNotesRewrite(token: UUID) {
        guard let footnoteSyncService else { return }
        footnoteSyncService.cancelPendingDebounce()
        footnoteSyncService.dropAllUndoCheckpoints()
        footnoteSyncService.holdUndoCheckpoints(token: token)
    }

    /// Ends the hold of `guardFootnoteCheckpointsForNotesRewrite(token:)` (a later job's hold is left alone).
    func releaseFootnoteCheckpointGuard(token: UUID) {
        footnoteSyncService?.releaseUndoCheckpointHold(token: token)
    }
}
