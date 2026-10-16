//
//  QuickUndoSidebarRestoreTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2b; the first real-app runs, VM test testQuickUndoTiming_article): the sidebar and the hierarchy
//  after the quick undo, driven with `EditorFirstRig` (EditorFirstDeleteTests.swift). Shared helpers: QuickUndoFixtures.swift. The pure
//  overlay, the editor state's merge and the enforcement predicate are in Tier1/SidebarRestoreOverlayTests.swift.
//    - U-Q40 (sw66)  the quick undo of the article's last body section before Notes: the sidebar lists its sub-headings right after the
//                    heading that stood before it (no hierarchy violation), their levels in the database are unchanged, the redo stays
//    - U-Q41b (sw68) the REAL sections-updated handler (the static factory): no enforcement while a restore is pending, enforcement when not
//    - U-Q41c (sw73) the same handler inside the sidebar update's own window (the reinsert resolved, the update waiting for the frame)
//  The deferred sidebar update (U-Q43 ... U-Q46) is in QuickUndoDeferredSidebarTests.swift.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Quick undo: the sidebar and the hierarchy after the restore (Phase 4b slice 2b, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct QuickUndoSidebarRestoreTests: QuickUndoFixtures {

    /// The section the first VM run deleted: the last one before the Conclusion and Notes, with two sub-headings.
    private static let lastBodySection = "1.5 Lanterns After Dark"

    /// The headings whose level in the database is not the one they had in `levels`.
    private func changedLevels(_ rig: EditorFirstRig, since levels: [String: Int]) throws -> [String] {
        try rig.blocks().filter { block in levels[block.id].map { $0 != (block.headingLevel ?? 1) } ?? false }.map(\.textContent)
    }

    @Test("U-Q40 (VM bug): the quick undo of the last body section keeps its sub-headings in place, their levels, and the redo")
    func testQuickUndoOfTheLastBodySectionKeepsItsSubheadingLevelAndTheRedoStack_article() async throws {
        let rig = try makeArticleRig()
        let outlineBefore = try rig.db.fetchOutlineBlocks(projectId: rig.pid)
        let levels = Dictionary(uniqueKeysWithValues: outlineBefore.map { ($0.id, $0.headingLevel ?? 1) })
        let deleted = try await delete(rig, Self.lastBodySection)
        let blocker = try rig.holdQueue()   // the reinsert waits behind it: the database lacks the section, the sidebar shows the overlay
        defer { rig.release(blocker) }

        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        await rig.editorState.refreshSectionsAwaiting()

        let whilePending = sidebarOrderProblem(rig, expected: outlineBefore)
        #expect(whilePending == nil, "the sidebar while the reinsert is pending: \(whilePending ?? "")")
        let pendingViolations = ContentView.hasHierarchyViolations(in: rig.editorState.sections)
        #expect(!pendingViolations, "expected no hierarchy violation in the sidebar while the reinsert is pending")

        rig.release(blocker)
        let settled = await rig.waitUntilSettled(iterations: 1500)
        #expect(settled)
        await rig.editorState.refreshSectionsAwaiting()

        let afterReinsert = sidebarOrderProblem(rig, expected: outlineBefore)
        #expect(afterReinsert == nil, "the sidebar once the rows are back: \(afterReinsert ?? "")")
        let changed = try changedLevels(rig, since: levels)
        #expect(changed.isEmpty, "expected every heading to keep its level in the database, changed: \(changed.prefix(3))")
        #expect(rig.unifiedUndo.redoStack.last?.id == deleted.entry.id, "the redo stack still holds the entry")
        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
    }

    /// The sections list the first VM run had while the restore was pending: the document's outline with its last sub-heading behind
    /// "Notes" (level 3 after a level 1 heading), which is what the stale sort-order rule produced.
    private func violatingSections(from outline: [Block]) -> [SectionViewModel] {
        var blocks = outline
        if let sub = blocks.lastIndex(where: { ($0.headingLevel ?? 1) == 3 }) {
            let moved = blocks.remove(at: sub)
            if let notes = blocks.firstIndex(where: \.isNotes) { blocks.insert(moved, at: notes + 1) }
        }
        return blocks.map { SectionViewModel(from: $0) }
    }

    /// What `DocumentManager.shared` (process-wide) held before a test pointed it at its own project.
    private struct DocumentManagerState {
        let controller: StructuralUndoController?
        let database: ProjectDatabase?
        let projectId: String?
    }

    /// `persistEnforcedSections` reads the structural controller, the database and the project id from `DocumentManager.shared`.
    private func wireDocumentManager(to rig: EditorFirstRig) -> DocumentManagerState {
        let prior = DocumentManagerState(
            controller: DocumentManager.shared.structuralUndoController, database: DocumentManager.shared.projectDatabase,
            projectId: DocumentManager.shared.projectId)
        DocumentManager.shared.structuralUndoController = rig.controller
        DocumentManager.shared.projectDatabase = rig.db
        DocumentManager.shared.projectId = rig.pid
        return prior
    }

    @Test("U-Q41b (VM bug): the sections-updated handler does not enforce the hierarchy while a restore is pending, and does when none is")
    func testSectionsUpdatedDoesNotEnforceHierarchyWhileAQuickUndoRestoreIsPending_article() async throws {
        let rig = try makeArticleRig()
        let prior = wireDocumentManager(to: rig)
        defer {
            DocumentManager.shared.structuralUndoController = prior.controller
            DocumentManager.shared.projectDatabase = prior.database
            DocumentManager.shared.projectId = prior.projectId
        }
        let syncService = SectionSyncService()   // the handler holds it weakly
        let handler = ContentView.makeSectionsUpdatedHandler(for: rig.editorState, syncService: syncService)
        let outlineBefore = try rig.db.fetchOutlineBlocks(projectId: rig.pid)
        let levels = Dictionary(uniqueKeysWithValues: outlineBefore.map { ($0.id, $0.headingLevel ?? 1) })
        let deleted = try await delete(rig, Self.lastBodySection)
        let blocker = try rig.holdQueue()   // the reinsert waits behind it: the restore is pending
        defer { rig.release(blocker) }
        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        await rig.editorState.refreshSectionsAwaiting()
        let violating = violatingSections(from: outlineBefore)
        let violatingLevels = violating.map(\.headerLevel)
        func patchedInMemory() -> Int { zip(rig.editorState.sections, violatingLevels).filter { $0.0.headerLevel != $0.1 }.count }

        // While the restore is pending the list is partly overlay: the handler must leave it alone.
        rig.editorState.sections = violating
        #expect(ContentView.hierarchyEnforcementWaitsForQuickUndo(rig.editorState), "precondition: a restore is pending")
        #expect(ContentView.hasHierarchyViolations(in: rig.editorState.sections), "precondition: the list violates the hierarchy")
        #expect(rig.editorState.contentState == .idle, "precondition: the handler is not held back by a transition")
        handler()
        let started = await gateWaitUntil({ rig.editorState.contentState != .idle || rig.unifiedUndo.redoStack.isEmpty }, iterations: 60)
        let redoCount = rig.unifiedUndo.redoStack.count
        let patched = patchedInMemory()
        #expect(
            !started && patched == 0 && redoCount == 1,
            "expected no hierarchy enforcement (no patch, redo intact) while the restore was pending, got \(patched) patched, redo \(redoCount)")
        #expect(try changedLevels(rig, since: levels).isEmpty, "no heading level was written to the database")

        // Control: once nothing is pending the very same handler does start enforcement (and that is what wipes the redo stack).
        rig.release(blocker)
        let settled = await rig.waitUntilSettled(iterations: 1500)
        #expect(settled)
        await rig.editorState.refreshSectionsAwaiting()
        #expect(!ContentView.hierarchyEnforcementWaitsForQuickUndo(rig.editorState), "precondition: nothing is pending any more")
        rig.editorState.sections = violating
        handler()
        let enforced = await gateWaitUntil({ rig.unifiedUndo.redoStack.isEmpty }, iterations: 600)
        let redoLeft = rig.unifiedUndo.redoStack.count
        #expect(enforced, "control: with nothing pending the same handler must start enforcement (redo stack \(redoLeft))")
        let finished = await gateWaitUntil({ rig.editorState.contentState == .idle && ((try? changedLevels(rig, since: levels))?.isEmpty == false) })
        #expect(finished, "control: the enforcement patches the sub-heading's level in the database")
    }

    @Test("U-Q41c (VM measurement): the handler does not enforce while only the sidebar update's window is open (the reinsert has resolved)")
    func testSectionsUpdatedDoesNotEnforceHierarchyWhileTheSidebarUpdateWaits_article() async throws {
        let rig = try makeArticleRig()
        let prior = wireDocumentManager(to: rig)
        defer {
            DocumentManager.shared.structuralUndoController = prior.controller
            DocumentManager.shared.projectDatabase = prior.database
            DocumentManager.shared.projectId = prior.projectId
        }
        let syncService = SectionSyncService()   // the handler holds it weakly
        let handler = ContentView.makeSectionsUpdatedHandler(for: rig.editorState, syncService: syncService)
        let outlineBefore = try rig.db.fetchOutlineBlocks(projectId: rig.pid)
        let deleted = try await delete(rig, Self.lastBodySection)
        let paint = LifecycleEntryHarness.Gate()   // the editor's next frame: the sidebar update waits for it
        defer { paint.open() }
        rig.controller.testNextPaintWait = { await paint.wait() }
        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        // The window: the reinsert has put the rows back (nothing pending there, no overlay), the sidebar update is still waiting.
        let resolved = await gateWaitUntil({ rig.editorState.pendingReinsertCount == 0 })
        #expect(resolved, "precondition: the reinsert's job has resolved")
        let onlyTheUpdateWaits = rig.editorState.pendingRestoreSections.isEmpty && rig.editorState.pendingSidebarRestoreCount == 1
        #expect(onlyTheUpdateWaits, "precondition: only the sidebar update waits")
        let violating = violatingSections(from: outlineBefore)
        let violatingLevels = violating.map(\.headerLevel)
        rig.editorState.sections = violating
        #expect(ContentView.hasHierarchyViolations(in: rig.editorState.sections), "precondition: the list violates the hierarchy")

        handler()
        let started = await gateWaitUntil({ rig.editorState.contentState != .idle || rig.unifiedUndo.redoStack.isEmpty }, iterations: 60)
        let patched = zip(rig.editorState.sections, violatingLevels).filter { $0.0.headerLevel != $0.1 }.count
        let redoCount = rig.unifiedUndo.redoStack.count
        #expect(
            !started && patched == 0 && redoCount == 1,
            "expected no hierarchy enforcement while the sidebar update waited, got \(patched) patched, redo \(redoCount)")

        paint.open()
        let settled = await rig.waitUntilSettled(iterations: 1500)
        #expect(settled)
    }
}
