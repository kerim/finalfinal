//
//  BibliographyBareTitleInsertPathTests.swift
//  final finalTests
//
//  Split out of BibliographyBareTitleSelectionTests.swift to keep that file's struct body under
//  SwiftLint's type_body_length limit -- see the header comment there for the full bare-title
//  selection background. This file covers the insert-path adoption/marker cases (Cases 7-8):
//  applyBlockChangesFromEditor's handling of bare-title vs. marker-carrying heading fragments
//  inserted via BlockChanges. The replaceBlocks curative-fix and parseHeaders/marker-selection
//  cases that used to live here moved to
//  BibliographyBareTitleCurativeFixAndTerminatorTests.swift.
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension BibliographyBareTitleSelectionTests {

    // MARK: - Case 7: insert path never adopts by title

    @Test("Insert path never adopts by title: a bare-title heading fragment between two flagged bibliography rows is not flagged")
    func insertPathNeverAdoptsByTitle() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let bibBlocksBefore = blocksBefore.filter { $0.isBibliography }.sorted { $0.sortOrder < $1.sortOrder }
        let himmelmann = try #require(
            bibBlocksBefore.first { $0.markdownFragment.contains("Himmelmann") },
            "richTestContent should contain a Himmelmann bibliography entry"
        )

        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-bare-title-heading",
                blockType: "heading",
                textContent: "References",
                markdownFragment: "# References",
                headingLevel: 1,
                afterBlockId: himmelmann.id
            )
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-bare-title-heading"])
        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isBibliography == false,
            """
            A bare-title heading fragment (no marker) must never be adopted as the bibliography \
            heading, even wedged between two flagged entries where containment alone would \
            resolve true
            """
        )
    }

    // MARK: - Case 8: insert path honours the marker

    @Test("Insert path honours the marker: a marker-carrying heading fragment inserted OUTSIDE any bibliography containment is still flagged")
    func insertPathHonoursTheMarker() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Insert at document start -- deliberately NOT anchored to any bibliography block.
        // `resolveInsertPlacement`'s doc-start branch always resolves `isBibliography: false`
        // unconditionally, without ever reaching the containment check, so
        // `isBibliographyContainment` is guaranteed false here. That means ONLY
        // `buildInsertedBlock`'s independent `hasBibliographyMarker` check can make the
        // assertion below pass. (The previous version of this test anchored between two
        // already-flagged bibliography rows, where containment alone would have satisfied the
        // assertion even with the marker-check branch deleted -- it proved nothing about the
        // marker check itself.)
        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-marker-heading",
                blockType: "heading",
                textContent: "References",
                markdownFragment: "<!-- ::auto-bibliography:: --># References",
                headingLevel: 1,
                afterBlockId: nil,
                atDocumentStart: true
            )
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-marker-heading"])
        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isBibliography == true,
            "A marker-carrying heading fragment must be flagged purely by carrying the marker, with no containment help"
        )
    }

}
