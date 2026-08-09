//
//  BibliographyRegenerationPositionTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  REGRESSION SUITE guarding the anchor-based bibliography reinsertion fix.
//
//  Prior bug: `BibliographySyncService.updateBibliographyBlock` deleted ALL existing
//  `isBibliography` blocks FIRST, then computed `maxSortOrder` as the max `sortOrder`
//  across the project's REMAINING blocks -- which, after the delete, included any trailing
//  content that used to sort AFTER the bibliography. The new bibliography blocks (heading +
//  entries) were then inserted at `maxSortOrder + index + 1`, i.e. always appended past
//  whatever now had the highest sortOrder in the document -- unconditionally placing the
//  regenerated bibliography at the very END of the document's sortOrder range, regardless of
//  where the bibliography section originally sat. That silently moved the bibliography ahead
//  of any text the user had typed after it, every time a citation changed elsewhere in the
//  document and triggered a regeneration.
//
//  FIX: `updateBibliographyBlock` now captures an anchor (the old bibliography heading's
//  sortOrder, or the first surviving bibliography block's, or `nil` for first-ever
//  generation) BEFORE deleting the old rows, and reinserts the regenerated fragments starting
//  at that anchor, spaced to fit strictly before whatever block already followed it. The
//  bibliography returns to where it was, so trailing user text stays after it no matter how
//  many times the bibliography regenerates.
//
//  These tests drive the REAL production code paths (`BibliographySyncService.
//  regenerateBibliography` -> `performBibliographyUpdate` -> `updateBibliographyBlock`), not a
//  hand-rolled simulation.
//
//  This suite is split across several files purely to stay under SwiftLint's type_body_length
//  limit, each covering one logical concern:
//    - BibliographyRegenerationPositionTests.swift     -- this file: the core anchor-return
//      case, plus repeated-regeneration stability
//    - BibliographyRegenerationEdgeCaseTests.swift      -- first-ever generation (anchor ==
//      nil), already-at-the-end, and tight sortOrder gaps
//    - BibliographyRegenerationAnchorHijackTests.swift  -- the stray same-titled heading must
//      not be mistaken for the real anchor
//    - BibliographyRegenerationPositionTestSupport.swift -- shared Zotero item-loading fixture
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Bibliography Regeneration Position — Regression", .serialized)
struct BibliographyRegenerationPositionTests {

    // MARK: - 1. Core case: regeneration returns the bibliography to its prior anchor, not the document end

