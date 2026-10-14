//
//  LifecycleWholeDocumentWriteTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1a, W-FB: the queued WHOLE-DOCUMENT save ("FB") a close / project switch /
//  quit will take through the writer (plan v3 §2.3, coder items 15-17, judge adjustments B1, B6, B9,
//  slice-3a-1a.md (D)). Everything is exercised through the primitive's own shapes:
//    - `LifecycleWholeDocumentWrite.prepare` (MainActor parse step)
//    - `LifecycleWholeDocumentWrite.body` (pure `@Sendable (Database) throws` write body)
//    - `BlockSyncService.performLifecycleWholeDocumentWrite(identity:prepared:)`
//    - `DocumentWriter.applySystemWrite(kind: .lifecycleWholeDocument ...)`
//
//  FAIL-BEFORE (honest): these compile against the 3a-1a step-S stubs and fail BEHAVIOURALLY
//  there: the stub `prepare` returns a Prepared with NO blocks, the stub `body` writes nothing,
//  the stub `performLifecycleWholeDocumentWrite` refuses with `.notWanted` without touching the
//  database, and `noteLifecycleWholeDocumentLost` is a no-op.
//
//  Writer-level tests build their own `DocumentWriter` (via `DocumentWriterTests.makeWriterStack`,
//  the precedent `DocumentWriterSystemWriteTests` already follows); BlockSyncService-level tests
//  use BlockSyncPollWatchdogTests.swift's top-level `makeStack()` -- `BlockSyncService.writer` is
//  private and has no injection seam, so those tests observe the writer only through the existing
//  `testWriterLedger` / `testWriterEventHandler` pass-throughs.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Lifecycle whole-document write (FB) — Tier 2", .serialized, .timeLimit(.minutes(1)))
struct LifecycleWholeDocumentWriteTests {

    // MARK: - Fixtures and helpers

    private static let threeSections =
        "# Alpha\n\nalpha body.\n\n# Beta\n\nbeta body.\n\n# Gamma\n\ngamma body.\n"

    /// One comparable line per block: type, heading level, text, markdown.
    private static func shape(_ block: Block) -> String {
        "\(block.blockType.rawValue)|\(block.headingLevel.map(String.init) ?? "-")|\(block.textContent)|\(block.markdownFragment)"
    }

    /// Uses `makeWriterStack`'s DEFAULT fixture ("# Alpha / one two three. / # Beta / four five six."):
    /// that helper `#require`s paragraphs containing exactly those words, so it cannot take other
    /// content. Both headings ("Alpha", "Beta") are what the writer-level tests below rely on.
    private func makeWriterOnlyStack() throws -> (db: ProjectDatabase, pid: String, writer: DocumentWriter) { // swiftlint:disable:this large_tuple
        let helper = DocumentWriterTests()
        let (db, pid, writer, _, _) = try helper.makeWriterStack()
        return (db, pid, writer)
    }

    // MARK: - (a) Applied

