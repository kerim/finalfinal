//
//  EditorFirstReorderTests.swift
//  final finalTests
//
//  Tier 2 (t-0b70d1e9, plan tests U2 to U6, U9, U11, U12, U14 and the cases around them): the controller's editor-first drag-reorder in
//  the Outline sidebar, driven with a REAL `BlockSyncService` and `DocumentWriter` and a scripted editor (`ReorderRig`, in
//  EditorFirstReorderRig.swift, on top of `EditorFirstRig`). The editor's side of a drag (the range move and its reply) is scripted;
//  what these tests pin is what Swift does with it: that the drop never bumps the out-of-queue counter (so an earlier editor-first
//  delete stays quick-undoable), that the entry is recorded as editor-first with the job's snapshot on its slot, that typing made right
//  after the click is kept, that the sidebar shows the moved order until the job has renumbered the rows and follows a delete or an
//  undo made in the meantime, that the plan is worked out inside the structural gate from the list the sidebar has by then, and that
//  a job that fails puts the old order back on the screen and in the sidebar.
//
//  The document has a preamble paragraph, three chapters (Alpha, Bravo, Charlie, each a heading and two paragraphs) and a Notes section
//  with one definition (the reference sits in Bravo's second paragraph). Typing is always into a paragraph with no footnote reference.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// A fault the reorder job's body raises on purpose (`testEFReorderJobBodyHold`).
private struct ReorderJobFault: Error {}

