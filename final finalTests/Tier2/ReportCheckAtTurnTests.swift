//
//  ReportCheckAtTurnTests.swift
//  final finalTests
//
//  t-25eb1399: a report's stale-snapshot check (a batch that deletes every row and inserts none is refused) reads the rows, so it
//  must run at the report's writer turn, after a section command queued ahead of it has written -- not when the report arrives.
//  Driven through the real intake (`ReportApplier.receive`), the real writer and a real queued system write.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("A report is checked against the rows when its turn comes (t-25eb1399)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ReportCheckAtTurnTests {
    private final class Box { var reserved = false }

    /// Whether the writer has recorded that sequence `seq` is waiting for its turn.
    private func parked(_ recorder: WriterEventRecorder, seq: UInt64) -> Bool {
        recorder.all.contains { if case .parked(let parkedSeq) = $0 { return parkedSeq == seq }; return false }
    }

    @Test("a report that deletes the original chapter, behind a queued Duplicate, is judged after the copy is written and applied")
    func reportBehindQueuedDuplicateIsJudgedAfterIt() async throws {
        let rig = try ReportRig()   // "Alpha.\n\nBravo.\n\nCharlie.": three rows, no Notes, no Bibliography
        let original = try rig.db.fetchBlocks(projectId: rig.pid).map(\.id)
        try #require(original.count > 2, "precondition: the stale-snapshot guard needs more than two rows")
        let writer = try #require(rig.sync.writer)
        let recorder = WriterEventRecorder()
        rig.sync.testWriterEventHandler = { recorder.append($0) }

        // The click's ticket N, still open: holds the queue.
        let hold = try rig.holdWriter()
        // The Duplicate's queued job (N+1): writes the copy's rows when its turn comes.
        let pid = rig.pid
        let maxSort = try rig.db.fetchBlocks(projectId: rig.pid).map(\.sortOrder).max() ?? 0
        let identity = SystemWriteIdentity(projectId: rig.pid, database: rig.db)
        let box = Box()
        let job = Task { @MainActor in
            _ = await rig.sync.performSystemWrite(
                identity: identity, kind: .sectionDuplicate, stillWanted: { true },
                onReserved: { box.reserved = true },
                body: { (database: Database) throws -> SystemWriteBody<Int> in
                    for (index, text) in ["Alpha copy.", "Bravo copy.", "Charlie copy."].enumerated() {
                        var row = Block(projectId: pid, sortOrder: maxSort + Double(index + 1) * 1000, blockType: .paragraph,
                                        textContent: text, markdownFragment: text)
                        try row.insert(database)
                    }
                    return SystemWriteBody(value: 0)
                })
        }
        #expect(await rig.waitUntil(2) { box.reserved }, "precondition: the Duplicate's job holds its place in the queue")

        // The report: the user deleted the whole original chapter; the copy stays in the editor. Its writer sequence is the next
        // one the writer hands out (read here, not assumed from the numbering of the other reservations).
        let reportSeq = writer.nextSequence
        rig.post(1, BlockChanges(deletes: original))
        #expect(writer.nextSequence == reportSeq + 1, "precondition: the report took its place in the queue, behind the job")
        // Either the report was decided at once (the old order: refused on arrival) or it waits for its turn (the new order).
        #expect(await rig.waitUntil(2) { rig.decided() == 1 || parked(recorder, seq: reportSeq) })

        rig.release(hold)
        await job.value
        #expect(await rig.waitUntil { rig.decided() == 1 })

        let rows = try rig.db.fetchBlocks(projectId: rig.pid)
        let left = rows.map(\.id).filter { original.contains($0) }
        #expect(left.isEmpty, """
            the report was judged against the rows as they are after the queued Duplicate wrote its copy: \
            the whole original chapter is deleted (still there: \(left.count) of \(original.count) rows)
            """)
        #expect(Set(rows.map(\.markdownFragment)) == ["Alpha copy.", "Bravo copy.", "Charlie copy."], "only the copy is left")
        #expect(writer.ledger.discardedAfterFetch == 0, "the report was not discarded as a stale snapshot")
    }

    @Test("a report that deletes every row the database holds, with nothing queued ahead of it, is still refused at its turn")
    func aStaleShapedReportIsStillRefusedAtItsTurn() async throws {
        let rig = try ReportRig()   // three rows, no Notes, no Bibliography
        let original = try rig.db.fetchBlocks(projectId: rig.pid).map(\.id)
        try #require(original.count > 2, "precondition: the stale-snapshot guard needs more than two rows")
        let writer = try #require(rig.sync.writer)

        // The queue is held by an open ticket and no section command is queued: at its turn the database holds exactly the rows
        // the report deletes, and it inserts none.
        let hold = try rig.holdWriter()
        rig.post(1, BlockChanges(deletes: original))
        rig.release(hold)
        #expect(await rig.waitUntil(5) { rig.decided() == 1 }, "the report is decided once its turn has come")

        let left = try rig.db.fetchBlocks(projectId: rig.pid).map(\.id).filter { original.contains($0) }
        #expect(left.count == original.count, """
            a report that deletes every row the database holds, and inserts none, is refused as a stale snapshot at its turn: \
            the rows stay (still there: \(left.count) of \(original.count) rows)
            """)
        #expect(writer.ledger.discardedAfterFetch == 1, "the report was discarded as a stale snapshot")
    }

    @Test("an empty report behind a held queue is decided at once, without waiting for its turn")
    func emptyReportDoesNotWaitForItsTurn() async throws {
        let rig = try ReportRig()
        let hold = try rig.holdWriter()
        rig.post(1, BlockChanges())
        #expect(await rig.waitUntil(2) { rig.decided() == 1 }, "an empty report settles at once, as before")
        rig.release(hold)
    }
}
