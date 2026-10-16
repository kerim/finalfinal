//
//  QuickUndoRedoAndEligibilityTests.swift
//  final finalTests
//
//  This file: U-Q16 / U-Q17 family (quick redo), B2s (the resume order), U-Q10 (eligibility), U-Q24 and U-Q26-flush.
//  Tier 2 (t-94369a83 Phase 4b slice 2b; plan-v1 F2, plan-v2-addendum 6.2, plan-v3-addendum A1/D1/D2/D7, plan-v4-addendum 5): guards of
//  the quick undo and quick redo of an editor-first Delete Section, driven with `EditorFirstRig` (EditorFirstDeleteTests.swift). The
//  quick undo replies BEFORE its reinsert has applied, so every test that reads the database waits with
//  `EditorFirstRig.waitUntilSettled()` first. Every wait is bounded. Shared helpers: QuickUndoFixtures.swift.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Quick redo, eligibility and flush ordering (Phase 4b slice 2b, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct QuickUndoRedoAndEligibilityTests: QuickUndoFixtures {

    // MARK: - U-Q16, U-Q17, U-Q17b: redo

    @Test("U-Q16: undo, redo, undo after the delete renumbered the footnotes ends with the original labels, one definition each")
    func testQuickRedoAfterRenumberKeepsLabelsConsistent_article() async throws {
        let rig = try makeArticleRig()
        let before = try rig.assembledMarkdown()
        let deleted = try await delete(rig, Self.villageRegisters)
        let afterDelete = try rig.assembledMarkdown()

        let undo = await rig.pressAndSettle(deleted.entry)
        #expect(try rig.documentDiff(before) == nil, "the undo restored the document")
        let redo = await rig.pressAndSettle(deleted.entry, .redo)
        #expect(try rig.documentDiff(afterDelete) == nil, "the redo removed the section and renumbered exactly as the delete did")
        let undoAgain = await rig.pressAndSettle(deleted.entry)

        #expect(undo && redo && undoAgain)
        #expect(try rig.documentDiff(before) == nil, "the second undo restored it again: the labels are the original ones")
        let labels = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: try rig.assembledMarkdown())
        #expect(labels.references.count == 9 && labels.definitions.count == 9, "nine references, nine definitions: \(labels)")
        #expect(rig.replyWords() == ["undo performed", "redo performed", "undo performed"], "got \(rig.replyWords())")
    }

    // U-Q17: Cmd-Shift-Z straight after the quick undo (before its reinsert has settled) runs quick, the section ends up deleted, and the
    // undo's settle stands down
    @Test("U-Q17: Cmd-Shift-Z straight after the quick undo")
    func testRedoStraightAfterQuickUndoRunsQuick_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let afterDelete = try rig.assembledMarkdown()
        // The reinsert's body holds the writer's thread (for well under the editor's 5 s watchdog): the reinsert has NOT applied when the
        // redo is pressed (the slot is still `quickUndone`), and the undo's settle has not begun either.
        let reinsertMayRun = DispatchSemaphore(value: 0)
        defer { reinsertMayRun.signal() }
        rig.controller.testReinsertBodyHold = { reinsertMayRun.wait() }
        let pushesBefore = rig.pushes.filter(\.preserveUserBlocks).count

        let undo = rig.startPress(deleted.entry)
        let redo = rig.startPress(deleted.entry, .redo)
        let ended = await rig.awaitRuns([undo, redo])
        #expect(ended, "both presses ended")
        #expect(rig.controller.efSlots.slot(deleted.entry.id)?.state == .reserved, "the redo took the slot while the reinsert was still queued")
        reinsertMayRun.signal()
        let settled = await rig.waitUntilSettled()

        #expect(settled)
        #expect(rig.replyWords() == ["undo performed", "redo performed"], "expected the redo to run quick (performed), got \(rig.replyWords())")
        #expect(rig.quickRedoScripts.count == 1 && rig.scripts(containing: "performStructuralSwap").isEmpty)
        #expect(try rig.presentRowCount(deleted.subtree) == 0, "the section is deleted in the database at the end")
        #expect(try rig.documentDiff(afterDelete) == nil)
        #expect(
            rig.pushes.filter(\.preserveUserBlocks).count == pushesBefore,
            "expected the reinsert settle to skip its resync and push once the redo had moved the epoch")
    }

    // U-Q17b: a quick-undone entry whose slot fell back is never sent to the slow redo: the press fails with the notice and no text redo
    // is replayed
    @Test("U-Q17b: a quick-undone entry whose slot fell back is never sent to the slow redo")
    func testQuickUndoneEntryNeverReachesTheSlowRedo_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        #expect(await rig.pressAndSettle(deleted.entry))
        rig.controller.efSlots.markFallback(deleted.entry.id)

        #expect(await rig.pressAndSettle(deleted.entry, .redo))

        #expect(rig.replyWords() == ["undo performed", "redo failed"], "expected reply .failed with the notice, got \(rig.replyWords())")
        #expect(rig.toasts.current?.message == ToastFactory.undoQueueDropped().message, "the notice is shown")
        #expect(rig.quickRedoScripts.isEmpty)
    }

    // U-Q17d: a quick redo the editor refuses (the document changed) is answered failed with the notice, leaves the section on screen and
    // in the database, and keeps the entry on the redo stack
    @Test("U-Q17d: a quick redo the editor refuses")
    func testRefusedQuickRedoShowsNoticeAndChangesNothing_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        #expect(await rig.pressAndSettle(deleted.entry))
        let rowsBack = try rig.blocks()
        try rig.setReply(.init(succeeded: false, reason: "docChanged"), forRoot: deleted.root.id)

        #expect(await rig.pressAndSettle(deleted.entry, .redo))

        #expect(rig.replyWords() == ["undo performed", "redo failed"], "got \(rig.replyWords())")
        #expect(rig.toasts.current?.message == ToastFactory.undoQueueDropped().message, "the notice is shown")
        let changed = EditorFirstRig.parityProblem(try rig.blocks(), rowsBack)
        #expect(changed == nil, "the section stays in the database: \(changed ?? "")")
        #expect(rig.unifiedUndo.redoStack.last?.id == deleted.entry.id, "the entry stays on the redo stack")
        #expect(rig.editorState.pendingReinsertCount == 0)
    }

    @Test("U-Q17c: the redo's delete job registers under a key of its own, so its record stays unresolved while the job is queued")
    func testRedoJobHasItsOwnRegistryRecord_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        #expect(await rig.pressAndSettle(deleted.entry))
        let blocker = try rig.holdQueue()
        defer { rig.release(blocker) }

        let redo = rig.startPress(deleted.entry, .redo)
        let ended = await rig.awaitRuns([redo])

        #expect(ended)
        // The key the redo's job registered under: a fresh one of its own, or (the defect sw31 plants) the entry's own id, whose record
        // is the first delete job's and long resolved.
        let key = rig.controller.efLatestJobKey[deleted.entry.id] ?? deleted.entry.id
        let outcome = rig.editorState.efJobRegistry.record(for: key)?.outcome
        #expect(
            outcome == nil,
            "expected the redo's job future to stay unresolved until the redo's delete job ended (it was already resolved)")
        #expect(key != deleted.entry.id, "the redo's job has a key of its own")
        rig.release(blocker)
        _ = await rig.waitUntilSettled()
        #expect(try rig.presentRowCount(deleted.subtree) == 0)
    }

    @Test("B2s: the editor is resumed only after the reinsert holds its place in the queue, and before the press is answered")
    func testTheEditorIsResumedOnlyAfterTheReinsertHoldsItsPlace_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        rig.controller.testOrderingSpy = { [spyLog = rig.spyLog, events = rig.events] step in
            spyLog.note(step)
            events.note("spy " + step)
        }

        #expect(await rig.pressAndSettle(deleted.entry))

        let events = rig.events.items
        let restored = try #require(events.firstIndex { $0.contains("undoSectionDeleteEditorFirst") })
        let reserved = try #require(events.firstIndex(of: "spy quickUndoReinsertReserved"))
        let resumed = try #require(
            events.firstIndex { $0.contains("resumeSyncAfterQuickUndo") },
            "expected the rig to see resumeSyncAfterQuickUndo after the reinsert reserved")
        let performed = try #require(events.firstIndex(of: "spy quickUndoPerformed"))
        let order = "restore \(restored), reserved \(reserved), resume \(resumed), performed \(performed)"
        #expect(
            restored < reserved && reserved < resumed && resumed < performed,
            "expected quickUndoReinsertReserved before quickUndoResumed (the spy order): \(order)")
    }

    // MARK: - U-Q10: ineligible entries take the slow path

    @Test("U-Q10: a duplicate after the delete writes the table outside the queue: the delete's undo takes the slow path")
    func testIneligibleEntriesTakeTheSlowPath() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.editorTextAfterUndoSwap = try rig.assembledMarkdown()
        let sectionA = try rig.heading("Section A")
        let sectionC = try rig.heading("Section C")
        try rig.setReply(.init(removedLeaderIds: [sectionA.id]))
        let snapshots = SnapshotService(database: rig.db, projectId: rig.pid)
        defer { for snapshot in (try? snapshots.fetchAllSnapshots()) ?? [] { SnapshotService.unpinUndoPointSnapshot(snapshot.id) } }
        let deleteOutcome = await rig.controller.performSectionDelete(rootId: sectionA.id)
        #expect(deleteOutcome == .performed)
        let deleteEntry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(deleteEntry.id)
        try rig.syncEditorContentFromDatabase()
        let duplicateOutcome = await rig.controller.performSectionDuplicate(rootId: sectionC.id)
        #expect(duplicateOutcome == .performed)
        let duplicateEntry = try #require(rig.unifiedUndo.undoStack.last)

        await rig.controller.handleStructuralRequest(opId: duplicateEntry.id.uuidString, direction: .undo)
        await rig.controller.handleStructuralRequest(opId: deleteEntry.id.uuidString, direction: .undo)

        #expect(rig.quickUndoScripts.isEmpty, "expected the delete's undo to take the slow path after a duplicate, saw undoSectionDeleteEditorFirst")
        #expect(rig.replyWords() == ["undo performed", "undo performed"], "got \(rig.replyWords())")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "the slow undo brought the section back")
    }

    @Test("U-Q10: an entry whose slot fell back, and an undo forced slow, take the slow path; the quick path ran for none of them")
    func testFallbackSlotAndForcedSeamTakeTheSlowPath_book6() async throws {
        let fallback = try makeBookRig()
        fallback.editorTextAfterUndoSwap = try fallback.assembledMarkdown()
        let one = try await delete(fallback)
        fallback.controller.efSlots.markFallback(one.entry.id)
        #expect(await fallback.pressAndSettle(one.entry))
        #expect(
            fallback.quickUndoScripts.isEmpty && !fallback.scripts(containing: "performStructuralSwap").isEmpty,
            "a fallback slot takes the slow path")

        let forced = try makeBookRig()
        forced.editorTextAfterUndoSwap = try forced.assembledMarkdown()
        forced.controller.testForceSlowDeleteUndo = true
        let two = try await delete(forced)
        #expect(await forced.pressAndSettle(two.entry))
        #expect(
            forced.quickUndoScripts.isEmpty && !forced.scripts(containing: "performStructuralSwap").isEmpty,
            "the forced seam takes the slow path")
    }

    // MARK: - U-Q24 and U-Q26-flush: a backup, Save Version or export flush

    // U-Q24: after an idle backup's whole-document flush (fresh ids on most rows) the next Cmd-Z still takes the quick path, and the rows
    // end equal to the pre-delete document, ids included
    @Test("U-Q24: after an idle backup's whole-document flush")
    func testQuickUndoAfterLiveFlush_book6() async throws {
        let rig = try makeBookRig()
        let before = try rig.blocks()
        let deleted = try await delete(rig)
        await rig.editorState.flushLiveContentToDatabase { [weak rig] in rig?.editorState.content }
        let afterFlushIds = Set(try rig.blocks().map(\.id))
        let idsUnchangedByFlush = afterFlushIds == Set(before.map(\.id)).subtracting(deleted.subtree)
        #expect(!idsUnchangedByFlush, "precondition: the flush gave the surviving rows fresh ids")

        let everythingSettled = await rig.pressAndSettle(deleted.entry)

        #expect(everythingSettled)
        #expect(rig.scripts(containing: "performStructuralSwap").isEmpty && rig.quickUndoScripts.count == 1,
                "expected the quick path (undoSectionDeleteEditorFirst), saw performStructuralSwap")
        let after = try rig.blocks()
        #expect(try rig.idDifferenceCount(before) == 0, "the rows are the payload's: ids as before the delete")
        let contentProblem = EditorFirstRig.parityProblem(after, before)   // a short description of the first difference, never the rows
        #expect(contentProblem == nil, "and so is every row's content: \(contentProblem ?? "")")
    }

    // U-Q26-flush: a flush that is still running when Cmd-Z is pressed finishes first (the press is held, not refused), and the restore
    // comes after the flush's id push
    @Test("U-Q26-flush: a flush that is still running when Cmd-Z is pressed finishes first")
    func testFlushInFlightAndQuickUndoAreOrdered_book6() async throws {
        let rig = try makeBookRig()
        let before = try rig.blocks()
        let deleted = try await delete(rig)
        let fetchMayEnd = LifecycleEntryHarness.Gate()
        defer { fetchMayEnd.open() }
        let flush = Task { @MainActor in
            await rig.editorState.flushLiveContentToDatabase { [weak rig] in
                await fetchMayEnd.wait()
                return rig?.editorState.content
            }
            rig.events.note("flush done")
        }
        let running = await gateWaitUntil({ rig.editorState.liveFlushRunning > 0 })
        #expect(running, "the flush is running (its fetch is held)")

        let undo = rig.startPress(deleted.entry)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.quickUndoScripts.isEmpty, "the press waits for the flush: no restore yet")
        #expect(!undo.done)

        fetchMayEnd.open()
        await flush.value
        let ended = await rig.awaitRuns([undo])
        #expect(ended)
        _ = await rig.waitUntilSettled()

        let events = rig.events.items
        let idPush = try #require(events.firstIndex(of: "pushBlockIds"))
        let restore = try #require(events.firstIndex { $0.contains("undoSectionDeleteEditorFirst") })
        #expect(idPush < restore, "expected the restore after the flush's id push")
        #expect(try rig.idDifferenceCount(before) == 0, "the rows end equal to the payload: the flush's fresh ids are gone")
    }

    @Test("U-Q26-flush: a flush that starts after the restore was sent waits for the reinsert's settle: its whole-document write comes after it")
    func testFlushStartedAfterTheRestoreWaitsForTheReinsertSettle_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        rig.controller.testOrderingSpy = { [spyLog = rig.spyLog, events = rig.events] step in
            spyLog.note(step)
            events.note("spy " + step)
        }
        var flush: Task<Void, Never>?
        rig.controller.testQuickUndoAfterRestore = { [weak rig] in
            // The reinsert's unsettled marker is registered already: a flush that starts from here on must wait for it.
            flush = Task { @MainActor in
                await rig?.editorState.flushLiveContentToDatabase { rig?.quickEditorText }
                rig?.events.note("flush done")
            }
        }

        let everythingSettled = await rig.pressAndSettle(deleted.entry)
        await flush?.value

        #expect(everythingSettled)
        let events = rig.events.items
        let settled = try #require(events.firstIndex(of: "spy reinsertSettled"))
        let idPush = try #require(events.firstIndex(of: "pushBlockIds"))
        #expect(settled < idPush, "expected the flush's whole-document write after the reinsert's settle")
    }

    // U-Q24 redo: after a backup flush gave the rows fresh ids, the redo of the quick-undone delete stays quick, and the undo after it
    // restores exactly the rows the redo's job saw
    @Test("U-Q24 redo: after a backup flush gave the rows fresh ids")
    func testQuickRedoAfterLiveFlushStaysQuick_book6() async throws {
        let rig = try makeBookRig()
        let before = try rig.blocks()
        let deleted = try await delete(rig)
        #expect(await rig.pressAndSettle(deleted.entry))
        await rig.editorState.flushLiveContentToDatabase { [weak rig] in rig?.editorState.content }
        let rowsAfterFlush = try rig.blocks()
        #expect(try rig.idDifferenceCount(before) != 0, "precondition: the flush gave rows fresh ids")

        #expect(await rig.pressAndSettle(deleted.entry, .redo))
        let afterRedo = try rig.blocks()
        #expect(rig.quickRedoScripts.count == 1 && rig.scripts(containing: "performStructuralSwap").isEmpty, "the redo stayed on the quick path")
        #expect(!afterRedo.contains { $0.textContent == deleted.root.textContent }, "the redo took the section out again")
        #expect(afterRedo.count == rowsAfterFlush.count - deleted.subtree.count, "and nothing else")

        #expect(await rig.pressAndSettle(deleted.entry))
        let diff = EditorFirstRig.parityProblem(try rig.blocks(), rowsAfterFlush)
        #expect(diff == nil, "the last undo brought back the rows the redo's job saw: \(diff ?? "")")
        #expect(try rig.idDifferenceCount(rowsAfterFlush) == 0, "with the ids they had then")
        #expect(rig.replyWords() == ["undo performed", "redo performed", "undo performed"], "got \(rig.replyWords())")
        #expect(rig.quickUndoScripts.count == 2 && rig.scripts(containing: "performStructuralSwap").isEmpty)
    }

    // U-Q19 (S8): a Cmd-Z queued on the gate behind another structural command decides quick or slow INSIDE the gate, after that command
    // has run: here the command wrote the table outside the queue, so the undo goes slow
    @Test("U-Q19 (S8): a Cmd-Z queued on the gate behind another structural command decides quick or slow INSIDE")
    func testUndoQueuedBehindAnotherCommandDecidesInside() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.editorTextAfterUndoSwap = try rig.assembledMarkdown()
        let snapshots = SnapshotService(database: rig.db, projectId: rig.pid)
        defer { for snapshot in (try? snapshots.fetchAllSnapshots()) ?? [] { SnapshotService.unpinUndoPointSnapshot(snapshot.id) } }
        let deleted = try await delete(rig, "Section A")
        #expect(rig.controller.quickUndoEligible(deleted.entry), "precondition: at press time the entry is eligible for the quick path")

        // Another structural command holds the gate; before it ends it writes the table outside the queue (what a duplicate does).
        let commandMayEnd = LifecycleEntryHarness.Gate()
        defer { commandMayEnd.open() }
        let command = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "a duplicate", cancelled: false) {
                await commandMayEnd.wait()
                rig.editorState.structuralOutOfQueueGeneration &+= 1
                return true
            }
        }
        let busy = await gateWaitUntil { rig.editorState.structuralGate.isHeld }
        #expect(busy, "the other command holds the gate")
        let undo = rig.startPress(deleted.entry)
        let queued = await gateWaitUntil { rig.editorState.structuralGate.waiterCount == 1 }
        #expect(queued, "the undo waits on the gate behind it")

        commandMayEnd.open()
        _ = await command.value
        #expect(await rig.awaitRuns([undo]))
        _ = await rig.waitUntilSettled()

        #expect(rig.quickUndoScripts.isEmpty, "expected the slow path after a structural out-of-queue write, saw undoSectionDeleteEditorFirst")
        #expect(!rig.scripts(containing: "performStructuralSwap").isEmpty, "the slow undo ran")
        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "and the section is back")
    }
}