@Suite("Editor-first drag-reorder (t-0b70d1e9, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstReorderTests: QuickUndoFixtures {

    static let document = """
    Preamble paragraph before any heading.

    # Alpha

    Alpha body one.

    Alpha body two.

    # Bravo

    Bravo body one.

    Bravo body two.[^1]

    # Charlie

    Charlie body one.

    Charlie body two.

    # Notes

    [^1]: The footnote text.
    """

    private static let alphaBravoCharlie = ["Alpha", "Bravo", "Charlie", "Notes"]
    private static let bravoAlphaCharlie = ["Bravo", "Alpha", "Charlie", "Notes"]

    private func makeRig(_ markdown: String? = nil) async throws -> ReorderRig {
        try await ReorderRig.make(markdown: markdown ?? Self.document)
    }

    /// The jobs pin the snapshots they write: unpin everything this rig's project holds when the test ends.
    private func unpinSnapshots(_ rig: EditorFirstRig) {
        for snapshot in (try? SnapshotService(database: rig.db, projectId: rig.pid).fetchAllSnapshots()) ?? [] {
            SnapshotService.unpinUndoPointSnapshot(snapshot.id)
        }
    }

    private func row(_ rig: EditorFirstRig, _ text: String) throws -> Block {
        try #require(try rig.blocks().first { $0.textContent == text }, "no block with the text '\(text)'")
    }

    // MARK: - U2

    // U2: a drag in Rich Text is a queued system write, not an out-of-queue write. Before this change the whole-document body bumped
    // `structuralOutOfQueueGeneration`, which closed the quick undo of every earlier editor-first delete. The editor must also have been
    // asked (the drop took the editor-first road at all).
    @Test("reorderDoesNotBumpStructuralGeneration")
    func reorderDoesNotBumpStructuralGeneration() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let before = r.rig.editorState.structuralOutOfQueueGeneration

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        _ = await r.rig.waitUntilSettled()

        #expect(outcome == .performed, "the drop ended \(outcome)")
        #expect(r.clicks.count == 1, "the editor was asked \(r.clicks.count) times: the drop did not take the editor-first road")
        #expect(
            r.rig.editorState.structuralOutOfQueueGeneration == before,
            "the drop bumped structuralOutOfQueueGeneration: \(before) -> \(r.rig.editorState.structuralOutOfQueueGeneration)")
    }

    // MARK: - U3

    // U3: the drop is recorded as an editor-first entry (no snapshot id of its own); the job writes the Version History snapshot of the
    // document as it was BEFORE the move onto the entry's slot and renumbers the rows; there is no quick undo for it; and the `section`
    // table, which the old body never reconciled either (its legacy persist wrote nothing), follows the new order through the settle's
    // section sync. That sync runs only for the project the app has open (`DocumentManager.shared.projectId`), so the test sets it for
    // its own duration, as StructuralUndoControllerSectionConvergenceTests does.
    @Test("reorderRecordsEditorFirstEntryAndSlotSnapshot")
    func reorderRecordsEditorFirstEntryAndSlotSnapshot() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let before = try r.rig.assembledMarkdown()
        await r.sectionSync.syncNow(before)   // the section table as the app has it once a document is open
        let priorProjectId = DocumentManager.shared.projectId
        DocumentManager.shared.projectId = r.rig.pid
        defer { DocumentManager.shared.projectId = priorProjectId }

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        #expect(outcome == .performed, "the drop ended \(outcome)")
        let entry = try #require(r.rig.unifiedUndo.undoStack.last, "the drop recorded no entry")
        #expect(entry.kind == .sectionReorder && entry.title == "Reorder Sections")
        #expect(
            entry.undoSnapshotId == nil && entry.isEditorFirst,
            "the entry carries its own snapshot id: \(String(describing: entry.undoSnapshotId))")
        #expect(await r.rig.waitUntilSettled(), "the job and its settle never ended")

        let slot = try #require(r.rig.controller.efSlots.slot(entry.id), "no slot for the entry")
        let snapshotId = try #require(slot.snapshotId, "the job recorded no snapshot on the slot")
        let snapshot = try #require(try r.rig.db.fetchSnapshot(id: snapshotId))
        #expect(snapshot.previewMarkdown == before, "the slot's snapshot must hold the document as it was before the move")
        #expect(try r.databaseHeadingTitles() == Self.bravoAlphaCharlie, "the rows are not in the new order: \(r.databaseTitles)")
        #expect(!r.rig.controller.quickUndoEligible(entry), "a reorder has no quick undo")

        let sectionTitles = try r.rig.db.fetchSections(projectId: r.rig.pid).sorted { $0.sortOrder < $1.sortOrder }.map(\.title)
        #expect(
            sectionTitles.filter { ["Alpha", "Bravo", "Charlie"].contains($0) } == ["Bravo", "Alpha", "Charlie"],
            "the section table is not in the new order: \(sectionTitles)")
    }

    // MARK: - U4

    // U4: keystrokes made in the instant after the drop (the click is over and the job is reserved, no poll has run) are kept. The user
    // types into Bravo, a paragraph the move does not touch the text of, and the typing reaches the database and stays on the screen.
    //
    // What this test can and cannot say: the rig answers the editor's JavaScript with a script, so it cannot reproduce WebKit's
    // whole-document `setContentWithBlockIds` overwriting live typing, the way the old body did. There is no seam to type at mid-op in
    // the old path here, so the red run of the old behaviour is the end-to-end test E1 (the loss itself); this one pins the outcome of the new
    // road: after everything is quiet the screen and the table are the same text and the typed word is in both.
    @Test("typingAfterClickIsKept")
    func typingAfterClickIsKept() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let typedInto = try row(r.rig, "Bravo body one.")
        r.rig.controller.testOrderingSpy = { [unowned r] step in
            r.rig.spyLog.note(step)
            if step == "efReservedJob" { r.rig.typeIntoEditor(typedInto, appending: " ZEBRA") }   // the user types at once, no click
        }

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        #expect(outcome == .performed, "the drop ended \(outcome)")
        await r.settleThenCarryTyping()

        #expect(r.rig.spyLog.items.contains("efReservedJob"), "the drop never reached the point where the job holds its place")
        let editorMarkdown = try #require(r.rig.editorText, "the editor holds no document")
        let databaseMarkdown = try r.rig.assembledMarkdown()
        #expect(editorMarkdown.contains("ZEBRA"), "the typed word is not on the screen: \(editorMarkdown)")
        #expect(
            ReorderRig.contentLines(editorMarkdown) == ReorderRig.contentLines(databaseMarkdown),
            "after quiet, the screen and the table differ:\n\(editorMarkdown)\n---\n\(databaseMarkdown)")
        #expect(try row(r.rig, "Bravo body one. ZEBRA").id == typedInto.id, "the typed word did not reach the row it was typed into")
        #expect(try r.databaseHeadingTitles() == Self.bravoAlphaCharlie)
    }

    // MARK: - U5

    // U5: delete Charlie (editor-first), drag Alpha after Bravo, undo the drag (the slow undo: a reorder has no quick one). The delete's own
    // quick undo stays available through all of it, and when it runs (no slow route, no "Undoing...") the words typed afterwards reach
    // the database. Before this change the drag bumped the out-of-queue counter and the delete's Cmd-Z became the slow undo.
    @Test("earlierDeleteQuickUndoStaysEligibleAfterReorder")
    func earlierDeleteQuickUndoStaysEligibleAfterReorder() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let deleted = try await delete(r.rig, "Charlie")
        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(r.rig.controller.quickUndoEligible(deleted.entry), "precondition: a fresh editor-first delete is quick-undoable")
        #expect(r.sidebarTitles == ["Alpha", "Bravo", "Notes"], "precondition: the sidebar shows the document without Charlie")

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        #expect(outcome == .performed, "the drop ended \(outcome)")
        _ = await r.rig.waitUntilSettled()
        let reorderEntry = try #require(r.rig.unifiedUndo.undoStack.last)
        #expect(reorderEntry.kind == .sectionReorder, "the top entry is not the reorder: \(reorderEntry.kind)")
        #expect(r.rig.controller.quickUndoEligible(deleted.entry), "the drag made the earlier delete's quick undo ineligible")

        try await restorePress(r.rig, .undo)   // the reorder's undo: slow
        #expect(r.rig.swapScripts.count == 1, "the reorder's undo was not the slow swap: \(r.rig.swapScripts.count) swap(s)")
        #expect(r.rig.controller.quickUndoEligible(deleted.entry), "undoing the drag made the earlier delete's quick undo ineligible")
        #expect(try r.databaseHeadingTitles() == ["Alpha", "Bravo", "Notes"], "the undo did not put the order back")

        try await restorePress(r.rig, .undo)   // the delete's undo: quick
        #expect(r.rig.quickUndoScripts.count == 1, "the delete's undo did not take the quick path")
        #expect(r.rig.swapScripts.count == 1, "the delete's undo took the slow route")
        // (Where the reinserted rows land among the rows the reorder's undo wrote is the reinsert's business, not this test's.)
        #expect(r.databaseTitles.contains("Charlie"), "the delete's undo did not bring Charlie back: \(r.databaseTitles)")

        let alphaBody = try row(r.rig, "Alpha body one.")
        r.rig.typeIntoEditor(alphaBody, appending: " WORD")
        await r.settleThenCarryTyping()
        #expect(try row(r.rig, "Alpha body one. WORD").id == alphaBody.id, "the word typed after the quick undo is not in Alpha's paragraph row")
    }

    // MARK: - U6

    // U6: a drop is planned against the sidebar's list as it is when the command's turn comes, not the one the drop saw. Delete Charlie
    // starts, and the drop (planned against the list that still had Charlie) is held behind it on the gate; when it runs, Charlie is
    // gone from the list, so the order it carries has no Charlie in it. (The same property holds behind a slow Cmd-Z; a delete is the
    // everyday way to change the list inside the gate.) With the pre-gate plan carried out instead, the order would still name Charlie.
    @Test("inGatePlanUsesLiveSections")
    func inGatePlanUsesLiveSections() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let alpha = try r.rig.heading("Alpha")
        let bravo = try r.rig.heading("Bravo")
        let charlie = try r.rig.heading("Charlie")
        let notes = try #require(try r.rig.blocks().first { $0.isNotes && $0.blockType == .heading })
        let staleCards = r.rig.editorState.sections
        #expect(staleCards.map(\.title) == Self.alphaBravoCharlie, "precondition: the drop is planned against all four cards")
        let request = try r.request(moving: "Alpha", after: "Bravo")

        final class DropBox { var task: Task<StructuralUndoController.StructuralOpOutcome, Never>? }
        let box = DropBox()
        r.rig.controller.testOrderingSpy = { [unowned r] step in
            r.rig.spyLog.note(step)
            // The delete's click has the gate: the drop is dispatched now and waits for it.
            if step == "efClickStart", box.task == nil {
                box.task = Task { @MainActor in await r.drop(request, preGatePlanAgainst: staleCards) }
            }
        }
        _ = try await delete(r.rig, "Charlie", settle: false)
        let dropOutcome = try #require(await box.task?.value, "the drop was never dispatched")
        _ = await r.rig.waitUntilSettled()

        #expect(dropOutcome == .performed, "the held drop ended \(dropOutcome)")
        let click = try #require(r.clicks.last, "the editor was never asked to move anything")
        #expect(!click.sentOrder.contains(charlie.id), "the drop carried out the order planned before the delete: it still names Charlie")
        #expect(click.sentOrder == [bravo.id, alpha.id, notes.id], "the applied order is not the one planned from the live list: \(click.sentOrder)")
        #expect(try r.databaseHeadingTitles() == ["Bravo", "Alpha", "Notes"], "got \(r.databaseTitles)")
        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(r.sidebarTitles == ["Bravo", "Alpha", "Notes"], "got \(r.sidebarTitles)")
    }

    // MARK: - The sidebar between the click and the commit

    // The order overlay end to end: while the job has not committed (the writer is held), every outline read still carries the old row
    // order and must be put into the order the editor shows; once the job has settled the overlay is gone and the rows say the same.
    @Test("outlineReadBeforeTheJobCommitsKeepsTheNewOrder")
    func outlineReadBeforeTheJobCommitsKeepsTheNewOrder() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let hold = try r.rig.holdQueue()   // the job is reserved but cannot run
        defer { r.rig.release(hold) }

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        #expect(outcome == .performed, "the drop ended \(outcome)")
        #expect(try r.databaseHeadingTitles() == Self.alphaBravoCharlie, "precondition: the rows still have the old order")
        #expect(r.rig.editorState.pendingReorder != nil, "no overlay was set for the pending reorder")

        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(r.sidebarTitles == Self.bravoAlphaCharlie, "an outline read before the commit put the old order back: \(r.sidebarTitles)")
        #expect(r.editorHeadingTitles == Self.bravoAlphaCharlie)
        #expect(r.rig.editorState.sections.last?.isNotes == true, "the Notes card is not last")

        r.rig.release(hold)
        #expect(await r.rig.waitUntilSettled())
        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(r.rig.editorState.pendingReorder == nil, "the overlay was not lifted when the job settled")
        #expect(r.sidebarTitles == Self.bravoAlphaCharlie, "got \(r.sidebarTitles)")
        #expect(try r.databaseHeadingTitles() == Self.bravoAlphaCharlie)
    }

    // U11: drag, then Cmd-Z at once. The undo of a drag is the slow one: it waits for the drag's job (the writer is held until the press
    // is on its way), and what the sidebar shows afterwards must be the order the text has, the old one, not the dragged one.
    @Test("dragThenUndoAtOnceSidebarMatchesText")
    func dragThenUndoAtOnceSidebarMatchesText() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let hold = try r.rig.holdQueue()
        defer { r.rig.release(hold) }

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        #expect(outcome == .performed, "the drop ended \(outcome)")
        #expect(r.sidebarTitles == Self.bravoAlphaCharlie, "precondition: the sidebar shows the dragged order")
        let entry = try #require(r.rig.unifiedUndo.undoStack.last)
        let undo = r.rig.startPress(entry, .undo)   // waits for the drag's job
        r.rig.release(hold)
        #expect(await r.rig.awaitRuns([undo]), "the undo did not end")
        _ = await r.rig.waitUntilSettled()

        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(r.rig.replyWords() == ["undo performed"], "got \(r.rig.replyWords())")
        #expect(r.sidebarTitles == Self.alphaBravoCharlie, "the sidebar does not match the text after the undo: \(r.sidebarTitles)")
        #expect(r.editorHeadingTitles == Self.alphaBravoCharlie, "the text is not back in the old order: \(r.editorHeadingTitles)")
        #expect(try r.databaseHeadingTitles() == Self.alphaBravoCharlie)
        #expect(r.rig.editorState.pendingReorder == nil)
    }

    // U12: drag Alpha after Bravo, then Delete Section on Alpha (the section just dragged) before the drag's job has applied. An outline
    // read in that window must not bring Alpha's card back (the removal filter wins over the order overlay, which never adds a card);
    // afterwards both jobs have applied and the sidebar and the table agree. (Alpha, not Bravo: Bravo's paragraph holds the footnote
    // reference, and deleting it would also take the footnote and the Notes section out, which is not what this test is about.)
    @Test("dragThenDeleteAtOnceCardStaysGone")
    func dragThenDeleteAtOnceCardStaysGone() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let hold = try r.rig.holdQueue()
        defer { r.rig.release(hold) }

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        #expect(outcome == .performed, "the drop ended \(outcome)")
        let alpha = try r.rig.heading("Alpha")
        _ = try await delete(r.rig, "Alpha", settle: false)

        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(!r.rig.editorState.sections.contains { $0.id == alpha.id }, "Alpha's card is back in the sidebar: \(r.sidebarTitles)")
        #expect(r.sidebarTitles == ["Bravo", "Charlie", "Notes"], "got \(r.sidebarTitles)")

        r.rig.release(hold)
        #expect(await r.rig.waitUntilSettled(), "the two jobs did not settle")
        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(!r.rig.editorState.sections.contains { $0.id == alpha.id }, "Alpha's card is back after the jobs: \(r.sidebarTitles)")
        #expect(try r.databaseHeadingTitles() == ["Bravo", "Charlie", "Notes"], "got \(r.databaseTitles)")
        #expect(r.sidebarTitles == ["Bravo", "Charlie", "Notes"], "got \(r.sidebarTitles)")
        #expect(r.rig.editorState.pendingReorder == nil && r.rig.editorState.pendingRemovalIds.isEmpty, "an overlay or filter was not lifted")
    }

    // MARK: - U9

    private static let failedMoveMessage =
        "The move couldn't be saved, so the sections are back in their earlier order. "
        + "If you typed in the last moments, check that your text is still there."

    // U9: the job fails. The put-back gives the old order back on the screen and in the sidebar, drops the entry, and tells the user
    // once, in the words of UX contract 4.3.
    @Test("failedJobPutsOrderBack")
    func failedJobPutsOrderBack() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        r.rig.modelsWholePushOnEditor = true
        r.rig.controller.testEFReorderJobBodyHold = { throw ReorderJobFault() }
        let hold = try r.rig.holdQueue()   // the job is reserved but cannot fail yet
        defer { r.rig.release(hold) }

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        #expect(outcome == .performed, "the drop ended \(outcome)")
        #expect(r.sidebarTitles == Self.bravoAlphaCharlie, "precondition: the sidebar showed the dragged order at once")
        r.rig.release(hold)
        await r.settleThenCarryTyping()
        await r.rig.editorState.refreshSectionsAwaiting()

        #expect(r.rig.alerts.map(\.title) == ["Couldn't Move Section"], "expected exactly one alert, got \(r.rig.alerts)")
        #expect(r.rig.alerts.first?.message == Self.failedMoveMessage, "got \(String(describing: r.rig.alerts.first?.message))")
        #expect(r.sidebarTitles == Self.alphaBravoCharlie, "the sidebar still shows the dragged order: \(r.sidebarTitles)")
        #expect(r.editorHeadingTitles == Self.alphaBravoCharlie, "the editor still shows the dragged order: \(r.editorHeadingTitles)")
        #expect(try r.databaseHeadingTitles() == Self.alphaBravoCharlie)
        #expect(r.rig.editorState.pendingReorder == nil, "the order overlay was not lifted")
        #expect(r.rig.unifiedUndo.undoStack.isEmpty, "the failed reorder is still on the timeline")
        #expect(r.rig.editorState.pendingEditorFirstJobs == 0)
    }

    // U9, part two: the project is closing (the structural gate is closed) when the put-back runs. It does nothing to the screen (the
    // close saves the document itself), but the overlay must still be lifted and the entry removed.
    // (RARE: a job failing at the very moment a project closes; the plan asks for the overlay to be cleared on this exit too.)
    @Test("failedJobWithTheGateClosedStillLiftsTheOverlay")
    func failedJobWithTheGateClosedStillLiftsTheOverlay() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let jobMayRun = DispatchSemaphore(value: 0)
        defer { jobMayRun.signal() }
        r.rig.controller.testEFReorderJobBodyHold = { jobMayRun.wait(); throw ReorderJobFault() }

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        #expect(outcome == .performed, "the drop ended \(outcome)")
        #expect(r.rig.editorState.pendingReorder != nil, "precondition: the overlay is set while the job is held")
        r.rig.editorState.structuralGate.isClosedToNewWork = true
        defer { r.rig.editorState.structuralGate.isClosedToNewWork = false }
        jobMayRun.signal()
        #expect(await r.rig.waitUntilSettled(), "the failed job never settled")

        #expect(r.rig.editorState.pendingReorder == nil, "the order overlay stayed up after the failed job with the gate closed")
        #expect(r.rig.unifiedUndo.undoStack.isEmpty, "the failed reorder is still on the timeline")
        #expect(r.rig.alerts.isEmpty, "the put-back must not touch the screen of a closing project: \(r.rig.alerts)")
    }

}

