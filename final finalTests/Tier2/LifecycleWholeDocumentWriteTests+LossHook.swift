//
//  LifecycleWholeDocumentWriteTests+LossHook.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1a review fixes M24 / M18, W-FB (c) continued: the lifecycle-loss HOOK
//  (`BlockSyncService.performSystemWrite`'s call to `reportLifecycleWholeDocumentLost` for every
//  non-applied `.lifecycleWholeDocument` outcome) driven END TO END through each refusal shape the
//  first file only covers for `.identityMismatch` and `.noWriter`:
//    - `.nested`   (W32 precedent: `SystemWriteScope.$active.withValue(true)` + `testSuppressNestedAssert`)
//    - `.failed`   (a body that throws)
//    - `.skipped`  (`configure` -> `skipAllReserved` while FB waits for its turn behind an open editor
//                   sequence -- the "hold an editor sequence open (a reserved report turn)" recipe the
//                   NOT-covered note at the end of SystemWriteOrderingTests W36 describes)
//    - a replaced writer (review fix M18): the loss is counted on the writer the write USED, not on the
//      replacement writer that `configure` installed while the write was suspended
//  plus the defence-in-depth throw of `LifecycleWholeDocumentWrite.body` for the zoomed-without-range shape.
//
//  An extension of the same suite as LifecycleWholeDocumentWriteTests.swift (it inherits `.serialized` and
//  the time limit); a separate file because of SwiftLint's type_body_length / file_length caps.
//
//  Every test reads the report counter `BlockSyncService.testLifecycleLossReports` (review fix M24)
//  alongside the writer's ledger, because `testWriterLedger` is all-zero when the service has no writer.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// What `runFBSkippedWhileWaitingForItsTurn` hands back.
private struct FBSkippedRun {
    let stack: TestStack
    let result: SystemWriteResult<LifecycleWholeDocumentWriteValue>
    let recorder: WriterEventRecorder
}

extension LifecycleWholeDocumentWriteTests {

    private func plainShapes(_ db: ProjectDatabase) throws -> [String] {
        try TestFixtureFactory.fetchBlocks(from: db).map { "\($0.id)|\($0.textContent)|\($0.markdownFragment)" }
    }

    // MARK: - .noWriter (moved here from LifecycleWholeDocumentWriteTests.swift, rewritten non-vacuous: M24)

