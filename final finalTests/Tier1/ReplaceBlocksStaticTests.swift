//
//  ReplaceBlocksStaticTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1a, U9 (judge adjustment B4): REGRESSION PINS for the whole-document
//  and ranged block replace, written against the PRE-extraction instance methods
//  (`ProjectDatabase.replaceBlocks(_:for:preservingMachineManagedBlocks:)`,
//  `replaceBlocksInRange(_:for:startSortOrder:endSortOrder:anchorHeadingId:)` and the
//  instance `fetchNotesHeadingTitle(projectId:)`) so they pass on the UNMODIFIED base.
//
//  Every case seeds hand-built rows with explicit ids and asserts EXPLICIT expected rows
//  (id, sortOrder, type, text, metadata, isNotes/isBibliography, section parent link,
//  lastWriteEpoch/lastWriteSequence) plus `project.blockWriteEpoch == before + 1`. The
//  expectations were derived by reading the code (Database+BlocksReplace.swift and its
//  Preservation/RowOps helpers, Database+BlockWriteStamp.swift's
//  `stampWholeProjectForRewrite`, Database+BlockParents.swift's `recomputeSectionParents`):
//    - the epoch moves E -> E+1 inside the replace's own transaction, and EVERY row of the
//      project (including rows outside a ranged replace) is restamped to (E+1, 0);
//    - the default path inserts the incoming blocks with their own sortOrder; the
//      preserving path and the ranged path renumber the whole project to 1...N.
//
//  STATIC-PATH CALLS (added with the extraction, judge adjustment B4): every case is
//  parameterised over `ReplaceBlocksApiPath`. `.instance` drives the public instance method, exactly as
//  before the extraction. `.staticInTransaction` drives the extracted db-level static
//  (`ProjectDatabase.replaceBlocks(db:...)`, `replaceBlocksInRange(db:...)`,
//  `fetchNotesHeadingTitle(db:...)`) inside a plain `dbWriter.write` / `dbWriter.read`, against
//  the SAME explicit expected rows and epoch. The regression guard is those explicit
//  expectations, which were written against and passed on the unmodified base. That the two
//  paths agree is only an API-shape check: after the extraction the instance method IS
//  `write { Self.replaceBlocks(db:...) }`, so comparing instance to static is new code against
//  new code and proves nothing about behaviour preservation by itself.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// Which API shape a case drives (see the header comment).
enum ReplaceBlocksApiPath: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// The public instance method (`replaceBlocks(_:for:...)` etc.): `write { Self.<static> }`.
    case instance
    /// The extracted db-level static, called inside a plain `dbWriter.write` / `dbWriter.read`
    /// -- the way `LifecycleWholeDocumentWrite.body` runs it inside a writer transaction.
    case staticInTransaction

    var testDescription: String { rawValue }
}

@Suite("replaceBlocks / replaceBlocksInRange / fetchNotesHeadingTitle — instance and static paths (Tier 1)", .serialized)
struct ReplaceBlocksStaticTests {

    // MARK: - Snapshot helpers

    /// Every persisted field a replace can touch, plus the raw write stamp (which `Block`
    /// deliberately does not carry -- see Database+BlockWriteStamp.swift).
    fileprivate struct RowSnapshot: Equatable {
        var id: String
        var sortOrder: Double
        var blockType: BlockType
        var textContent: String
        var markdownFragment: String
        var headingLevel: Int?
        var parentId: String?
        var sectionParentId: String?
        var status: SectionStatus?
        var tags: [String]?
        var wordGoal: Int?
        var goalType: GoalType
        var aggregateGoal: Int?
        var aggregateGoalType: GoalType
        var isNotes: Bool
        var isBibliography: Bool
        var isPseudoSection: Bool
        var lastWriteEpoch: Int64
        var lastWriteSequence: Int64
    }

