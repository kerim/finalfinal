//
//  RestorePrimitivesTests.swift
//  final finalTests
//
//  Tier 1 (t-18b7fa48 Phase 4b, slice 2, round 2b): the groundwork the editor-first Version History restores stand on, tested before
//  any restore uses it. Four pieces:
//
//    U-S2-P1  the editor payload builder (`StructuralUndoController.editorPayload(for:)`) gives, for the rows the database holds, exactly
//             what `fetchFullBlocksWithIds` gave before the builder was factored out of it.
//    U-S2-P2  `ProjectDatabase.replaceProjectRows(db:projectId:rows:)` writes the rows it is given and moves NO write epoch and NO
//             surviving row's stamp (the existing whole-document body `replaceBlocks(db:)` bumps the epoch and restamps every row, which
//             would make the writer refuse, whole, an editor batch the user typed while the restore was queued).
//    U-S2-P3  `ProjectDatabase.flatSectionBlockIds(db:headingId:projectId:)`: a section's FLAT range, the heading and its own body up to
//             the next heading of any level, a section break, the first Notes / Bibliography row, or the end (not the delete rule's
//             subtree, which takes every deeper heading too).
//    U-S2-P4  the payload builder over rows that are not in the database (a restored section's fragment, with a loose list): one id per
//             top-level editor node, the same types the whole-document builder gives for the same rows.
//
//  Plus a DEBUG-only generator, `testWriteAlignmentFixtures`, that writes the three JSON files the web test V2-3 (round 2c) reads. It does
//  nothing unless `FF_WRITE_ALIGNMENT_FIXTURES=1` is in the test process's environment, so a normal run never touches a tracked file.
//
//  Document cases are built from explicit rows or from `ComplexDocumentFixture.parse` (which passes the bibliography and Notes names in),
//  so no case depends on the process-wide export settings.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@MainActor
@Suite("Restore primitives — Tier 1 (t-18b7fa48 slice 2, round 2b)")
struct RestorePrimitivesTests {

    // MARK: - Shared builders

    /// A fresh database holding exactly `blocks` (their `projectId` replaced by the fixture's own). Inserted directly, never through
    /// `replaceBlocks`: its heading-id carry-over could rename ids, and its restamp would hide the stamps the cases read.
    private func makeDatabase(_ blocks: [Block]) throws -> (db: ProjectDatabase, pid: String) {
        let db = try TestFixtureFactory.createTemporary(content: "# Seed")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        try db.dbWriter.write { database in
            try Block.filter(Block.Columns.projectId == pid).deleteAll(database)
            for var block in blocks {
                block.projectId = pid
                try block.insert(database)
            }
        }
        return (db, pid)
    }

    private static func heading(_ level: Int, _ text: String, at sort: Double, notes: Bool = false, bibliography: Bool = false) -> Block {
        Block(
            id: "id-\(text)", projectId: "p", sortOrder: sort, blockType: .heading,
            textContent: text, markdownFragment: String(repeating: "#", count: level) + " " + text, headingLevel: level,
            isBibliography: bibliography, isNotes: notes
        )
    }

    private static func paragraph(_ text: String, at sort: Double, notes: Bool = false, bibliography: Bool = false) -> Block {
        Block(
            id: "id-\(text)", projectId: "p", sortOrder: sort, blockType: .paragraph,
            textContent: text, markdownFragment: text, isBibliography: bibliography, isNotes: notes
        )
    }

    private static func sectionBreak(_ text: String, at sort: Double) -> Block {
        Block(
            id: "id-\(text)", projectId: "p", sortOrder: sort, blockType: .sectionBreak,
            textContent: text, markdownFragment: "<!-- ::break:: -->", isPseudoSection: true
        )
    }

    private static func hr(_ text: String, at sort: Double) -> Block {
        Block(id: "id-\(text)", projectId: "p", sortOrder: sort, blockType: .horizontalRule, textContent: "", markdownFragment: "---")
    }

    /// The auto-bibliography opening marker row: its own `.bibliography` row, flagged as bibliography content.
    private static func bibliographyMarker(_ text: String, at sort: Double) -> Block {
        Block(
            id: "id-\(text)", projectId: "p", sortOrder: sort, blockType: .bibliography,
            textContent: "", markdownFragment: "<!-- ::auto-bibliography:: -->", isBibliography: true
        )
    }

