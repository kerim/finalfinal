//
//  StructuralUndoControllerReorderTests.swift
//  final finalTests
//
//  Split out of StructuralUndoControllerTests.swift to keep that file's struct body under
//  SwiftLint's type_body_length limit -- see the header comment there for the full Tier 1 /
//  Phase 3 unified-undo background. This file covers Phase 7's sidebar drag-reorder tests
//  (undo/redo/chronological-order interplay) plus the MF-1 zoomed-reorder regressions, using
//  the shared `makeReorderFixture()` / `swapSections()` helpers defined in
//  StructuralUndoControllerTests.swift. The must-fix 3/4/5 restore-replace, annotation-sync,
//  and cancelPendingInsertions tests that used to live in this file moved to
//  StructuralUndoControllerSourceModeAndAnnotationSyncTests.swift.
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension StructuralUndoControllerTests {

    @Test("performSectionReorder undo reverts the section order to pre-reorder")
    func performSectionReorderUndoRevertsOrder() async throws {
        let fixture = try makeReorderFixture()
        let swapped = try swapSections(fixture.editorState.sections, "Methodology", "Results and Discussion")

        let outcome = await fixture.controller.performSectionReorder(sections: swapped)
        #expect(outcome == .performed)
        let entry = try #require(fixture.unifiedUndoService.undoStack.last)

        await fixture.controller.handleStructuralRequest(opId: entry.id.uuidString, direction: .undo)
        #expect(fixture.unifiedUndoService.redoStack.last?.id == entry.id, "a successful undo moves the entry to the redo stack")
        #expect(fixture.unifiedUndoService.undoStack.isEmpty)

        let afterUndoTitles = try fixture.db.fetchOutlineBlocks(projectId: fixture.pid).map(\.outlineTitle)
        let methodologyIdx = try #require(afterUndoTitles.firstIndex(of: "Methodology"))
        let resultsIdx = try #require(afterUndoTitles.firstIndex(of: "Results and Discussion"))
        #expect(methodologyIdx < resultsIdx, "undo must restore Methodology before Results and Discussion (pre-reorder order)")
    }

    @Test("Combined scenario: restore then reorder then undo twice undoes both, in correct chronological order (plan §7's motivating gap)")
    func restoreThenReorderThenUndoTwiceInChronologicalOrder() async throws {
        let fixture = try makeReorderFixture()
        let snapshotService = SnapshotService(database: fixture.db, projectId: fixture.pid)
        let pristineSnapshot = try snapshotService.createManualSnapshot(name: "Pristine")

        // Mutate the live document (simulating an edit made after the snapshot) so the
        // upcoming restore is actually detectable -- mirrors makeFixture()'s reasoning for the
        // other restore tests. performStructuralOp's step 2 (modeAwareFlush) reparses
        // editorState.content into the DB in WYSIWYG mode (the fixture default) BEFORE the
        // restore's own DB read, so setting editorState.content here (rather than poking the
        // Block table directly) is what actually lands this as "the current DB state" at the
        // moment the restore runs -- see performSectionDeleteRefusesBibliography's matching
        // comment for the same mechanism.
        let mutatedContent = TestFixtureFactory.richTestContent.replacingOccurrences(
            of: "This study employs a mixed-methods approach",
            with: "MUTATED body -- if this text survives the restore, the restore is broken"
        )
        fixture.editorState.content = mutatedContent

        // 1. Restore -- reverts the mutation, records a .restoreProject entry.
        let restoreOk = await fixture.controller.performRestoreProject(
            snapshotId: pristineSnapshot.id, requestingProjectId: fixture.pid
        )
        #expect(restoreOk == .performed)
        let restoreEntry = try #require(fixture.unifiedUndoService.undoStack.last)
        #expect(restoreEntry.kind == .restoreProject)

        let afterRestoreBlocks = try fixture.db.fetchBlocks(projectId: fixture.pid)
        #expect(!afterRestoreBlocks.contains { $0.markdownFragment.contains("MUTATED body") })
        #expect(afterRestoreBlocks.contains { $0.markdownFragment.contains("This study employs a mixed-methods approach") })

        // 2. Reorder -- the natural follow-up to a restore landing a section in the wrong
        // place (the exact combined workflow this phase exists to support). Restoring a whole
        // project mints fresh block ids (SnapshotService.restoreEntireProject deletes/reinserts
        // everything), so the sections to swap must be re-read AFTER the restore, not reused
        // from before it.
        let postRestoreSections = fixture.editorState.sections
        let swapped = try swapSections(postRestoreSections, "Methodology", "Results and Discussion")
        let reorderOk = await fixture.controller.performSectionReorder(sections: swapped)
        #expect(reorderOk == .performed)
        let reorderEntry = try #require(fixture.unifiedUndoService.undoStack.last)
        #expect(reorderEntry.kind == .sectionReorder)
        #expect(fixture.unifiedUndoService.undoStack.map(\.id) == [restoreEntry.id, reorderEntry.id],
                "both ops must be on the undo stack, oldest first")

        // 3. Undo #1 -- must undo the REORDER (last-in, first-out), not the restore.
        await fixture.controller.handleStructuralRequest(opId: reorderEntry.id.uuidString, direction: .undo)
        #expect(fixture.unifiedUndoService.undoStack.map(\.id) == [restoreEntry.id],
                "after one undo, only the restore entry remains on the undo stack")
        #expect(fixture.unifiedUndoService.redoStack.map(\.id) == [reorderEntry.id])

        let afterFirstUndoTitles = try fixture.db.fetchOutlineBlocks(projectId: fixture.pid).map(\.outlineTitle)
        let methodologyIdx = try #require(afterFirstUndoTitles.firstIndex(of: "Methodology"))
        let resultsIdx = try #require(afterFirstUndoTitles.firstIndex(of: "Results and Discussion"))
        #expect(methodologyIdx < resultsIdx, "undoing the reorder must restore the post-restore (pre-reorder) order")

        // 4. Undo #2 -- must undo the RESTORE, bringing the mutated text back.
        await fixture.controller.handleStructuralRequest(opId: restoreEntry.id.uuidString, direction: .undo)
        #expect(fixture.unifiedUndoService.undoStack.isEmpty, "both entries now undone")
        #expect(fixture.unifiedUndoService.redoStack.map(\.id) == [reorderEntry.id, restoreEntry.id],
                "redo stack holds both entries, most-recently-undone (the restore) on top")

        let afterSecondUndoBlocks = try fixture.db.fetchBlocks(projectId: fixture.pid)
        #expect(afterSecondUndoBlocks.contains { $0.markdownFragment.contains("MUTATED body") },
                "undoing the restore must bring back the pre-restore mutation")
    }

    @Test(
        """
        MF-1 (review round): performSectionReorder succeeds while zoomed instead of refusing (zoomed reorder is \
        a deliberately shipped feature, git history 12cef025 -- not an accident)
        """
    )
    func performSectionReorderSucceedsWhileZoomed() async throws {
        let fixture = try makeReorderFixture()
        let before = fixture.editorState.sections
        let methodologySection = try #require(before.first { $0.title == "Methodology" })
        fixture.editorState.zoomedSectionId = methodologySection.id
        fixture.editorState.zoomedSectionIds = [methodologySection.id]

        let swapped = try swapSections(before, "Methodology", "Results and Discussion")

        let outcome = await fixture.controller.performSectionReorder(sections: swapped)
        #expect(outcome == .performed, "a reorder while zoomed must succeed under .allowWhileZoomed, not refuse under .refuseIfZoomed")

        let entry = try #require(fixture.unifiedUndoService.undoStack.last)
        #expect(entry.kind == .sectionReorder)

        let afterTitles = try fixture.db.fetchOutlineBlocks(projectId: fixture.pid).map(\.outlineTitle)
        let methodologyIdx = try #require(afterTitles.firstIndex(of: "Methodology"))
        let resultsIdx = try #require(afterTitles.firstIndex(of: "Results and Discussion"))
        #expect(resultsIdx < methodologyIdx, "Results and Discussion must now sort before Methodology, even though the reorder ran while zoomed")
    }

    @Test("MF-1 (review round): undoing a reorder recorded while zoomed zooms back out")
    func undoingReorderRecordedWhileZoomedZoomsOut() async throws {
        let fixture = try makeReorderFixture()
        let before = fixture.editorState.sections
        let methodologySection = try #require(before.first { $0.title == "Methodology" })
        fixture.editorState.zoomedSectionId = methodologySection.id
        fixture.editorState.zoomedSectionIds = [methodologySection.id]

        let swapped = try swapSections(before, "Methodology", "Results and Discussion")
        let outcome = await fixture.controller.performSectionReorder(sections: swapped)
        #expect(outcome == .performed)
        #expect(
            fixture.editorState.zoomedSectionId != nil,
            "fixture precondition: .allowWhileZoomed does not zoom out on its own, unlike .autoZoomOut"
        )

        let entry = try #require(fixture.unifiedUndoService.undoStack.last)
        await fixture.controller.handleStructuralRequest(opId: entry.id.uuidString, direction: .undo)

        #expect(
            fixture.editorState.zoomedSectionId == nil,
            """
            performUndo must zoom out before restoring -- restoreEntireProject mints fresh section ids, so \
            leaving the old zoomedSectionId in place would strand it on an id that no longer exists post-restore
            """
        )
        #expect(fixture.unifiedUndoService.redoStack.last?.id == entry.id)
    }

}
