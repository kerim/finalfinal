//
//  AnnotationSyncOffMainTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  The annotation sync's database write must not block the main thread. A stack sample of the main thread after a section
//  delete on the twelve-chapter book showed it parked for about 2.5 seconds inside `AnnotationSyncService.syncContent`'s
//  synchronous `applyAnnotationChanges`, waiting for the database's one writer, which the delete's own background job held.
//  While it waited the window was frozen: the removal was not painted and typing was not echoed.
//
//  The write now runs off the main thread and is awaited. These tests hold the database's writer busy from a background
//  thread (the same thing a long delete or restore does) and check three things:
//   1. the main actor stays free while a sync's write waits (the bug; fails on the old code),
//   2. syncs still run one after the other, never overlapping, now that a sync has a suspension point (pins the chain),
//   3. a started sync finishes against the database it was queued for.
//

import Testing
import Foundation
import os
import GRDB
@testable import final_final

/// Holds a project database's one writer busy from a background thread until `release()` is called.
/// `releaseAfter(seconds:)` is the safety net for a failing run: the old, blocking code would otherwise never return.
private final class HeldWriter: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let released = OSAllocatedUnfairLock(initialState: false)

    /// Takes the writer on a background thread and returns once it is really held.
    func hold(_ db: ProjectDatabase) async {
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { [gate] in
                _ = try? db.dbWriter.write { _ in
                    held.resume()
                    gate.wait()
                }
            }
        }
    }

    var isReleased: Bool { released.withLock { $0 } }

    /// Lets the held write finish. Safe to call more than once.
    func release() {
        let firstCall = released.withLock { wasReleased -> Bool in
            defer { wasReleased = true }
            return !wasReleased
        }
        if firstCall { gate.signal() }
    }

    func releaseAfter(seconds: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in release() }
    }
}

/// Records, per committed transaction, the kinds of row change made to the `annotation` table.
/// Two syncs that did not overlap leave `[["insert"], ["update", "insert"]]`; two that read the same stale rows leave
/// `[["insert"], ["insert", "insert"]]`.
private final class AnnotationCommitSpy: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var committed: [[String]] = []

    var commits: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return committed
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == "annotation"
    }

    func databaseDidChange(with event: DatabaseEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event.kind {
        case .insert: pending.append("insert")
        case .update: pending.append("update")
        case .delete: pending.append("delete")
        }
    }

    func databaseDidCommit(_ db: Database) {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty { committed.append(pending) }
        pending = []
    }

    func databaseDidRollback(_ db: Database) {
        lock.lock()
        defer { lock.unlock() }
        pending = []
    }
}

/// What concurrent main-actor tasks saw as they finished, in the order they finished.
@MainActor
private final class FinishLog {
    var entries: [String] = []
    var writerReleasedWhenSecondReturned = false
    var rowsWhenSecondReturned: [String] = []
}

// `.serialized`: Swift Testing runs suites in parallel inside one process, and these tests depend on the main actor
// getting to run while a writer is held. A busy full-suite run must not starve them into tripping the safety net.
@Suite("Annotation Sync — Tier 1: database write stays off the main thread", .serialized)
@MainActor
struct AnnotationSyncOffMainTests {

    // MARK: - Helpers

    /// How long the safety-net timer waits before freeing a held writer. Only a failing run (the old, blocking code)
    /// ever waits this long; a passing run releases the writer itself, long before. Generous so that a loaded machine
    /// cannot trip it while the main actor is merely slow to get scheduled.
    private static let safetyNetSeconds = 30.0