    private func ids(_ names: String...) -> [String] { names.map { "id-\($0)" } }

    // MARK: - U-S2-P1: the factored-out builder equals the whole-document builder

    /// A payload as a list of short, comparable facts, so a mismatch names the first field that differs (the markdown of a book is
    /// 350,000 characters; it is never printed).
    private static func payloadProblem(_ lhs: ContentView.BlockFetchResult, _ rhs: ContentView.BlockFetchResult) -> String? {
        func imageFacts(_ payload: ContentView.BlockFetchResult) -> [String] {
            payload.imageMeta.map { "\($0.id)|\($0.width.map(String.init) ?? "-")|\($0.caption ?? "-")|\($0.alt ?? "-")|\($0.src ?? "-")" }
        }
        func typeFacts(_ payload: ContentView.BlockFetchResult) -> [String] {
            payload.expectedBlocks.map { "\($0.blockType)|\($0.nonEmpty)" }
        }
        if lhs.markdown != rhs.markdown { return "markdown differs (\(lhs.markdown.count) vs \(rhs.markdown.count) characters)" }
        if lhs.blockIds != rhs.blockIds { return "blockIds differ (\(lhs.blockIds.count) vs \(rhs.blockIds.count) ids)" }
        if typeFacts(lhs) != typeFacts(rhs) { return "expectedBlocks differ" }
        if imageFacts(lhs) != imageFacts(rhs) { return "imageMeta differs" }
        if lhs.bibBoundaryIndex != rhs.bibBoundaryIndex { return "bibBoundaryIndex differs" }
        if lhs.bibBoundaryEndIndex != rhs.bibBoundaryEndIndex { return "bibBoundaryEndIndex differs" }
        if lhs.managedBlockIds != rhs.managedBlockIds { return "managedBlockIds differ" }
        return nil
    }

    /// The body of `fetchFullBlocksWithIds` as it was BEFORE the builder was factored out of it (round 2b), kept here verbatim as the
    /// reference the refactor must not change: the same sort, the same assembly and the same alignment pairs, written out inline. It
    /// is the oracle for "the output is unchanged", which a comparison of the two live functions alone could not give (they share the
    /// new builder).
    private static func payloadBeforeTheRefactor(_ allBlocks: [Block]) -> ContentView.BlockFetchResult {
        let sorted = allBlocks.sorted { a, b in
            let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
            let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
            return aKey < bKey
        }
        let markdown = BlockParser.assembleMarkdownForEditor(from: sorted)
        let pairs = BlockParser.alignmentPairs(sorted)
        let imageMeta = sorted
            .filter { $0.blockType == .image }
            .map { ContentView.ImageBlockMeta(id: $0.id, width: $0.imageWidth, caption: $0.imageCaption, alt: $0.imageAlt, src: $0.imageSrc) }
        return ContentView.BlockFetchResult(
            markdown: markdown, blockIds: pairs.map { $0.id }, imageMeta: imageMeta,
            bibBoundaryIndex: BlockParser.firstBibliographyNodeIndex(sorted),
            bibBoundaryEndIndex: BlockParser.lastBibliographyNodeIndex(sorted),
            expectedBlocks: pairs.map { $0.meta },
            managedBlockIds: Set(sorted.filter { $0.isBibliography || $0.isNotes }.map { $0.id })
        )
    }

    @Test("U-S2-P1: fetchFullBlocksWithIds equals editorPayload(for: the table's rows), field by field", arguments: ["article", "book6"])
    func testFetchFullBlocksWithIdsEqualsEditorPayload(_ name: String) throws {
        let document = name == "article" ? ComplexDocumentFixture.article : ComplexDocumentFixture.book6
        let (db, pid) = try makeDatabase(ComplexDocumentFixture.parse(document.editorMarkdown))
        let rows = try db.fetchBlocks(projectId: pid)

        let whole = try #require(StructuralUndoController().fetchFullBlocksWithIds(db: db, pid: pid))
        let payload = StructuralUndoController.editorPayload(for: rows)
        #expect(Self.payloadProblem(whole, payload) == nil,
                "\(name): fetchFullBlocksWithIds and editorPayload(for:) differ: \(Self.payloadProblem(whole, payload) ?? "")")

