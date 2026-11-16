//
//  BatchWordCountsOnePassTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  t-58d64b34. The Outline sidebar's word counts (`ProjectDatabase.batchWordCounts`, read after every saved change) used to walk
//  the project's block rows once per heading, and a second time for a heading with an aggregate goal. They are now taken from ONE
//  walk over the rows. The numbers must not change, so the old computation lives at the bottom of THIS file as
//  `ProjectDatabase.batchWordCountsPerHeading` (test code only; nothing in the app has it) and these tests hold the new counts up
//  against it. The copy carries its own heading lookup (the old code's, unchanged), so it shares no code with the new path: a
//  fault in the production helper that finds the headings cannot pass the comparison unseen.
//
//  WHAT EACH TEST PINS
//   - The committed fixtures (`Fixtures/test-fixture.ff`, the bundled `getting-started.ff`), a rich document with a section break, a
//     Notes section and a bibliography, and the six-chapter generated book: the one-pass counts equal the per-heading counts, for
//     every heading, with no aggregate, with an aggregate for every heading and with one for every third heading, asking for all the
//     headings, for every other heading, and for the outline's blocks (the headings and section breaks, which are not headings and
//     get no entry) plus other blocks.
//   - A generated document of exactly 5,000 blocks and 200 headings (varied levels with skips, empty sections, a preamble before the
//     first heading, code blocks and section breaks that count 0 words): the same equality (a smaller matrix of asks, because each
//     old-style run on it is slow), and the counts also equal the numbers
//     the generator knows by construction (each section's words are added up while the document is built; the aggregate is the
//     definition applied to the generator's own list), so the new counts are checked against something other than the old code.
//   - Sixty small random documents whose block positions (`sortOrder`) collide often and whose headings include some with no level
//     (the old code treats a level-less heading as level 99): ties and odd levels give the same counts as before.
//   - Timing, on the generated 5,000-block document with an aggregate asked for every heading (the worst case the sidebar can
//     reach). Limits: the one-pass count takes under 0.5 s (best of three), AND at least twice as fast as the per-heading walk
//     (best of three each, measured one after the other in the same run, so a busy machine slows both). These are reasoned, not
//     measured: the old walk makes about 400 passes (200 headings plus 200 aggregates) over up to 5,000 rows, on average about
//     half of them visited per pass, so about a million row visits, each a by-name column lookup: roughly a tenth of a second at
//     best in a Debug build, more likely a few tenths of a second to a couple of seconds. The one-pass count reads the 5,000 rows
//     once through a cursor and does arithmetic on 200 headings: tens of milliseconds, nearly all of it the SQL read that both
//     versions pay. So 0.5 s leaves a wide margin on the new side and "twice as fast" a wide margin on the ratio (expected 5x to
//     30x). A failure prints both measured times.
//
//  If the counts ever differ, the failure message starts with "one-pass word counts differ from the per-heading reference" and names
//  the first heading that differs, with both pairs of numbers.
//

import Foundation
import GRDB
import Testing
@testable import final_final

// The suite is serialized: its timing test compares two measurements taken one after the other.
@Suite("Batch word counts in one pass match the per-heading counts — Tier 1: Silent Killers", .serialized)
@MainActor
struct BatchWordCountsOnePassTests {

    typealias Counts = ProjectDatabase.HeadingWordCounts

    // MARK: - Comparing the two computations

