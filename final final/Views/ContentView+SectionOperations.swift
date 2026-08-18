//
//  ContentView+SectionOperations.swift
//  final final
//
//  Sidebar section delete/duplicate (right-click/control-click context menu). Forward DB ops
//  ported from the parked `sidebar-section-delete-dup` worktree (see
//  Models/Database+SectionOps.swift). Undo/redo is NOT a separate mechanism here -- both ops
//  are `StructuralEntry.Kind` cases on the unified chronological timeline
//  (docs/plans/patient-rewinding-clockwork.md §4.4/§7 Phase 4), driven end to end by
//  `StructuralUndoController.performSectionDelete`/`performSectionDuplicate` (the shared
//  audited sequence: flush, checkpoint, forced undo-point snapshot, the DB mutation, forced
//  bibliography/footnote resync, content push, timeline record).
//
//  The parked worktree's single-slot `pendingSectionOperation`/`undoSectionOperation()`/
//  Cmd-Opt-Z mechanism is deliberately NOT ported -- it's fully superseded by
//  `StructuralUndoController.performUndo`/`performRedo` (plan §7 Phase 4 scope), which restore
//  from the same forced undo-point snapshot every other structural op uses rather than a
//  verbatim per-op row inverse.
//

import SwiftUI

extension ContentView {
    /// Whether the sidebar's delete/duplicate actions are available right now. Both refuse
    /// while zoomed into a section (`StructuralUndoController`'s `.refuseIfZoomed` policy,
    /// plan §4.5) -- the zoom range is itself a DB structural concept; reconciling it against a
    /// concurrent delete/duplicate is out of scope (known limitation, not attempted).
    var isSectionOperationAvailable: Bool {
        editorState.zoomedSectionId == nil
    }

    /// Delete a section's full subtree (heading + descendants) from the sidebar context menu.
    /// Runs the full audited structural-op sequence
    /// (`StructuralUndoController.performSectionDelete`) end to end. No-op while zoomed, for a
    /// bibliography/notes section, or if `sectionId` can't be resolved -- all three refusal
    /// cases surface as a `false` return from the controller, not a thrown error.
    func deleteSectionFromSidebar(_ sectionId: String) {
        guard isSectionOperationAvailable else { return }
        Task {
            let ok = await structuralUndoController.performSectionDelete(rootId: sectionId)
            if !ok {
                DebugLog.log(.undo, "[ContentView] deleteSectionFromSidebar: op refused or failed for section \(sectionId)")
            }
        }
    }

    /// Duplicate a section's full subtree from the sidebar context menu. Same refusal/no-op
    /// rules as `deleteSectionFromSidebar`.
    func duplicateSectionFromSidebar(_ sectionId: String) {
        guard isSectionOperationAvailable else { return }
        Task {
            let ok = await structuralUndoController.performSectionDuplicate(rootId: sectionId)
            if !ok {
                DebugLog.log(.undo, "[ContentView] duplicateSectionFromSidebar: op refused or failed for section \(sectionId)")
            }
        }
    }
}