    @Test("""
        (a) Applied: the database equals the parsed content (same rows, texts, fragments and sortOrders), \
        lifecycleWholeDocumentApplied == 1, systemWritesApplied goes up by exactly 1, and the epoch moves by exactly 1
        """)
    @MainActor
    func appliedWholeDocument_writesParsedContent_countsApplied() async throws {
        let stack = try makeStack(content: Self.threeSections)
        let content = "# Alpha\n\nalpha edited.\n\n# Beta\n\nbeta edited.\n\nbeta second paragraph.\n"
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: content, database: stack.db, projectId: stack.pid, zoomedRange: nil, zoomedSectionId: nil))
        let expectedBlocks = BlockParser.parse(markdown: content, projectId: stack.pid)

        let ledgerBefore = stack.sync.testWriterLedger
        let epochBefore = try stack.db.currentBlockWriteEpoch(projectId: stack.pid)
        let identity = SystemWriteIdentity(projectId: stack.pid, database: stack.db)
        let result = await stack.sync.performLifecycleWholeDocumentWrite(identity: identity, prepared: prepared)

        guard case .applied = result.outcome else {
            Issue.record("expected the whole-document write to apply, got \(result.outcome)")
            return
        }
        let after = try TestFixtureFactory.fetchBlocks(from: stack.db)
        #expect(after.map { Self.shape($0) } == expectedBlocks.map { Self.shape($0) })
        #expect(after.map(\.sortOrder) == expectedBlocks.map(\.sortOrder))
        let ledgerAfter = stack.sync.testWriterLedger
        #expect(ledgerAfter.lifecycleWholeDocumentApplied == ledgerBefore.lifecycleWholeDocumentApplied + 1)
        #expect(ledgerAfter.lifecycleWholeDocumentApplied == 1)
        #expect(ledgerAfter.systemWritesApplied == ledgerBefore.systemWritesApplied + 1)
        #expect(ledgerAfter.lifecycleWholeDocumentLost == 0)
        #expect(try stack.db.currentBlockWriteEpoch(projectId: stack.pid) == epochBefore + 1,
                "the replace bumps the epoch inside FB's own transaction (fact 3 / slice (D)); FB adds no second bump")
    }

    // MARK: - (b) U2c-W: the epoch mechanism (REGRESSION PIN)

    @Test("""
        (b) U2c-W, REGRESSION PIN for the epoch mechanism (slice (D)): an editor batch fetched BEFORE FB (stamp epoch E) \
        that applies late AFTER FB (which moved the epoch to E+1) is refused WHOLESALE for its stale epoch -- its update, \
        delete and insert all land nowhere -- the rows equal FB's content, and the epoch is E+1
        """)
    func staleOrphanEditorBatchRefusedAfterFB_epochMechanism() async throws {
        let (db, pid, writer) = try makeWriterOnlyStack()
        writer.testLateAfterSeconds = 0.05
        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let alphaId = try #require(before.first { $0.blockType == .heading && $0.textContent == "Alpha" }).id
        let betaId = try #require(before.first { $0.blockType == .heading && $0.textContent == "Beta" }).id

        // Editor seq 1, reserved exactly as `reserveWriterTurn` does: read the epoch, then reserve.
        let epochE = try db.currentBlockWriteEpoch(projectId: pid)
        let ticket1 = writer.reserve()
        let stamp1 = BlockWriteStamp(epoch: epochE, sequence: Int64(ticket1.seq))

        // FB at seq 2.
        let fbContent = "# Alpha\n\nfb alpha body.\n\n# Beta\n\nfb beta body.\n"
        let prepared = LifecycleWholeDocumentPrepared(
            blocks: BlockParser.parse(markdown: fbContent, projectId: pid),
            projectId: pid, range: nil, anchorHeadingId: nil, miniNotes: nil)
        let fbTicket = writer.reserveSystem()
        #expect(fbTicket.seq == 2)

        // FB's parked waiter arms seq 1's turn-stall expiry; seq 1 goes late (never fetched), which
        // makes it passable, so FB applies FIRST. The wait is BOUNDED (review fix M31): were the expiry
        // not armed, this fails in about 4s instead of hanging to the suite's 1-minute limit.
        let fbTurn = Task { await writer.waitForTurnAsync(fbTicket.seq) }
        var polls = 0
        while writer.testFrontier <= ticket1.seq, polls < 400 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        guard writer.testFrontier > ticket1.seq else {
            writer.retire(reason: .close)               // resumes the parked FB turn, so nothing is left waiting
            Issue.record("seq 1 never went late: FB's parked waiter did not arm the turn-stall expiry within 4s")
            return
        }
        #expect(await fbTurn.value == .go)
        let fbOutcome = await writer.applySystemWrite(
            fbTicket.seq, kind: .lifecycleWholeDocument,
            identity: SystemWriteIdentity(projectId: pid, database: db),
            body: LifecycleWholeDocumentWrite.body(prepared))
        guard case .applied = fbOutcome else {
            Issue.record("expected FB to apply first, got \(fbOutcome)")
            return
        }

        // Now seq 1's reply arrives, with an update, a delete and an insert -- every one targeting rows
        // that STILL EXIST after FB (the headings keep their ids by title match), so a refusal can only
        // be the stale-epoch rule, not "row missing".
        ticket1.noteFetched()
        let changes = BlockChanges(
            updates: [BlockUpdate(id: alphaId, textContent: "STALE alpha", markdownFragment: nil, headingLevel: nil)],
            inserts: [BlockInsert(tempId: "temp-u2cw-1", blockType: "paragraph", textContent: "stale insert",
                                  markdownFragment: "stale insert", headingLevel: nil,
                                  afterBlockId: alphaId, atDocumentStart: nil)],
            deletes: [betaId])
        let outcome1 = await writer.applyEditorBatch(ticket1.seq, changes, stamp: stamp1)
        guard case .applied(let result1) = outcome1 else {
            Issue.record("expected the late editor batch to be admitted and then refused by stamp, got \(outcome1)")
            return
        }
        #expect(result1.rejectedWholeBatchForStaleEpoch, "the WHOLE batch (inserts included) must be refused for its stale epoch")
        #expect(result1.writtenCount == 0)
        #expect(result1.idMapping.isEmpty)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let expected = BlockParser.parse(markdown: fbContent, projectId: pid)
        #expect(after.map { Self.shape($0) } == expected.map { Self.shape($0) }, "the rows must equal FB's content exactly")
        #expect(after.contains { $0.id == betaId }, "the stale delete must not have removed Beta")
        #expect(after.contains { $0.id == alphaId && $0.textContent == "Alpha" })
        #expect(!after.contains { $0.textContent == "STALE alpha" || $0.textContent == "stale insert" })
        #expect(try db.currentBlockWriteEpoch(projectId: pid) == epochE + 1)
        #expect(writer.ledger.lifecycleWholeDocumentApplied == 1)
    }

    // MARK: - (c) Refused / skipped FB is a counted loss (B6)

    @Test("""
        (c1) Through BlockSyncService, an FB refused for .identityMismatch IS a loss (B6 / plan §2.3): \
        lifecycleWholeDocumentLost == 1, a .lifecycleWholeDocumentLost event is emitted, nothing is applied
        """)
    @MainActor
    func identityMismatch_isCountedAsLoss_andEmitsEvent() async throws {
        let stack = try makeStack(content: Self.threeSections)
        let recorder = WriterEventRecorder()
        stack.sync.testWriterEventHandler = { recorder.append($0) }
        let otherDb = try TestFixtureFactory.createTemporary()
        let otherPid = try TestFixtureFactory.getProjectId(from: otherDb)
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: "# Alpha\n\nwould-be edit.\n", database: stack.db, projectId: stack.pid,
            zoomedRange: nil, zoomedSectionId: nil))
        let rowsBefore = try TestFixtureFactory.fetchBlocks(from: stack.db).map { Self.shape($0) }

        let result = await stack.sync.performLifecycleWholeDocumentWrite(
            identity: SystemWriteIdentity(projectId: otherPid, database: otherDb), prepared: prepared)

        guard case .refused(.identityMismatch) = result.outcome else {
            Issue.record("expected .refused(.identityMismatch), got \(result.outcome)")
            return
        }
        let ledger = stack.sync.testWriterLedger
        #expect(ledger.lifecycleWholeDocumentLost == 1)
        #expect(ledger.lifecycleWholeDocumentApplied == 0)
        #expect(stack.sync.testLifecycleLossReports == 1, "exactly one loss report went through the hook")
        #expect(recorder.all.contains { if case .lifecycleWholeDocumentLost = $0 { return true }; return false })
        #expect(try TestFixtureFactory.fetchBlocks(from: stack.db).map { Self.shape($0) } == rowsBefore, "a refused FB writes nothing")
    }

    @Test("""
        (c3) A skipped FB and an FB on a retired writer are both refused by the writer (.skipped(reason) / .writerRetired) \
        WITHOUT the writer counting them itself; noteLifecycleWholeDocumentLost then counts each one and emits \
        .lifecycleWholeDocumentLost(reason) with the reason it was given
        """)
    func skippedAndRetiredFB_areRefused_andNoteLossCountsAndEmits() async throws {
        let (db, pid, writer) = try makeWriterOnlyStack()
        let recorder = WriterEventRecorder()
        writer.testEventHandler = { recorder.append($0) }
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        let prepared = LifecycleWholeDocumentPrepared(
            blocks: BlockParser.parse(markdown: "# X\n\nbody.\n", projectId: pid),
            projectId: pid, range: nil, anchorHeadingId: nil, miniNotes: nil)

        // Skipped.
        let skippedTicket = writer.reserveSystem()
        writer.skip(upTo: skippedTicket.seq, reason: .projectSwitch)
        let skippedOutcome = await writer.applySystemWrite(
            skippedTicket.seq, kind: .lifecycleWholeDocument, identity: identity,
            body: LifecycleWholeDocumentWrite.body(prepared))
        guard case .refused(.skipped(.projectSwitch)) = skippedOutcome else {
            Issue.record("expected .refused(.skipped(.projectSwitch)), got \(skippedOutcome)")
            return
        }
        #expect(writer.ledger.lifecycleWholeDocumentLost == 0,
                "applySystemWrite only counts APPLIED FB writes; the loss is counted by performSystemWrite's caller hook")
        writer.noteLifecycleWholeDocumentLost(reason: "skipped(projectSwitch)")

        // Retired.
        writer.retire(reason: .close)
        let retiredTicket = writer.reserveSystem()
        let retiredOutcome = await writer.applySystemWrite(
            retiredTicket.seq, kind: .lifecycleWholeDocument, identity: identity,
            body: LifecycleWholeDocumentWrite.body(prepared))
        guard case .refused(.writerRetired) = retiredOutcome else {
            Issue.record("expected .refused(.writerRetired), got \(retiredOutcome)")
            return
        }
        writer.noteLifecycleWholeDocumentLost(reason: "writerRetired")

        #expect(writer.ledger.lifecycleWholeDocumentLost == 2)
        #expect(writer.ledger.lifecycleWholeDocumentApplied == 0)
        let reasons: [String] = recorder.all.compactMap { event in
            if case .lifecycleWholeDocumentLost(let reason) = event { return reason }
            return nil
        }
        #expect(reasons == ["skipped(projectSwitch)", "writerRetired"])
    }

    // MARK: - (d) Parse-before-reserve is structural

    @Test("""
        (d) Parse before reserve is STRUCTURAL (plan item 17): prepare takes no writer, so it cannot reserve; its \
        MainActor result is a plain Sendable value already holding the parsed blocks, with the zoom-notes text carried \
        UNWRITTEN as miniNotes (B9). The reservation function takes that value, so it cannot parse
        """)
    @MainActor
    func prepareParsesBeforeAnyReservation_noWriterInvolved() throws {
        let (db, pid, writer) = try makeWriterOnlyStack()
        let seqBefore = writer.nextSequence
        let content = "# Beta\n\nbeta zoomed[^1] body.\n\n<!-- ::zoom-notes:: -->\n\n[^1]: mini note.\n"

        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: content, database: db, projectId: pid,
            zoomedRange: (start: 3.0, end: 5.0), zoomedSectionId: "some-root"))

        #expect(writer.nextSequence == seqBefore, "prepare reserved nothing")
        let strippedExpected = BlockParser.parse(markdown: "# Beta\n\nbeta zoomed[^1] body.", projectId: pid)
        #expect(prepared.blocks.map { Self.shape($0) } == strippedExpected.map { Self.shape($0) },
                "the zoom-notes marker and everything after it is stripped BEFORE parsing")
        #expect(prepared.miniNotes == "[^1]: mini note.")
        #expect(prepared.projectId == pid)
        #expect(prepared.anchorHeadingId == "some-root")
        #expect(prepared.range?.start == 3.0)
        #expect(prepared.range?.end == 5.0)
        let sendableCheck: any Sendable = prepared
        _ = sendableCheck
    }

    // MARK: - (e) Zoomed: replaceBlocksInRange path

    @Test("""
        (e) Zoomed (range given): the write goes through the ranged replace -- only the rows inside [start, end) are \
        replaced (the zoom root keeps its id), every row outside the range keeps its id and text, and the epoch moves by 1
        """)
    @MainActor
    func zoomedRange_replacesOnlyTheRange() async throws {
        let stack = try makeStack(content: Self.threeSections)
        let before = try TestFixtureFactory.fetchBlocks(from: stack.db)
        let alphaHeading = try #require(before.first { $0.blockType == .heading && $0.textContent == "Alpha" })
        let betaHeading = try #require(before.first { $0.blockType == .heading && $0.textContent == "Beta" })
        let gammaHeading = try #require(before.first { $0.blockType == .heading && $0.textContent == "Gamma" })
        let alphaBody = try #require(before.first { $0.textContent == "alpha body." })
        let gammaBody = try #require(before.first { $0.textContent == "gamma body." })
        let epochBefore = try stack.db.currentBlockWriteEpoch(projectId: stack.pid)

        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: "# Beta\n\nbeta zoomed edit.\n", database: stack.db, projectId: stack.pid,
            zoomedRange: (start: betaHeading.sortOrder, end: gammaHeading.sortOrder),
            zoomedSectionId: betaHeading.id))
        let result = await stack.sync.performLifecycleWholeDocumentWrite(
            identity: SystemWriteIdentity(projectId: stack.pid, database: stack.db), prepared: prepared)

        guard case .applied = result.outcome else {
            Issue.record("expected the zoomed FB to apply, got \(result.outcome)")
            return
        }
        let after = try TestFixtureFactory.fetchBlocks(from: stack.db)
        #expect(after.map(\.textContent) == ["Alpha", "alpha body.", "Beta", "beta zoomed edit.", "Gamma", "gamma body."])
        #expect(after.first { $0.textContent == "Beta" }?.id == betaHeading.id, "the zoom root keeps its id (anchorHeadingId)")
        #expect(after.first { $0.textContent == "Alpha" }?.id == alphaHeading.id)
        #expect(after.first { $0.textContent == "alpha body." }?.id == alphaBody.id, "rows before the range are untouched")
        #expect(after.first { $0.textContent == "Gamma" }?.id == gammaHeading.id)
        #expect(after.first { $0.textContent == "gamma body." }?.id == gammaBody.id, "rows after the range are untouched")
        #expect(try stack.db.currentBlockWriteEpoch(projectId: stack.pid) == epochBefore + 1)
        #expect(stack.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
    }

    // MARK: - (f) The body is pure

    @Test("""
        (f) The body is a pure `@Sendable (Database) throws` closure: it is declared as exactly that type and runs inside a \
        plain dbWriter.write with no writer, no BlockSyncService, no EditorViewState and no MainActor, and writes the \
        prepared blocks
        """)
    func bodyIsAPureSendableDatabaseClosure() throws {
        let (db, pid, _) = try makeWriterOnlyStack()
        let content = "# Alpha\n\npure body paragraph.\n"
        let prepared = LifecycleWholeDocumentPrepared(
            blocks: BlockParser.parse(markdown: content, projectId: pid),
            projectId: pid, range: nil, anchorHeadingId: nil, miniNotes: nil)

        // Compile-level: the declared type is the contract.
        let body: @Sendable (Database) throws -> SystemWriteBody<LifecycleWholeDocumentWriteValue> =
            LifecycleWholeDocumentWrite.body(prepared)
        _ = try db.dbWriter.write { database in try body(database) }

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let expected = BlockParser.parse(markdown: content, projectId: pid)
        #expect(after.map { Self.shape($0) } == expected.map { Self.shape($0) })
    }

    // MARK: - (g) Judge adjustment B1

    @Test("""
        (g) B1: zoomedSectionId != nil with zoomedRange == nil (zoom in flight, no block range yet) is REFUSED -- never a \
        whole-document body -- the loss is counted (lifecycleWholeDocumentLost == 1) and an event emitted, nothing is \
        reserved (no applied / skipped / abandoned system write), and every other section is untouched
        """)
    @MainActor
    func zoomedSectionWithoutRange_isRefused_countedAsLoss_everySectionUntouched() async throws {
        let stack = try makeStack(content: Self.threeSections)
        let recorder = WriterEventRecorder()
        stack.sync.testWriterEventHandler = { recorder.append($0) }
        let rowsBefore = try TestFixtureFactory.fetchBlocks(from: stack.db).map { Self.shape($0) }
        let epochBefore = try stack.db.currentBlockWriteEpoch(projectId: stack.pid)

        // What a zoomed editor shows mid-zoom: ONLY the zoomed section. Treating it as the whole
        // document would delete Alpha and Gamma.
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: "# Beta\n\nzoom in flight.\n", database: stack.db, projectId: stack.pid,
            zoomedRange: nil, zoomedSectionId: "beta-section-id"))
        let result = await stack.sync.performLifecycleWholeDocumentWrite(
            identity: SystemWriteIdentity(projectId: stack.pid, database: stack.db), prepared: prepared)

        guard case .refused = result.outcome else {
            Issue.record("expected the zoomed-without-range FB to be refused, got \(result.outcome)")
            return
        }
        #expect(result.prepareRan == false)
        let ledger = stack.sync.testWriterLedger
        #expect(ledger.lifecycleWholeDocumentLost == 1)
        #expect(ledger.lifecycleWholeDocumentApplied == 0)
        #expect(ledger.systemWritesApplied == 0, "nothing was reserved or applied")
        #expect(ledger.systemWritesSkipped == 0)
        #expect(ledger.systemReservationsAbandoned == 0, "a reservation that was made and dropped would show here")
        #expect(stack.sync.testLifecycleLossReports == 1, "reported exactly once, by the B1 pre-reservation refusal")
        #expect(recorder.all.contains { if case .lifecycleWholeDocumentLost = $0 { return true }; return false })
        #expect(!recorder.all.contains { if case .systemApplied = $0 { return true }; return false })
        #expect(try TestFixtureFactory.fetchBlocks(from: stack.db).map { Self.shape($0) } == rowsBefore,
                "every section, Alpha and Gamma included, must be untouched")
        #expect(try stack.db.currentBlockWriteEpoch(projectId: stack.pid) == epochBefore, "a refused FB does not bump the epoch")
    }
}
