//
//  MarkdownLeaderMapTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 5, plan B1: `MarkdownLeaderMap`, the request for the
//  page's `markdownStructuralEditorFirst`, built from the rows of a REAL database (the fixtures are parsed by `BlockParser`, so the Notes,
//  Bibliography and section-break flags are the ones the app's rows carry). No page. Break patches (a 1-5 line change in
//  `MarkdownLeaderMap.swift`) and the failure each makes:
//
//   order and levels  BREAK: in `init` filter on `\.isPseudoSection` only (headings dropped).
//                      FAILS: "leaders are not the headings in order".
//   section break      BREAK: in `init` use `block.headingLevel ?? 2`.   FAILS: "a section break is not level 1".
//   managed flags      BREAK: in `init` set `managed: nil` always.
//                      FAILS: "the Notes / Bibliography rows are not marked managed".
//   stopLine           BREAK: in `request` take `nil` as `stopLine`.
//                      FAILS: "stopLine is not the first Notes/Bibliography row's line".
//   endLeaderId        BREAK: in `request` filter `$0.level < root.level`.
//                      FAILS: "endLeaderId is not the first later leader that is not deeper".
//   end rule           BREAK: in `removedLeaderIds` drop the `leader.managed == nil` test.
//                      FAILS: "the section ran into the Notes/Bibliography".
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("Markdown leader map — Tier 2 (t-4a8fd8af round 5, B1)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownLeaderMapTests {

    private struct Fixture {
        let map: MarkdownLeaderMap
        let rows: [Block]
        let db: ProjectDatabase
        let pid: String
    }

    private func rows(_ markdown: String) throws -> Fixture {
        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        return Fixture(map: MarkdownLeaderMap(rows: blocks), rows: blocks, db: db, pid: pid)
    }

    private func id(of title: String, in rows: [Block]) throws -> String {
        try #require(rows.first { $0.blockType == .heading && $0.textContent == title }, "no heading \(title)").id
    }

    private static let chapters =
        "# Chapter 1\n\nOne.\n\n## Section 1.1\n\nOne point one.\n\n# Chapter 2\n\nTwo.\n\n"
        + "## Section 2.1\n\nTwo point one.\n\n### Part 2.1.1\n\nDeep.\n\n# Chapter 3\n\nThree."

    @Test("leaders are every heading in document order with their levels and first lines")
    func orderAndLevels() throws {
        let fixture = try rows(Self.chapters)
        #expect(
            fixture.map.leaders.map(\.line) == ["# Chapter 1", "## Section 1.1", "# Chapter 2", "## Section 2.1", "### Part 2.1.1", "# Chapter 3"],
            "leaders are not the headings in order")
        #expect(fixture.map.leaders.map(\.level) == [1, 2, 1, 2, 3, 1])
        #expect(fixture.map.leaders.allSatisfy { $0.managed == nil })
    }

    @Test("a section break is a leader at level 1, with the marker as its line")
    func sectionBreakIsLevelOne() throws {
        let fixture = try rows("# Chapter 1\n\nOne.\n\n## Section 1.1\n\nx\n\n\(BlockParser.sectionBreakMarker)\n\n# Chapter 2\n\nTwo.")
        let breakLeader = try #require(fixture.map.leaders.first { $0.line == BlockParser.sectionBreakMarker }, "the break is not a leader")
        #expect(breakLeader.level == 1, "a section break is not level 1")
        // The break ends a level-1 chapter's section and the sub-section before it belongs to Chapter 1.
        let chapter1 = try id(of: "Chapter 1", in: fixture.rows)
        #expect(fixture.map.removedLeaderIds(rootId: chapter1).count == 2)
    }

    @Test("Notes and Bibliography rows are managed; stopLine is the first managed row after the root; endLeaderId the first not-deeper leader")
    func managedFlagsStopLineAndEndLeader() throws {
        // The text the editor's CONTENT RECORD holds for a generated bibliography (`ComplexDocumentFixture.editorMarkdown`'s shape): Notes
        // with its definitions, then `# Bibliography` with one paragraph per entry and the end marker. No opening marker: the app stores
        // the bibliography WITHOUT it (`BibliographySyncService+EntryFormatting`: "marker is injected only for CodeMirror source mode").
        let text = "# Chapter 1\n\nOne.[^1]\n\n## Section 1.1\n\nx\n\n# Chapter 2\n\nTwo.\n\n# Notes\n\n[^1]: Note.\n\n"
            + "# Bibliography\n\nSmith, J. (2020). A book.\n\nJones, K. (2021). Another.\n\n<!-- ::auto-bibliography-end:: -->"
        let fixture = try rows(text)
        let notes = try #require(fixture.map.leaders.first { $0.managed == "notes" }, "the Notes / Bibliography rows are not marked managed")
        let bibliography = try #require(
            fixture.map.leaders.first { $0.managed == "bibliography" }, "the Notes / Bibliography rows are not marked managed")
        #expect(notes.line == "# Notes")
        #expect(bibliography.line == "# Bibliography")

        let chapter2 = try id(of: "Chapter 2", in: fixture.rows)
        let request = try #require(fixture.map.request(opId: UUID(), rootId: chapter2))
        #expect(request.stopLine == "# Notes", "stopLine is not the first Notes/Bibliography row's line")
        #expect(request.endLeaderId == notes.id, "endLeaderId is not the first later leader that is not deeper")
        #expect(fixture.map.removedLeaderIds(rootId: chapter2) == [chapter2], "the section ran into the Notes/Bibliography")

        let chapter1 = try id(of: "Chapter 1", in: fixture.rows)
        let first = try #require(fixture.map.request(opId: UUID(), rootId: chapter1))
        #expect(first.endLeaderId == chapter2, "endLeaderId is not the first later leader that is not deeper")
        #expect(first.stopLine == "# Notes")
    }

    @Test("rows written the way BibliographySyncService writes them (a .heading row and paragraphs, isBibliography, no marker) are managed")
    func rowsWrittenByTheBibliographyServiceAreManaged() throws {
        let chapters = try rows("# Chapter 1\n\nOne.\n\n# Chapter 2\n\nTwo.")
        var stored = chapters.rows
        let after = (stored.map(\.sortOrder).max() ?? 0) + 1
        // `writeBibliographyRows`: the heading fragment first (typed .heading, level 1), then one paragraph per entry, all isBibliography.
        stored.append(Block(
            projectId: chapters.pid, sortOrder: after, blockType: .heading, textContent: "Bibliography",
            markdownFragment: "# Bibliography", headingLevel: 1, isBibliography: true))
        stored.append(Block(
            projectId: chapters.pid, sortOrder: after + 1, blockType: .paragraph, textContent: "Smith, J. (2020). A book.",
            markdownFragment: "Smith, J. (2020). A book.", isBibliography: true))
        let map = MarkdownLeaderMap(rows: stored)
        let bibliography = try #require(map.leaders.first { $0.managed == "bibliography" }, "the Notes / Bibliography rows are not marked managed")
        #expect(bibliography.line == "# Bibliography" && bibliography.level == 1)

        let chapter2 = try id(of: "Chapter 2", in: stored)
        let request = try #require(map.request(opId: UUID(), rootId: chapter2))
        #expect(request.stopLine == "# Bibliography", "stopLine is not the first Notes/Bibliography row's line")
        #expect(request.endLeaderId == bibliography.id)
        #expect(map.removedLeaderIds(rootId: chapter2) == [chapter2], "the section ran into the Notes/Bibliography")
    }

    @Test("a Notes H2 after an H1 chapter is managed and ends the chapter although it is deeper")
    func notesH2EndsTheChapter() throws {
        let fixture = try rows("# Chapter 1\n\nOne.[^1]\n\n# Chapter 2\n\nTwo.\n\n## Notes\n\n[^1]: Note.")
        let chapter2 = try id(of: "Chapter 2", in: fixture.rows)
        let notes = try #require(fixture.map.leaders.first { $0.managed == "notes" }, "the Notes / Bibliography rows are not marked managed")
        #expect(notes.level == 2)
        #expect(fixture.map.removedLeaderIds(rootId: chapter2) == [chapter2], "the section ran into the Notes/Bibliography")
        let request = try #require(fixture.map.request(opId: UUID(), rootId: chapter2))
        #expect(request.stopLine == "## Notes" && request.endLeaderId == nil)
    }

    @Test("the legacy shape (the opening marker glued to the heading in ONE row, typed .bibliography) is read as the managed bibliography leader")
    func legacyGluedMarkerRowIsAManagedLeader() throws {
        // What BlockParser makes of text that still holds the glued marker: not a `.heading` row (the fragment starts with `<!--`).
        let text = "# Chapter 1\n\nOne.\n\n# Chapter 2\n\nTwo.\n\n<!-- ::auto-bibliography:: --># Bibliography\n\n"
            + "Smith, J. (2020). A book.\n\n<!-- ::auto-bibliography-end:: -->"
        let fixture = try rows(text)
        let glued = try #require(fixture.rows.first { $0.markdownFragment.contains("::auto-bibliography:: -->") && $0.isBibliography })
        #expect(glued.blockType == .bibliography, "premise: the parser types the glued heading row .bibliography")
        let bibliography = try #require(
            fixture.map.leaders.first { $0.managed == "bibliography" }, "the Notes / Bibliography rows are not marked managed")
        #expect(bibliography.id == glued.id && bibliography.line == "# Bibliography" && bibliography.level == 1)
        let chapter2 = try id(of: "Chapter 2", in: fixture.rows)
        #expect(fixture.map.removedLeaderIds(rootId: chapter2) == [chapter2], "the section ran into the Notes/Bibliography")
        let request = try #require(fixture.map.request(opId: UUID(), rootId: chapter2))
        #expect(request.endLeaderId == bibliography.id)
    }

    @Test("a standalone bibliography opening marker row is the stopLine of the last chapter before it")
    func standaloneMarkerIsTheStopLine() throws {
        let text = "# Chapter 1\n\nOne.\n\n# Chapter 2\n\nTwo.\n\n<!-- ::auto-bibliography:: -->\n\n# Bibliography\n\nSmith, J. (2020). A book.\n\n"
            + "<!-- ::auto-bibliography-end:: -->"
        let fixture = try rows(text)
        let chapter2 = try id(of: "Chapter 2", in: fixture.rows)
        let request = try #require(fixture.map.request(opId: UUID(), rootId: chapter2))
        #expect(request.stopLine == "<!-- ::auto-bibliography:: -->", "stopLine is not the first Notes/Bibliography row's line")
        let bibliography = try #require(fixture.map.leaders.first { $0.managed == "bibliography" })
        #expect(request.endLeaderId == bibliography.id)
        #expect(fixture.map.removedLeaderIds(rootId: chapter2) == [chapter2], "the last chapter ran into the Bibliography")
    }

    @Test("with nothing managed after the root, stopLine and endLeaderId are null in the JSON; a managed or unknown root gets no request")
    func requestJSONAndRefusals() throws {
        let fixture = try rows(Self.chapters)
        let chapter3 = try id(of: "Chapter 3", in: fixture.rows)
        let request = try #require(fixture.map.request(opId: UUID(), rootId: chapter3))
        #expect(request.stopLine == nil && request.endLeaderId == nil)
        let json = try #require(request.json)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "delete")
        #expect(object["rootId"] as? String == chapter3)
        #expect(object["stopLine"] is NSNull && object["endLeaderId"] is NSNull, "absent values must be explicit nulls")
        #expect((object["leaders"] as? [[String: Any]])?.count == 6)

        #expect(fixture.map.request(opId: UUID(), rootId: "no-such-block") == nil)
        let withNotes = try rows("# Chapter 1\n\nOne.[^1]\n\n# Notes\n\n[^1]: Note.")
        let notesId = try #require(withNotes.map.leaders.first { $0.managed == "notes" }).id
        #expect(withNotes.map.request(opId: UUID(), rootId: notesId) == nil, "a managed root must get no request")
        #expect(withNotes.map.removedLeaderIds(rootId: notesId).isEmpty)
    }

    @Test("the leaders a delete takes are exactly the leaders the database's own end rule takes, for every deletable root")
    func agreesWithTheDatabaseEndRule() throws {
        let text = Self.chapters + "\n\n# Chapter 4\n\nFour.[^1]\n\n## Section 4.1\n\nx\n\n# Notes\n\n[^1]: Note."
        let fixture = try rows(text)
        let leaderIds = Set(fixture.map.leaders.map(\.id))
        for leader in fixture.map.leaders where leader.managed == nil {
            let subtree = try #require(try fixture.db.sectionBlockIds(rootId: leader.id, projectId: fixture.pid))
            let databaseLeaders = subtree.filter { leaderIds.contains($0) }
            let removed = Set(fixture.map.removedLeaderIds(rootId: leader.id))
            #expect(removed == Set(databaseLeaders), "the section ran into the Notes/Bibliography (\(leader.line))")
        }
    }

    // MARK: - M-3: finding the root again after a slow undo re-created its rows

    /// A slow Cmd-Z puts a deleted section back by replacing the project's rows with a snapshot's: the section's rows get FRESH ids, so
    /// the id the Delete clicked on names no row, and the slow redo's request (which needs a root that is one of the leaders) could not
    /// be built from it. A second parse of the same text stands in for the re-created rows (the parser makes new ids every time).
    /// BREAK: in `currentRootId(for:)` return `nil` instead of looking the line up.   FAILS: "the root was not found again".
    @Test("review M-3: a root whose rows were re-created with fresh ids is found again by its heading line and occurrence")
    func theRootIsFoundAgainAfterItsRowsWereRecreated() throws {
        let text = "# Chapter 1\n\nOne.\n\n# Same\n\nA.\n\n# Chapter 3\n\nThree.\n\n# Same\n\nB."
        let before = try rows(text)
        let after = try rows(text)
        func leaderId(_ fixture: Fixture, _ line: String, occurrence: Int = 0) throws -> String {
            try #require(fixture.map.leaders.filter { $0.line == line }[occurrence...].first, "no leader \(line)").id
        }
        let chapter3Before = try leaderId(before, "# Chapter 3")
        let chapter3After = try leaderId(after, "# Chapter 3")
        try #require(chapter3Before != chapter3After, "premise: a second parse gives the heading a fresh id")

        let reference = try #require(before.map.rootReference(of: chapter3Before), "no reference to a deletable root")
        #expect(reference.line == "# Chapter 3" && reference.occurrence == 0)
        #expect(before.map.currentRootId(for: reference) == chapter3Before, "a root whose own id still exists keeps it")
        #expect(after.map.currentRootId(for: reference) == chapter3After, "the root was not found again by its heading line")

        // The second chapter with the same title is the second occurrence, not the first.
        let secondSameBefore = try leaderId(before, "# Same", occurrence: 1)
        let secondReference = try #require(before.map.rootReference(of: secondSameBefore))
        #expect(secondReference.occurrence == 1)
        let secondSameAfter = try leaderId(after, "# Same", occurrence: 1)
        #expect(after.map.currentRootId(for: secondReference) == secondSameAfter, "the wrong occurrence was chosen")
    }

    @Test("review M-3: a root that cannot be found again is refused, never guessed: its line is gone, or fewer such lines remain")
    func aRootThatCannotBeFoundAgainIsRefused() throws {
        let before = try rows("# Chapter 1\n\nOne.\n\n# Same\n\nA.\n\n# Same\n\nB.\n\n# Notes\n\n[^1]: Note.")
        let secondSame = try #require(before.map.leaders.filter { $0.line == "# Same" }.last, "no second '# Same'")
        let reference = try #require(before.map.rootReference(of: secondSame.id))
        let renamed = try rows("# Chapter 1\n\nOne.\n\n# Other\n\nA.\n\n# Same\n\nB.")
        #expect(renamed.map.currentRootId(for: reference) == nil, "only one '# Same' is left, so the second occurrence does not exist")
        let gone = try rows("# Chapter 1\n\nOne.")
        #expect(gone.map.currentRootId(for: reference) == nil, "the heading line is gone")
        let notes = try #require(before.map.leaders.first { $0.managed == "notes" }, "no Notes leader")
        #expect(before.map.rootReference(of: notes.id) == nil, "a managed heading is no deletable root")
    }

    // MARK: - M-1 / M-4: the grammar the page's own heading scan assumes

    /// The page (web/codemirror/src/api-structural-markdown.ts) counts leaders with its own scan, and a delete is refused as
    /// `leadersMismatch` whenever its count differs from the rows'. These are the facts about `BlockParser` that scan relies on, so a
    /// change on either side shows here. BREAK: in `detectBlockType` change the heading regex `\s+` to `[ \t]+`; FAILS: "U+3000 after the
    /// hashes".
    @Test("review M-1/M-4: '#' + U+3000 is a heading, and '~~~' is no fence, so a '# x' between two '~~~' lines is a heading row")
    func theBlockParserGrammarThePageScanAssumes() throws {
        let cjk = BlockParser.detectBlockType("#\u{3000}第二章")
        #expect(cjk.0 == .heading && cjk.1 == 1, "U+3000 after the hashes is not an ATX heading space in BlockParser")
        #expect(BlockParser.detectBlockType("#\u{00A0}Title").0 == .heading, "NBSP after the hashes is not an ATX heading space in BlockParser")
        #expect(BlockParser.detectBlockType("#\u{FEFF}Title").0 != .heading, "U+FEFF after the hashes must not be a heading space (ICU)")
        #expect(BlockParser.detectBlockType("#第二章").0 != .heading, "no space after the hashes must not be a heading")

        let fixture = try rows("## A\n\ntext\n\n~~~\n\n# x\n\n~~~\n\n## B\n\nmore\n")
        #expect(
            fixture.map.leaders.map(\.line) == ["## A", "# x", "## B"],
            "a '# x' between two '~~~' lines must be a heading row: tilde blocks are not fences")
    }

    @MainActor
    @Test("the record text drops the section anchors and the bibliography opening marker and keeps the end marker")
    func recordText() {
        let raw = "<!-- @sid:ab12-cd34 -->## Notes\n\n<!-- ::auto-bibliography:: --># Bibliography\n\nSmith.\n\n<!-- ::auto-bibliography-end:: -->"
        #expect(
            MarkdownLeaderMap.recordText(fromRaw: raw) == "## Notes\n\n# Bibliography\n\nSmith.\n\n<!-- ::auto-bibliography-end:: -->")
    }

    // MARK: - The Duplicate request (t-4a8fd8af slice 3)

    /// The golden request file the page's own test (`web/codemirror/src/__tests__/structural-markdown-duplicate.test.ts`, WD21) runs too:
    /// one line of canonical JSON (sorted keys, compact, `managed` left out when nil).
    private static var requestGolden: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MarkdownEditorFirst/
            .deletingLastPathComponent()   // Tier2/
            .deletingLastPathComponent()   // final finalTests/
            .deletingLastPathComponent()   // the repository root
            .appendingPathComponent("docs/architecture/golden-requests/markdown-duplicate-request-golden.json")
    }

    /// The request `markdownStructuralDuplicate` takes, built through `MarkdownLeaderMap.duplicateRequest` from real UUID ids and
    /// compared, canonical (sorted keys, compact), with the shared golden file the page test reads. Both sides pin the same text, so a
    /// key, a value or a null that moves on one side fails the other's test. The document is the golden's: Chapter 1, Chapter 2 with
    /// Part 2.1, Chapter 3, then the Notes (the stop line and the managed leader). BREAK: in `DuplicateRequest.json` drop the
    /// `"copyIds"` entry. FAILS: "duplicate request JSON mismatch".
    @Test("the duplicate request JSON is the shared golden file, byte for byte")
    func testDuplicateRequestJSONIsPinned() throws {
        func heading(_ id: String, _ level: Int, _ title: String, at order: Double, notes: Bool = false) -> Block {
            Block(
                id: id, projectId: "project", sortOrder: order, blockType: .heading, textContent: title,
                markdownFragment: String(repeating: "#", count: level) + " " + title, headingLevel: level, isNotes: notes)
        }
        let chapter1 = "0B8C1E52-3D7A-4F6B-9A10-6C2E5D4F8A01"
        let chapter2 = "1C9D2F63-4E8B-4A7C-8B21-7D3F6E509B12"
        let part21 = "2DAE3074-5F9C-4B8D-9C32-8E4A7F61AC23"
        let chapter3 = "3EBF4185-60AD-4C9E-8D43-9F5B8072BD34"
        let notes = "4FC05296-71BE-4DAF-9E54-A06C9183CE45"
        let rows = [
            heading(chapter1, 1, "Chapter 1", at: 0), heading(chapter2, 1, "Chapter 2", at: 1), heading(part21, 2, "Part 2.1", at: 2),
            heading(chapter3, 1, "Chapter 3", at: 3), heading(notes, 2, "Notes", at: 4, notes: true)
        ]
        let map = MarkdownLeaderMap(rows: rows)
        let opId = try #require(UUID(uuidString: "5AD163A7-82CF-4EB0-8F65-B17DA294DF56"))
        let copyIds = [
            MarkdownLeaderMap.DuplicateCopyId(source: chapter2, new: "6BE274B8-93D0-4FC1-9076-C28EB3A5E067"),
            MarkdownLeaderMap.DuplicateCopyId(source: part21, new: "7CF385C9-A4E1-40D2-A187-D39FC4B6F178")
        ]
        let request = try #require(map.duplicateRequest(opId: opId, rootId: chapter2, copyIds: copyIds), "no duplicate request for a chapter")
        let text = try #require(request.json, "the request has no JSON")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let canonicalData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let canonical = try #require(String(data: canonicalData, encoding: .utf8), "the sorted JSON is not UTF-8")
        let golden = try String(contentsOf: Self.requestGolden, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(canonical == golden, "duplicate request JSON mismatch (the request built from the rows is not the shared golden file)")

        // The last chapter of a document without Notes: explicit nulls, as the Delete's request writes them.
        let plain = MarkdownLeaderMap(rows: Array(rows.prefix(4)))
        let lastCopyIds = [MarkdownLeaderMap.DuplicateCopyId(source: chapter3, new: "8D0496DA-B5F2-41E3-92B8-E40AD5C7A289")]
        let last = try #require(
            plain.duplicateRequest(opId: opId, rootId: chapter3, copyIds: lastCopyIds),
            "no duplicate request for the last chapter")
        let lastJSON = try #require(last.json, "the last chapter's request has no JSON")
        let lastParsed = try JSONSerialization.jsonObject(with: Data(lastJSON.utf8))
        let lastObject = try #require(lastParsed as? [String: Any], "the last chapter's JSON is no object")
        #expect(lastObject["stopLine"] is NSNull && lastObject["endLeaderId"] is NSNull, "duplicate request JSON mismatch: explicit nulls missing")
        #expect(
            Set(lastObject.keys) == ["kind", "opId", "rootId", "leaders", "stopLine", "endLeaderId", "copyIds"],
            "duplicate request JSON mismatch: keys")

        // Pairs that are not exactly the subtree's leaders, in order, make no request (the page would refuse it).
        #expect(map.duplicateRequest(opId: opId, rootId: chapter2, copyIds: [copyIds[0]]) == nil, "a request was built with a missing pair")
        #expect(map.duplicateRequest(opId: opId, rootId: notes, copyIds: []) == nil, "a request was built for the Notes heading")
    }
}

