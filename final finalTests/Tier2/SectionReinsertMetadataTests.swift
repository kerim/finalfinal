//
//  SectionReinsertMetadataTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b structural, round 1c; plan-v3 D9, review rows N4 and S6): the quick undo of an editor-first Delete
//  Section keeps the sidebar-only fields (status, tags, word goal, goal type, image width) that were changed on a surviving row after
//  the delete. They live on the block row and in no undo entry, so the reinsert, which makes the table equal to the rows from before
//  the delete, used to put the old values back. The job-level rules (the five fields, `expectedRemovals`, the log wording) are pinned
//  in SectionReinsertJobTests.swift; this file drives the real press, with `EditorFirstRig` (EditorFirstDeleteTests.swift).
//
//  U-S1-4d is the delete twin of the duplicate test U-S1-4 (round 1e-i): the same rule, proven here on the path that exists today.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Quick undo keeps sidebar-only edits (Phase 4b round 1c, Tier 2)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SectionReinsertMetadataTests: QuickUndoFixtures {

    /// A plain (non-async) function on purpose: inside an `async` test `dbWriter.write` resolves to GRDB's async overload.
    private func saveFromSidebar(_ rig: EditorFirstRig, _ edit: (inout Block) -> Void, ofSection title: String) throws {
        var heading = try rig.heading(title)
        edit(&heading)
        heading.updatedAt = Date()   // the sidebar's save stamps the row, as `ContentView.updateSection` does
        try rig.db.dbWriter.write { database in try heading.update(database) }
    }

    // U-S1-4d: delete A, set B's status in the sidebar, Cmd-Z: A is back and B still has the status
    @Test("U-S1-4d: the quick undo of a delete keeps a status set after the delete")
    func testQuickUndoOfDeleteKeepsAStatusSetAfterTheOp() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let deleted = try await delete(rig, "Section A")
        #expect(try rig.heading("Section B").status != .final_, "precondition: B does not have the status yet")
        try saveFromSidebar(rig, { $0.status = .final_ }, ofSection: "Section B")

        #expect(await rig.pressAndSettle(deleted.entry))

        #expect(rig.quickUndoScripts.count == 1, "expected the quick undo (the slow one re-parses the snapshot and is not what this pins)")
        #expect(try rig.presentRowCount(deleted.subtree) == deleted.subtree.count, "Section A is back, every row of it")
        #expect(try rig.heading("Section B").status == .final_, "the quick undo reverted a status set after the delete")
    }

    // The same press with every sidebar-only field of the heading set after the delete: all of them survive, the section's text and
    // position come from the rows before the delete.
    @Test("U-S1-4d (all fields): tags, word goal and goal type set after the delete survive the quick undo too")
    func testQuickUndoOfDeleteKeepsEverySidebarFieldSetAfterTheOp() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let deleted = try await delete(rig, "Section A")
        try saveFromSidebar(
            rig, { $0.status = .review; $0.tags = ["keep", "me"]; $0.wordGoal = 750; $0.goalType = .max }, ofSection: "Section C")

        #expect(await rig.pressAndSettle(deleted.entry))

        #expect(rig.quickUndoScripts.count == 1)
        let sectionC = try rig.heading("Section C")
        #expect(sectionC.status == .review, "status: \(String(describing: sectionC.status))")
        #expect(sectionC.tags == ["keep", "me"], "tags: \(String(describing: sectionC.tags))")
        #expect(sectionC.wordGoal == 750, "word goal: \(String(describing: sectionC.wordGoal))")
        #expect(sectionC.goalType == .max, "goal type: \(sectionC.goalType)")
        let order = try rig.blocks().filter { $0.blockType == .heading }.sorted { $0.sortOrder < $1.sortOrder }.map(\.textContent)
        #expect(order == ["Chapter", "Section A", "Section B", "Section C"], "the section is back in its place: \(order)")
    }
}

// MARK: - The job on its own

