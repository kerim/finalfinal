//
//  BibliographyOrphanMarkerAnchorTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  t-341706cb follow-up: a block whose entire trimmed content is the bare literal
//  `<!-- ::auto-bibliography:: -->` -- an ORPHAN left behind because CodeMirror's Source Mode
//  hides this marker as an invisible atomic decoration with no delete-protection, so deleting
//  the visible bibliography section around it can leave the marker behind -- must never be
//  used as `BibliographySyncService.updateBibliographyBlock`'s regeneration anchor. Modeled on
//  `BibliographyRegenerationAnchorHijackTests.swift`'s pattern; reuses
//  `BibliographyRegenerationFixtures`'s Zotero-item-loading helper (see
//  `BibliographyRegenerationPositionTestSupport.swift`).
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Bibliography Regeneration Position — Orphan Marker Anchor Guard", .serialized)
struct BibliographyOrphanMarkerAnchorTests {

    // MARK: - An orphan marker block must never be used as the anchor

    @Test("An orphan marker block (unstripped literal shape) at a low sortOrder is not mistaken for the real bibliography's anchor when exactly one real entry is flagged further down")
    @MainActor
    func orphanMarkerBlockIsNotUsedAsTheRegenerationAnchor() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Intro\n\nplaceholder")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        ZoteroService.shared.isConnected = true
        try BibliographyRegenerationFixtures.loadItem(citekey: "orphanKeyA", family: "Smith", given: "Jane", year: 2018)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let introHeading = Block(
            projectId: projectId, sortOrder: 1.0, blockType: .heading,
            textContent: "Intro", markdownFragment: "# Intro"
        )
        let para = Block(
            projectId: projectId, sortOrder: 2.0, blockType: .paragraph,
            textContent: "Citing [@orphanKeyA].", markdownFragment: "Citing [@orphanKeyA]."
        )
        // The orphan: a whole block whose content IS the bare opening-marker literal, flagged
        // isBibliography = true from a stale prior generation, sitting at a LOW sortOrder --
        // exactly the shape CodeMirror's invisible atomic decoration can leave behind.
        let orphanMarker = Block(
            projectId: projectId, sortOrder: 3.0, blockType: .paragraph,
            textContent: "", markdownFragment: "<!-- ::auto-bibliography:: -->",
            isBibliography: true
        )
        let filler = Block(
            projectId: projectId, sortOrder: 4.0, blockType: .paragraph,
            textContent: "Some more body text, unrelated.", markdownFragment: "Some more body text, unrelated."
        )
        // The REAL bibliography, further down -- heading UNFLAGGED (the damaged shape), but
        // with exactly one flagged entry.
        let bibHeading = Block(
            projectId: projectId, sortOrder: 5.0, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography",
            headingLevel: 1, status: .final_, isBibliography: false
        )
        let entryA = Block(
            projectId: projectId, sortOrder: 6.0, blockType: .paragraph,
            textContent: "Smith, J. (2018). Title A.", markdownFragment: "Smith, J. (2018). Title A.",
            isBibliography: true
        )
        let trailing = Block(
            projectId: projectId, sortOrder: 7.0, blockType: .paragraph,
            textContent: "Trailing sentinel text.", markdownFragment: "Trailing sentinel text."
        )

        try db.write { database in
            for var b in [introHeading, para, orphanMarker, filler, bibHeading, entryA, trailing] {
                try b.insert(database)
            }
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        await service.regenerateBibliography(projectId: projectId, citekeys: ["orphanKeyA"])

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let afterBibHeading = try #require(
            afterBlocks.first { $0.isBibliography && $0.blockType == .heading },
            "Regeneration must produce a new bibliography heading block"
        )

