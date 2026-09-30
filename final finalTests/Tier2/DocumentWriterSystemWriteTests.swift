//
//  DocumentWriterSystemWriteTests.swift
//  final finalTests
//
//  Phase 2 (t-94369a83), §1 & §6: drives `DocumentWriter`'s system-write API
//  (`reserveSystem`/`applySystemWrite`) directly, plus `BlockSyncService.
//  performSystemWrite`'s own steps, the same way `DocumentWriterTests.swift` drives
//  the editor path -- no WebView, no JS.
//
//  NOTE (recorded honestly rather than silently, updated across dispatches): the plan
//  specifies W24-W36 (13 tests). Implemented so far -- W24 (ordering behind an editor
//  sequence), W26 (deinit's abandoned-reservation safety net), W27 (a `skip(upTo:)`
//  refusal carries its reason through and is counted), W28 (a throwing body settles
//  `.failed`), W31 (the I-SYS stall backstop), W32 (the nesting refusal), W33
//  (`retire()` then apply refuses `.writerRetired`). All 7 have been RUN, not just
//  written, and pass. The remaining W25/W29/W30/W34-W36 are NOT implemented -- see
//  this round's report for the full list of what's outstanding.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("DocumentWriter — System writes (Phase 2, Tier 2)", .serialized, .timeLimit(.minutes(1)))
struct DocumentWriterSystemWriteTests {

    // Reuses DocumentWriterTests' own helper (internal, shared via extension per that
    // file's own doc comment). Named distinctly from BlockSyncPollWatchdogTests.swift's
    // top-level `makeStack()` (used by the W32 test below) to avoid a name collision --
    // a member function of this type would otherwise shadow that free function.
    private func makeWriterOnlyStack() throws -> (db: ProjectDatabase, pid: String, writer: DocumentWriter) {
        let helper = DocumentWriterTests()
        let (db, pid, writer, _, _) = try helper.makeWriterStack()
        return (db, pid, writer)
    }

    // W24
    @Test("a system write waits behind an earlier fetched editor sequence")
    func systemWriteWaitsBehindEditorSequence() async throws {
        let (db, pid, writer) = try makeWriterOnlyStack()
        let editorTicket = writer.reserve()   // seq 1: reserved, not yet fetched
        editorTicket.noteFetched()

        let identity = SystemWriteIdentity(projectId: pid, database: db)
        let systemTicket = writer.reserveSystem()   // seq 2
        #expect(systemTicket.seq == 2)

        // The system write's turn has not come yet -- seq 1 is still open.
        let stillOpenBeforeApply = writer.testFrontier
        #expect(stillOpenBeforeApply == 1)

        // Settle seq 1, which should let seq 2 through.
        editorTicket.settleIfOpen(.empty)

        let outcome = await writer.applySystemWrite(
            systemTicket.seq, kind: .headingLevels, identity: identity
        ) { _ in SystemWriteBody(value: 42) }
        guard case .applied(let value) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(value == 42)
    }

    // W26
    @Test("a SystemReservation released without applying settles through deinit as abandoned")
    func abandonedReservationSettlesViaDeinit() async throws {
        let (db, pid, writer) = try makeWriterOnlyStack()
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        let before = writer.ledger.systemReservationsAbandoned

        do {
            var reservation: SystemReservation? = SystemReservation(writer.reserveSystem())
            _ = identity   // silence unused-var warnings while not consuming
            reservation = nil   // deinit fires here without ever calling consume()
            _ = reservation
        }

        // Give the actor a beat to process the abandon (abandonSystemReservation is
        // synchronous/Mutex-guarded, so this should already be reflected, but a yield
        // costs nothing and matches this file's own defensive style).
        await Task.yield()
        #expect(writer.ledger.systemReservationsAbandoned == before + 1)

        // A successor should not be blocked by the abandoned reservation.
        let nextTicket = writer.reserveSystem()
        let outcome = await writer.applySystemWrite(
            nextTicket.seq, kind: .headingLevels, identity: identity
        ) { _ in SystemWriteBody(value: true) }
        guard case .applied = outcome else {
            Issue.record("expected successor to apply, got \(outcome)")
            return
        }
    }

