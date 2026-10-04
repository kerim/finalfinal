//
//  LifecycleAbortTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C5a (slice-3a-1b-everyday.md sections 4.3 and 7.2 "C5a"): the ONE abort routine
//  every exit that does not reach a tail goes through (a section operation that never cleared, a writer that
//  refused the barrier, a `perform` that threw), driven through `LifecycleEntry.run`.
//
//    - item 13 / N14: after FB, a `perform` throw re-pushes block ids BEFORE polling restarts, clears the token,
//      and leaves no barrier open; `isResettingContent` is cleared only after the re-push
//    - must-fix #3 / N23: a section-operation cancel (before FB) still restarts polling (the real timer is armed),
//      and a LATER EDIT REACHES THE DATABASE through a poll cycle driven as the timer's tick would (a real timer is
//      not waited on: it does not reliably fire while the test host sits in a `Task.sleep` loop, see
//      `QuitFlushDuplicateInsertTests`)
//    - a refused barrier (FB still queued behind a foreign one) waits for FB only within the abort's bound, then
//      restarts polling and shows the busy notice
//    - review row C8: a push that never returns cannot hold the abort past its bound, wedge the token, or stop a
//      second close being accepted
//    - #18: a quit that JOINED the lifecycle keeps its token and its barrier: neither the abort (stand-down) nor
//      the run's own `finish` releases them
//
//  Every assertion that the routine did something is paired with a positive proof that the guard path ran (the
//  `.armed` entry event, item 32). Recorded state is read INSIDE the harness `withEntry` block or after it from
//  the harness's own copies (the harness resets the entry's global state on the way out).
//
//  Harness: `LifecycleFlushHarness` (Helpers/). The suite nests under `LifecycleEntryStatic`, the serialized
//  parent of every suite that touches `LifecycleEntry`'s process-global state.
//

import Foundation
import Testing
@testable import final_final

private struct AbortBoom: Error, Equatable {}

