//
//  SectionDeleteJobTests.swift
//  final finalTests
//
//  Tier 2: the queued background half of an editor-first section delete (t-94369a83 Phase 4b, slice 2a): `SectionDeleteJob`
//  as a `SystemWriteKind.sectionDelete` system write, its slot (`SectionDeleteSlotStore`) and its job futures
//  (`EFJobRegistry`). Plan tests U1, U3, U4, U6 (the outcome-resolution half) and U19.
//
//  Driven the way `DocumentWriterSystemWriteTests` drives the writer: no WebView, no JS. The editor's side of a delete (the
//  removal and its batch) is out of scope here; these tests start from "the editor removed the section and its batch has
//  been applied" and pin what the job does with the database.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("SectionDeleteJob — Phase 4b slice 2a (Tier 2)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SectionDeleteJobTests {

    // MARK: - Fixture

    private struct Rig {
        let db: ProjectDatabase
        let pid: String
        let writer: DocumentWriter
        let slots: SectionDeleteSlotStore
        var identity: SystemWriteIdentity { SystemWriteIdentity(projectId: pid, database: db) }
    }

    private func makeRig(markdown: String) throws -> Rig {
        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        return Rig(db: db, pid: pid, writer: DocumentWriter(database: db, projectId: pid), slots: SectionDeleteSlotStore())
    }

    private func makeJob(_ rig: Rig, opId: UUID, root: String) -> SectionDeleteJob {
        SectionDeleteJob(
            opId: opId, rootBlockId: root, projectId: rig.pid,
            fallbackBibliographyTitle: "Bibliography", slots: rig.slots)
    }

    /// Reserves the job's turn on the rig's writer and applies it (the job is the frontier: nothing else is open).
    private func apply(_ job: SectionDeleteJob, on rig: Rig) async -> SystemWriteOutcome<SectionDeleteJob.Output> {
        let ticket = rig.writer.reserveSystem()
        return await rig.writer.applySystemWrite(ticket.seq, kind: .sectionDelete, identity: rig.identity) { database, idMap in
            try job.run(db: database, idMap: idMap)
        }
    }

    /// The snapshot section list derived from the rows for `markdown`. A plain (non-async) function on purpose: inside an `async`
    /// test, `dbWriter.read` resolves to GRDB's async overload, which would need an `await` and a `@Sendable` closure.
    private func derivedSections(_ rig: Rig, markdown: String) throws -> [Section] {
        let pid = rig.pid
        return try rig.db.dbWriter.read { database in
            try SnapshotService.derivedSnapshotSections(
                db: database, projectId: pid, markdown: markdown, fallbackBibliographyTitle: "Bibliography")
        }
    }

    /// A middle chapter heading of the six-chapter book (level 1, neither Notes nor Bibliography).
    private func middleChapter(_ blocks: [Block]) throws -> Block {
        let chapters = blocks.filter { $0.blockType == .heading && $0.headingLevel == 1 && !$0.isNotes && !$0.isBibliography }
        #expect(chapters.count >= 4, "the six-chapter book has chapters to pick from (\(chapters.count))")
        return try #require(chapters.dropFirst(2).first)
    }

    // MARK: - U1

    @Test("testJobWritesSnapshotThenDeletes_book6")
    func testJobWritesSnapshotThenDeletes_book6() async throws {
        let rig = try makeRig(markdown: ComplexDocumentFixture.book6.editorMarkdown)
        let before = try rig.db.fetchBlocks(projectId: rig.pid)
        let chapter = try middleChapter(before)
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: chapter.id, projectId: rig.pid))
        let subtreeSet = Set(subtree)
        let assembledBefore = BlockParser.assembleMarkdownForEditor(from: before)
        let derivedBefore = try derivedSections(rig, markdown: assembledBefore)
        let epochBefore = try rig.db.currentBlockWriteEpoch(projectId: rig.pid)
        let snapshotCountBefore = try rig.db.countSnapshots(projectId: rig.pid)

        let opId = UUID()
        rig.slots.open(opId)
        defer { rig.slots.removeAll() }
        let outcome = await apply(makeJob(rig, opId: opId, root: chapter.id), on: rig)

        guard case .applied(let output) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        // The rows are gone, and only those rows.
        let after = try rig.db.fetchBlocks(projectId: rig.pid)
        #expect(Set(after.map(\.id)) == Set(before.map(\.id)).subtracting(subtreeSet))
        #expect(output.deletedBlockIds == before.map(\.id).filter { subtreeSet.contains($0) }, "reported in document order")
        // One snapshot was written, from the rows as they were BEFORE the delete, in the same transaction.
        #expect(try rig.db.countSnapshots(projectId: rig.pid) == snapshotCountBefore + 1)
        let snapshot = try #require(try rig.db.fetchSnapshot(id: output.snapshotId))
        #expect(snapshot.isAutomatic && snapshot.name == nil)
        #expect(snapshot.previewMarkdown == assembledBefore, "the snapshot holds the whole document with the section still in it")
        #expect(snapshot.contentHash == SnapshotService.computeHash(assembledBefore))
        let snapshotSections = try rig.db.fetchSnapshotSections(snapshotId: output.snapshotId)
        #expect(snapshotSections.map(\.title) == derivedBefore.map(\.title), "the section list comes from the block rows")
        #expect(snapshotSections.contains { $0.title == chapter.textContent }, "including the section that was just deleted")
        // The content row was written from the same rows.
        #expect(try rig.db.fetchContent(for: rig.pid)?.markdown == assembledBefore)
        // No epoch bump (a system write).
        #expect(try rig.db.currentBlockWriteEpoch(projectId: rig.pid) == epochBefore)
        // The slot holds the snapshot, the delete's leaders, and the snapshot is pinned.
        let slot = try #require(rig.slots.slot(opId))
        #expect(slot.state == .applied && slot.snapshotId == output.snapshotId)
        #expect(slot.removedSections.first?.id == chapter.id)
        #expect(slot.removedSections.allSatisfy { subtreeSet.contains($0.id) && ($0.blockType == .heading || $0.isPseudoSection) })
        #expect(SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(output.snapshotId))
    }

    @Test("testFailedJobRollsBackSnapshotAndRows: a root the database cannot delete leaves no snapshot, no content change, no slot record")
    func testFailedJobRollsBackSnapshotAndRows() async throws {
        let rig = try makeRig(markdown: "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n")
        let before = try rig.db.fetchBlocks(projectId: rig.pid)
        let snapshotCountBefore = try rig.db.countSnapshots(projectId: rig.pid)
        let contentBefore = try rig.db.fetchContent(for: rig.pid)?.markdown

        let opId = UUID()
        rig.slots.open(opId)
        defer { rig.slots.removeAll() }
        let outcome = await apply(makeJob(rig, opId: opId, root: "no-such-block"), on: rig)

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(try rig.db.fetchBlocks(projectId: rig.pid) == before, "nothing was deleted")
        #expect(try rig.db.countSnapshots(projectId: rig.pid) == snapshotCountBefore, "the snapshot was part of the rolled-back transaction")
        #expect(try rig.db.fetchContent(for: rig.pid)?.markdown == contentBefore)
        #expect(rig.slots.slot(opId)?.snapshotId == nil, "nothing was recorded on the slot")
    }

    // MARK: - U3

    @Test("testBatchReservedBeforeJobIsInSnapshot: an editor batch reserved before the job is applied first, so it is in the snapshot")
    func testBatchReservedBeforeJobIsInSnapshot() async throws {
        let stack = try makeStack(content: "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n")
        let writer = try #require(stack.sync.writer)
        let blocks = try stack.db.fetchBlocks(projectId: stack.pid)
        let alpha = try #require(blocks.first { $0.blockType == .heading && $0.textContent == "Alpha" })
        let typedInto = try #require(blocks.first { $0.textContent.contains("one two three") })

        // The editor's batch takes its place in the queue first ...
        let (ticket, stamp) = try #require(stack.sync.reserveWriterTurn(database: stack.db, projectId: stack.pid))
        ticket.noteFetched()
        // ... then the job is reserved behind it.
        let opId = UUID()
        let slots = SectionDeleteSlotStore()
        slots.open(opId)
        defer { slots.removeAll() }
        let registry = EFJobRegistry()
        let job = SectionDeleteJob(
            opId: opId, rootBlockId: alpha.id, projectId: stack.pid,
            fallbackBibliographyTitle: "Bibliography", slots: slots)
        let reserved = ReservedFlag()
        let identity = SystemWriteIdentity(projectId: stack.pid, database: stack.db)
        let jobTask = Task { @MainActor in
            await job.perform(on: stack.sync, identity: identity, registry: registry, onReserved: { reserved.value = true })
        }
        for _ in 0..<300 where !reserved.value { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reserved.value, "the job reserved its place")
        #expect(registry.record(for: opId)?.isResolved == false, "behind the editor's batch, the job has not run")

        // The batch applies: typing inside the section that is being deleted.
        let batch = BlockChanges(updates: [
            BlockUpdate(id: typedInto.id, textContent: "TYPED-U3", markdownFragment: "TYPED-U3", headingLevel: nil)
        ])
        let batchOutcome = await writer.applyEditorBatch(ticket.seq, batch, stamp: stamp)
        guard case .applied = batchOutcome else {
            Issue.record("expected the editor batch to apply, got \(batchOutcome)")
            return
        }

        let result = await jobTask.value
        guard case .applied(let output) = result.outcome else {
            Issue.record("expected the job to apply, got \(result.outcome)")
            return
        }
        let snapshot = try #require(try stack.db.fetchSnapshot(id: output.snapshotId))
        #expect(snapshot.previewMarkdown.contains("TYPED-U3"), "the snapshot holds the batch's text")
        #expect(output.deletedBlockIds.contains(typedInto.id), "and the row the batch updated was deleted after it")
        #expect(try stack.db.fetchBlocks(projectId: stack.pid).contains { $0.id == typedInto.id } == false)
        let recorded = await registry.awaitOutcome(opId)
        #expect(recorded == .applied, "the job's future resolved with the system write's outcome")
    }

    // MARK: - U4

    @Test("testTempIdsResolvedThroughAdmissionMap: a root named by a temp id resolves through the writer's admission-time map")
    func testTempIdsResolvedThroughAdmissionMap() async throws {
        let rig = try makeRig(markdown: "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n")
        let blocks = try rig.db.fetchBlocks(projectId: rig.pid).sorted { $0.sortOrder < $1.sortOrder }
        let last = try #require(blocks.last)

        // An editor batch inserts a new heading and a paragraph under it (temp ids), and applies: the writer records the
        // temp -> permanent mapping.
        let ticket = rig.writer.reserve()
        ticket.noteFetched()
        let stamp = BlockWriteStamp(epoch: try rig.db.currentBlockWriteEpoch(projectId: rig.pid), sequence: Int64(ticket.seq))
        let insert = BlockChanges(inserts: [
            BlockInsert(tempId: "temp-u4-heading", blockType: "heading", textContent: "Typed chapter",
                        markdownFragment: "# Typed chapter", headingLevel: 1, afterBlockId: last.id),
            BlockInsert(tempId: "temp-u4-para", blockType: "paragraph", textContent: "typed body",
                        markdownFragment: "typed body", headingLevel: nil, afterBlockId: "temp-u4-heading")
        ])
        let batchOutcome = await rig.writer.applyEditorBatch(ticket.seq, insert, stamp: stamp)
        guard case .applied(let applied) = batchOutcome else {
            Issue.record("expected the insert batch to apply, got \(batchOutcome)")
            return
        }
        let headingId = try #require(applied.idMapping["temp-u4-heading"])
        let paragraphId = try #require(applied.idMapping["temp-u4-para"])

        // The editor still names the section by its temp id when the delete is clicked.
        let opId = UUID()
        rig.slots.open(opId)
        defer { rig.slots.removeAll() }
        let outcome = await apply(makeJob(rig, opId: opId, root: "temp-u4-heading"), on: rig)

        guard case .applied(let output) = outcome else {
            Issue.record("expected .applied through the admission map, got \(outcome)")
            return
        }
        #expect(output.deletedBlockIds == [headingId, paragraphId], "deleted under their permanent ids, in document order")
        let remaining = try rig.db.fetchBlocks(projectId: rig.pid).map(\.id)
        #expect(!remaining.contains(headingId) && !remaining.contains(paragraphId))
        #expect(Set(remaining) == Set(blocks.map(\.id)), "every original row is still there")
    }

    @Test("the one-argument system-write overload is unchanged: a body that ignores the id map still runs and applies")
    func existingOverloadStillWorks() async throws {
        let rig = try makeRig(markdown: "# Alpha\n\none two three.\n")
        let ticket = rig.writer.reserveSystem()
        let outcome = await rig.writer.applySystemWrite(ticket.seq, kind: .headingLevels, identity: rig.identity) { _ in
            SystemWriteBody(value: 7)
        }
        guard case .applied(let value) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(value == 7)
    }

    // MARK: - U19

    @Test("testSnapshotWrittenWhenSlotGone: the Version History copy is written in every case; only the pin and the record are skipped")
    func testSnapshotWrittenWhenSlotGone() async throws {
        let rig = try makeRig(markdown: "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n")
        let alpha = try #require(try rig.db.fetchBlocks(projectId: rig.pid).first { $0.blockType == .heading && $0.textContent == "Alpha" })

        let opId = UUID()
        rig.slots.open(opId)
        rig.slots.remove(opId)   // the timeline was invalidated (mode switch, zoom, eviction) before the job ran
        let outcome = await apply(makeJob(rig, opId: opId, root: alpha.id), on: rig)

        guard case .applied(let output) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(try rig.db.fetchSnapshot(id: output.snapshotId) != nil, "the snapshot exists")
        #expect(!SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(output.snapshotId), "it is not pinned")
        #expect(rig.slots.count == 0 && rig.slots.slot(opId) == nil, "the slot store is empty")
        #expect(try rig.db.fetchBlocks(projectId: rig.pid).contains { $0.id == alpha.id } == false, "the section is deleted")
    }

    // MARK: - U6 (the outcome-resolution half)

    @Test("testEveryOutcomeResolvesTheFuture: each system-write outcome resolves the job's future exactly once")
    func testEveryOutcomeResolvesTheFuture() async throws {
        struct Boom: Error {}
        let cases: [OutcomeCase] = [
            OutcomeCase(name: "applied", outcome: .applied(1), expected: .applied),
            OutcomeCase(name: "failed", outcome: .failed(Boom()), expected: .failed(String(describing: Boom()))),
            OutcomeCase(name: "systemStalled", outcome: .refused(.skipped(.systemStalled)), expected: .refused(.skipped(.systemStalled))),
            OutcomeCase(name: "writerRetired", outcome: .refused(.writerRetired), expected: .refused(.writerRetired)),
            OutcomeCase(name: "identityMismatch", outcome: .refused(.identityMismatch), expected: .refused(.identityMismatch)),
            OutcomeCase(name: "nested", outcome: .refused(.nested), expected: .refused(.nested)),
            OutcomeCase(name: "outOfTurn", outcome: .refused(.outOfTurn), expected: .refused(.outOfTurn)),
            OutcomeCase(name: "notWanted", outcome: .refused(.notWanted), expected: .refused(.notWanted)),
            OutcomeCase(name: "noWriter", outcome: .refused(.noWriter), expected: .refused(.noWriter))
        ]
        let registry = EFJobRegistry()
        for item in cases {
            let opId = UUID()
            let record = registry.register(opId)
            #expect(record.isResolved == false, "\(item.name): outstanding until the outcome arrives")

            let waiter = Task { await registry.awaitOutcome(opId) }
            #expect(registry.settle(opId, with: item.outcome), "\(item.name): the first settle resolves it")
            let resumedWith = await waiter.value
            #expect(resumedWith == item.expected, "\(item.name): a waiter that was already waiting is resumed with it")

            #expect(registry.settle(opId, with: SystemWriteOutcome<Int>.applied(2)) == false, "\(item.name): a second outcome changes nothing")
            #expect(registry.resolve(opId, .abandoned) == false, "\(item.name): and neither does the barrier afterwards")
            let again = await registry.awaitOutcome(opId)
            #expect(again == item.expected, "\(item.name): a later waiter sees the first outcome")
        }
        #expect(registry.outstandingCount == 0)
    }

    @Test("abandonAll resolves every outstanding future .abandoned and leaves finished ones alone")
    func abandonAllResolvesOutstanding() async throws {
        let registry = EFJobRegistry()
        let done = UUID(), pendingOne = UUID(), pendingTwo = UUID()
        registry.register(done)
        registry.register(pendingOne)
        registry.register(pendingTwo)
        registry.settle(done, with: SystemWriteOutcome<Int>.applied(1))
        let waiter = Task { await registry.awaitOutcome(pendingOne) }

        #expect(registry.outstandingCount == 2)
        let resolved = registry.abandonAll()

        #expect(resolved == 2)
        let waiterOutcome = await waiter.value
        #expect(waiterOutcome == .abandoned)
        let secondPending = await registry.awaitOutcome(pendingTwo)
        let finished = await registry.awaitOutcome(done)
        #expect(secondPending == .abandoned)
        #expect(finished == .applied, "a job that already finished keeps its outcome")
        #expect(registry.abandonAll() == 0, "nothing is left to abandon")
        await registry.awaitAllOutstanding()   // returns at once: nothing is outstanding
    }

    @Test("a registry that goes away resolves its outstanding futures .abandoned")
    func deinitResolvesOutstanding() async throws {
        var registry: EFJobRegistry? = EFJobRegistry()
        let record = try #require(registry?.register(UUID()))
        let waiter = Task { await record.future.wait() }

        registry = nil   // the owner goes away

        let waiterOutcome = await waiter.value
        #expect(waiterOutcome == .abandoned)
        #expect(record.outcome == .abandoned)
    }

    @Test("a job the writer refuses (identity mismatch) still resolves its future, with the refusal")
    func refusedJobResolvesItsFuture() async throws {
        let stack = try makeStack()
        let other = try TestFixtureFactory.createTemporary(content: "# Elsewhere\n")
        let otherPid = try TestFixtureFactory.getProjectId(from: other)
        let opId = UUID()
        let slots = SectionDeleteSlotStore()
        let registry = EFJobRegistry()
        let job = SectionDeleteJob(
            opId: opId, rootBlockId: "x", projectId: stack.pid, fallbackBibliographyTitle: "Bibliography", slots: slots)

        let result = await job.perform(
            on: stack.sync, identity: SystemWriteIdentity(projectId: otherPid, database: other), registry: registry)

        guard case .refused(.identityMismatch) = result.outcome else {
            Issue.record("expected .refused(.identityMismatch), got \(result.outcome)")
            return
        }
        let recorded = await registry.awaitOutcome(opId)
        #expect(recorded == .refused(.identityMismatch))
    }

    private struct OutcomeCase {
        let name: String
        let outcome: SystemWriteOutcome<Int>
        let expected: JobOutcome
    }

    /// A flag the job's `onReserved` hook sets (the hook is an escaping closure, so it captures a box, not a local).
    private final class ReservedFlag: @unchecked Sendable {
        var value = false
    }
}