    // W28
    @Test("a throwing system-write body settles .failed and the frontier advances")
    func throwingBodySettlesFailed() async throws {
        let (db, pid, writer) = try makeWriterOnlyStack()
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        struct Boom: Error {}

        let ticket = writer.reserveSystem()
        let before = writer.ledger.failedWrites
        let outcome = await writer.applySystemWrite(
            ticket.seq, kind: .bibliographyUpdate, identity: identity
        ) { (_: Database) -> SystemWriteBody<Int> in throw Boom() }
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(writer.ledger.failedWrites == before + 1)

        // A successor is not blocked by the failure.
        let nextTicket = writer.reserveSystem()
        let nextOutcome = await writer.applySystemWrite(
            nextTicket.seq, kind: .bibliographyUpdate, identity: identity
        ) { _ in SystemWriteBody(value: 1) }
        guard case .applied = nextOutcome else {
            Issue.record("expected successor to apply, got \(nextOutcome)")
            return
        }
    }

    // W31
    @Test("the I-SYS stall backstop skips a reserved-and-never-applied system ticket")
    func stallBackstopSkipsUnappliedSystemWrite() async throws {
        let (db, pid, writer) = try makeWriterOnlyStack()
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        writer.testSystemStallAfterSeconds = 0.1

        let signal = WriterEventSignal { event in
            if case .systemStalled = event { return true }
            return false
        }
        writer.testEventHandler = { signal.note($0) }

        let ticket = writer.reserveSystem()   // never applied
        await signal.wait()

        #expect(writer.ledger.systemWritesStalled == 1)
        #expect(writer.systemSkipReason(ticket.seq) == .systemStalled)

        let outcome = await writer.applySystemWrite(
            ticket.seq, kind: .headingLevels, identity: identity
        ) { _ in SystemWriteBody(value: 1) }
        guard case .refused(.skipped(.systemStalled)) = outcome else {
            Issue.record("expected .refused(.skipped(.systemStalled)), got \(outcome)")
            return
        }

        // A successor is not blocked by the stalled predecessor.
        let nextTicket = writer.reserveSystem()
        let nextOutcome = await writer.applySystemWrite(
            nextTicket.seq, kind: .headingLevels, identity: identity
        ) { _ in SystemWriteBody(value: 1) }
        guard case .applied = nextOutcome else {
            Issue.record("expected successor to apply, got \(nextOutcome)")
            return
        }
    }