        // Neither is changed by the refactor: both equal what the pre-refactor body computed for the same rows.
        let before = Self.payloadBeforeTheRefactor(rows)
        #expect(Self.payloadProblem(before, payload) == nil,
                "\(name): editorPayload(for:) differs from the pre-refactor algorithm: \(Self.payloadProblem(before, payload) ?? "")")

        // The builder puts the rows in assembly order itself: handed the same rows back to front, it gives the same payload.
        let reversed = StructuralUndoController.editorPayload(for: Array(rows.reversed()))
        #expect(Self.payloadProblem(whole, reversed) == nil,
                "\(name): editorPayload(for:) depends on the order of the rows: \(Self.payloadProblem(whole, reversed) ?? "")")

        // The comparison is not vacuous: the document has a bibliography and Notes, so every field carries something.
        #expect(payload.blockIds.count > 20 && payload.blockIds.count == payload.expectedBlocks.count,
                "\(name): \(payload.blockIds.count) ids, \(payload.expectedBlocks.count) expected entries")
        #expect(payload.bibBoundaryIndex != nil && payload.bibBoundaryEndIndex != nil, "\(name): no bibliography span")
        #expect(!payload.managedBlockIds.isEmpty, "\(name): no managed ids")
        #expect(payload.markdown.contains(BlockParser.bibliographyEndMarker), "\(name): no bibliography end marker")
    }

    // MARK: - U-S2-P2: replaceProjectRows moves no epoch and no surviving stamp

    private static let fourSectionsMarkdown = """
        # Chapter

        The chapter body.

        ## Section A

        The A body.

        ## Section B

        The B body.

        ## Section C

        The C body.
        """

    private func stamps(_ db: ProjectDatabase, _ ids: [String]) throws -> [String: BlockWriteStamp] {
        try db.read { database in
            var result: [String: BlockWriteStamp] = [:]
            for id in ids {
                if let stamp = try ProjectDatabase.storedStamp(db: database, blockId: id) { result[id] = stamp }
            }
            return result
        }
    }

    /// Every field of a row that a restore decides (not the dates, which SQLite stores to the millisecond, and not `sectionParentId`,
    /// which the primitive recomputes: the case asserts it separately). In document order.
    private struct RowShape: Equatable {
        let id: String
        let parentId: String?
        let sortOrder: Double
        let blockType: BlockType
        let textContent: String
        let markdownFragment: String
        let headingLevel: Int?
        let status: SectionStatus?
        let tags: [String]
        let wordGoal: Int?
        let wordCount: Int
        let flags: [Bool]
    }

    private static func shapes(_ rows: [Block]) -> [RowShape] {
        rows.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }.map {
            RowShape(
                id: $0.id, parentId: $0.parentId, sortOrder: $0.sortOrder, blockType: $0.blockType, textContent: $0.textContent,
                markdownFragment: $0.markdownFragment, headingLevel: $0.headingLevel, status: $0.status, tags: $0.tags ?? [],
                wordGoal: $0.wordGoal, wordCount: $0.wordCount, flags: [$0.isBibliography, $0.isNotes, $0.isPseudoSection]
            )
        }
    }

    @Test("U-S2-P2: replaceProjectRows writes the rows given and moves no write epoch and no surviving row's stamp")
    func testReplaceProjectRowsMovesNoEpochAndNoSurvivingStamp() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.fourSectionsMarkdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let epoch = try db.currentBlockWriteEpoch(projectId: pid)

        // Two editor batches at different sequences, so two rows carry a stamp other than the one the creation gave every row.
        let seeded = try db.fetchBlocks(projectId: pid)
        let bodyA = try #require(seeded.first { $0.textContent == "The A body." })
        let bodyB = try #require(seeded.first { $0.textContent == "The B body." })
        for (body, sequence) in [(bodyA, Int64(5)), (bodyB, Int64(9))] {
            let text = body.textContent + " typed"
            let typed = BlockChanges(updates: [BlockUpdate(id: body.id, textContent: text, markdownFragment: text, headingLevel: nil)])
            let applied = try db.applyBlockChangesFromEditor(typed, for: pid, stamp: BlockWriteStamp(epoch: epoch, sequence: sequence))
            #expect(applied.writtenUpdateIds == [body.id], "precondition: the seeding batch at sequence \(sequence) must be written")
        }

        let existing = try db.fetchBlocks(projectId: pid)
        let stampsBefore = try stamps(db, existing.map(\.id))
        #expect(stampsBefore[bodyA.id] == BlockWriteStamp(epoch: epoch, sequence: 5), "precondition: A's stamp is (\(epoch), 5)")
        #expect(stampsBefore[bodyB.id] == BlockWriteStamp(epoch: epoch, sequence: 9), "precondition: B's stamp is (\(epoch), 9)")

        // The rows to write: Section C and its body dropped, the chapter body's text replaced, Section A's parent link left stale
        // (nil: the primitive must recompute it), and one new row (a new id) after B's body.
        let chapterBody = try #require(existing.first { $0.textContent == "The chapter body." })
        let sectionA = try #require(existing.first { $0.textContent == "Section A" })
        let chapter = try #require(existing.first { $0.textContent == "Chapter" })
        let dropped = existing.filter { ["Section C", "The C body."].contains($0.textContent) }.map(\.id)
        #expect(dropped.count == 2, "precondition: Section C and its body are rows")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newRow = Block(
            id: "new-row", projectId: pid, sortOrder: bodyB.sortOrder + 0.5, blockType: .paragraph,
            textContent: "A brand-new row.", markdownFragment: "A brand-new row.", createdAt: fixedDate, updatedAt: fixedDate
        )
        var input: [Block] = []
        for var row in existing where !dropped.contains(row.id) {
            if row.id == chapterBody.id { row.textContent = "The chapter body, restored."; row.markdownFragment = "The chapter body, restored." }
            if row.id == sectionA.id { row.sectionParentId = nil }
            input.append(row)
            if row.id == bodyB.id { input.append(newRow) }
        }

        try db.write { database in
            try ProjectDatabase.replaceProjectRows(db: database, projectId: pid, rows: input)
        }

        let after = try db.fetchBlocks(projectId: pid)
        let epochAfter = try db.currentBlockWriteEpoch(projectId: pid)
        #expect(epochAfter == epoch, "replaceProjectRows moved the project's write epoch from \(epoch) to \(epochAfter)")

        let stampsAfter = try stamps(db, after.map(\.id))
        let moved = existing.map(\.id).filter { stampsAfter[$0] != nil && stampsAfter[$0] != stampsBefore[$0] }
        let firstMoved = moved.first.map { "\(String(describing: stampsBefore[$0])) -> \(String(describing: stampsAfter[$0]))" } ?? ""
        #expect(moved.isEmpty, "\(moved.count) surviving rows had their stamp changed, e.g. \(firstMoved)")
        #expect(stampsAfter["new-row"] == BlockWriteStamp(epoch: 0, sequence: 0), "a new row lands at the default stamp (0, 0)")

        #expect(Self.shapes(after) == Self.shapes(input), "the rows after the write are not the rows given")
        #expect(after.filter { dropped.contains($0.id) }.isEmpty, "a row that was not in the input is still in the table")
        let sectionAAfter = try #require(after.first { $0.id == sectionA.id })
        #expect(sectionAAfter.sectionParentId == chapter.id, "section parents were not recomputed (Section A's parent should be the chapter)")
    }

    // MARK: - U-S2-P3: the flat section range

    @Test("U-S2-P3: a level-1 heading's flat range is its own body only; its level-2 children are not in it")
    func testFlatSectionBlockIdsOfAnH1IsItsOwnBodyOnly() throws {
        let (db, pid) = try makeDatabase([
            Self.heading(1, "Ch", at: 1), Self.paragraph("ch body", at: 2),
            Self.heading(2, "A", at: 3), Self.paragraph("a body", at: 4),
            Self.heading(2, "B", at: 5), Self.paragraph("b body", at: 6),
            Self.heading(1, "Next", at: 7), Self.paragraph("next body", at: 8)
        ])
        func flat(_ name: String) throws -> [String]? {
            try db.read { try ProjectDatabase.flatSectionBlockIds(db: $0, headingId: "id-\(name)", projectId: pid) }
        }
        #expect(try flat("Ch") == ids("Ch", "ch body"), "the H1 took its H2 children")
        #expect(try flat("A") == ids("A", "a body"))
        #expect(try flat("B") == ids("B", "b body"), "B's range runs to the next heading, which here is a level-1 heading")
        #expect(try flat("Next") == ids("Next", "next body"), "the last section runs to the end of the document")
        // The two rules really differ on this document: the delete rule's subtree of the H1 holds the H2s, the flat range does not.
        #expect(try db.sectionBlockIds(rootId: "id-Ch", projectId: pid) == ids("Ch", "ch body", "A", "a body", "B", "b body"))
    }

    @Test("U-S2-P3: a section break ends a flat range, an hr does not, and a section break is a root of its own")
    func testFlatSectionBlockIdsStopsAtASectionBreakButNotAnHr() throws {
        let (db, pid) = try makeDatabase([
            Self.heading(2, "X", at: 1), Self.paragraph("x body", at: 2),
            Self.hr("rule", at: 3), Self.paragraph("after rule", at: 4),
            Self.sectionBreak("brk", at: 5), Self.paragraph("brk body", at: 6),
            Self.heading(2, "Y", at: 7), Self.paragraph("y body", at: 8)
        ])
        func flat(_ name: String) throws -> [String]? {
            try db.read { try ProjectDatabase.flatSectionBlockIds(db: $0, headingId: "id-\(name)", projectId: pid) }
        }
        #expect(try flat("X") == ids("X", "x body", "rule", "after rule"), "an hr stays inside the section; the break ends it")
        #expect(try flat("brk") == ids("brk", "brk body"), "a section break's own range runs to the next heading")
    }

    @Test("U-S2-P3: the first Notes or Bibliography row ends a flat range, and a managed row is never a root")
    func testFlatSectionBlockIdsStopsAtTheFirstManagedRow() throws {
        // A chapter, then the auto-bibliography marker row (not a heading), then the Bibliography heading and an entry.
        let (bibDb, bibPid) = try makeDatabase([
            Self.heading(1, "Ch", at: 1), Self.paragraph("ch body", at: 2),
            Self.bibliographyMarker("marker", at: 3),
            Self.heading(1, "Bibliography", at: 4, bibliography: true), Self.paragraph("an entry", at: 5, bibliography: true)
        ])
        func flatBib(_ name: String) throws -> [String]? {
            try bibDb.read { try ProjectDatabase.flatSectionBlockIds(db: $0, headingId: "id-\(name)", projectId: bibPid) }
        }
        #expect(try flatBib("Ch") == ids("Ch", "ch body"), "the range ran into the bibliography marker row")
        #expect(try flatBib("Bibliography") == nil, "a Bibliography heading is not a restorable root")
        #expect(try flatBib("ch body") == nil, "a paragraph is not a root")
        #expect(try flatBib("no such row") == nil, "an unknown id is not a root")

        // A chapter followed by footnote-definition rows that are Notes content but come with no Notes heading row in between.
        let (notesDb, notesPid) = try makeDatabase([
            Self.heading(1, "Ch", at: 1), Self.paragraph("ch body", at: 2),
            Self.paragraph("[^1]: the footnote", at: 3, notes: true),
            Self.heading(1, "Notes", at: 4, notes: true), Self.paragraph("[^2]: another", at: 5, notes: true)
        ])
        func flatNotes(_ name: String) throws -> [String]? {
            try notesDb.read { try ProjectDatabase.flatSectionBlockIds(db: $0, headingId: "id-\(name)", projectId: notesPid) }
        }
        #expect(try flatNotes("Ch") == ids("Ch", "ch body"), "the range ran into a Notes row")
        #expect(try flatNotes("Notes") == nil, "a Notes heading is not a restorable root")
    }

    // MARK: - U-S2-P4: the payload for rows that are not in the database (a section fragment with a loose list)

    /// A restored section's fragment: a heading, a paragraph, a bullet list and an ordered list each written loose (a blank line
    /// between items, so the parser makes one row per item), a figure and a closing paragraph.
    private static let looseListSectionMarkdown = """
        ## Loose list section

        Before the lists.

        - first item

        - second item

        - third item

        1. step one

        2. step two

        ![A figure](media/figure.png)

        After the figure.
        """

    private static func parseFragment(_ markdown: String, projectId: String) -> [Block] {
        BlockParser.parse(
            markdown: markdown, projectId: projectId, bibliographyHeaderName: "Bibliography", graceNames: [], notesHeaderName: "Notes")
    }

    @Test("U-S2-P4: editorPayload(for: a fragment with loose lists) has one id per top-level node and the whole-document builder's types")
    func testEditorPayloadOfAFragmentWithLooseListsHasOnePairPerNode() throws {
        let rows = Self.parseFragment(Self.looseListSectionMarkdown, projectId: "fragment")
        // Hand count of the fragment: the heading, the paragraph, the bullet list (three items, ONE editor node), the ordered list (two
        // items, one node), the figure and the closing paragraph are SIX top-level nodes, written as nine rows.
        #expect(rows.count == 9, "precondition: the parser writes one row per loose list item, \(rows.count) rows")
        #expect(rows.filter { $0.blockType == .bulletList }.count == 3 && rows.filter { $0.blockType == .orderedList }.count == 2)

        let payload = StructuralUndoController.editorPayload(for: rows)
        #expect(payload.blockIds.count == 6, "one id per top-level node, saw \(payload.blockIds.count)")
        #expect(payload.expectedBlocks.map(\.blockType) == ["heading", "paragraph", "bullet_list", "ordered_list", "image", "paragraph"],
                "types: \(payload.expectedBlocks.map(\.blockType))")
        // The id of a merged list node is the id of its FIRST row.
        #expect(payload.blockIds == [rows[0].id, rows[1].id, rows[2].id, rows[5].id, rows[7].id, rows[8].id],
                "a list node must carry the id of its first item")
        #expect(payload.markdown.contains("- first item\n\n- second item\n\n- third item\n\n1. step one\n\n2. step two"),
                "the markdown the editor parses must keep the lists loose")
        #expect(payload.imageMeta.map(\.src) == ["media/figure.png"] && payload.imageMeta.map(\.id) == [rows[7].id])
        #expect(payload.bibBoundaryIndex == nil && payload.managedBlockIds.isEmpty, "a plain section fragment has no managed content")

        // The same rows in a table, read by the whole-document builder: the same markdown, node count and types.
        let (db, pid) = try makeDatabase(rows)
        let whole = try #require(StructuralUndoController().fetchFullBlocksWithIds(db: db, pid: pid))
        let problem = Self.payloadProblem(whole, payload)
        #expect(problem == nil, "the fragment builder and the whole-document builder differ: \(problem ?? "")")
    }

}

