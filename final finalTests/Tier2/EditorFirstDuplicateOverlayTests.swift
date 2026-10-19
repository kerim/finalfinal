//
//  EditorFirstDuplicateOverlayTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 1, round 1g-A: the controller-side fixes of the slice-1 code review, items A1, A4 and A7): the
//  controller's editor-first Duplicate Section driven with a REAL `BlockSyncService` and `DocumentWriter` and a scripted editor
//  (`EditorFirstRig`, answers in EditorFirstRig+StructuralQueue.swift and EditorFirstRig+QuickUndo.swift).
//
//    A1  Acting on the NEW COPY straight after Duplicate. The sidebar shows the copy at once (an overlay), but its rows are not in the
//        table until the queued job commits; the next Delete or Duplicate of the copy used to read the table, find nothing, and fall
//        to the old path, which refused with "Couldn't ... Nothing was changed". Every rig test settled between two operations, so no
//        test saw it; these hold the first job (`testEFJobBodyHold`) and act on the copy before it can commit.
//    A4  The undo's settle must not wipe the sidebar overlay that a redo of the duplicate set meanwhile.
//    A7  The editor's own id for the root heading can still be a temporary one (`rootNotFound`): the press goes on the old way instead
//        of ending in a refusal.
//    A5  (round 1g-B) The undo of a duplicate hides only the COPY's leaders from the sidebar, whatever the editor lists as taken out.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Editor-first duplicate: the copy at once, the redo's overlay, an unconfirmed heading (round 1g-A)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct EditorFirstDuplicateOverlayTests: QuickUndoFixtures {

    /// Duplicates Section C with the job parked in its body (the writer's thread waits on `jobMayRun`), so the copy is on the screen and
    /// in the sidebar but not in the table. Jobs queued after it get no hold of their own (they wait behind it anyway).
    private func duplicateWithJobParked(_ rig: EditorFirstRig, jobMayRun: DispatchSemaphore) async throws -> DuplicateClick {
        rig.controller.testEFJobBodyHold = { jobMayRun.wait() }
        let outcome = await rig.controller.performSectionDuplicate(rootId: try rig.heading("Section C").id)
        rig.controller.testEFJobBodyHold = nil
        #expect(outcome == .performed, "the duplicate of Section C ended \(outcome)")
        let click = try #require(rig.duplicateClicks.values.first)
        let copyRoot = try #require(click.copyLeaderIds.first)
        #expect(try !rig.blocks().contains { $0.id == copyRoot }, "precondition: the copy's rows are not in the table yet")
        #expect(rig.editorState.sections.contains { $0.id == copyRoot }, "precondition: the sidebar shows the copy")
        return click
    }

    private func press(_ rig: EditorFirstRig, _ direction: StructuralUndoController.UndoDirection) async throws {
        let entry = try #require(direction == .undo ? rig.unifiedUndo.undoStack.last : rig.unifiedUndo.redoStack.last)
        #expect(await rig.pressAndSettle(entry, direction), "the \(direction) did not end and settle")
        _ = await rig.waitUntilSettled()
    }

    /// The non-empty lines of a Markdown text: what the screen and the table are compared by (blank lines carry no content).
    private func contentLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - A1

    // A1 (i): Duplicate Section C, then at once Delete Section on the new copy (the copy's rows are not in the table yet). The delete is
    // carried out, not refused with the "Nothing was changed" alert; the copy leaves the table, the editor and the sidebar, the original
    // section is untouched, and the two Cmd-Z presses undo the delete and then the duplicate, one at a time.
    @Test func testDeleteOfTheCopyRightAfterTheDuplicateIsCarriedOut() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let jobMayRun = DispatchSemaphore(value: 0)
        defer { jobMayRun.signal() }
        let click = try await duplicateWithJobParked(rig, jobMayRun: jobMayRun)
        let copyRoot = try #require(click.copyLeaderIds.first)
        try rig.setReply(.init(removedLeaderIds: click.copyLeaderIds), forRoot: copyRoot)

        let outcome = await rig.controller.performSectionDelete(rootId: copyRoot)
        #expect(outcome == .performed, "Delete Section on the copy straight after the duplicate ended \(outcome)")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
        await rig.editorState.refreshSectionsAwaiting()
        #expect(!rig.editorState.sections.contains { $0.id == copyRoot }, "the deleted copy's card is back in the sidebar")

        jobMayRun.signal()
        #expect(await rig.waitUntilSettled(), "the two jobs did not settle")
        #expect(try rig.presentRowCount(click.copyIds) == 0, "the deleted copy's rows are still in the table")
        let texts = try rig.blocks().map(\.textContent)
        #expect(!texts.contains("Section C copy"), "the copy is still in the table: \(texts)")
        #expect(texts.contains("Section C") && texts.filter { $0 == "The C body." }.count == 1, "the original section is not intact: \(texts)")
        #expect(rig.editorText?.contains("Section C copy") == false, "the copy is still in the editor")
        #expect(rig.alerts.isEmpty, "an alert was raised after the jobs ran: \(rig.alerts)")
        await rig.editorState.refreshSectionsAwaiting()
        #expect(!rig.editorState.sections.contains { $0.id == copyRoot }, "the deleted copy's card is in the sidebar after the jobs")

        // Cmd-Z: the delete is undone, the copy is back. Cmd-Z again: the duplicate is undone, the copy is gone and the original stays.
        try await press(rig, .undo)
        let backAfterFirstUndo = try rig.presentRowCount(click.copyIds)
        #expect(
            backAfterFirstUndo == click.copyIds.count,
            "the first Cmd-Z did not bring the copy back: \(backAfterFirstUndo) of \(click.copyIds.count) rows")
        #expect(rig.editorText?.contains("Section C copy") == true, "the first Cmd-Z did not bring the copy back into the editor")
        try await press(rig, .undo)
        #expect(try rig.presentRowCount(click.copyIds) == 0, "the second Cmd-Z did not take the copy out again")
        let after = try rig.blocks().map(\.textContent)
        #expect(after.contains("Section C") && after.contains("The C body.") && !after.contains("Section C copy"), "got \(after)")
        #expect(rig.replyWords() == ["undo performed", "undo performed"], "got \(rig.replyWords())")
    }

    // A1 (ii): Duplicate Section C, then at once Duplicate the new copy. Both go through; after the jobs there are three sections (the
    // original and two copies) with their own ids, and the editor's text equals the table's.
    @Test func testDuplicateOfTheCopyRightAfterTheDuplicateMakesASecondCopyWithItsOwnIds() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let jobMayRun = DispatchSemaphore(value: 0)
        defer { jobMayRun.signal() }
        let first = try await duplicateWithJobParked(rig, jobMayRun: jobMayRun)
        let copyRoot = try #require(first.copyLeaderIds.first)

        let outcome = await rig.controller.performSectionDuplicate(rootId: copyRoot)
        #expect(outcome == .performed, "Duplicate Section on the copy straight after the duplicate ended \(outcome)")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")

        jobMayRun.signal()
        #expect(await rig.waitUntilSettled(), "the two jobs did not settle")
        let second = try #require(rig.duplicateClicks.values.first { $0.rootId == copyRoot }, "the second click was not answered")
        #expect(Set(first.copyIds).isDisjoint(with: second.copyIds), "the two copies share ids: \(first.copyIds) and \(second.copyIds)")
        #expect(try rig.presentRowCount(first.copyIds) == first.copyIds.count, "the first copy's rows are not all in the table")
        #expect(try rig.presentRowCount(second.copyIds) == second.copyIds.count, "the second copy's rows are not all in the table")
        let headings = try rig.blocks().filter { $0.blockType == .heading && $0.textContent.hasPrefix("Section C") }.map(\.textContent)
        #expect(headings.sorted() == ["Section C", "Section C copy", "Section C copy copy"], "got \(headings)")
        let screen = try #require(rig.editorText, "the editor holds no document")
        let tableText = try rig.assembledMarkdown()
        #expect(contentLines(screen) == contentLines(tableText), "the editor and the table differ:\n\(screen)\n---\n\(tableText)")
        #expect(rig.alerts.isEmpty, "an alert was raised after the jobs ran: \(rig.alerts)")
    }

    // MARK: - A4

    // A4: Duplicate, Cmd-Z, Cmd-Shift-Z before the undo's settle has run. The redo shows the copy in the sidebar through an overlay until
    // its own job commits; the undo's settle, which runs after the redo has taken the entry, must leave that overlay alone. (Before the
    // fix it cleared the overlay on its way out and the copy's cards left the sidebar until the redo's job settled.)
    @Test func testTheUndosSettleLeavesTheRedosSidebarOverlayAlone() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let duplicateOutcome = await rig.controller.performSectionDuplicate(rootId: try rig.heading("Section C").id)
        #expect(duplicateOutcome == .performed, "the duplicate ended \(duplicateOutcome)")
        _ = await rig.waitUntilSettled()
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        let click = try #require(rig.duplicateClicks.values.first)

        let settleMayRun = LifecycleEntryHarness.Gate()
        defer { settleMayRun.open() }
        rig.controller.testReinsertSettleHold = { await settleMayRun.wait() }   // the undo's settle waits at its first line
        let undo = rig.startPress(entry, .undo)
        #expect(await rig.awaitRuns([undo]), "the undo did not end")
        // The reinsert (which takes the copy's rows out of the table) runs in the writer's queue; only its settle is parked.
        let copyRowsGone = await gateWaitUntil({ (try? rig.presentRowCount(click.copyIds)) == 0 })
        #expect(copyRowsGone, "precondition: the undo's reinsert did not take the copy's rows out of the table")
        let blocker = try rig.holdQueue()   // the redo's job cannot run: the copy stays an overlay in the sidebar
        defer { rig.release(blocker) }
        let redo = rig.startPress(try #require(rig.unifiedUndo.redoStack.last), .redo)
        #expect(await rig.awaitRuns([redo]), "the redo did not end")
        #expect(rig.editorState.pendingRestoreSections[entry.id] != nil, "precondition: the redo shows the copy through an overlay")

        settleMayRun.open()   // the undo's settle runs now, after the redo has taken the entry
        let ran = await gateWaitUntil({ rig.spyLog.items.contains("reinsertApplied") })
        #expect(ran, "the undo's settle did not run")
        await rig.editorState.refreshSectionsAwaiting()
        #expect(
            rig.editorState.pendingRestoreSections[entry.id] != nil,
            "the undo's settle wiped the sidebar overlay of the redo that took the entry")
        let shown = click.copyLeaderIds.filter { id in rig.editorState.sections.contains { $0.id == id } }
        #expect(
            shown == click.copyLeaderIds,
            "the copy's cards left the sidebar after the undo's settle: \(shown.count) of \(click.copyLeaderIds.count)")

        rig.release(blocker)
        #expect(await rig.waitUntilSettled(), "the redo's job did not settle")
        #expect(try rig.presentRowCount(click.copyIds) == click.copyIds.count, "the redo did not put the copy back into the table")
        #expect(rig.editorState.pendingRestoreSections.isEmpty, "the redo's overlay was not lifted when its job settled")
    }

    // MARK: - A7

    // A7: the editor answers `rootNotFound` (its id for the root heading is still a temporary one, although the database row and the
    // sidebar entry are confirmed). Nothing was changed on the screen, so the press goes on the old way and the section is duplicated;
    // it is not refused with "Couldn't Duplicate Section ... Nothing was changed".
    @Test func testDuplicateWhenTheEditorDoesNotKnowTheRootYetGoesOnTheOldWay() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.forceEditorRootNotFound = true
        let outcome = await rig.controller.performSectionDuplicate(rootId: try rig.heading("Section C").id)
        #expect(outcome == .performed, "Duplicate Section on a heading the editor has no id for yet ended \(outcome)")
        _ = await rig.waitUntilSettled()
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
        #expect(rig.duplicateScripts.count == 1, "the editor was asked \(rig.duplicateScripts.count) times")
        #expect(!rig.scripts(containing: "beginStructuralOp").isEmpty, "the old whole sequence did not run")
        #expect(try rig.blocks().contains { $0.textContent == "Section C copy" }, "the copy is not in the table")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count stayed up")
        #expect(rig.unifiedUndo.undoStack.count == 1 && rig.unifiedUndo.undoStack.last?.kind == .sectionDuplicate, "the duplicate was not recorded")
    }

    // MARK: - A5 (round 1g-B)

    /// Two section breaks around the duplicated section, so the editor's list of "leaders the undo took out" can name them.
    private static let partsWithBreaks = """
    # Part One

    The part one body.

    <!-- ::break:: -->

    # Part Two

    ## Section C

    The C body.

    <!-- ::break:: -->

    # Part Three

    The part three body.
    """

    // A5: the editor's `removedLeaderIds` for the undo of a duplicate is "the live leaders whose id the checkpoint's id map lacks". After a
    // flush that re-minted the ids of non-heading blocks (the idle backup, Save Version, export) that list also holds every ORIGINAL
    // section break of the document. The sidebar must hide the copy's leaders only: until the reinsert's settle refreshes it, the original
    // sections' cards stay (before the fix they all left, and the sidebar healed only when the settle ran).
    //
    // What this does and does not prove: the rig cannot re-mint ids, so it answers the undo with the list the real editor would give
    // after a re-mint (`undoAlsoReportsRemoved`: the original breaks' ids besides the copy's leader) while the rows and the sidebar still
    // carry the original ids. It pins what Swift does with such a reply -- hide the intersection with the copy's own ids -- not the
    // web side's computation of the list (api-section-undo.ts) and not the flush itself.
    @Test func testTheUndoOfADuplicateHidesOnlyTheCopysLeadersNotTheOriginalSectionBreaks() async throws {
        let rig = try EditorFirstRig(markdown: Self.partsWithBreaks)
        let breakIds = try rig.blocks().filter(\.isPseudoSection).map(\.id)
        #expect(breakIds.count == 2, "the document should hold two section breaks, got \(breakIds.count)")

        let outcome = await rig.controller.performSectionDuplicate(rootId: try rig.heading("Section C").id)
        #expect(outcome == .performed, "the duplicate of Section C ended \(outcome)")
        #expect(await rig.waitUntilSettled(), "the duplicate never settled")
        await rig.editorState.refreshSectionsAwaiting()
        let click = try #require(rig.duplicateClicks.values.first)
        let copyLeader = try #require(click.copyLeaderIds.first)
        for id in breakIds {
            #expect(rig.editorState.sections.contains { $0.id == id }, "precondition: the sidebar shows the section break \(id)")
        }
        #expect(rig.editorState.sections.contains { $0.id == copyLeader }, "precondition: the sidebar shows the copy")

        // Cmd-Z, with the undo's settle parked at its first line: what the sidebar shows is what the quick undo itself left there.
        rig.undoAlsoReportsRemoved = breakIds
        let settleMayRun = LifecycleEntryHarness.Gate()
        defer { settleMayRun.open() }
        rig.controller.testReinsertSettleHold = { await settleMayRun.wait() }
        let undo = rig.startPress(try #require(rig.unifiedUndo.undoStack.last), .undo)
        #expect(await rig.awaitRuns([undo]), "the undo did not end")

        for id in breakIds {
            #expect(
                rig.editorState.sections.contains { $0.id == id },
                "an original section break (\(id)) left the sidebar when the duplicate was undone")
        }
        #expect(!rig.editorState.sections.contains { $0.id == copyLeader }, "the undone copy is still in the sidebar")
        #expect(
            rig.editorState.pendingRemovalIds.isDisjoint(with: Set(breakIds)),
            "the outline results filter out an original section break: \(rig.editorState.pendingRemovalIds)")

        settleMayRun.open()
        #expect(await rig.waitUntilSettled(), "the undo never settled")
        await rig.editorState.refreshSectionsAwaiting()
        for id in breakIds {
            #expect(rig.editorState.sections.contains { $0.id == id }, "an original section break (\(id)) is not in the sidebar after the settle")
        }
        #expect(!rig.editorState.sections.contains { $0.id == copyLeader }, "the copy is back in the sidebar after the settle")
        #expect(rig.editorState.pendingRemovalIds.isEmpty, "a filter was not lifted: \(rig.editorState.pendingRemovalIds)")
        #expect(try rig.presentRowCount(click.copyIds) == 0, "the undo did not take the copy's rows out of the table")
    }
}
