//
//  EditorFirstDuplicateTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 3, round 1e-i; plan-v3 tests U-S1-1, U-S1-2a, U-S1-2b, U-S1-3, U-S1-4, U-S1-7): the controller's
//  editor-first Duplicate Section, driven with a REAL `BlockSyncService` and `DocumentWriter` and a scripted editor
//  (`EditorFirstRig`, answers in EditorFirstRig+StructuralQueue.swift). The editor's side (the insertion and its reply) is scripted;
//  what these tests pin is what Swift does with it: that a duplicate leaves a delete's undo on the quick path, that the quick redo
//  of a duplicate writes the same ids again, that the click's batch is applied and nothing is pushed back over the editor, that a
//  status set after the operation survives the quick undo, and that a job that fails puts the document back without losing typing.
//
//  U-S1-5, U-S1-6, U-S1-8 and U-S1-9 (the stale-rebuild and refusal cases) are round 1e-ii.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// Sets a block's section status directly in the database (what the sidebar's status badge does). A plain (non-async) function on
/// purpose: inside an `async` test `dbWriter.write` resolves to GRDB's async overload.
@MainActor
private func setStatus(_ rig: EditorFirstRig, ofBlock id: String, to status: SectionStatus) throws {
    try rig.db.dbWriter.write { database in
        guard var block = try Block.fetchOne(database, key: id) else { return }
        block.status = status
        try block.update(database)
    }
}