    // W27
    @Test("""
        skip(upTo:) on a reserved system write refuses it .refused(.skipped(reason)) with the reason carried through, and counts \
        it in systemWritesSkipped
        """)
    func skipUpToRefusesSystemWriteWithReasonCarriedThrough() async throws {
        let (db, pid, writer) = try makeWriterOnlyStack()
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        let skippedConsumedBefore = writer.ledger.skippedConsumed
        let systemWritesSkippedBefore = writer.ledger.systemWritesSkipped

        let ticket = writer.reserveSystem()
        writer.skip(upTo: ticket.seq, reason: .projectSwitch)

        let outcome = await writer.applySystemWrite(
            ticket.seq, kind: .headingLevels, identity: identity
        ) { _ in SystemWriteBody(value: 1) }
        guard case .refused(.skipped(.projectSwitch)) = outcome else {
            Issue.record("expected .refused(.skipped(.projectSwitch)), got \(outcome)")
            return
        }
        #expect(writer.ledger.systemWritesSkipped == systemWritesSkippedBefore + 1)
        // Bug fix (round 2 of this dispatch): `skip(upTo:reason:)` used to bump
        // `skippedConsumed` for EVERY `.fetched`-phase sequence with no branch
        // excluding a system one, so a system-write skip double-counted into the
        // editor-batch counter. Per the plan's own §1.2 wording ("... not
        // `skippedConsumed`, so editor-batch accounting stays unchanged"),
        // `skippedConsumed` must NOT move when what was skipped is a system write --
        // fixed in `DocumentWriter.swift` by gating the whole ledger switch on
        // `!writerState.systemSeqs.contains(seq)`. This now asserts the CORRECTED
        // behavior directly.
        #expect(writer.ledger.skippedConsumed == skippedConsumedBefore,
                "skippedConsumed is the editor-batch counter and must not move for a system-write skip")
    }

    // W33
    @Test("retire() then apply gives .refused(.writerRetired)")
    func retireThenApplyRefusesWriterRetired() async throws {
        let (db, pid, writer) = try makeWriterOnlyStack()
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        let ticket = writer.reserveSystem()

        writer.retire(reason: .writerReplaced)

        let outcome = await writer.applySystemWrite(
            ticket.seq, kind: .headingLevels, identity: identity
        ) { _ in SystemWriteBody(value: 1) }
        guard case .refused(.writerRetired) = outcome else {
            Issue.record("expected .refused(.writerRetired), got \(outcome)")
            return
        }
    }

    // W35
    @Test("""
        the turn-stall expiry and the lateAbandon timer never touch a system sequence, however long an editor sequence ahead of \
        it stays late or abandoned -- once that editor sequence is passed, the system write applies cleanly
        """)
    func expiryAndAbandonTimersNeverTouchSystemSequence() async throws {
        let (db, pid, writer) = try makeWriterOnlyStack()
        writer.testLateAfterSeconds = 0.05
        writer.testLateAbandonAfterSeconds = 0.1
        let identity = SystemWriteIdentity(projectId: pid, database: db)

        let expired = WriterEventSignal(matching: { if case .expired(1) = $0 { return true }; return false })
        let abandoned = WriterEventSignal(matching: { if case .abandoned(1) = $0 { return true }; return false })
        writer.testEventHandler = { event in
            expired.note(event)
            abandoned.note(event)
        }

        let editorTicket = writer.reserve()       // seq 1: reserved, never fetched
        let systemTicket = writer.reserveSystem() // seq 2: queued behind seq 1
        // `rearmExpiryLocked`/`rearmAbandonLocked` only ever arm while at least one
        // waiter is parked BEHIND the frontier -- a bare reservation is not itself a
        // waiter. Parking seq 2's own turn here is what makes the timers arm at all
        // (and doubles as this test's proof that seq 2 genuinely becomes admissible
        // the moment seq 1 is passed, below).
        let waitTask = Task { await writer.waitForTurnAsync(systemTicket.seq) }

        // I-SYS backstop's own invariant (`checkSystemStallInvariantLocked`, an
        // `assert` that crashes the process if violated) already structurally proves a
        // system sequence can never be `.reserved`/`.late(fetched:false)` -- the two
        // phases `expiryFired`/`abandonFired` require to act at all. This test proves
        // the OBSERVABLE consequence: across both timers actually firing on the
        // sequence ahead of it, seq 2's own counters never move.
        await expired.wait()
        #expect(writer.ledger.systemWritesStalled == 0, "the expiry firing on seq 1 must not touch the system ticket")
        #expect(writer.ledger.systemReservationsAbandoned == 0)

        await abandoned.wait()
        #expect(writer.ledger.systemWritesStalled == 0, "the abandon timer firing on seq 1 must not touch the system ticket")
        #expect(writer.ledger.systemReservationsAbandoned == 0)

        // seq 1 being `.abandoned` (passably late) lets the frontier pass it -- seq 2
        // is now admissible and applies normally, proving it was never itself skipped,
        // stalled, or abandoned by either timer.
        let turnResult = await waitTask.value
        #expect(turnResult == .go, "seq 2 must be admitted once seq 1 is passed, not skipped")
        let outcome = await writer.applySystemWrite(
            systemTicket.seq, kind: .headingLevels, identity: identity
        ) { _ in SystemWriteBody(value: 7) }
        guard case .applied(let value) = outcome else {
            Issue.record("expected the untouched system write to apply cleanly, got \(outcome)")
            return
        }
        #expect(value == 7)
        #expect(writer.ledger.systemWritesStalled == 0)
        #expect(writer.ledger.systemReservationsAbandoned == 0)
        _ = editorTicket   // never settled -- its own eventual late reply is out of scope for this test
    }

    // W29
    @Test("""
        a system write's deletedAnchors merge into the tombstone map only while mintPossible, letting a late insert anchored on \
        a deleted row re-anchor after its tombstone's target once its reply finally arrives
        """)
    func deletedAnchorsMergeOnlyWhileMintPossible() async throws {
        let helper = DocumentWriterTests()
        let (db, pid, writer, blockA, blockB) = try helper.makeWriterStack()
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        writer.testLateAfterSeconds = 0.05

        let expired = WriterEventSignal(matching: { if case .expired(1) = $0 { return true }; return false })
        writer.testEventHandler = { expired.note($0) }

        // seq 1: an editor sequence that goes late (fetched: false) -- mintPossible ==
        // true from here on, since its eventual reply could still mint an insert's
        // anchor.
        let editorTicket = writer.reserve()
        // seq 2: a system write (standing in for a real bibliography removal), reserved
        // BEHIND seq 1 -- and its own turn parked (`rearmExpiryLocked` only arms while
        // a waiter sits behind the frontier; a bare reservation is not a waiter) before
        // awaiting the expiry, so the timer actually has something to arm for.
        let sysTicket = writer.reserveSystem()
        let waitTask = Task { await writer.waitForTurnAsync(sysTicket.seq) }
        await expired.wait()
        let turnResult = await waitTask.value
        #expect(turnResult == .go, "seq 2 must be admitted once seq 1 goes late, not skipped")

        // Deletes a row anchored `.after(blockA.id)` -- reported via `deletedAnchors`,
        // exactly as `BibliographySyncService+SystemWrite.writeBibliographyRemoval`
        // would. Applied WHILE mintPossible is true, so this must merge into the
        // writer's own tombstone map.
        let sysOutcome = await writer.applySystemWrite(
            sysTicket.seq, kind: .bibliographyRemoval, identity: identity
        ) { _ in
            SystemWriteBody(value: 1, deletedAnchors: ["deleted-bib-row": .after(blockA.id)])
        }
        guard case .applied = sysOutcome else {
            Issue.record("expected the bibliography-removal-shaped system write to apply, got \(sysOutcome)")
            return
        }

        // seq 1's reply finally arrives, carrying a NEW insert anchored on the row the
        // system write just deleted (`deleted-bib-row`) -- Addendum A2 §2's tombstone
        // resolution should re-anchor it onto the tombstone's own target (blockA)
        // rather than rejecting it, proving the merge above actually happened.
        editorTicket.noteFetched()
        guard await editorTicket.waitForTurn() == .go else {
            Issue.record("expected seq 1's late reply to be admitted")
            return
        }
        let reanchored = WriterEventSignal(matching: {
            if case .insertReanchored(tempId: "temp-late-insert") = $0 { return true }
            return false
        })
        writer.testEventHandler = { reanchored.note($0) }
        let lateOutcome = await writer.applyEditorBatch(1, BlockChanges(inserts: [
            BlockInsert(tempId: "temp-late-insert", blockType: "paragraph", textContent: "late insert",
                        markdownFragment: "late insert", headingLevel: nil,
                        afterBlockId: "deleted-bib-row", atDocumentStart: false)
        ]), stamp: try helper.stamp(db, pid, 1))
        await reanchored.wait()

        guard case .applied = lateOutcome else {
            Issue.record("expected the late insert to apply (re-anchored), got \(lateOutcome)")
            return
        }
        #expect(writer.ledger.lateInsertsReanchored == 1,
                "the late insert must have been re-anchored via the merged tombstone, not rejected")
        #expect(writer.ledger.staleAnchorInsertsRejected == 0)
        _ = blockB
    }

    // W25
    @Test("""
        a system write that touches a row while a late (lower-sequence) editor predecessor is still open stamps nothing on that \
        row, so the predecessor's own body edit to the same row still lands once its reply arrives
        """)
    func systemWriteStampsNothing_lateLowerSequenceBodyEditStillLands() async throws {
        let helper = DocumentWriterTests()
        let (db, pid, writer, blockA, _) = try helper.makeWriterStack()
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        writer.testLateAfterSeconds = 0.05

        // Standing in for a real Notes definition row (the underlying stamp/ordering
        // mechanism -- `Database+BlockWriteStamp.swift`'s row-level write guard -- is
        // identical regardless of `isNotes`; only the write BODY differs, and this
        // test's own inline body is what §1.4 says every real system-write body must
        // do: touch rows without ever calling `Database.stamp(...)`).
        let stampBefore = try await db.dbWriter.read { try ProjectDatabase.storedStamp(db: $0, blockId: blockA.id) }

        let expired = WriterEventSignal(matching: { if case .expired(1) = $0 { return true }; return false })
        writer.testEventHandler = { expired.note($0) }

        // seq 1: the "late predecessor" -- reserved first (lower sequence number),
        // never fetched, forced late. Parked before awaiting the expiry for the same
        // reason W29/W35 above needed to: `rearmExpiryLocked` only arms while a waiter
        // sits behind the frontier.
        let editorTicket = writer.reserve()
        let sysTicket = writer.reserveSystem()
        let waitTask = Task { await writer.waitForTurnAsync(sysTicket.seq) }
        await expired.wait()
        #expect(await waitTask.value == .go, "seq 2 must be admitted once seq 1 goes late, not skipped")

        // seq 2: a system write that mutates blockA's own text DIRECTLY -- deliberately
        // never calling `Database.stamp(...)`, exactly as every real system-write body
        // in this codebase is required to (§1.4: system writes are never stamped).
        struct BlockNotFound: Error {}
        let sysOutcome = await writer.applySystemWrite(
            sysTicket.seq, kind: .headingLevels, identity: identity
        ) { db in
            guard var row = try Block.fetchOne(db, key: blockA.id) else { throw BlockNotFound() }
            row.textContent = "system-write text"
            try row.update(db)
            return SystemWriteBody(value: 1)
        }
        guard case .applied = sysOutcome else {
            Issue.record("expected the system write to apply, got \(sysOutcome)")
            return
        }

        let stampAfterSystemWrite = try await db.dbWriter.read { try ProjectDatabase.storedStamp(db: $0, blockId: blockA.id) }
        #expect(stampAfterSystemWrite == stampBefore,
                """
                a system write must never advance a row's write stamp -- got \(String(describing: stampAfterSystemWrite)), \
                was \(String(describing: stampBefore))
                """)
        let afterSystemWrite = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == blockA.id }
        #expect(afterSystemWrite?.textContent == "system-write text")

        // seq 1's reply finally arrives with its OWN body edit to the SAME row --
        // since the system write left no stamp behind, the editor write-stamp guard
        // has nothing to reject this late edit against, and it must land, overwriting
        // the system write's text with the editor's own.
        editorTicket.noteFetched()
        guard await editorTicket.waitForTurn() == .go else {
            Issue.record("expected seq 1's late reply to be admitted")
            return
        }
        let lateOutcome = await writer.applyEditorBatch(1, BlockChanges(updates: [
            BlockUpdate(id: blockA.id, textContent: "late editor text", markdownFragment: nil, headingLevel: nil)
        ]), stamp: try helper.stamp(db, pid, 1))
        guard case .applied = lateOutcome else {
            Issue.record("expected the late lower-sequence body edit to land, got \(lateOutcome)")
            return
        }
        let final = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == blockA.id }
        #expect(final?.textContent == "late editor text",
                "the late editor edit must win -- the un-stamped system write left nothing to reject it against")
    }

    // W32
    @Test("performSystemWrite inside SystemWriteScope.active is refused .nested")
    @MainActor
    func nestedCallIsRefused() async throws {
        // Reuses BlockSyncPollWatchdogTests.swift's top-level `makeStack()` (same
        // test target, `.configure(database:projectId:webView:)` wires up its own
        // internal writer -- there is no injection seam for a pre-made `DocumentWriter`
        // instance, so this test drives `BlockSyncService.performSystemWrite` through
        // its own real configuration instead of `DocumentWriterTests.makeWriterStack`).
        let stack = try makeStack()
        let identity = SystemWriteIdentity(projectId: stack.pid, database: stack.db)

        let result = await SystemWriteScope.$active.withValue(true) {
            await stack.sync.performSystemWrite(
                identity: identity, kind: .headingLevels, stillWanted: { true },
                body: { _ in SystemWriteBody(value: 1) }
            )
        }

        guard case .refused(.nested) = result.outcome else {
            Issue.record("expected .refused(.nested), got \(result.outcome)")
            return
        }
        #expect(result.prepareRan == false)
    }

    // T3 / T3b / T3c
    @Test("""
        patchHeadingLevels patches only the level and leading # marker of a matching row byte-for-byte, skips a row whose \
        current level no longer matches what was captured, and never reverts text an editor already changed underneath it
        """)
    func patchHeadingLevelsOnlyTouchesLevelAndMarker_skipsStale_neverRevertsConcurrentText() throws {
        let helper = DocumentWriterTests()
        let content = "# Alpha\n\nBody one.\n\n## Beta\n\nBody two.\n"
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let headings = TestFixtureFactory.headingBlocks(try TestFixtureFactory.fetchBlocks(from: db))
        let alpha = try #require(headings.first { $0.textContent == "Alpha" })
        let beta = try #require(headings.first { $0.textContent == "Beta" })
        #expect(alpha.headingLevel == 1)
        #expect(beta.headingLevel == 2)

        // T3c setup: an "editor batch" (simulated directly here) already changed
        // alpha's OWN markdown text -- its `headingLevel` is untouched (still 1), so
        // this is the "editor-edit-before-patch" ordering: by the time the patch
        // below runs, alpha's CURRENT fragment already differs from whatever text
        // was captured when `changes` was computed.
        try db.dbWriter.write { txDb in
            guard var row = try Block.fetchOne(txDb, key: alpha.id) else { return }
            row.markdownFragment = "# Alpha EDITED BY A CONCURRENT BATCH"
            row.textContent = "Alpha EDITED BY A CONCURRENT BATCH"
            try row.update(txDb)
        }

        // alpha: a genuine change (oldLevel matches its CURRENT level) -> patched.
        // beta: a STALE change (oldLevel=99, deliberately wrong, standing in for a
        // capture that's since been superseded by a concurrent level change) -> skipped.
        let changes: [(id: String, oldLevel: Int, newLevel: Int)] = [
            (id: alpha.id, oldLevel: 1, newLevel: 3),
            (id: beta.id, oldLevel: 99, newLevel: 4)
        ]
        let result = try db.dbWriter.write { txDb in
            ContentView.patchHeadingLevels(db: txDb, projectId: pid, changes: changes)
        }
        #expect(result.value == 1, "exactly one row (alpha) should have been patched; beta is stale")

        let afterAlpha = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == alpha.id })
        #expect(afterAlpha.headingLevel == 3, "T3: level changes")
        #expect(afterAlpha.markdownFragment == "### Alpha EDITED BY A CONCURRENT BATCH",
                """
                T3/T3c: only the leading marker changes -- the concurrent edit's text must survive byte-for-byte, \
                never reverted to whatever was captured before it
                """)
        #expect(afterAlpha.textContent == "Alpha EDITED BY A CONCURRENT BATCH",
                "T3: textContent is never touched by a heading-level patch")

        let afterBeta = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == beta.id })
        #expect(afterBeta.headingLevel == 2, "T3b: a stale row (oldLevel mismatch) must be skipped, not patched")
        #expect(afterBeta.markdownFragment == beta.markdownFragment, "T3b: a skipped row's fragment is untouched")
        _ = helper
    }

    // T3c (second ordering): a late editor batch that lands AFTER the heading patch.
    //
    // REVIEW FIX (finding #13): this test used to send
    // `BlockUpdate(markdownFragment: nil, headingLevel: nil)` for the "late body edit"
    // -- a payload no real editor ever sends. `Database+Blocks.swift`'s own comment on
    // `applyUpdateToExistingBlock` states it plainly: "block-sync-plugin.ts's
    // detectChanges always sets markdownFragment via getMarkdownFragment(newBlock) --
    // a non-optional string -- whenever it enqueues a pendingUpdate" -- and
    // `block-sync-plugin.ts`'s own `detectChanges` (the `pendingUpdates.set` call)
    // ALWAYS includes `headingLevel: newBlock.headingLevel` alongside it, for every
    // detected change, not only a level change. With `markdownFragment: nil`, the old
    // test's whole write silently skipped `applyMarkdownFragmentTransition` (guarded by
    // `if let markdownFragment = update.markdownFragment`) entirely -- so its assertion
    // that "the patch's marker change survives" was never actually exercised; nothing
    // ever touched `markdownFragment`/`headingLevel` in that version of the test at all.
    //
    // Using the REALISTIC payload below (`markdownFragment`/`headingLevel` both
    // present, reflecting the editor's own STALE level 1 belief, since its snapshot was
    // taken before the patch landed) reveals the test's original claim was FALSE:
    // `applyUpdateToExistingBlock` has no staleness guard for `headingLevel` the way it
    // does for a Notes row's label -- it unconditionally applies
    // `update.markdownFragment`/`update.headingLevel`, so the late editor batch
    // SILENTLY REVERTS the patch's own level correction back to the editor's stale
    // level. This is a genuine, newly-discovered residual (not something this dispatch
    // is fixing -- see this round's report: it needs a product decision on whether a
    // late-editor-echo reverting a hierarchy-enforcement correction is acceptable, the
    // same category as document-writer.md's other documented "Known gap" residuals,
    // before anyone attempts a fix). This test now asserts the ACTUAL, verified
    // behavior instead of an unproven claim.
    @Test("""
        a late editor body edit that applies AFTER a heading-level patch lands its own text but also reverts the patch's \
        marker/level back to the editor's stale belief (documented residual, not fixed here)
        """)
    func lateEditorBodyEditAfterHeadingPatch_lateEditReverts_documentedResidual() async throws {
        let helper = DocumentWriterTests()
        let (db, pid, writer, blockA, _) = try helper.makeWriterStack()
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        // `blockA` from `makeWriterStack()`'s default content is a PARAGRAPH ("one two
        // three"), not a heading -- promote it to a heading in the fixture directly so
        // this test can drive both a heading-level patch AND a body-text edit against
        // the SAME row, matching what `patchHeadingLevels`/an editor update both target.
        try await db.dbWriter.write { txDb in
            guard var row = try Block.fetchOne(txDb, key: blockA.id) else { return }
            row.blockType = .heading
            row.headingLevel = 1
            row.markdownFragment = "# " + row.textContent
            try row.update(txDb)
        }
        writer.testLateAfterSeconds = 0.05

        let expired = WriterEventSignal(matching: { if case .expired(1) = $0 { return true }; return false })
        writer.testEventHandler = { expired.note($0) }

        // seq 1: the editor's own body edit to the row, reserved first (lower
        // sequence) but forced late -- its reply arrives AFTER the patch below.
        let editorTicket = writer.reserve()
        let sysTicket = writer.reserveSystem()
        let waitTask = Task { await writer.waitForTurnAsync(sysTicket.seq) }
        await expired.wait()
        #expect(await waitTask.value == .go)

        // seq 2: the heading-level patch runs FIRST (editor sequence 1 is still open/late).
        let patchOutcome = await writer.applySystemWrite(
            sysTicket.seq, kind: .headingLevels, identity: identity
        ) { db in
            ContentView.patchHeadingLevels(db: db, projectId: pid, changes: [(id: blockA.id, oldLevel: 1, newLevel: 2)])
        }
        guard case .applied = patchOutcome else {
            Issue.record("expected the heading patch to apply, got \(patchOutcome)")
            return
        }

        // seq 1's reply (the late batch) NOW arrives, carrying its own text change to
        // the SAME row. Realistic payload (see this test's own doc comment above): the
        // editor's snapshot predates the patch, so its `markdownFragment`/`headingLevel`
        // both still reflect the OLD level 1 -- exactly what `block-sync-plugin.ts`'s
        // `detectChanges` actually sends, never `nil`.
        editorTicket.noteFetched()
        guard await editorTicket.waitForTurn() == .go else {
            Issue.record("expected seq 1's late reply to be admitted")
            return
        }
        let lateOutcome = await writer.applyEditorBatch(1, BlockChanges(updates: [
            BlockUpdate(id: blockA.id, textContent: "late body text",
                        markdownFragment: "# late body text", headingLevel: 1)
        ]), stamp: try helper.stamp(db, pid, 1))
        guard case .applied = lateOutcome else {
            Issue.record("expected the late body edit to land, got \(lateOutcome)")
            return
        }

        let final = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == blockA.id })
        // The late editor edit's own text always lands -- this part of the original
        // claim holds.
        #expect(final.textContent == "late body text", "the late editor edit's own text must land")
        // DOCUMENTED RESIDUAL (see this test's own doc comment): `applyUpdateToExistingBlock`
        // has no staleness guard for `headingLevel`/`markdownFragment` the way it has one
        // for a Notes row's label -- the late editor batch's stale level 1 silently wins,
        // reverting the patch's own level-2 correction. Asserting the ACTUAL behavior,
        // not the originally-claimed (and never actually exercised) one.
        #expect(final.headingLevel == 1, Comment(rawValue:
                "documented residual: the late editor batch's stale level silently reverts the patch's " +
                "correction -- see this test's own doc comment"))
        #expect(final.markdownFragment.hasPrefix("# ") && !final.markdownFragment.hasPrefix("## "), Comment(rawValue:
                "documented residual: the marker reverts to the editor's stale single-# level too"))
    }

    // T14
    @Test("""
        every system-write body runs inside exactly one transaction -- writeBibliographyRows, writeBibliographyRemoval, the \
        rename body, reconcileNotesBlocks, writeNotesRemoval, and patchHeadingLevels all apply cleanly with no GRDB reentrancy \
        trap
        """)
    func everySystemWriteBodyRunsInsideExactlyOneTransaction() async throws {
        let helper = DocumentWriterTests()
        let (db, pid, writer, _, _) = try helper.makeWriterStack()
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        let headingBlock = try #require(TestFixtureFactory.headingBlocks(try TestFixtureFactory.fetchBlocks(from: db)).first)

        struct UnexpectedOutcome: Error, CustomStringConvertible {
            let description: String
        }
        @discardableResult
        func apply<R: Sendable>(
            _ kind: SystemWriteKind, _ body: @escaping @Sendable (Database) throws -> SystemWriteBody<R>
        ) async throws -> R {
            let ticket = writer.reserveSystem()
            let outcome = await writer.applySystemWrite(ticket.seq, kind: kind, identity: identity, body: body)
            guard case .applied(let value) = outcome else {
                throw UnexpectedOutcome(description: "expected .applied for \(kind), got \(outcome)")
            }
            return value
        }

        // Each of these, if it ever opened its OWN nested `db.write`/`dbWriter.write`
        // transaction instead of using the `Database` parameter it was already handed,
        // would trap ("not reentrant") the instant `DocumentWriter.applySystemWrite`'s
        // own already-open transaction tried to run it -- every `applied` result below
        // is therefore direct proof of no such nesting, not just a functional check.
        try await apply(.bibliographyUpdate) { db in
            try BibliographySyncService.writeBibliographyRows(db: db, content: "# Bibliography\n\nEntry one.", projectId: pid)
        }
        try await apply(.bibliographyRemoval) { db in
            try BibliographySyncService.writeBibliographyRemoval(db: db, projectId: pid)
        }
        try await apply(.bibliographyRename) { db in
            _ = BibliographyHeadingRenamer.renameInTransaction(db: db, projectId: pid, from: ["Bibliography"], to: "Works Cited")
            return SystemWriteBody(value: 1)
        }
        try await apply(.notesUpdate) { db in
            try FootnoteSyncService.writeNotesReconciliation(db: db, projectId: pid, targetRefs: ["1"], renameMap: [:])
        }
        try await apply(.notesRemoval) { db in
            SystemWriteBody(value: try FootnoteSyncService.writeNotesRemoval(db: db, projectId: pid))
        }
        try await apply(.headingLevels) { db in
            ContentView.patchHeadingLevels(db: db, projectId: pid, changes: [(id: headingBlock.id, oldLevel: 1, newLevel: 2)])
        }
    }

    // T7 (T6 -- the reserve-time/`performSystemWrite` identity-mismatch refusal -- is
    // already covered by SystemWriteOrderingTests.swift's W36 test, case 4).
    @Test("""
        an identity mismatch is refused at APPLY time by DocumentWriter.applySystemWrite's own check, leaving the reservation \
        open for a correctly-identified retry
        """)
    func identityMismatchRefusedAtApplyTime_leavesReservationOpenForRetry() async throws {
        let (db, pid, writer) = try makeWriterOnlyStack()
        let otherDb = try TestFixtureFactory.createTemporary()
        let otherPid = try TestFixtureFactory.getProjectId(from: otherDb)
        let mismatched = SystemWriteIdentity(projectId: otherPid, database: otherDb)

        let ticket = writer.reserveSystem()
        let mismatchOutcome = await writer.applySystemWrite(
            ticket.seq, kind: .headingLevels, identity: mismatched
        ) { _ in SystemWriteBody(value: 1) }
        guard case .refused(.identityMismatch) = mismatchOutcome else {
            Issue.record("expected .refused(.identityMismatch), got \(mismatchOutcome)")
            return
        }

        // The identity check runs BEFORE the admission lock even opens, so it never
        // settles the phase entry -- the SAME reservation is still open and a retry
        // with the correct identity must still be able to apply.
        let correct = SystemWriteIdentity(projectId: pid, database: db)
        let retryOutcome = await writer.applySystemWrite(
            ticket.seq, kind: .headingLevels, identity: correct
        ) { _ in SystemWriteBody(value: 42) }
        guard case .applied(let value) = retryOutcome else {
            Issue.record("expected the correctly-identified retry to apply, got \(retryOutcome)")
            return
        }
        #expect(value == 42)
    }
}
