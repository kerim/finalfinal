//
//  BibliographyDropGuardTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for bibliography and notes position protection during reorder.
//  Bibliography/notes appearing in wrong positions corrupts document structure
//  and is masked by display-layer sorting until next DB read.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Bibliography Drop Guard — Tier 1: Silent Killers")
struct BibliographyDropGuardTests {

    // MARK: - Bibliography Position Tests

    @Test("Bibliography remains at end after reorder moves section after it")
    @MainActor
    func bibliographyRemainsAtEnd() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = TestFixtureFactory.headingBlocks(blocks)

        // Find bibliography and a regular section
        let bibHeading = headings.first { $0.isBibliography }
        let regularHeading = headings.first { !$0.isBibliography && !$0.isNotes && $0.textContent != "Research Paper Draft" }

        #expect(bibHeading != nil, "Rich content should have a bibliography heading")
        #expect(regularHeading != nil, "Rich content should have a regular heading")

        // Build sections and attempt to place a regular section after bibliography
        var sections = headings.map { SectionViewModel(from: $0) }

        // Current order has bibliography near end. Reorder to put a section after it.
        if let bibIdx = sections.firstIndex(where: { $0.isBibliography }),
           let regIdx = sections.firstIndex(where: { $0.id == regularHeading!.id }) {

            // Move the regular section to after bibliography
            let moved = sections.remove(at: regIdx)
            let insertIdx = bibIdx < sections.count ? bibIdx + 1 : sections.count
            sections.insert(moved, at: insertIdx)
        }

        try db.reorderAllBlocks(sections: sections, projectId: pid)

        // Verify the resulting block order
        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let headingsAfter = TestFixtureFactory.headingBlocks(blocksAfter)

        // t-0b70d1e9 (C1) closed the gap this test used to document: reorderAllBlocks now resolves
        // Notes and Bibliography from the LIVE rows and puts them last, whatever order it receives.
        let bibIdx = headingsAfter.firstIndex { $0.isBibliography }
        let movedIdx = headingsAfter.firstIndex { $0.id == regularHeading!.id }

        #expect(bibIdx != nil, "Bibliography heading should still exist")
        #expect(movedIdx != nil, "Moved heading should still exist")

        // The guard: bibliography IS last, the moved section lands before it (the test's own title).
        if let bIdx = bibIdx, let mIdx = movedIdx {
            #expect(mIdx < bIdx,
                    "With the guard: the moved section is placed before bibliography, which stays at the end")
        }
    }

    @Test("Notes section is preserved during reorder")
    @MainActor
    func notesSectionPreserved() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = TestFixtureFactory.headingBlocks(blocks)

        let notesHeading = headings.first { $0.isNotes }
        #expect(notesHeading != nil, "Rich content should have a Notes heading")

        // Reorder: reverse all sections
        var sections = headings.map { SectionViewModel(from: $0) }
        sections.reverse()

        try db.reorderAllBlocks(sections: sections, projectId: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let headingsAfter = TestFixtureFactory.headingBlocks(blocksAfter)

        // Notes heading should still exist with its content
        let notesAfter = headingsAfter.first { $0.isNotes }
        #expect(notesAfter != nil, "Notes heading should survive reorder")
        #expect(notesAfter?.textContent == "Notes", "Notes title should be preserved")
    }

    @Test("reorderAllBlocks preserves bibliography/notes flags")
    @MainActor
    func reorderPreservesBibNotesFlags() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = TestFixtureFactory.headingBlocks(blocks)

        // Count bibliography and notes blocks before
        let bibCountBefore = blocks.filter { $0.isBibliography }.count
        let notesCountBefore = blocks.filter { $0.isNotes }.count

        #expect(bibCountBefore > 0, "Should have bibliography blocks")
        #expect(notesCountBefore > 0, "Should have notes blocks")

        // Do a simple reorder (swap two regular sections)
        var sections = headings.map { SectionViewModel(from: $0) }
        let regularIndices = sections.indices.filter {
            !sections[$0].isBibliography && !sections[$0].isNotes
        }
        if regularIndices.count >= 2 {
            sections.swapAt(regularIndices[0], regularIndices[1])
        }

        try db.reorderAllBlocks(sections: sections, projectId: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let bibCountAfter = blocksAfter.filter { $0.isBibliography }.count
        let notesCountAfter = blocksAfter.filter { $0.isNotes }.count

        #expect(bibCountAfter == bibCountBefore,
                "Bibliography flag count should be preserved after reorder")
        #expect(notesCountAfter == notesCountBefore,
                "Notes flag count should be preserved after reorder")
    }

    @Test("reorderAllBlocks preserves all blocks (no data loss)")
    @MainActor
    func reorderPreservesAllBlocks() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = TestFixtureFactory.headingBlocks(blocks)
        let blockCountBefore = blocks.count

        // Reverse all sections
        var sections = headings.map { SectionViewModel(from: $0) }
        sections.reverse()

        try db.reorderAllBlocks(sections: sections, projectId: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(blocksAfter.count == blockCountBefore,
                "Reorder must not lose or duplicate blocks")
    }

    @Test("Sort orders are valid after reorder with bibliography")
    @MainActor
    func sortOrdersValidAfterReorder() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = TestFixtureFactory.headingBlocks(blocks)

        // Shuffle regular sections
        var sections = headings.map { SectionViewModel(from: $0) }
        let regularIndices = sections.indices.filter {
            !sections[$0].isBibliography && !sections[$0].isNotes
        }
        if regularIndices.count >= 3 {
            // Move last regular to first regular position
            let last = sections.remove(at: regularIndices.last!)
            sections.insert(last, at: regularIndices.first!)
        }

        try db.reorderAllBlocks(sections: sections, projectId: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)

        // All sort orders must be monotonically increasing
        for i in 1..<blocksAfter.count {
            #expect(blocksAfter[i].sortOrder > blocksAfter[i-1].sortOrder,
                    "Sort orders must increase: block[\(i-1)]=\(blocksAfter[i-1].sortOrder), block[\(i)]=\(blocksAfter[i].sortOrder)")
        }

        // All sort orders must be distinct
        let sortOrders = blocksAfter.map { $0.sortOrder }
        #expect(Set(sortOrders).count == sortOrders.count,
                "All sort orders must be distinct")
    }
}
