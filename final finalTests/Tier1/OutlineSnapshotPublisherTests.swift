//
//  OutlineSnapshotPublisherTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Phase 6 (numbered sidebar snapshots). The publisher is the ONE reader of the Outline sidebar's data: it numbers every reading
//  in the order the reads are made, reads the heading rows and their word counts in one transaction, and never loses a commit
//  or leaves a caller waiting. The sidebar side (which snapshot is shown) is in `OutlineRefreshStalenessTests`.
//

import Testing
import Foundation
import GRDB
import Synchronization
@testable import final_final

@Suite("Outline Snapshot Publisher — Tier 1: Silent Killers")
struct OutlineSnapshotPublisherTests {

    // MARK: - Helpers

    /// Collects the snapshots from `publisher.ticks`.
    private final class TickCollector: Sendable {
        private let items = Mutex<[OutlineSnapshot]>([])
        var all: [OutlineSnapshot] { items.withLock { $0 } }
        func append(_ snapshot: OutlineSnapshot) { items.withLock { $0.append(snapshot) } }

        /// Polls until `predicate` holds for the snapshots collected so far; false if `timeout` passes first.
        func wait(timeout: Duration = .seconds(5), until predicate: @Sendable ([OutlineSnapshot]) -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while !predicate(all) {
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }
    }

    private func collect(_ publisher: OutlineSnapshotPublisher) -> (TickCollector, Task<Void, Never>) {
        let collector = TickCollector()
        let task = Task.detached {
            for await snapshot in publisher.ticks { collector.append(snapshot) }
        }
        return (collector, task)
    }

    private func makeDatabase(_ content: String = "# Only Section\n\nOne two three four five.") throws -> (ProjectDatabase, String) {
        let db = try TestFixtureFactory.createTemporary(content: content)
        return (db, try TestFixtureFactory.getProjectId(from: db))
    }

    private func headingBlock(in db: ProjectDatabase) throws -> Block {
        try #require(try TestFixtureFactory.fetchBlocks(from: db).first(where: { $0.blockType == .heading }))
    }

    private struct Rollback: Error {}

    // MARK: - Numbers

    @Test("Numbers strictly increase and are never reused")
    func numbersIncreaseAndAreNeverReused() async throws {
        let (db, pid) = try makeDatabase()
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: false)
        var revs: [Int] = []
        for _ in 0..<5 {
            revs.append(try #require(await publisher.snapshotNow()).rev)
        }
        #expect(revs == [1, 2, 3, 4, 5])
        #expect(publisher.lastAssignedRev == 5)
    }

    @Test("Callers that arrive together all get a snapshot, and a number is never reused for different readings")
    func concurrentCallersAllGetASnapshot() async throws {
        let (db, pid) = try makeDatabase()
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: false)
        let snapshots = await withTaskGroup(of: OutlineSnapshot?.self) { group in
            for _ in 0..<6 { group.addTask { await publisher.snapshotNow() } }
            var all: [OutlineSnapshot?] = []
            for await snapshot in group { all.append(snapshot) }
            return all
        }
        #expect(snapshots.allSatisfy { $0 != nil })
        let revs = Set(snapshots.compactMap(\.?.rev))
        // Callers waiting together share one reading (one number); the numbers are consecutive from 1.
        #expect(revs.min() == 1)
        #expect(revs.max() == revs.count)
        #expect(publisher.lastAssignedRev == revs.count)
    }

    // MARK: - What a reading holds

    @Test("An explicit caller sees a write that finished before the call")
    func explicitCallerSeesAnEarlierWrite() async throws {
        let (db, pid) = try makeDatabase()
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: false)
        #expect(try #require(await publisher.snapshotNow()).blocks.first?.textContent == "Only Section")

        var heading = try headingBlock(in: db)
        heading.textContent = "Renamed"
        heading.markdownFragment = "# Renamed"
        try db.write { try heading.update($0) }

