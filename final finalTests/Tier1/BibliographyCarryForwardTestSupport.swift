//
//  BibliographyCarryForwardTestSupport.swift
//  final finalTests
//
//  Shared fixtures and helpers for the Bibliography Carry-Forward Tier 1 suites:
//  `BibliographyCarryForwardTests.swift` (the carry-forward mechanism itself) and
//  `BibliographyCarryForwardRegressionTests.swift` (idempotency, isolation from other
//  replaceBlocks paths, and the multi-section case).
//
//  `Database+BlocksReplace+Preservation.swift`'s applyPreservedHeading restores isBibliography onto a
//  HEADING by title match, but never onto the entry rows below it. When BlockParser.parse()
//  fails to recognise that heading (custom header name since changed, heading level demoted
//  past isBibliographyHeading's exact `# X`/`## X` forms), the entries come back unflagged
//  while the heading comes back flagged. BibliographySyncService.updateBibliographyBlock then
//  deletes only the flagged heading and regenerates, stranding the old entries as duplicate
//  body text in the document and in every export.
//
//  FIX: replaceBlocks' default path carries the restored flag forward onto the rows beneath
//  such a heading, bounded BOTH by the next heading AND by the first block after the heading
//  carrying `endsBibliographyRun` (BlockParser.parse's transient marker for
//  `bibliographyEndMarker`) — whichever comes first — and capped by the count of non-heading
//  isBibliography rows the project already has.
//
//  PREVENTIVE, NOT CURATIVE. See `alreadyDamagedDocumentIsNotRepaired` in
//  `BibliographyCarryForwardTests.swift`: a document already in the broken state is
//  deliberately left alone, because the terminator in that state sits immediately after the
//  heading and bounds nothing. Pinned, understood limitation.
//

import Testing
import Foundation
import GRDB
@testable import final_final

enum BibliographyCarryForwardSupport {

    /// ExportSettings ISOLATION: neither suite reads OR writes `ExportSettings.userDefaults`'s
    /// swappable state — it does not need to. This "unrecognised heading" literal is
    /// deliberately shaped so that no real bibliography header name setting, and no other test
    /// suite's swapped literal, could plausibly collide with it. Do NOT add settings
    /// isolation/swapping machinery to these files; that would create exactly the cross-suite
    /// race this design avoids by construction.
    static let syntheticHeader = "Sources §carry-fixture"
    static var syntheticHeadingMarkdown: String { "# \(syntheticHeader)" }

    /// A second, distinct unrecognised header — used only by the two-section test, so a
    /// document can carry two independently-mismatched bibliography headings at once without
    /// them colliding on the same title queue.
    static let syntheticHeader2 = "Sources §carry-fixture-two"
    static var syntheticHeadingMarkdown2: String { "# \(syntheticHeader2)" }

    static func blocks(_ db: ProjectDatabase, _ projectId: String) throws -> [Block] {
        try db.read { database in
            try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(database)
        }
    }

    static func flag(_ db: ProjectDatabase, _ projectId: String, containing needles: [String]) throws {
        try db.write { database in
            for var row in try Block
                .filter(Block.Columns.projectId == projectId)
                .fetchAll(database) where needles.contains(where: { row.markdownFragment.contains($0) }) {
                row.isBibliography = true
                try row.update(database)
            }
        }
    }

    static func isFlagged(_ all: [Block], _ needle: String) throws -> Bool {
        try #require(all.first { $0.markdownFragment.contains(needle) }).isBibliography
    }

    static func seed(content: String, flagged: [String]) throws -> (ProjectDatabase, String) {
        let db = try TestFixtureFactory.createTemporary(content: content)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        try db.replaceBlocks(BlockParser.parse(markdown: content, projectId: projectId), for: projectId)
        try flag(db, projectId, containing: flagged)
        return (db, projectId)
    }

    @discardableResult
    static func roundTrip(_ db: ProjectDatabase, _ projectId: String) throws -> String {
        let markdown = BlockParser.assembleMarkdownForEditor(from: try blocks(db, projectId))
        try db.replaceBlocks(BlockParser.parse(markdown: markdown, projectId: projectId), for: projectId)
        return markdown
    }
}