    @Test("Regenerating the bibliography after trailing text was already typed reinserts it back at its original anchor, not past the trailing text")
    @MainActor
    func regenerationReanchorsBibliographyInsteadOfAppendingPastTrailingText() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Intro\n\nplaceholder")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        // Wipe the auto-parsed placeholder blocks and build a precise starting layout:
        // intro heading/para (citing keyA) + an ALREADY-CORRECTLY-PLACED bibliography
        // section (heading + 1 entry) + a trailing paragraph typed after it.
        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        ZoteroService.shared.isConnected = true
        try BibliographyRegenerationFixtures.loadItem(citekey: "regressionKeyA", family: "Alpha", given: "Ann", year: 2020)
        try BibliographyRegenerationFixtures.loadItem(citekey: "regressionKeyB", family: "Beta", given: "Bob", year: 2021)
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
            textContent: "Citing [@regressionKeyA].", markdownFragment: "Citing [@regressionKeyA]."
        )
        let bibHeading = Block(
            projectId: projectId, sortOrder: 3.0, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography",
            headingLevel: 1, status: .final_, isBibliography: true
        )
        let entryA = Block(
            projectId: projectId, sortOrder: 4.0, blockType: .paragraph,
            textContent: "Alpha, Ann. (2020). Title A.", markdownFragment: "Alpha, Ann. (2020). Title A.",
            isBibliography: true
        )
        let trailing = Block(
            projectId: projectId, sortOrder: 5.0, blockType: .paragraph,
            textContent: "Trailing sentinel text.", markdownFragment: "Trailing sentinel text."
        )

        try db.write { database in
            for var b in [heading, para, bibHeading, entryA, trailing] {
                try b.insert(database)
            }
        }

        // Sanity check: this starting layout is exactly the "already correct" case. Export
        // must place the trailing paragraph AFTER the bibliography heading/marker.
        let beforeBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let beforeExport = BlockParser.assembleMarkdownForExport(from: beforeBlocks, bibliographyPlaceholder: true)
        let beforeHeadingRange = try #require(beforeExport.range(of: "# Bibliography"))
        let beforeTrailingRange = try #require(beforeExport.range(of: "Trailing sentinel text."))
        #expect(
            beforeHeadingRange.upperBound <= beforeTrailingRange.lowerBound,
            """
            Sanity check failed: before any regeneration, the bibliography heading must already \
            precede the trailing text. Export:
            \(beforeExport)
            """
        )

        // Simulate the user adding a NEW citation elsewhere in the document. This drives the
        // REAL BibliographySyncService regeneration path exactly as the app does.
        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        await service.regenerateBibliography(projectId: projectId, citekeys: ["regressionKeyA", "regressionKeyB"])

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let afterBibHeading = try #require(
            afterBlocks.first { $0.isBibliography && $0.blockType == .heading },
            "Regeneration must produce a new bibliography heading block"
        )
        let afterTrailing = try #require(
            afterBlocks.first { $0.textContent == "Trailing sentinel text." },
            "The trailing paragraph must survive regeneration untouched (regeneration only deletes isBibliography-flagged rows)"
        )

        #expect(
            afterTrailing.sortOrder == trailing.sortOrder,
            """
            The trailing paragraph itself must never move -- regeneration only deletes/reinserts \
            isBibliography rows. Original sortOrder=\(trailing.sortOrder), after=\(afterTrailing.sortOrder)
            """
        )

        // TIGHT assertion, not just "less than trailing": the regenerated heading must land
        // EXACTLY at the original anchor position (the old heading's sortOrder). A weaker
        // `afterBibHeading.sortOrder < afterTrailing.sortOrder` check would also pass for a
        // wrong fix that merely lands the bibliography somewhere-before the trailing text
        // without actually returning it to its correct anchor.
        #expect(
            afterBibHeading.sortOrder == bibHeading.sortOrder,
            """
            FIX: the regenerated bibliography heading must land EXACTLY at the original anchor \
            sortOrder (\(bibHeading.sortOrder)), not merely somewhere before the trailing \
            paragraph. Got \(afterBibHeading.sortOrder).
            """
        )

        // Export must still place the trailing paragraph after the bibliography heading/marker.
        let afterExport = BlockParser.assembleMarkdownForExport(from: afterBlocks, bibliographyPlaceholder: true)
        let afterHeadingRange = try #require(afterExport.range(of: "# Bibliography"))
        let afterTrailingRange = try #require(afterExport.range(of: "Trailing sentinel text."))
        #expect(
            afterHeadingRange.upperBound <= afterTrailingRange.lowerBound,
            """
            After regeneration, the trailing paragraph must still render AFTER the bibliography \
            heading/marker in export output. Export:
            \(afterExport)
            """
        )
    }

    // MARK: - 2. Repeated regeneration stays anchored across many rounds

    @Test("Repeated regeneration with different citekey sets keeps the bibliography heading at the same exact anchor every time")
    @MainActor
    func repeatedRegenerationKeepsHeadingAtIdenticalAnchor() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Intro\n\nplaceholder")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        ZoteroService.shared.isConnected = true
        try BibliographyRegenerationFixtures.loadItem(citekey: "repeatKeyA", family: "Alpha", given: "Ann", year: 2020)
        try BibliographyRegenerationFixtures.loadItem(citekey: "repeatKeyB", family: "Beta", given: "Bob", year: 2021)
        try BibliographyRegenerationFixtures.loadItem(citekey: "repeatKeyC", family: "Gamma", given: "Gail", year: 2022)
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
            textContent: "Citing [@repeatKeyA].", markdownFragment: "Citing [@repeatKeyA]."
        )
        let bibHeading = Block(
            projectId: projectId, sortOrder: 3.0, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography",
            headingLevel: 1, status: .final_, isBibliography: true
        )
        let entryA = Block(
            projectId: projectId, sortOrder: 4.0, blockType: .paragraph,
            textContent: "Alpha, Ann. (2020). Title A.", markdownFragment: "Alpha, Ann. (2020). Title A.",
            isBibliography: true
        )
        let trailing = Block(
            projectId: projectId, sortOrder: 5.0, blockType: .paragraph,
            textContent: "Trailing sentinel text.", markdownFragment: "Trailing sentinel text."
        )

        try db.write { database in
            for var b in [heading, para, bibHeading, entryA, trailing] {
                try b.insert(database)
            }
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)

        let citekeySets: [[String]] = [
            ["repeatKeyA", "repeatKeyB"],
            ["repeatKeyA", "repeatKeyB", "repeatKeyC"],
            ["repeatKeyB", "repeatKeyC"]
        ]

        var observedHeadingSortOrders: [Double] = []
        for citekeys in citekeySets {
            await service.regenerateBibliography(projectId: projectId, citekeys: citekeys)

            let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            let bibHeadingNow = try #require(
                blocks.first { $0.isBibliography && $0.blockType == .heading },
                "Every round must produce a bibliography heading block"
            )
            let trailingNow = try #require(
                blocks.first { $0.textContent == "Trailing sentinel text." },
                "The trailing paragraph must survive every round of regeneration"
            )
            #expect(
                trailingNow.sortOrder == trailing.sortOrder,
                "The trailing paragraph must never move across regenerations, round citekeys=\(citekeys)"
            )
            observedHeadingSortOrders.append(bibHeadingNow.sortOrder)
        }

        #expect(
            Set(observedHeadingSortOrders).count == 1,
            "The bibliography heading's sortOrder must be IDENTICAL after every single regeneration, got \(observedHeadingSortOrders)"
        )
        #expect(
            observedHeadingSortOrders.first == bibHeading.sortOrder,
            "The bibliography heading must keep returning to the ORIGINAL anchor position, not drift to a new one"
        )

        // After all 3 rounds: exactly one bibliography heading BLOCK in the database. Checked
        // against the raw rows, not just the export below: `assembleMarkdownForExport`'s own
        // `emittedPlaceholder` dedup guard emits a heading at most once in its OUTPUT no matter
        // how many heading BLOCKS actually exist, so an export-only check is structurally
        // incapable of catching a duplicated bibliography-heading block left behind by a faulty
        // regeneration -- the exact failure mode this assertion guards against.
        let finalBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let finalHeadingBlocks = finalBlocks.filter { $0.isBibliography && $0.blockType == .heading }
        #expect(
            finalHeadingBlocks.count == 1,
            """
            Exactly one bibliography heading BLOCK must exist in the database after repeated \
            regeneration, got \(finalHeadingBlocks.count): \(finalHeadingBlocks.map(\.textContent))
            """
        )

        // Same check via the export, for good measure -- exactly one "# Bibliography" heading
        // in the export, and the trailing text still comes last.
        let finalExport = BlockParser.assembleMarkdownForExport(from: finalBlocks, bibliographyPlaceholder: true)
        let firstHeadingRange = try #require(finalExport.range(of: "# Bibliography"))
        let remainderAfterFirstHeading = finalExport[firstHeadingRange.upperBound...]
        #expect(
            remainderAfterFirstHeading.range(of: "# Bibliography") == nil,
            "Export must contain exactly one \"# Bibliography\" heading after repeated regeneration. Export:\n\(finalExport)"
        )
        let finalTrailingRange = try #require(finalExport.range(of: "Trailing sentinel text."))
        #expect(
            firstHeadingRange.upperBound <= finalTrailingRange.lowerBound,
            "The trailing paragraph must still come after the bibliography heading/marker following repeated regeneration. Export:\n\(finalExport)"
        )
    }
}