        let second = try #require(await publisher.snapshotNow())
        #expect(second.blocks.first?.textContent == "Renamed")
        #expect(second.rev == 2)
    }

    @Test("One reading carries the heading rows and word counts that agree")
    func blocksAndCountsAgree() async throws {
        let (db, pid) = try makeDatabase("# First\n\nOne two three.\n\n# Second\n\nFour five six seven.")
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: false)
        let snapshot = try #require(await publisher.snapshotNow())
        let headings = snapshot.blocks.filter { $0.blockType == .heading }
        #expect(headings.count == 2)
        #expect(Set(snapshot.counts.keys) == Set(headings.map(\.id)))
        let totalInCounts = snapshot.counts.values.reduce(0) { $0 + $1.sectionOnly }
        let totalInRows = try db.read { database in
            try Int.fetchOne(database, sql: "SELECT COALESCE(SUM(wordCount), 0) FROM block WHERE projectId = ?", arguments: [pid]) ?? 0
        }
        #expect(totalInCounts == totalInRows)
    }

    // MARK: - Commits

    @Test("The first reading of an opened project arrives on the ticks")
    func firstReadingArrives() async throws {
        let (db, pid) = try makeDatabase()
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: true)
        defer { publisher.stop() }
        let (collector, task) = collect(publisher)
        defer { task.cancel() }
        #expect(await collector.wait { !$0.isEmpty })
    }

    @Test("A body-only edit produces a tick whose word counts changed (GUARDRAIL)")
    func bodyEditProducesATick() async throws {
        let (db, pid) = try makeDatabase()
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: true)
        defer { publisher.stop() }
        let (collector, task) = collect(publisher)
        defer { task.cancel() }
        #expect(await collector.wait { !$0.isEmpty })
        let headingId = try headingBlock(in: db).id
        let before = try #require(collector.all.last?.counts[headingId]?.sectionOnly)

        var paragraph = try #require(try TestFixtureFactory.fetchBlocks(from: db).first(where: { $0.blockType == .paragraph }))
        paragraph.textContent += " extra words appended here"
        paragraph.recalculateWordCount()
        paragraph.updatedAt = Date()
        try db.write { try paragraph.update($0) }

        #expect(
            await collector.wait { $0.last?.counts[headingId]?.sectionOnly != before },
            "A body edit must reach the sidebar's word counts; the commit signal must be table-wide, with no deduplication"
        )
    }

    @Test("A status edit made outside the writer produces a tick (the updateSection path)")
    func statusEditOutsideTheWriterProducesATick() async throws {
        let (db, pid) = try makeDatabase()
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: true)
        defer { publisher.stop() }
        let (collector, task) = collect(publisher)
        defer { task.cancel() }
        #expect(await collector.wait { !$0.isEmpty })

        let heading = try headingBlock(in: db)
        try db.updateBlockStatus(id: heading.id, status: .review)

        #expect(await collector.wait { $0.last?.blocks.first(where: { $0.id == heading.id })?.status == .review })
    }

    @Test("A burst of commits is never lost: the last reading shows the last write")
    func burstOfCommitsIsNotLost() async throws {
        let (db, pid) = try makeDatabase()
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: true)
        defer { publisher.stop() }
        let (collector, task) = collect(publisher)
        defer { task.cancel() }
        #expect(await collector.wait { !$0.isEmpty })

        var heading = try headingBlock(in: db)
        for index in 0..<25 {
            heading.textContent = "Title \(index)"
            heading.markdownFragment = "# Title \(index)"
            try db.write { try heading.update($0) }
        }

        #expect(await collector.wait { $0.last?.blocks.first?.textContent == "Title 24" })
        let revs = collector.all.map(\.rev)
        #expect(revs == revs.sorted() && Set(revs).count == revs.count, "numbers on the ticks only go up")
    }

    @Test("A commit that lands while a reading is being made gets one more reading (the dirty flag is cleared BEFORE the read)")
    func commitDuringAReadGetsAnotherReading() async throws {
        let (db, pid) = try makeDatabase()
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // Hold the FIRST reading after it has read and before it is delivered. If the drain cleared its dirty flag after the read
        // instead of before it, the commit made during the hold would be swallowed and no second reading would come.
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: true, afterRead: { rev in
            if rev == 1 {
                held.signal()
                release.wait()
            }
        })
        defer { publisher.stop() }
        let (collector, task) = collect(publisher)
        defer { task.cancel() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                held.wait()
                continuation.resume()
            }
        }
        // The first reading has been made (it shows the old title) and is held. Commit a write now.
        var heading = try headingBlock(in: db)
        heading.textContent = "Written during the read"
        heading.markdownFragment = "# Written during the read"
        try db.write { try heading.update($0) }
        release.signal()

        #expect(await collector.wait { $0.last?.blocks.first?.textContent == "Written during the read" })
        #expect(collector.all.first?.blocks.first?.textContent == "Only Section", "the held reading was made before the write")
        #expect(collector.all.map(\.rev) == [1, 2])
    }

    @Test("A rolled-back write produces no tick")
    func rolledBackWriteProducesNoTick() async throws {
        let (db, pid) = try makeDatabase()
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: true)
        defer { publisher.stop() }
        let (collector, task) = collect(publisher)
        defer { task.cancel() }
        #expect(await collector.wait { !$0.isEmpty })
        let countBefore = collector.all.count

        var heading = try headingBlock(in: db)
        heading.textContent = "Never committed"
        do {
            try db.write { database in
                try heading.update(database)
                throw Rollback()
            }
        } catch is Rollback {
            // expected
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(collector.all.count == countBefore)
    }

    // MARK: - Never a hang

    @Test("After stop, a caller gets nothing back at once and the ticks end")
    func stopAnswersCallersAndEndsTicks() async throws {
        let (db, pid) = try makeDatabase()
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: false)
        publisher.stop()
        publisher.stop()   // twice is fine
        #expect(await publisher.snapshotNow() == nil)
        var seen = 0
        for await _ in publisher.ticks { seen += 1 }   // finished: returns
        #expect(seen == 0)
        publisher.noteCommit()   // ignored after stop
        #expect(publisher.lastAssignedRev == 0)
    }

    @Test("Callers waiting when the publisher stops are all answered")
    func stopWhileCallersWaitAnswersThemAll() async throws {
        let (db, pid) = try makeDatabase()
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: false)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = await publisher.snapshotNow() } }
            group.addTask { publisher.stop() }
            await group.waitForAll()   // returns: nobody is left waiting
        }
    }

    @Test("A read that fails answers the caller with nothing and does not hang")
    func failedReadAnswersWithNothing() async throws {
        let (db, pid) = try makeDatabase()
        let publisher = OutlineSnapshotPublisher(database: db, projectId: pid, observesCommits: false)
        try db.write { try $0.execute(sql: "ALTER TABLE block RENAME TO block_gone") }
        #expect(await publisher.snapshotNow() == nil)
        try db.write { try $0.execute(sql: "ALTER TABLE block_gone RENAME TO block") }
        #expect(await publisher.snapshotNow() != nil, "the publisher recovers once the table is back")
    }
}
