//
//  LifecycleSyncSuspendTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C3b (slice-3a-1b-everyday.md section 4.2 step 0, reviews C6 and C23): the two
//  sync services are SUSPENDED while a close, switch or quit holds the editor.
//
//    - `suspendForLifecycle()` cancels the debounce, clears `pendingUpdate`, bumps `syncGeneration` (so an older
//      run's own generation check refuses its write) and makes `checkAndUpdate*` record the request and return
//    - `resumeAfterLifecycle()` clears that and re-runs ONE check for what was recorded, INCLUDING an update
//      that was pending at suspend (C23: a cancelled close must not drop a pending footnote update)
//    - `reset()` (the tails run it) un-suspends, so the next project's services are live again
//
//  Pure service tests: no sequence, no editor. `testHasPendingUpdate` is "a debounced update is scheduled".
//

import Foundation
import Testing
@testable import final_final

@Suite("Sync services suspended for a lifecycle — Tier 2 (t-94369a83 3a-1b C3b)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LifecycleSyncSuspendTests {

    private static let seed = "Body[^1] text.\n\n# Notes\n\n[^1]: First note.\n"

    // MARK: - Footnotes

    @Test("footnotes: suspend cancels the debounce and clears the pending update")
    func footnoteSuspend_cancelsTheDebounce() throws {
        let rig = try LifecycleFlushHarness(content: Self.seed)
        let service = rig.attachFootnoteService()
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: rig.pid, fullContent: Self.seed)
        #expect(service.testHasPendingUpdate, "precondition: an update is scheduled")

        service.suspendForLifecycle()

        #expect(!service.testHasPendingUpdate, "suspend must clear the pending snapshot")
        service.reset()
    }

    @Test("footnotes: a check made while suspended is recorded, not scheduled; resume runs it once")
    func footnoteCheckWhileSuspended_isRecordedAndRunOnResume() throws {
        let rig = try LifecycleFlushHarness(content: Self.seed)
        let service = rig.attachFootnoteService()
        service.suspendForLifecycle()

        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: rig.pid, fullContent: Self.seed)
        #expect(!service.testHasPendingUpdate, "while suspended nothing may be scheduled")

        service.resumeAfterLifecycle()

        #expect(service.testHasPendingUpdate, "resume must re-run the recorded check, which schedules the update")
        service.reset()
    }

    @Test("footnotes: resume with nothing recorded and nothing pending schedules nothing")
    func footnoteResumeWithNothingRecorded_schedulesNothing() throws {
        let rig = try LifecycleFlushHarness(content: Self.seed)
        let service = rig.attachFootnoteService()
        service.suspendForLifecycle()

        service.resumeAfterLifecycle()

        #expect(!service.testHasPendingUpdate)
        service.reset()
    }

    @Test("footnotes (C23): an update PENDING at suspend is not dropped: resume schedules it again")
    func footnotePendingAtSuspend_isReScheduledOnResume() throws {
        let rig = try LifecycleFlushHarness(content: Self.seed)
        let service = rig.attachFootnoteService()
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: rig.pid, fullContent: Self.seed)

        service.suspendForLifecycle()
        #expect(!service.testHasPendingUpdate)
        service.resumeAfterLifecycle()

        #expect(service.testHasPendingUpdate, "a cancelled close must not lose a footnote update that was pending")
        service.reset()
    }

    @Test("footnotes: suspend bumps the generation, so an OLDER run's write is refused and the database is untouched")
    func footnoteSuspend_refusesAnOlderRunsWrite() async throws {
        let rig = try LifecycleFlushHarness(content: Self.seed)
        let service = rig.attachFootnoteService()
        #expect(try rig.notesDefinitions().keys.sorted() == ["1"], "precondition: only [^1] has a definition")

        service.suspendForLifecycle()
        // A run scheduled before the suspend still carries generation 0.
        await service.performFootnoteUpdate(
            refs: ["1", "2"], projectId: rig.pid, fullContent: Self.seed, scheduledGeneration: 0)

        #expect(try rig.notesDefinitions().keys.sorted() == ["1"], "the older run must not have written a definition for [^2]")
        service.reset()
    }

    @Test("footnotes: reset (the tails run it) un-suspends the service")
    func footnoteReset_unsuspends() throws {
        let rig = try LifecycleFlushHarness(content: Self.seed)
        let service = rig.attachFootnoteService()
        service.suspendForLifecycle()
        service.reset()

        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: rig.pid, fullContent: Self.seed)

        #expect(service.testHasPendingUpdate, "after reset the next project's checks must schedule again")
        service.reset()
    }

    // MARK: - Bibliography

    @Test("bibliography: suspend cancels the debounce; a check while suspended is recorded and run on resume")
    func bibliographySuspendAndResume() throws {
        let rig = try LifecycleFlushHarness(content: Self.seed)
        let service = rig.attachBibliographyService()
        service.checkAndUpdateBibliography(currentCitekeys: ["smith2020"], projectId: rig.pid)
        #expect(service.testHasPendingUpdate, "precondition: an update is scheduled")

        service.suspendForLifecycle()
        #expect(!service.testHasPendingUpdate, "suspend must clear the pending snapshot")

        service.checkAndUpdateBibliography(currentCitekeys: ["jones2021"], projectId: rig.pid)
        #expect(!service.testHasPendingUpdate, "while suspended nothing may be scheduled")

        service.resumeAfterLifecycle()
        #expect(service.testHasPendingUpdate, "resume must re-run the recorded check")
        service.reset()
    }

    @Test("bibliography (C23): an update pending at suspend is re-scheduled by resume")
    func bibliographyPendingAtSuspend_isReScheduledOnResume() throws {
        let rig = try LifecycleFlushHarness(content: Self.seed)
        let service = rig.attachBibliographyService()
        service.checkAndUpdateBibliography(currentCitekeys: ["smith2020"], projectId: rig.pid)

        service.suspendForLifecycle()
        service.resumeAfterLifecycle()

        #expect(service.testHasPendingUpdate)
        service.reset()
    }

    @Test("bibliography: reset un-suspends the service")
    func bibliographyReset_unsuspends() throws {
        let rig = try LifecycleFlushHarness(content: Self.seed)
        let service = rig.attachBibliographyService()
        service.suspendForLifecycle()
        service.reset()

        service.checkAndUpdateBibliography(currentCitekeys: ["smith2020"], projectId: rig.pid)

        #expect(service.testHasPendingUpdate)
        service.reset()
    }
}