// The tests below are an extension of the same suite, in this file, only to keep the struct body under SwiftLint's
// `type_body_length` limit; they are members of `SectionDeleteJobTests` and run as part of it.
extension SectionDeleteJobTests {

    // MARK: - A7: DiscardReason.bridgeFailed

    @Test("a ticket settled as discarded(.bridgeFailed) is counted as a discard and the queue moves on")
    func bridgeFailedSettlesTheTicketAsDiscarded() throws {
        let rig = try makeRig(markdown: "# Alpha\n\none two three.\n")
        let ticket = rig.writer.reserve()
        ticket.noteFetched()

        ticket.settleIfOpen(.discarded(.bridgeFailed))

        #expect(rig.writer.ledger.discardedAfterFetch == 1)
        #expect(rig.writer.testFrontier == ticket.seq + 1, "the sequence is settled; the next one is the frontier")
    }

    // MARK: - Fix round 2a, item 10: the editor's removed ids against the rows the job deleted

    @Test("Item 10: editor-reported ids that differ from the rows the job deleted are reported in the output and change nothing else")
    func testEditorRemovedIdsMismatchIsReportedAndChangesNothing() async throws {
        let rig = try makeRig(markdown: "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n")
        let before = try rig.db.fetchBlocks(projectId: rig.pid)
        let alpha = try #require(before.first { $0.textContent == "Alpha" })
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: alpha.id, projectId: rig.pid))
        let lastRow = try #require(subtree.last)
        let opId = UUID()
        rig.slots.open(opId)
        defer { rig.slots.removeAll() }
        var job = makeJob(rig, opId: opId, root: alpha.id)
        // The editor says it removed all but the last row, plus one the database does not have.
        job.editorRemovedIds = Array(subtree.dropLast()) + ["ghost-id"]

        let outcome = await apply(job, on: rig)

        guard case .applied(let output) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(output.removedIdsMismatch == SectionDeleteJob.RemovedIdsMismatch(editorOnly: ["ghost-id"], jobOnly: [lastRow]))
        let after = Set(try rig.db.fetchBlocks(projectId: rig.pid).map(\.id))
        #expect(after.isDisjoint(with: Set(subtree)), "no behaviour change: the job deleted the whole section by its own rule")
    }

    @Test("Item 10: editor ids that agree with the job, and an absent list, report no mismatch")
    func testEditorRemovedIdsThatAgreeReportNoMismatch() async throws {
        let rig = try makeRig(markdown: "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n")
        let before = try rig.db.fetchBlocks(projectId: rig.pid)
        let alpha = try #require(before.first { $0.textContent == "Alpha" })
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: alpha.id, projectId: rig.pid))
        let opId = UUID()
        rig.slots.open(opId)
        defer { rig.slots.removeAll() }
        var job = makeJob(rig, opId: opId, root: alpha.id)
        job.editorRemovedIds = subtree

        let outcome = await apply(job, on: rig)

        guard case .applied(let output) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(output.removedIdsMismatch == nil)

        // No list at all: no comparison.
        let rigTwo = try makeRig(markdown: "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n")
        let alphaTwo = try #require(try rigTwo.db.fetchBlocks(projectId: rigTwo.pid).first { $0.textContent == "Alpha" })
        let opIdTwo = UUID()
        rigTwo.slots.open(opIdTwo)
        defer { rigTwo.slots.removeAll() }
        let outcomeTwo = await apply(makeJob(rigTwo, opId: opIdTwo, root: alphaTwo.id), on: rigTwo)
        guard case .applied(let outputTwo) = outcomeTwo else {
            Issue.record("expected .applied, got \(outcomeTwo)")
            return
        }
        #expect(outputTwo.removedIdsMismatch == nil, "the editor sent no ids: nothing to compare")
    }
}
