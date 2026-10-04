//
//  LifecycleCloseTailTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C5b (slice-3a-1b-everyday.md sections 4.4 and 7.2 "C5b"): the CLOSE tail
//  (`ContentView.runCloseTail`), driven directly on a bare `ContentView` wired to a temporary project database
//  (`LifecycleTailRig`).
//
//    - #7 / N30: a close leaves an automatic-version ROW in the real database (`snapshot` table, not a stub's
//      call count), made BEFORE `autoBackupService.reset()` (a reset first would nil the backup's database and turn
//      the close backup into a silent no-op); the service IS reset afterwards
//    - N1: the backup is skipped only when the TOKEN says Getting Started was open (captured at arm), and
//      `lifecycleBackupDoneFor` is recorded only when a backup was attempted
//    - P6: the writer is RETIRED and the barrier RELEASED in that order: a system write parked above the held
//      barrier resumes `.skipped`, never `.go`; `barriersCancelled == 0`; no handle is left behind
//    - a joined quit takes over: the tail makes the backup and the resets, then stands down BEFORE retire, reset
//      and `onProjectClosed`, leaving the barrier held
//    - `onProjectClosed` runs for a close and not for E9
//    - N7: no project is open in `DocumentManager.shared` anywhere in these tests, and the tail still works,
//      because it takes everything from the services and editor state it captured
//
//  Item 32: tests that use `LifecycleEntry` assert the `.armed` event; these call the tail directly, so they
//  arm a token on the editor state themselves (`rig.arm`) and read `activeLifecycle` where it matters.
//

import Foundation
import Testing
@testable import final_final