    private func snapshots(_ db: ProjectDatabase, _ pid: String) throws -> [RowSnapshot] {
        try db.read { database in
            let blocks = try Block
                .filter(Block.Columns.projectId == pid)
                .order(Block.Columns.sortOrder)
                .fetchAll(database)
            let stampRows = try Row.fetchAll(
                database,
                sql: "SELECT id, lastWriteEpoch, lastWriteSequence FROM block WHERE projectId = ?",
                arguments: [pid])
            var stamps: [String: (epoch: Int64, sequence: Int64)] = [:]
            for row in stampRows {
                let rowId: String = row["id"]
                let epoch: Int64 = row["lastWriteEpoch"]
                let sequence: Int64 = row["lastWriteSequence"]
                stamps[rowId] = (epoch, sequence)
            }
            return blocks.map { block in
                RowSnapshot(
                    id: block.id,
                    sortOrder: block.sortOrder,
                    blockType: block.blockType,
                    textContent: block.textContent,
                    markdownFragment: block.markdownFragment,
                    headingLevel: block.headingLevel,
                    parentId: block.parentId,
                    sectionParentId: block.sectionParentId,
                    status: block.status,
                    tags: block.tags,
                    wordGoal: block.wordGoal,
                    goalType: block.goalType,
                    aggregateGoal: block.aggregateGoal,
                    aggregateGoalType: block.aggregateGoalType,
                    isNotes: block.isNotes,
                    isBibliography: block.isBibliography,
                    isPseudoSection: block.isPseudoSection,
                    lastWriteEpoch: stamps[block.id]?.epoch ?? -99,
                    lastWriteSequence: stamps[block.id]?.sequence ?? -99)
            }
        }
    }

    /// Expected-row builder. `fragment` defaults to `text`; everything not named is the
    /// `Block.init` default (no status/tags/goals, `.approx` goal types, no flags).
    private func expected(
        _ id: String, _ sortOrder: Double, _ type: BlockType, _ text: String,
        fragment: String? = nil, level: Int? = nil, sectionParent: String? = nil,
        status: SectionStatus? = nil, tags: [String]? = nil, wordGoal: Int? = nil,
        goalType: GoalType = .approx, aggregateGoal: Int? = nil,
        aggregateGoalType: GoalType = .approx,
        isNotes: Bool = false, isBibliography: Bool = false, epoch: Int64
    ) -> RowSnapshot {
        RowSnapshot(
            id: id, sortOrder: sortOrder, blockType: type, textContent: text,
            markdownFragment: fragment ?? text, headingLevel: level, parentId: nil,
            sectionParentId: sectionParent, status: status, tags: tags, wordGoal: wordGoal,
            goalType: goalType, aggregateGoal: aggregateGoal, aggregateGoalType: aggregateGoalType,
            isNotes: isNotes, isBibliography: isBibliography, isPseudoSection: false,
            lastWriteEpoch: epoch, lastWriteSequence: 0)
    }

    // Each test seeds its own project inline: it creates a temporary fixture, clears the fixture's
    // blocks and inserts hand-built rows with explicit ids directly (they start at the default (0, 0)
    // stamp, which each test then replaces with a NONZERO one -- see `seedNonzeroStamps`), then reads
    // the project's epoch BEFORE the replace under test.

    // MARK: - (i) Plain document, default path