    /// A deterministic pseudo-random sequence (the same documents every run).
    private struct Rng {
        var state: UInt64
        mutating func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) & 0x7FFF_FFFF)
        }
        mutating func pick(_ count: Int) -> Int { next() % count }
    }

    /// The first difference between the two answers, in words ("" when equal).
    private static func firstDifference(
        _ onePass: [String: Counts],
        _ reference: [String: Counts],
        headings: [String: Block]
    ) -> String {
        let differing = Set(onePass.keys).symmetricDifference(Set(reference.keys))
        if !differing.isEmpty {
            return "the two answers cover different headings (\(differing.count) headings are in one answer only)"
        }
        let ordered = reference.keys.sorted { (headings[$0]?.sortOrder ?? 0) < (headings[$1]?.sortOrder ?? 0) }
        for key in ordered where onePass[key] != reference[key] {
            let block = headings[key]
            let level = block?.headingLevel.map(String.init) ?? "none"
            let name = "\"\(block?.textContent ?? key)\" (level \(level), sortOrder \(block?.sortOrder ?? 0))"
            let mine = onePass[key].map { "section \($0.sectionOnly) / aggregate \($0.aggregate)" } ?? "missing"
            let theirs = reference[key].map { "section \($0.sectionOnly) / aggregate \($0.aggregate)" } ?? "missing"
            return "heading \(name): one-pass \(mine), reference \(theirs)"
        }
        return ""
    }

    /// Runs both computations in ONE read transaction and returns their answers.
    private static func bothAnswers(
        _ db: ProjectDatabase,
        blockIds: [String],
        needsAggregate: Set<String>
    ) throws -> (onePass: [String: Counts], reference: [String: Counts]) {
        try db.dbWriter.read { database in
            (
                try ProjectDatabase.batchWordCounts(in: database, blockIds: blockIds, needsAggregate: needsAggregate),
                try ProjectDatabase.batchWordCountsPerHeading(in: database, blockIds: blockIds, needsAggregate: needsAggregate)
            )
        }
    }

    /// Compares the two computations on one project, for every combination of "which blocks are asked for" and "which headings get
    /// an aggregate" (a smaller matrix when `fullMatrix` is false, for the big generated document, where each old-style run is slow).
    /// Returns how many headings the project has (so a caller can refuse a vacuous comparison).
    @discardableResult
    private func expectOnePassMatchesPerHeading(_ db: ProjectDatabase, label: String, fullMatrix: Bool = true) throws -> Int {
        let (headings, outlineShape) = try db.dbWriter.read { database -> ([Block], [String]) in
            let heads = try Block.filter(Block.Columns.blockType == BlockType.heading.rawValue).order(Block.Columns.sortOrder).fetchAll(database)
            // What the outline asks for: the heading rows and the section breaks, plus (to prove that a block that is not a heading gets
            // no entry) up to 300 other blocks. Never thousands of ids in one SQL `IN` list.
            let rows = try Block.order(Block.Columns.sortOrder).fetchAll(database)
            let outline = rows.filter { $0.blockType == .heading || $0.isPseudoSection }
            let others = rows.filter { !($0.blockType == .heading || $0.isPseudoSection) }.prefix(300)
            return (heads, (outline + others).map(\.id))
        }
        let headingsById = Dictionary(uniqueKeysWithValues: headings.map { ($0.id, $0) })
        let headingIds = headings.map(\.id)

        var asked: [(name: String, ids: [String])] = [
            ("every heading", headingIds),
            ("the outline's blocks and others", outlineShape)
        ]
        var aggregates: [(name: String, ids: Set<String>)] = [
            ("aggregate for every heading", Set(headingIds)),
            ("aggregate for every third heading", Set(headingIds.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)))
        ]
        if fullMatrix {
            asked.append(("every other heading", headingIds.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)))
            aggregates.insert(("no aggregate", []), at: 0)
        }
        var sawAnAggregateThatDiffers = false
        for request in asked {
            for aggregate in aggregates {
                let (onePass, reference) = try Self.bothAnswers(db, blockIds: request.ids, needsAggregate: aggregate.ids)
                let context = "\(label); asked for \(request.name); \(aggregate.name)"
                let difference = Self.firstDifference(onePass, reference, headings: headingsById)
                #expect(onePass == reference, "one-pass word counts differ from the per-heading reference [\(context)]: \(difference)")
                if reference.values.contains(where: { $0.aggregate != $0.sectionOnly }) { sawAnAggregateThatDiffers = true }
            }
        }
        // Not vacuous: the headings were found, and at least one aggregate is larger than its section-only count (the document nests).
        #expect(!headings.isEmpty, "\(label): the project has no headings, so nothing was compared")
        #expect(sawAnAggregateThatDiffers, "\(label): no heading had a sub-section, so the aggregate path was never exercised")
        return headings.count
    }

    // MARK: - The committed fixtures

    private static func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tier1
            .deletingLastPathComponent()   // final finalTests
            .deletingLastPathComponent()   // project root
    }

    /// Opens a COPY of a committed `.ff` package (opening runs migrations, which must never touch the committed file) and compares.
    private func expectOnePassMatchesOnCommittedPackage(at relativePath: String) throws {
        let source = Self.projectRoot().appendingPathComponent(relativePath)
        try #require(FileManager.default.fileExists(atPath: source.path), "the committed package \(relativePath) is missing (\(source.path))")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("wordcount-onepass-\(UUID().uuidString).ff")
        try FileManager.default.copyItem(at: source, to: copy)
        let package = try ProjectPackage.open(at: copy)
        let db = try ProjectDatabase(package: package)
        defer { TestDatabaseTeardown.closeThenCleanUp(copy, db) }
        let headingCount = try expectOnePassMatchesPerHeading(db, label: relativePath)
        #expect(headingCount >= 2, "\(relativePath) was expected to hold at least two headings")
    }

    @Test("The committed test fixture gives the same counts one pass as per heading")
    func committedTestFixtureMatches() throws {
        try expectOnePassMatchesOnCommittedPackage(at: "final finalTests/Fixtures/test-fixture.ff")
    }

    @Test("The bundled Getting Started project gives the same counts one pass as per heading")
    func bundledGettingStartedMatches() throws {
        try expectOnePassMatchesOnCommittedPackage(at: "final final/Resources/getting-started.ff")
    }

    @Test("A rich document (section break, Notes, bibliography) gives the same counts one pass as per heading")
    func richDocumentMatches() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        try expectOnePassMatchesPerHeading(db, label: "richTestContent")
    }

    @Test("The six-chapter generated book gives the same counts one pass as per heading")
    func sixChapterBookMatches() throws {
        let db = try TestFixtureFactory.createTemporary(content: ComplexDocumentFixture.book6.editorMarkdown)
        try expectOnePassMatchesPerHeading(db, label: "ComplexDocumentFixture.book6")
    }

    // MARK: - A generated document of 5,000 blocks and 200 headings

    /// What the generator knows about the document it built.
    private struct GeneratedDocument {
        let db: ProjectDatabase
        let blockCount: Int
        /// Headings in document order.
        let headings: [Block]
        /// Words from each heading (its own words included) up to the next heading of any level, by construction.
        let sectionWords: [String: Int]
        /// Words in the blocks before the first heading.
        let preambleWords: Int
        let totalWords: Int
    }

    private static let generatedBlockCount = 5_000
    private static let generatedHeadingCount = 200
    private static let preambleBlockCount = 8

    /// Builds the document straight into the `block` table (one write): 8 preamble paragraphs, then 200 headings with 4,792 body
    /// blocks shared out at random (some headings get none), 5,000 rows in all. Levels run 1 to 4 and skip freely (the first heading
    /// is level 1). Words: paragraphs 0 to 59, headings 1 to 6, code blocks and section breaks 0. Positions rise by irregular steps
    /// that a double holds exactly.
    private static func makeGeneratedDocument() throws -> GeneratedDocument {
        let db = try TestFixtureFactory.createTemporary(content: "")
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        var rng = Rng(state: 0x5EED_0F_5EC7)

        var bodySizes = [Int](repeating: 0, count: generatedHeadingCount)
        for _ in 0..<(generatedBlockCount - preambleBlockCount - generatedHeadingCount) { bodySizes[rng.pick(generatedHeadingCount)] += 1 }

        var blocks: [Block] = []
        var headings: [Block] = []
        var sectionWords: [String: Int] = [:]
        var sortOrder = 0.0
        func nextSortOrder() -> Double {
            sortOrder += 0.5 + Double(rng.pick(8)) / 4.0
            return sortOrder
        }

        var preambleWords = 0
        for _ in 0..<preambleBlockCount {
            let words = 1 + rng.pick(59)
            preambleWords += words
            blocks.append(Block(projectId: projectId, sortOrder: nextSortOrder(), blockType: .paragraph, wordCount: words))
        }
        for index in 0..<generatedHeadingCount {
            let roll = rng.pick(10)
            let level = index == 0 ? 1 : (roll < 1 ? 1 : (roll < 4 ? 2 : (roll < 8 ? 3 : 4)))
            let ownWords = 1 + rng.pick(6)
            let heading = Block(
                projectId: projectId, sortOrder: nextSortOrder(), blockType: .heading,
                textContent: "Heading \(index)", headingLevel: level, wordCount: ownWords
            )
            blocks.append(heading)
            headings.append(heading)
            var words = ownWords
            for position in 0..<bodySizes[index] {
                let block: Block
                if position % 17 == 16 {
                    block = Block(projectId: projectId, sortOrder: nextSortOrder(), blockType: .codeBlock, wordCount: 0)
                } else if position % 41 == 40 {
                    block = Block(
                        projectId: projectId, sortOrder: nextSortOrder(), blockType: .sectionBreak, wordCount: 0, isPseudoSection: true
                    )
                } else {
                    block = Block(projectId: projectId, sortOrder: nextSortOrder(), blockType: .paragraph, wordCount: rng.pick(60))
                }
                blocks.append(block)
                words += block.wordCount
            }
            sectionWords[heading.id] = words
        }

        try db.dbWriter.write { database in
            for var block in blocks { try block.insert(database) }
        }
        let totalWords = blocks.reduce(0) { $0 + $1.wordCount }
        return GeneratedDocument(
            db: db, blockCount: blocks.count, headings: headings,
            sectionWords: sectionWords, preambleWords: preambleWords, totalWords: totalWords
        )
    }

    @Test("A generated 5,000-block, 200-heading document gives the same counts one pass as per heading, and the builder's own numbers")
    func generatedLargeDocumentMatches() throws {
        let document = try Self.makeGeneratedDocument()
        #expect(document.blockCount == Self.generatedBlockCount)
        #expect(document.headings.count == Self.generatedHeadingCount)
        let storedRows = try document.db.dbWriter.read { try Block.fetchCount($0) }
        #expect(storedRows == Self.generatedBlockCount, "the generated document must really hold 5,000 rows")

        try expectOnePassMatchesPerHeading(document.db, label: "generated 5,000-block document", fullMatrix: false)

        // The builder's own numbers, not the old code's: every section's words by construction, and the aggregate by its definition
        // (the heading's section plus every following section until a heading of the same or a higher level).
        let ids = document.headings.map(\.id)
        let counts = try document.db.batchWordCounts(blockIds: ids, needsAggregate: Set(ids))
        var sectionSum = 0
        for (index, heading) in document.headings.enumerated() {
            let expectedSection = document.sectionWords[heading.id] ?? -1
            sectionSum += expectedSection
            var expectedAggregate = expectedSection
            let level = heading.headingLevel ?? 99
            for later in document.headings[(index + 1)...] {
                if (later.headingLevel ?? 99) <= level { break }
                expectedAggregate += document.sectionWords[later.id] ?? 0
            }
            #expect(counts[heading.id]?.sectionOnly == expectedSection, "\(heading.textContent): section-only words differ from the builder's")
            #expect(counts[heading.id]?.aggregate == expectedAggregate, "\(heading.textContent): aggregate words differ from the definition")
        }
        #expect(sectionSum + document.preambleWords == document.totalWords, "the builder's sections plus the preamble must add up to every word")
    }

    // MARK: - Ties and headings with no level

    @Test("Sixty small random documents with colliding positions and level-less headings give the same counts one pass as per heading")
    func tiedSortOrdersAndLevellessHeadingsMatch() throws {
        let db = try TestFixtureFactory.createTemporary(content: "")
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        var rng = Rng(state: 0xC0_11_1D_E5)
        var headingsSeen = 0
        var tiedHeadingsSeen = 0

        for trial in 0..<60 {
            // ~40 blocks on 15 positions: positions collide often, among headings too.
            var blocks: [Block] = []
            for _ in 0..<(30 + rng.pick(20)) {
                let position = Double(rng.pick(15)) / 2.0
                if rng.pick(10) < 3 {
                    let levels: [Int?] = [nil, 1, 1, 2, 3, 4, 5, 6]
                    let level = levels[rng.pick(levels.count)]
                    blocks.append(Block(
                        projectId: projectId, sortOrder: position, blockType: .heading,
                        textContent: "T\(trial) heading", headingLevel: level, wordCount: 1 + rng.pick(5)
                    ))
                } else {
                    blocks.append(Block(projectId: projectId, sortOrder: position, blockType: .paragraph, wordCount: rng.pick(10)))
                }
            }
            let headingBlocks = blocks.filter { $0.blockType == .heading }
            headingsSeen += headingBlocks.count
            tiedHeadingsSeen += headingBlocks.filter { head in headingBlocks.contains { $0.id != head.id && $0.sortOrder == head.sortOrder } }.count

            try db.dbWriter.write { database in
                try database.execute(sql: "DELETE FROM block")
                for var block in blocks { try block.insert(database) }
            }
            let headingIds = headingBlocks.map(\.id)
            let headingsById = Dictionary(uniqueKeysWithValues: headingBlocks.map { ($0.id, $0) })
            // Some headings asked for, some of those with an aggregate, all drawn from the same sequence.
            let asked = rng.pick(3) == 0 ? blocks.map(\.id) : headingIds.filter { _ in rng.pick(4) != 0 }
            let aggregate = Set(headingIds.filter { _ in rng.pick(2) == 0 })
            let (onePass, reference) = try Self.bothAnswers(db, blockIds: asked, needsAggregate: aggregate)
            let difference = Self.firstDifference(onePass, reference, headings: headingsById)
            #expect(onePass == reference, "one-pass word counts differ from the per-heading reference [random document \(trial)]: \(difference)")
        }
        #expect(headingsSeen > 300, "the random documents held too few headings to prove anything (\(headingsSeen))")
        #expect(tiedHeadingsSeen > 50, "the random documents held too few headings sharing a position (\(tiedHeadingsSeen))")
    }

    // MARK: - Timing

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The fastest of `runs` timed runs (the first, unmeasured, warms the page cache).
    private static func bestSeconds(runs: Int, _ work: () throws -> Void) rethrows -> Double {
        try work()
        var best = Double.infinity
        for _ in 0..<runs {
            let duration = try ContinuousClock().measure(work)
            best = min(best, seconds(duration))
        }
        return best
    }

    @Test("On 5,000 blocks and 200 headings the one-pass count takes under half a second and at least twice as fast as the per-heading walk")
    func onePassIsFastOnALargeDocument() throws {
        let document = try Self.makeGeneratedDocument()
        let ids = document.headings.map(\.id)
        let everyAggregate = Set(ids)

        let onePass = try Self.bestSeconds(runs: 3) {
            _ = try document.db.dbWriter.read { database in
                try ProjectDatabase.batchWordCounts(in: database, blockIds: ids, needsAggregate: everyAggregate)
            }
        }
        let perHeading = try Self.bestSeconds(runs: 3) {
            _ = try document.db.dbWriter.read { database in
                try ProjectDatabase.batchWordCountsPerHeading(in: database, blockIds: ids, needsAggregate: everyAggregate)
            }
        }
        let ratio = perHeading / max(onePass, 1e-9)
        let timings = String(format: "one pass %.1f ms, per heading %.1f ms (%.1fx)", onePass * 1000, perHeading * 1000, ratio)
        print("[WORDCOUNT-ONEPASS] 5,000 blocks, 200 headings, aggregate for every heading: \(timings)")
        #expect(onePass < 0.5, "the one-pass count must take under 0.5 s on 5,000 blocks and 200 headings: \(timings)")
        #expect(onePass * 2 < perHeading, "the one-pass count must be at least twice as fast as the per-heading walk: \(timings)")
    }
}

