//
//  BatchWordCountsTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for ProjectDatabase.batchWordCounts — the single source of truth
//  for sidebar/heading word counts. Boundary mistakes here silently misreport
//  goal progress and section sizes. Every case below pins behavior the user
//  observes in the outline sidebar.
//

import Testing
import Foundation
import GRDB
@testable import final_final

// Test suite covers many boundary cases; each is short but the total exceeds
// the default struct-body threshold. Splitting by @Suite doesn't help readability.
// swiftlint:disable type_body_length

@Suite("Batch Word Counts — Tier 1: Silent Killers")
struct BatchWordCountsTests {

    // MARK: - Helpers

    /// Build a doc with predictable per-block word counts so totals are easy to verify.
    /// Each non-heading paragraph contains exactly the requested number of words.
    private func makeDoc() -> String {
        return """
        # Top Level Heading

        Top intro one two three four.

        ## Section A

        Section A paragraph alpha beta.

        ### Subsection A1

        Sub A1 paragraph gamma.

        ## Section B

        Section B paragraph delta epsilon zeta.

        # Second Top Level

        Second intro paragraph.
        """
    }

    private func headingByText(_ blocks: [Block], _ text: String) -> Block? {
        blocks.first { $0.blockType == .heading && $0.textContent == text }
    }

    // MARK: - Empty / Edge Inputs