// MARK: - U-S2-P5: the db-level forms of the snapshot-restore writes share one transaction

extension RestorePrimitivesTests {

    private struct RollBack: Error {}

    @Test("U-S2-P5: saveContent, deleteAllSections and insertSection take a Database, and commit or roll back together")
    func testSnapshotRestoreWritesShareOneTransaction() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Original\n\nOriginal body.")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        try db.insertSection(Section(projectId: pid, sortOrder: 0, headerLevel: 1, title: "Old", markdownContent: "# Old"))
        let contentBefore = try #require(try db.fetchContent(for: pid)).markdown
        let titlesBefore = try db.fetchSections(projectId: pid).map(\.title)
        #expect(titlesBefore.contains("Old"), "precondition: the instance form inserted its section")
        let restored = Section(projectId: pid, sortOrder: 0, headerLevel: 1, title: "Restored", markdownContent: "# Restored")
        func restoreWrites(_ database: Database) throws {
            try ProjectDatabase.saveContent(db: database, markdown: "# Restored\n\nRestored body.", projectId: pid)
            try ProjectDatabase.deleteAllSections(db: database, projectId: pid)
            try ProjectDatabase.insertSection(db: database, restored)
        }

        // A failure after the three writes undoes all three: the old content and the old sections are still there.
        #expect(throws: RollBack.self) {
            try db.write { database in
                try restoreWrites(database)
                throw RollBack()
            }
        }
        #expect(try db.fetchContent(for: pid)?.markdown == contentBefore, "the content changed although the transaction rolled back")
        #expect(try db.fetchSections(projectId: pid).map(\.title) == titlesBefore, "the sections changed although the transaction rolled back")

        // Without the failure all three land: the new content, and ONLY the new section.
        try db.write { database in try restoreWrites(database) }
        #expect(try db.fetchContent(for: pid)?.markdown == "# Restored\n\nRestored body.")
        #expect(try db.fetchSections(projectId: pid).map(\.title) == ["Restored"], "deleteAllSections(db:) left a section behind")
    }
}

