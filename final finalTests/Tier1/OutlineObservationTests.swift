//
//  OutlineObservationTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Guards `observeOutlineBlocks` against the `.removeDuplicates()` regression.
//  The tracking closure returns only heading + pseudo-section rows, but the
//  downstream sidebar derives per-section word counts from body blocks via
//  `batchWordCounts`. A naive `.removeDuplicates()` here would suppress
//  re-emission on body-only edits — exactly the bug this file exists to prevent.
//
//  Background: `.removeDuplicates()` has been add→remove→add→remove across
//  four commits. See `docs/lessons/grdb-database.md` §"removeDuplicates()
//  Suppresses Derived-Data Updates" and the comment at the top of
//  `Database+BlocksObservation.swift`.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Outline Observation — Tier 1: Silent Killers")
struct OutlineObservationTests {

    // MARK: - Fixture

    /// Simple doc with one heading and one paragraph so a body-only edit is
    /// unambiguous and the signature change is easy to verify.
    private func makeDoc() -> String {
        return """
        # Only Section

        One two three four five.
        """
    }

    // MARK: - Helpers

    /// Signature that captures derived-data state: sum of every block's
    /// stored `wordCount` for the given project. Body edits change this sum
    /// even though heading rows don't — so a dedup scheme that compares
    /// fetched heading rows would incorrectly suppress an emission that
    /// should surface this change.
    private func bodyWordCountSum(_ db: ProjectDatabase, _ projectId: String) throws -> Int {
        try db.read { database in
            try Int.fetchOne(database, sql: """
                SELECT COALESCE(SUM(wordCount), 0)
                FROM block
                WHERE projectId = ?
                """, arguments: [projectId]) ?? 0
        }
    }

    /// Actor-backed emission collector. A background Task drains the stream
    /// into this array; the test polls `count` with a deadline so a
    /// suppressed emission fails loudly rather than hanging CI.
    private actor EmissionCollector {
        private(set) var count: Int = 0
        func increment() { count += 1 }

        /// Busy-wait (with small sleep) until `count >= target`. Returns
        /// true if the target was reached within `timeout`, false otherwise.
        func waitUntil(count target: Int, timeout: Duration = .seconds(3)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while count < target {
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return true
        }
    }

    /// Start a background Task that drains `stream` into `collector`.
    /// Returns the Task so the caller can cancel it when the test ends.
    private func startCollecting(
        _ stream: AsyncThrowingStream<[Block], Error>,
        into collector: EmissionCollector
    ) -> Task<Void, Never> {
        Task.detached {
            do {
                for try await _ in stream {
                    await collector.increment()
                }
            } catch {
                // Stream terminated via cancellation or error; fine.
            }
        }
    }

    // MARK: - Guardrail Test

    @Test("Body-only paragraph edit re-emits on observeOutlineBlocks (GUARDRAIL)")
    @MainActor
    func bodyEditReEmits() async throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let initialBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard var paragraph = initialBlocks.first(where: { $0.blockType == .paragraph }) else {
            Issue.record("Fixture must contain at least one paragraph"); return
        }

        let collector = EmissionCollector()
        let stream = db.observeOutlineBlocks(for: pid)
        let collectTask = startCollecting(stream, into: collector)
        defer { collectTask.cancel() }

        // Handshake: wait for the initial emission so the observer is
        // definitely attached before we write.
        let gotFirst = await collector.waitUntil(count: 1)
        #expect(gotFirst, "Initial emission must arrive (observer not attached)")
        let firstSignature = try bodyWordCountSum(db, pid)

        // Body-only edit: change a paragraph. Heading rows do not change.
        paragraph.textContent += " extra words appended here"
        paragraph.recalculateWordCount()
        paragraph.updatedAt = Date()
        try db.write { database in
            try paragraph.update(database)
        }

        // Second emission must arrive. If `.removeDuplicates()` is present
        // on `observeOutlineBlocks`, this times out at 3s and `gotSecond` is
        // false.
        let gotSecond = await collector.waitUntil(count: 2)
        #expect(
            gotSecond,
            """
            observeOutlineBlocks did not re-emit after a body-only edit.
            This almost always means `.removeDuplicates()` was added to the
            observation in Database+BlocksObservation.swift — see the comment
            at the top of that file and docs/lessons/grdb-database.md.
            """
        )

        let secondSignature = try bodyWordCountSum(db, pid)
        #expect(
            secondSignature != firstSignature,
            "Derived wordCount sum must differ after a body edit"
        )
    }

    // MARK: - Positive Baseline

    @Test("Heading-text edit re-emits (positive baseline)")
    @MainActor
    func headingEditReEmits() async throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let initialBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard var heading = initialBlocks.first(where: { $0.blockType == .heading }) else {
            Issue.record("Fixture must contain at least one heading"); return
        }

        let collector = EmissionCollector()
        let stream = db.observeOutlineBlocks(for: pid)
        let collectTask = startCollecting(stream, into: collector)
        defer { collectTask.cancel() }

        let gotFirst = await collector.waitUntil(count: 1)
        #expect(gotFirst)

        heading.textContent = "Renamed Heading"
        heading.recalculateWordCount()
        heading.updatedAt = Date()
        try db.write { database in
            try heading.update(database)
        }

        let gotSecond = await collector.waitUntil(count: 2)
        #expect(gotSecond, "Heading edits must emit (this would fail only if the observation itself is broken)")
    }

    // MARK: - Metadata Path

    @Test("Metadata write on a heading re-emits (covers updateSection path)")
    @MainActor
    func metadataWriteOnHeadingReEmits() async throws {
        let db = try TestFixtureFactory.createTemporary(content: makeDoc())
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let initialBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard var heading = initialBlocks.first(where: { $0.blockType == .heading }) else {
            Issue.record("Fixture must contain at least one heading"); return
        }

        let collector = EmissionCollector()
        let stream = db.observeOutlineBlocks(for: pid)
        let collectTask = startCollecting(stream, into: collector)
        defer { collectTask.cancel() }

        let gotFirst = await collector.waitUntil(count: 1)
        #expect(gotFirst)

        // Change a non-text metadata column. This is the `updateSection`
        // shape — status / goals / tags on heading blocks.
        heading.status = .review
        heading.updatedAt = Date()
        try db.write { database in
            try heading.update(database)
        }

        let gotSecond = await collector.waitUntil(count: 2)
        #expect(gotSecond, "Metadata writes on heading blocks must emit")
    }
}