    @Test("Empty blockIds returns empty result")
    @MainActor
    func emptyBlockIds() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let result = try db.batchWordCounts(blockIds: [], needsAggregate: [])
        #expect(result.isEmpty)
    }

    @Test("Unknown blockId is absent from result (not crash, not zero)")
    @MainActor
    func unknownBlockId() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let result = try db.batchWordCounts(blockIds: ["does-not-exist"], needsAggregate: [])
        #expect(result["does-not-exist"] == nil)
        #expect(result.isEmpty)
    }

    @Test("Non-heading block IDs are filtered out")
    @MainActor
    func nonHeadingFiltered() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let paragraph = blocks.first(where: { $0.blockType == .paragraph }) else {
            Issue.record("No paragraph block in fixture"); return
        }
        let result = try db.batchWordCounts(blockIds: [paragraph.id], needsAggregate: [])
        #expect(result[paragraph.id] == nil)
    }

    // MARK: - Section-Only Counts

    @Test("Section-only count covers heading + content up to next heading of any level")
    @MainActor
    func sectionOnlyStopsAtNextHeading() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let topHeading = headingByText(blocks, "Top Level Heading") else {
            Issue.record("Top heading missing"); return
        }
        let result = try db.batchWordCounts(blockIds: [topHeading.id], needsAggregate: [])
        guard let counts = result[topHeading.id] else {
            Issue.record("No counts for top heading"); return
        }
        // "Top Level Heading" (3) + "Top intro one two three four." (6) = 9
        // Stops at "## Section A"
        #expect(counts.sectionOnly == 9)
    }

    @Test("Section-only for a sub-heading covers only its own paragraph")
    @MainActor
    func sectionOnlyForSubHeading() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let h2 = headingByText(blocks, "Section A") else {
            Issue.record("Section A missing"); return
        }
        let result = try db.batchWordCounts(blockIds: [h2.id], needsAggregate: [])
        guard let counts = result[h2.id] else {
            Issue.record("No counts for Section A"); return
        }
        // "Section A" (2) + "Section A paragraph alpha beta." (5) = 7
        // Stops at "### Subsection A1"
        #expect(counts.sectionOnly == 7)
    }

    @Test("Section-only for last heading runs to end of document")
    @MainActor
    func sectionOnlyForLastHeading() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let last = headingByText(blocks, "Second Top Level") else {
            Issue.record("Last heading missing"); return
        }
        let result = try db.batchWordCounts(blockIds: [last.id], needsAggregate: [])
        guard let counts = result[last.id] else {
            Issue.record("No counts for last heading"); return
        }
        // "Second Top Level" (3) + "Second intro paragraph." (3) = 6
        #expect(counts.sectionOnly == 6)
    }

    // MARK: - Aggregate Counts

    @Test("Aggregate count for H1 spans all sub-headings until next H1")
    @MainActor
    func aggregateForH1() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let topH1 = headingByText(blocks, "Top Level Heading") else {
            Issue.record("Top H1 missing"); return
        }
        let result = try db.batchWordCounts(
            blockIds: [topH1.id],
            needsAggregate: [topH1.id]
        )
        guard let counts = result[topH1.id] else {
            Issue.record("No counts for top H1"); return
        }
        // Aggregate goes from "Top Level Heading" through everything until "Second Top Level":
        //   "Top Level Heading" (3) + "Top intro one two three four." (6) +
        //   "Section A" (2) + "Section A paragraph alpha beta." (5) +
        //   "Subsection A1" (2) + "Sub A1 paragraph gamma." (4) +
        //   "Section B" (2) + "Section B paragraph delta epsilon zeta." (6) = 30
        #expect(counts.aggregate == 30)
    }

    @Test("Aggregate count for H2 includes its H3 children but stops at next H2")
    @MainActor
    func aggregateForH2() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let h2 = headingByText(blocks, "Section A") else {
            Issue.record("Section A missing"); return
        }
        let result = try db.batchWordCounts(
            blockIds: [h2.id],
            needsAggregate: [h2.id]
        )
        guard let counts = result[h2.id] else {
            Issue.record("No counts for Section A"); return
        }
        // Aggregate for Section A:
        //   "Section A" (2) + "Section A paragraph alpha beta." (5) +
        //   "Subsection A1" (2) + "Sub A1 paragraph gamma." (4) = 13
        // Stops at "## Section B" (next H2)
        #expect(counts.aggregate == 13)
    }

    @Test("Aggregate equals sectionOnly when needsAggregate is not set")
    @MainActor
    func aggregateDefaultsToSectionOnly() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let topH1 = headingByText(blocks, "Top Level Heading") else {
            Issue.record("Top H1 missing"); return
        }
        // needsAggregate empty: aggregate field equals sectionOnly (cheap path)
        let result = try db.batchWordCounts(
            blockIds: [topH1.id],
            needsAggregate: []
        )
        guard let counts = result[topH1.id] else {
            Issue.record("No counts for top H1"); return
        }
        #expect(counts.aggregate == counts.sectionOnly)
    }

    // MARK: - Heading Self-Inclusion

    @Test("Heading block's own word count is included in section-only exactly once")
    @MainActor
    func headingIncludedOnce() throws {
        // Doc with one heading, one paragraph.
        let doc = """
        # OneTwo

        Three four five six seven.
        """
        let db = try TestFixtureFactory.createTemporary(content: doc)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let heading = blocks.first(where: { $0.blockType == .heading }) else {
            Issue.record("Heading missing"); return
        }
        let result = try db.batchWordCounts(blockIds: [heading.id], needsAggregate: [heading.id])
        guard let counts = result[heading.id] else {
            Issue.record("No counts"); return
        }
        // Heading "OneTwo" (1) + paragraph "Three four five six seven." (5) = 6
        #expect(counts.sectionOnly == 6)
        #expect(counts.aggregate == 6)
    }

    // MARK: - Code Blocks Excluded

    @Test("Code block words don't count toward heading totals")
    @MainActor
    func codeBlockExcluded() throws {
        let doc = """
        # Section

        Real prose here.

        ```swift
        let x = 1
        let y = 2
        let z = 3
        ```

        More prose.
        """
        let db = try TestFixtureFactory.createTemporary(content: doc)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let heading = blocks.first(where: { $0.blockType == .heading }) else {
            Issue.record("Heading missing"); return
        }
        let result = try db.batchWordCounts(blockIds: [heading.id], needsAggregate: [])
        guard let counts = result[heading.id] else {
            Issue.record("No counts"); return
        }
        // Heading "Section" (1) + "Real prose here." (3) + code block (0) +
        // "More prose." (2) = 6
        #expect(counts.sectionOnly == 6)
    }

    // MARK: - Multiple Headings in One Call

    @Test("Multiple heading IDs are all returned with correct counts")
    @MainActor
    func multipleHeadingsBatched() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let allHeadings = blocks.filter { $0.blockType == .heading }
        let ids = allHeadings.map { $0.id }
        let result = try db.batchWordCounts(blockIds: ids, needsAggregate: [])
        #expect(result.count == allHeadings.count)
        for heading in allHeadings {
            #expect(result[heading.id] != nil, "Missing count for heading: \(heading.textContent)")
        }
    }

    // MARK: - recomputeStoredBlockWordCounts migration

    /// Corrupt a block's stored wordCount to a known-wrong value to simulate
    /// stale data left by older word-count rules on disk.
    private func corruptWordCount(_ db: ProjectDatabase, blockId: String, to value: Int) throws {
        try db.dbWriter.write { database in
            try database.execute(
                sql: "UPDATE block SET wordCount = ? WHERE id = ?",
                arguments: [value, blockId]
            )
        }
    }

    @Test("Migration corrects a stale wordCount and reports the change")
    @MainActor
    func migrationFixesStaleCount() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let paragraph = blocks.first(where: { $0.blockType == .paragraph }) else {
            Issue.record("No paragraph block"); return
        }
        let correctCount = paragraph.wordCount
        #expect(correctCount > 0)

        try corruptWordCount(db, blockId: paragraph.id, to: 9999)

        let summary = try db.recomputeStoredBlockWordCounts(projectId: pid)
        #expect(summary.changedBlocks == 1)
        #expect(summary.totalBlocks >= 1)

        let refreshed = try TestFixtureFactory.fetchBlocks(from: db)
        let fixed = refreshed.first { $0.id == paragraph.id }
        #expect(fixed?.wordCount == correctCount)
    }

    @Test("Migration is idempotent on a fresh database")
    @MainActor
    func migrationIsIdempotent() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // First pass: blocks were parsed via BlockParser which calls recalculateWordCount,
        // so stored values already match current rules. Expect zero writes.
        let first = try db.recomputeStoredBlockWordCounts(projectId: pid)
        #expect(first.changedBlocks == 0)

        // Second pass: again, nothing to change.
        let second = try db.recomputeStoredBlockWordCounts(projectId: pid)
        #expect(second.changedBlocks == 0)
        #expect(second.oldTotal == second.newTotal)
    }

    @Test("Migration does NOT zero a bibliography block's prose count (Bug B.1 pin)")
    @MainActor
    func migrationPreservesBibliographyProse() throws {
        // Set up: `# Bibliography` heading marks subsequent blocks as bibliography per BlockParser.
        // t-341706cb round 9: tier 3 (bare-title-anywhere) is deleted, so a bare-title heading
        // now needs a genuine terminator-bounded, non-empty run to be recognized as evidence —
        // see `BibliographyOpeningSelector`. The terminator below is real evidence a generated
        // bibliography would carry (`BlockParser+Assembly.swift` writes it after the last
        // bibliography block); it produces zero Blocks itself.
        let doc = """
        # Chapter

        Body paragraph.

        # Bibliography

        Smith, J. (2020). Title. Journal. 3(1). 1-10.

        <!-- ::auto-bibliography-end:: -->
        """
        let db = try TestFixtureFactory.createTemporary(content: doc)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let bibEntry = blocks.first(where: { $0.isBibliography && $0.blockType == .paragraph }) else {
            Issue.record("No bibliography paragraph block"); return
        }

        // Compute the expected count the same way the real code does, at test time,
        // to avoid hardcoding a number that could drift with MarkdownUtils changes
        // while still pinning the invariant "bibliography prose is counted".
        let expected = MarkdownUtils.wordCount(for: bibEntry.textContent)
        #expect(expected > 0, "Bibliography entry should have non-zero prose word count")

        // Corrupt to a known-wrong stale value.
        try corruptWordCount(db, blockId: bibEntry.id, to: 9999)

        let summary = try db.recomputeStoredBlockWordCounts(projectId: pid)
        #expect(summary.changedBlocks >= 1)

        let refreshed = try TestFixtureFactory.fetchBlocks(from: db)
        let fixed = refreshed.first { $0.id == bibEntry.id }
        #expect(fixed?.wordCount == expected, "Bibliography prose must equal the MarkdownUtils count — not 0, not 9999")
    }

    @Test("Migration zeros a code block regardless of stale stored value")
    @MainActor
    func migrationZeroesCodeBlock() throws {
        let doc = """
        # Section

        Real prose.

        ```swift
        let x = 1
        let y = 2
        ```
        """
        let db = try TestFixtureFactory.createTemporary(content: doc)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let codeBlock = blocks.first(where: { $0.blockType == .codeBlock }) else {
            Issue.record("No code block"); return
        }

        try corruptWordCount(db, blockId: codeBlock.id, to: 30)

        let summary = try db.recomputeStoredBlockWordCounts(projectId: pid)
        #expect(summary.changedBlocks >= 1)

        let refreshed = try TestFixtureFactory.fetchBlocks(from: db)
        let fixed = refreshed.first { $0.id == codeBlock.id }
        #expect(fixed?.wordCount == 0)
    }

    @Test("Migration preserves updatedAt — partial column update only")
    @MainActor
    func migrationPreservesUpdatedAt() throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard let paragraph = blocks.first(where: { $0.blockType == .paragraph }) else {
            Issue.record("No paragraph block"); return
        }
        let originalUpdatedAt = paragraph.updatedAt

        // Corrupt stored count so migration will write to this row.
        try corruptWordCount(db, blockId: paragraph.id, to: 9999)

        try db.recomputeStoredBlockWordCounts(projectId: pid)

        let refreshed = try TestFixtureFactory.fetchBlocks(from: db)
        let fixed = refreshed.first { $0.id == paragraph.id }
        // updatedAt must be byte-identical — any timestamp drift means the partial
        // column update was replaced with a full update, breaking sort-by-recency.
        #expect(fixed?.updatedAt == originalUpdatedAt)
    }

    @Test("Migration on an empty project returns zero-tallies and does not throw")
    @MainActor
    func migrationHandlesEmptyProject() throws {
        let db = try TestFixtureFactory.createTemporary(content: "")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Ensure the project really has no blocks (empty markdown → zero blocks).
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(blocks.isEmpty)

        let summary = try db.recomputeStoredBlockWordCounts(projectId: pid)
        #expect(summary.totalBlocks == 0)
        #expect(summary.changedBlocks == 0)
        #expect(summary.oldTotal == 0)
        #expect(summary.newTotal == 0)
    }

    @Test("Migration stays scoped to one project — sibling project untouched")
    @MainActor
    func migrationIsProjectScoped() throws {
        // Create two independent temp projects with their own stale-corrupted block.
        let dbA = try TestFixtureFactory.createTemporary(content: makeDoc())
        let pidA = try TestFixtureFactory.getProjectId(from: dbA)
        let dbB = try TestFixtureFactory.createTemporary(content: makeDoc())
        let pidB = try TestFixtureFactory.getProjectId(from: dbB)

        let blocksA = try TestFixtureFactory.fetchBlocks(from: dbA)
        let blocksB = try TestFixtureFactory.fetchBlocks(from: dbB)
        guard let paraA = blocksA.first(where: { $0.blockType == .paragraph }),
              let paraB = blocksB.first(where: { $0.blockType == .paragraph }) else {
            Issue.record("Missing paragraph blocks"); return
        }

        try corruptWordCount(dbA, blockId: paraA.id, to: 9999)
        try corruptWordCount(dbB, blockId: paraB.id, to: 8888)

        // Only recompute project A.
        _ = try dbA.recomputeStoredBlockWordCounts(projectId: pidA)

        let refreshedA = try TestFixtureFactory.fetchBlocks(from: dbA).first { $0.id == paraA.id }
        let refreshedB = try TestFixtureFactory.fetchBlocks(from: dbB).first { $0.id == paraB.id }
        #expect(refreshedA?.wordCount != 9999, "Project A's corrupted count should have been fixed")
        #expect(refreshedB?.wordCount == 8888, "Project B's corrupted count must remain untouched")
        // Suppress unused-variable warning; pidB is part of the test narrative.
        _ = pidB
    }

    @Test("excludeBibliography toggle end-to-end via real EditorViewState")
    @MainActor
    func excludeBibliographyToggleIsOnlyLever() throws {
        // t-341706cb round 9: tier 3 (bare-title-anywhere) is deleted, so a bare-title heading
        // now needs a genuine terminator-bounded, non-empty run to be recognized as evidence —
        // see `BibliographyOpeningSelector`. The terminator below is real evidence a generated
        // bibliography would carry (`BlockParser+Assembly.swift` writes it after the last
        // bibliography block); it produces zero Blocks itself.
        let doc = """
        # Chapter

        Body with several prose words here.

        # Bibliography

        Smith, J. (2020). Title. Journal. 3(1). 1-10.

        <!-- ::auto-bibliography-end:: -->
        """
        let db = try TestFixtureFactory.createTemporary(content: doc)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Ensure stored counts are fresh (the fixture factory calls BlockParser
        // which already does this, but a migration pass is free insurance).
        try db.recomputeStoredBlockWordCounts(projectId: pid)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = blocks.filter { $0.blockType == .heading }

        // Build SectionViewModels via the production init so the test exercises
        // the same pipe the app uses.
        var viewModels = headings.map { SectionViewModel(from: $0) }

        // Populate wordCount via batchWordCounts (same as EditorViewState does).
        let counts = try db.batchWordCounts(blockIds: viewModels.map { $0.id })
        for i in viewModels.indices {
            if let wc = counts[viewModels[i].id] {
                viewModels[i].wordCount = wc.sectionOnly
            }
        }

        // Sanity: the bibliography section must have non-zero prose under the
        // new policy, otherwise the toggle test is meaningless.
        let bibVM = viewModels.first { $0.isBibliography }
        #expect(bibVM != nil)
        #expect((bibVM?.wordCount ?? 0) > 0, "Bibliography section must have prose words for this test to be meaningful")

        let editorState = EditorViewState()
        editorState.sections = viewModels

        editorState.excludeBibliography = false
        let totalIncluding = editorState.filteredTotalWordCount
        editorState.excludeBibliography = true
        let totalExcluding = editorState.filteredTotalWordCount

        #expect(totalIncluding - totalExcluding == (bibVM?.wordCount ?? 0),
                "Toggling excludeBibliography must shift the total by exactly the bibliography section's prose count")
    }
}

// swiftlint:enable type_body_length
