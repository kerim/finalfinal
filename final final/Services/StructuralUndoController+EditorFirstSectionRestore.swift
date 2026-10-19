//
//  StructuralUndoController+EditorFirstSectionRestore.swift
//  final final
//
//  t-18b7fa48 Phase 4b, slice 2, round 2d-ii (plan-v3 D1, D3, D7, D8, D10): the two SECTION Version History restores in Rich Text, editor
//  first, on the click the whole-project restore already stands on (`runEditorFirstRestoreClick`,
//  StructuralUndoController+EditorFirstRestore.swift; the shared click, `runEditorFirstStructuralClick`; the one queued job,
//  `StructuralReplaceJob`, whose `section` and `insertAfter` modes these two use).
//
//    - `performEditorFirstSectionRestoreReplace`: "Replace Current Section". The editor replaces the FLAT range of the target heading
//      (the heading and its own body, never its sub-sections) with the version's text in one JavaScript turn (payload mode "section").
//    - `performEditorFirstRestoreSectionDuplicate`: "Restore as Duplicate". The editor inserts the version's text after the section the
//      window names, or after the last block that is not Notes or Bibliography (payload mode "insertAfter").
//
//  Both are called under the structural gate (the entry points in StructuralUndoController.swift take it WITHOUT the rebuild wait: the
//  rebuild stamp protects the editor, as it does for the whole-project restore) after the multi-window guard, and return nil when the
//  press has to take the old restore: Markdown mode, the UI-test legacy flag, the target cannot be told apart in the document (D8, logged
//  `[EF-STRUCT] <kind> target unresolved: ...`), the version's section cannot go through the editor (a section break, Notes or
//  Bibliography text: logged `[EF-STRUCT] <kind> fell back to the old path: ...`), no writer turn, an editor that refuses (D7).
//
//  READING. Everything the click needs (the version's section, the section table, the project's rows) is read in ONE synchronous stretch
//  with no flush, as the old restore's plan was read after its own flush: the rows are the database's, which lack the typing the click's
//  batch is about to bring. That is why nothing here depends on the exact rows around the range: the job finds the range and the sort
//  orders inside its own transaction (`replaceFlatSectionRange`, `insertRows`), after that batch has applied.
//
//  The sidebar, the quick undo and redo, the settle and the put-back are the whole-project restore's: they read the plan.
//

import SwiftUI
import GRDB

extension StructuralUndoController {

    // MARK: - Replace Current Section

    /// Restore `snapshotSectionId`'s text over the section `targetSectionId` (a row of the `section` table), editor first.
    func performEditorFirstSectionRestoreReplace(snapshotSectionId: String, targetSectionId: String) async -> StructuralOpOutcome? {
        guard let editorState, unifiedUndoService != nil, blockSyncService != nil,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId, takesTheEditorFirstPath else { return nil }
        // The same working notice as the whole-project restore (past one second, dismissed by id on every exit).
        let notice = DelayedProgressToast(toastCenter: editorState.toastCenter, message: DelayedProgressToast.finishingMessage)
        defer { notice.stop() }
        // `.autoZoomOut`, as the old restore opens (D10); the rows are read afterwards, because zooming out rewrites them.
        if editorState.zoomedSectionId != nil { await editorState.zoomOut() }

        // One synchronous stretch from here to the reservation of the click's writer turn (no `await` before `runEditorFirstRestoreClick`
        // hands the call to the web view).
        guard let snapshotSection = try? db.fetchSnapshotSection(id: snapshotSectionId),
              let sections = try? db.fetchSections(projectId: pid), let existing = try? db.fetchBlocks(projectId: pid) else { return nil }
        let kind = EditorFirstOpKind.restoreSectionReplace
        let target: Block
        switch SnapshotService.resolveFlatSectionTarget(sectionId: targetSectionId, sections: sections, blocks: existing) {
        case .resolved(let heading, _): target = heading
        case .unresolved(let reason):
            DebugLog.alwaysPersisted("[EF-STRUCT] \(kind.logName) target unresolved: \(reason) (project \(pid))")
            return nil
        }
        let plan: RestorePlan
        switch SnapshotService.sectionReplacePlan(
            database: db, projectId: pid, snapshotSection: snapshotSection, target: target, existing: existing,
            sidebarAnchor: sidebarAnchor(before: target.id)
        ) {
        case .plan(let built): plan = built
        case .legacy(let reason):
            DebugLog.alwaysPersisted("[EF-STRUCT] \(kind.logName) fell back to the old path: \(reason) (project \(pid))")
            return nil
        }
        return await runEditorFirstRestoreClick(plan: plan, database: db, projectId: pid)
    }