    @Test("""
        replaceBlocks (default path): a plain document keeps each same-titled heading's id and metadata, inserts the \
        incoming rows at their own sortOrder, restamps every row to (E+1, 0), bumps the epoch by exactly 1 and \
        recomputes section parents
        """, arguments: ReplaceBlocksApiPath.allCases)
    func plainDocumentDefaultPath(path: ReplaceBlocksApiPath) throws {
        let probe = try TestFixtureFactory.createTemporary(content: "# Seed\n\nSeed body.\n")
        let pid = try TestFixtureFactory.getProjectId(from: probe)

        let existing = [
            Block(id: "u9-i-alpha", projectId: pid, sortOrder: 0, blockType: .heading,
                  textContent: "Alpha", markdownFragment: "# Alpha", headingLevel: 1,
                  status: .writing, tags: ["a"], wordGoal: 500, goalType: .min,
                  aggregateGoal: 900, aggregateGoalType: .max),
            Block(id: "u9-i-old-p1", projectId: pid, sortOrder: 1, blockType: .paragraph,
                  textContent: "old alpha body", markdownFragment: "old alpha body"),
            Block(id: "u9-i-beta", projectId: pid, sortOrder: 2, blockType: .heading,
                  textContent: "Beta", markdownFragment: "## Beta", headingLevel: 2, status: .final_)
        ]
        try probe.write { database in
            try Block.filter(Block.Columns.projectId == pid).deleteAll(database)
            for var row in existing {
                try row.insert(database)
            }
        }
        let db = probe
        let epochBefore = try db.currentBlockWriteEpoch(projectId: pid)
        let seeded = try seedNonzeroStamps(db, pid, ids: existing.map(\.id), epoch: epochBefore, base: 7)

        let incoming = [
            Block(id: "u9-i-new-alpha", projectId: pid, sortOrder: 0, blockType: .heading,
                  textContent: "Alpha", markdownFragment: "# Alpha", headingLevel: 1),
            Block(id: "u9-i-new-p1", projectId: pid, sortOrder: 1, blockType: .paragraph,
                  textContent: "new alpha body", markdownFragment: "new alpha body"),
            Block(id: "u9-i-new-beta", projectId: pid, sortOrder: 2, blockType: .heading,
                  textContent: "Beta", markdownFragment: "## Beta", headingLevel: 2),
            Block(id: "u9-i-new-p2", projectId: pid, sortOrder: 3, blockType: .paragraph,
                  textContent: "new beta body", markdownFragment: "new beta body"),
            Block(id: "u9-i-new-gamma", projectId: pid, sortOrder: 4, blockType: .heading,
                  textContent: "Gamma", markdownFragment: "## Gamma", headingLevel: 2)
        ]
        try replace(db, path, incoming, pid: pid)

        let epochAfter = try db.currentBlockWriteEpoch(projectId: pid)
        #expect(epochAfter == epochBefore + 1, "replaceBlocks bumps the project epoch exactly once, in its own transaction")

        // Alpha and Beta pop their title queue: id + status/tags/goals come from the OLD row,
        // text/level from the incoming one. Gamma has no old occurrence, so it keeps its own
        // id and default metadata. sectionParentId: Beta and Gamma (level 2) hang off Alpha.
        let expectedRows = [
            expected("u9-i-alpha", 0, .heading, "Alpha", fragment: "# Alpha", level: 1,
                     status: .writing, tags: ["a"], wordGoal: 500, goalType: .min,
                     aggregateGoal: 900, aggregateGoalType: .max, epoch: epochAfter),
            expected("u9-i-new-p1", 1, .paragraph, "new alpha body", epoch: epochAfter),
            expected("u9-i-beta", 2, .heading, "Beta", fragment: "## Beta", level: 2,
                     sectionParent: "u9-i-alpha", status: .final_, epoch: epochAfter),
            expected("u9-i-new-p2", 3, .paragraph, "new beta body", epoch: epochAfter),
            expected("u9-i-new-gamma", 4, .heading, "Gamma", fragment: "## Gamma", level: 2,
                     sectionParent: "u9-i-alpha", epoch: epochAfter)
        ]
        let actualRows = try snapshots(db, pid)
        #expect(actualRows == expectedRows)
        expectRestamped(actualRows, seeded: seeded, epoch: epochAfter)
    }

    // MARK: - (ii) Bibliography + Notes, preserving path

