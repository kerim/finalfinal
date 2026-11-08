//
//  ReportWriterGuardTests.swift
//  final finalTests
//
//  Phase 5 job B4 (docs/architecture/write-queue-plan/phase5/b4-notes.md, S5): the assertions about the WRITER itself that the
//  deleted poll tests made (BlockSyncPollWatchdogTests and its extensions), moved here and driven by the editor's reports instead
//  of a poll cycle. Each test names the test it replaces. They pin the guards B4 KEEPS (b2-b4-design.md 4.2): the (epoch,
//  sequence) stamp checks and the epoch bump retry, Phase 1's late-sequence / held-op / drain-skip machinery (kept because the
//  editor-first clicks still reserve ticket N before their page reply: correction 2, B4a not built), the writer's temp-id map, and
//  that no generation guard came back (GuardGen, the model's `P5B_FAA_Hierarchy`).
//

import Foundation
import GRDB
import Testing
import WebKit
@testable import final_final

@Suite("The writer's guards under the editor's reports (Phase 5 B4, moved from the poll tests)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ReportWriterGuardTests {

    private func paragraph(_ text: String, temp: String, after: String?, atStart: Bool? = nil) -> BlockInsert {
        BlockInsert(tempId: temp, blockType: "paragraph", textContent: text, markdownFragment: text, headingLevel: nil,
                    afterBlockId: after, atDocumentStart: atStart)
    }

    // Moved from BlockSyncPollWatchdogTests+EpochBarrier `wholesaleRewriteMidFlight_rejectsWedgedCyclesWholeBatch_...` (T7, R4).
    @Test("a wholesale rewrite between a report's admission and its turn refuses the report WHOLE; a report after the rewrite lands")
    func rewriteBetweenAdmissionAndTurnRefusesTheWholeReport() async throws {
        let rig = try ReportRig()
        let hold = try rig.holdWriter()
        // A document-start insert depends on no surviving row: without the epoch check it WOULD land (T7's reasoning).
        rig.post(1, BlockChanges(inserts: [paragraph("Stale insert.", temp: "temp-stale", after: nil, atStart: true)]))
        #expect(rig.sync.reportApplier.testLedger("s1").waiting == [1], "admitted: its turn and its stamp (epoch E) are taken now")
        try await rig.sync.parseAndStoreBlocks(markdown: "Rewritten.\n\nSecond.")   // replaceBlocks bumps the epoch
        rig.release(hold)
        #expect(try await rig.waitUntil { rig.decided() == 1 })
        var texts = try rig.paragraphs().map(\.markdownFragment)
        #expect(!texts.contains("Stale insert."), "the stale report's insert must not land")
        #expect(texts.contains("Rewritten."), "the rewrite's content survives")
        rig.post(2, BlockChanges(inserts: [paragraph("Fresh insert.", temp: "temp-fresh", after: nil, atStart: true)]))
        #expect(try await rig.waitUntil { rig.decided() == 2 })
        texts = try rig.paragraphs().map(\.markdownFragment)
        #expect(texts.contains("Fresh insert."), "the same insert shape lands when the report carries the current epoch")
    }

    // Moved from BlockSyncPollWatchdogTests+EpochBarrier `failedConfigureBump_isRetriedByNextPoll_deferringUntilItSucceeds` (T8).
    @Test("a failed configure-time epoch bump admits no report until its retry succeeds; the re-post then lands, not dropped as stale")
    func failedConfigureBumpDefersAReportUntilItsRepost() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "Alpha.\n\nBravo.")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let target = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.textContent.contains("Alpha") })
        // "Last session": the row's stamp becomes (E, 300).
        let sessionEpoch = try db.currentBlockWriteEpoch(projectId: pid)
        _ = try db.applyBlockChangesFromEditor(
            BlockChanges(updates: [BlockUpdate(id: target.id, textContent: "last session text", markdownFragment: nil, headingLevel: nil)]),
            for: pid, stamp: BlockWriteStamp(epoch: sessionEpoch, sequence: 300))
        try await db.dbWriter.write { try $0.execute(sql: "ALTER TABLE project DROP COLUMN blockWriteEpoch") }
        let view = WKWebView()
        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: view)
        #expect(sync.needsEpochBump, "precondition: configure's bump failed")
        let js = ScriptedJSEvaluator()
        sync.testJSEvaluator = { try await js.evaluate($0) }
        sync.reportApplier.gapFetchDisabled = true
        func text() throws -> String? { try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == target.id }?.textContent }
        func update(_ text: String) -> BlockChanges {
            BlockChanges(updates: [BlockUpdate(id: target.id, textContent: text, markdownFragment: nil, headingLevel: nil)])
        }

        sync.reportApplier.receive(IncomingReport(number: 1, session: "s1", changes: update("this session text"), detectedAt: 0), via: .message)
        #expect(sync.reportApplier.admittedCount == 0, "no turn is reserved while the bump keeps failing")
        #expect(try text() == "last session text")

        try await db.dbWriter.write { database in
            try database.execute(sql: "ALTER TABLE project ADD COLUMN blockWriteEpoch INTEGER NOT NULL DEFAULT 0")
            try database.execute(sql: "UPDATE project SET blockWriteEpoch = ? WHERE id = ?", arguments: [sessionEpoch, pid])
        }
        // The page sends report 1 again (it was never acknowledged): the retry succeeds and the report is admitted.
        let json = try blockChangesJSON(updates: update("this session text").updates)
        sync.reportApplier.receive(body: ["es": NSNumber(value: 1), "session": "s1", "kind": "changes", "json": json,
                                          "detectedAt": NSNumber(value: 0), "repost": NSNumber(value: true)])
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        while sync.reportApplier.decidedThrough(session: "s1") < 1, clock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try db.currentBlockWriteEpoch(projectId: pid) == sessionEpoch + 1, "the retry bumped the epoch exactly once")
        #expect(try text() == "this session text", "the edit lands, not dropped against last session's (E, 300) stamp")

        sync.reportApplier.receive(IncomingReport(number: 2, session: "s1", changes: update("later text"), detectedAt: 0), via: .message)
        while sync.reportApplier.decidedThrough(session: "s1") < 2, clock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try db.currentBlockWriteEpoch(projectId: pid) == sessionEpoch + 1, "a cleared flag does not bump again")
        #expect(try text() == "later text")
        _ = view
    }

    // Moved from BlockSyncPollWatchdogTests+EpochBarrier `failedReconfigureBump_newWriterDefersUntilRetrySucceeds` (B5).
    @Test("a failed reconfigure-time epoch bump admits no report for the new project until the retry succeeds")
    func failedReconfigureBumpDefersTheNewProjectsReport() async throws {
        let rig = try ReportRig()
        let dbB = try TestFixtureFactory.createTemporary(content: "Bravo project.")
        let pidB = try TestFixtureFactory.getProjectId(from: dbB)
        let targetB = try #require(try TestFixtureFactory.fetchBlocks(from: dbB).first { $0.textContent.contains("Bravo project") })
        try await dbB.dbWriter.write { try $0.execute(sql: "ALTER TABLE project DROP COLUMN blockWriteEpoch") }
        await rig.sync.reconfigure(database: dbB, projectId: pidB)
        #expect(rig.sync.needsEpochBump, "precondition: reconfigure's bump failed")
        let update = BlockChanges(updates: [BlockUpdate(id: targetB.id, textContent: "B edited", markdownFragment: nil, headingLevel: nil)])
        rig.post(1, update, session: "s2")
        #expect(rig.sync.reportApplier.admittedCount == 0)
        try await dbB.dbWriter.write { try $0.execute(sql: "ALTER TABLE project ADD COLUMN blockWriteEpoch INTEGER NOT NULL DEFAULT 0") }
        rig.sync.reportApplier.receive(IncomingReport(number: 1, session: "s2", changes: update, detectedAt: 0), via: .repost)
        #expect(try await rig.waitUntil { rig.sync.reportApplier.decidedThrough(session: "s2") == 1 })
        #expect(try TestFixtureFactory.fetchBlocks(from: dbB).first { $0.id == targetB.id }?.textContent == "B edited")
    }

    // Moved from BlockSyncPollWatchdogTests `writerLateApply_predecessorResumesAndIsMergedPerBlock` (T4). The stuck predecessor is now
    // an editor-first click's ticket N whose page reply is wedged (the case B4 keeps the late machinery for).
    @Test("a report behind a click ticket whose reply is wedged proceeds once N goes late; N's batch is merged per block when it comes")
    func lateClickTicketLetsAReportProceedAndIsMergedPerBlock() async throws {
        let rig = try ReportRig()
        let ids = try rig.ids()
        let (alpha, bravo) = (ids[0], ids[1])
        rig.sync.testWriterLateAfterSeconds = 0.3
        let (ticketN, stampN) = try #require(rig.sync.reserveWriterTurn(database: rig.db, projectId: rig.pid))
        rig.post(1, rig.update(alpha, "Y alpha."))
        #expect(try await rig.waitUntil { rig.decided() == 1 }, "the report proceeds once N's turn goes late")
        #expect(try rig.text(alpha) == "Y alpha.")
        // N's reply finally arrives: its batch (both blocks, older text) applies late.
        ticketN.noteFetched()
        let batchN = BlockChanges(updates: [
            BlockUpdate(id: alpha, textContent: "X alpha.", markdownFragment: "X alpha.", headingLevel: nil, blockType: "paragraph"),
            BlockUpdate(id: bravo, textContent: "X bravo.", markdownFragment: "X bravo.", headingLevel: nil, blockType: "paragraph")
        ])
        await rig.sync.applyFetchedBatch(ticket: ticketN, changes: batchN, stamp: stampN, webView: rig.view,
                                         database: rig.db, projectId: rig.pid, force: false)
        #expect(try rig.text(alpha) == "Y alpha.", "the shared block keeps the newer text")
        #expect(try rig.text(bravo) == "X bravo.", "the block only N touched still lands")
        rig.post(2, rig.update(bravo, "Z bravo."))
        #expect(try await rig.waitUntil { rig.decided() == 2 })
        #expect(try rig.text(bravo) == "Z bravo.", "a later report still applies normally")
    }

    // Moved from BlockSyncPollWatchdogTests+TempIdAfterValve `writerTurnOrder_insertAfterJustInsertedTempId_resolvesAfterTurn`.
    @Test("a second insert anchored on the temp id the first report is still inserting lands directly after it")
    func insertAnchoredOnAnEarlierReportsTempId() async throws {
        let rig = try ReportRig()
        let alpha = try #require(try rig.ids().first)
        let before = try rig.paragraphs().count
        let hold = try rig.holdWriter()   // both reports are admitted before the first one applies
        rig.post(1, BlockChanges(inserts: [paragraph("First inserted.", temp: "temp-v1", after: alpha)]))
        rig.post(2, BlockChanges(inserts: [paragraph("Second inserted.", temp: "temp-v2", after: "temp-v1")]))
        rig.release(hold)
        #expect(try await rig.waitUntil { rig.decided() == 2 })
        let rows = try rig.paragraphs()
        #expect(rows.count == before + 2)
        let first = try #require(rows.firstIndex { $0.markdownFragment == "First inserted." })
        let second = try #require(rows.firstIndex { $0.markdownFragment == "Second inserted." })
        #expect(second == first + 1, "anchored on the minted row, not the document's end")
        #expect(!rows[first].id.hasPrefix("temp-") && !rows[second].id.hasPrefix("temp-"))
    }

    // Replaces BlockSyncGenerationGuardTests and the RebuildKeepsBatch tests (GuardGen removed): the model's `P5B_FAA_Hierarchy` trace.
    @Test("a report waiting for its turn while a heading-level fix bumps the content generation is applied, not discarded")
    func reportAcrossAGenerationChangeIsApplied() async throws {
        let rig = try ReportRig()
        let editorState = EditorViewState()
        rig.sync.editorState = editorState
        let alpha = try #require(try rig.ids().first)
        let hold = try rig.holdWriter()
        rig.post(1, rig.update(alpha, "Typed during the fix."))
        let generation = editorState.contentGeneration
        editorState.contentState = .hierarchyEnforcement
        editorState.contentState = .idle
        #expect(editorState.contentGeneration != generation, "precondition: the generation moved")
        rig.release(hold)
        #expect(try await rig.waitUntil { rig.decided() == 1 })
        #expect(try rig.text(alpha) == "Typed during the fix.")
    }

    // Moved from BlockSyncPollWatchdogTests+WriterDrain `close_boundsTheWriterWait_onStuckFetch` (B3). The never-fetched sequence is
    // now a click ticket whose page reply never came.
    @Test("a close bounds the writer wait: a click ticket whose reply never came is skipped, never waited out, and never lands later")
    func closeBoundsTheWriterWaitOnAWedgedClickTicket() async throws {
        let rig = try LifecycleFlushHarness()
        let target = try #require(try rig.blocks().first { $0.textContent.contains("one two three") })
        let (ticketN, stampN) = try #require(rig.sync.reserveWriterTurn(database: rig.db, projectId: rig.pid))
        let bounds = LifecycleBounds.production.scaled(0.1)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await rig.run(.close, bounds: bounds)
        #expect(clock.now - start < .seconds(bounds.closeTotal + 1.5))
        if case .waited(.timedOut(let skippedEditorSeqs, let skippedFetched)) = result.barrier {
            #expect(skippedEditorSeqs == [ticketN.seq], "exactly the click's sequence is skipped")
            #expect(skippedFetched == 0, "its batch never reached Swift")
        } else {
            Issue.record("expected the barrier wait to time out on the wedged ticket, got \(result.barrier)")
        }
        #expect(rig.sync.testWriterLedger.skippedUnfetched == 1)
        // The reply comes after all: the skipped sequence must not land.
        ticketN.noteFetched()
        let stale = BlockChanges(updates: [BlockUpdate(id: target.id, textContent: "stuck edit", markdownFragment: nil, headingLevel: nil)])
        let view = try #require(rig.webView)
        await rig.sync.applyFetchedBatch(ticket: ticketN, changes: stale, stamp: stampN, webView: view,
                                         database: rig.db, projectId: rig.pid, force: false)
        #expect(try !rig.blocks().contains { $0.textContent == "stuck edit" })
    }
}
