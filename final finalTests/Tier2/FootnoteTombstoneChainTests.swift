//
//  FootnoteTombstoneChainTests.swift
//  final finalTests
//
//  Footnote clean-up: find each removed row's neighbour in one pass (t-83251af6).
//
//  `FootnoteSyncService.resolveTombstoneChain` records, for every row a Notes write is about
//  to delete, which SURVIVING row stood before it. It used to ask the database one step at a
//  time (`resolveTombstoneChainOneQueryPerStep`, kept as the reference): N deleted rows that
//  stood next to each other cost about N squared over two queries inside the write. It now
//  reads the project's row ids in document order once and works the answers out in memory.
//  This file proves the two give the SAME answer, and that the new one asks the database once.
//
//  Three tests:
//    1. A hand-worked example (expected values written out from the rule, not copied from
//       either function), run through BOTH functions.
//    2. The new result against the old walk for many random layouts and random sets of
//       deleted rows. A seeded generator, so a failure names the seed that reproduces it.
//    3. 300 neighbouring deleted rows: ONE statement reads the block table (counted through
//       GRDB's statement trace, the way `SectionDeleteRootGuardTests` does), against the
//       old walk's N * (N + 1) / 2, shown on a smaller run.
//

import Testing
import Foundation
import GRDB
@testable import final_final

/// The SQL of every statement a traced connection ran, in order.
private final class TombstoneStatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []
    func record(_ sql: String) { lock.lock(); statements.append(sql); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return statements }
}

/// A tiny deterministic PRNG (splitmix64): every random layout and delete set can be rebuilt from its seed.
/// Swift's `SystemRandomNumberGenerator` is intentionally not seedable.
private struct TombstoneSeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

@Suite(
    "Footnote tombstone chain — one read gives the old walk's answer (t-83251af6, Tier 2)",
    .timeLimit(.minutes(3))
)
struct FootnoteTombstoneChainTests {
    private static let otherProjectId = "other-project"

    /// A project in a fresh database, plus a second, empty project whose rows must never be anchors.
    private struct Stack {
        let db: ProjectDatabase
        let pid: String
    }