        #expect(
            afterBibHeading.sortOrder == entryA.sortOrder,
            """
            The regenerated bibliography heading must land at the real entry's original anchor \
            (\(entryA.sortOrder)), not the orphan marker's position (\(orphanMarker.sortOrder)). \
            Got \(afterBibHeading.sortOrder).
            """
        )
        #expect(
            afterBibHeading.sortOrder != orphanMarker.sortOrder,
            "The regenerated bibliography must not be relocated to the orphan marker's position"
        )

        // The orphan row itself is deleted by the existing unconditional `deleteAll` (it was
        // flagged isBibliography == true, so it's swept up along with every other bibliography
        // row regardless of anchor selection).
        #expect(
            !afterBlocks.contains { $0.markdownFragment == "<!-- ::auto-bibliography:: -->" },
            "The orphan marker block must be removed by regeneration's deleteAll, like any other stale bibliography row"
        )
    }

    // MARK: - Must-fix (round 1 regression guard): a single ordinary flagged entry still anchors

    @Test("A single flagged block that is an ORDINARY entry (not the marker literal, not empty) still anchors regeneration there, unchanged from today's behavior")
    @MainActor
    func singleEntryBibliographyWithUnflaggedHeadingStillAnchors() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Intro\n\nplaceholder")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        ZoteroService.shared.isConnected = true
        try BibliographyRegenerationFixtures.loadItem(citekey: "singleKeyA", family: "Doe", given: "Jane", year: 2019)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let introHeading = Block(
            projectId: projectId, sortOrder: 1.0, blockType: .heading,
            textContent: "Intro", markdownFragment: "# Intro"
        )
        let para = Block(
            projectId: projectId, sortOrder: 2.0, blockType: .paragraph,
            textContent: "Citing [@singleKeyA].", markdownFragment: "Citing [@singleKeyA]."
        )
        let bibHeading = Block(
            projectId: projectId, sortOrder: 3.0, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography",
            headingLevel: 1, status: .final_, isBibliography: false
        )
        let entryA = Block(
            projectId: projectId, sortOrder: 4.0, blockType: .paragraph,
            textContent: "Doe, J. (2019). Title A.", markdownFragment: "Doe, J. (2019). Title A.",
            isBibliography: true
        )
        let trailing = Block(
            projectId: projectId, sortOrder: 5.0, blockType: .paragraph,
            textContent: "Trailing sentinel text.", markdownFragment: "Trailing sentinel text."
        )

        try db.write { database in
            for var b in [introHeading, para, bibHeading, entryA, trailing] {
                try b.insert(database)
            }
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        await service.regenerateBibliography(projectId: projectId, citekeys: ["singleKeyA"])

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let afterBibHeading = try #require(afterBlocks.first { $0.isBibliography && $0.blockType == .heading })

        #expect(
            afterBibHeading.sortOrder == entryA.sortOrder,
            "The single flagged ordinary entry must still anchor regeneration at its own position, unchanged from today's behavior"
        )
    }

    // MARK: - An orphan as the ONLY flagged block appends at the document end

    @Test("An orphan marker block that is the ONLY flagged row in the document resolves to no anchor -- the bibliography appends at the document end, and the orphan is cleaned up")
    @MainActor
    func orphanAsTheOnlyFlaggedBlockAppendsAtEnd() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Intro\n\nplaceholder")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        ZoteroService.shared.isConnected = true
        try BibliographyRegenerationFixtures.loadItem(citekey: "onlyOrphanKeyA", family: "Lee", given: "Ann", year: 2020)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let introHeading = Block(
            projectId: projectId, sortOrder: 1.0, blockType: .heading,
            textContent: "Intro", markdownFragment: "# Intro"
        )
        let para = Block(
            projectId: projectId, sortOrder: 2.0, blockType: .paragraph,
            textContent: "Citing [@onlyOrphanKeyA].", markdownFragment: "Citing [@onlyOrphanKeyA]."
        )
        let orphanMarker = Block(
            projectId: projectId, sortOrder: 3.0, blockType: .paragraph,
            textContent: "", markdownFragment: "<!-- ::auto-bibliography:: -->",
            isBibliography: true
        )
        let trailing = Block(
            projectId: projectId, sortOrder: 4.0, blockType: .paragraph,
            textContent: "Trailing sentinel text.", markdownFragment: "Trailing sentinel text."
        )

        try db.write { database in
            for var b in [introHeading, para, orphanMarker, trailing] {
                try b.insert(database)
            }
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        await service.regenerateBibliography(projectId: projectId, citekeys: ["onlyOrphanKeyA"])

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let afterBibHeading = try #require(afterBlocks.first { $0.isBibliography && $0.blockType == .heading })
        let afterTrailing = try #require(afterBlocks.first { $0.textContent == "Trailing sentinel text." })

        #expect(
            afterBibHeading.sortOrder > afterTrailing.sortOrder,
            "With the orphan excluded from every anchor level, there is no anchor at all -- the regenerated bibliography must append after every surviving block, including the trailing text"
        )
        #expect(
            !afterBlocks.contains { $0.markdownFragment == "<!-- ::auto-bibliography:: -->" },
            "The orphan marker block must be removed by regeneration's deleteAll"
        )
    }

    // MARK: - Must-fix (round 2): the STRIPPED orphan shape (legacy-load path) is also excluded

    @Test("""
    An orphan block in the STRIPPED shape (empty markdownFragment, non-heading blockType -- what \
    the legacy-load strippingBibliographyMarkerFromBlocks path actually produces) is also excluded \
    from the regeneration anchor, not just the unstripped literal shape
    """)
    @MainActor
    func strippedOrphanMarkerBlockIsNotUsedAsTheRegenerationAnchor() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Intro\n\nplaceholder")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        ZoteroService.shared.isConnected = true
        try BibliographyRegenerationFixtures.loadItem(citekey: "strippedKeyA", family: "Park", given: "Min", year: 2021)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let introHeading = Block(
            projectId: projectId, sortOrder: 1.0, blockType: .heading,
            textContent: "Intro", markdownFragment: "# Intro"
        )
        let para = Block(
            projectId: projectId, sortOrder: 2.0, blockType: .paragraph,
            textContent: "Citing [@strippedKeyA].", markdownFragment: "Citing [@strippedKeyA]."
        )
        // The STRIPPED orphan shape: on the legacy-load path, `BlockParser.parse`'s
        // `strippingBibliographyMarkerFromBlocks` computes `fragmentForBlock` from the
        // classification text, which for a marker-only raw block is the marker literal
        // STRIPPED OUT -- i.e. the empty string, not the marker literal itself. blockType is
        // NOT .heading (an empty, non-heading, isBibliography-flagged block can only arise this
        // way -- its entire original text WAS the marker, now stripped away).
        let strippedOrphan = Block(
            projectId: projectId, sortOrder: 3.0, blockType: .paragraph,
            textContent: "", markdownFragment: "",
            isBibliography: true
        )
        let filler = Block(
            projectId: projectId, sortOrder: 4.0, blockType: .paragraph,
            textContent: "Some more body text, unrelated.", markdownFragment: "Some more body text, unrelated."
        )
        let bibHeading = Block(
            projectId: projectId, sortOrder: 5.0, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography",
            headingLevel: 1, status: .final_, isBibliography: false
        )
        let entryA = Block(
            projectId: projectId, sortOrder: 6.0, blockType: .paragraph,
            textContent: "Park, M. (2021). Title A.", markdownFragment: "Park, M. (2021). Title A.",
            isBibliography: true
        )
        let trailing = Block(
            projectId: projectId, sortOrder: 7.0, blockType: .paragraph,
            textContent: "Trailing sentinel text.", markdownFragment: "Trailing sentinel text."
        )

        try db.write { database in
            for var b in [introHeading, para, strippedOrphan, filler, bibHeading, entryA, trailing] {
                try b.insert(database)
            }
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        await service.regenerateBibliography(projectId: projectId, citekeys: ["strippedKeyA"])

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let afterBibHeading = try #require(
            afterBlocks.first { $0.isBibliography && $0.blockType == .heading },
            "Regeneration must produce a new bibliography heading block"
        )

        #expect(
            afterBibHeading.sortOrder == entryA.sortOrder,
            """
            The regenerated bibliography heading must land at the real entry's original anchor \
            (\(entryA.sortOrder)), not the stripped orphan's position (\(strippedOrphan.sortOrder)). \
            Got \(afterBibHeading.sortOrder).
            """
        )
        #expect(
            afterBibHeading.sortOrder != strippedOrphan.sortOrder,
            "The regenerated bibliography must not be relocated to the stripped orphan's position"
        )
    }
}
