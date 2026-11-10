//
//  OutlineObservationTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Guards the commit signal that tells the Outline sidebar's reader (`OutlineSnapshotPublisher`) to take a new snapshot:
//  `ProjectDatabase.observeBlockCommits`, a GRDB region observation on the whole `block` table.
//
//  Background (this file used to guard `observeOutlineBlocks` against `.removeDuplicates()`): the outline rows are headings and
//  section breaks, but the sidebar derives each section's word total from the BODY blocks' `wordCount`. A signal that only
//  fired for a change to a heading row would freeze the sidebar's word counts at their open-time values. The signal is
//  therefore table-wide and is not deduplicated. See `docs/lessons/grdb-database.md` §"removeDuplicates() Suppresses
//  Derived-Data Updates".
//

import Testing
import Foundation
import GRDB
import Synchronization
@testable import final_final

@Suite("Outline Observation — Tier 1: Silent Killers")
struct OutlineObservationTests {

    // MARK: - Fixture

    private func makeDoc() -> String {
        return """
        # Only Section

        One two three four five.
        """
    }

    /// Counts commit signals. The signal runs on GRDB's writer queue, so the count is behind a lock.
    private final class SignalCounter: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func increment() { value.withLock { $0 += 1 } }

        /// Polls until `count >= target`; false if `timeout` passes first.
        func waitUntil(count target: Int, timeout: Duration = .seconds(3)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while count < target {
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return true
        }
    }

    private func startCounting(_ db: ProjectDatabase) -> (SignalCounter, AnyDatabaseCancellable) {
        let counter = SignalCounter()
        let cancellable = db.observeBlockCommits { counter.increment() }
        return (counter, cancellable)
    }

    // MARK: - Guardrail Test

    @Test("A body-only paragraph edit signals a commit (GUARDRAIL)")
    @MainActor
    func bodyEditSignalsACommit() async throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        guard var paragraph = try TestFixtureFactory.fetchBlocks(from: db).first(where: { $0.blockType == .paragraph }) else {
            Issue.record("Fixture must contain at least one paragraph"); return
        }
        let (counter, cancellable) = startCounting(db)
        defer { cancellable.cancel() }

        // Body-only edit: change a paragraph. Heading rows do not change.
        paragraph.textContent += " extra words appended here"
        paragraph.recalculateWordCount()
        paragraph.updatedAt = Date()
        try db.write { database in
            try paragraph.update(database)
        }

        let signalled = await counter.waitUntil(count: 1)
        #expect(
            signalled,
            """
            No commit signal after a body-only edit. The outline's word counts come from body blocks, so the signal must be
            table-wide (Database+BlocksObservation.swift); see docs/lessons/grdb-database.md.
            """
        )
    }

    // MARK: - Positive Baselines

    @Test("A heading-text edit signals a commit")
    @MainActor
    func headingEditSignalsACommit() async throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        guard var heading = try TestFixtureFactory.fetchBlocks(from: db).first(where: { $0.blockType == .heading }) else {
            Issue.record("Fixture must contain at least one heading"); return
        }
        let (counter, cancellable) = startCounting(db)
        defer { cancellable.cancel() }

        heading.textContent = "Renamed Heading"
        heading.recalculateWordCount()
        heading.updatedAt = Date()
        try db.write { database in
            try heading.update(database)
        }

        #expect(await counter.waitUntil(count: 1), "Heading edits must signal")
    }

    @Test("A metadata write on a heading signals a commit (covers the updateSection path)")
    @MainActor
    func metadataWriteOnHeadingSignalsACommit() async throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        guard var heading = try TestFixtureFactory.fetchBlocks(from: db).first(where: { $0.blockType == .heading }) else {
            Issue.record("Fixture must contain at least one heading"); return
        }
        let (counter, cancellable) = startCounting(db)
        defer { cancellable.cancel() }

        // A non-text metadata column: the `updateSection` shape (status / goals / tags on heading blocks), which does NOT go
        // through the DocumentWriter.
        heading.status = .review
        heading.updatedAt = Date()
        try db.write { database in
            try heading.update(database)
        }

        #expect(await counter.waitUntil(count: 1), "Metadata writes on heading blocks must signal")
    }

    // MARK: - Negative Cases

    private struct Rollback: Error {}

    @Test("A write that is rolled back does not signal")
    @MainActor
    func rolledBackWriteDoesNotSignal() async throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        guard var heading = try TestFixtureFactory.fetchBlocks(from: db).first(where: { $0.blockType == .heading }) else {
            Issue.record("Fixture must contain at least one heading"); return
        }
        let (counter, cancellable) = startCounting(db)
        defer { cancellable.cancel() }

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
        #expect(counter.count == 0, "A rolled-back transaction must not reach the sidebar")

        // The signal still works afterwards.
        heading.textContent = "Committed"
        try db.write { database in
            try heading.update(database)
        }
        #expect(await counter.waitUntil(count: 1))
    }

    @Test("A write to another table does not signal")
    @MainActor
    func otherTableDoesNotSignal() async throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let (counter, cancellable) = startCounting(db)
        defer { cancellable.cancel() }

        try db.write { database in
            try database.execute(sql: "UPDATE project SET title = 'Renamed project'")
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == 0)
    }

    @Test("A cancelled observation never signals again")
    @MainActor
    func cancelledObservationStaysQuiet() async throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        guard var heading = try TestFixtureFactory.fetchBlocks(from: db).first(where: { $0.blockType == .heading }) else {
            Issue.record("Fixture must contain at least one heading"); return
        }
        let (counter, cancellable) = startCounting(db)
        cancellable.cancel()

        heading.textContent = "After cancel"
        try db.write { database in
            try heading.update(database)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == 0)
    }
}