extension LifecycleEntryStatic {
    @Suite("LifecycleEntry abort routine — Tier 2 (t-94369a83 3a-1b C5a)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct LifecycleAbortTests {

        private static let fresh = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"

        private func prime(_ rig: LifecycleFlushHarness) {
            rig.js.answer("flushPendingBlockChanges", true)
            rig.js.answer("hasBlockChanges", false)
            rig.fetchAnswer = Self.fresh
        }

        /// Polls `condition` every 50ms until it holds or `seconds` pass. Real-clock, bounded.
        private func waitUntil(seconds: Double, _ condition: () throws -> Bool) async rethrows -> Bool {
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: .seconds(seconds))
            while clock.now < end {
                if try condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return try condition()
        }

        // MARK: - Item 13: a post-FB throw re-pushes ids before polling restarts

        @Test("""
            item 13 / N14: a perform that throws AFTER FB re-pushes block ids BEFORE polling restarts, then restarts \
            polling; the token is cleared and no barrier is left open
            """)
        func postFBThrow_repushesBlockIds_beforePollingRestarts() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            rig.recordPushes()
            defer { rig.sync.stopPolling() }
            var thrown = false

            try await rig.withEntry {
                do {
                    try await LifecycleEntry.run(kind: .projectSwitch) {
                        rig.note("perform")
                        throw AbortBoom()
                    }
                } catch is AbortBoom {
                    thrown = true
                }
                // The slot is free again as soon as `run` has thrown (read here: the harness resets it on the way out).
                #expect(LifecycleEntry.current == nil)
            }

            #expect(thrown, "the failure is re-reported: run rethrows what perform threw")
            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1, "precondition: FB applied before the throw")
            let push = try #require(rig.pushes.first, "the abort must re-push block ids after FB's non-preserving write")
            #expect(rig.pushes.count == 1)
            #expect(!push.pollTimerArmed, "the ids go back BEFORE polling restarts (event order): the timer was armed at the push")
            let dbIds = Set(try rig.blocks().map(\.id))
            #expect(!push.ids.isEmpty && Set(push.ids).isSubset(of: dbIds), "the pushed ids are FB's new ids: \(push.ids)")
            let perform = try #require(rig.log.firstIndex(of: "perform"))
            let pushed = try #require(rig.log.firstIndex(of: "pushBlockIds"))
            #expect(perform < pushed, "the re-push follows the failed perform; log: \(rig.log)")
            #expect(rig.sync.testPollTimerIsArmed, "and polling is running again afterwards")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleFlushDoneFor == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(rig.sync.testWriterHandle?.testOpenBarrierSeq == nil, "N9: no barrier is open after a non-tail exit")
            #expect(!rig.log.contains { $0.hasPrefix("tail:") }, "a failed perform runs no tail; log: \(rig.log)")
        }

        @Test("`isResettingContent` is cleared only AFTER the re-push (still set while the ids go back), then cleared")
        func isResettingContent_isClearedAfterTheRepush() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            rig.recordPushes()
            defer { rig.sync.stopPolling() }

            await rig.withEntry {
                _ = try? await LifecycleEntry.run(kind: .projectSwitch) {
                    rig.editorState.isResettingContent = true
                    throw AbortBoom()
                }
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran")
            let push = try #require(rig.pushes.first, "precondition: the abort re-pushed")
            #expect(push.isResettingContent, "the flag is still set while the ids are re-pushed")
            #expect(!rig.editorState.isResettingContent, "and cleared once the abort is done")
        }

        // MARK: - Must-fix #3: a section-operation cancel restarts polling

        @Test("""
            must-fix #3 / N23: a section operation that never clears CANCELS the close BEFORE FB; the abort still \
            restarts polling (nothing to re-push), and a LATER EDIT REACHES THE DATABASE (an unforced poll cycle, as \
            the timer's tick runs it, saves it: nothing is still held or suspended)
            """)
        func sectionOperationCancel_restartsPolling_andALaterEditReachesTheDatabase() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            rig.recordPushes()
            rig.controller.testSetIsPerforming(true)
            defer {
                rig.controller.testSetIsPerforming(false)
                rig.sync.stopPolling()
            }
            var outcome: LifecycleRunOutcome?
            var performed = 0

            try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.1)) {
                outcome = try await LifecycleEntry.run(kind: .close) {
                    performed += 1
                    return .close
                }
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(outcome == .cancelled)
            #expect(performed == 0)
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 0, "the wait timed out BEFORE FB: nothing was written")
            #expect(rig.pushes.isEmpty, "FB never ran, so there are no ids to restore")
            #expect(rig.sync.testPollTimerIsArmed, "polling MUST be running again, FB or not (the common cancel precedes FB)")

            // The proof that matters: an edit made after the cancel is saved. The tick is simulated with an
            // UNFORCED cycle (what the timer invokes); a barrier left held or a gate left shut would park the write.
            rig.controller.testSetIsPerforming(false)
            let paragraph = try #require(try rig.blocks().first { $0.blockType == .paragraph && $0.textContent == "one two three." })
            rig.js.answer("hasBlockChanges", true)
            rig.js.answer("getBlockChanges", try blockChangesJSON(updates: [
                BlockUpdate(id: paragraph.id, textContent: "typed after the cancel.", markdownFragment: nil, headingLevel: nil)
            ]))
            await rig.sync.pollBlockChangesForTest(force: false)
            let saved = try await waitUntil(seconds: 3) {
                try rig.paragraphTexts().contains("typed after the cancel.")
            }
            #expect(saved, "a later edit must reach the database; paragraphs: \((try? rig.paragraphTexts()) ?? [])")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
        }

        // MARK: - A refused barrier

        @Test("""
            a writer that refuses the barrier while FB is still parked behind the foreign one: the abort waits for \
            FB only within its bound, restarts polling, shows the busy notice, re-pushes nothing (FB is not known \
            to have applied) and leaves nothing held
            """)
        func barrierRefused_withFBStillQueued_restartsPollingAndNotifies() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            rig.recordPushes()
            let toasts = ToastCenter()
            rig.editorState.toastCenter = toasts
            let writer = try #require(rig.sync.testWriterHandle)
            let foreign = try #require(writer.enqueueBarrier(), "precondition: another barrier is open")
            defer { rig.sync.stopPolling() }
            var outcome: LifecycleRunOutcome?
            var performed = 0

            // FB stays parked behind the foreign barrier for the whole run (FB's 0.5s race and the abort's 0.5s
            // wait at this scale), and the barrier at step 8 is refused outright.
            try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.25)) {
                outcome = try await LifecycleEntry.run(kind: .close) {
                    performed += 1
                    return .close
                }
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(outcome == .cancelled)
            #expect(performed == 0, "a refused barrier cancels: perform is not called")
            #expect(toasts.current?.message == ToastFactory.lifecycleBusy().message)
            #expect(rig.pushes.isEmpty, "FB had not settled when the abort gave up waiting: nothing is known to need a re-push")
            #expect(rig.sync.testPollTimerIsArmed, "polling restarts whatever FB is doing")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil, "the lifecycle holds no barrier (only the foreign one is open)")
            #expect(rig.editorState.lifecycleFlushDoneFor == nil)

            // Let FB through so no write is left parked into the teardown, and make sure it lands (never lost).
            foreign.release()
            let landed = await waitUntil(seconds: 3) { rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1 }
            #expect(landed, "FB lands once the foreign barrier leaves")
        }

        // MARK: - Review row C8: a wedged re-push

        @Test("""
            review row C8: a re-push that never returns cannot hold the abort past its bound: run still throws, the \
            token is nil, polling is back, and a SECOND close is accepted
            """)
        func wedgedPush_abortReturnsWithinItsBound_tokenCleared_secondCloseAccepted() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            rig.recordPushes()
            let gate = LifecycleEntryHarness.Gate()
            rig.pushGate = gate
            defer {
                gate.open()
                rig.sync.stopPolling()
            }
            let clock = ContinuousClock()
            var elapsed: Duration = .zero
            var second: LifecycleRunOutcome?

            try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.1)) {
                let start = clock.now
                await #expect(throws: AbortBoom.self) {
                    try await LifecycleEntry.run(kind: .close) { throw AbortBoom() }
                }
                elapsed = clock.now - start
                #expect(LifecycleEntry.current == nil, "the busy slot is free even though the push never returned")
                #expect(rig.editorState.activeLifecycle == nil, "the token is cleared even if the re-push times out")
                #expect(rig.editorState.lifecycleBarrier == nil)
                #expect(rig.sync.testWriterHandle?.testOpenBarrierSeq == nil)
                // Read BEFORE the second close: its step 0 stops polling again.
                #expect(rig.sync.testPollTimerIsArmed, "polling restarts after the push timed out")
                second = try await LifecycleEntry.run(kind: .close) { .close }
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(rig.pushes.count == 1, "precondition: the push was attempted and is parked in the gate")
            #expect(elapsed < .seconds(1.4), "the abort is bounded (0.2s at this scale), not the 15s deadline: \(elapsed)")
            #expect(second == .performed, "review row C8: a second close must be accepted afterwards")
        }

        // MARK: - #18: a joined quit keeps its token and its barrier

        @Test("""
            #18: a quit that JOINED the lifecycle keeps its token and its barrier when the close's perform throws: \
            the abort stands down (no re-push, no polling restart, services stay suspended, flush marker kept)
            """)
        func joinedQuit_barrierAndToken_surviveTheClosesAbort() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            rig.recordPushes()
            let footnotes = rig.attachFootnoteService()
            let performGate = LifecycleEntryHarness.Gate()
            var quit: LifecycleToken?
            var closeToken: LifecycleToken?
            var runError: Error?

            await rig.withEntry {
                let run = Task { @MainActor () -> Error? in
                    do {
                        _ = try await LifecycleEntry.run(kind: .close) {
                            rig.note("perform")
                            await performGate.wait()
                            throw AbortBoom()
                        }
                        return nil
                    } catch {
                        return error
                    }
                }
                await LifecycleEntryHarness.waitUntil("the close's perform is running") { rig.log.contains("perform") }
                closeToken = LifecycleEntry.current?.token
                if case .joined(let token) = rig.editorState.armLifecycle(.quit, wasGettingStarted: false) { quit = token }
                performGate.open()
                runError = await run.value
                #expect(LifecycleEntry.current == nil)
            }

            let quitToken = try #require(quit, "precondition: the quit joined")
            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(runError is AbortBoom, "the close still reports its own failure")
            #expect(rig.editorState.activeLifecycle?.id == quitToken.id, "the quit's token is not cleared by the close's end")
            #expect(rig.editorState.lifecycleBarrier != nil, "a joined quit's barrier is held to exit, not released by the close")
            #expect(rig.sync.testWriterHandle?.testOpenBarrierSeq != nil, "and still open on the writer")
            #expect(!rig.sync.testPollTimerIsArmed, "stand-down: polling is not restarted under the quit")
            #expect(rig.pushes.isEmpty, "stand-down: no re-push")
            #expect(rig.editorState.lifecycleFlushDoneFor == closeToken?.id, "the quit sees the flush as done and does not flush again")
            footnotes.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: rig.pid, fullContent: "x[^1]")
            #expect(!footnotes.testHasPendingUpdate, "the sync services stay suspended for the quit")

            rig.editorState.releaseLifecycleBarrier()
            rig.editorState.clearLifecycle(quitToken.id)
            footnotes.reset()
        }

        @Test("#18: the same for a close that COMPLETES: its `finish` neither releases a joined quit's barrier nor clears its token")
        func joinedQuit_barrierAndToken_surviveTheClosesFinish() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            let performGate = LifecycleEntryHarness.Gate()
            var quit: LifecycleToken?
            var outcome: LifecycleRunOutcome?

            await rig.withEntry {
                let run = Task { @MainActor () -> LifecycleRunOutcome? in
                    try? await LifecycleEntry.run(kind: .close) {
                        rig.note("perform")
                        await performGate.wait()
                        return .close
                    }
                }
                await LifecycleEntryHarness.waitUntil("the close's perform is running") { rig.log.contains("perform") }
                if case .joined(let token) = rig.editorState.armLifecycle(.quit, wasGettingStarted: false) { quit = token }
                performGate.open()
                outcome = await run.value
            }

            let quitToken = try #require(quit, "precondition: the quit joined")
            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(outcome == .performed)
            #expect(rig.editorState.activeLifecycle?.id == quitToken.id)
            #expect(rig.editorState.lifecycleBarrier != nil, "released by the quit's own path, never by the close's defer")
            #expect(rig.sync.testWriterHandle?.testOpenBarrierSeq != nil)

            rig.editorState.releaseLifecycleBarrier()
            rig.editorState.clearLifecycle(quitToken.id)
        }
    }
}