// The rest of the suite, in an extension of the same struct and file only so the struct body stays under SwiftLint's type length limit.
// (`private` members of the struct are visible here: same type, same file.)
extension EditorFirstReorderTests {

    // MARK: - U14

    // U14: Bravo was made a sub-section (level 2) in the editor and in the table a moment ago, and the sidebar has not caught up (it
    // still says level 1). Dragging Charlie to the top changes no level, so Bravo keeps level 2 in the table and in the editor. The old body
    // wrote the level of every card the sidebar showed and put Bravo back to 1.
    @Test("levelChangedJustBeforeDragSurvives")
    func levelChangedJustBeforeDragSurvives() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let bravo = try r.rig.heading("Bravo")
        try Self.makeLevelTwo(r.rig, headingId: bravo.id)
        let screen = r.rig.editorText ?? r.rig.quickEditorText ?? r.rig.editorState.content
        let levelTwoScreen = screen.replacingOccurrences(of: "\n# Bravo\n", with: "\n## Bravo\n")
        #expect(levelTwoScreen != screen, "precondition: the fixture text has the Bravo heading")
        r.rig.editorText = levelTwoScreen
        r.rig.quickEditorText = levelTwoScreen
        r.rig.editorState.content = levelTwoScreen
        #expect(r.rig.editorState.sections.first { $0.id == bravo.id }?.headerLevel == 1, "precondition: the sidebar still says level 1")

