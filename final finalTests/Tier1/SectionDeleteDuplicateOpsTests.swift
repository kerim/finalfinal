//
//  SectionDeleteDuplicateOpsTests.swift
//  final finalTests
//
//  Tier 1: sidebar section delete/duplicate forward DB ops. Exercises
//  Models/Database+SectionOps.swift directly -- the actual, only production implementation of
//  these operations (ContentView+SectionOperations.swift's Swift-level wrapper adds only
//  StructuralUndoController/editorState plumbing that can't be exercised without a live app;
//  there is no separate "DB-layer-only" reimplementation to diverge from what production runs).
//
//  Ported from the parked `sidebar-section-delete-dup` worktree
//  (docs/plans/patient-rewinding-clockwork.md §6/§7 Phase 4), adapted for this phase's DB-layer
//  API change: `deleteSections`/`duplicateSections` now return the affected section's title
//  (`String?`) rather than a `SectionOperationRecord`, because undo is no longer a verbatim
//  row-level inverse (`restoreDeletedBlocks`/`canUndoSectionOperation`/`deleteBlocks` are gone)
//  -- it's handled the same way as every other structural op, by restoring a forced
//  undo-point snapshot via StructuralUndoController.performUndo (see
//  StructuralUndoControllerTests.swift's sectionDelete/sectionDuplicate cases for that half).
//  The parked suite's undo/staleness-specific tests (`canUndoSectionOperation`,
//  `restoreDeletedBlocks`, `undoMenuTitleNamesAction`) are dropped for the same reason -- there
//  is nothing left in this file's API surface for them to exercise.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Section Operations — Tier 1: Sidebar delete/duplicate (forward ops)")
struct SectionDeleteDuplicateOpsTests {

    private static let content = """
    # Document

    Intro text.

    ## Section A

    Content A paragraph.

    ### Section A1

    Nested content A1.

    ## Section B

    Content B paragraph.
    """

    @Test("sectionBlockIds resolves heading + its own body + deeper descendants, stopping at a sibling")
    @MainActor
    func sectionBlockIdsResolvesSubtree() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(blocks.first { $0.textContent == "Section A" })

        let ids = try #require(try db.sectionBlockIds(rootId: sectionA.id, projectId: pid))
        let subtreeTexts = ids.compactMap { id in blocks.first { $0.id == id }?.textContent }