@Suite("Editor-first duplicate (t-18b7fa48 slice 1)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct EditorFirstDuplicateTests: QuickUndoFixtures {

    private func duplicate(_ rig: EditorFirstRig, _ title: String) async throws {
        let outcome = await rig.controller.performSectionDuplicate(rootId: try rig.heading(title).id)
        #expect(outcome == .performed, "the duplicate of \(title) ended \(outcome)")
    }

    private func press(_ rig: EditorFirstRig, _ direction: StructuralUndoController.UndoDirection) async throws {
        let entry = try #require(direction == .undo ? rig.unifiedUndo.undoStack.last : rig.unifiedUndo.redoStack.last)
        #expect(await rig.pressAndSettle(entry, direction), "the \(direction) did not end and settle")
        _ = await rig.waitUntilSettled()
    }

    private func update(_ block: Block, to text: String) -> BlockChanges {
        BlockChanges(updates: [BlockUpdate(id: block.id, textContent: text, markdownFragment: text, headingLevel: nil)])
    }

    // U-S1-1 (R5): a delete, then a duplicate: both Cmd-Z are instant. Before this slice the duplicate wrote the table outside the
    // queue, bumped the structural counter, and made the delete's undo take the slow snapshot path.
    @Test func testDeleteUndoStaysQuickAfterDuplicate() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        _ = try await delete(rig, "Section A")
        try await duplicate(rig, "Section C")
        _ = await rig.waitUntilSettled()
        try await press(rig, .undo)
        try await press(rig, .undo)
        #expect(rig.quickUndoScripts.count == 2, "expected both undos quick, saw \(rig.quickUndoScripts.count) quick")
        #expect(rig.scripts(containing: "performStructuralSwap").isEmpty, "expected no slow swap after a duplicate")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "the delete's undo brought Section A back")
        #expect(try !rig.blocks().contains { $0.textContent == "Section C copy" }, "the duplicate's undo took the copy out")
    }

    // U-S1-2a (G-F11): duplicate C, delete A, Cmd-Z Cmd-Z Cmd-Shift-Z Cmd-Shift-Z: none of the four is refused.
    @Test func testDeleteRedoAfterDuplicateUndoIsNotRefused() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        try await duplicate(rig, "Section C")
        _ = await rig.waitUntilSettled()
        _ = try await delete(rig, "Section A")
        for direction in [StructuralUndoController.UndoDirection.undo, .undo, .redo, .redo] { try await press(rig, direction) }
        #expect(
            rig.replyWords().suffix(4) == ["undo performed", "undo performed", "redo performed", "redo performed"],
            "got \(rig.replyWords())")
        #expect(try rig.blocks().contains { $0.textContent == "Section C copy" }, "the duplicate's redo put the copy back")
        #expect(try !rig.blocks().contains { $0.textContent == "Section A" }, "the delete's redo took Section A out again")
    }

    // U-S1-2b (S9): duplicate C, delete the copy, Cmd-Z Cmd-Z Cmd-Shift-Z Cmd-Shift-Z: the duplicate's redo writes the copy with the
    // ids of its first click, so the delete's redo finds the rows it expects.
    @Test func testRedoOfDuplicateReusesTheCopyIds() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        try await duplicate(rig, "Section C")
        _ = await rig.waitUntilSettled()
        let copyRoot = try rig.heading("Section C copy")
        let copyIds = try #require(try rig.db.sectionBlockIds(rootId: copyRoot.id, projectId: rig.pid))
        _ = try await delete(rig, "Section C copy")
        try await press(rig, .undo)
        try await press(rig, .undo)
        try await press(rig, .redo)
        // Round 1g-A (review T3): right after the DUPLICATE's redo, before the delete's redo. The rows of the first click are back,
        // under the same ids. (After the delete's redo "none of them are there" holds whether or not the ids were reused: fresh ids
        // would leave the first-click rows deleted too.)
        let presentAfterRedo = try rig.presentRowCount(copyIds)
        #expect(
            presentAfterRedo == copyIds.count,
            "the duplicate's redo did not write the first click's ids again: \(presentAfterRedo) of \(copyIds.count) rows")
        try await press(rig, .redo)
        #expect(
            rig.replyWords().suffix(4) == ["undo performed", "undo performed", "redo performed", "redo performed"],
            "got \(rig.replyWords())")
        #expect(try rig.presentRowCount(copyIds) == 0, "the copy's first-click rows are deleted again")
        #expect(try !rig.blocks().contains { $0.textContent == "Section C copy" }, "a copy with other ids is still in the table")
    }

    // U-S1-3: the duplicate's own click and job push nothing whole into the editor, and the batch the click consumed (typing up to
    // the click) is applied before the job copies the section.
    @Test func testDuplicateDoesNotPushTheWholeDocumentAndKeepsTheClickBatch() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let body = try #require(try rig.blocks().first { $0.textContent == "The B body." })
        rig.duplicateClickBatch = update(body, to: "The B body typed.")
        let pushesBefore = rig.pushes.count
        try await duplicate(rig, "Section B")
        #expect(
            rig.pushes.count == pushesBefore,
            "expected no whole-document push from the duplicate itself, got \(rig.pushes.count - pushesBefore)")
        _ = await rig.waitUntilSettled()
        let texts = try rig.blocks().map(\.textContent)
        #expect(texts.filter { $0 == "The B body typed." }.count == 2, "typing in the original and the copy: \(texts)")
    }

    // U-S1-4 (#9): a status set after the duplicate is not reverted by the duplicate's quick undo.
    @Test func testQuickUndoKeepsAStatusSetAfterTheOp() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        try await duplicate(rig, "Section C")
        _ = await rig.waitUntilSettled()
        let other = try rig.heading("Section A")
        try setStatus(rig, ofBlock: other.id, to: .final_)
        try await press(rig, .undo)
        #expect(try rig.heading("Section A").status == .final_, "the quick undo reverted a status set after the duplicate")
        #expect(try !rig.blocks().contains { $0.textContent == "Section C copy" }, "and the copy is gone")
    }

    // The sidebar shows the copy at once (before the database holds its rows) and drops it when the duplicate is undone.
    @Test func testCopyAppearsInTheSidebarAtOnceAndLeavesWithTheUndo() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let hold = try rig.holdQueue()   // the duplicate's job is reserved but cannot run: the database has no copy yet
        try await duplicate(rig, "Section C")
        #expect(try !rig.blocks().contains { $0.textContent == "Section C copy" }, "the job ran although the queue was held")
        #expect(rig.editorState.sections.contains { $0.title == "Section C copy" }, "the copy is not in the sidebar yet")
        rig.release(hold)
        _ = await rig.waitUntilSettled()
        #expect(try rig.blocks().contains { $0.textContent == "Section C copy" }, "the job did not apply")
        #expect(rig.editorState.sections.contains { $0.title == "Section C copy" }, "the copy left the sidebar when its rows arrived")
        #expect(rig.editorState.pendingRestoreSections.isEmpty, "the overlay that showed the copy was not lifted")

        try await press(rig, .undo)
        #expect(!rig.editorState.sections.contains { $0.title == "Section C copy" }, "the undone copy is still in the sidebar")
        #expect(rig.editorState.pendingRemovalIds.isEmpty, "the filter that hid the copy was not lifted: \(rig.editorState.pendingRemovalIds)")
    }

    private static let failedDuplicateMessage =
        "The duplicate couldn't be saved, so the section is back as it was. Anything you typed into the copy was removed with it."

    /// Waits for the job and the put-back to end, then polls until the rig's typing queue is empty (a poll carries one batch per
    /// cycle; the put-back's own push may queue keystrokes made while it was in flight).
    private func settleThenCarryTyping(_ rig: EditorFirstRig) async {
        _ = await rig.waitUntilSettled()
        var cycles = 0
        repeat {
            #expect(await rig.awaitRuns([rig.startReport()]), "a poll did not end")
            cycles += 1
        } while !rig.typingQueue.isEmpty && cycles < 6
        _ = await rig.waitUntilSettled()
    }

    // U-S1-7 (C4), rebuilt in round 1g-A (review T1): a duplicate whose job fails puts the document back, tells the user once, and keeps
    // the typing. The job fails with a database fault in its own insert, so the section's root row is untouched and "the section is
    // back as it was" is what the test sets up. What the EDITOR holds after the put-back is checked, not only the database:
    //   - the typing up to the click (the click's batch) was applied before the job, so the put-back's push carries it;
    //   - keystrokes made while the put-back's push is in flight stay on the screen only because that push asks for
    //     `detectPausedEdits` (the rig's editor keeps them as pending changes when the option is there and drops them when it is not),
    //     and a poll afterwards carries them to the database;
    //   - typing made after the click and carried by a poll reaches the database (as before);
    //   - the copy is gone from the editor, the table and the sidebar.
    @Test func testFailedDuplicatePutBackKeepsTyping() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.modelsWholePushOnEditor = true
        let a = try #require(try rig.blocks().first { $0.textContent == "The A body." })
        let b = try #require(try rig.blocks().first { $0.textContent == "The B body." })
        rig.duplicateClickBatch = update(a, to: "The A body typed.")
        rig.typedDuringNextWholePush = (b, " LATER")
        rig.forceNextJobFailure = true
        try await duplicate(rig, "Section C")
        let cBody = try #require(try rig.blocks().first { $0.textContent == "The C body." })
        rig.typingQueue.append(update(cBody, to: "The C body later."))
        await settleThenCarryTyping(rig)

        let screen = try #require(rig.editorText, "the editor holds no document")
        #expect(screen.contains("The A body typed."), "the put-back removed the typing up to the click from the editor: \(screen)")
        #expect(
            screen.contains("The B body. LATER"),
            "the put-back removed the typing made while its push was in flight from the editor (detectPausedEdits): \(screen)")
        #expect(!screen.contains("Section C copy"), "the copy is still in the editor: \(screen)")
        let wholePushes = rig.pushes.filter { !$0.preserveUserBlocks }
        #expect(
            wholePushes.contains { $0.markdown.contains("The A body typed.") && !$0.markdown.contains("Section C copy") },
            "no whole-document put-back push with the click's typing in it and without the copy, got \(wholePushes.count) push(es)")
        #expect(wholePushes.contains { $0.detectPausedEdits }, "the put-back's push did not ask for detectPausedEdits")

        let texts = try rig.blocks().map(\.textContent)
        #expect(texts.contains("The A body typed."), "put-back lost the typing up to the click: \(texts)")
        #expect(texts.contains("The B body. LATER"), "put-back lost the typing made during its push: \(texts)")
        #expect(texts.contains("The C body later."), "put-back lost the typing made after the click: \(texts)")
        #expect(texts.contains("Section C"), "the section the duplicate was made from is gone: \(texts)")
        #expect(!texts.contains("Section C copy"), "the copy is in the table although its job failed: \(texts)")
        await rig.editorState.refreshSectionsAwaiting()
        #expect(!rig.editorState.sections.contains { $0.title == "Section C copy" }, "the copy is still in the sidebar")
        #expect(rig.editorState.pendingRestoreSections.isEmpty, "the overlay that showed the copy was not lifted")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "the put-back removes the entry")
        #expect(rig.alerts.map(\.title) == ["Couldn't Duplicate Section"], "expected exactly one alert, got \(rig.alerts)")
        #expect(rig.alerts.first?.message == Self.failedDuplicateMessage, "got \(String(describing: rig.alerts.first?.message))")
    }

    // Round 1g-A (review T1): what a failed duplicate does to typing INSIDE the copy. The copy's rows never reached the database, so the
    // put-back removes the copy and whatever was typed into it, and the alert says so in plain words (floor item 5). Text the database
    // never had cannot be in the table either.
    @Test func testTypingIntoTheCopyIsRemovedWithItWhenTheDuplicateFails() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.modelsWholePushOnEditor = true
        let jobMayRun = DispatchSemaphore(value: 0)
        defer { jobMayRun.signal() }
        rig.controller.testEFJobBodyHold = { jobMayRun.wait() }   // the copy is on the screen and its job has not run: the user types into it
        rig.forceNextJobFailure = true
        try await duplicate(rig, "Section C")
        let click = try #require(rig.duplicateClicks.values.first)
        let copyBodyId = try #require(click.copyIds.last, "the copy has no paragraph")
        let typed = "The C body typed in the copy."
        let screenBefore = try #require(rig.editorText)
        #expect(screenBefore.contains("Section C copy"), "precondition: the copy is on the screen")
        let copyBody = try #require(screenBefore.range(of: "The C body.", options: .backwards), "no paragraph in the copy")
        rig.editorText = screenBefore.replacingCharacters(in: copyBody, with: typed)
        rig.typingQueue.append(BlockChanges(updates: [BlockUpdate(id: copyBodyId, textContent: typed, markdownFragment: typed, headingLevel: nil)]))
        let poll = rig.startReport()
        #expect(await gateWaitUntil({ rig.typingQueue.isEmpty }), "the poll did not fetch the typing")
        jobMayRun.signal()
        #expect(await rig.awaitRuns([poll]))
        _ = await rig.waitUntilSettled()

        let screen = try #require(rig.editorText)
        #expect(!screen.contains(typed), "the typing in the copy is still in the editor after the put-back: \(screen)")
        #expect(!screen.contains("Section C copy"), "the copy is still in the editor: \(screen)")
        let texts = try rig.blocks().map(\.textContent)
        #expect(!texts.contains { $0.contains(typed) }, "typing into the copy reached the table, which has no such row: \(texts)")
        #expect(!texts.contains("Section C copy"), "the copy is in the table although its job failed: \(texts)")
        #expect(texts.contains("Section C") && texts.contains("The C body."), "the original section is not intact: \(texts)")
        #expect(rig.alerts.map(\.title) == ["Couldn't Duplicate Section"], "expected exactly one alert, got \(rig.alerts)")
        #expect(
            rig.alerts.first?.message.contains("Anything you typed into the copy was removed with it.") == true,
            "the alert does not say that typing into the copy was removed: \(String(describing: rig.alerts.first?.message))")
    }

    // U16 (t-4a8fd8af slice 3, the Markdown Duplicate): the Markdown page gives only the section's LEADERS new ids, so its job gets ONE
    // pair per leader and every other row of the subtree takes a fresh id. The job then reports "N node(s) got a fresh id", which is the
    // normal case and not a disagreement: with `copiesAreLeadersOnly` the settle must NOT push the database's block ids to the editor.
    // The same pairs without the flag ARE reported (the Rich Text rule), which is the control inside this test: it shows the push path is
    // live in this rig, so "no push" for the flagged job is the flag's doing.
    @Test func testLeaderOnlyCopiesAreNotReportedAsDisagreeing() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)

        func startJob(on title: String, leadersOnly: Bool) async throws -> Block {
            let root = try rig.heading(title)
            let opId = UUID()
            rig.controller.efOpEpoch[opId] = 1
            rig.editorState.pendingEditorFirstJobs += 1   // the job's task brings it down again (`ownsPendingJobCount`)
            let copies = [DuplicatedBlock(sourceId: root.id, newId: UUID().uuidString)]   // the heading only: its paragraph has no pair
            let reserved = await rig.controller.startEditorFirstDuplicateJob(
                opId: opId, rootId: root.id, copies: copies, database: rig.db, projectId: rig.pid, ownsPendingJobCount: true,
                copiesAreLeadersOnly: leadersOnly)
            #expect(reserved, "the job for \(title) did not reserve its place")
            #expect(await rig.waitUntilSettled(), "the job for \(title) did not settle")
            let copyRow = try #require(try rig.blocks().first { $0.id == copies[0].newId }, "the heading's copy does not have the pair's id")
            #expect(copyRow.textContent == "\(title) copy")
            return copyRow
        }

        _ = try await startJob(on: "Section A", leadersOnly: true)
        #expect(rig.pushBlockIdsCalls == 0, "pushesDatabaseBlockIds true: leader-only copies were reported as disagreeing")
        _ = try await startJob(on: "Section B", leadersOnly: false)
        #expect(rig.pushBlockIdsCalls == 1, "control: the same kind of pairs without the flag must be reported (\(rig.pushBlockIdsCalls))")
    }
}