        let outcome = try await r.reorder("Charlie", after: nil)
        #expect(outcome == .performed, "the drop ended \(outcome)")
        _ = await r.rig.waitUntilSettled()

        let click = try #require(r.clicks.last)
        #expect(click.sentLevels[bravo.id] == nil, "the order carried a level for Bravo: \(click.sentLevels)")
        let row = try r.rig.heading("Bravo")
        #expect(row.headingLevel == 2, "Bravo's level in the table was reset to \(String(describing: row.headingLevel))")
        #expect(row.markdownFragment == "## Bravo", "Bravo's text in the table is '\(row.markdownFragment)'")
        #expect(
            r.rig.editorText?.contains("\n## Bravo\n") == true, "Bravo is no longer a level-2 heading in the editor: \(r.editorHeadingTitles)")
        #expect(try r.databaseHeadingTitles() == ["Charlie", "Alpha", "Bravo", "Notes"], "got \(r.databaseTitles)")
    }

    /// Bravo's heading row is level 2 with the matching text. A plain (non-async) function: inside an `async` test `dbWriter.write` resolves
    /// to GRDB's async overload.
    private static func makeLevelTwo(_ rig: EditorFirstRig, headingId: String) throws {
        _ = try rig.db.dbWriter.write { database in
            try Block.filter(key: headingId).updateAll(
                database, Block.Columns.headingLevel.set(to: 2), Block.Columns.markdownFragment.set(to: "## Bravo"))
        }
    }

    // MARK: - The old road

    // Binding extras 8: in Markdown mode the drop keeps the old whole-document body (the editor is never asked), it still counts as an
    // out-of-queue write, the entry carries its own snapshot id, and the content state is idle afterwards so typing straight after is
    // polled and saved.
    @Test("markdownModeReorderTakesTheOldRoadAndLeavesTheContentStateIdle")
    func markdownModeReorderTakesTheOldRoadAndLeavesTheContentStateIdle() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        r.rig.editorState.editorMode = .source
        let before = r.rig.editorState.structuralOutOfQueueGeneration

        let outcome = try await r.reorder("Alpha", after: "Bravo")
        _ = await r.rig.waitUntilSettled()

        #expect(outcome == .performed, "the drop ended \(outcome)")
        #expect(r.clicks.isEmpty, "the Rich Text editor was asked to move sections in Markdown mode")
        #expect(
            r.rig.editorState.contentState == .idle,
            "the content state is \(r.rig.editorState.contentState): typing straight after would not be polled")
        #expect(r.rig.editorState.structuralOutOfQueueGeneration > before, "the old body no longer counts as an out-of-queue write")
        let entry = try #require(r.rig.unifiedUndo.undoStack.last)
        #expect(entry.kind == .sectionReorder && !entry.isEditorFirst && entry.undoSnapshotId != nil, "got \(entry)")
        #expect(try r.databaseHeadingTitles() == Self.bravoAlphaCharlie, "the old body did not reorder the rows")
    }

    // MARK: - A restore pressed right after a drag

    // The reorder overlay refers to the document as it was before a LATER operation that swaps the whole outline (here Restore Entire
    // Project of a version saved before the drag). That operation records its own sidebar state and must clear the older order, or the
    // restored outline would be put into the dragged order, which the restored text does not have.
    @Test("dragThenRestoreAtOnceSidebarFollowsTheRestore")
    func dragThenRestoreAtOnceSidebarFollowsTheRestore() async throws {
        let r = try await makeRig()
        defer { unpinSnapshots(r.rig) }
        let version = try saveVersion(r.rig)
        let hold = try r.rig.holdQueue()
        defer { r.rig.release(hold) }

        let dropOutcome = try await r.reorder("Alpha", after: "Bravo")
        #expect(dropOutcome == .performed, "the drop ended \(dropOutcome)")
        let restoreOutcome = await r.rig.performRestore("project", from: version)
        #expect(restoreOutcome == .performed, "the restore ended \(restoreOutcome)")
        #expect(r.rig.editorState.pendingReorder == nil, "the restore left the older drag's order overlay in place")

        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(r.sidebarTitles == Self.alphaBravoCharlie, "the restored outline was put into the dragged order: \(r.sidebarTitles)")

        r.rig.release(hold)
        #expect(await r.rig.waitUntilSettled(), "the two jobs did not settle")
        await r.rig.editorState.refreshSectionsAwaiting()
        #expect(r.sidebarTitles == Self.alphaBravoCharlie, "got \(r.sidebarTitles)")
        #expect(try r.databaseHeadingTitles() == Self.alphaBravoCharlie)
    }
}
