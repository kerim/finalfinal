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

    @Test("delete removes the legacy section row for the deleted heading")
    @MainActor
    func deleteRemovesLegacySectionRow() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(blocks.first { $0.textContent == "Section A" })

        // Legacy section table: seed a row for the heading being deleted (production code
        // populates this via SectionSyncService; seeded directly here to isolate the
        // section-table cleanup this test targets).
        try db.insertSection(Section(
            id: sectionA.id, projectId: pid, sortOrder: 1, headerLevel: 2, title: "Section A"
        ))
        #expect(try db.fetchSection(id: sectionA.id) != nil)

        _ = try db.deleteSections(rootId: sectionA.id, projectId: pid)
        #expect(try db.fetchSection(id: sectionA.id) == nil)
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

    @Test("duplicate creates a legacy section row for the copy's heading")
    @MainActor
    func duplicateCreatesSectionRowForCopy() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(before.first { $0.textContent == "Section A" })

        _ = try #require(try db.duplicateSections(rootId: sectionA.id, projectId: pid))

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let copiedHeadingId = try #require(
            after.first { $0.textContent == "Section A copy" }?.id
        )

        let sectionRow = try db.fetchSection(id: copiedHeadingId)
        #expect(sectionRow != nil)
        #expect(sectionRow?.title == "Section A copy")
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