// MARK: - The Restore request (t-4a8fd8af slice 4)

extension MarkdownLeaderMapTests {

    /// The golden request file of the Version History restores: the page's own test (WR17, `structural-markdown-restore.test.ts`) runs it
    /// too. The file is the shared contract: never move or edit it from either side.
    private static var restoreRequestGolden: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MarkdownEditorFirst/
            .deletingLastPathComponent()   // Tier2/
            .deletingLastPathComponent()   // final finalTests/
            .deletingLastPathComponent()   // the repository root
            .appendingPathComponent("docs/architecture/golden-requests/markdown-restore-request-golden.json")
    }

    private func canonicalJSON(_ text: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return try #require(String(data: data, encoding: .utf8), "the sorted JSON is not UTF-8")
    }

    /// The request `markdownStructuralRestore` takes, built through `MarkdownLeaderMap.restoreRequest` from real UUID ids and compared,
    /// canonical (sorted keys, compact), with the shared golden file the page test reads. The document is the golden's: Chapter 1,
    /// Chapter 2 with Part 2.1, Chapter 3, then the Notes (the stop line and the managed leader); the mode is `section` on Chapter 2.
    /// BREAK: in `RestoreRequest.json` rename the `"rootId"` key.   FAILS: "restore request JSON mismatch".
    @Test("the restore request JSON is the shared golden file, byte for byte")
    func testRestoreRequestJSONIsPinned() throws {
        func heading(_ id: String, _ level: Int, _ title: String, at order: Double, notes: Bool = false) -> Block {
            Block(
                id: id, projectId: "project", sortOrder: order, blockType: .heading, textContent: title,
                markdownFragment: String(repeating: "#", count: level) + " " + title, headingLevel: level, isNotes: notes)
        }
        let chapter1 = "0B8C1E52-3D7A-4F6B-9A10-6C2E5D4F8A01"
        let chapter2 = "1C9D2F63-4E8B-4A7C-8B21-7D3F6E509B12"
        let part21 = "2DAE3074-5F9C-4B8D-9C32-8E4A7F61AC23"
        let chapter3 = "3EBF4185-60AD-4C9E-8D43-9F5B8072BD34"
        let notes = "4FC05296-71BE-4DAF-9E54-A06C9183CE45"
        let rows = [
            heading(chapter1, 1, "Chapter 1", at: 0), heading(chapter2, 1, "Chapter 2", at: 1), heading(part21, 2, "Part 2.1", at: 2),
            heading(chapter3, 1, "Chapter 3", at: 3), heading(notes, 2, "Notes", at: 4, notes: true)
        ]
        let map = MarkdownLeaderMap(rows: rows)
        let opId = try #require(UUID(uuidString: "5AD163A7-82CF-4EB0-8F65-B17DA294DF56"))
        let text = "<!-- @sid:\(chapter2) --># Chapter 2\n\nRestored body of Chapter 2."
        let request = try #require(
            map.restoreRequest(opId: opId, mode: .section, rootId: chapter2, text: text), "no restore request for a chapter")
        let json = try #require(request.json, "the request has no JSON")
        let golden = try String(contentsOf: Self.restoreRequestGolden, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try canonicalJSON(json) == golden, "restore request JSON mismatch (the request built from the rows is not the shared golden file)")

        // A whole restore: the root and the stop line are explicit nulls whatever is passed, the mode says so, no leader check is asked for.
        let whole = try #require(
            map.restoreRequest(opId: opId, mode: .whole, rootId: chapter2, text: "Whole text."), "no request for a whole restore")
        let wholeJSON = try #require(whole.json, "the whole request has no JSON")
        let wholeObject = try #require(try JSONSerialization.jsonObject(with: Data(wholeJSON.utf8)) as? [String: Any], "no JSON object")
        #expect(
            Set(wholeObject.keys) == ["kind", "opId", "mode", "rootId", "leaders", "stopLine", "endLeaderId", "text"],
            "restore request JSON mismatch: keys")
        #expect(
            wholeObject["mode"] as? String == "whole" && wholeObject["kind"] as? String == "restore",
            "restore request JSON mismatch: kind or mode")
        #expect(
            wholeObject["rootId"] is NSNull && wholeObject["stopLine"] is NSNull && wholeObject["endLeaderId"] is NSNull,
            "restore request JSON mismatch: explicit nulls missing for a whole restore")

        // An Insert as New Section: the anchor leader is the root; with none, the root is null and the stop line is the first Notes line.
        let after = try #require(map.restoreRequest(opId: opId, mode: .insertAfter, rootId: chapter3, text: "New."), "no request after Chapter 3")
        let afterJSON = try #require(after.json, "the insertAfter request has no JSON")
        let afterObject = try #require(try JSONSerialization.jsonObject(with: Data(afterJSON.utf8)) as? [String: Any], "no JSON object")
        #expect(afterObject["rootId"] as? String == chapter3 && afterObject["stopLine"] as? String == "## Notes", "insertAfter root or stop line")
        let noAnchor = try #require(map.restoreRequest(opId: opId, mode: .insertAfter, rootId: nil, text: "New."), "no request without an anchor")
        let noAnchorJSON = try #require(noAnchor.json, "the request without an anchor has no JSON")
        let noAnchorObject = try #require(try JSONSerialization.jsonObject(with: Data(noAnchorJSON.utf8)) as? [String: Any], "no JSON object")
        #expect(
            noAnchorObject["rootId"] is NSNull && noAnchorObject["stopLine"] as? String == "## Notes",
            "restore request JSON mismatch: an insert without an anchor takes the first Notes line as its stop line")

        // The last chapter of a document without Notes: explicit nulls, as the Delete's request writes them.
        let plain = MarkdownLeaderMap(rows: Array(rows.prefix(4)))
        let last = try #require(plain.restoreRequest(opId: opId, mode: .section, rootId: chapter3, text: "Last."), "no request for the last chapter")
        let lastJSON = try #require(last.json, "the last chapter's request has no JSON")
        let lastObject = try #require(try JSONSerialization.jsonObject(with: Data(lastJSON.utf8)) as? [String: Any], "no JSON object")
        #expect(lastObject["stopLine"] is NSNull && lastObject["endLeaderId"] is NSNull, "restore request JSON mismatch: explicit nulls missing")

        // A root that is no leader of these rows, a section restore with no root, and a root that is the Notes heading make no request
        // (the page would refuse each of them).
        #expect(
            map.restoreRequest(opId: opId, mode: .section, rootId: "no-such-heading", text: "x") == nil,
            "a request was built for an unknown root")
        #expect(map.restoreRequest(opId: opId, mode: .section, rootId: nil, text: "x") == nil, "a section request was built without a root")
        #expect(map.restoreRequest(opId: opId, mode: .section, rootId: notes, text: "x") == nil, "a request was built for the Notes heading")
        #expect(map.restoreRequest(opId: opId, mode: .insertAfter, rootId: notes, text: "x") == nil, "an insert was anchored on the Notes heading")
    }
}