// MARK: - The alignment fixtures for the web test V2-3 (DEBUG only; writes nothing unless asked)

#if DEBUG

/// One image entry of a fixture file (`BlockFetchResult.imageMeta`'s shape).
private struct AlignmentFixtureImage: Encodable {
    let id: String
    let width: Int?
    let caption: String?
    let alt: String?
    let src: String?
}

/// One fixture file: the payload `editorPayload(for:)` builds for a document, with the keys named like `BlockFetchResult`'s properties.
private struct AlignmentFixtureFile: Encodable {
    let about: String
    let name: String
    let markdown: String
    let blockIds: [String]
    let expectedBlocks: [BlockParser.BlockAlignmentMeta]
    let imageMeta: [AlignmentFixtureImage]
    let bibBoundaryIndex: Int?
    let bibBoundaryEndIndex: Int?
    let managedBlockIds: [String]
}

extension RestorePrimitivesTests {

    /// Set to `1` in the TEST PROCESS's environment (xcodebuild: `TEST_RUNNER_FF_WRITE_ALIGNMENT_FIXTURES=1`) to write the fixtures.
    private static let writeFixturesVariable = "FF_WRITE_ALIGNMENT_FIXTURES"

    /// The rows with ids `blk-0001`, `blk-0002`, ... (and `parentId` mapped the same way), so that writing the fixtures twice gives
    /// the same bytes: a fixture whose ids changed on every regeneration would show as a full-file diff each time.
    private static func withStableIds(_ rows: [Block]) -> [Block] {
        var map: [String: String] = [:]
        for (index, row) in rows.enumerated() { map[row.id] = String(format: "blk-%04d", index + 1) }
        return rows.map { row in
            var stable = row
            stable.id = map[row.id] ?? row.id
            stable.parentId = row.parentId.flatMap { map[$0] }
            return stable
        }
    }

