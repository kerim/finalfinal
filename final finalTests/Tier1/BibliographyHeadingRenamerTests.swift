//
//  BibliographyHeadingRenamerTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression coverage for BibliographyHeadingRenamer.rename -- the single-row bibliography
//  heading retitle that fires when the bibliography-heading-name preference changes while a
//  document is open. See BibliographyHeadingRenamer.swift's doc comment for the full design
//  rationale (strict single-candidate matching, the collision guard, why no busy-guard against
//  BibliographySyncService is needed).
//
//  ExportSettings ISOLATION: this suite never reads or writes `ExportSettings.userDefaults` --
//  `BibliographyHeadingRenamer.rename` takes `oldNames`/`newName` as plain arguments and never
//  consults settings itself, so there is nothing here to isolate.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("BibliographyHeadingRenamer")
struct BibliographyHeadingRenamerTests {

    /// Creates a fixture database and clears its placeholder content. Every scenario below
    /// inserts its own bibliography blocks directly via `db.write`, for full control over the
    /// exact shape (heading level, isBibliography flags, duplicate/colliding headings) each
    /// test needs -- going through BlockParser.parse for these setups would fight the very
    /// title-matching logic under test.
    private static func makeFixture() throws -> (ProjectDatabase, String) {
        let db = try TestFixtureFactory.createTemporary(content: "# Placeholder\n\nBody text.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }
        return (db, projectId)
    }

    @discardableResult
    private static func insertHeading(
        _ db: ProjectDatabase, _ projectId: String, text: String, level: Int = 1,
        sortOrder: Double, isBibliography: Bool
    ) throws -> Block {
        var block = Block(
            projectId: projectId,
            sortOrder: sortOrder,
            blockType: .heading,
            textContent: text,
            markdownFragment: String(repeating: "#", count: level) + " " + text,
            headingLevel: level,
            status: .final_,
            wordCount: MarkdownUtils.wordCount(for: text),
            isBibliography: isBibliography
        )
        try db.write { database in try block.insert(database) }
        return block
    }

    /// Inserts a block in the marker-glued heading shape (`blockType == .bibliography`,
    /// `headingLevel == nil`, marker glued directly onto the heading text in one fragment --
    /// see `BlockParser.parse`'s doc comment) -- exactly what `BibliographySyncService`'s own
    /// regeneration writes by default, not a synthetic/legacy-only shape.
    @discardableResult
    private static func insertGluedMarkerHeading(
        _ db: ProjectDatabase, _ projectId: String, title: String, level: Int = 1, sortOrder: Double
    ) throws -> Block {
        let prefix = String(repeating: "#", count: level)
        let fragment = "\(BlockParser.bibliographyStartMarker)\(prefix) \(title)"
        var block = Block(
            projectId: projectId,
            sortOrder: sortOrder,
            blockType: .bibliography,
            textContent: fragment,
            markdownFragment: fragment,
            headingLevel: nil,
            status: .final_,
            wordCount: MarkdownUtils.wordCount(for: title),
            isBibliography: true
        )
        try db.write { database in try block.insert(database) }
        return block
    }

    @discardableResult
    private static func insertParagraph(
        _ db: ProjectDatabase, _ projectId: String, text: String, sortOrder: Double, isBibliography: Bool
    ) throws -> Block {
        var block = Block(
            projectId: projectId,
            sortOrder: sortOrder,
            blockType: .paragraph,
            textContent: text,
            markdownFragment: text,
            wordCount: MarkdownUtils.wordCount(for: text),
            isBibliography: isBibliography
        )
        try db.write { database in try block.insert(database) }
        return block
    }

    private static func fetchBlock(_ db: ProjectDatabase, id: String) throws -> Block? {
        try db.read { database in try Block.fetchOne(database, key: id) }
    }

    @Test("Exactly one candidate renames correctly -- id preserved, all fields change together")
    func exactlyOneCandidateRenames() throws {
        let (db, projectId) = try Self.makeFixture()
        let heading = try Self.insertHeading(
            db, projectId, text: "Old Name and a Half", level: 1, sortOrder: 1.0, isBibliography: true)
        try Self.insertParagraph(db, projectId, text: "Entry one.", sortOrder: 2.0, isBibliography: true)
        let beforeUpdatedAt = heading.updatedAt
        let beforeWordCount = heading.wordCount

        let outcome = BibliographyHeadingRenamer.rename(
            in: db, projectId: projectId, from: ["Old Name and a Half"], to: "New Name")
        #expect(outcome == .renamed)

        let after = try #require(try Self.fetchBlock(db, id: heading.id))
        #expect(after.id == heading.id, "Row id must be preserved -- this is a RETITLE, not a delete-and-reinsert")
        #expect(after.textContent == "New Name")
        #expect(after.markdownFragment == "# New Name")
        #expect(after.headingLevel == 1)
        #expect(after.wordCount == MarkdownUtils.wordCount(for: "New Name"))
        #expect(after.wordCount != beforeWordCount, "wordCount must be recomputed for the new text, not left stale")
        // `>=` rather than strict `>`: both timestamps come from `Date()` calls microseconds
        // apart, and the DB's date-storage precision must not make this test flaky.
        #expect(after.updatedAt >= beforeUpdatedAt)
        #expect(after.isBibliography == true, "isBibliography must not be disturbed by a rename")

        // The entry paragraph is untouched by the rename.
        let entries = try #require(try db.read { database in
            try Block.filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.blockType == BlockType.paragraph.rawValue)
                .fetchAll(database)
        }).first
        #expect(entries?.textContent == "Entry one.")
    }

    @Test("## level is preserved across a rename")
    func levelTwoIsPreserved() throws {
        let (db, projectId) = try Self.makeFixture()
        let heading = try Self.insertHeading(
            db, projectId, text: "Old Name", level: 2, sortOrder: 1.0, isBibliography: true)

        let outcome = BibliographyHeadingRenamer.rename(
            in: db, projectId: projectId, from: ["Old Name"], to: "New Name")
        #expect(outcome == .renamed)

        let after = try #require(try Self.fetchBlock(db, id: heading.id))
        #expect(after.markdownFragment == "## New Name")
        #expect(after.headingLevel == 2)
    }

    @Test("Zero candidates no-ops")
    func zeroCandidatesNoOps() throws {
        let (db, projectId) = try Self.makeFixture()
        try Self.insertHeading(db, projectId, text: "Unrelated", sortOrder: 1.0, isBibliography: true)

        let outcome = BibliographyHeadingRenamer.rename(
            in: db, projectId: projectId, from: ["Old Name"], to: "New Name")
        #expect(outcome == .noOp(.noCandidate))
    }

    @Test("Two candidates no-ops -- neither is touched")
    func twoCandidatesNoOps() throws {
        let (db, projectId) = try Self.makeFixture()
        let first = try Self.insertHeading(db, projectId, text: "Old Name", sortOrder: 1.0, isBibliography: true)
        let second = try Self.insertHeading(db, projectId, text: "Old Name", sortOrder: 5.0, isBibliography: true)

        let outcome = BibliographyHeadingRenamer.rename(
            in: db, projectId: projectId, from: ["Old Name"], to: "New Name")
        #expect(outcome == .noOp(.ambiguousCandidates(count: 2)))

        let afterFirst = try #require(try Self.fetchBlock(db, id: first.id))
        let afterSecond = try #require(try Self.fetchBlock(db, id: second.id))
        #expect(afterFirst.textContent == "Old Name")
        #expect(afterSecond.textContent == "Old Name")
    }

    @Test("Collision with an existing heading already carrying the target title no-ops")
    func collisionWithExistingHeadingNoOps() throws {
        let (db, projectId) = try Self.makeFixture()
        let candidate = try Self.insertHeading(
            db, projectId, text: "Old Name", sortOrder: 1.0, isBibliography: true)
        // A completely ordinary user heading that happens to already carry the target title.
        try Self.insertHeading(db, projectId, text: "New Name", sortOrder: 5.0, isBibliography: false)

        let outcome = BibliographyHeadingRenamer.rename(
            in: db, projectId: projectId, from: ["Old Name"], to: "New Name")
        #expect(
            outcome == .noOp(.collision(existingTitle: "New Name")),
            "the collision reason must name the ACTUAL colliding title, safe to show a user directly"
        )

        let after = try #require(try Self.fetchBlock(db, id: candidate.id))
        #expect(after.textContent == "Old Name", "Must not have been retitled into a colliding title")
    }

    @Test("Judge-round must-fix 5: a marker-glued heading (blockType == .bibliography, headingLevel == nil) is retitled")
    func gluedMarkerHeadingRenames() throws {
        let (db, projectId) = try Self.makeFixture()
        let heading = try Self.insertGluedMarkerHeading(db, projectId, title: "Bibliography", sortOrder: 1.0)
        try Self.insertParagraph(db, projectId, text: "Entry one.", sortOrder: 2.0, isBibliography: true)

        let outcome = BibliographyHeadingRenamer.rename(
            in: db, projectId: projectId, from: ["Bibliography"], to: "References")
        #expect(outcome == .renamed)

        let after = try #require(try Self.fetchBlock(db, id: heading.id))
        #expect(after.id == heading.id, "must be a RETITLE, preserving the row id")
        #expect(after.blockType == .bibliography, "classification is deliberately not repaired by the rename")
        #expect(after.headingLevel == nil)
        #expect(after.markdownFragment == "\(BlockParser.bibliographyStartMarker)# References")
        #expect(after.textContent == after.markdownFragment, "extractTextContent never strips .bibliography content")
        #expect(after.isBibliography == true)
    }

    @Test("Judge-round must-fix 5: a level-2 marker-glued heading preserves its level across a rename")
    func gluedMarkerHeadingLevelTwoIsPreserved() throws {
        let (db, projectId) = try Self.makeFixture()
        let heading = try Self.insertGluedMarkerHeading(db, projectId, title: "Old Name", level: 2, sortOrder: 1.0)

        let outcome = BibliographyHeadingRenamer.rename(
            in: db, projectId: projectId, from: ["Old Name"], to: "New Name")
        #expect(outcome == .renamed)

        let after = try #require(try Self.fetchBlock(db, id: heading.id))
        #expect(after.markdownFragment == "\(BlockParser.bibliographyStartMarker)## New Name")
        #expect(after.headingLevel == nil, "glued shape's headingLevel stays nil -- level lives in the fragment text")
    }

    @Test("Judge-round must-fix 6: collision guard catches a colliding heading at ANY level, not just # or ##")
    func collisionAtLevelThreeNoOps() throws {
        let (db, projectId) = try Self.makeFixture()
        let candidate = try Self.insertHeading(
            db, projectId, text: "Old Name", sortOrder: 1.0, isBibliography: true)
        // An ordinary H3 user heading that already carries the target title -- the old
        // fragment-shape match ("# X"/"## X" only) missed this entirely.
        try Self.insertHeading(db, projectId, text: "New Name", level: 3, sortOrder: 5.0, isBibliography: false)

        let outcome = BibliographyHeadingRenamer.rename(
            in: db, projectId: projectId, from: ["Old Name"], to: "New Name")
        #expect(outcome == .noOp(.collision(existingTitle: "New Name")))

        let after = try #require(try Self.fetchBlock(db, id: candidate.id))
        #expect(after.textContent == "Old Name", "must not have been retitled into a colliding title even at H3")
    }

    @Test("Judge-round must-fix: a candidate already titled newName no-ops without writing or checking for collisions")
    func candidateAlreadyCorrectNoOps() throws {
        let (db, projectId) = try Self.makeFixture()
        // Exactly the reconciliation-path shape: `newName` ("Bibliography") is also present in
        // `oldNames`, and the one matching candidate already carries that exact title.
        let candidate = try Self.insertHeading(
            db, projectId, text: "Bibliography", sortOrder: 1.0, isBibliography: true)
        // An unrelated, unflagged heading that happens to already share the same title -- under
        // the OLD code (no already-correct check ahead of the collision guard), this would have
        // tripped a bogus `.collision` against the candidate's own, already-correct name.
        try Self.insertHeading(db, projectId, text: "Bibliography", level: 2, sortOrder: 5.0, isBibliography: false)
        // Re-fetched from the DB rather than read off the in-memory `candidate` struct: GRDB
        // stores `Date` as TEXT truncated to millisecond precision (`Date.swift`'s
        // "yyyy-MM-dd HH:mm:ss.SSS" storage formatter), so the raw pre-insert `Date()` value
        // (full double precision) is NOT bit-for-bit identical to what a fresh SELECT decodes
        // back -- comparing the two below would fail on that precision loss alone, with no
        // write ever having happened. Fetching "before" through the same round-trip as "after"
        // makes the equality check actually test what it claims to test.
        let beforeUpdatedAt = try #require(try Self.fetchBlock(db, id: candidate.id)).updatedAt

        let outcome = BibliographyHeadingRenamer.rename(
            in: db, projectId: projectId, from: ["Bibliography"], to: "Bibliography")
        #expect(
            outcome == .noOp(.alreadyCorrect),
            "already being correctly titled must win over the collision guard, not trip it"
        )

        let after = try #require(try Self.fetchBlock(db, id: candidate.id))
        #expect(after.textContent == "Bibliography")
        #expect(after.updatedAt == beforeUpdatedAt, "must not have been written to at all -- not even a bare updatedAt bump")
    }

    @Test("A grace-list name among several oldNames still matches the one real candidate")
    func graceListNameAmongOldNamesMatches() throws {
        let (db, projectId) = try Self.makeFixture()
        let heading = try Self.insertHeading(
            db, projectId, text: "Works Cited", sortOrder: 1.0, isBibliography: true)

        let outcome = BibliographyHeadingRenamer.rename(
            in: db, projectId: projectId, from: ["Sources", "Works Cited", "Bibliography"], to: "References")
        #expect(outcome == .renamed)

        let after = try #require(try Self.fetchBlock(db, id: heading.id))
        #expect(after.textContent == "References")
    }

    // MARK: - NoOpReason.message -- plain-English text safe to show a user

    @Test("""
          Reproduces the user's exact reported scenario: a real bibliography heading ("Works Cited") \
          and an unflagged, unrelated heading that already carries the target title ("Bibliography") -- \
          renaming must no-op with a specific, correct collision error, never silently
          """)
    func reproducesReportedCollisionScenario() throws {
        let (db, projectId) = try Self.makeFixture()
        let bibliography = try Self.insertHeading(
            db, projectId, text: "Works Cited", sortOrder: 1.0, isBibliography: true)
        try Self.insertParagraph(db, projectId, text: "Doe, J. (2020).", sortOrder: 2.0, isBibliography: true)
        // The user's deliberate, unflagged "# Bibliography" heading elsewhere in the document
        // (created for an earlier fix's testing instructions) -- an entirely ordinary heading,
        // not a bibliography section at all.
        try Self.insertHeading(db, projectId, text: "Bibliography", sortOrder: 0.5, isBibliography: false)

        let outcome = BibliographyHeadingRenamer.rename(
            in: db, projectId: projectId, from: ["Works Cited"], to: "Bibliography")

        #expect(outcome == .noOp(.collision(existingTitle: "Bibliography")))
        #expect(
            outcome.noOpMessage ==
                "Another heading in this document is already named \"Bibliography\" " +
                "— rename it first, or choose a different name."
        )

        let after = try #require(try Self.fetchBlock(db, id: bibliography.id))
        #expect(after.textContent == "Works Cited", "the real bibliography heading must not have been touched")
        #expect(after.isBibliography == true, "must not lose its flag on a refused rename")
    }

    @Test("Every NoOpReason has distinct, plain-English message text")
    func noOpReasonMessagesAreDistinctAndPlain() {
        typealias NoOpReason = BibliographyHeadingRenamer.NoOpReason
        let messages: [String] = [
            NoOpReason.noCandidate.message,
            NoOpReason.alreadyCorrect.message,
            NoOpReason.ambiguousCandidates(count: 2).message,
            NoOpReason.collision(existingTitle: "X").message,
            NoOpReason.databaseError.message
        ]
        #expect(Set(messages).count == messages.count, "each reason must produce distinct user-facing text")
        for message in messages {
            #expect(!message.isEmpty)
        }
    }
}

private extension BibliographyHeadingRenamer.RenameOutcome {
    /// Test convenience: the `.noOp` case's message, or `nil` for `.renamed`.
    var noOpMessage: String? {
        if case .noOp(let reason) = self { return reason.message }
        return nil
    }
}