    @Test("""
        replaceBlocks(preservingMachineManagedBlocks: true): the Notes and Bibliography sections survive, the same-label \
        Notes definition is merged in place (its row keeps its id), preserved rows are re-anchored after the new content, \
        sortOrders are renumbered 1...N, every row is restamped to (E+1, 0) and the epoch moves by exactly 1
        """, arguments: ReplaceBlocksApiPath.allCases)
    func bibliographyAndNotesPreservingPath(path: ReplaceBlocksApiPath) throws {
        let probe = try TestFixtureFactory.createTemporary(content: "# Seed\n\nSeed body.\n")
        let pid = try TestFixtureFactory.getProjectId(from: probe)

        let existing = [
            Block(id: "u9-ii-intro", projectId: pid, sortOrder: 0, blockType: .heading,
                  textContent: "Intro", markdownFragment: "# Intro", headingLevel: 1,
                  status: .review, tags: ["t1"], wordGoal: 300),
            Block(id: "u9-ii-body", projectId: pid, sortOrder: 1, blockType: .paragraph,
                  textContent: "Old body.", markdownFragment: "Old body."),
            Block(id: "u9-ii-notes-h", projectId: pid, sortOrder: 2, blockType: .heading,
                  textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1, isNotes: true),
            Block(id: "u9-ii-fn1", projectId: pid, sortOrder: 3, blockType: .paragraph,
                  textContent: "Old footnote.", markdownFragment: "[^1]: Old footnote.", isNotes: true),
            Block(id: "u9-ii-bib-h", projectId: pid, sortOrder: 4, blockType: .heading,
                  textContent: "Bibliography", markdownFragment: "# Bibliography", headingLevel: 1,
                  isBibliography: true),
            Block(id: "u9-ii-bib-1", projectId: pid, sortOrder: 5, blockType: .paragraph,
                  textContent: "Entry one.", markdownFragment: "Entry one.", isBibliography: true)
        ]
        try probe.write { database in
            try Block.filter(Block.Columns.projectId == pid).deleteAll(database)
            for var row in existing {
                try row.insert(database)
            }
        }
        let db = probe
        let epochBefore = try db.currentBlockWriteEpoch(projectId: pid)
        let seeded = try seedNonzeroStamps(db, pid, ids: existing.map(\.id), epoch: epochBefore, base: 20)

        // The incoming document carries NO Notes/Bibliography headings or entries (the real
        // section-restore call sites guarantee that), plus one same-label Notes definition
        // that must merge into the preserved "[^1]:" row instead of being inserted.
        let incoming = [
            Block(id: "u9-ii-new-intro", projectId: pid, sortOrder: 0, blockType: .heading,
                  textContent: "Intro", markdownFragment: "# Intro", headingLevel: 1),
            Block(id: "u9-ii-new-body", projectId: pid, sortOrder: 0, blockType: .paragraph,
                  textContent: "New body.", markdownFragment: "New body."),
            Block(id: "u9-ii-new-next", projectId: pid, sortOrder: 0, blockType: .heading,
                  textContent: "Next", markdownFragment: "## Next", headingLevel: 2),
            Block(id: "u9-ii-new-next-body", projectId: pid, sortOrder: 0, blockType: .paragraph,
                  textContent: "Next body.", markdownFragment: "Next body."),
            Block(id: "u9-ii-new-fn1", projectId: pid, sortOrder: 0, blockType: .paragraph,
                  textContent: "New footnote.", markdownFragment: "[^1]: New footnote.", isNotes: true)
        ]
        try replace(db, path, incoming, pid: pid, preservingMachineManagedBlocks: true)

        let epochAfter = try db.currentBlockWriteEpoch(projectId: pid)
        #expect(epochAfter == epochBefore + 1, "the preserving path bumps the epoch exactly once as well")

        // Order after renumbering (index + 1): the four new rows (sortOrder 0...3 before),
        // then the re-anchored preserved rows in their original relative order
        // (Notes heading, footnote, Bibliography heading, entry at 5...8 before).
        // "Intro" pops its old row's id and metadata. The incoming "[^1]:" block is merged into
        // "u9-ii-fn1" (text + fragment replaced, id kept) and never inserted under its own id.
        let expectedRows = [
            expected("u9-ii-intro", 1, .heading, "Intro", fragment: "# Intro", level: 1,
                     status: .review, tags: ["t1"], wordGoal: 300, epoch: epochAfter),
            expected("u9-ii-new-body", 2, .paragraph, "New body.", epoch: epochAfter),
            expected("u9-ii-new-next", 3, .heading, "Next", fragment: "## Next", level: 2,
                     sectionParent: "u9-ii-intro", epoch: epochAfter),
            expected("u9-ii-new-next-body", 4, .paragraph, "Next body.", epoch: epochAfter),
            expected("u9-ii-notes-h", 5, .heading, "Notes", fragment: "# Notes", level: 1,
                     isNotes: true, epoch: epochAfter),
            expected("u9-ii-fn1", 6, .paragraph, "New footnote.", fragment: "[^1]: New footnote.",
                     isNotes: true, epoch: epochAfter),
            expected("u9-ii-bib-h", 7, .heading, "Bibliography", fragment: "# Bibliography", level: 1,
                     isBibliography: true, epoch: epochAfter),
            expected("u9-ii-bib-1", 8, .paragraph, "Entry one.", isBibliography: true, epoch: epochAfter)
        ]
        let actualRows = try snapshots(db, pid)
        #expect(actualRows == expectedRows)
        expectRestamped(actualRows, seeded: seeded, epoch: epochAfter)
        #expect(!actualRows.contains { $0.id == "u9-ii-new-fn1" }, "the merged Notes definition must not also be inserted")
    }

