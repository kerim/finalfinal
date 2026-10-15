//
//  MarkdownBlockWriteTests.swift
//  final finalTests
//
//  t-94369a83 Phase 4a, plan v2 section 3, tests U2 (a), (c), (i), plus the service-level checks of judge notes C1 and C2
//  and of plan 1(d) step 6 (the stale-epoch outcome). These need only the service entry
//  (`BlockSyncService.reserveMarkdownTurn` / `applyMarkdownTurn` / `ensureWriter`) and the REAL writer and database: no
//  editor view state, no debounce, no bibliography flush. The cases that need the view-state wiring are in their own
//  files (coder C2): U2 d, e, f, g in MarkdownBlockWriteRaceTests; U2 a (at article length), b, h, k, l, m and the model
//  ruling's M2 in MarkdownBlockWriteTypingTests; U2 j in MarkdownBlockWriteRefusedEditTests; U3 b, c and the M5 guards in
//  MarkdownWriterLifecycleOrderTests (U3 a is MarkdownReparseGatingTests); U4's wiring in MarkdownWriterInstallTests; U5 in
//  MarkdownBibliographyFlushTests. All share Helpers/MarkdownWriterRig.swift.
//
//  "Hold" means: reserve a system sequence (`DocumentWriter.reserveSystem()`) and apply it later through
//  `applySystemWrite`, exactly as `DocumentWriterSystemWriteTests` does (RESOLVED VERIFY-FIRST: that file's
//  `systemWriteWaitsBehindEditorSequence`, lines 39-65, applies a reserved system ticket with
//  `writer.applySystemWrite(ticket.seq, kind:, identity:) { _ in SystemWriteBody(value:) }`; there is no separate
//  "release" call).
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Markdown block writes through the writer — Tier 2 (t-94369a83 Phase 4a)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownBlockWriteTests {

    // MARK: - Helpers

    private func parse(_ markdown: String, projectId: String) -> [Block] {
        BlockParser.parse(markdown: markdown, projectId: projectId, bibliographyHeaderName: "Bibliography", graceNames: [])
    }

    private func rows(_ db: ProjectDatabase) throws -> [Block] {
        MarkdownBlockDiff.assemblyOrderedNonEmpty(try TestFixtureFactory.fetchBlocks(from: db))
    }

    /// `[id: [lastWriteEpoch, lastWriteSequence]]` for every row.
    private func stamps(_ db: ProjectDatabase) throws -> [String: [Int64]] {
        try db.read { database in
            var result: [String: [Int64]] = [:]
            for row in try Row.fetchAll(database, sql: "SELECT id, lastWriteEpoch, lastWriteSequence FROM block") {
                result[row["id"] as String] = [row["lastWriteEpoch"] as Int64, row["lastWriteSequence"] as Int64]
            }
            return result
        }
    }

    private func reserve(_ stack: TestStack, sourceLocation: SourceLocation = #_sourceLocation) throws -> MarkdownTurn {
        let reservation = stack.sync.reserveMarkdownTurn(database: stack.db, projectId: stack.pid)
        guard case .reserved(let turn) = reservation else {
            Issue.record("expected a reserved turn, got \(reservation)", sourceLocation: sourceLocation)
            throw ReservationFailed()
        }
        return turn
    }

    private struct ReservationFailed: Error {}

    private func ensure(
        _ sync: BlockSyncService, _ db: ProjectDatabase, _ pid: String, lifecycleActive: Bool, editorProjectId: String?
    ) -> EnsureWriterOutcome {
        sync.ensureWriter(database: db, projectId: pid, lifecycleActive: lifecycleActive, editorProjectId: editorProjectId)
    }

    // MARK: - (a) only the changed rows are written

    @Test("(a) a Markdown batch writes only the changed rows; every other row's id and stamp are untouched")
    func onlyChangedRowsWritten() async throws {
        let oldText = "# Alpha\n\nOne.\n\nTwo.\n\nThree.\n\n# Beta\n\nFour."
        let newText = "# Alpha\n\nOne.\n\nTwo, edited.\n\nThree.\n\nInserted after three.\n\n# Beta\n\nFour."
        let stack = try makeStack(content: oldText)
        let before = try rows(stack.db)
        let stampsBefore = try stamps(stack.db)
        let epochBefore = try stack.db.currentBlockWriteEpoch(projectId: stack.pid)
        try #require(before.map(\.markdownFragment) == ["# Alpha", "One.", "Two.", "Three.", "# Beta", "Four."])

        let diff = MarkdownBlockDiff.diff(rows: before, new: parse(newText, projectId: stack.pid))
        #expect(diff.changes.updates.count == 1 && diff.changes.inserts.count == 1 && diff.changes.deletes.isEmpty)

        let turn = try reserve(stack)
        let outcome = await stack.sync.applyMarkdownTurn(turn, diff.changes)
        guard case .applied(let applied) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(outcome.isClean)
        #expect(applied.writtenUpdateIds == [before[2].id])
        #expect(applied.writtenInsertIds.count == 1)
        #expect(applied.writtenDeleteIds.isEmpty)

        // The database now holds exactly the new text.
        let after = try rows(stack.db)
        #expect(BlockParser.assembleMarkdown(from: after) == newText)

        // Same ids for every pre-existing row; the one new row is new.
        #expect(Set(before.map(\.id)).isSubset(of: Set(after.map(\.id))))
        #expect(after.count == before.count + 1)

        // Stamps: only the rows the batch wrote moved, and to this batch's own (epoch, sequence).
        let stampsAfter = try stamps(stack.db)
        let writtenIds = Set(applied.writtenUpdateIds + applied.writtenInsertIds)
        for block in before where !writtenIds.contains(block.id) {
            #expect(stampsAfter[block.id] == stampsBefore[block.id], "untouched row \(block.markdownFragment) kept its stamp")
        }
        for id in writtenIds {
            #expect(stampsAfter[id] == [turn.stamp.epoch, turn.stamp.sequence])
        }
        // The batch never bumps the epoch.
        #expect(try stack.db.currentBlockWriteEpoch(projectId: stack.pid) == epochBefore)
        #expect(stack.sync.testWriterLedger.markdownStaleEpochRejections == 0)
    }

    // MARK: - (c) the wait-for-turn probe

    @Test("(c) a Markdown batch reserved behind a held system sequence waits for it, then applies, with no .outOfTurn")
    func waitsForAHeldSystemSequence() async throws {
        let stack = try makeStack(content: "# Alpha\n\nOne.\n\nTwo.")
        let writer = try #require(stack.sync.testWriterHandle)
        let recorder = WriterEventRecorder()
        let parked = WriterEventSignal(matching: { if case .parked = $0 { return true }; return false })
        stack.sync.testWriterEventHandler = { event in
            recorder.append(event)
            parked.note(event)
        }

        // Hold: a system sequence is reserved first (seq 1) and not yet applied.
        let held = writer.reserveSystem()
        let before = try rows(stack.db)
        let diff = MarkdownBlockDiff.diff(rows: before, new: parse("# Alpha\n\nOne, edited.\n\nTwo.", projectId: stack.pid))
        #expect(diff.changes.updates.count == 1)

        let turn = try reserve(stack)
        #expect(turn.ticket.seq == held.seq + 1, "the Markdown turn is ordered behind the held sequence")

        let applying = Task { @MainActor in await stack.sync.applyMarkdownTurn(turn, diff.changes) }
        await parked.wait()   // the batch is parked on its turn, not applied

        #expect(try rows(stack.db).map(\.markdownFragment) == before.map(\.markdownFragment), "nothing is written while the held sequence is open")

        // Release: the held system sequence applies; the Markdown batch's turn comes next.
        let identity = SystemWriteIdentity(projectId: stack.pid, database: stack.db)
        let released = await writer.applySystemWrite(held.seq, kind: .headingLevels, identity: identity) { _ in
            SystemWriteBody(value: 1)
        }
        guard case .applied = released else {
            Issue.record("expected the held system write to apply, got \(released)")
            return
        }
        let outcome = await applying.value
        guard case .applied = outcome else {
            Issue.record("expected the Markdown batch to apply after the held sequence, got \(outcome)")
            return
        }
        #expect(outcome.isClean)
        #expect(try rows(stack.db).map(\.markdownFragment) == ["# Alpha", "One, edited.", "Two."])

        let events = recorder.all
        #expect(!events.contains { if case .refused(_, .outOfTurn) = $0 { return true }; return false }, "no .outOfTurn refusal")
        #expect(events.contains { if case .systemApplied(held.seq) = $0 { return true }; return false })
        let ledger = stack.sync.testWriterLedger
        #expect(ledger.systemWritesApplied == 1 && ledger.failedWrites == 0 && ledger.discardedAfterFetch == 0)
    }

    // MARK: - (i) the renumber probe

    private func chainedInserts(count: Int, after anchorId: String) -> BlockChanges {
        var inserts: [BlockInsert] = []
        for number in 1...count {
            let fragment = String(format: "Inserted %02d.", number)
            inserts.append(BlockInsert(
                tempId: "temp-md-\(number)", blockType: "paragraph", textContent: fragment, markdownFragment: fragment,
                headingLevel: nil, afterBlockId: number == 1 ? anchorId : "temp-md-\(number - 1)", atDocumentStart: nil))
        }
        return BlockChanges(inserts: inserts)
    }

    private var tenParagraphsAndABibliographyHeading: String {
        (1...10).map { String(format: "Paragraph %02d.", $0) }.joined(separator: "\n\n") + "\n\n# Bibliography"
    }

    @Test("(i) 80 chained inserts in one batch keep every row distinct and in order (the renumber guard), with no restamp and no epoch bump")
    func eightyChainedInsertsRenumber() async throws {
        let stack = try makeStack(content: tenParagraphsAndABibliographyHeading)
        let before = try rows(stack.db)
        let stampsBefore = try stamps(stack.db)
        let epochBefore = try stack.db.currentBlockWriteEpoch(projectId: stack.pid)
        let anchor = try #require(before.first { $0.markdownFragment == "Paragraph 05." })
        let changes = chainedInserts(count: 80, after: anchor.id)

        let turn = try reserve(stack)
        let outcome = await stack.sync.applyMarkdownTurn(turn, changes)
        guard case .applied(let applied) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(outcome.isClean)
        #expect(applied.writtenInsertIds.count == 80)

        // Assembly order is exactly the intended order.
        let after = try rows(stack.db)
        let expected = (1...5).map { String(format: "Paragraph %02d.", $0) }
            + (1...80).map { String(format: "Inserted %02d.", $0) }
            + (6...10).map { String(format: "Paragraph %02d.", $0) } + ["# Bibliography"]
        #expect(after.map(\.markdownFragment) == expected)

        // No two rows share a sort order, they strictly increase, and none is crowded.
        let orders = after.map(\.sortOrder)
        #expect(Set(orders).count == orders.count, "no two rows share a sortOrder")
        #expect(zip(orders, orders.dropFirst()).allSatisfy { $0 < $1 })
        let smallestGap = zip(orders, orders.dropFirst()).map { $1 - $0 }.min() ?? 1
        #expect(smallestGap >= ProjectDatabase.crowdedSortOrderGap, "smallest gap \(smallestGap)")

        // RESOLVED VERIFY-FIRST (plan 1(b)): renumbering restamps nothing and bumps no epoch.
        #expect(try stack.db.currentBlockWriteEpoch(projectId: stack.pid) == epochBefore)
        let stampsAfter = try stamps(stack.db)
        for block in before {
            #expect(stampsAfter[block.id] == stampsBefore[block.id], "pre-existing row \(block.markdownFragment) kept its stamp")
        }
        for id in applied.writtenInsertIds {
            #expect(stampsAfter[id] == [turn.stamp.epoch, turn.stamp.sequence])
        }
    }

    @Test("(i) control: the same 80 chained inserts through the Rich Text path (guard off) DO collapse sort orders")
    func eightyChainedInsertsCollapseWithoutTheGuard() throws {
        let db = try TestFixtureFactory.createTemporary(content: tenParagraphsAndABibliographyHeading)
        let before = try rows(db)
        let anchor = try #require(before.first { $0.markdownFragment == "Paragraph 05." })
        try db.applyBlockChangesFromEditor(chainedInserts(count: 80, after: anchor.id), for: try TestFixtureFactory.getProjectId(from: db))
        let orders = try rows(db).map(\.sortOrder)
        #expect(Set(orders).count < orders.count, "premise: without renumbering the halving runs out and rows share a sortOrder")
    }

    // MARK: - Judge note C1: the reservation is synchronous

    @Test("C1: the reservation exists the moment the synchronous part returns; a retire between it and the apply makes the apply skip, never write")
    func reservationIsSynchronousAndSurvivesNoRetire() async throws {
        let stack = try makeStack(content: "# Alpha\n\nOne.\n\nTwo.")
        let writer = try #require(stack.sync.testWriterHandle)
        let before = try rows(stack.db)
        let diff = MarkdownBlockDiff.diff(rows: before, new: parse("# Alpha\n\nOne, edited.\n\nTwo.", projectId: stack.pid))
        let sequenceBefore = writer.nextSequence

        // (i) synchronous part: no Task was created, yet the sequence is already reserved.
        let turn = try reserve(stack)
        #expect(writer.nextSequence == sequenceBefore + 1)
        #expect(turn.ticket.seq == sequenceBefore)

        // A lifecycle-style retire lands between the reservation and the apply.
        writer.retire(reason: .close)

        // (ii) the async part finds its turn skipped and writes nothing.
        let outcome = await stack.sync.applyMarkdownTurn(turn, diff.changes)
        guard case .skipped = outcome else {
            Issue.record("expected .skipped, got \(outcome)")
            return
        }
        #expect(outcome.countsAsRefusal)
        #expect(try rows(stack.db).map(\.markdownFragment) == before.map(\.markdownFragment), "nothing was written")
        #expect(stack.sync.testWriterLedger.skippedConsumed == 1, "the reserved, fetched sequence is counted as skipped-consumed")
    }

    @Test("C1: with no writer, or a writer for another database, nothing is reserved")
    func reservationRefusals() throws {
        let stack = try makeStack()
        let otherDatabase = try TestFixtureFactory.createTemporary(content: "# Elsewhere\n\nText.")
        let writer = try #require(stack.sync.testWriterHandle)
        let sequenceBefore = writer.nextSequence

        guard case .refused(.identityMismatch) = stack.sync.reserveMarkdownTurn(database: otherDatabase, projectId: stack.pid) else {
            Issue.record("expected .refused(.identityMismatch) for another database")
            return
        }
        guard case .refused(.identityMismatch) = stack.sync.reserveMarkdownTurn(database: stack.db, projectId: "another-project") else {
            Issue.record("expected .refused(.identityMismatch) for another project id")
            return
        }
        #expect(writer.nextSequence == sequenceBefore, "a refusal reserves nothing")

        let bare = BlockSyncService()
        guard case .refused(.noWriter) = bare.reserveMarkdownTurn(database: stack.db, projectId: stack.pid) else {
            Issue.record("expected .refused(.noWriter)")
            return
        }
    }

    // MARK: - Plan 1(d) step 6: the stale-epoch rejection is its own outcome

    @Test("a batch refused whole for a stale epoch is .staleEpoch, counted in markdownStaleEpochRejections, and writes nothing")
    func staleEpochIsItsOwnOutcome() async throws {
        let stack = try makeStack(content: "# Alpha\n\nOne.\n\nTwo.")
        let before = try rows(stack.db)
        let diff = MarkdownBlockDiff.diff(rows: before, new: parse("# Alpha\n\nOne.\n\nTwo.\n\nBrand new.", projectId: stack.pid))
        #expect(diff.changes.inserts.count == 1 && diff.changes.updates.isEmpty && diff.changes.deletes.isEmpty)

        let turn = try reserve(stack)
        // A direct whole-document write (or a lifecycle write, or a configure) bumps the epoch after the reservation.
        try stack.db.bumpBlockWriteEpoch(projectId: stack.pid)

        let outcome = await stack.sync.applyMarkdownTurn(turn, diff.changes)
        guard case .staleEpoch(let result) = outcome else {
            Issue.record("expected .staleEpoch, got \(outcome)")
            return
        }
        #expect(result.rejectedWholeBatchForStaleEpoch)
        #expect(result.idMapping.isEmpty, "the inserts were dropped silently")
        #expect(!outcome.isClean && !outcome.countsAsRefusal)
        #expect(stack.sync.testWriterLedger.markdownStaleEpochRejections == 1)
        #expect(try rows(stack.db).map(\.markdownFragment) == before.map(\.markdownFragment), "nothing was written")
    }

    @Test("an update to a row a newer write stamped is dropped, so the batch is applied but NOT clean")
    func droppedUpdateIsNotClean() async throws {
        let stack = try makeStack(content: "# Alpha\n\nOne.\n\nTwo.")
        let before = try rows(stack.db)
        let target = try #require(before.first { $0.markdownFragment == "One." })
        let diff = MarkdownBlockDiff.diff(rows: before, new: parse("# Alpha\n\nOne, edited.\n\nTwo.", projectId: stack.pid))

        let turn = try reserve(stack)
        // A newer sequence wrote the row after this turn was reserved (as a later editor batch would have).
        try stack.db.write { database in
            try database.execute(
                sql: "UPDATE block SET lastWriteEpoch = ?, lastWriteSequence = ? WHERE id = ?",
                arguments: [turn.stamp.epoch, turn.stamp.sequence + 1_000, target.id])
        }
        let outcome = await stack.sync.applyMarkdownTurn(turn, diff.changes)
        guard case .applied(let result) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(result.droppedUpdateIds == [target.id])
        #expect(!outcome.isClean)
    }

    // MARK: - Judge note C2 / plan 1(e): ensureWriter (the service half; the wiring is a later step)

    @Test("ensureWriter installs a writer when there is none, bumps the epoch, and the Markdown entry then works")
    func ensureWriterInstalls() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Alpha\n\nOne.\n\nTwo.")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let sync = BlockSyncService()
        let epochBefore = try db.currentBlockWriteEpoch(projectId: pid)

        #expect(ensure(sync, db, pid, lifecycleActive: false, editorProjectId: pid) == .installed)
        let writer = try #require(sync.testWriterHandle)
        #expect(writer.database === db && writer.projectId == pid)
        #expect(try db.currentBlockWriteEpoch(projectId: pid) == epochBefore + 1)

        let before = try rows(db)
        let diff = MarkdownBlockDiff.diff(rows: before, new: parse("# Alpha\n\nOne, edited.\n\nTwo.", projectId: pid))
        guard case .reserved(let turn) = sync.reserveMarkdownTurn(database: db, projectId: pid) else {
            Issue.record("expected a reserved turn on the installed writer")
            return
        }
        guard case .applied = await sync.applyMarkdownTurn(turn, diff.changes) else {
            Issue.record("expected the batch to apply on the installed writer")
            return
        }
        #expect(try rows(db).map(\.markdownFragment) == ["# Alpha", "One, edited.", "Two."])
    }

    @Test("ensureWriter is a no-op while a lifecycle token is armed, and when the editor state names another project")
    func ensureWriterNoOps() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Alpha\n\nOne.")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let sync = BlockSyncService()

        #expect(ensure(sync, db, pid, lifecycleActive: true, editorProjectId: pid) == .skippedLifecycleActive)
        #expect(sync.testWriterHandle == nil)
        #expect(ensure(sync, db, pid, lifecycleActive: false, editorProjectId: "the-old-project") == .skippedProjectMismatch)
        #expect(sync.testWriterHandle == nil)
        #expect(ensure(sync, db, pid, lifecycleActive: false, editorProjectId: nil) == .skippedProjectMismatch)
        #expect(sync.testWriterHandle == nil)
    }

    @Test("ensureWriter is a no-op when a live writer already exists for this database and project, and never replaces one a lifecycle holds")
    func ensureWriterLeavesAnExistingWriterAlone() throws {
        let stack = try makeStack()   // `configure` created the writer
        let existing = try #require(stack.sync.testWriterHandle)

        #expect(ensure(stack.sync, stack.db, stack.pid, lifecycleActive: false, editorProjectId: stack.pid) == .alreadyPresent)
        #expect(stack.sync.testWriterHandle === existing)
        // Under a lifecycle token the answer is the lifecycle rule, whatever the writer's state.
        #expect(ensure(stack.sync, stack.db, stack.pid, lifecycleActive: true, editorProjectId: stack.pid) == .skippedLifecycleActive)
        #expect(stack.sync.testWriterHandle === existing)
    }

    @Test("ensureWriter replaces a retired writer and continues its sequence numbers")
    func ensureWriterReplacesARetiredWriter() throws {
        let stack = try makeStack()
        let old = try #require(stack.sync.testWriterHandle)
        _ = old.reserve()   // advance the sequence space
        let nextBefore = old.nextSequence
        old.retire(reason: .writerReplaced)

        #expect(ensure(stack.sync, stack.db, stack.pid, lifecycleActive: false, editorProjectId: stack.pid) == .installed)
        let replacement = try #require(stack.sync.testWriterHandle)
        #expect(replacement !== old)
        #expect(replacement.nextSequence == nextBefore, "sequence numbers continue across the replacement, so stamps stay monotonic")
    }
}
