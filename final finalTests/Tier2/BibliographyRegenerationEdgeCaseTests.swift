//
//  BibliographyRegenerationEdgeCaseTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Boundary cases for the anchor-based bibliography reinsertion fix: first-ever generation
//  (no prior anchor), a bibliography already sitting at the document's end, and a very tight
//  sortOrder gap between the anchor and whatever follows it. Split out of
//  BibliographyRegenerationPositionTests.swift (SwiftLint type_body_length) -- see that file for
//  the full feature background comment shared by every file in this suite.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Bibliography Regeneration Position — Edge Cases", .serialized)
struct BibliographyRegenerationEdgeCaseTests {

    // MARK: - 1. First-ever generation (anchor == nil): unchanged append-at-end behavior

    @Test("First-ever bibliography generation still appends after all existing content, unchanged")
    @MainActor
    func firstEverGenerationAppendsAtEnd() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Intro\n\nplaceholder")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        ZoteroService.shared.isConnected = true
        try BibliographyRegenerationFixtures.loadItem(citekey: "firstGenKey", family: "Delta", given: "Dana", year: 2019)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        // No bibliography blocks exist at all -- just ordinary content.
        let heading = Block(
            projectId: projectId, sortOrder: 1.0, blockType: .heading,
            textContent: "Intro", markdownFragment: "# Intro"
        )
        let para = Block(
            projectId: projectId, sortOrder: 2.0, blockType: .paragraph,
            textContent: "Citing [@firstGenKey].", markdownFragment: "Citing [@firstGenKey]."
        )

        try db.write { database in
            for var b in [heading, para] {
                try b.insert(database)
            }
        }