    @Test("""
        (c2) Through BlockSyncService, an FB refused for .noWriter is NOT counted as a loss (B6): plan §2.3 makes it a \
        direct-write fallback for the caller, not a loss -- the outcome is .refused(.noWriter) and, NON-VACUOUSLY (review \
        fix M24), the loss-report counter stays 0 (the ledger is all-zero with no writer, so it cannot show this alone)
        """)
    @MainActor
    func noWriter_isNotCountedAsLoss() async throws {
        let unconfigured = BlockSyncService()
        let db = try TestFixtureFactory.createTemporary(content: "# Alpha\n\nalpha body.\n\n# Beta\n\nbeta body.\n")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: "# Alpha\n\nx.\n", database: db, projectId: pid, zoomedRange: nil, zoomedSectionId: nil))

        let result = await unconfigured.performLifecycleWholeDocumentWrite(
            identity: SystemWriteIdentity(projectId: pid, database: db), prepared: prepared)

        guard case .refused(.noWriter) = result.outcome else {
            Issue.record("expected .refused(.noWriter) for a never-configured service, got \(result.outcome)")
            return
        }
        #expect(unconfigured.testWriterLedger.lifecycleWholeDocumentLost == 0)
        // The assertion above is VACUOUS on its own: with no writer `testWriterLedger` is all-zero whatever
        // the hook did. The report counter tells "never reported" from "reported, but no writer to count on".
        #expect(unconfigured.testLifecycleLossReports == 0, "B6: .noWriter must not be reported as a loss at all")
        // Non-vacuity probe: a report with no writer is only logged -- yet the seam still counts it, so a
        // wrongly-reported .noWriter WOULD have shown up above.
        unconfigured.reportLifecycleWholeDocumentLost(reason: "probe")
        #expect(unconfigured.testLifecycleLossReports == 1)
        #expect(unconfigured.testWriterLedger.lifecycleWholeDocumentLost == 0, "still no ledger to count on")
    }

    // MARK: - .nested, .failed

    @Test("""
        (c4) END TO END, .nested: an FB issued from inside SystemWriteScope.active is refused .nested BEFORE anything is \
        reserved, and the hook still reports it -- lifecycleWholeDocumentLost == 1, one loss report, nothing written
        """)
    @MainActor
    func nested_isCountedAsLoss_endToEnd() async throws {
        let stack = try makeStack()
        stack.sync.testSuppressNestedAssert = true               // W32 precedent (guards the heldEditorSeq assert)
        let identity = SystemWriteIdentity(projectId: stack.pid, database: stack.db)
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: "# Alpha\n\nwould-be edit.\n", database: stack.db, projectId: stack.pid,
            zoomedRange: nil, zoomedSectionId: nil))
        let rowsBefore = try plainShapes(stack.db)

        let result = await SystemWriteScope.$active.withValue(true) {
            await stack.sync.performLifecycleWholeDocumentWrite(identity: identity, prepared: prepared)
        }

        guard case .refused(.nested) = result.outcome else {
            Issue.record("expected .refused(.nested), got \(result.outcome)")
            return
        }
        #expect(result.prepareRan == false)
        let ledger = stack.sync.testWriterLedger
        #expect(ledger.lifecycleWholeDocumentLost == 1)
        #expect(ledger.lifecycleWholeDocumentApplied == 0)
        #expect(stack.sync.testLifecycleLossReports == 1)
        #expect(try plainShapes(stack.db) == rowsBefore, "a refused FB writes nothing")
    }

    @Test("""
        (c5) END TO END, .failed: a lifecycle write whose body throws is reported through the hook -- the writer counts its \
        own failedWrites (== 1) AND lifecycleWholeDocumentLost == 1 (an overlay, per review finding M21), one loss report
        """)
    @MainActor
    func failedBody_isCountedAsLoss_endToEnd() async throws {
        struct Boom: Error {}
        let stack = try makeStack()
        let identity = SystemWriteIdentity(projectId: stack.pid, database: stack.db)
        let rowsBefore = try plainShapes(stack.db)

        let result = await stack.sync.performSystemWrite(
            identity: identity, kind: .lifecycleWholeDocument, stillWanted: { true },
            body: { (_: Database) -> SystemWriteBody<Int> in throw Boom() })

        guard case .failed = result.outcome else {
            Issue.record("expected .failed, got \(result.outcome)")
            return
        }
        let ledger = stack.sync.testWriterLedger
        #expect(ledger.failedWrites == 1)
        #expect(ledger.lifecycleWholeDocumentLost == 1)
        #expect(ledger.lifecycleWholeDocumentApplied == 0)
        #expect(stack.sync.testLifecycleLossReports == 1)
        #expect(try plainShapes(stack.db) == rowsBefore, "a failed body rolls its transaction back")
    }

    // MARK: - .skipped (and the replaced-writer variant, review fix M18)

    /// Holds an editor sequence open (a report admitted, not applied), issues FB from a task, waits until
    /// FB is PARKED behind the editor sequence, then calls `configure` -- same project (`replaceWriter:
    /// false`: `skipAllReserved(.editorReplaced)`, the writer survives) or a different one (`true`:
    /// `retire(.writerReplaced)`, a fresh writer takes over) -- and returns FB's result.
    @MainActor
    private func runFBSkippedWhileWaitingForItsTurn(replaceWriter: Bool) async throws -> FBSkippedRun? {
        let stack = try makeStack()
        let recorder = WriterEventRecorder()
        let parked = WriterEventSignal(matching: { if case .parked = $0 { return true }; return false })
        stack.sync.testWriterEventHandler = { recorder.append($0); parked.note($0) }

        // An editor sequence held open ahead of FB: a report admitted (its turn reserved, its batch taken in) whose apply has not
        // run yet. (Phase 5 B4: it was a poll cycle parked right after its fetch.)
        let (openTicket, _) = try #require(stack.sync.reserveWriterTurn(database: stack.db, projectId: stack.pid))
        openTicket.noteFetched()

        let identity = SystemWriteIdentity(projectId: stack.pid, database: stack.db)
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: "# Alpha\n\nfb content that must not land.\n", database: stack.db, projectId: stack.pid,
            zoomedRange: nil, zoomedSectionId: nil))
        let otherDb = try TestFixtureFactory.createTemporary()
        let otherPid = try TestFixtureFactory.getProjectId(from: otherDb)

        let sync = stack.sync
        let fbTask = Task { @MainActor in
            await sync.performLifecycleWholeDocumentWrite(identity: identity, prepared: prepared)
        }
        await parked.wait()                                  // FB holds the next sequence, behind the open editor sequence
        if replaceWriter {
            stack.sync.configure(database: otherDb, projectId: otherPid, webView: stack.webView)
        } else {
            stack.sync.configure(database: stack.db, projectId: stack.pid, webView: stack.webView)
        }
        return FBSkippedRun(stack: stack, result: await fbTask.value, recorder: recorder)
    }

    @Test("""
        (c6) END TO END, .skipped: an FB waiting for its turn behind an open editor sequence, then skipped by \
        configure's skipAllReserved(.editorReplaced), is reported through the hook -- refused .skipped(.editorReplaced), \
        lifecycleWholeDocumentLost == 1 on the (surviving) writer, one loss report, and the FB content never lands
        """)
    @MainActor
    func skippedWhileWaitingForItsTurn_isCountedAsLoss_endToEnd() async throws {
        guard let run = try await runFBSkippedWhileWaitingForItsTurn(replaceWriter: false) else { return }
        guard case .refused(.skipped(.editorReplaced)) = run.result.outcome else {
            Issue.record("expected .refused(.skipped(.editorReplaced)), got \(run.result.outcome)")
            return
        }
        #expect(run.result.prepareRan == false)
        let ledger = run.stack.sync.testWriterLedger
        #expect(ledger.lifecycleWholeDocumentLost == 1)
        #expect(ledger.lifecycleWholeDocumentApplied == 0)
        #expect(ledger.systemWritesSkipped == 1, "the skipped FB sequence also has its own ordinary counter (the overlay, M21)")
        #expect(run.stack.sync.testLifecycleLossReports == 1)
        #expect(run.recorder.all.contains { if case .lifecycleWholeDocumentLost = $0 { return true }; return false })
        let texts = try TestFixtureFactory.fetchBlocks(from: run.stack.db).map(\.textContent)
        #expect(!texts.contains("fb content that must not land."), "a skipped FB writes nothing")
    }

    @Test("""
        (c7) REVIEW FIX M18 -- END TO END, replaced writer: when configure installs a NEW writer for another project \
        while FB waits for its turn, the loss is reported (one loss report, one event) but counted on the writer the write \
        USED -- the replacement writer's ledger stays at lifecycleWholeDocumentLost == 0
        """)
    @MainActor
    func skippedAcrossWriterReplacement_lossIsNotCountedOnTheNewWriter() async throws {
        guard let run = try await runFBSkippedWhileWaitingForItsTurn(replaceWriter: true) else { return }
        guard case .refused(.skipped(.writerReplaced)) = run.result.outcome else {
            Issue.record("expected .refused(.skipped(.writerReplaced)), got \(run.result.outcome)")
            return
        }
        #expect(run.stack.sync.testLifecycleLossReports == 1, "the loss was reported exactly once")
        let lossEvents = run.recorder.all.filter { if case .lifecycleWholeDocumentLost = $0 { return true }; return false }
        #expect(lossEvents.count == 1)
        #expect(run.stack.sync.testWriterLedger.lifecycleWholeDocumentLost == 0,
                "testWriterLedger is now the REPLACEMENT writer's: the old project's lost save must not be charged to it")
    }

    // MARK: - The body's defence-in-depth throw

    @Test("""
        (h) The body's defence in depth (review fix M24): LifecycleWholeDocumentWrite.body on a zoomed-without-range \
        Prepared throws zoomedSectionWithoutRange inside dbWriter.write and leaves rows and epoch unchanged; through \
        applySystemWrite it is .failed with failedWrites +1, no epoch bump and no applied FB
        """)
    func zoomedSectionWithoutRange_bodyThrows_rowsAndEpochUnchanged_failedThroughApply() async throws {
        let helper = DocumentWriterTests()
        let (db, pid, writer, _, _) = try helper.makeWriterStack()
        let rowsBefore = try plainShapes(db)
        let epochBefore = try db.currentBlockWriteEpoch(projectId: pid)
        let prepared = LifecycleWholeDocumentPrepared(
            blocks: BlockParser.parse(markdown: "# X\n\nwould replace everything.\n", projectId: pid),
            projectId: pid, range: nil, anchorHeadingId: "zoom-root-id", miniNotes: nil)

        // Directly, inside a plain write.
        let body = LifecycleWholeDocumentWrite.body(prepared)
        #expect(throws: LifecycleWholeDocumentWriteError.zoomedSectionWithoutRange) {
            _ = try db.dbWriter.write { database in try body(database) }
        }
        #expect(try plainShapes(db) == rowsBefore, "the throw rolls the transaction back: no rows written")
        #expect(try db.currentBlockWriteEpoch(projectId: pid) == epochBefore, "and no epoch bump")

        // Through the writer.
        let failedBefore = writer.ledger.failedWrites
        let ticket = writer.reserveSystem()
        let outcome = await writer.applySystemWrite(
            ticket.seq, kind: .lifecycleWholeDocument, identity: SystemWriteIdentity(projectId: pid, database: db),
            body: LifecycleWholeDocumentWrite.body(prepared))
        guard case .failed(let error) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect((error as? LifecycleWholeDocumentWriteError) == .zoomedSectionWithoutRange)
        #expect(writer.ledger.failedWrites == failedBefore + 1)
        #expect(writer.ledger.lifecycleWholeDocumentApplied == 0)
        #expect(try plainShapes(db) == rowsBefore)
        #expect(try db.currentBlockWriteEpoch(projectId: pid) == epochBefore)
    }
}