        // Section A's subtree: A itself, its body paragraph, A1 (deeper), A1's body -- NOT
        // Section B (a sibling, not deeper than A).
        #expect(subtreeTexts == ["Section A", "Content A paragraph.", "Section A1", "Nested content A1."])
    }

    @Test("sectionBlockIds/deleteSections/duplicateSections all refuse a bibliography section")
    @MainActor
    func refusesBibliography() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let bibId = UUID().uuidString
        try db.insertBlock(Block(
            id: bibId, projectId: pid, sortOrder: 1000, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography", headingLevel: 1,
            isBibliography: true
        ))

        #expect(try db.sectionBlockIds(rootId: bibId, projectId: pid) == nil)
        #expect(try db.deleteSections(rootId: bibId, projectId: pid) == nil)
        #expect(try db.duplicateSections(rootId: bibId, projectId: pid) == nil)

        // Refusal is a no-op, not a partial mutation -- the block must still be there.
        #expect(try db.fetchBlock(id: bibId) != nil)
    }

    @Test("sectionBlockIds/deleteSections/duplicateSections all refuse a notes section")
    @MainActor
    func refusesNotes() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let notesId = UUID().uuidString
        try db.insertBlock(Block(
            id: notesId, projectId: pid, sortOrder: 1000, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1,
            isNotes: true
        ))

        #expect(try db.sectionBlockIds(rootId: notesId, projectId: pid) == nil)
        #expect(try db.deleteSections(rootId: notesId, projectId: pid) == nil)
        #expect(try db.duplicateSections(rootId: notesId, projectId: pid) == nil)
    }

    @Test("delete removes exactly the subtree; sibling section's block/sortOrder is untouched; returns the deleted title")
    @MainActor
    func deleteRemovesOnlySubtree() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(before.first { $0.textContent == "Section A" })
        let sectionB = try #require(before.first { $0.textContent == "Section B" })

        let deletedTitle = try #require(try db.deleteSections(rootId: sectionA.id, projectId: pid))
        #expect(deletedTitle == "Section A")

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(!after.contains { $0.textContent == "Section A" })
        #expect(!after.contains { $0.textContent == "Section A1" })
        let sectionBAfter = try #require(after.first { $0.id == sectionB.id })
        #expect(sectionBAfter.sortOrder == sectionB.sortOrder)
    }

    @Test("delete does not touch a real section row -- convergence is SectionReconciler's job now (2026-08-22 fix)")
    @MainActor
    func deleteDoesNotTouchRealSectionRow() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(blocks.first { $0.textContent == "Section A" })

        // A REAL section row, seeded the way `SectionReconciler.reconcile()` actually creates
        // one in production: its OWN independently-generated UUID (`Section.swift`'s
        // `id: String = UUID().uuidString` default), NOT the heading's block id. This is the
        // exact shape of the bug found via Phase D's e2e suite: the OLD `deleteSections` deleted
        // `Section` rows by matching `Block` ids (`Section.filter(keys: blockIds)`) -- since
        // `block` and `section` share no ID space, that call matched zero rows every time,
        // silently, leaving this exact row (title "Section A", independent id) stranded forever.
        // This test's predecessor (`deleteRemovesLegacySectionRow`, removed) seeded the row
        // WRONGLY keyed by the block id, which is why it appeared to pass despite the
        // production code being broken -- it was testing a scenario that never occurs for real.
        let realSectionRow = Section(
            projectId: pid, sortOrder: 1, headerLevel: 2, title: "Section A"
        )
        try db.insertSection(realSectionRow)
        let realRowId = realSectionRow.id
        #expect(try db.fetchSection(id: realRowId) != nil, "sanity: the seeded row should exist before delete")

        _ = try #require(try db.deleteSections(rootId: sectionA.id, projectId: pid))

        // deleteSections alone must leave this row exactly as it was -- proves the removed
        // `Section.filter(keys:).deleteAll(db)` call (which never actually matched anything in
        // production) is genuinely gone, not silently still failing the same way. Actual
        // convergence (this row disappearing once the deleted heading is gone from the document)
        // is `StructuralUndoController.performStructuralOp`'s forced `SectionSyncService.syncNow`
        // resync, exercised end-to-end in `StructuralUndoControllerSectionConvergenceTests.swift`.
        #expect(try db.fetchSection(id: realRowId) != nil, "deleteSections must not touch the section table at all")
    }

    @Test("duplicate deep-copies the subtree with fresh ids, a \" copy\" heading suffix, and does not disturb any other block's sortOrder")
    @MainActor
    func duplicateDeepCopiesSubtree() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(before.first { $0.textContent == "Section A" })
        let sectionB = try #require(before.first { $0.textContent == "Section B" })

        let newTitle = try #require(try db.duplicateSections(rootId: sectionA.id, projectId: pid))
        #expect(newTitle == "Section A copy")

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(after.count == before.count + 4)
        #expect(Set(after.map(\.id)).isSuperset(of: Set(before.map(\.id))))

        let newBlocks = after.filter { block in !before.contains { $0.id == block.id } }
            .sorted { $0.sortOrder < $1.sortOrder }
        #expect(newBlocks.map(\.textContent) ==
                ["Section A copy", "Content A paragraph.", "Section A1", "Nested content A1."])
        #expect(newBlocks[0].markdownFragment == "## Section A copy")
        // Only the top heading gets the suffix -- the nested heading's title is untouched.
        #expect(newBlocks[2].textContent == "Section A1")

        // Placed strictly after the original subtree and before Section B; Section B itself
        // (and everything else) keeps its original sortOrder exactly.
        let sectionBAfter = try #require(after.first { $0.id == sectionB.id })
        #expect(sectionBAfter.sortOrder == sectionB.sortOrder)
        let originalLastBody = try #require(before.first { $0.textContent == "Nested content A1." })
        for copy in newBlocks {
            #expect(copy.sortOrder > originalLastBody.sortOrder)
            #expect(copy.sortOrder < sectionBAfter.sortOrder)
        }

        // Full document order: original subtree, then the copy, then Section B.
        let sortedTexts = after.sorted { $0.sortOrder < $1.sortOrder }.map(\.textContent)
        #expect(sortedTexts == [
            "Document", "Intro text.",
            "Section A", "Content A paragraph.", "Section A1", "Nested content A1.",
            "Section A copy", "Content A paragraph.", "Section A1", "Nested content A1.",
            "Section B", "Content B paragraph.",
        ])
    }

    @Test("duplicate's \" copy\"-suffixed heading gets a wordCount one higher than the original, not a stale pre-suffix count")
    @MainActor
    func duplicateHeadingWordCountReflectsCopySuffix() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(before.first { $0.textContent == "Section A" })
        let originalWordCount = sectionA.wordCount

        _ = try #require(try db.duplicateSections(rootId: sectionA.id, projectId: pid))

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let copiedHeading = try #require(after.first { $0.textContent == "Section A copy" })
        #expect(copiedHeading.wordCount == originalWordCount + 1)
    }

    @Test("duplicate does not create any section row keyed by the copy's block id -- that was a real, active data-corruption bug (2026-08-22 fix)")
    @MainActor
    func duplicateDoesNotOrphanSectionRow() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(before.first { $0.textContent == "Section A" })

        _ = try #require(try db.duplicateSections(rootId: sectionA.id, projectId: pid))

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let copiedHeadingId = try #require(
            after.first { $0.textContent == "Section A copy" }?.id
        )

        // The OLD (broken) behavior -- this test's predecessor, `duplicateCreatesSectionRowForCopy`,
        // removed -- inserted `Section(id: copy.id, ...)`, i.e. a `section` row keyed by this
        // exact fresh `block` id. Since every REAL `section` row gets its own independently-
        // generated UUID (`SectionReconciler.reconcile()`, never a `block` id), no reconciler
        // pass could ever find or prune a row planted under a `block` id -- this was a permanent
        // orphan created on EVERY sidebar duplicate, confirmed empirically (4 duplicates -> 4
        // accumulated orphan rows that never got cleaned up). `duplicateSections` must not touch
        // the `section` table at all; convergence (the copy correctly getting its own
        // independently-keyed row) is `StructuralUndoController.performStructuralOp`'s forced
        // `SectionSyncService.syncNow` resync, exercised end-to-end in
        // `StructuralUndoControllerSectionConvergenceTests.swift`.
        #expect(try db.fetchSection(id: copiedHeadingId) == nil, "duplicateSections must not insert a section row keyed by the copy's block id")
    }

    // MARK: - Annotation survival (parked worktree's must-fix #1, delete half)
    //
    // The legacy `annotation` table (the one actually driving the annotation panel --
    // `EditorViewState.startObservingAnnotations` observes it, and `AnnotationSyncService`'s
    // regex-based reconciliation is its only writer) has NO foreign key to `block` at all, so a
    // plain `deleteSections` call does nothing to it by itself -- production
    // (`StructuralUndoController.pushPostOpContentAndFinalize`, shared by every structural op
    // including sectionDelete/sectionDuplicate) closes that gap by forcing
    // `annotationSyncService.syncNow(editorState.content)` once the content push lands. This
    // test exercises that exact reconciliation entry point (`AnnotationSyncService.syncNowSync`,
    // the synchronous twin of `syncNow`) against markdown assembled from the real
    // `deleteSections` output, not a DB-layer approximation of it.
    @Test("delete then forced reconciliation removes the now-orphaned task annotation, not just leaves it dangling")
    @MainActor
    func deleteThenReconciliationRemovesOrphanedAnnotation() throws {
        let content = """
        # Document

        Intro text.

        ## Section A

        Content A paragraph.

        <!-- ::task:: [x] Completed task in A -->

        ## Section B

        Content B paragraph.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let contentId = try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM content LIMIT 1")!
        }
        let service = AnnotationSyncService()
        service.configure(database: db, contentId: contentId)

        // Establish the "before" annotation row exactly the way production does: parse the
        // assembled document markdown, reconcile against (empty) DB state.
        let beforeBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        service.syncNowSync(BlockParser.assembleMarkdown(from: beforeBlocks))
        let beforeAnnotations = try db.fetchAnnotations(contentId: contentId).filter { !$0.isDocumentLevel }
        let originalTask = try #require(beforeAnnotations.first { $0.type == .task })
        #expect(originalTask.isCompleted == true)

        let sectionA = try #require(beforeBlocks.first { $0.textContent == "Section A" })
        _ = try #require(try db.deleteSections(rootId: sectionA.id, projectId: pid))

        // Reconcile against the post-delete document -- same forced call
        // pushPostOpContentAndFinalize makes -- and confirm the now-orphaned annotation row is
        // actually cleaned up, not just ignored, since the section's markdown is gone.
        let afterDeleteBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        service.syncNowSync(BlockParser.assembleMarkdown(from: afterDeleteBlocks))
        let afterDeleteAnnotations = try db.fetchAnnotations(contentId: contentId).filter { !$0.isDocumentLevel }
        #expect(!afterDeleteAnnotations.contains { $0.id == originalTask.id })
    }
}
