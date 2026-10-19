//
//  EditorFirstRestoreUndoTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 2, round 2d-i; the judge's extra unit tests of round 2a (notes F2) and the slice-1 lessons (a) to
//  (e)): the whole-project restore meeting a stale Notes or bibliography rebuild, its quick undo and redo, and the sidebar. The click and
//  its failures are EditorFirstRestoreTests.swift. Helpers: EditorFirstRestoreFixtures.swift.
//
//  THE STAMP. A rebuild reads the database, and some time later pushes what it read into the editor. A restore click changes the
//  editor's whole document before the database follows, so a rebuild that read the old table would put the OLD document back over the
//  restored one. The guard (`rebuildPushStillWanted`) skips that push; the model checks only its click-generation half (round 1a verdict
//  M1), so the unit tests cover BOTH orders: (i) a rebuild that read BEFORE the click and lands after it; (ii) one that read AFTER the
//  click and lands while the restore's job is still pending. The rig's editor has no ContentView, so no rebuild fires by itself: a
//  stand-in Task (`startStampedRebuildNotingSkip`) plays the rebuild through the real guard. Its push is recorded by the rig only when
//  the guard lets it through, so `rig.pushes` is what actually reached the editor.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Editor-first restore: rebuild guard, undo, redo, sidebar (t-18b7fa48 slice 2, 2d-i)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstRestoreUndoTests: QuickUndoFixtures {

    // MARK: - A rebuild that read before the click, or while the job was pending (round 2a verdict, notes F2)

    /// What the user sees after a restore that met a stale rebuild: the editor's text is the restored document and nothing the editor
    /// was pushed after the click carries the pre-restore text.
    private func expectTheEditorKeepsTheRestoredDocument(_ rig: EditorFirstRig, pushesFrom: Int, marker: String) throws {
        let text = try #require(rig.editorText, "the editor holds no document")
        #expect(!text.contains(marker), "the editor's text is the pre-restore document again")
        let plan = try #require(rig.controller.testLastRestorePlan)
        let restored = Self.ownText(of: plan.markdown)
        #expect(Self.ownText(of: text) == restored, "the editor's text is not the restored document")
        let pushes = Array(rig.pushes[pushesFrom...])
        #expect(
            pushes.allSatisfy { !$0.markdown.contains(marker) },
            "the stale rebuild pushed the pre-restore document (\(pushes.count) push(es) after the click)")
        #expect(Self.ownText(of: rig.editorState.content) == restored, "content is not the restored document (the stale rebuild's text stayed)")
        // Fix round F1, review C2: the push the stale rebuild skipped is made up for by the settle's closing push, so once everything has
        // settled the editor's Notes and Bibliography regions are the database's (`ownText` leaves them out of the comparison above).
        let databaseNotes = Self.notesRegion(of: try rig.assembledMarkdown())
        #expect(
            Self.notesRegion(of: text) == databaseNotes,
            "the editor's Notes were left behind: the skipped rebuild's push was not made up for after the restore")
    }

    // (i) A Notes or bibliography rebuild that READ the database BEFORE the restore click lands after it. Its push is skipped and the
    // editor's text is still the restored document, on the article and on the six-chapter book.
    @Test("A rebuild that read before the restore click skips its push; the editor still shows the restored document",
          arguments: ["article", "book6"])
    func testStaleRebuildReadBeforeTheClickDoesNotBringBackTheOldDocument(_ doc: String) async throws {
        let rig = try makeRestoreRig(doc)
        let version = try saveVersion(rig)
        try editAParagraph(rig)
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // reads the pre-restore document
        let pushesFrom = rig.pushes.count

        #expect(await rig.performRestore("project", from: version) == .performed)
        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
        let settled = await rig.waitUntilSettled()

        #expect(landed, "the stand-in rebuild never landed")
        #expect(settled, "the restore never settled")
        #expect(rig.events.items.contains("rebuild push skipped"), "the guard did not skip the push of the rebuild that read before")
        #expect(rig.events.items.contains("rebuild content-equals-live=true"), "content lost the restored text to the stale rebuild")
        try expectTheEditorKeepsTheRestoredDocument(rig, pushesFrom: pushesFrom, marker: "EDITED-BEFORE")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count came back down")
    }

    // (ii) A rebuild that read the database WHILE the restore job was pending (the table still holds the old document) lands later. The
    // click generation has not moved since it read; only the pending-jobs half of the stamp can skip it.
    @Test("A rebuild that read while the restore job was pending skips its push; the editor still shows the restored document",
          arguments: ["article", "book6"])
    func testStaleRebuildReadWhileTheJobWasPendingDoesNotBringBackTheOldDocument(_ doc: String) async throws {
        let rig = try makeRestoreRig(doc)
        let version = try saveVersion(rig)
        try editAParagraph(rig)
        let hold = try rig.holdQueue()   // the restore's job is reserved but cannot run: the table still holds the old document
        let pushesFrom = rig.pushes.count
        #expect(await rig.performRestore("project", from: version) == .performed)
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // reads the OLD document, after the click, while the job pends
        #expect(try rig.blocks().contains { $0.textContent.contains("EDITED-BEFORE") }, "the job ran although the queue was held")

        rig.release(hold)
        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
        let settled = await rig.waitUntilSettled()

        #expect(landed, "the stand-in rebuild never landed")
        #expect(settled, "the restore never settled")
        #expect(rig.events.items.contains("rebuild push skipped"), "the guard did not skip the push of the rebuild that read while pending")
        try expectTheEditorKeepsTheRestoredDocument(rig, pushesFrom: pushesFrom, marker: "EDITED-BEFORE")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count came back down")
    }

    // MARK: - The quick undo and redo

    // The limit-9 hole (round 2a verdict): Cmd-Z (the quick undo) of a whole restore with a Notes rebuild in flight. The rebuild read the
    // RESTORED document; if it landed on top of the undo it would put the restored document (its ids) back over the old one. The editor
    // still shows the pre-restore document with its OLD ids, and the database rows are the pre-restore rows.
    @Test("Cmd-Z of a whole restore with a rebuild in flight: the editor keeps the old document and its ids, the table the old rows",
          arguments: ["article", "book6"])
    func testQuickUndoOfWholeRestoreWithARebuildInFlight(_ doc: String) async throws {
        let rig = try makeRestoreRig(doc)
        let version = try saveVersion(rig)
        try editAParagraph(rig)
        let rowsBefore = try userRows(rig)
        let preRestoreAllIds = Set(try rig.blocks().map(\.id))
        let preText = try rig.assembledMarkdown()

        #expect(await rig.performRestore("project", from: version) == .performed)
        let plan = try #require(rig.controller.testLastRestorePlan)
        _ = await rig.waitUntilSettled()
        // The ids only the RESTORED document has: not one row of the whole table before the restore. (Computed against ALL the rows, the
        // Notes and Bibliography ones included: a heading kept by title keeps its id, so the restored document shares those with the
        // old one, and the undo's own re-push of the database's regions legitimately carries them.)
        let restoredOnlyIds = Set(plan.rows.map(\.id)).subtracting(preRestoreAllIds)
        #expect(!restoredOnlyIds.isEmpty, "the restore changed no ids: the test would prove nothing")

        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // the rebuild in flight: it read the RESTORED document
        let pushesFrom = rig.pushes.count
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        let undo = rig.startPress(entry, .undo)
        #expect(await gateWaitUntil({ undo.done }, iterations: 4000), "the undo did not end")
        mayLand.open()
        _ = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
        let settled = await rig.waitUntilSettled()

        #expect(settled, "the undo never settled")
        #expect(rig.quickUndoScripts.count == 1, "expected the quick undo, saw \(rig.quickUndoScripts.count) quick undo call(s)")
        #expect(rig.replyWords().suffix(1) == ["undo performed"], "got \(rig.replyWords())")
        let screen = try #require(rig.editorText)
        #expect(Self.ownText(of: screen) == Self.ownText(of: preText), "the editor does not show the pre-restore document")
        #expect(rig.events.items.contains("rebuild push skipped"), "the guard did not skip the push of the rebuild that read the restored document")
        let pushes = Array(rig.pushes[pushesFrom...])
        let detail = pushes.map { push in
            "preserve=\(push.preserveUserBlocks) ids=\(push.blockIds.count) restoredOnly=\(Set(push.blockIds).intersection(restoredOnlyIds).count)"
        }
        #expect(
            pushes.allSatisfy { Set($0.blockIds).isDisjoint(with: restoredOnlyIds) },
            "the editor was pushed ids of the restored document after the undo (the stale rebuild's push): \(detail)")
        let rowsAfter = try userRows(rig)
        #expect(Set(rowsAfter.map(\.id)) == Set(rowsBefore.map(\.id)), "the table does not hold the pre-restore rows")
        #expect(EditorFirstRig.parityProblem(rowsBefore, rowsAfter) == nil, "the rows differ from the pre-restore rows")
        let stateAfter = rig.editorState
        #expect(stateAfter.pendingRemovalIds.isEmpty && stateAfter.pendingRestoreSections.isEmpty, "the sidebar filter or overlay stayed up")
    }

    // The quick REDO has the same cover as the click (review A3, lessons (b)): the redo raises the click generation and the pending count
    // in its own stretch, so a rebuild that stamps after the redo's reply and reads a table without the restore cannot push it over the
    // editor. After the release the editor holds the restored document, with the SAME ids as the first time (S9).
    @Test("The quick redo of a whole restore is covered against a stale rebuild, and brings the restored document back with its ids")
    func testQuickRedoOfWholeRestoreHasTheRebuildCover() async throws {
        let (rig, version) = try makeRigWithEditedBody()
        #expect(await rig.performRestore("project", from: version) == .performed)
        let plan = try #require(rig.controller.testLastRestorePlan)
        _ = await rig.waitUntilSettled()
        try await restorePress(rig, .undo)
        #expect(try rig.blocks().contains { $0.textContent == Self.editedBody }, "the undo did not bring the old document back")

        let hold = try rig.holdQueue()   // the redo's job pends behind it
        let entry = try #require(rig.unifiedUndo.redoStack.last)
        let redo = rig.startPress(entry, .redo)
        #expect(await gateWaitUntil({ rig.spyLog.items.contains("quickRedoJobReserved") }, iterations: 4000), "the redo's job was not reserved")
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // stamps AFTER the redo's reply and reads the old document
        let pushesFrom = rig.pushes.count
        #expect(await gateWaitUntil({ redo.done }, iterations: 4000), "the redo did not end")

        rig.release(hold)
        mayLand.open()
        _ = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
        let settled = await rig.waitUntilSettled()

        #expect(settled, "the redo never settled")
        #expect(rig.events.items.contains("rebuild push skipped"), "the guard did not skip the push of the rebuild that read after the redo")
        let screen = try #require(rig.editorText)
        #expect(Self.ownText(of: screen) == Self.ownText(of: plan.markdown), "the editor does not hold the restored document after the redo")
        #expect(!rig.pushes[pushesFrom...].contains { $0.markdown.contains(Self.editedBody) }, "the stale rebuild pushed the old document")
        #expect(Set(try rig.blocks().map(\.id)) == Set(plan.rows.map(\.id)), "the redo wrote other ids than the first restore")
        #expect(rig.replyWords().suffix(2) == ["undo performed", "redo performed"], "got \(rig.replyWords())")
    }

    // The other order of the same cover (fix round F4; break patch S2-18: the `editorFirstClickGeneration &+= 1` line of
    // `performQuickRedoOfRestore`). The test above starts its rebuild AFTER the redo's reply, where the pending-jobs half of the stamp
    // skips it and raises the owed re-push by itself, so it cannot tell whether the redo moved the click generation. Here the rebuild
    // read the table BEFORE the redo and lands after it: the restore generation alone skips its push, and only the click generation makes
    // the skip owe the editor a re-push of the database's Notes and Bibliography (a stamp that went stale only because a quick undo or
    // redo started raises nothing: the redo has taken the reinsert's settle, which would have pushed, away). Same shape as the Delete and
    // Duplicate redos' A3 (i). The four-section document has no Notes, so the rig's stand-in for the merge-guarded push hands back the
    // database's text and the re-push shows as a `preserveUserBlocks` push after the redo.
    // Predicted failure with the line removed: "the editor was never given the database's Notes and Bibliography after the skipped rebuild".
    @Test("A rebuild that read before the quick redo of a whole restore skips its push, and the editor is given the database's Notes afterwards")
    func testRebuildThatReadBeforeTheRestoreRedoSkipsItsPushAndTheRegionsAreRepushed() async throws {
        let (rig, version) = try makeRigWithEditedBody()
        #expect(await rig.performRestore("project", from: version) == .performed)
        let plan = try #require(rig.controller.testLastRestorePlan)
        _ = await rig.waitUntilSettled()
        try await restorePress(rig, .undo)
        #expect(try rig.blocks().contains { $0.textContent == Self.editedBody }, "the undo did not bring the old document back")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "precondition: nothing is pending when the rebuild reads")

        let hold = try rig.holdQueue()   // the redo's job pends behind it
        defer { rig.release(hold) }
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // reads the OLD document (the edited body), BEFORE the redo's stretch
        let redo = rig.startPress(try #require(rig.unifiedUndo.redoStack.last), .redo)
        #expect(await rig.awaitRuns([redo]), "the redo did not end")
        #expect(rig.editorState.pendingEditorFirstJobs == 1, "precondition: the redo's job is pending and holds the count")
        #expect(try rig.blocks().contains { $0.textContent == Self.editedBody }, "precondition: the table still has the old document")
        let pushesFrom = rig.pushes.count

        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
        #expect(landed, "the stand-in rebuild never landed")
        #expect(rig.events.items.contains("rebuild push skipped"), "the guard did not skip the push of the rebuild that read before the redo")
        #expect(rig.pushes.count == pushesFrom, "the stale rebuild pushed the old document while the redo's job was pending")
        #expect(
            rig.events.items.contains("rebuild content-equals-live=true"),
            "content lost the restored text to the stale rebuild (it was not put back to the editor's own text)")

        rig.release(hold)
        #expect(await rig.waitUntilSettled(), "the redo never settled")
        #expect(Set(try rig.blocks().map(\.id)) == Set(plan.rows.map(\.id)), "the redo's job did not write the restored rows")
        let screen = try #require(rig.editorText, "the editor holds no document")
        #expect(Self.ownText(of: screen) == Self.ownText(of: plan.markdown), "the editor does not hold the restored document after the redo")
        let pushes = Array(rig.pushes[pushesFrom...])
        #expect(!pushes.contains { $0.markdown.contains(Self.editedBody) }, "the old document was pushed into the editor after the redo")
        #expect(
            pushes.contains { $0.preserveUserBlocks },
            "the editor was never given the database's Notes and Bibliography after the skipped rebuild")
        #expect(Self.notesRegion(of: screen) == Self.notesRegion(of: try rig.assembledMarkdown()), "the editor's Notes are not the database's")
        #expect(!rig.editorState.managedRegionsNeedRepush, "the re-push owed to the editor was made")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count came back down")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
    }

    // S9: undo and redo step by step give the same ids, twice.
    @Test("S9: Cmd-Z and Cmd-Shift-Z of a whole restore, step by step, give the same ids every time")
    func testRestoreUndoRedoGivesTheSameIds() async throws {
        let (rig, version) = try makeRigWithEditedBody()
        let before = Set(try rig.blocks().map(\.id))
        #expect(await rig.performRestore("project", from: version) == .performed)
        let plan = try #require(rig.controller.testLastRestorePlan)
        let restored = Set(plan.rows.map(\.id))
        _ = await rig.waitUntilSettled()
        #expect(Set(try rig.blocks().map(\.id)) == restored)

        for _ in 0..<2 {
            try await restorePress(rig, .undo)
            #expect(Set(try rig.blocks().map(\.id)) == before, "the undo did not give back the rows it replaced")
            #expect(try rig.blocks().contains { $0.textContent == Self.editedBody })
            try await restorePress(rig, .redo)
            #expect(Set(try rig.blocks().map(\.id)) == restored, "the redo wrote other ids than the first restore")
            let texts = try rig.blocks().map(\.textContent)
            #expect(texts.contains("The C body.") && !texts.contains(Self.editedBody), "the redo did not restore the version")
        }
        let expected = ["undo performed", "redo performed", "undo performed", "redo performed"]
        #expect(rig.replyWords().suffix(4) == expected, "got \(rig.replyWords())")
        #expect(rig.scripts(containing: "performStructuralSwap").isEmpty, "a slow swap ran")
    }

    // What `SectionReinsertJob`'s carry-forward promises on undo: a sidebar-only edit (a status) made on a heading AFTER the restore stays
    // when the restore is undone, and the undo gives back the rest of the old document.
    @Test("A status set after a whole restore is kept by the quick undo of the restore")
    func testQuickUndoOfWholeRestoreKeepsAStatusSetAfterIt() async throws {
        let (rig, version) = try makeRigWithEditedBody()
        #expect(await rig.performRestore("project", from: version) == .performed)
        _ = await rig.waitUntilSettled()
        try setStatus(rig, ofBlock: try rig.heading("Section B").id, to: .final_)   // a sidebar-only edit made after the restore

        try await restorePress(rig, .undo)

        #expect(try rig.heading("Section B").status == .final_, "the quick undo reverted a status set after the restore")
        let texts = try rig.blocks().map(\.textContent)
        #expect(texts.contains(Self.editedBody) && !texts.contains("The C body."), "the undo did not give back the old document")
    }

    // MARK: - The sidebar

    // The restored outline is in the sidebar at once (before the database holds its rows) and leaves with the undo.
    @Test("The restored outline is in the sidebar at once, and leaves with the undo")
    func testRestoredOutlineAppearsInTheSidebarAtOnceAndLeavesWithTheUndo() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let version = try saveVersion(rig)
        try removeRows(rig, ofSectionTitled: "Section C")   // the document changed after the version: Section C is gone
        await rig.editorState.refreshSectionsAwaiting()
        #expect(!rig.editorState.sections.contains { $0.title == "Section C" }, "precondition: the sidebar still lists Section C")
        let restoredOutline = ["Chapter", "Section A", "Section B", "Section C"]

        let hold = try rig.holdQueue()   // the restore's job is reserved but cannot run: the database has no Section C yet
        #expect(await rig.performRestore("project", from: version) == .performed)
        #expect(try !rig.blocks().contains { $0.textContent == "Section C" }, "the job ran although the queue was held")
        #expect(rig.editorState.sections.map(\.title) == restoredOutline, "not the restored outline: \(rig.editorState.sections.map(\.title))")
        rig.release(hold)
        _ = await rig.waitUntilSettled()
        #expect(try rig.blocks().contains { $0.textContent == "Section C" }, "the job did not apply")
        #expect(rig.editorState.sections.map(\.title) == restoredOutline, "the outline changed when the rows arrived")
        #expect(rig.editorState.pendingRestoreSections.isEmpty, "the overlay that showed the restored outline was not lifted")
        #expect(rig.editorState.pendingRemovalIds.isEmpty, "the filter that hid the old outline was not lifted")

        try await restorePress(rig, .undo)
        await rig.editorState.refreshSectionsAwaiting()
        #expect(rig.editorState.sections.map(\.title) == ["Chapter", "Section A", "Section B"], "the old outline did not come back")
        #expect(rig.editorState.pendingRemovalIds.isEmpty, "the filter that hid the restored outline was not lifted")
    }
}