    // MARK: - Restore as Duplicate

    /// Restore `snapshotSectionId`'s text as a new section, editor first. `insertAfterSectionId` is a row of the `section` table (the
    /// window passes the last one); a Notes or Bibliography row, a row the table no longer has, and nil all mean "after the last block
    /// that is not Notes or Bibliography", which is where the old restore put the new section.
    func performEditorFirstRestoreSectionDuplicate(snapshotSectionId: String, insertAfterSectionId: String?) async -> StructuralOpOutcome? {
        guard let editorState, unifiedUndoService != nil, blockSyncService != nil,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId, takesTheEditorFirstPath else { return nil }
        let notice = DelayedProgressToast(toastCenter: editorState.toastCenter, message: DelayedProgressToast.finishingMessage)
        defer { notice.stop() }
        if editorState.zoomedSectionId != nil { await editorState.zoomOut() }

        guard let snapshotSection = try? db.fetchSnapshotSection(id: snapshotSectionId),
              let sections = try? db.fetchSections(projectId: pid), let existing = try? db.fetchBlocks(projectId: pid) else { return nil }
        let kind = EditorFirstOpKind.restoreSectionDuplicate

        var anchorBlockId: String?      // the editor's top-level node the copy goes after
        var jobAnchorBlockId: String?   // the database row the job inserts it after (the last row of the same range)
        var sidebarAnchor: RestoreAnchor?
        if let afterId = insertAfterSectionId,
           let afterSection = sections.first(where: { $0.id == afterId }), !afterSection.isBibliography, !afterSection.isNotes {
            switch SnapshotService.resolveFlatSectionTarget(sectionId: afterId, sections: sections, blocks: existing) {
            case .resolved(let heading, let nodeIds):
                // After the last editor node of that section's flat range; in the sidebar, right after its heading. The editor's node
                // for a list is its FIRST item's id, so the job gets the last ROW of the flat range instead (fix round F1, review A1):
                // an anchor on the first item would put the copy between a list's first and second item in the database.
                anchorBlockId = nodeIds.last
                jobAnchorBlockId = SnapshotService.flatRange(of: heading.id, in: BlockParser.assemblySorted(existing)).last?.id
                sidebarAnchor = .after(heading.id)
            case .unresolved(let reason):
                DebugLog.alwaysPersisted("[EF-STRUCT] \(kind.logName) target unresolved: \(reason) (project \(pid))")
                return nil
            }
        }
        if anchorBlockId == nil { sidebarAnchor = sidebarAnchorAfterLastUserSection() }

        let plan: RestorePlan
        switch SnapshotService.insertAfterPlan(
            database: db, projectId: pid, snapshotSection: snapshotSection, anchorBlockId: anchorBlockId,
            jobAnchorBlockId: jobAnchorBlockId, existing: existing, sidebarAnchor: sidebarAnchor
        ) {
        case .plan(let built): plan = built
        case .legacy(let reason):
            DebugLog.alwaysPersisted("[EF-STRUCT] \(kind.logName) fell back to the old path: \(reason) (project \(pid))")
            return nil
        }
        return await runEditorFirstRestoreClick(plan: plan, database: db, projectId: pid)
    }

    // MARK: - Where the sidebar puts the restored leaders

    /// Where a replaced heading's restored leader goes in the sidebar's list: right after the entry that stands before it now, or first.
    /// Nil when the sidebar does not list the heading (the leaders' sort orders then decide).
    private func sidebarAnchor(before leaderId: String) -> RestoreAnchor? {
        guard let sections = editorState?.sections, let index = sections.firstIndex(where: { $0.id == leaderId }) else { return nil }
        return index == 0 ? .documentStart : .after(sections[index - 1].id)
    }

    /// Where a copy inserted after the last block that is not managed goes in the sidebar: right after the last entry that is not Notes
    /// or Bibliography, or first when there is none.
    private func sidebarAnchorAfterLastUserSection() -> RestoreAnchor? {
        guard let sections = editorState?.sections else { return nil }
        guard let last = sections.last(where: { !$0.isNotes && !$0.isBibliography }) else { return .documentStart }
        return .after(last.id)
    }
}