    private static func fixtureFile(name: String, rows: [Block]) -> AlignmentFixtureFile {
        let payload = StructuralUndoController.editorPayload(for: withStableIds(rows))
        return AlignmentFixtureFile(
            about: "Written by RestorePrimitivesTests.testWriteAlignmentFixtures from StructuralUndoController.editorPayload(for:) "
                + "(the payload a restore sends the editor); read by restore-payload-alignment.test.ts (V2-3). Regenerate by hand: run "
                + "that one test with TEST_RUNNER_\(writeFixturesVariable)=1 in the environment, then commit the files.",
            name: name, markdown: payload.markdown, blockIds: payload.blockIds, expectedBlocks: payload.expectedBlocks,
            imageMeta: payload.imageMeta.map {
                AlignmentFixtureImage(id: $0.id, width: $0.width, caption: $0.caption, alt: $0.alt, src: $0.src)
            },
            bibBoundaryIndex: payload.bibBoundaryIndex, bibBoundaryEndIndex: payload.bibBoundaryEndIndex,
            managedBlockIds: payload.managedBlockIds.sorted()
        )
    }

    /// The three documents whose payloads are the fixtures (shared by the generator and the drift check).
    private static var fixtureDocuments: [(name: String, rows: [Block])] {
        [
            ("article", ComplexDocumentFixture.parse(ComplexDocumentFixture.article.editorMarkdown)),
            ("book6", ComplexDocumentFixture.parse(ComplexDocumentFixture.book6.editorMarkdown)),
            ("looseListSection", Self.parseFragment(Self.looseListSectionMarkdown, projectId: "alignment-fixture"))
        ]
    }

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tier1
            .deletingLastPathComponent()   // final finalTests
            .deletingLastPathComponent()   // the repository (or worktree) root
            .appendingPathComponent("web/milkdown/src/__tests__/fixtures", isDirectory: true)
    }

    /// Writes `alignment-article.json`, `alignment-book6.json` and `alignment-looseListSection.json` into
    /// `web/milkdown/src/__tests__/fixtures/`, only when `FF_WRITE_ALIGNMENT_FIXTURES=1` is set. Without it the test returns at once:
    /// it neither reads nor writes any file, so a normal suite run cannot rewrite a tracked file and cannot fail because the files
    /// exist. With it, the files are written (replaced when the content differs, left alone when the same), which is the point: this is a
    /// generator that a person runs by hand, like `FixtureGeneratorTests`.
    @Test("testWriteAlignmentFixtures: writes the V2-3 fixtures when FF_WRITE_ALIGNMENT_FIXTURES=1 (a no-op otherwise)")
    func testWriteAlignmentFixtures() throws {
        guard ProcessInfo.processInfo.environment[Self.writeFixturesVariable] == "1" else { return }

        let documents = Self.fixtureDocuments
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: Self.fixtureDirectory, withIntermediateDirectories: true)

        var report: [String] = []
        for document in documents {
            let file = Self.fixtureFile(name: document.name, rows: document.rows)
            let data = try encoder.encode(file) + Data("\n".utf8)
            let url = Self.fixtureDirectory.appendingPathComponent("alignment-\(document.name).json")
            let unchanged = (try? Data(contentsOf: url)) == data
            if !unchanged { try data.write(to: url, options: .atomic) }
            let outcome = unchanged ? "unchanged" : "written"
            report.append("[ALIGNMENT-FIXTURES] \(url.lastPathComponent): \(file.blockIds.count) ids, \(data.count) bytes, \(outcome)")
            #expect(file.blockIds.count == file.expectedBlocks.count, "\(document.name): ids and expected entries differ in number")
        }
        UnitOutputFile.emit("alignment-fixtures", report)
    }

    /// The part of a committed fixture file the drift check compares (everything but the `about` text and the image list).
    private struct CommittedAlignmentFixture: Decodable {
        let markdown: String
        let blockIds: [String]
        let expectedBlocks: [BlockParser.BlockAlignmentMeta]
        let bibBoundaryIndex: Int?
        let bibBoundaryEndIndex: Int?
        let managedBlockIds: [String]
    }

    /// Fix round F1, review C8: the web test V2-3 reads the COMMITTED `alignment-*.json`, which only a person regenerates, so a change to
    /// `BlockParser` or to `editorPayload(for:)` would leave V2-3 checking yesterday's payload while Swift sends today's. This compares
    /// today's payloads (rebuilt in memory exactly as the generator builds them) with the committed files. READ-ONLY: it writes nothing,
    /// whatever the environment says. On a failure, regenerate by running `testWriteAlignmentFixtures` with
    /// `TEST_RUNNER_FF_WRITE_ALIGNMENT_FIXTURES=1` and commit the files.
    @Test("The committed alignment fixtures are today's payloads (read-only drift check)")
    func testCommittedAlignmentFixturesMatchTodaysPayloads() throws {
        for document in Self.fixtureDocuments {
            let url = Self.fixtureDirectory.appendingPathComponent("alignment-\(document.name).json")
            let data = try #require(try? Data(contentsOf: url), "the committed fixture \(url.lastPathComponent) is missing")
            let committed = try JSONDecoder().decode(CommittedAlignmentFixture.self, from: data)
            let today = Self.fixtureFile(name: document.name, rows: document.rows)
            let hint = "regenerate with TEST_RUNNER_\(Self.writeFixturesVariable)=1 (\(document.name))"
            #expect(committed.markdown == today.markdown, "the fixture's Markdown is not today's payload: \(hint)")
            #expect(committed.blockIds == today.blockIds, "the fixture's ids are not today's payload: \(hint)")
            let committedBlocks = committed.expectedBlocks.map { [$0.blockType, String($0.nonEmpty)] }
            let todaysBlocks = today.expectedBlocks.map { [$0.blockType, String($0.nonEmpty)] }
            #expect(committedBlocks == todaysBlocks, "the fixture's expected blocks are not today's payload: \(hint)")
            #expect(committed.bibBoundaryIndex == today.bibBoundaryIndex, "the fixture's bibliography boundary start drifted: \(hint)")
            #expect(committed.bibBoundaryEndIndex == today.bibBoundaryEndIndex, "the fixture's bibliography boundary end drifted: \(hint)")
            #expect(committed.managedBlockIds == today.managedBlockIds, "the fixture's managed ids are not today's payload: \(hint)")
        }
    }
}

#endif
