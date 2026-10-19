//
//  EditorFirstRestoreTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 2, round 2d-i; plan-v3 tests U-S2-3, U-S2-6, U-S2-7, U-S2-8): Version History "Restore this version"
//  of the WHOLE project, editor first: the click and what happens to the typing around it. Driven with `EditorFirstRig`
//  (EditorFirstDeleteTests.swift); the restore's answers are in EditorFirstRig+Restore.swift, the helpers in
//  EditorFirstRestoreFixtures.swift. The rebuild guard, the quick undo and redo and the sidebar are EditorFirstRestoreUndoTests.swift.
//  The two section restores (replace, restore as duplicate) and their tests (U-S2-1, 2, 4, 5, 5d) are round 2d-ii's.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Editor-first version restore (t-18b7fa48 slice 2, round 2d-i, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstRestoreTests: QuickUndoFixtures {

    @Test("A whole restore is editor-first: one editor call, no old sequence, no whole-document push, and the database follows the plan")
    func testWholeRestoreIsEditorFirstAndTheDatabaseFollows() async throws {
        let (rig, version) = try makeRigWithEditedBody()
        let snapshots = SnapshotService(database: rig.db, projectId: rig.pid)
        defer { for snapshot in (try? snapshots.fetchAllSnapshots()) ?? [] { SnapshotService.unpinUndoPointSnapshot(snapshot.id) } }

        #expect(await rig.performRestore("project", from: version) == .performed)

        #expect(rig.scripts(containing: "replaceRangeEditorFirst").count == 1, "the editor was not asked exactly once")
        #expect(rig.scripts(containing: "beginStructuralOp").isEmpty, "the old whole sequence ran")
        #expect(rig.pushes.filter { !$0.preserveUserBlocks }.isEmpty, "the restore pushed the whole document into the editor")
        let entry = try #require(rig.unifiedUndo.undoStack.last, "the restore was not recorded")
        #expect(entry.kind == .restoreProject && entry.isEditorFirst && entry.undoSnapshotId == nil, "got \(entry)")
        let plan = try #require(rig.controller.testLastRestorePlan)
        #expect(plan.mode == .whole)

        await rig.settle(entry.id)
        let texts = try rig.blocks().map(\.textContent)
        #expect(texts.contains("The C body.") && !texts.contains(Self.editedBody), "the version was not restored: \(texts)")
        #expect(Set(try rig.blocks().map(\.id)) == Set(plan.rows.map(\.id)), "the table does not hold exactly the plan's rows")
        #expect(
            try rig.db.fetchContent(for: rig.pid)?.markdown == version.previewMarkdown,
            "content.markdown is not the version's Markdown")
        let slot = try #require(rig.controller.efSlots.slot(entry.id))
        let pinned = slot.snapshotId.map { SnapshotService.isUndoPointSnapshotPinned($0) }
        #expect(pinned == true, "the undo copy the job wrote is not pinned")
        #expect(rig.persistedLog.allSatisfy { !$0.contains("[EF-STRUCT]") }, "a fallback was logged: \(rig.persistedLog)")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
        #expect(rig.editorState.pendingEditorFirstJobs == 0 && rig.editorState.pendingRemovalIds.isEmpty)
        #expect(rig.editorState.pendingRestoreSections.isEmpty, "the sidebar overlay was not lifted")
    }

    // U-S2-3 (item 2): typing reserved after the click and applied after the job is KEPT in the database; the job moves no epoch, and no
    // batch is refused for a stale one.
    @Test("U-S2-3: typing made after a whole restore is not dropped for a stale epoch")
    func testTypingAfterWholeRestoreIsNotDroppedForStaleEpoch() async throws {
        let (rig, version) = try makeRigWithEditedBody()
        let hold = try rig.holdQueue()
        let epochBefore = try rig.projectWriteEpoch()
        let rejectionsBefore = rig.sync.testWriterLedger.debugRichTextStaleEpochRejections
        let systemWritesBefore = rig.sync.testWriterLedger.systemWritesApplied

        #expect(await rig.performRestore("project", from: version) == .performed)
        let plan = try #require(rig.controller.testLastRestorePlan)
        let payloadId = try #require(plan.rows.first { $0.textContent == "The A body." }?.id)   // the id the editor now holds
        rig.typingQueue.append(typing(id: payloadId, to: "The A body typed."))
        let poll = rig.startPoll()
        rig.release(hold)
        #expect(await rig.awaitRuns([poll]))
        _ = await rig.waitUntilSettled()

        let kept = try rig.blocks().contains { $0.id == payloadId && $0.textContent == "The A body typed." }
        #expect(kept, "typing after the restore was dropped")
        #expect(try rig.blocks().contains { $0.textContent == "The C body." }, "the restore did not apply")
        #expect(try rig.projectWriteEpoch() == epochBefore, "the restore job bumped the write epoch")
        // Not vacuous (fix round F1, review C9d): `testWriterLedger` is a fresh all-zero ledger when the service has no writer, so
        // "no rejection" proves nothing unless the ledger read is the rig's real writer's, which counted the restore job.
        _ = try #require(rig.sync.testWriterHandle, "the rig has no writer: the ledger read below would be an empty one")
        #expect(
            rig.sync.testWriterLedger.systemWritesApplied > systemWritesBefore,
            "the ledger does not show the restore job: it is not the rig's writer's")
        #expect(
            rig.sync.testWriterLedger.debugRichTextStaleEpochRejections == rejectionsBefore,
            "a batch was rejected for a stale epoch")
    }

    // U-S2-6 (#6, D7): the editor refuses the click; the batch is applied, the old restore runs in the same gate turn, the fall back is
    // logged with this rig's project id, and the press is `.performed` (the window shows nothing).
    @Test("U-S2-6: an editor refusal falls back to the old restore, which restores, with the fallback logged")
    func testEditorRefusalFallsBackToLegacy() async throws {
        let (rig, version) = try makeRigWithEditedBody()
        let snapshots = SnapshotService(database: rig.db, projectId: rig.pid)
        defer { for snapshot in (try? snapshots.fetchAllSnapshots()) ?? [] { SnapshotService.unpinUndoPointSnapshot(snapshot.id) } }
        rig.forceEditorRefusal = true

        #expect(await rig.performRestore("project", from: version) == .performed)
        _ = await rig.waitUntilSettled()

        let fellBack = rig.persistedLog.contains {
            $0.contains("[EF-STRUCT] restoreProject fell back to the old path: idAlignment")
        }
        #expect(fellBack, "no fallback line in this rig's log: \(rig.persistedLog)")
        #expect(!rig.scripts(containing: "beginStructuralOp").isEmpty, "the old sequence did not run")
        let texts = try rig.blocks().map(\.textContent)
        #expect(texts.contains("The C body.") && !texts.contains(Self.editedBody), "the old restore did not restore the version: \(texts)")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
        let entry = try #require(rig.unifiedUndo.undoStack.last, "the restore was not recorded")
        #expect(entry.kind == .restoreProject && !entry.isEditorFirst, "the entry must be the old path's (it carries an undo snapshot)")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count stayed up after the fall back")
        #expect(rig.editorState.efJobRegistry.outstandingCount == 0, "no job may be queued for a press the old sequence carried out")
    }

    // U-S2-7 (item 9, C4), in the shape of slice 1's U-S1-7 after its review (T1): a restore whose job fails (a database fault in its own
    // insert, so the database is exactly as it was) puts the document back from the database. What the EDITOR holds after the put-back is
    // checked, not only the database:
    //   - the typing up to the click (the click's batch) was applied before the job, so the put-back's push carries it;
    //   - keystrokes made while the put-back's push is in flight stay on the screen because that push asks for `detectPausedEdits`;
    //   - typing made after the click into a block whose id the restored text and the old text share (a heading kept by title) reaches
    //     the database;
    //   - the restored text is gone from the editor, the table and the sidebar.
    @Test("U-S2-7: a failed restore job puts the document back and keeps the typing")
    func testFailedRestorePutBackKeepsTyping() async throws {
        let (rig, version) = try makeRigWithEditedBody()
        rig.modelsWholePushOnEditor = true
        let aBody = try #require(try rig.blocks().first { $0.textContent == "The A body." })
        let bBody = try #require(try rig.blocks().first { $0.textContent == "The B body." })
        let sectionC = try rig.heading("Section C")
        rig.replaceClickBatch = typing(aBody, to: "The A body typed.")
        rig.typedDuringNextWholePush = (bBody, " LATER")
        rig.forceNextJobFailure = true

        #expect(await rig.performRestore("project", from: version) == .performed)
        rig.queueTyping(sectionC, appending: " later")
        await settleThenCarryRestoreTyping(rig)

        let screen = try #require(rig.editorText, "the editor holds no document")
        #expect(screen.contains("The A body typed."), "the put-back removed the typing up to the click from the editor: \(screen)")
        #expect(screen.contains("The B body. LATER"), "the put-back removed the typing made during its push from the editor: \(screen)")
        #expect(screen.contains(Self.editedBody), "the editor does not show the document as it was before the restore: \(screen)")
        #expect(!screen.contains("The C body."), "the restored text is still in the editor: \(screen)")
        let wholePushes = rig.pushes.filter { !$0.preserveUserBlocks }
        #expect(
            wholePushes.contains { $0.markdown.contains("The A body typed.") && $0.markdown.contains(Self.editedBody) },
            "no whole-document put-back push with the click's typing in it and the old text, got \(wholePushes.count) push(es)")
        #expect(wholePushes.contains { $0.detectPausedEdits }, "the put-back's push did not ask for detectPausedEdits")

        let texts = try rig.blocks().map(\.textContent)
        #expect(texts.contains("The A body typed."), "put-back lost the typing up to the click: \(texts)")
        #expect(texts.contains("The B body. LATER"), "put-back lost the typing made during its push: \(texts)")
        #expect(texts.contains("Section C later"), "put-back lost the typing made after the click: \(texts)")
        #expect(texts.contains(Self.editedBody) && !texts.contains("The C body."), "the table is not the old document: \(texts)")
        await rig.editorState.refreshSectionsAwaiting()
        #expect(rig.editorState.sections.map(\.title).contains("Section C later"), "the sidebar does not show the old document")
        #expect(rig.editorState.pendingRestoreSections.isEmpty, "the overlay that showed the restored outline was not lifted")
        #expect(rig.editorState.pendingRemovalIds.isEmpty, "the filter that hid the old outline was not lifted")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "the put-back removes the entry")
        #expect(rig.alerts.map(\.title) == ["Couldn't Restore Version"], "expected exactly one alert, got \(rig.alerts)")
        #expect(rig.alerts.first?.message == Self.failedRestoreMessage, "got \(String(describing: rig.alerts.first?.message))")
    }

    // The other half of the alert's last sentence (floor item 5): what was typed into the RESTORED text before the job failed is typed
    // into blocks the database never got, so the put-back removes it, and the alert says so.
    @Test("U-S2-7b: typing into the restored text is removed with it when the restore fails, and the alert says so")
    func testTypingIntoTheRestoredTextIsRemovedWithItWhenTheRestoreFails() async throws {
        let (rig, version) = try makeRigWithEditedBody()
        rig.modelsWholePushOnEditor = true
        let jobMayRun = DispatchSemaphore(value: 0)
        defer { jobMayRun.signal() }
        rig.controller.testEFJobBodyHold = { jobMayRun.wait() }   // the restored text is on the screen and its job has not run
        rig.forceNextJobFailure = true

        #expect(await rig.performRestore("project", from: version) == .performed)
        let plan = try #require(rig.controller.testLastRestorePlan)
        let restoredBody = try #require(plan.rows.first { $0.textContent == "The A body." })
        let typed = "The A body typed in the restored text."
        let screenBefore = try #require(rig.editorText)
        let range = try #require(screenBefore.range(of: "The A body."), "the restored text is not on the screen")
        rig.editorText = screenBefore.replacingCharacters(in: range, with: typed)
        rig.typingQueue.append(typing(restoredBody, to: typed))
        let poll = rig.startPoll()
        #expect(await gateWaitUntil({ rig.typingQueue.isEmpty }), "the poll did not fetch the typing")
        jobMayRun.signal()
        #expect(await rig.awaitRuns([poll]))
        _ = await rig.waitUntilSettled()

        let screen = try #require(rig.editorText)
        #expect(!screen.contains(typed), "the typing in the restored text is still in the editor after the put-back: \(screen)")
        #expect(screen.contains(Self.editedBody), "the editor does not show the document as it was before the restore: \(screen)")
        let texts = try rig.blocks().map(\.textContent)
        #expect(!texts.contains { $0.contains(typed) }, "typing into the restored text reached a table that has no such row: \(texts)")
        #expect(texts.contains("The A body."), "the old document is not intact: \(texts)")
        #expect(rig.alerts.map(\.title) == ["Couldn't Restore Version"], "expected exactly one alert, got \(rig.alerts)")
        let sentence = "Anything you typed into the restored text was removed with it."
        #expect(
            rig.alerts.first?.message.contains(sentence) == true,
            "the alert does not say that typing into the restored text was removed: \(String(describing: rig.alerts.first?.message))")
    }

    // U-S2-8 (item 9, C4): a forced job failure returns `.performed` (the window keys its own "Restore failed" line on `.refused`) and
    // raises exactly one alert.
    @Test("U-S2-8: a failed restore job returns .performed and raises exactly one alert, and the window's own line never shows")
    func testFailedRestoreReturnsPerformedAndOneAlert() async throws {
        let (rig, version) = try makeRigWithEditedBody()
        rig.forceNextJobFailure = true

        let outcome = await rig.performRestore("project", from: version)
        _ = await rig.waitUntilSettled()

        #expect(outcome == .performed, "the window would show 'Restore failed' beside the modal: \(outcome)")
        let shown = rig.controller.testShownAlerts
        #expect(shown == ["Couldn't Restore Version"], "expected exactly one alert, got \(shown)")
        #expect(rig.alerts.map(\.title) == ["Couldn't Restore Version"], "got \(rig.alerts)")
        #expect(rig.alerts.first?.message == Self.failedRestoreMessage, "got \(String(describing: rig.alerts.first?.message))")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "the failed restore is still on the timeline")
        #expect(rig.editorState.pendingEditorFirstJobs == 0)
    }
}