// MARK: - The reference: the old per-heading computation

extension ProjectDatabase {

    /// The OLD computation of `batchWordCounts(in:blockIds:needsAggregate:)`, copied from the code as it was before t-58d64b34 (the
    /// heading lookup written out inline, the per-heading `sumWords` walk, the aggregate end). Every heading sums its own range of
    /// rows: one pass over the rows per heading, two for a heading with an aggregate goal. It exists only here, as the reference the
    /// one-pass counts are compared with and as the slow side of the timing check. Only its closing debug log was left out.
    fileprivate static func batchWordCountsPerHeading(
        in db: Database,
        blockIds: [String],
        needsAggregate: Set<String> = []
    ) throws -> [String: HeadingWordCounts] {
        guard !blockIds.isEmpty else { return [:] }

        // Fetch the requested heading blocks
        let headingBlocks = try Block
            .filter(blockIds.contains(Block.Columns.id))
            .filter(Block.Columns.blockType == BlockType.heading.rawValue)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)

        guard !headingBlocks.isEmpty else { return [:] }

        // Safety: callers should only pass blockIds from one project.
        // If multiple projects sneak in, only process the dominant one.
        let projectIds = Set(headingBlocks.map { $0.projectId })
        if projectIds.count > 1 {
            DebugLog.log(.outline, "[batchWordCounts] WARNING: blockIds span \(projectIds.count) projects; using first")
        }
        guard let projectId = headingBlocks.first?.projectId else { return [:] }