/// `SectionReinsertJob` run directly, the way SectionReinsertJobTests.swift drives it (a `DocumentWriter` on a temporary project, no
/// WebView): the five sidebar-only fields of a row that is in both the payload and the table, and a long run of expected removals.
/// Neither test reads the process-global `DebugLog.alwaysSink` (the one that does is in SectionReinsertJobTests.swift, which keeps it
/// away from the other test that installs it).
@Suite("SectionReinsertJob sidebar-only fields (Phase 4b round 1c, Tier 2)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SectionReinsertSidebarFieldsTests {

    private struct Rig {
        let db: ProjectDatabase
        let pid: String
        let writer: DocumentWriter
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

    private func makeRig() throws -> Rig {
        let db = try TestFixtureFactory.createTemporary(content: Self.threeSections)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let opId = UUID()
        return Rig(
            db: db, pid: pid, writer: DocumentWriter(database: db, projectId: pid),
            holder: SectionDeletePayloadHolder(opId: opId, rootId: "unset", projectId: pid), opId: opId)
    }

    // Plain (non-async) database helpers: inside an `async` test `dbWriter.write` resolves to GRDB's async overload.
    private func rows(_ rig: Rig) throws -> [Block] {
        try rig.db.fetchBlocks(projectId: rig.pid).sorted { $0.sortOrder < $1.sortOrder }
    }

    private func updateRow(_ rig: Rig, _ block: Block) throws {
        try rig.db.dbWriter.write { database in try block.update(database) }
    }

    private func insertRow(_ rig: Rig, _ block: Block) throws {
        var copy = block
        try rig.db.dbWriter.write { database in try copy.insert(database) }
    }

    private func deleteRows(_ rig: Rig, _ ids: [String]) throws {
        try rig.db.dbWriter.write { database in _ = try Block.filter(keys: ids).deleteAll(database) }
    }

    private func row(_ rig: Rig, id: String) throws -> Block {
        try #require(try rows(rig).first { $0.id == id })
    }

    private func heading(_ rig: Rig, _ title: String) throws -> Block {
        try #require(try rows(rig).first { $0.blockType == .heading && $0.textContent == title })
    }

    /// The rows as the operation's job would have recorded them before it ran.
    private func recordPayload(_ rig: Rig, root: Block) throws -> [Block] {
        let payload = try rows(rig)
        rig.holder.fill(rows: payload, leaders: [], resolvedRootId: root.id)
        return payload
    }

    private func run(
        _ rig: Rig, expectedRemovals: Set<String> = []
    ) async -> SystemWriteOutcome<SectionReinsertJob.Output> {
        var job = SectionReinsertJob(opId: rig.opId, projectId: rig.pid, holder: rig.holder, slots: SectionDeleteSlotStore())
        job.expectedRemovals = expectedRemovals
        let configured = job
        let ticket = rig.writer.reserveSystem()
        return await rig.writer.applySystemWrite(ticket.seq, kind: .sectionReinsert, identity: rig.identity) { database in
            try configured.run(db: database)
        }
    }

    private func applied(_ outcome: SystemWriteOutcome<SectionReinsertJob.Output>) throws -> SectionReinsertJob.Output {
        guard case .applied(let output) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            throw CancellationError()
        }
        return output
    }

    @Test("testCarriesForwardTheSidebarOnlyFieldsOfRowsPresentInBoth: status, tags, word goal, goal type and image width stay as they are now")
    func testCarriesForwardTheSidebarOnlyFieldsOfRowsPresentInBoth() async throws {
        let rig = try makeRig()
        var first = try heading(rig, "First Chapter")
        var second = try heading(rig, "Second Section")
        var third = try heading(rig, "Third Section")
        first.status = .writing
        second.status = .writing; second.tags = ["draft"]; second.wordGoal = 500; second.goalType = .min
        third.status = .review; third.wordGoal = 300
        for edited in [first, second, third] { try updateRow(rig, edited) }
        // The image sits between the first chapter's body and the second section, so it belongs to neither the section that is removed
        // (the third) nor the one the sidebar edits (the second).
        let firstBody = try #require(try rows(rig).first { $0.textContent == "The first chapter's body." })
        let image = Block(
            projectId: rig.pid, sortOrder: (firstBody.sortOrder + second.sortOrder) / 2, blockType: .image,
            markdownFragment: "![diagram](media/diagram.png)", imageSrc: "media/diagram.png", imageWidth: 40)
        try insertRow(rig, image)
        let payload = try recordPayload(rig, root: second)
        let firstInPayload = try #require(payload.first { $0.id == first.id })

        // After the operation: the sidebar changes the second section and the image width; the first section's text was rewritten by a
        // derived rebuild AND its status changed; the third section is gone (the operation removed it, so it has to come back).
        let later = Date().addingTimeInterval(60)
        second.status = .final_; second.tags = ["done", "keep"]; second.wordGoal = 900; second.goalType = .max; second.updatedAt = later
        var imageNow = try row(rig, id: image.id)
        imageNow.imageWidth = 80; imageNow.updatedAt = later
        first.textContent = "First Chapter, rewritten"; first.markdownFragment = "# First Chapter, rewritten"; first.status = .final_
        for edited in [second, imageNow, first] { try updateRow(rig, edited) }
        third = try heading(rig, "Third Section")
        let thirdRows = try #require(try rig.db.sectionBlockIds(rootId: third.id, projectId: rig.pid))
        try deleteRows(rig, thirdRows)

        let output = try applied(await run(rig))

        let secondBack = try row(rig, id: second.id)
        #expect(secondBack.status == .final_, "status: \(String(describing: secondBack.status))")
        #expect(secondBack.tags == ["done", "keep"], "tags: \(String(describing: secondBack.tags))")
        #expect(
            secondBack.wordGoal == 900 && secondBack.goalType == .max,
            "word goal \(String(describing: secondBack.wordGoal)), goal type \(secondBack.goalType)")
        let imageBack = try row(rig, id: image.id)
        #expect(imageBack.imageWidth == 80, "image width: \(String(describing: imageBack.imageWidth))")
        let firstBack = try row(rig, id: first.id)
        #expect(
            firstBack.textContent == firstInPayload.textContent && firstBack.markdownFragment == firstInPayload.markdownFragment,
            "a row that differs in text is still put back to the payload's text: \(firstBack.textContent)")
        #expect(firstBack.status == .final_, "and keeps the status it has now: \(String(describing: firstBack.status))")
        let thirdBack = try row(rig, id: third.id)
        #expect(thirdBack.status == .review && thirdBack.wordGoal == 300, "a row the operation removed returns with the payload's fields")
        #expect(Set(output.insertedIds) == Set(thirdRows), "exactly the removed section was inserted: \(output.insertedIds)")
        #expect(
            output.updatedIds == [first.id],
            "only the row that differs in more than the sidebar-only fields is written; got \(output.updatedIds)")
    }

    @Test("testManyExpectedRemovalsAreCountedNotTreatedAsLostRows: a copy of a long section (far above the 50-line log cap)")
    func testManyExpectedRemovalsAreCountedNotTreatedAsLostRows() async throws {
        let rig = try makeRig()
        let second = try heading(rig, "Second Section")
        let payload = try recordPayload(rig, root: second)
        let last = try #require(payload.last)
        let copies = (1...120).map { index in
            Block(
                projectId: rig.pid, sortOrder: last.sortOrder + Double(index), blockType: .paragraph,
                textContent: "COPYMANY-\(index)", markdownFragment: "COPYMANY-\(index)")
        }
        for copy in copies { try insertRow(rig, copy) }

        let output = try applied(await run(rig, expectedRemovals: Set(copies.map(\.id))))

        #expect(Set(try rows(rig).map(\.id)) == Set(payload.map(\.id)), "the copies are gone")
        #expect(output.deletedExpectedRows == 120, "counted as expected removals: \(output.deletedExpectedRows)")
        // A user row that is neither expected nor a re-identified repeat is what the log lists, and what its 50-line cap and its
        // 'N more' line count: with every copy expected there is none.
        #expect(
            output.deletedUserRows == 0 && output.deletedReidentifiedRows == 0,
            "none of them is a 'row not in the document before': user rows \(output.deletedUserRows)")
    }
}
