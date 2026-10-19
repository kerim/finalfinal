//
//  SectionReinsertJobTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2b, plan-v2-addendum 5 and 6.2, plan-v3-addendum D9): the queued database half of the quick undo,
//  `SectionReinsertJob` as a `SystemWriteKind.sectionReinsert` system write.
//
//  Driven the way `SectionDeleteJobTests` drives the delete job: a `DocumentWriter` on a temporary project, no WebView, no JS. The
//  tests start from "the editor shows the pre-delete document again, and the payload holder holds the rows the delete job saw" and
//  pin what the job makes of the table: it ends EXACTLY equal to the payload, whatever the delete job and the derived rewrites that
//  followed it left behind.
//
//  Targeted breaks (S's patches, see swift-break-map.md): sw27 (the reinsert reads the slot), sw28 (a failed holder is not checked),
//  sw29 (rows outside the payload are kept), sw30 (differing rows are not updated), sw39 (region-only payload).
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("SectionReinsertJob — Phase 4b slice 2b (Tier 2)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SectionReinsertJobTests {

    // MARK: - Fixture

    private struct Rig {
        let db: ProjectDatabase
        let pid: String
        let writer: DocumentWriter
        let slots: SectionDeleteSlotStore
        let holder: SectionDeletePayloadHolder
        let opId: UUID
        var identity: SystemWriteIdentity { SystemWriteIdentity(projectId: pid, database: db) }
    }

    private static let threeSections = """
    # First Chapter

    The first chapter's body.

    ## Second Section

    The second section's body.

    ## Third Section

    The third section's body.
    """

    private func makeRig(markdown: String? = nil) throws -> Rig {
        let db = try TestFixtureFactory.createTemporary(content: markdown ?? Self.threeSections)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let opId = UUID()
        return Rig(
            db: db, pid: pid, writer: DocumentWriter(database: db, projectId: pid), slots: SectionDeleteSlotStore(),
            holder: SectionDeletePayloadHolder(opId: opId, rootId: "unset", projectId: pid), opId: opId)
    }

    /// Plain (non-async) database helpers: inside an `async` test `dbWriter.write` resolves to GRDB's async overload.
    private func deleteRows(_ rig: Rig, _ ids: [String]) throws {
        try rig.db.dbWriter.write { database in _ = try Block.filter(keys: ids).deleteAll(database) }
    }

    private func updateRow(_ rig: Rig, _ block: Block) throws {
        try rig.db.dbWriter.write { database in try block.update(database) }
    }

    private func insertRow(_ rig: Rig, _ block: Block) throws {
        var copy = block
        try rig.db.dbWriter.write { database in try copy.insert(database) }
    }

    private func rows(_ rig: Rig) throws -> [Block] {
        try rig.db.fetchBlocks(projectId: rig.pid).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The rows as the delete job would have recorded them, with the holder filled.
    private func recordPayload(_ rig: Rig, root: Block, leaders: [Block] = []) throws -> [Block] {
        let payload = try rows(rig)
        rig.holder.fill(rows: payload, leaders: leaders, resolvedRootId: root.id)
        return payload
    }

    private func job(_ rig: Rig) -> SectionReinsertJob {
        SectionReinsertJob(opId: rig.opId, projectId: rig.pid, holder: rig.holder, slots: rig.slots)
    }

    private func run(_ rig: Rig) async -> SystemWriteOutcome<SectionReinsertJob.Output> {
        let job = job(rig)
        let ticket = rig.writer.reserveSystem()
        return await rig.writer.applySystemWrite(ticket.seq, kind: .sectionReinsert, identity: rig.identity) { database in
            try job.run(db: database)
        }
    }

    private func applied(_ outcome: SystemWriteOutcome<SectionReinsertJob.Output>) throws -> SectionReinsertJob.Output {
        guard case .applied(let output) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            throw CancellationError()
        }
        return output
    }

    private func heading(_ rig: Rig, _ title: String) throws -> Block {
        try #require(try rows(rig).first { $0.blockType == .heading && $0.textContent == title })
    }

    // MARK: - Tests

    // testInsertsMissingRowsWithIdsAndMetadata: the deleted section's rows come back with their own ids, text, level, section metadata and
    // sort order
    @Test("testInsertsMissingRowsWithIdsAndMetadata: the deleted section's rows come back with their own ids")
    func testInsertsMissingRowsWithIdsAndMetadata() async throws {
        let rig = try makeRig()
        var second = try heading(rig, "Second Section")
        second.status = .writing
        second.tags = ["draft", "keep"]
        second.wordGoal = 800
        try updateRow(rig, second)
        let payload = try recordPayload(rig, root: second, leaders: [second])
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: second.id, projectId: rig.pid))
        #expect(subtree.count >= 2)
        try deleteRows(rig, subtree)
        #expect(try rows(rig).count == payload.count - subtree.count, "precondition: the section is gone")

        let output = try applied(await run(rig))

        let after = try rows(rig)
        #expect(after.map(\.id) == payload.map(\.id), "every payload row is back under its own id, in the payload's order")
        #expect(Set(output.insertedIds) == Set(subtree), "exactly the deleted rows were inserted: \(output.insertedIds)")
        #expect(output.updatedIds.isEmpty && output.deletedIds.isEmpty)
        let restored = try #require(after.first { $0.id == second.id })
        #expect(restored.status == .writing && restored.tags == ["draft", "keep"] && restored.wordGoal == 800, "the section metadata came back")
        #expect(restored.textContent == "Second Section" && restored.headingLevel == 2)
        #expect(restored.sortOrder == second.sortOrder, "the original sort order is kept")
        #expect(output.wroteRows)
    }

    @Test("testKeepsOriginalSortOrderWhenItFits: every restored row has exactly the sort order it had before the delete")
    func testKeepsOriginalSortOrderWhenItFits() async throws {
        let rig = try makeRig()
        let second = try heading(rig, "Second Section")
        let payload = try recordPayload(rig, root: second)
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: second.id, projectId: rig.pid))
        try deleteRows(rig, subtree)

        _ = try applied(await run(rig))

        let sortOrders = Dictionary(uniqueKeysWithValues: try rows(rig).map { ($0.id, $0.sortOrder) })
        for row in payload {
            #expect(
                sortOrders[row.id] == row.sortOrder,
                "row \(row.textContent): sort order \(String(describing: sortOrders[row.id])) != \(row.sortOrder)")
        }
    }

    @Test("testUpdatesDerivedRows: a present row that differs from the payload (a renumbered reference, a cleaned Notes definition) is put back")
    func testUpdatesDerivedRows() async throws {
        let rig = try makeRig()
        let second = try heading(rig, "Second Section")
        let payload = try recordPayload(rig, root: second)
        let third = try #require(payload.first { $0.textContent == "The third section's body." })
        var rewritten = third
        rewritten.textContent = "The third section's body, renumbered."
        rewritten.markdownFragment = "The third section's body, renumbered."
        try updateRow(rig, rewritten)

        let output = try applied(await run(rig))

        let back = try #require(try rows(rig).first { $0.id == third.id })
        #expect(
            back.textContent == third.textContent && back.markdownFragment == third.markdownFragment,
            "expected the updated row to equal the payload row")
        #expect(output.updatedIds == [third.id], "only the differing row was updated: \(output.updatedIds)")
        #expect(output.insertedIds.isEmpty && output.deletedIds.isEmpty)
    }

    // testDeletesEveryNonPayloadRowAndLogsUserRows: rows outside the payload go, managed or not; the user's own are logged, a
    // re-identified copy only counted
    @Test("testDeletesEveryNonPayloadRowAndLogsUserRows: rows outside the payload go")
    func testDeletesEveryNonPayloadRowAndLogsUserRows() async throws {
        let rig = try makeRig()
        let second = try heading(rig, "Second Section")
        let payload = try recordPayload(rig, root: second)
        let last = try #require(payload.last)
        // 1: a paragraph the payload never had (typed after the delete and not in the restored document);
        // 2: a Notes row the delete's resync wrote;
        // 3: a copy of a payload row under another id (the idle backup's whole-document rewrite does that).
        let stray = Block(
            projectId: rig.pid, sortOrder: last.sortOrder + 1, blockType: .paragraph, textContent: "STRAY-USER-ROW",
            markdownFragment: "STRAY-USER-ROW")
        let notes = Block(
            projectId: rig.pid, sortOrder: last.sortOrder + 2, blockType: .paragraph, textContent: "[^1]: a definition the resync wrote",
            markdownFragment: "[^1]: a definition the resync wrote", isNotes: true)
        let copyOf = try #require(payload.first { $0.textContent == "The first chapter's body." })
        let copy = Block(
            projectId: rig.pid, sortOrder: last.sortOrder + 3, blockType: .paragraph, textContent: copyOf.textContent,
            markdownFragment: copyOf.markdownFragment)
        for row in [stray, notes, copy] { try insertRow(rig, row) }
        // An observer, not the sink (fix round F1, review C7): `DebugLog.alwaysSink` is process-wide and other suites replace and clear it.
        let capture = AlwaysLogCapture()
        let observer = DebugLog.addAlwaysObserver { capture.append($0) }
        defer { DebugLog.removeAlwaysObserver(observer) }

        let output = try applied(await run(rig))

        let remaining = Set(try rows(rig).map(\.id))
        #expect(remaining == Set(payload.map(\.id)), "expected the rows outside the payload to be gone")
        #expect(Set(output.deletedIds) == [stray.id, notes.id, copy.id])
        #expect(output.deletedUserRows == 2, "the stray row and the copy are the user's; the Notes row is not: \(output.deletedUserRows)")
        #expect(output.deletedReidentifiedRows == 1, "the copy only repeats a payload row")
        let lines = capture.captured.filter { $0.contains("reinsert removed a row not in the pre-delete document") }
        #expect(lines.count == 1 && lines.first?.contains("STRAY-USER-ROW") == true, "only the stray user row is logged, with its text: \(lines)")
    }

    @Test("testHolderFailedDoesNothing: when the delete job did not apply, the reinsert writes nothing")
    func testHolderFailedDoesNothing() async throws {
        let rig = try makeRig()
        let second = try heading(rig, "Second Section")
        let before = try rows(rig)
        rig.holder.markFailed()
        // The rows a failed delete job never recorded would, read as a payload, empty the project: this is what the check prevents.
        #expect(rig.holder.outcome == .failed)

        let output = try applied(await run(rig))

        #expect(!output.wroteRows)
        #expect(try rows(rig) == before, "expected the rows to be unchanged when the delete job did not apply")
        #expect(try rows(rig).contains { $0.id == second.id })
    }

    @Test("testPendingHolderDoesNothing: a holder the delete job has not filled yet is never read as an empty document")
    func testPendingHolderDoesNothing() async throws {
        let rig = try makeRig()
        let before = try rows(rig)
        #expect(rig.holder.outcome == .pending)

        let output = try applied(await run(rig))

        #expect(!output.wroteRows)
        #expect(try rows(rig) == before)
    }

    // testSlotMovesToReinsertedOnlyFromQuickUndone: the transaction's commit marks the slot, and a slot a quick redo has already moved on
    // is left alone
    @Test("testSlotMovesToReinsertedOnlyFromQuickUndone: the transaction's commit marks the slot")
    func testSlotMovesToReinsertedOnlyFromQuickUndone() async throws {
        let rig = try makeRig()
        let second = try heading(rig, "Second Section")
        _ = try recordPayload(rig, root: second)
        try deleteRows(rig, try #require(try rig.db.sectionBlockIds(rootId: second.id, projectId: rig.pid)))
        rig.slots.open(rig.opId)
        defer { rig.slots.removeAll() }
        rig.slots.markQuickUndone(rig.opId)

        _ = try applied(await run(rig))
        #expect(rig.slots.slot(rig.opId)?.state == .reinserted)

        // A redo that ran first moved the slot back to `reserved`: the reinsert's commit must not move it again.
        rig.slots.markReserved(rig.opId)
        #expect(rig.slots.slot(rig.opId)?.state == .reserved)
        _ = try applied(await run(rig))
        #expect(rig.slots.slot(rig.opId)?.state == .reserved, "only quickUndone becomes reinserted")
    }

    @Test("testBrokenParentChainRollsBack: a payload row whose parent is nowhere writes nothing at all")
    func testBrokenParentChainRollsBack() async throws {
        let rig = try makeRig()
        let second = try heading(rig, "Second Section")
        var payload = try recordPayload(rig, root: second)
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: second.id, projectId: rig.pid))
        try deleteRows(rig, subtree)
        let before = try rows(rig)
        payload.append(Block(
            projectId: rig.pid, parentId: "a-parent-that-never-existed", sortOrder: 99, blockType: .listItem,
            textContent: "orphan item", markdownFragment: "- orphan item"))
        rig.holder.fill(rows: payload, leaders: [], resolvedRootId: second.id)

        let outcome = await run(rig)

        guard case .failed = outcome else {
            Issue.record("expected .failed for a broken parent chain, got \(outcome)")
            return
        }
        #expect(try rows(rig) == before, "the transaction rolled back: no row was inserted before the broken one was found")
    }

    @Test("testATableThatAlreadyEqualsThePayloadIsLeftAlone: nothing missing, nothing differing, nothing extra: nothing is written")
    func testATableThatAlreadyEqualsThePayloadIsLeftAlone() async throws {
        let rig = try makeRig()
        let second = try heading(rig, "Second Section")
        let payload = try recordPayload(rig, root: second)
        let before = try rig.db.fetchBlocks(projectId: rig.pid).count

        let output = try applied(await run(rig))

        // With nothing missing and nothing differing the job writes nothing; a row of another project could never be in its read.
        #expect(try rig.db.fetchBlocks(projectId: rig.pid).count == before)
        #expect(
            output.insertedIds.isEmpty && output.updatedIds.isEmpty && output.deletedIds.isEmpty,
            "a table that already equals the payload is left alone")
        #expect(payload.count == before)
    }

    // Round 1c (plan-v3 D9 / review row S6). Reads the always-persisted log through a private observer (fix round F1, review C7: it used
    // to replace the process-wide `DebugLog.alwaysSink`, which other suites also set and clear while this one ran).
    // The sidebar-only fields and the many-copies case are in SectionReinsertMetadataTests.swift.
    @Test("testExpectedRemovalsAreRemovedCountedAndNotLogged: the operation's own rows go quietly, an unexpected row is still logged")
    func testExpectedRemovalsAreRemovedCountedAndNotLogged() async throws {
        let rig = try makeRig()
        let second = try heading(rig, "Second Section")
        let payload = try recordPayload(rig, root: second)
        let last = try #require(payload.last)
        let copyHeading = Block(
            projectId: rig.pid, sortOrder: last.sortOrder + 1, blockType: .heading, textContent: "COPYTEST-HEADING copy",
            markdownFragment: "## COPYTEST-HEADING copy", headingLevel: 2)
        let copyBody = Block(
            projectId: rig.pid, sortOrder: last.sortOrder + 2, blockType: .paragraph, textContent: "COPYTEST-BODY",
            markdownFragment: "COPYTEST-BODY")
        let stray = Block(
            projectId: rig.pid, sortOrder: last.sortOrder + 3, blockType: .paragraph, textContent: "COPYTEST-STRAY-UNEXPECTED",
            markdownFragment: "COPYTEST-STRAY-UNEXPECTED")
        for inserted in [copyHeading, copyBody, stray] { try insertRow(rig, inserted) }
        var configured = job(rig)
        configured.expectedRemovals = [copyHeading.id, copyBody.id]
        configured.operationLabel = "duplicate"
        let duplicateJob = configured
        // An observer, not the sink (fix round F1, review C7): `DebugLog.alwaysSink` is process-wide and other suites replace and clear
        // it while this one runs, which could take this test's line away.
        let capture = AlwaysLogCapture()
        let observer = DebugLog.addAlwaysObserver { capture.append($0) }
        defer { DebugLog.removeAlwaysObserver(observer) }

        let ticket = rig.writer.reserveSystem()
        let outcome = await rig.writer.applySystemWrite(ticket.seq, kind: .sectionReinsert, identity: rig.identity) { database in
            try duplicateJob.run(db: database)
        }
        let output = try applied(outcome)

        #expect(Set(try rows(rig).map(\.id)) == Set(payload.map(\.id)), "every row outside the payload is gone, expected or not")
        #expect(Set(output.deletedIds) == [copyHeading.id, copyBody.id, stray.id])
        #expect(output.deletedExpectedRows == 2, "the operation's own two rows are counted as expected: \(output.deletedExpectedRows)")
        #expect(output.deletedUserRows == 1, "only the unexpected row counts as a lost user row: \(output.deletedUserRows)")
        let mine = capture.captured.filter { $0.contains("COPYTEST-") || $0.contains(stray.id) }   // the sink is shared with other suites
        #expect(mine.count == 1 && mine.first?.contains("COPYTEST-STRAY-UNEXPECTED") == true, "only the unexpected row is logged: \(mine)")
        #expect(
            mine.first?.contains("not in the pre-duplicate document") == true,
            "the wording names the operation that was undone: \(mine.first ?? "no line")")
    }
}
