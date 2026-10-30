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
        // t-4a8fd8af slice 4: Markdown mode has its own editor-first click, chosen here once (see `performEditorFirstRestoreProject`).
        let markdownPath = takesTheMarkdownEditorFirstRestorePath
        guard let editorState, unifiedUndoService != nil, blockSyncService != nil,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId,
              takesTheEditorFirstPath || markdownPath else { return nil }
        // The same working notice as the whole-project restore (past one second, dismissed by id on every exit).
        let notice = DelayedProgressToast(toastCenter: editorState.toastCenter, message: DelayedProgressToast.finishingMessage)
        defer { notice.stop() }
        // `.autoZoomOut`, as the old restore opens (D10); the rows are read afterwards, because zooming out rewrites them.
        // Typing during the zoom-out that happens before a restore of a zoomed section can still be lost in Markdown; zoom is Phase 5.
        if editorState.zoomedSectionId != nil { await editorState.zoomOut() }

        if markdownPath {
            return await performMarkdownEditorFirstRestore(kind: .restoreSectionReplace) {
                await markdownSectionRestoreReplaceBuild(
                    snapshotSectionId: snapshotSectionId, targetSectionId: targetSectionId, database: db, projectId: pid)
            }
        }

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
        // t-4a8fd8af slice 4: Markdown mode has its own editor-first click, chosen here once (see `performEditorFirstRestoreProject`).
        let markdownPath = takesTheMarkdownEditorFirstRestorePath
        guard let editorState, unifiedUndoService != nil, blockSyncService != nil,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId,
              takesTheEditorFirstPath || markdownPath else { return nil }
        let notice = DelayedProgressToast(toastCenter: editorState.toastCenter, message: DelayedProgressToast.finishingMessage)
        defer { notice.stop() }
        // Typing during the zoom-out that happens before a restore of a zoomed section can still be lost in Markdown; zoom is Phase 5.
        if editorState.zoomedSectionId != nil { await editorState.zoomOut() }

        if markdownPath {
            return await performMarkdownEditorFirstRestore(kind: .restoreSectionDuplicate) {
                await markdownRestoreSectionDuplicateBuild(
                    snapshotSectionId: snapshotSectionId, insertAfterSectionId: insertAfterSectionId, database: db, projectId: pid)
            }
        }

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

    // MARK: - The Markdown plan builders (t-4a8fd8af slice 4)

    // The two builders below are what the Markdown click calls AFTER its hold wait (the rows must be read then) and once more after a
    // flush-and-retry. They read what the Rich Text functions above read and build the same plans, with one difference (plan-v1 addendum
    // section 15): `prepareMarkdownPageForStructuralCommand` does NOT refresh the section table or the rows, so a heading typed a moment
    // ago can be in the table but not in the rows (the typing is unflushed). When the target (or the Insert's anchor) is `.unresolved`
    // the typing is flushed ONCE, the rows and the table are read again and the target is resolved again; still unresolved takes the old
    // path with the existing log line. A table BEHIND the rows still takes the old path (tracked on the board).

    /// Replace Current Section, Markdown: the plan for restoring `snapshotSectionId`'s text over `targetSectionId`.
    func markdownSectionRestoreReplaceBuild(
        snapshotSectionId: String, targetSectionId: String, database db: ProjectDatabase, projectId pid: String
    ) async -> MarkdownRestoreBuild {
        let kind = EditorFirstOpKind.restoreSectionReplace
        guard let snapshotSection = try? db.fetchSnapshotSection(id: snapshotSectionId) else { return .legacy }
        var flushed = false
        while true {
            guard let sections = try? db.fetchSections(projectId: pid), let existing = try? db.fetchBlocks(projectId: pid) else {
                return .legacy
            }
            switch SnapshotService.resolveFlatSectionTarget(sectionId: targetSectionId, sections: sections, blocks: existing) {
            case .resolved(let heading, _):
                switch SnapshotService.sectionReplacePlan(
                    database: db, projectId: pid, snapshotSection: snapshotSection, target: heading, existing: existing,
                    sidebarAnchor: sidebarAnchor(before: heading.id)
                ) {
                case .plan(let built): return .ready(built, rootId: heading.id)
                case .legacy(let reason):
                    DebugLog.alwaysPersisted("[EF-STRUCT] \(kind.logName) fell back to the old path: \(reason) (project \(pid))")
                    return .legacy
                }
            case .unresolved(let reason):
                if !flushed {
                    flushed = true
                    if await flushTypingForMarkdownRetry(projectId: pid) { continue }
                }
                DebugLog.alwaysPersisted("[EF-STRUCT] \(kind.logName) target unresolved: \(reason) (project \(pid))")
                return .legacy
            }
        }
    }

    /// Insert as New Section, Markdown: the plan for restoring `snapshotSectionId`'s text as a new section after `insertAfterSectionId`
    /// (the window passes the last one; a Notes or Bibliography row, a row the table no longer has, and nil all mean "after the last
    /// block that is not Notes or Bibliography"). The page's `rootId` is the anchor section's HEADING (a leader), not the editor node
    /// the Rich Text payload uses; `jobAnchorBlockId` stays the last row of the same flat range.
    func markdownRestoreSectionDuplicateBuild(
        snapshotSectionId: String, insertAfterSectionId: String?, database db: ProjectDatabase, projectId pid: String
    ) async -> MarkdownRestoreBuild {
        let kind = EditorFirstOpKind.restoreSectionDuplicate
        guard let snapshotSection = try? db.fetchSnapshotSection(id: snapshotSectionId) else { return .legacy }
        var flushed = false
        while true {
            guard let sections = try? db.fetchSections(projectId: pid), let existing = try? db.fetchBlocks(projectId: pid) else {
                return .legacy
            }
            let anchors: MarkdownInsertAnchors
            switch markdownInsertAnchors(afterSectionId: insertAfterSectionId, sections: sections, existing: existing) {
            case .success(let resolved): anchors = resolved
            case .failure(let unresolved):
                if !flushed {
                    flushed = true
                    if await flushTypingForMarkdownRetry(projectId: pid) { continue }
                }
                DebugLog.alwaysPersisted("[EF-STRUCT] \(kind.logName) target unresolved: \(unresolved.reason) (project \(pid))")
                return .legacy
            }
            switch SnapshotService.insertAfterPlan(
                database: db, projectId: pid, snapshotSection: snapshotSection, anchorBlockId: anchors.anchorBlockId,
                jobAnchorBlockId: anchors.jobAnchorBlockId, existing: existing, sidebarAnchor: anchors.sidebarAnchor
            ) {
            case .plan(let built): return .ready(built, rootId: anchors.pageAnchorId)
            case .legacy(let reason):
                DebugLog.alwaysPersisted("[EF-STRUCT] \(kind.logName) fell back to the old path: \(reason) (project \(pid))")
                return .legacy
            }
        }
    }

    /// Where an Insert as New Section goes, for the Markdown builder: the anchor section's resolved pieces, as the Rich Text function
    /// above works them out, plus the anchor section's HEADING id (the page's `rootId`).
    private struct MarkdownInsertAnchors {
        var anchorBlockId: String?      // the editor's top-level node the copy goes after (the plan's payload; the page does not read it)
        var jobAnchorBlockId: String?   // the database row the job inserts it after (the last row of the same range)
        var pageAnchorId: String?       // the anchor section's heading
        var sidebarAnchor: RestoreAnchor?
    }

    private struct MarkdownAnchorUnresolved: Error {
        let reason: String
    }

    private func markdownInsertAnchors(
        afterSectionId: String?, sections: [Section], existing: [Block]
    ) -> Result<MarkdownInsertAnchors, MarkdownAnchorUnresolved> {
        var anchors = MarkdownInsertAnchors()
        if let afterId = afterSectionId,
           let afterSection = sections.first(where: { $0.id == afterId }), !afterSection.isBibliography, !afterSection.isNotes {
            switch SnapshotService.resolveFlatSectionTarget(sectionId: afterId, sections: sections, blocks: existing) {
            case .resolved(let heading, let nodeIds):
                anchors.anchorBlockId = nodeIds.last
                anchors.jobAnchorBlockId = SnapshotService.flatRange(of: heading.id, in: BlockParser.assemblySorted(existing)).last?.id
                anchors.pageAnchorId = heading.id
                anchors.sidebarAnchor = .after(heading.id)
            case .unresolved(let reason):
                return .failure(MarkdownAnchorUnresolved(reason: reason))
            }
        }
        if anchors.anchorBlockId == nil { anchors.sidebarAnchor = sidebarAnchorAfterLastUserSection() }
        return .success(anchors)
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