    // MARK: - (iii) Ranged replace with a renamed anchor heading

    @Test("""
        replaceBlocksInRange with anchorHeadingId: a RENAMED zoom-root heading keeps its id and metadata by position, \
        rows after the range are shifted and renumbered, rows outside the range keep their ids and text, and every row \
        (inside and outside the range) is restamped to (E+1, 0)
        """, arguments: ReplaceBlocksApiPath.allCases)
    func rangedReplaceWithRenamedAnchor(path: ReplaceBlocksApiPath) throws {
        let probe = try TestFixtureFactory.createTemporary(content: "# Seed\n\nSeed body.\n")
        let pid = try TestFixtureFactory.getProjectId(from: probe)

        let existing = [
            Block(id: "u9-iii-top", projectId: pid, sortOrder: 0, blockType: .heading,
                  textContent: "Top", markdownFragment: "# Top", headingLevel: 1),
            Block(id: "u9-iii-top-body", projectId: pid, sortOrder: 1, blockType: .paragraph,
                  textContent: "Top body.", markdownFragment: "Top body."),
            Block(id: "u9-iii-zoom", projectId: pid, sortOrder: 2, blockType: .heading,
                  textContent: "Zoomed Old", markdownFragment: "## Zoomed Old", headingLevel: 2,
                  status: .writing, tags: ["z"], wordGoal: 150, goalType: .max),
            Block(id: "u9-iii-zoom-body", projectId: pid, sortOrder: 3, blockType: .paragraph,
                  textContent: "Zoomed body.", markdownFragment: "Zoomed body."),
            Block(id: "u9-iii-after", projectId: pid, sortOrder: 4, blockType: .heading,
                  textContent: "After", markdownFragment: "# After", headingLevel: 1),
            Block(id: "u9-iii-after-body", projectId: pid, sortOrder: 5, blockType: .paragraph,
                  textContent: "After body.", markdownFragment: "After body.")
        ]
        try probe.write { database in
            try Block.filter(Block.Columns.projectId == pid).deleteAll(database)
            for var row in existing {
                try row.insert(database)
            }
        }
        let db = probe
        let epochBefore = try db.currentBlockWriteEpoch(projectId: pid)
        // Every row gets a nonzero stamp, the four OUTSIDE the replaced range [2, 4) included
        // (u9-iii-top, u9-iii-top-body, u9-iii-after, u9-iii-after-body): those keep their id and text, so
        // only their stamp can show whether the ranged replace restamped them or left them alone.
        let seeded = try seedNonzeroStamps(db, pid, ids: existing.map(\.id), epoch: epochBefore, base: 40)

        let incoming = [
            Block(id: "u9-iii-new-zoom", projectId: pid, sortOrder: 0, blockType: .heading,
                  textContent: "Zoomed Renamed", markdownFragment: "## Zoomed Renamed", headingLevel: 2),
            Block(id: "u9-iii-new-zoom-body", projectId: pid, sortOrder: 0, blockType: .paragraph,
                  textContent: "Zoomed body edited.", markdownFragment: "Zoomed body edited."),
            Block(id: "u9-iii-new-added", projectId: pid, sortOrder: 0, blockType: .paragraph,
                  textContent: "Added paragraph.", markdownFragment: "Added paragraph.")
        ]
        let inserted = try replaceInRange(
            db, path, incoming, pid: pid,
            range: RangedReplaceArgs(startSortOrder: 2, endSortOrder: 4, anchorHeadingId: "u9-iii-zoom"))

        // The returned rows are the rows actually inserted, in document order, with the anchor
        // heading carrying its preserved id.
        #expect(inserted.map(\.id) == ["u9-iii-zoom", "u9-iii-new-zoom-body", "u9-iii-new-added"])

        let epochAfter = try db.currentBlockWriteEpoch(projectId: pid)
        #expect(epochAfter == epochBefore + 1, "replaceBlocksInRange bumps the project epoch exactly once")

        // Range [2, 4) held the old zoom heading + body; they are replaced by three rows at
        // sortOrder 2, 3, 4. insertEnd (5) overshoots the range end (4) by 1, so the two
        // rows after the range shift 4,5 -> 5,6. Renumbering then maps 0...6 -> 1...7.
        // Section parents: the renamed level-2 anchor hangs off "Top"; "After" is level 1.
        let expectedRows = [
            expected("u9-iii-top", 1, .heading, "Top", fragment: "# Top", level: 1, epoch: epochAfter),
            expected("u9-iii-top-body", 2, .paragraph, "Top body.", epoch: epochAfter),
            expected("u9-iii-zoom", 3, .heading, "Zoomed Renamed", fragment: "## Zoomed Renamed", level: 2,
                     sectionParent: "u9-iii-top", status: .writing, tags: ["z"], wordGoal: 150,
                     goalType: .max, epoch: epochAfter),
            expected("u9-iii-new-zoom-body", 4, .paragraph, "Zoomed body edited.", epoch: epochAfter),
            expected("u9-iii-new-added", 5, .paragraph, "Added paragraph.", epoch: epochAfter),
            expected("u9-iii-after", 6, .heading, "After", fragment: "# After", level: 1, epoch: epochAfter),
            expected("u9-iii-after-body", 7, .paragraph, "After body.", epoch: epochAfter)
        ]
        let actualRows = try snapshots(db, pid)
        #expect(actualRows == expectedRows)
        // Restamped vs untouched: the rows OUTSIDE the range keep their ids and text, yet are NOT left at their
        // seeded (E, 40+n) stamps -- the whole project is restamped to (E+1, 0).
        expectRestamped(actualRows, seeded: seeded, epoch: epochAfter,
                        only: ["u9-iii-top", "u9-iii-top-body", "u9-iii-after", "u9-iii-after-body"])
    }