        let beforeBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let maxSortOrderBefore = try #require(beforeBlocks.map(\.sortOrder).max())

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        await service.regenerateBibliography(projectId: projectId, citekeys: ["firstGenKey"])

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let newBibHeading = try #require(
            afterBlocks.first { $0.isBibliography && $0.blockType == .heading },
            "First-ever generation must create a bibliography heading"
        )

        #expect(
            newBibHeading.sortOrder > maxSortOrderBefore,
            "With no prior bibliography (anchor == nil), the new bibliography must append after all existing content, exactly as before this fix"
        )
        #expect(
            newBibHeading.sortOrder == maxSortOrderBefore + 1.0,
            "The anchor == nil branch must reproduce the unchanged append formula (maxSortOrder + 1.0)"
        )
    }

    // MARK: - 2. Bibliography already at the document's end, no trailing text: no regression

    @Test("Bibliography already at the document's end with no trailing text stays at the end and does not inflate its sortOrder across regenerations")
    @MainActor
    func bibliographyAlreadyAtEndDoesNotRegress() async throws {
        // NOTE: the OLD code already handled this specific sub-case correctly, but not because
        // it was position-aware -- it deleted the bibliography-flagged rows FIRST, so the
        // remaining `maxSortOrder` fell back to the preceding paragraph, and appending at
        // `maxSortOrder + index + 1` happened to land the heading back at effectively the same
        // place in THIS SPECIFIC no-trailing-text scenario (there was nothing left to append
        // past). This test guards the NEW anchor-based code against regressing that existing
        // behavior -- it is not exercising a bug this fix introduces.
        let db = try TestFixtureFactory.createTemporary(content: "# Intro\n\nplaceholder")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        ZoteroService.shared.isConnected = true
        try BibliographyRegenerationFixtures.loadItem(citekey: "endKeyA", family: "Epsilon", given: "Eve", year: 2018)
        try BibliographyRegenerationFixtures.loadItem(citekey: "endKeyB", family: "Zeta", given: "Zoe", year: 2019)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let heading = Block(
            projectId: projectId, sortOrder: 1.0, blockType: .heading,
            textContent: "Intro", markdownFragment: "# Intro"
        )
        let para = Block(
            projectId: projectId, sortOrder: 2.0, blockType: .paragraph,
            textContent: "Citing [@endKeyA].", markdownFragment: "Citing [@endKeyA]."
        )
        let bibHeading = Block(
            projectId: projectId, sortOrder: 3.0, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography",
            headingLevel: 1, status: .final_, isBibliography: true
        )
        let entryA = Block(
            projectId: projectId, sortOrder: 4.0, blockType: .paragraph,
            textContent: "Epsilon, Eve. (2018). Title A.", markdownFragment: "Epsilon, Eve. (2018). Title A.",
            isBibliography: true
        )
        // No trailing block -- the bibliography IS the last thing in the document.

        try db.write { database in
            for var b in [heading, para, bibHeading, entryA] {
                try b.insert(database)
            }
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)

        var observedHeadingSortOrders: [Double] = []
        for citekeys in [["endKeyA", "endKeyB"], ["endKeyA"]] {
            await service.regenerateBibliography(projectId: projectId, citekeys: citekeys)
            let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            let bibHeadingNow = try #require(blocks.first { $0.isBibliography && $0.blockType == .heading })
            let nonBibliographyAfterHeading = blocks.filter { $0.sortOrder > bibHeadingNow.sortOrder && !$0.isBibliography }
            #expect(
                nonBibliographyAfterHeading.isEmpty,
                """
                The bibliography heading must remain the start of the trailing bibliography run -- \
                nothing non-bibliography follows it, found: \(nonBibliographyAfterHeading.map(\.textContent))
                """
            )
            observedHeadingSortOrders.append(bibHeadingNow.sortOrder)
        }

        #expect(
            observedHeadingSortOrders[0] == bibHeading.sortOrder,
            "With no next block, the heading must stay exactly at the anchor (its own prior position) rather than drifting"
        )
        #expect(
            observedHeadingSortOrders[0] == observedHeadingSortOrders[1],
            """
            The heading's sortOrder must not inflate across repeated regenerations when the \
            bibliography is already last, got \(observedHeadingSortOrders)
            """
        )
    }

    // MARK: - 3. Tight sortOrder gap between anchor and the next block

    @Test("A very tight sortOrder gap between the anchor and the next block still yields strictly increasing, correctly ordered inserts")
    @MainActor
    func tightSortOrderGapStaysStrictlyOrdered() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Intro\n\nplaceholder")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        ZoteroService.shared.isConnected = true
        try BibliographyRegenerationFixtures.loadItem(citekey: "tightKeyA", family: "Eta", given: "Elle", year: 2017)
        try BibliographyRegenerationFixtures.loadItem(citekey: "tightKeyB", family: "Theta", given: "Tam", year: 2018)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let heading = Block(
            projectId: projectId, sortOrder: 1.0, blockType: .heading,
            textContent: "Intro", markdownFragment: "# Intro"
        )
        let para = Block(
            projectId: projectId, sortOrder: 2.0, blockType: .paragraph,
            textContent: "Citing [@tightKeyA].", markdownFragment: "Citing [@tightKeyA]."
        )
        let bibHeading = Block(
            projectId: projectId, sortOrder: 3.0, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography",
            headingLevel: 1, status: .final_, isBibliography: true
        )
        let entryA = Block(
            projectId: projectId, sortOrder: 3.00000005, blockType: .paragraph,
            textContent: "Eta, Elle. (2017). Title A.", markdownFragment: "Eta, Elle. (2017). Title A.",
            isBibliography: true
        )
        // Trailing text sits almost immediately after the anchor -- an extremely tight gap.
        let trailingSortOrder = 3.0000001
        let trailing = Block(
            projectId: projectId, sortOrder: trailingSortOrder, blockType: .paragraph,
            textContent: "Trailing sentinel text.", markdownFragment: "Trailing sentinel text."
        )

        try db.write { database in
            for var b in [heading, para, bibHeading, entryA, trailing] {
                try b.insert(database)
            }
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        await service.regenerateBibliography(projectId: projectId, citekeys: ["tightKeyA", "tightKeyB"])

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let afterTrailing = try #require(afterBlocks.first { $0.textContent == "Trailing sentinel text." })
        #expect(
            afterTrailing.sortOrder == trailingSortOrder,
            """
            The trailing block's own sortOrder must be completely unchanged by regeneration -- no \
            block mutation, even under a tight gap. Original=\(trailingSortOrder), \
            after=\(afterTrailing.sortOrder)
            """
        )

        let bibBlocksAfter = afterBlocks
            .filter { $0.isBibliography }
            .sorted { $0.sortOrder < $1.sortOrder }
        #expect(bibBlocksAfter.count >= 2, "Regeneration with 2 citekeys must produce a heading plus at least one entry")

        // Strictly increasing among the regenerated fragments themselves.
        for (a, b) in zip(bibBlocksAfter, bibBlocksAfter.dropFirst()) {
            #expect(
                a.sortOrder < b.sortOrder,
                "Regenerated bibliography fragments must be strictly increasing in sortOrder, got \(bibBlocksAfter.map(\.sortOrder))"
            )
        }

        // Every regenerated fragment must still sort before the trailing text.
        for block in bibBlocksAfter {
            #expect(
                block.sortOrder < afterTrailing.sortOrder,
                """
                Every regenerated bibliography fragment must sort before the trailing text even \
                under a tight gap. fragment=\(block.sortOrder), trailing=\(afterTrailing.sortOrder)
                """
            )
        }

        // The heading must still be exactly at the anchor.
        let afterBibHeading = try #require(bibBlocksAfter.first { $0.blockType == .heading })
        #expect(
            afterBibHeading.sortOrder == bibHeading.sortOrder,
            "The bibliography heading must still land exactly at the original anchor even under a tight gap"
        )
    }
}