extension LifecycleEntryStatic {
    @Suite("LifecycleEntry close tail — Tier 2 (t-94369a83 3a-1b C5b)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct LifecycleCloseTailTests {

        // MARK: - #7 and N30: the automatic version

        @Test("""
            #7 / N30: a close tail leaves an automatic-version ROW in the real database, made before \
            autoBackupService.reset(); the backup service IS reset afterwards
            """)
        func closeTailLeavesASnapshotRowAndResetsTheServiceAfterwards() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()   // typing since the last version: what makes a backup due
            let token = rig.arm(.close)

            await rig.view.runCloseTail(token: token, callOnProjectClosed: false)

            #expect(
                try rig.snapshotCount() == before + 1,
                "the close backup must have run BEFORE the reset (a reset first leaves no row at all)")
            #expect(rig.backup.hasUnsavedChanges == false)
            // The reset ran after the backup: the service no longer has a database, so even a forced backup of
            // DIFFERENT content makes no row.
            let changed = BlockParser.parse(markdown: "# Alpha\n\nchanged after the tail.\n", projectId: rig.pid)
            try rig.db.replaceBlocks(changed, for: rig.pid)
            await rig.backup.createAutoBackup(reason: "after the tail")
            #expect(try rig.snapshotCount() == before + 1, "autoBackupService.reset() must have run (it nils the database)")
        }

        @Test("a close tail never reads DocumentManager for the closing project (N7): the row is made from the captured services")
        func closeTailNeedsNoDocumentManagerProject() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            let token = rig.arm(.close)

            // After `perform` on a close, `DocumentManager.projectDatabase` is nil. The rig never opens a project in
            // `DocumentManager.shared`; the tail must work from what it captured. The precondition makes that explicit:
            // were a project open there, the row could come from `dm` and this test would pass for the wrong reason.
            #expect(DocumentManager.shared.projectDatabase == nil, "precondition: DocumentManager has no project open")
            await rig.view.runCloseTail(token: token, callOnProjectClosed: false)

            #expect(try rig.snapshotCount() == before + 1)
            #expect(rig.editorState.content.isEmpty, "resetForProjectSwitch ran")
        }

        // MARK: - N1

        @Test("N1: the close backup is skipped ONLY when the token says Getting Started was open (captured at arm)")
        func backupIsSkippedOnlyForGettingStarted() async throws {
            let gettingStarted = try LifecycleTailRig()
            let regular = try LifecycleTailRig()
            defer { gettingStarted.shutdown(); regular.shutdown() }
            let gsBefore = try gettingStarted.snapshotCount()
            let regularBefore = try regular.snapshotCount()
            gettingStarted.backup.contentDidChange()
            regular.backup.contentDidChange()
            let gsToken = gettingStarted.arm(.close, wasGettingStarted: true)
            let regularToken = regular.arm(.close, wasGettingStarted: false)

            await gettingStarted.view.runCloseTail(token: gsToken, callOnProjectClosed: false)
            await regular.view.runCloseTail(token: regularToken, callOnProjectClosed: false)

            #expect(try gettingStarted.snapshotCount() == gsBefore, "Getting Started is an ephemeral playground: no version")
            #expect(try regular.snapshotCount() == regularBefore + 1, "E9 backs up the project it replaces")
            #expect(gettingStarted.editorState.lifecycleBackupDoneFor == nil, "no backup was attempted")
            #expect(regular.editorState.lifecycleBackupDoneFor == regularToken.id, "a quit that joins must not back up twice")
        }

        // MARK: - What the tail resets and calls

        @Test("onProjectClosed runs for a close and NOT for E9 (callOnProjectClosed == false)")
        func onProjectClosedRunsOnlyWhenAsked() async throws {
            let closing = try LifecycleTailRig()
            let swapping = try LifecycleTailRig()
            defer { closing.shutdown(); swapping.shutdown() }
            var closedCalls = 0
            var swapCalls = 0
            closing.view.onProjectClosed = { closedCalls += 1 }
            swapping.view.onProjectClosed = { swapCalls += 1 }

            await closing.view.runCloseTail(token: closing.arm(.close), callOnProjectClosed: true)
            await swapping.view.runCloseTail(token: swapping.arm(.close), callOnProjectClosed: false)

            #expect(closedCalls == 1)
            #expect(swapCalls == 0, "E9 posts nothing back to the picker: the app's own view swap follows")
        }

        // MARK: - P6

        @Test("""
            P6: the close tail RETIRES the writer and RELEASES the barrier in that order -- a system write parked above \
            the held barrier resumes .skipped (never .go and applied), barriersCancelled == 0, no handle is left
            """)
        func closeTailRetiresThenReleases() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            let token = rig.arm(.close)
            let handle = try #require(await rig.holdBarrier())
            #expect(rig.writer?.testOpenBarrierSeq == handle.seq, "precondition: the barrier is held on the writer")
            let parked = await rig.parkSystemWrite()
            #expect(rig.editorState.systemWriteInFlight == 1, "precondition: the write is parked above the held barrier")

            await rig.view.runCloseTail(token: token, callOnProjectClosed: false)

            let result = await parked.value
            guard case .refused(.skipped(let reason)) = result.outcome else {
                Issue.record("the parked write must resume .skipped, never .go; got \(result.outcome)")
                return
            }
            #expect(reason == .close)
            #expect(rig.writer?.ledger.barriersCancelled == 0, "a barrier released by retire is a release, never a cancel")
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(rig.writer?.testOpenBarrierSeq == nil)
            #expect(rig.writer?.enqueueBarrier() == nil, "the writer is retired: it grants no further barrier")
            #expect(rig.editorState.systemWriteInFlight == 0, "the parked write returned (N10)")
        }

        @Test("retireForLifecycle on its own: retire first, then release; the handle is dropped; reason is carried")
        func retireForLifecycleOnItsOwn() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            _ = rig.arm(.projectSwitch)
            _ = try #require(await rig.holdBarrier())
            let parked = await rig.parkSystemWrite()

            rig.editorState.retireForLifecycle(reason: .projectSwitch)

            #expect(rig.editorState.lifecycleBarrier == nil, "dropped in the same synchronous block")
            guard case .refused(.skipped(let reason)) = await parked.value.outcome else {
                Issue.record("the parked write must resume .skipped")
                return
            }
            #expect(reason == .projectSwitch)
            #expect(rig.writer?.ledger.barriersCancelled == 0)
            // Idempotent: nothing to release the second time.
            rig.editorState.retireForLifecycle(reason: .projectSwitch)
            #expect(rig.editorState.lifecycleBarrier == nil)
        }

        // MARK: - A joined quit

        @Test("""
            a quit that JOINED during the close: the tail still makes the automatic version and the resets, then stands \
            down BEFORE retire, reset and onProjectClosed, leaving the barrier held (the quit holds it to exit)
            """)
        func joinedQuitStandsTheTailDown() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            var closedCalls = 0
            rig.view.onProjectClosed = { closedCalls += 1 }
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            let closeToken = rig.arm(.close)
            let handle = try #require(await rig.holdBarrier())
            guard case .joined = rig.editorState.armLifecycle(.quit, wasGettingStarted: false) else {
                Issue.record("the quit must join the close")
                return
            }

            await rig.view.runCloseTail(token: closeToken, callOnProjectClosed: true)

            #expect(try rig.snapshotCount() == before + 1, "the close's own automatic version was made before the check")
            #expect(rig.editorState.lifecycleBarrier != nil, "the joined quit holds the barrier: nothing here may release it")
            #expect(rig.writer?.testOpenBarrierSeq == handle.seq)
            #expect(rig.editorState.content == LifecycleTailRig.seed, "resetForProjectSwitch did not run")
            #expect(closedCalls == 0, "onProjectClosed did not run")
            #expect(rig.editorState.activeLifecycle?.kind == .quit)
        }
    }
}