    // MARK: - (iv) Notes-heading-title read

    @Test("""
        fetchNotesHeadingTitle(projectId:) returns the FIRST (by sortOrder) isNotes HEADING's text, ignores an isNotes \
        non-heading row, and is nil when no isNotes heading exists
        """, arguments: ReplaceBlocksApiPath.allCases)
    func notesHeadingTitleRead(path: ReplaceBlocksApiPath) throws {
        let probe = try TestFixtureFactory.createTemporary(content: "# Seed\n\nSeed body.\n")
        let pid = try TestFixtureFactory.getProjectId(from: probe)

        // No isNotes anywhere yet: nil.
        try probe.write { database in
            try Block.filter(Block.Columns.projectId == pid).deleteAll(database)
            var plain = Block(id: "u9-iv-plain-h", projectId: pid, sortOrder: 0, blockType: .heading,
                              textContent: "Plain", markdownFragment: "# Plain", headingLevel: 1)
            try plain.insert(database)
        }
        #expect(try notesTitle(probe, path, pid: pid) == nil)

        // An isNotes PARAGRAPH sorts first (sortOrder 0.5) but must not be returned; the
        // headings at sortOrder 5 and 9 are both isNotes, and the earlier one wins.
        try probe.write { database in
            var notesParagraph = Block(id: "u9-iv-fn", projectId: pid, sortOrder: 0.5, blockType: .paragraph,
                                       textContent: "x", markdownFragment: "[^1]: x", isNotes: true)
            try notesParagraph.insert(database)
            var secondNotes = Block(id: "u9-iv-notes-2", projectId: pid, sortOrder: 9, blockType: .heading,
                                    textContent: "Second Notes", markdownFragment: "# Second Notes",
                                    headingLevel: 1, isNotes: true)
            try secondNotes.insert(database)
            var firstNotes = Block(id: "u9-iv-notes-1", projectId: pid, sortOrder: 5, blockType: .heading,
                                   textContent: "Footnotes Custom", markdownFragment: "# Footnotes Custom",
                                   headingLevel: 1, isNotes: true)
            try firstNotes.insert(database)
        }
        #expect(try notesTitle(probe, path, pid: pid) == "Footnotes Custom")
    }

    // MARK: - API-shape note (B4)

    // Each case above runs twice, once per `ReplaceBlocksApiPath`, against the SAME explicit
    // expected rows. The explicit expectations are the regression guard (written against, and
    // passing on, the unmodified base). Instance-vs-static agreement is an API-shape check only:
    // after the extraction the instance method IS `write { Self.replaceBlocks(db:...) }`.
}

/// The ranged-replace arguments, bundled so `replaceInRange` stays under the parameter-count limit.
private struct RangedReplaceArgs {
    let startSortOrder: Double
    let endSortOrder: Double?
    let anchorHeadingId: String?
}