    private func makeStack() throws -> Stack {
        let db = try TestFixtureFactory.createTemporary(content: "# A\n\nbody")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        try db.dbWriter.write { database in
            let now = Date()
            try database.execute(
                sql: "INSERT INTO project (id, title, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [Self.otherProjectId, "Other project", now, now])
        }
        return Stack(db: db, pid: pid)
    }

    /// Replaces every block of both projects with exactly these rows, inserted in the order given (which need not be document order).
    private func seedRows(
        _ stack: Stack, mine: [(id: String, sortOrder: Double)], others: [(id: String, sortOrder: Double)]
    ) throws {
        try stack.db.dbWriter.write { database in
            try Block.filter(Block.Columns.projectId == stack.pid).deleteAll(database)
            try Block.filter(Block.Columns.projectId == Self.otherProjectId).deleteAll(database)
            for row in mine {
                var block = Block(id: row.id, projectId: stack.pid, sortOrder: row.sortOrder, blockType: .paragraph)
                try block.insert(database)
            }
            for row in others {
                var block = Block(id: row.id, projectId: Self.otherProjectId, sortOrder: row.sortOrder, blockType: .paragraph)
                try block.insert(database)
            }
        }
    }

    // MARK: - 1. Hand-worked example

    @Test("Hand-worked: a deleted row's neighbour is the nearest row before it that is not deleted; both functions agree")
    func handWorkedExample() throws {
        let stack = try makeStack()
        // Document order A B C D E F. Inserted shuffled, with ids whose alphabetical order is NOT the document order, so only
        // `sortOrder` can put them right. Another project's rows sit before A (0.5) and between B and C (2.5): never anchors.
        try seedRows(
            stack,
            mine: [("p-e", 5), ("p-a", 1), ("p-f", 6), ("p-c", 3), ("p-b", 2), ("p-d", 4)],
            others: [("x-before-first", 0.5), ("x-between", 2.5)])

        // Delete A, C, D, F (and an id with no row at all).
        //   A is the first row of its project: nothing before it -> start of document (the other project's 0.5 row does not count).
        //   C's row before it is B, which stays -> after B.
        //   D's row before it is C, which is deleted too -> walk past it to B.
        //   F's row before it is E, which stays -> after E.
        //   "ghost" has no row: nothing to measure from -> start of document.
        let deleted: Set<String> = ["p-a", "p-c", "p-d", "p-f", "ghost"]
        let expected: [String: DeletedAnchor] = [
            "p-a": .documentStart, "p-c": .after("p-b"), "p-d": .after("p-b"), "p-f": .after("p-e"), "ghost": .documentStart
        ]
        // Delete the whole project: every row, and the first rows of the run, have nothing surviving before them.
        let everything: Set<String> = ["p-a", "p-b", "p-c", "p-d", "p-e", "p-f"]
        let expectedEverything = Dictionary(uniqueKeysWithValues: everything.map { ($0, DeletedAnchor.documentStart) })

        try stack.db.dbWriter.read { database in
            let pid = stack.pid
            let oneRead = try FootnoteSyncService.resolveTombstoneChain(db: database, projectId: pid, deletedIds: deleted)
            let oldWalk = try FootnoteSyncService.resolveTombstoneChainOneQueryPerStep(db: database, projectId: pid, deletedIds: deleted)
            #expect(oneRead == expected, "one read: \(oneRead)")
            #expect(oldWalk == expected, "the reference walk gives the hand-worked answer too (checks the worked example): \(oldWalk)")

            let allOneRead = try FootnoteSyncService.resolveTombstoneChain(db: database, projectId: pid, deletedIds: everything)
            let allOldWalk = try FootnoteSyncService.resolveTombstoneChainOneQueryPerStep(
                db: database, projectId: pid, deletedIds: everything)
            #expect(allOneRead == expectedEverything, "every row deleted, one read: \(allOneRead)")
            #expect(allOldWalk == expectedEverything, "every row deleted, reference walk: \(allOldWalk)")

            #expect(try FootnoteSyncService.resolveTombstoneChain(db: database, projectId: pid, deletedIds: []).isEmpty)
            #expect(try FootnoteSyncService.resolveTombstoneChainOneQueryPerStep(db: database, projectId: pid, deletedIds: []).isEmpty)
        }
    }

    // MARK: - 2. Random layouts and delete sets

    /// One random project layout and one random delete set, rebuilt from `seed` alone.
    private struct Scenario {
        let seed: UInt64
        let mine: [(id: String, sortOrder: Double)]   // inserted in this (shuffled) order
        let others: [(id: String, sortOrder: Double)]
        let deleted: Set<String>
        let mode: String
    }

    private typealias RowList = [(id: String, sortOrder: Double)]

    /// Document order: strictly increasing, fractional, possibly negative sortOrders; ids unrelated to that order.
    private func makeDocumentOrder(rowCount: Int, rng: inout TombstoneSeededGenerator) -> RowList {
        var usedIds: Set<String> = []
        var rows: RowList = []
        var sortOrder = Double.random(in: -50...50, using: &rng)
        for _ in 0..<rowCount {
            var id = "r" + String(UInt32.random(in: 0...UInt32.max, using: &rng), radix: 16)
            while usedIds.contains(id) { id += "x" }
            usedIds.insert(id)
            rows.append((id, sortOrder))
            sortOrder += Double.random(in: 0.25...20, using: &rng)
        }
        return rows
    }

    /// The other project's rows, about half of them at exactly the same sortOrder as one of mine.
    private func makeOtherProjectRows(among documentOrder: RowList, rng: inout TombstoneSeededGenerator) -> RowList {
        let low = documentOrder[0].sortOrder - 5
        let high = documentOrder[documentOrder.count - 1].sortOrder + 5
        var rows: RowList = []
        for index in 0..<Int.random(in: 0...20, using: &rng) {
            let order = Bool.random(using: &rng)
                ? documentOrder[Int.random(in: 0..<documentOrder.count, using: &rng)].sortOrder
                : Double.random(in: low...high, using: &rng)
            rows.append(("o\(index)", order))
        }
        return rows
    }

    /// The delete set: a sparse, half or dense random pick, one run of neighbours, or everything.
    private func makeDeleteSet(from documentOrder: RowList, rng: inout TombstoneSeededGenerator) -> (ids: Set<String>, mode: String) {
        let picks: [(mode: String, chance: Double)] = [("sparse", 0.1), ("half", 0.5), ("dense", 0.9)]
        let kind = Int.random(in: 0..<5, using: &rng)
        if kind < picks.count {
            var ids: Set<String> = []
            for row in documentOrder where Double.random(in: 0..<1, using: &rng) < picks[kind].chance { ids.insert(row.id) }
            return (ids, picks[kind].mode)
        }
        if kind == picks.count {
            let start = Int.random(in: 0..<documentOrder.count, using: &rng)
            let length = Int.random(in: 1...(documentOrder.count - start), using: &rng)
            return (Set(documentOrder[start..<(start + length)].map(\.id)), "one-run")
        }
        return (Set(documentOrder.map(\.id)), "everything")
    }

    private func makeScenario(seed: UInt64) -> Scenario {
        var rng = TombstoneSeededGenerator(seed: seed)
        let rowCount = Int.random(in: 1...60, using: &rng)
        let documentOrder = makeDocumentOrder(rowCount: rowCount, rng: &rng)
        let others = makeOtherProjectRows(among: documentOrder, rng: &rng)
        let picked = makeDeleteSet(from: documentOrder, rng: &rng)
        var deleted = picked.ids
        // Sometimes an id with no row, which the old walk answered with "start of document".
        if Int.random(in: 0..<4, using: &rng) == 0 { deleted.insert("ghost-\(seed)") }
        return Scenario(seed: seed, mine: documentOrder.shuffled(using: &rng), others: others, deleted: deleted, mode: picked.mode)
    }

    @Test("For 300 random layouts and delete sets, one read gives exactly the old one-query-per-step result")
    func oneReadMatchesTheOldWalkForRandomDeleteSets() throws {
        let stack = try makeStack()
        var comparedRows = 0
        for seed in UInt64(1)...300 {
            let scenario = makeScenario(seed: seed)
            try seedRows(stack, mine: scenario.mine, others: scenario.others)
            let (oneRead, oldWalk) = try stack.db.dbWriter.read { database in
                (
                    try FootnoteSyncService.resolveTombstoneChain(
                        db: database, projectId: stack.pid, deletedIds: scenario.deleted),
                    try FootnoteSyncService.resolveTombstoneChainOneQueryPerStep(
                        db: database, projectId: stack.pid, deletedIds: scenario.deleted)
                )
            }
            comparedRows += scenario.deleted.count
            if oneRead != oldWalk {
                let differing = oldWalk.keys.sorted().filter { oneRead[$0] != oldWalk[$0] }.prefix(3)
                    .map { "\($0): one read \(String(describing: oneRead[$0])) vs old walk \(String(describing: oldWalk[$0]))" }
                Issue.record(
                    """
                    one-pass tombstone result differs from the one-query-per-step walk — seed=\(seed) mode=\(scenario.mode) \
                    rows=\(scenario.mine.count) deleted=\(scenario.deleted.count); first differences: \(differing)
                    """)
                return
            }
        }
        #expect(comparedRows > 1000, "the sweep must actually compare many deleted rows, compared \(comparedRows)")
    }

    // MARK: - 3. One read for 300 neighbours

    @Test("300 neighbouring deleted rows are resolved with ONE read of the block table; the old walk ran N*(N+1)/2")
    func threeHundredNeighboursReadTheTableOnce() throws {
        let stack = try makeStack()

        /// `survivorsBefore` rows that stay, then `neighbours` deleted rows side by side, then 20 more that stay.
        func seedRun(neighbours: Int, survivorsBefore: Int) throws -> (deleted: Set<String>, lastSurvivorBefore: String) {
            var rows: [(id: String, sortOrder: Double)] = []
            for index in 0..<(survivorsBefore + neighbours + 20) { rows.append((String(format: "row-%04d", index), Double(index + 1) * 2)) }
            var shuffler = TombstoneSeededGenerator(seed: 7)
            try seedRows(stack, mine: rows.shuffled(using: &shuffler), others: [])
            let deleted = Set(rows[survivorsBefore..<(survivorsBefore + neighbours)].map(\.id))
            return (deleted, rows[survivorsBefore - 1].id)
        }

        /// The SELECTs of the block table a call ran. GRDB's own schema introspection (`PRAGMA ...`) is not a read of the project.
        func blockSelects(_ log: TombstoneStatementLog) -> [String] {
            log.all.filter { $0.hasPrefix("SELECT") && $0.contains("FROM block") }
        }

        // The new version, 300 neighbours.
        let big = try seedRun(neighbours: 300, survivorsBefore: 20)
        let newLog = TombstoneStatementLog()
        let result = try stack.db.dbWriter.read { database -> [String: DeletedAnchor] in
            database.trace(options: .statement) { event in
                if case .statement(let statement) = event { newLog.record(statement.sql) }
            }
            defer { database.trace(options: []) }
            return try FootnoteSyncService.resolveTombstoneChain(db: database, projectId: stack.pid, deletedIds: big.deleted)
        }
        #expect(blockSelects(newLog).count == 1, "one read of the block table for 300 neighbours (the old walk ran 45,150): \(newLog.all)")
        #expect(result.count == 300, "every one of the 300 deleted rows has an anchor, got \(result.count)")
        #expect(
            result.values.allSatisfy { $0 == .after(big.lastSurvivorBefore) },
            "all 300 neighbours stood after the same surviving row, \(big.lastSurvivorBefore)")

        // Nothing to resolve: the database is not touched at all.
        let emptyLog = TombstoneStatementLog()
        let emptyResult = try stack.db.dbWriter.read { database -> [String: DeletedAnchor] in
            database.trace(options: .statement) { event in
                if case .statement(let statement) = event { emptyLog.record(statement.sql) }
            }
            defer { database.trace(options: []) }
            return try FootnoteSyncService.resolveTombstoneChain(db: database, projectId: stack.pid, deletedIds: [])
        }
        #expect(emptyResult.isEmpty)
        #expect(blockSelects(emptyLog).isEmpty, "an empty set reads nothing: \(emptyLog.all)")

        // The control: the probe does see the old walk's per-step queries -- 40 neighbours cost 40 * 41 / 2 = 820 of them.
        let small = try seedRun(neighbours: 40, survivorsBefore: 5)
        let oldLog = TombstoneStatementLog()
        let oldResult = try stack.db.dbWriter.read { database -> [String: DeletedAnchor] in
            database.trace(options: .statement) { event in
                if case .statement(let statement) = event { oldLog.record(statement.sql) }
            }
            defer { database.trace(options: []) }
            return try FootnoteSyncService.resolveTombstoneChainOneQueryPerStep(
                db: database, projectId: stack.pid, deletedIds: small.deleted)
        }
        #expect(blockSelects(oldLog).count >= 40 * 41 / 2, "the old walk read the block table once per step: \(blockSelects(oldLog).count)")
        #expect(oldResult.values.allSatisfy { $0 == .after(small.lastSurvivorBefore) })
    }
}
