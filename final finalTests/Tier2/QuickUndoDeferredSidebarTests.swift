//
//  QuickUndoDeferredSidebarTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2b; the VM measurement: the sidebar update after the restore is a main-thread stretch of 110-240 ms
//  that gates WebKit's next frame, so it now waits for the editor's next frame, at most 300 ms): the deferred sidebar update of the
//  quick undo, driven with `EditorFirstRig` (EditorFirstDeleteTests.swift). Shared helpers: QuickUndoFixtures.swift.
//
//  A unit rig has no web view, so the update would run at once. `StructuralUndoController.testNextPaintWait` (DEBUG) stands in for the
//  editor's frame: while a test sets it, the update waits for it, and the test holds it and releases it by hand (`holdNextFrame`).
//    - U-Q43 (sw70)  the update waits for the frame and runs after it
//    - U-Q44 (sw71)  the reinsert's settle waits for the update (and the reinsert's marker covers the window)
//    - U-Q45 (sw72)  a quick redo inside the window drops the update
//    - U-Q46 (sw74)  an update that finds the reinsert already resolved sets no overlay
//  The count term of the enforcement predicate (sw73) is in Tier1/SidebarRestoreOverlayTests.swift (U-Q41) and Tier2/
//  QuickUndoSidebarRestoreTests.swift (U-Q41c).
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Quick undo: the deferred sidebar update (Phase 4b slice 2b, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct QuickUndoDeferredSidebarTests: QuickUndoFixtures {

    /// The editor's next frame, held: the sidebar update of a quick undo started from now on waits until the test opens the gate.
    private func holdNextFrame(_ rig: EditorFirstRig) -> LifecycleEntryHarness.Gate {
        let frame = LifecycleEntryHarness.Gate()
        rig.controller.testNextPaintWait = { await frame.wait() }
        return frame
    }

    /// The reinsert's job has ended (the count is lowered when its future resolves) and the section's rows are back in the table.
    private func reinsertHasApplied(_ rig: EditorFirstRig, _ deleted: QuickUndoDeleted) -> Bool {
        rig.editorState.pendingReinsertCount == 0 && ((try? rig.presentRowCount([deleted.root.id])) ?? 0) == 1
    }

    private func isListed(_ rig: EditorFirstRig, _ deleted: QuickUndoDeleted) -> Bool {
        rig.editorState.sections.contains { $0.id == deleted.root.id }
    }

    @Test("U-Q43 (VM measurement): the sidebar update waits for the editor's next frame and runs after it")
    func testSidebarUpdateWaitsForTheEditorsNextFrameAndRunsAfterIt() async throws {
        let rig = try makeBookRig()
        let outlineBefore = try rig.db.fetchOutlineBlocks(projectId: rig.pid)
        let deleted = try await delete(rig)
        let frame = holdNextFrame(rig)
        defer { frame.open() }

        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))

        // The editor shows the restored section; its frame is not painted yet, and the sidebar has not been touched.
        let listed = isListed(rig, deleted)
        let overlay = rig.editorState.pendingRestoreSections[deleted.entry.id] != nil
        let waiting = rig.editorState.pendingSidebarRestoreCount
        #expect(
            !listed && !overlay && waiting == 1,
            "expected the section not in the sidebar while the next frame was held: listed \(listed), overlay \(overlay), waiting \(waiting)")
        #expect(rig.replyWords() == ["undo performed"], "the press does not wait for the update")

        frame.open()
        let ran = await gateWaitUntil({ rig.editorState.pendingSidebarRestoreCount == 0 })
        #expect(ran, "the update ends once the frame is released")
        #expect(isListed(rig, deleted), "expected the restored section in the sidebar once the frame was released")
        #expect(await rig.waitUntilSettled(iterations: 1500))
        await rig.editorState.refreshSectionsAwaiting()
        let problem = sidebarOrderProblem(rig, expected: outlineBefore)
        #expect(problem == nil, "the sidebar once everything settled: \(problem ?? "")")
    }

    @Test("U-Q44 (VM measurement): the reinsert's settle waits for the deferred sidebar update, and the reinsert's marker stays up meanwhile")
    func testReinsertSettleWaitsForTheDeferredSidebarUpdate() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let events = rig.events
        rig.controller.testOrderingSpy = { [weak rig, events] step in
            events.note("spy " + step)
            guard step == "reinsertSettled", let rig else { return }
            let listed = rig.editorState.sections.contains { $0.id == deleted.root.id }
            events.note(listed ? "listed at settle" : "not listed at settle")
        }
        let frame = holdNextFrame(rig)
        defer { frame.open() }

        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        let applied = await gateWaitUntil({ reinsertHasApplied(rig, deleted) })
        #expect(applied, "precondition: the reinsert has put the rows back")

        let settledEarly = await gateWaitUntil({ events.items.contains("spy reinsertSettled") }, iterations: 60)
        let markerUp = rig.editorState.efJobRegistry.hasUnsettledWork
        #expect(
            !settledEarly && markerUp,
            "expected reinsertSettled only after the sidebar update: settled while the update waited \(settledEarly), marker up \(markerUp)")

        frame.open()
        #expect(await rig.waitUntilSettled(iterations: 1500))
        #expect(events.items.contains("listed at settle"), "the update comes first, then the settle: \(events.items.suffix(4))")
        #expect(!events.items.contains("not listed at settle"), "the settle did not run before the update")
        #expect(rig.editorState.pendingRestoreSections[deleted.entry.id] == nil, "no overlay entry is left")
    }

    @Test("U-Q45 (VM measurement): a quick redo inside the paint window drops the sidebar update")
    func testQuickRedoInsideThePaintWindowDropsTheSidebarUpdate() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let blocker = try rig.holdQueue()   // the reinsert and the redo's delete job wait: the removal ids of the redo stay set
        defer { rig.release(blocker) }
        let frame = holdNextFrame(rig)
        defer { frame.open() }

        let undo = rig.startPress(deleted.entry)
        let redo = rig.startPress(deleted.entry, .redo)
        #expect(await rig.awaitRuns([undo, redo]), "both presses ended")
        #expect(rig.editorState.pendingRemovalIds.contains(deleted.root.id), "precondition: the redo removed the section again")

        frame.open()
        let ended = await gateWaitUntil({ rig.editorState.pendingSidebarRestoreCount == 0 })
        #expect(ended, "the update ends once the frame is released")
        let listed = isListed(rig, deleted)
        let stillRemoved = rig.editorState.pendingRemovalIds.contains(deleted.root.id)
        #expect(
            !listed && stillRemoved,
            "expected the deferred update dropped after the quick redo moved the epoch: listed \(listed), still removed \(stillRemoved)")
        rig.release(blocker)
        #expect(await rig.waitUntilSettled(iterations: 1500))
        #expect(rig.replyWords() == ["undo performed", "redo performed"], "got \(rig.replyWords())")
    }

    @Test("U-Q46 (VM measurement): an update that finds the reinsert already resolved sets no overlay entry")
    func testDeferredSidebarUpdateAfterTheReinsertResolvedLeavesNoOverlay() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let settleMayRun = LifecycleEntryHarness.Gate()   // the settle (which would clear an overlay entry) starts only when told
        defer { settleMayRun.open() }
        rig.controller.testReinsertSettleHold = { await settleMayRun.wait() }
        let frame = holdNextFrame(rig)
        defer { frame.open() }

        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        let applied = await gateWaitUntil({ reinsertHasApplied(rig, deleted) })
        #expect(applied, "precondition: the reinsert has put the rows back before the frame is released")

        frame.open()
        let ran = await gateWaitUntil({ rig.editorState.pendingSidebarRestoreCount == 0 })
        #expect(ran, "the update ends once the frame is released")
        let overlay = rig.editorState.pendingRestoreSections[deleted.entry.id] != nil
        #expect(!overlay, "expected no overlay entry once the reinsert had resolved, got one nobody would clear")
        #expect(isListed(rig, deleted), "the section is in the sidebar")

        settleMayRun.open()
        #expect(await rig.waitUntilSettled(iterations: 1500))
    }
}