// MARK: - API-path drivers

private extension ReplaceBlocksStaticTests {
    /// Review fix M31: gives every row in `ids` a NONZERO stamp `(epoch, base + index)` by raw SQL (the
    /// `Block` record deliberately has no stamp columns), and asserts the seed took. Seeded at the
    /// default (0, 0), a row's `lastWriteSequence == 0` after a replace cannot tell "restamped to
    /// (E+1, 0)" from "never touched"; with a nonzero seed the two are different values.
    func seedNonzeroStamps(
        _ db: ProjectDatabase, _ pid: String, ids: [String], epoch: Int64, base: Int64
    ) throws -> [String: (epoch: Int64, sequence: Int64)] {
        var seeded: [String: (epoch: Int64, sequence: Int64)] = [:]
        try db.write { database in
            for (index, id) in ids.enumerated() {
                let sequence = base + Int64(index)
                try database.execute(
                    sql: "UPDATE block SET lastWriteEpoch = ?, lastWriteSequence = ? WHERE id = ?",
                    arguments: [epoch, sequence, id])
                seeded[id] = (epoch, sequence)
            }
        }
        for row in try snapshots(db, pid) {
            #expect(row.lastWriteEpoch == seeded[row.id]?.epoch && row.lastWriteSequence == seeded[row.id]?.sequence,
                    "the nonzero seed on \(row.id) must be in place before the replace")
        }
        #expect(seeded.values.allSatisfy { $0.sequence != 0 }, "a seed of 0 would defeat the purpose")
        return seeded
    }

    /// After the replace: every row (or just `only`) carries (E+1, 0) AND differs from its seeded stamp in
    /// both fields -- restamped, not left alone.
    func expectRestamped(
        _ rows: [RowSnapshot], seeded: [String: (epoch: Int64, sequence: Int64)], epoch: Int64,
        only ids: Set<String>? = nil
    ) {
        let checked = rows.filter { ids?.contains($0.id) ?? true }
        #expect(ids == nil || checked.count == ids?.count, "every named row must exist after the replace")
        for row in checked {
            #expect(row.lastWriteEpoch == epoch && row.lastWriteSequence == 0, "\(row.id) must be restamped to (E+1, 0)")
            if let stamp = seeded[row.id] {
                #expect(row.lastWriteEpoch != stamp.epoch && row.lastWriteSequence != stamp.sequence,
                        "\(row.id) must differ from its seeded stamp in BOTH fields")
            }
        }
    }

    func replace(
        _ db: ProjectDatabase, _ path: ReplaceBlocksApiPath, _ blocks: [Block], pid: String,
        preservingMachineManagedBlocks: Bool = false
    ) throws {
        switch path {
        case .instance:
            try db.replaceBlocks(blocks, for: pid, preservingMachineManagedBlocks: preservingMachineManagedBlocks)
        case .staticInTransaction:
            try db.dbWriter.write { database in
                try ProjectDatabase.replaceBlocks(
                    db: database, blocks, for: pid, preservingMachineManagedBlocks: preservingMachineManagedBlocks)
            }
        }
    }

    func replaceInRange(
        _ db: ProjectDatabase, _ path: ReplaceBlocksApiPath, _ blocks: [Block], pid: String, range: RangedReplaceArgs
    ) throws -> [Block] {
        switch path {
        case .instance:
            return try db.replaceBlocksInRange(
                blocks, for: pid, startSortOrder: range.startSortOrder, endSortOrder: range.endSortOrder,
                anchorHeadingId: range.anchorHeadingId)
        case .staticInTransaction:
            return try db.dbWriter.write { database in
                try ProjectDatabase.replaceBlocksInRange(
                    db: database, blocks, for: pid, startSortOrder: range.startSortOrder,
                    endSortOrder: range.endSortOrder, anchorHeadingId: range.anchorHeadingId)
            }
        }
    }

    func notesTitle(_ db: ProjectDatabase, _ path: ReplaceBlocksApiPath, pid: String) throws -> String? {
        switch path {
        case .instance:
            return try db.fetchNotesHeadingTitle(projectId: pid)
        case .staticInTransaction:
            return try db.dbWriter.read { database in
                try ProjectDatabase.fetchNotesHeadingTitle(db: database, projectId: pid)
            }
        }
    }
}