    private func contentId(_ db: ProjectDatabase) throws -> String {
        try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM content LIMIT 1")!
        }
    }

    /// A temporary project database and an annotation sync service configured for it.
    private struct Rig {
        let db: ProjectDatabase
        let contentId: String
        let service: AnnotationSyncService
    }

    private func makeRig(markdown: String) throws -> Rig {
        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let cid = try contentId(db)
        let service = AnnotationSyncService()
        service.configure(database: db, contentId: cid)
        return Rig(db: db, contentId: cid, service: service)
    }

    /// Lets every task already scheduled on the main actor run up to its next suspension point.
    private func letScheduledTasksRun() async {
        for _ in 0..<3 { await Task.yield() }
    }

    private func rows(_ db: ProjectDatabase, _ cid: String) throws -> [String] {
        try db.fetchAnnotations(contentId: cid)
            .filter { !$0.isDocumentLevel }
            .sorted { $0.charOffset < $1.charOffset }
            .map { "\($0.type.rawValue)|\($0.text)|\($0.charOffset)" }
    }

    private func described(_ markdown: String, by service: AnnotationSyncService) -> [String] {
        service.parseAnnotations(from: markdown).map { "\($0.type.rawValue)|\($0.text)|\($0.charOffset)" }
    }

    // MARK: - U1: the main actor stays free while the writer is busy

    /// MUST FAIL on the old code: there `syncContent` called `applyAnnotationChanges` synchronously, so the main thread
    /// parked inside `ProjectDatabase.write` until the writer was free; the probe below could only run after the safety
    /// net released the writer, and sees `writerReleased == true`.
    @Test("a sync waiting for a busy database writer leaves the main actor free, then applies the annotations")
    func syncLeavesMainActorFreeWhileWriterIsBusy() async throws {
        let markdown = "<!-- ::comment:: alpha -->\n\nSome text.\n\n<!-- ::task:: [ ] beta -->"
        let rig = try makeRig(markdown: markdown)
        let (db, cid, service) = (rig.db, rig.contentId, rig.service)
        let expected = described(markdown, by: service)
        #expect(expected.count == 2, "the fixture markdown must describe two annotations")

        let writer = HeldWriter()
        await writer.hold(db)
        writer.releaseAfter(seconds: Self.safetyNetSeconds)

        let sync = Task { await service.syncNow(markdown) }
        // The sync runs now, as far as its first suspension. On the old code that is the whole sync: it parks the main
        // thread here, in the database write, until the safety net frees the writer.
        await letScheduledTasksRun()

        // A main-actor task scheduled after the sync call. It must run while the writer is still held.
        let writerReleasedWhenMainActorRan = await Task { @MainActor in writer.isReleased }.value
        #expect(
            !writerReleasedWhenMainActorRan,
            "the main actor only got to run again after the database writer was freed: the sync blocked the main thread")

        #expect(try rows(db, cid).isEmpty, "nothing can be written while the writer is held")

        writer.release()
        await sync.value
        #expect(try rows(db, cid) == expected, "after the writer is free the sync must have applied the annotations")
    }

    // MARK: - U2: syncs never overlap

    /// Passes on the old code (every sync was atomic on the main actor) and pins the new chain: without it, the second
    /// sync reads the annotation rows before the first one's write has landed, so it inserts the second markdown's
    /// annotations next to the first markdown's instead of updating them.
    @Test("two syncs queued behind a busy writer run one after the other and leave exactly the second markdown's rows")
    func twoSyncsQueuedBehindBusyWriterDoNotOverlap() async throws {
        let first = "<!-- ::comment:: alpha -->"
        let second = "<!-- ::comment:: alpha two -->\n\n<!-- ::task:: [ ] beta -->"
        let rig = try makeRig(markdown: first)
        let (db, cid, service) = (rig.db, rig.contentId, rig.service)
        let expected = described(second, by: service)
        #expect(expected.count == 2)

        let spy = AnnotationCommitSpy()
        db.dbWriter.add(transactionObserver: spy)

        let writer = HeldWriter()
        await writer.hold(db)
        writer.releaseAfter(seconds: Self.safetyNetSeconds)

        let firstSync = Task { await service.syncNow(first) }
        let secondSync = Task { await service.syncNow(second) }
        await letScheduledTasksRun()
        #expect(try rows(db, cid).isEmpty, "both syncs are waiting; nothing is written while the writer is held")

        writer.release()
        await firstSync.value
        await secondSync.value

        #expect(try rows(db, cid) == expected, "exactly the rows the second markdown describes, no duplicates")
        #expect(
            spy.commits == [["insert"], ["update", "insert"]],
            "the second sync must read the rows the first one wrote (update alpha, insert beta), not start from an empty table; got \(spy.commits)")
        withExtendedLifetime(spy) {}
    }

    // MARK: - U3: syncNow waits for the sync already in flight

    /// `syncNow` is the awaited "before quit / before close" entry. The sync in flight here is itself started with
    /// `syncNow`: a debounced sync reaches the same private `syncContent`, and a debounced one cannot be seen in flight
    /// without a sleep.
    @Test("syncNow while another sync is in flight returns only after both are done")
    func syncNowWaitsForTheSyncAlreadyInFlight() async throws {
        let first = "<!-- ::comment:: alpha -->"
        let second = "<!-- ::comment:: alpha two -->\n\n<!-- ::task:: [ ] beta -->"
        let rig = try makeRig(markdown: first)
        let (db, cid, service) = (rig.db, rig.contentId, rig.service)
        let expected = described(second, by: service)

        let writer = HeldWriter()
        await writer.hold(db)
        writer.releaseAfter(seconds: Self.safetyNetSeconds)

        let log = FinishLog()
        let firstSync = Task {
            await service.syncNow(first)
            log.entries.append("first")
        }
        let secondSync = Task {
            await service.syncNow(second)
            log.writerReleasedWhenSecondReturned = writer.isReleased
            log.rowsWhenSecondReturned = (try? self.rows(db, cid)) ?? ["read failed"]
            log.entries.append("second")
        }
        await letScheduledTasksRun()
        #expect(log.entries.isEmpty, "neither sync can finish while the writer is held")

        writer.release()
        await firstSync.value
        await secondSync.value

        #expect(log.writerReleasedWhenSecondReturned, "syncNow returned while the writer was still held")
        #expect(
            log.rowsWhenSecondReturned == expected,
            "when syncNow returned, the sync in flight and its own sync must both be written; got \(log.rowsWhenSecondReturned)")
        #expect(log.entries == ["first", "second"], "the syncs finish in the order they were started")
    }

    // MARK: - U4: cancelPendingSync leaves a started sync, and its place in the chain, alone

    /// `cancelPendingSync()` is what the close and project-switch tails call (`stopContentServicesForLifecycle`) while a
    /// sync may be waiting for its write. It must cancel the debounce timer and nothing else: the started sync stays in
    /// the chain, so the next sync still waits for its write instead of reading the rows before they landed.
    ///
    /// The Task running the started sync is cancelled too, as the real caller (a debounce task) is when a new edit
    /// arrives. That cancellation alone cannot make a test fail: nothing in the sync path observes cancellation and the
    /// write is detached, so it is the same with or without the unstructured chain task. It is kept only to mirror the
    /// real caller.
    ///
    /// Fails if `cancelPendingSync()` drops the chain, for example a `syncChain = nil` added beside `debounceTask = nil`:
    /// the second sync then starts at once with nothing to wait for, reads the still-empty table and inserts its rows
    /// next to the first sync's (three rows, commits `[["insert"], ["insert", "insert"]]`).
    @Test("cancelPendingSync does not stop a started sync or drop its place: the next sync still waits for its write")
    func cancelPendingSyncLeavesAStartedSyncAlone() async throws {
        let first = "<!-- ::comment:: alpha -->"
        let second = "<!-- ::comment:: alpha two -->\n\n<!-- ::task:: [ ] beta -->"
        let rig = try makeRig(markdown: first)
        let (db, cid, service) = (rig.db, rig.contentId, rig.service)
        let expected = described(second, by: service)

        let spy = AnnotationCommitSpy()
        db.dbWriter.add(transactionObserver: spy)

        let writer = HeldWriter()
        await writer.hold(db)
        writer.releaseAfter(seconds: Self.safetyNetSeconds)

        let firstSync = Task { await service.syncNow(first) }
        await letScheduledTasksRun()
        service.cancelPendingSync()
        firstSync.cancel()

        // The next sync arrives after the cancel, while the first one's write is still waiting for the writer.
        let secondSync = Task { await service.syncNow(second) }
        await letScheduledTasksRun()
        #expect(try rows(db, cid).isEmpty, "both syncs are waiting; nothing is written while the writer is held")

        writer.release()
        await firstSync.value
        await secondSync.value

        #expect(try rows(db, cid) == expected, "the first sync's write landed and the second one built on it")
        #expect(
            spy.commits == [["insert"], ["update", "insert"]],
            "the second sync must wait for the first one's write (then update alpha, insert beta); got \(spy.commits)")
        withExtendedLifetime(spy) {}
    }

    // MARK: - U5: a queued sync writes to the database it was queued for

    /// The second sync is still waiting behind the first (it has not started) when the project is switched. It must
    /// still write to the database that was configured when it was called, not to the new one.
    ///
    /// Fails if `syncContent` reads `projectDatabase` and `contentId` after `await previous?.value` (inside the chained
    /// task or `performSync`) instead of capturing them at the top, before queueing: the second sync would then fetch
    /// from and insert into the new database, leaving the old one with only the first sync's row.
    @Test("a sync waiting behind another when the project is switched still writes to the old project's database")
    func queuedSyncWritesToTheDatabaseItWasQueuedFor() async throws {
        let first = "<!-- ::comment:: alpha -->"
        let second = "<!-- ::comment:: alpha two -->\n\n<!-- ::task:: [ ] beta -->"
        let rig = try makeRig(markdown: first)
        let (oldDb, oldCid, service) = (rig.db, rig.contentId, rig.service)
        let expected = described(second, by: service)
        let newDb = try TestFixtureFactory.createTemporary(content: "Other project.")
        let newCid = try contentId(newDb)

        let writer = HeldWriter()
        await writer.hold(oldDb)
        writer.releaseAfter(seconds: Self.safetyNetSeconds)

        let firstSync = Task { await service.syncNow(first) }
        let secondSync = Task { await service.syncNow(second) }
        await letScheduledTasksRun()
        #expect(try rows(oldDb, oldCid).isEmpty, "both syncs are waiting; nothing is written while the writer is held")

        // The switch comes while the second sync is queued behind the first.
        service.configure(database: newDb, contentId: newCid)

        writer.release()
        await firstSync.value
        await secondSync.value
        #expect(
            try rows(oldDb, oldCid) == expected,
            "both syncs belong to the old project: the second must have written to the old database")
        #expect(try rows(newDb, newCid).isEmpty, "the new project's database must not receive the old project's annotations")
    }
}