        let inProject = headingBlocks.filter { $0.projectId == projectId }

        // Fetch every heading in the project (needed to find boundaries)
        let allHeadings = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.blockType == BlockType.heading.rawValue)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)

        // Fetch every block in the project (just sortOrder + wordCount)
        // The COALESCE guards against the legacy column being NULL after migration drift.
        let allBlocks = try Row.fetchAll(db, sql: """
            SELECT sortOrder, COALESCE(wordCount, 0) AS wordCount
            FROM block
            WHERE projectId = ?
            ORDER BY sortOrder
            """, arguments: [projectId])

        // Sum block wordCounts whose sortOrder falls in [start, end). End nil = open.
        // One linear walk per call: O(B) for each heading asked for.
        func sumWords(from startSortOrder: Double, until endSortOrder: Double?) -> Int {
            var total = 0
            for row in allBlocks {
                let rowSort: Double = row["sortOrder"] ?? 0
                if rowSort < startSortOrder { continue }
                if let limit = endSortOrder, rowSort >= limit { break }
                total += (row["wordCount"] as Int?) ?? 0
            }
            return total
        }

        let headingSortOrders = allHeadings.map { $0.sortOrder }

        var result: [String: HeadingWordCounts] = [:]
        result.reserveCapacity(inProject.count)

        for heading in inProject {
            let headingSortOrder = heading.sortOrder

            // Section-only ends at the next heading of any level
            let nextAnyIdx = headingSortOrders.firstIndex(where: { $0 > headingSortOrder })
            let nextAnySortOrder = nextAnyIdx.map { headingSortOrders[$0] }
            let sectionOnly = sumWords(from: headingSortOrder, until: nextAnySortOrder)

            // Aggregate ends at the next heading of same-or-higher level (lower number)
            var aggregate = sectionOnly
            if needsAggregate.contains(heading.id), let level = heading.headingLevel {
                let nextSameOrHigherSO = allHeadings
                    .first(where: { $0.sortOrder > headingSortOrder && ($0.headingLevel ?? 99) <= level })
                    .map { $0.sortOrder }
                aggregate = sumWords(from: headingSortOrder, until: nextSameOrHigherSO)
            }

            result[heading.id] = HeadingWordCounts(sectionOnly: sectionOnly, aggregate: aggregate)
        }

        return result
    }
}
