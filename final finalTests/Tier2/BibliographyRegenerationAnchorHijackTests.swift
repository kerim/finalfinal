//
//  BibliographyRegenerationAnchorHijackTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Guards against a stray heading elsewhere in the document -- one that happens to share the
//  bibliography's recognized title text -- being mistaken for the real bibliography's anchor.
//  Split out of BibliographyRegenerationPositionTests.swift (SwiftLint type_body_length) -- see
//  that file for the full feature background comment shared by every file in this suite.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Bibliography Regeneration Position — Anchor Hijack Guard", .serialized)
struct BibliographyAnchorHijackTests {

    // MARK: - A stray, unrelated heading matching the bibliography title must not become the anchor

    @Test("A stray heading elsewhere in the document that matches the bibliography title is not mistaken for the real bibliography's anchor")
    @MainActor
    func strayBibliographyTitledHeadingIsNotMistakenForTheAnchor() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Intro\n\nplaceholder")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        ZoteroService.shared.isConnected = true
        try BibliographyRegenerationFixtures.loadItem(citekey: "strayKeyA", family: "Iota", given: "Ivy", year: 2016)
        try BibliographyRegenerationFixtures.loadItem(citekey: "strayKeyB", family: "Kappa", given: "Kai", year: 2017)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        // A stray heading near the TOP of the document that happens to match a recognized
        // bibliography title literal ("References") -- flagged isBibliography = true by the
        // insert-time containment logic purely because its text matches, exactly as it would
        // be if the user had typed or pasted it there (see Database+BlocksInsert.swift's
        // `buildInsertedBlock`). It is NOT followed by bibliography-flagged content, so it must
        // fail the containment check and never be picked as the anchor.
        let strayHeading = Block(
            projectId: projectId, sortOrder: 1.0, blockType: .heading,
            textContent: "References", markdownFragment: "# References",
            headingLevel: 1, status: .final_, isBibliography: true
        )
        let strayFollowup = Block(
            projectId: projectId, sortOrder: 2.0, blockType: .paragraph,
            textContent: "Some ordinary unrelated content near the top.",
            markdownFragment: "Some ordinary unrelated content near the top."
        )
        let introHeading = Block(
            projectId: projectId, sortOrder: 3.0, blockType: .heading,
            textContent: "Intro", markdownFragment: "# Intro"
        )
        let para = Block(
            projectId: projectId, sortOrder: 4.0, blockType: .paragraph,
            textContent: "Citing [@strayKeyA].", markdownFragment: "Citing [@strayKeyA]."
        )
        // The REAL bibliography section, further down, with its own trailing text.
        let bibHeading = Block(
            projectId: projectId, sortOrder: 5.0, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography",
            headingLevel: 1, status: .final_, isBibliography: true
        )
        let entryA = Block(
            projectId: projectId, sortOrder: 6.0, blockType: .paragraph,
            textContent: "Iota, Ivy. (2016). Title A.", markdownFragment: "Iota, Ivy. (2016). Title A.",
            isBibliography: true
        )
        let trailing = Block(
            projectId: projectId, sortOrder: 7.0, blockType: .paragraph,
            textContent: "Trailing sentinel text.", markdownFragment: "Trailing sentinel text."
        )

        try db.write { database in
            for var b in [strayHeading, strayFollowup, introHeading, para, bibHeading, entryA, trailing] {
                try b.insert(database)
            }
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        await service.regenerateBibliography(projectId: projectId, citekeys: ["strayKeyA", "strayKeyB"])

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let afterBibHeading = try #require(
            afterBlocks.first { $0.isBibliography && $0.blockType == .heading },
            "Regeneration must produce a new bibliography heading block"
        )

        #expect(
            afterBibHeading.sortOrder == bibHeading.sortOrder,
            """
            The regenerated bibliography heading must land at the REAL bibliography section's \
            original anchor (\(bibHeading.sortOrder)), not the stray "# References" heading's \
            position (\(strayHeading.sortOrder)). Got \(afterBibHeading.sortOrder).
            """
        )
        #expect(
            afterBibHeading.sortOrder != strayHeading.sortOrder,
            "The regenerated bibliography must not be relocated to the stray heading's position"
        )

        // The ordinary content that followed the stray heading must be completely undisturbed.
        let afterStrayFollowup = try #require(
            afterBlocks.first { $0.textContent == "Some ordinary unrelated content near the top." }
        )
        #expect(
            afterStrayFollowup.sortOrder == strayFollowup.sortOrder,
            "Ordinary content near the top of the document must not move because of a same-titled stray heading elsewhere"
        )

        // The real trailing text must still survive, in place, after the real bibliography.
        let afterTrailing = try #require(afterBlocks.first { $0.textContent == "Trailing sentinel text." })
        #expect(
            afterTrailing.sortOrder == trailing.sortOrder,
            "The trailing paragraph after the real bibliography section must not move"
        )
        #expect(
            afterBibHeading.sortOrder < afterTrailing.sortOrder,
            "The regenerated bibliography heading must still sort before the real section's trailing text"
        )
    }
}
